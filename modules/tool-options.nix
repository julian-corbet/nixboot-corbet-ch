# Tool exposure shared by the NixOS and System Manager backends.  This is intentionally a
# per-tool decision: inspecting the firmware's actual NVRAM state is useful on some physical
# hosts even when Secure Boot is not yet enabled, and is meaningless on containers.
{ lib, ... }:
{
  options.nixboot.tools.efitools.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Is `efi-readvar` on PATH, to back up the current PK/KEK/db/dbx before a
      vendor BIOS flash? `efitools` reads the firmware's current NVRAM variables
      independently of whichever tool enrolled them, making it useful alongside
      `sbctl` on a physical UEFI host.

      Take a capture before the flash, re-read it afterwards, and compare:

        efi-readvar -v PK  -o pk.esl
        efi-readvar -v KEK -o kek.esl
        efi-readvar -v db  -o db.esl
        efi-readvar -v dbx -o dbx.esl

      This is deliberately not derived from `secureBoot.enable`: it is an
      inspection-and-backup tool, not a signing mechanism.
    '';
  };

  options.nixboot.tools.hwdetect.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Is `hwdetect` on PATH, to answer "which kernel modules does this hardware actually need?"

      THE DIAGNOSTIC COUNTERPART TO A DECLARED INITRAMFS. On a host whose kernels and initramfs
      are pinned rather than discovered, that pin has to be right about exactly one thing: the
      module set. `hwdetect` enumerates what the running (or an offline) system's `/sys` actually
      exposes, per subsystem — `--show-modules`, `--show-block`, `--show-drm`, `--show-crypto`,
      `--show-cpufreq`, `--show-acpi`, and a dozen more — plus `--kernel_version=` and
      `--root_directory=` for inspecting a system OTHER than the one you are booted into, which
      is precisely the rescue case. So it is the tool that tells you whether a declaration is
      complete, which makes it boot's business rather than a general hardware-inventory tool's.

      READ-ONLY USE ONLY, AND THE DISTINCTION MATTERS ENOUGH TO STATE. Its own description
      advertises "loading modules and mkinitcpio.conf", and it can indeed emit an array formatted
      for `mkinitcpio.conf`. On a host where that file is DECLARED, letting it write is precisely
      the wrong thing: it would overwrite a hand-tuned config with an autodetected one and the
      declaration would silently no longer describe the box. This option exists for the
      `--show-*` output. Nothing here invokes the tool, and nothing here writes `mkinitcpio.conf`
      — enabling it puts a lister on PATH, which is the whole of it.

      Arch-family only: the tool is packaged by Arch and its derivatives and has no nixpkgs
      counterpart, so only the system-manager backend selects it. That is a property of the
      package, not a policy of this option — same shape as any other name a distro carries and
      nixpkgs does not.
    '';
  };
}
