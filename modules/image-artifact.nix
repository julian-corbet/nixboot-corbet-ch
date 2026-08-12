{ config, lib, pkgs, ... }:
let
  cfg = config.nixboot.imageArtifact;
  boot = config.nixboot;
  artifact = import ../lib/mk-systemd-boot-artifact.nix {
    inherit pkgs;
    name = cfg.name;
    inherit (cfg) role title version entryId sortKey;
    inherit (cfg) deviceClass;
    steadyStateHandoff = boot.loader.efiVariables;
    toplevel = config.system.build.toplevel;
    kernel = "${config.system.build.kernel}/${config.system.boot.loader.kernelFile}";
    initrd = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
    kernelParams = config.boot.kernelParams;
    timeout = boot.loader.timeout;
    editor = boot.loader.editor;
    consoleMode = boot.loader.consoleMode;
  };
in
{
  options.nixboot.imageArtifact = {
    enable = lib.mkEnableOption "a checked offline UEFI/systemd-boot artifact for a cloud or VM disk image";

    deviceClass = lib.mkOption {
      type = lib.types.enum [ "nixarch" "nixnas" "nixvps" ];
      description = ''
        Generic device class whose boot projection this artifact carries.
        This is never a provider or machine name. It remains independent of
        role, architecture, firmware handoff, and disk geometry.
      '';
    };

    name = lib.mkOption {
      type = lib.types.strMatching "^[A-Za-z0-9][A-Za-z0-9._-]*$";
      default = "${cfg.deviceClass}-${cfg.role}";
      defaultText = lib.literalExpression ''"''${deviceClass}-''${role}"'';
      description = "Stable public artifact name. The generic default deliberately contains neither a provider nor a machine identity.";
    };

    role = lib.mkOption {
      type = lib.types.enum [ "primary" "nixrescue" ];
      default = "primary";
      description = "The boot role of this artifact. Device class and provider remain independent inputs.";
    };

    title = lib.mkOption {
      type = lib.types.str;
      default = config.system.nixos.distroName;
      defaultText = lib.literalExpression "config.system.nixos.distroName";
      description = "Human-readable systemd-boot entry title.";
    };

    version = lib.mkOption {
      type = lib.types.str;
      default = "Generation 1 ${config.system.nixos.distroName} ${config.system.nixos.label} (Linux ${config.boot.kernelPackages.kernel.version})";
      defaultText = lib.literalExpression ''"Generation 1 ..." from the evaluated NixOS system'';
      description = "Human-readable version shown by systemd-boot for this freshly baked generation.";
    };

    entryId = lib.mkOption {
      type = lib.types.strMatching "^[A-Za-z0-9][A-Za-z0-9._-]*$";
      default = "${if cfg.role == "primary" then "nixos" else "nixrescue"}-generation-1";
      description = "Type-1 BLS entry basename. The artifact owns exactly this entry; later generation delivery belongs to nixdeploy.";
    };

    sortKey = lib.mkOption {
      type = lib.types.strMatching "^[A-Za-z0-9][A-Za-z0-9._-]*$";
      default = if cfg.role == "primary" then "nixos" else "nixrescue";
      description = "systemd-boot sort key for the initial entry.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = boot.enable;
        message = "nixboot.imageArtifact.enable requires nixboot.enable: an offline artifact without the matching live boot stance would have two unrelated declarations.";
      }
      {
        assertion = boot.loader.program == "systemd-boot";
        message = "nixboot.imageArtifact currently produces a systemd-boot Type-1/BLS artifact, so nixboot.loader.program must be systemd-boot. A signed UKI backend must be a separate honest artifact format, not this unsigned split kernel/initrd path under another name.";
      }
      {
        assertion = boot.loader.selfHeal;
        message = "nixboot.imageArtifact requires nixboot.loader.selfHeal: an offline-baked ESP has never run bootctl install, and leaving that state unreconciled makes the first switch-to-configuration fail on some cloud firmware.";
      }
    ];

    # This artifact is created offline and therefore necessarily needs the
    # already-existing bootctl reconciliation on its first real boot. A plain
    # host assignment may still override this default, but the assertion above
    # then refuses the unsafe combination rather than silently shipping it.
    nixboot.loader.selfHeal = lib.mkDefault true;

    system.build.nixbootBootArtifact = artifact.tree;
    system.build.nixbootBootArtifactManifest = artifact.manifest;
  };
}
