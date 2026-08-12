# Cloud and VM boot artifacts

Cloud does not change nixboot's boundary: firmware still has to find a loader,
the loader still has to find an exact kernel and initrd, and the initrd still
has to reach the declared NixOS `init`. What changes is the recovery medium and
who supplies the disk.

`nixboot.imageArtifact` is the provider-neutral NixOS backend for the UEFI
portion of an offline-baked disk. `deviceClass` is required and independent
of `role`: the same rescue release can be projected for a class without
acquiring a provider or machine identity. It produces two build outputs:

| Output | Meaning |
|---|---|
| `system.build.nixbootBootArtifact` | A checked ESP file tree ready to become the contents of a FAT ESP. |
| `system.build.nixbootBootArtifactManifest` | Machine-readable device class, boot role, firmware handoff, loader paths, exact `init`, and command line. |

The artifact is derived from the evaluated system's own kernel, initrd,
toplevel and `boot.kernelParams`. There is no second command-line declaration,
and a caller-supplied `init=` is rejected: nixboot always writes the exact
`${config.system.build.toplevel}/init`.

Every offline disk initially boots through
`EFI/BOOT/BOOT<ARCH>.EFI`; no disk image can pre-create an NVRAM variable in
the future VM or machine. The manifest records that immutable
`initialHandoff = "removable"` separately from `steadyStateHandoff`, which is
the declared `loader.efiVariables` policy once the system is running. On each
successful boot, self-heal repairs loader files and also attempts the NVRAM
entry when the steady-state policy is `"write"`; it passes `--no-variables`
only for `"removable"`.

The manifest also says explicitly that this split kernel/initrd artifact is
not a firmware-verified Secure Boot chain. That guarantee requires a signed
UKI format; absence of a signature claim must never be mistaken for one.

```nix
{
  nixboot = {
    enable = true;
    loader = {
      program = "systemd-boot";
      efiVariables = "removable";
      timeout = 5;
      # selfHeal defaults to true when imageArtifact is enabled. Setting it
      # false is an assertion failure: this ESP never ran bootctl install.
    };
    console.primary = "serial";
    imageArtifact = {
      enable = true;
      deviceClass = "nixvps";
      role = "primary";
    };
  };
}
```

The disk-layout owner consumes the checked tree; nixboot does not create or
size the partition:

```nix
{
  image.repart.partitions."10-esp".contents."/".source =
    config.system.build.nixbootBootArtifact;
}
```

That split is deliberate. A provider adapter may need 512-byte or 4096-byte
sectors, a fixed or growing disk, and any root filesystem. Those are facts
about the provider/storage contract, not new bootloader variants.

## Complete-disk acceptance

Checking the tree is insufficient if the final image gives it the wrong GPT
type or changes a byte while packing the FAT filesystem. The exported
`lib.mkEfiDiskImageCheck` checks the final raw image without loop devices or
mounts:

```nix
nixboot.lib.mkEfiDiskImageCheck {
  inherit pkgs;
  name = "my-cloud-image";
  image = "${config.system.build.image}/${config.image.fileName}";
  # Raw is the default. An envelope is an injected adapter, not a provider
  # name known to nixboot. This example accepts a zstd stream.
  imageMaterializer = {
    name = "zstd";
    runtimeInputs = [ pkgs.zstd ];
    script = ''zstd -dc -- "$source_image" > "$target"'';
  };
  espTree = config.system.build.nixbootBootArtifact;
  bootArtifactManifest =
    "${config.system.build.nixbootBootArtifactManifest}/nixboot-boot-artifact.json";
  sectorSize = 512;
  espPartitionLabel = "disk-root-ESP";
  requiredPartitions = [
    {
      label = "disk-root-ESP";
      typeGuid = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B";
      fsType = "vfat";
    }
    {
      label = "disk-root-root";
      typeGuid = "0FC63DAF-8483-4772-8E79-3D69D8477DE4";
      fsType = "btrfs";
    }
  ];
  rootPathProjection = {
    partitionLabel = "disk-root-root";
    runtimePrefix = "/nix/store";
    # The image assembler writes the runtime /nix/store into this btrfs
    # subvolume path. A wrong value is found in the final image, not trusted.
    imagePrefix = "/@nix/store";
    btrfsSubvolume = "@nix";
  };
  # allowedExtraEspFiles = [ "EFI/vendor/capsule.efi" ];
}
```

Every value in that example is an input. The verifier has no provider-name
table and no hidden GCE, Vultr, AWS or Hetzner default. A new adapter states
what its disk backend accepts and the gate proves the materialized image
matches it.

Omit `imageMaterializer` for an already-raw disk. For qcow2, VHD, VMDK or a
provider-specific envelope, the adapter supplies the required package in
`runtimeInputs` and a script that reads the read-only `$source_image` and
writes raw bytes to `$target`. The verifier does not gain another format
branch; after materialization, every envelope is subjected to the same disk
checks.

The gate verifies:

| Invariant | Failure caught |
|---|---|
| Declared logical sector interpretation parses | 4096/512 image mismatch |
| GPT partition table | Legacy or corrupt partitioning |
| Exactly one partition for each required GPT label | Missing/ambiguous ESP or root |
| Exact partition type GUID | A generic data partition where firmware/initrd expects an ESP or Linux root |
| Filesystem signature at the partition offset | Correct GPT with the wrong filesystem |
| Every artifact file byte-for-byte inside the FAT ESP, with no undeclared extras | Missing fallback loader, stale/foreign BLS entry, altered kernel/initrd or packing drift |
| Manifest `init=` projected through the declared runtime/image prefixes and found executable inside ext2/3/4 or btrfs | `/@nix/store` accidentally written as `/@nix/nix/store`, or a root image missing its selected system |

The root projection is optional only for artifacts whose root is intentionally
checked by another mechanism. Without it, the verifier reports success only
through the firmware/loader handoff; it does not claim the image can reach
`init`.

`lib.mkEfiDiskImageVerifier` exposes the same check as a command package when a
delivery pipeline needs to run it directly rather than make it a flake check.

## Capability boundary

This first offline artifact backend is deliberately exact:

| Capability | Status |
|---|---|
| UEFI x86_64/aarch64 systemd-boot | Implemented from the target platform's EFI architecture |
| NVRAM-less first boot | Implemented through `EFI/BOOT/BOOT<ARCH>.EFI` |
| Optional steady-state NVRAM entry | Implemented and repaired after boot when `loader.efiVariables = "write"` |
| Type-1 BLS kernel + separate initrd | Implemented and checked |
| BIOS-only firmware | Not represented by this backend; it must get its own artifact format |
| Firmware-enforced Secure Boot | Not represented by this unsigned split artifact; use a future signed-UKI format rather than weakening this claim |

An unsupported capability is therefore a missing backend, not a flag that is
accepted and silently ignored. That is the basis on which another provider
adapter can be added safely.

Recovery remains outside the production disk whenever the provider supplies
an independent ISO, image replacement, or boot-disk attachment mechanism. A
cloud adapter can package the same `nixrescue` content into such an envelope,
but `imageArtifact.role = "nixrescue"` does not imply resident rescue
partitions.
