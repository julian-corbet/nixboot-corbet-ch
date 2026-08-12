# Produce a verifier for a complete raw cloud disk. Expected geometry is data:
# provider/storage adapters supply it, and nixboot checks rather than guessing.
{ pkgs
, name
, espTree
, sectorSize
, espPartitionLabel
, requiredPartitions
, imageMaterializer ? null
, allowedExtraEspFiles ? [ ]
, bootArtifactManifest ? null
, rootPathProjection ? null
,
}:
let
  lib = pkgs.lib;
  safeName = value: builtins.match "^[A-Za-z0-9][A-Za-z0-9._-]*$" value != null;
  safeLabel = value: builtins.match "^[^\n\r]+$" value != null;
  guid = value: builtins.match "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$" value != null;
  labels = map (partition: partition.label) requiredPartitions;
  espMatches = lib.filter (partition: partition.label == espPartitionLabel) requiredPartitions;
  safeEspPath = value: builtins.match "^[A-Za-z0-9][A-Za-z0-9._+/@=-]*$" value != null
    && !(lib.hasInfix ".." value) && !(lib.hasSuffix "/" value);
  safeAbsolutePath = value: builtins.match "^/[A-Za-z0-9._+/@=-]+$" value != null
    && !(lib.hasInfix ".." value) && !(lib.hasSuffix "/" value);
  rootMatches = if rootPathProjection == null then [ ] else
  lib.filter (partition: partition.label == rootPathProjection.partitionLabel) requiredPartitions;
  btrfsSubvolume = if rootPathProjection == null then null else rootPathProjection.btrfsSubvolume or null;
  materializerIsAttrs = builtins.isAttrs imageMaterializer;
  materializerName = if imageMaterializer == null then "raw" else if materializerIsAttrs then imageMaterializer.name or null else null;
  materializerInputs = if imageMaterializer == null then [ ] else if materializerIsAttrs then imageMaterializer.runtimeInputs or [ ] else [ ];
  materializerScript = if imageMaterializer == null then null else if materializerIsAttrs then imageMaterializer.script or null else null;
  partitionLines = lib.concatMapStringsSep "\n"
    (partition: builtins.toJSON {
      inherit (partition) label fsType;
      typeGuid = lib.toUpper partition.typeGuid;
    })
    requiredPartitions;
in
assert lib.assertMsg (safeName name) "mkEfiDiskImageVerifier: name must be a safe token";
assert lib.assertMsg (lib.elem sectorSize [ 512 4096 ])
  "mkEfiDiskImageVerifier: sectorSize must be 512 or 4096";
assert lib.assertMsg
  (imageMaterializer == null || (
    materializerIsAttrs
      && materializerName != null
      && safeName materializerName
      && builtins.isList materializerInputs
      && builtins.isString materializerScript
      && materializerScript != ""
  )) "mkEfiDiskImageVerifier: imageMaterializer must be null for raw input or an attrset with a safe name, runtimeInputs list, and non-empty script";
assert lib.assertMsg (requiredPartitions != [ ])
  "mkEfiDiskImageVerifier: at least one required partition is needed";
assert lib.assertMsg (lib.length labels == lib.length (lib.unique labels))
  "mkEfiDiskImageVerifier: required partition labels must be unique";
assert lib.assertMsg
  (lib.all
    (partition:
    safeLabel partition.label && guid partition.typeGuid && safeName partition.fsType
    )
    requiredPartitions) "mkEfiDiskImageVerifier: every partition needs a safe label, type GUID, and filesystem name";
assert lib.assertMsg (lib.length espMatches == 1 && (builtins.head espMatches).fsType == "vfat")
  "mkEfiDiskImageVerifier: espPartitionLabel must name exactly one required vfat partition";
assert lib.assertMsg (lib.all safeEspPath allowedExtraEspFiles)
  "mkEfiDiskImageVerifier: allowedExtraEspFiles must contain safe relative file paths";
assert lib.assertMsg ((bootArtifactManifest == null) == (rootPathProjection == null))
  "mkEfiDiskImageVerifier: bootArtifactManifest and rootPathProjection must be supplied together";
