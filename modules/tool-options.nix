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
}
