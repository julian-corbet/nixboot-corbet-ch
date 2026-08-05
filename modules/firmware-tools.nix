# Firmware maintenance and local firmware inventory are boot-adjacent tools.  The package names
# are deliberately produced once so the NixOS and system-manager backends select the same tools
# without either backend inventing a second public option surface.
{ config, lib, ... }:
let
  cfg = config.nixboot.firmware;
in
{
  options.nixboot.firmware = {
    fwupd.enable = lib.mkEnableOption "fwupd for UEFI capsule firmware updates";

    dmidecode.enable = lib.mkEnableOption "dmidecode for local SMBIOS firmware inventory";

    packageNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = "Selected native package names for firmware maintenance and SMBIOS inventory.";
    };
  };

  config.nixboot.firmware.packageNames = lib.unique (
    lib.optional cfg.fwupd.enable "fwupd"
    ++ lib.optional cfg.dmidecode.enable "dmidecode"
  );
}