assert lib.assertMsg
  (rootPathProjection == null || (
    lib.length rootMatches == 1
      && safeAbsolutePath rootPathProjection.runtimePrefix
      && safeAbsolutePath rootPathProjection.imagePrefix
      && lib.elem (builtins.head rootMatches).fsType [ "ext2" "ext3" "ext4" "btrfs" ]
      && (btrfsSubvolume == null || (
      (builtins.head rootMatches).fsType == "btrfs"
        && builtins.match "^[A-Za-z0-9@][A-Za-z0-9@_-]*$" btrfsSubvolume != null
    ))
  )) "mkEfiDiskImageVerifier: rootPathProjection must name one required ext2/3/4 or btrfs partition and safe absolute prefixes";
pkgs.writeShellApplication {
  name = "nixboot-verify-${name}-disk-image";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.jq
    pkgs.mtools
    pkgs.util-linux
  ] ++ materializerInputs
  ++ lib.optionals (rootPathProjection != null) [ pkgs.btrfs-progs pkgs.e2fsprogs ];
  text = ''
    set -euo pipefail

    if [ "$#" -ne 1 ]; then
      echo "usage: nixboot-verify-${name}-disk-image IMAGE" >&2
      exit 64
    fi

    readonly source_image="$1"
    [ -f "$source_image" ] || { echo "nixboot: disk image is not a regular file: $source_image" >&2; exit 1; }

    work="$(mktemp -d -t nixboot-disk-image-XXXXXX)"
    cleanup() {
      chmod -R u+w "$work" 2>/dev/null || true
      rm -rf "$work" || true
    }
    trap cleanup EXIT
    ${if imageMaterializer == null then ''
      raw="$source_image"
    '' else ''
      readonly target="$work/image.raw"
      # The adapter receives read-only $source_image and $target. It owns only
      # transport decoding; all disk semantics below remain nixboot's check.
      ${materializerScript}
      [ -f "$target" ] || {
        echo "nixboot: image materializer '${materializerName}' did not produce $target" >&2
        exit 1
      }
      raw="$target"
    ''}

    table="$work/partition-table.json"
    if ! sfdisk --json --sector-size ${toString sectorSize} "$raw" > "$table"; then
      echo "nixboot: image does not parse using the declared ${toString sectorSize}-byte sector size" >&2
      exit 1
    fi
    [ "$(jq -r '.partitiontable.label' "$table")" = gpt ] || {
      echo "nixboot: disk image is not GPT" >&2
      exit 1
    }
    [ "$(jq -r '.partitiontable.sectorsize' "$table")" = ${toString sectorSize} ] || {
      echo "nixboot: partition parser did not retain the declared sector size" >&2
      exit 1
    }

    esp_offset=""
    while IFS= read -r expected_partition; do
      expected_label="$(jq -r '.label' <<<"$expected_partition")"
      expected_type="$(jq -r '.typeGuid' <<<"$expected_partition")"
      expected_fs="$(jq -r '.fsType' <<<"$expected_partition")"
      matches="$(jq --arg label "$expected_label" '[.partitiontable.partitions[] | select(.name == $label)] | length' "$table")"
      [ "$matches" = 1 ] || {
        echo "nixboot: expected exactly one GPT partition named '$expected_label', found $matches" >&2
        exit 1
      }
      partition="$(jq -c --arg label "$expected_label" '.partitiontable.partitions[] | select(.name == $label)' "$table")"
      actual_type="$(jq -r '.type | ascii_upcase' <<<"$partition")"
      [ "$actual_type" = "$expected_type" ] || {
        echo "nixboot: partition '$expected_label' has type $actual_type, expected $expected_type" >&2
        exit 1
      }

      start="$(jq -r '.start' <<<"$partition")"
      sectors="$(jq -r '.size' <<<"$partition")"
      offset="$((start * ${toString sectorSize}))"
      bytes="$((sectors * ${toString sectorSize}))"
      actual_fs="$(blkid -p -O "$offset" -S "$bytes" -s TYPE -o value "$raw" 2>/dev/null || true)"
      [ "$actual_fs" = "$expected_fs" ] || {
        echo "nixboot: partition '$expected_label' contains '$actual_fs', expected '$expected_fs'" >&2
        exit 1
      }
      if [ "$expected_label" = ${lib.escapeShellArg espPartitionLabel} ]; then
        esp_offset="$offset"
      fi
      echo "PASS  partition $expected_label: type=$actual_type fs=$actual_fs"
    done <<'NIXBOOT_PARTITIONS'
    ${partitionLines}
    NIXBOOT_PARTITIONS

    [ -n "$esp_offset" ] || { echo "nixboot: no ESP offset was resolved" >&2; exit 1; }
    esp_tree=${lib.escapeShellArg (toString espTree)}
    if find "$esp_tree" -type l -print -quit | grep . >/dev/null; then
      echo "nixboot: the declared ESP tree contains a symlink, which FAT cannot preserve" >&2
      exit 1
    fi

    expected_files="$work/expected-esp-files"
    actual_files="$work/actual-esp-files"
    allowed_files="$work/allowed-esp-files"
    find "$esp_tree" -type f -printf '%P\n' | sort > "$expected_files"
    MTOOLS_SKIP_CHECK=1 mdir -/ -b -i "$raw@@$esp_offset" :: \
      | sed -n '\#/$#d; s#^::/##p' | sort > "$actual_files"
    cat > "$allowed_files" <<'NIXBOOT_ALLOWED_ESP_FILES'
    ${lib.concatStringsSep "\n" allowedExtraEspFiles}
    NIXBOOT_ALLOWED_ESP_FILES

    while IFS= read -r extra; do
      [ -n "$extra" ] || continue
      if ! grep -Fx "$extra" "$allowed_files" >/dev/null; then
        echo "nixboot: ESP contains an undeclared extra file: /$extra" >&2
        exit 1
      fi
    done < <(comm -13 "$expected_files" "$actual_files")

    while IFS= read -r -d "" expected; do
      relative="''${expected#"$esp_tree"/}"
      actual="$work/esp-file"
      rm -f "$actual"
      if ! MTOOLS_SKIP_CHECK=1 mcopy -i "$raw@@$esp_offset" "::/$relative" "$actual" >/dev/null 2>&1; then
        echo "nixboot: ESP is missing /$relative" >&2
        exit 1
      fi
      if ! cmp "$expected" "$actual"; then
        echo "nixboot: ESP file differs from the declared artifact: /$relative" >&2
        exit 1
      fi
    done < <(find "$esp_tree" -type f -print0 | sort -z)

    echo "PASS  ESP payload matches the checked nixboot artifact byte for byte"
    ${lib.optionalString (rootPathProjection != null) ''
      manifest=${lib.escapeShellArg (toString bootArtifactManifest)}
      [ -f "$manifest" ] || { echo "nixboot: boot artifact manifest is absent: $manifest" >&2; exit 1; }
      runtime_init="$(jq -er '.payload.init | select(type == "string" and startswith("/"))' "$manifest")"
      if ! [[ "$runtime_init" =~ ^/[A-Za-z0-9._+/@=-]+$ ]]; then
        echo "nixboot: manifest init is not a safe absolute path: $runtime_init" >&2
        exit 1
      fi
      runtime_prefix=${lib.escapeShellArg rootPathProjection.runtimePrefix}
      image_prefix=${lib.escapeShellArg rootPathProjection.imagePrefix}
      case "$runtime_init" in
        "$runtime_prefix"/*) relative_init="''${runtime_init#"$runtime_prefix"/}" ;;
        *)
          echo "nixboot: manifest init '$runtime_init' is outside declared runtime prefix '$runtime_prefix'" >&2
          exit 1
          ;;
      esac
      case "$relative_init" in
        ""|/*|../*|*/../*|*/..)
          echo "nixboot: manifest init has an unsafe path below '$runtime_prefix': $runtime_init" >&2
          exit 1
          ;;
      esac
      image_init="$image_prefix/$relative_init"

      root_partition="$(jq -c --arg label ${lib.escapeShellArg rootPathProjection.partitionLabel} \
        '.partitiontable.partitions[] | select(.name == $label)' "$table")"
      root_start="$(jq -r '.start' <<<"$root_partition")"
      root_sectors="$(jq -r '.size' <<<"$root_partition")"
      root_offset="$((root_start * ${toString sectorSize}))"
      root_bytes="$((root_sectors * ${toString sectorSize}))"
      root_image="$work/root-partition.img"
      dd if="$raw" of="$root_image" iflag=skip_bytes,count_bytes \
        bs=16M skip="$root_offset" count="$root_bytes" conv=sparse status=none
      truncate -s "$root_bytes" "$root_image"
      root_fs="$(blkid -p -s TYPE -o value "$root_image")"

      case "$root_fs" in
        ext2|ext3|ext4)
          extracted_init="$work/extracted-init"
          debugfs -R "dump -p $image_init $extracted_init" "$root_image" >/dev/null 2>&1 || true
          if [ ! -s "$extracted_init" ] || [ ! -x "$extracted_init" ]; then
            echo "nixboot: root image lacks an executable manifest init projection: $runtime_init -> $image_init" >&2
            exit 1
          fi
          ;;
        btrfs)
          # btrfs restore reads an unmounted filesystem and can select one
          # exact path. When the store lives in its own subvolume, resolve
          # that subvolume's root ID and check the path relative to it.
          restore_init="$image_init"
          root_args=()
          ${lib.optionalString (btrfsSubvolume != null) ''
            btrfs_subvolume=${lib.escapeShellArg btrfsSubvolume}
            case "$image_init" in
              "/$btrfs_subvolume"/*) restore_init="/''${image_init#"/$btrfs_subvolume"/}" ;;
              *)
                echo "nixboot: image init '$image_init' is outside declared btrfs subvolume '$btrfs_subvolume'" >&2
                exit 1
                ;;
            esac
            root_id="$(btrfs inspect-internal dump-tree -t root "$root_image" \
              | sed -n '/ROOT_REF [0-9][0-9]*)/ {N; /name '"$btrfs_subvolume"'$/ {s/.*ROOT_REF \([0-9][0-9]*\)).*/\1/p}}')"
            if ! [[ "$root_id" =~ ^[0-9]+$ ]]; then
              echo "nixboot: btrfs subvolume '$btrfs_subvolume' has no unique root ID" >&2
              exit 1
            fi
            root_args=(-r "$root_id")
          ''}
          # Build btrfs restore's documented nested-prefix regex without
          # interpreting any path component as a regular expression.
          IFS='/' read -r -a components <<<"''${restore_init#/}"
          path_regex='^/(|'
          for index in "''${!components[@]}"; do
            component="''${components[$index]}"
            escaped="$(printf '%s' "$component" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
            if [ "$index" -eq 0 ]; then
              path_regex+="$escaped"
            else
              path_regex+="(|/$escaped"
            fi
          done
          for _component in "''${components[@]}"; do path_regex+=')'; done
          path_regex+='$'
          restore="$work/root-restore"
          mkdir -p "$restore"
          btrfs restore -m -S "''${root_args[@]}" --path-regex "$path_regex" \
            "$root_image" "$restore" >/dev/null 2>&1 || true
          if [ ! -s "$restore$restore_init" ] || [ ! -x "$restore$restore_init" ]; then
            echo "nixboot: root image lacks an executable manifest init projection: $runtime_init -> $image_init" >&2
            exit 1
          fi
          ;;
        *)
          echo "nixboot: root-path verification has no reader for filesystem '$root_fs'" >&2
          exit 1
          ;;
      esac
      echo "PASS  manifest init exists in root image: $runtime_init -> $image_init"
      echo "PASS  complete disk image satisfies the declared nixboot handoff"
    ''}
    ${lib.optionalString (rootPathProjection == null) ''
      echo "PASS  disk image satisfies the declared firmware/loader handoff (root projection not requested)"
    ''}
  '';
}
