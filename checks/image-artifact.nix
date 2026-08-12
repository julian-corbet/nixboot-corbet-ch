{ pkgs
, mkSystemdBootArtifact
, mkEfiDiskImageVerifier
, mkEfiDiskImageCheck
,
}:
let
  espType = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B";
  rootType = "0FC63DAF-8483-4772-8E79-3D69D8477DE4";
  partitions = [
    { label = "disk-root-ESP"; typeGuid = espType; fsType = "vfat"; }
    { label = "disk-root-root"; typeGuid = rootType; fsType = "btrfs"; }
  ];
  extPartitions = [
    { label = "disk-root-ESP"; typeGuid = espType; fsType = "vfat"; }
    { label = "disk-root-root"; typeGuid = rootType; fsType = "ext4"; }
  ];

  fakeToplevel = pkgs.runCommand "nixboot-cloud-fixture-toplevel" { } ''
    mkdir -p "$out"
    printf '#!/bin/sh\nexit 0\n' > "$out/init"
    chmod 0555 "$out/init"
  '';
  fakeInitrd = pkgs.writeText "nixboot-cloud-fixture-initrd" "a non-empty initrd fixture\n";
  efiArch = pkgs.stdenv.hostPlatform.efiArch;
  efiExecutable = "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";

  artifact = mkSystemdBootArtifact {
    inherit pkgs;
    name = "cloud-fixture";
    deviceClass = "nixvps";
    role = "primary";
    steadyStateHandoff = "removable";
    title = "nixboot cloud fixture";
    version = "Generation 1";
    toplevel = fakeToplevel;
    kernel = efiExecutable;
    initrd = fakeInitrd;
    kernelParams = [ "console=tty0" "console=ttyS0,115200n8" ];
    timeout = 5;
    editor = false;
    consoleMode = "keep";
  };
  writeHandoffArtifact = mkSystemdBootArtifact {
    inherit pkgs;
    name = "cloud-write-fixture";
    deviceClass = "nixvps";
    role = "primary";
    steadyStateHandoff = "write";
    title = "nixboot cloud write fixture";
    version = "Generation 1";
    toplevel = fakeToplevel;
    kernel = efiExecutable;
    initrd = fakeInitrd;
  };
  rescueArtifact = mkSystemdBootArtifact {
    inherit pkgs;
    name = "nixrescue-release";
    deviceClass = "nixnas";
    role = "nixrescue";
    steadyStateHandoff = "removable";
    title = "nixrescue";
    version = "Release 1";
    toplevel = fakeToplevel;
    kernel = efiExecutable;
    initrd = fakeInitrd;
  };
  bootArtifactManifest = "${artifact.manifest}/nixboot-boot-artifact.json";
  rootPathProjection = {
    partitionLabel = "disk-root-root";
    runtimePrefix = "/nix/store";
    imagePrefix = "/@nix/store";
    btrfsSubvolume = "@nix";
  };

  invalidInitRejected = !(builtins.tryEval (mkSystemdBootArtifact {
    inherit pkgs;
    name = "invalid-init-fixture";
    deviceClass = "nixvps";
    role = "primary";
    steadyStateHandoff = "removable";
    title = "invalid";
    version = "invalid";
    toplevel = fakeToplevel;
    kernel = efiExecutable;
    initrd = fakeInitrd;
    kernelParams = [ "init=/wrong/store/path/init" ];
  })).success;

  invalidDeviceClassRejected = !(builtins.tryEval (mkSystemdBootArtifact {
    inherit pkgs;
    name = "invalid-class-fixture";
    deviceClass = "some-provider";
    role = "primary";
    steadyStateHandoff = "removable";
    title = "invalid";
    version = "invalid";
    toplevel = fakeToplevel;
    kernel = efiExecutable;
    initrd = fakeInitrd;
  })).success;

  invalidMaterializerRejected = !(builtins.tryEval (mkEfiDiskImageVerifier {
    inherit pkgs;
    name = "invalid-materializer-fixture";
    espTree = artifact.tree;
    sectorSize = 512;
    espPartitionLabel = "disk-root-ESP";
    requiredPartitions = partitions;
    imageMaterializer = { name = "missing-script"; };
  })).success;

  artifactContract = assert invalidInitRejected; assert invalidDeviceClassRejected; assert invalidMaterializerRejected; pkgs.runCommand "nixboot-cloud-artifact-contract"
    { nativeBuildInputs = [ pkgs.jq ]; }
    ''
      set -euo pipefail
      tree=${artifact.tree}
      manifest=${bootArtifactManifest}
      test -s "$tree/EFI/BOOT/BOOT${pkgs.lib.toUpper efiArch}.EFI"
      test -s "$tree/loader/entries/nixos-generation-1.conf"
      write_manifest=${writeHandoffArtifact.manifest}/nixboot-boot-artifact.json
      rescue_manifest=${rescueArtifact.manifest}/nixboot-boot-artifact.json
      test "$(jq -r '.schemaVersion' "$manifest")" = 2
      test "$(jq -r '.deviceClass' "$manifest")" = nixvps
      test "$(jq -r '.firmware.initialHandoff' "$manifest")" = removable
      test "$(jq -r '.firmware.steadyStateHandoff' "$manifest")" = removable
      test "$(jq -r '.firmware.initialHandoff' "$write_manifest")" = removable
      test "$(jq -r '.firmware.steadyStateHandoff' "$write_manifest")" = write
      test "$(jq -r '.deviceClass' "$rescue_manifest")" = nixnas
      test "$(jq -r '.role' "$rescue_manifest")" = nixrescue
      test "$(jq -r '.loader.defaultEntry' "$rescue_manifest")" = /loader/entries/nixrescue-generation-1.conf
      test "$(jq -r '.payload.kernel' "$rescue_manifest")" = /EFI/nixos/nixrescue-generation-1-kernel.efi
      test "$(jq -r '.loader.selfHealRequired' "$manifest")" = true
      test "$(jq -r '.integrity.firmwareVerified' "$manifest")" = false
      test "$(jq -r '.payload.kernelParams[-1]' "$manifest")" = console=ttyS0,115200n8
      touch "$out"
    '';

  diskImage = pkgs.runCommand "nixboot-cloud-disk-fixture"
    {
      nativeBuildInputs = [
        pkgs.coreutils
        pkgs.btrfs-progs
        pkgs.dosfstools
        pkgs.jq
        pkgs.mtools
        pkgs.util-linux
      ];
    }
    ''
      set -euo pipefail
      mkdir -p "$out"
      image="$out/cloud-fixture.raw"
      truncate -s 192M "$image"
      printf 'label: gpt\nsize=32M,type=${espType},name=disk-root-ESP\nsize=+,type=${rootType},name=disk-root-root\n' \
        | sfdisk --sector-size 512 "$image" >/dev/null

      table="$PWD/table.json"
      sfdisk --json --sector-size 512 "$image" > "$table"
      esp_start="$(jq -r '.partitiontable.partitions[] | select(.name == "disk-root-ESP") | .start' "$table")"
      esp_sectors="$(jq -r '.partitiontable.partitions[] | select(.name == "disk-root-ESP") | .size' "$table")"
      root_start="$(jq -r '.partitiontable.partitions[] | select(.name == "disk-root-root") | .start' "$table")"
      root_sectors="$(jq -r '.partitiontable.partitions[] | select(.name == "disk-root-root") | .size' "$table")"

      esp_image="$PWD/esp.img"
      truncate -s "$((esp_sectors * 512))" "$esp_image"
      mkfs.vfat -n NIXBOOT "$esp_image" >/dev/null
      MTOOLS_SKIP_CHECK=1 mcopy -s -i "$esp_image" ${artifact.tree}/* ::/
      dd if="$esp_image" of="$image" bs=512 seek="$esp_start" conv=notrunc,sparse status=none

      root_image="$PWD/root.img"
      truncate -s "$((root_sectors * 512))" "$root_image"
      root_tree="$PWD/root-tree"
      mkdir -p "$root_tree/@nix/store"
      cp -a ${fakeToplevel} "$root_tree/@nix/store/$(basename ${fakeToplevel})"
      mkfs.btrfs -q -f -L nixroot -r "$root_tree" --subvol rw:@nix "$root_image"
      dd if="$root_image" of="$image" bs=512 seek="$root_start" conv=notrunc,sparse status=none
    '';

  verifier = mkEfiDiskImageVerifier {
    inherit pkgs;
    name = "cloud-fixture";
    espTree = artifact.tree;
    sectorSize = 512;
    espPartitionLabel = "disk-root-ESP";
    requiredPartitions = partitions;
    inherit bootArtifactManifest rootPathProjection;
  };
  compressedVerifier = mkEfiDiskImageVerifier {
    inherit pkgs;
    name = "cloud-fixture-zstd";
    espTree = artifact.tree;
    sectorSize = 512;
    espPartitionLabel = "disk-root-ESP";
    requiredPartitions = partitions;
    imageMaterializer = {
      name = "zstd";
      runtimeInputs = [ pkgs.zstd ];
      script = ''zstd -dc -- "$source_image" > "$target"'';
    };
    inherit bootArtifactManifest rootPathProjection;
  };
  sector4096Verifier = mkEfiDiskImageVerifier {
    inherit pkgs;
    name = "cloud-fixture-4096";
    espTree = artifact.tree;
    sectorSize = 4096;
    espPartitionLabel = "disk-root-ESP";
    requiredPartitions = partitions;
    inherit bootArtifactManifest rootPathProjection;
  };
  missingOutputVerifier = mkEfiDiskImageVerifier {
    inherit pkgs;
    name = "cloud-fixture-missing-materializer-output";
    espTree = artifact.tree;
    sectorSize = 512;
    espPartitionLabel = "disk-root-ESP";
    requiredPartitions = partitions;
    imageMaterializer = {
      name = "missing-output";
      script = ":";
    };
    inherit bootArtifactManifest rootPathProjection;
  };

  diskImageCheck = mkEfiDiskImageCheck {
    inherit pkgs;
    name = "cloud-fixture";
    image = "${diskImage}/cloud-fixture.raw";
    espTree = artifact.tree;
    sectorSize = 512;
    espPartitionLabel = "disk-root-ESP";
    requiredPartitions = partitions;
    inherit bootArtifactManifest rootPathProjection;
  };

  extDiskImage = pkgs.runCommand "nixboot-cloud-ext4-disk-fixture"
    {
      nativeBuildInputs = [
        pkgs.coreutils
        pkgs.dosfstools
        pkgs.e2fsprogs
        pkgs.jq
        pkgs.mtools
        pkgs.util-linux
      ];
    }
    ''
      set -euo pipefail
      mkdir -p "$out"
      image="$out/cloud-ext4-fixture.raw"
      truncate -s 96M "$image"
      printf 'label: gpt\nsize=32M,type=${espType},name=disk-root-ESP\nsize=+,type=${rootType},name=disk-root-root\n' \
        | sfdisk --sector-size 512 "$image" >/dev/null
      table="$PWD/table.json"
      sfdisk --json --sector-size 512 "$image" > "$table"
      esp_start="$(jq -r '.partitiontable.partitions[] | select(.name == "disk-root-ESP") | .start' "$table")"
      esp_sectors="$(jq -r '.partitiontable.partitions[] | select(.name == "disk-root-ESP") | .size' "$table")"
      root_start="$(jq -r '.partitiontable.partitions[] | select(.name == "disk-root-root") | .start' "$table")"
      root_sectors="$(jq -r '.partitiontable.partitions[] | select(.name == "disk-root-root") | .size' "$table")"
      truncate -s "$((esp_sectors * 512))" "$PWD/esp.img"
      mkfs.vfat -n NIXBOOT "$PWD/esp.img" >/dev/null
      MTOOLS_SKIP_CHECK=1 mcopy -s -i "$PWD/esp.img" ${artifact.tree}/* ::/
      dd if="$PWD/esp.img" of="$image" bs=512 seek="$esp_start" conv=notrunc,sparse status=none
      mkdir -p "$PWD/root-tree/nix/store"
      cp -a ${fakeToplevel} "$PWD/root-tree/nix/store/$(basename ${fakeToplevel})"
      truncate -s "$((root_sectors * 512))" "$PWD/root.img"
      mkfs.ext4 -q -F -L nixroot -d "$PWD/root-tree" "$PWD/root.img"
      dd if="$PWD/root.img" of="$image" bs=512 seek="$root_start" conv=notrunc,sparse status=none
    '';

  extDiskImageCheck = mkEfiDiskImageCheck {
    inherit pkgs;
    name = "cloud-ext4-fixture";
    image = "${extDiskImage}/cloud-ext4-fixture.raw";
    espTree = artifact.tree;
    sectorSize = 512;
    espPartitionLabel = "disk-root-ESP";
    requiredPartitions = extPartitions;
    inherit bootArtifactManifest;
    rootPathProjection = {
      partitionLabel = "disk-root-root";
      runtimePrefix = "/nix/store";
      imagePrefix = "/nix/store";
    };
  };

  diskImageRefusals = pkgs.runCommand "nixboot-cloud-disk-image-refusals"
    {
      nativeBuildInputs = [
        verifier
        compressedVerifier
        sector4096Verifier
        missingOutputVerifier
        pkgs.coreutils
        pkgs.dosfstools
        pkgs.btrfs-progs
        pkgs.jq
        pkgs.mtools
        pkgs.util-linux
        pkgs.zstd
      ];
    }
    ''
      set -euo pipefail
      good=${diskImage}/cloud-fixture.raw

      # Transport compression changes no boot semantics.
      zstd -q "$good" -o "$PWD/good.raw.zst"
      nixboot-verify-cloud-fixture-zstd-disk-image "$PWD/good.raw.zst" >/dev/null

      # A transport adapter is a checked contract, not a trusted side effect.
      # Returning successfully without materializing raw bytes is a refusal.
      if nixboot-verify-cloud-fixture-missing-materializer-output-disk-image \
        "$good" >"$PWD/out" 2>"$PWD/err"; then
        echo "nixboot disk gate accepted a materializer with no output" >&2
        exit 1
      fi
      grep -q "did not produce" "$PWD/err"

      # A structurally valid root filesystem under the wrong GPT type is the
      # exact early-boot failure the gate must reject.
      cp --sparse=always "$good" "$PWD/wrong-type.raw"
      chmod u+w "$PWD/wrong-type.raw"
      sfdisk --part-type "$PWD/wrong-type.raw" 2 ${espType} >/dev/null
      if nixboot-verify-cloud-fixture-disk-image "$PWD/wrong-type.raw" >"$PWD/out" 2>"$PWD/err"; then
        echo "nixboot disk gate accepted the wrong root partition type" >&2
        exit 1
      fi
      grep -q "partition 'disk-root-root' has type" "$PWD/err"

      # Geometry can stay perfect while one boot byte drifts. The image must
      # still be rejected before a provider sees it.
      cp --sparse=always "$good" "$PWD/tampered.raw"
      chmod u+w "$PWD/tampered.raw"
      printf 'tampered loader configuration\n' > "$PWD/tampered-loader.conf"
      esp_start="$(sfdisk --json --sector-size 512 "$PWD/tampered.raw" \
        | jq -r '.partitiontable.partitions[] | select(.name == "disk-root-ESP") | .start')"
      MTOOLS_SKIP_CHECK=1 mcopy -D o -i "$PWD/tampered.raw@@$((esp_start * 512))" \
        "$PWD/tampered-loader.conf" ::/loader/loader.conf
      if nixboot-verify-cloud-fixture-disk-image "$PWD/tampered.raw" >"$PWD/out" 2>"$PWD/err"; then
        echo "nixboot disk gate accepted a tampered ESP" >&2
        exit 1
      fi
      grep -q "ESP file differs" "$PWD/err"

      cp --sparse=always "$good" "$PWD/extra-entry.raw"
      chmod u+w "$PWD/extra-entry.raw"
      printf 'unexpected\n' > "$PWD/unexpected.conf"
      MTOOLS_SKIP_CHECK=1 mcopy -i "$PWD/extra-entry.raw@@$((esp_start * 512))" \
        "$PWD/unexpected.conf" ::/loader/entries/unexpected.conf
      if nixboot-verify-cloud-fixture-disk-image "$PWD/extra-entry.raw" >"$PWD/out" 2>"$PWD/err"; then
        echo "nixboot disk gate accepted an undeclared ESP file" >&2
        exit 1
      fi
      grep -q "undeclared extra file" "$PWD/err"

      # Reproduce the historical store-prefix failure: the init path in the
      # signed/declared command line is /nix/store/..., while the disk contains
      # the same closure under /@nix/nix/store/.... Geometry and ESP are both
      # correct, but this image cannot reach init and must be refused.
      cp --sparse=always "$good" "$PWD/wrong-store-prefix.raw"
      chmod u+w "$PWD/wrong-store-prefix.raw"
      root_start="$(sfdisk --json --sector-size 512 "$PWD/wrong-store-prefix.raw" \
        | jq -r '.partitiontable.partitions[] | select(.name == "disk-root-root") | .start')"
      root_sectors="$(sfdisk --json --sector-size 512 "$PWD/wrong-store-prefix.raw" \
        | jq -r '.partitiontable.partitions[] | select(.name == "disk-root-root") | .size')"
      mkdir -p "$PWD/wrong-root/@nix/nix/store"
      cp -a ${fakeToplevel} "$PWD/wrong-root/@nix/nix/store/$(basename ${fakeToplevel})"
      truncate -s "$((root_sectors * 512))" "$PWD/wrong-root.img"
      mkfs.btrfs -q -f -L nixroot -r "$PWD/wrong-root" --subvol rw:@nix "$PWD/wrong-root.img"
      dd if="$PWD/wrong-root.img" of="$PWD/wrong-store-prefix.raw" bs=512 \
        seek="$root_start" conv=notrunc,sparse status=none
      if nixboot-verify-cloud-fixture-disk-image "$PWD/wrong-store-prefix.raw" >"$PWD/out" 2>"$PWD/err"; then
        echo "nixboot disk gate accepted an unreachable manifest init path" >&2
        exit 1
      fi
      grep -q "lacks an executable manifest init projection" "$PWD/err"

      # A raw image does not carry a separate sector-size label. Its GPT is
      # located in units of the size used while constructing it, so parsing a
      # 4096-byte-sector image as a provider's declared 512-byte disk must fail.
      sector_image="$PWD/wrong-sector-size.raw"
      truncate -s 192M "$sector_image"
      printf 'label: gpt\nsize=32M,type=${espType},name=disk-root-ESP\nsize=+,type=${rootType},name=disk-root-root\n' \
        | sfdisk --sector-size 4096 "$sector_image" >/dev/null
      sector_table="$PWD/sector-table.json"
      sfdisk --json --sector-size 4096 "$sector_image" > "$sector_table"
      sector_esp_start="$(jq -r '.partitiontable.partitions[] | select(.name == "disk-root-ESP") | .start' "$sector_table")"
      sector_esp_sectors="$(jq -r '.partitiontable.partitions[] | select(.name == "disk-root-ESP") | .size' "$sector_table")"
      sector_root_start="$(jq -r '.partitiontable.partitions[] | select(.name == "disk-root-root") | .start' "$sector_table")"
      sector_root_sectors="$(jq -r '.partitiontable.partitions[] | select(.name == "disk-root-root") | .size' "$sector_table")"
      truncate -s "$((sector_esp_sectors * 4096))" "$PWD/sector-esp.img"
      mkfs.vfat -n NIXBOOT "$PWD/sector-esp.img" >/dev/null
      MTOOLS_SKIP_CHECK=1 mcopy -s -i "$PWD/sector-esp.img" ${artifact.tree}/* ::/
      dd if="$PWD/sector-esp.img" of="$sector_image" bs=4096 seek="$sector_esp_start" conv=notrunc,sparse status=none
      truncate -s "$((sector_root_sectors * 4096))" "$PWD/sector-root.img"
      mkdir -p "$PWD/sector-root/@nix/store"
      cp -a ${fakeToplevel} "$PWD/sector-root/@nix/store/$(basename ${fakeToplevel})"
      mkfs.btrfs -q -f -L nixroot -r "$PWD/sector-root" --subvol rw:@nix "$PWD/sector-root.img"
      dd if="$PWD/sector-root.img" of="$sector_image" bs=4096 seek="$sector_root_start" conv=notrunc,sparse status=none
      nixboot-verify-cloud-fixture-4096-disk-image "$sector_image" >/dev/null
      if nixboot-verify-cloud-fixture-disk-image "$sector_image" >"$PWD/out" 2>"$PWD/err"; then
        echo "nixboot disk gate accepted a 4096-byte-sector image as 512-byte" >&2
        exit 1
      fi
      test -s "$PWD/err"

      touch "$out"
    '';
in
{
  image-artifact-contract = artifactContract;
  efi-disk-image = diskImageCheck;
  efi-disk-image-ext4 = extDiskImageCheck;
  efi-disk-image-refusals = diskImageRefusals;
}
