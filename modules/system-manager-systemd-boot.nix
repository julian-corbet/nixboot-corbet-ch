# nixboot's system-manager backend for Arch-family hosts.
#
# This is intentionally a clean systemd-boot + UKI backend. A system-manager host has no
# NixOS `boot.*` surface and continues to use its native pacman kernel/mkinitcpio toolchain;
# NixBoot therefore renders the native contract and builds UKIs with `mkinitcpio --uki` rather
# than pretending to own a NixOS kernel closure.
#
# The migration is two-step on purpose. Enabling this module only declares the native packages.
# `stage.enable` renders manual stage/verify units, but does not start them. The stage writes a
# separate EFI/systemd loader and UKIs under a unique prefix; it deliberately leaves the current
# firmware entry and EFI/BOOT fallback untouched. A physical, one-time boot through the staged
# loader proves the chain before a later, separately reviewed firmware cutover or Secure Boot
# enrollment. This preserves a known-good boot path while making every desired file/versioned
# command declarative and reviewable.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixboot.systemdBoot;

  kernelType = lib.types.submodule ({ ... }: {
    options = {
      package = lib.mkOption {
        type = lib.types.str;
        description = "Native pacman kernel package to declare.";
      };
      packageBase = lib.mkOption {
        type = lib.types.str;
        description = "Expected content of /usr/lib/modules/<release>/pkgbase for this kernel.";
      };
      headersPackage = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Native headers package needed by this kernel's external modules, if any.";
      };
      id = lib.mkOption {
        type = lib.types.strMatching "[a-z0-9-]+";
        description = "Stable NixBoot UKI file suffix, distinct from the mutable kernel release.";
      };
      fallback = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Also build a fallback UKI without mkinitcpio's autodetect hook.";
      };
    };
  });

  kernelPackages = lib.concatMap (kernel:
    [ kernel.package ] ++ lib.optional (kernel.headersPackage != null) kernel.headersPackage
  ) cfg.kernels;

  nativePackages = lib.unique (
    [ "mkinitcpio" "systemd-ukify" "sbctl" "efibootmgr" cfg.firmwarePackage ]
    ++ kernelPackages
  );

  cmdlineFile = pkgs.writeText "nixboot-kernel-cmdline" "${cfg.kernelCmdline}\n";
  loaderConfFile = pkgs.writeText "nixboot-loader.conf" ''
    default ${cfg.loader.default}
    timeout ${toString cfg.loader.timeout}
    editor ${if cfg.loader.editor then "yes" else "no"}
  '';

  # Pacman owns the native kernel packages on a system-manager host, so it is the event source
  # for UKI regeneration. The hook is deliberately absent until the explicit stage gate is on:
  # before a local staged-loader test, no package upgrade may create a second boot path.
  pacmanHookFile = pkgs.writeText "95-nixboot-systemd-boot.hook" ''
    [Trigger]
    Operation = Install
    Operation = Upgrade
    Type = Path
    Target = usr/lib/modules/*/pkgbase

    [Trigger]
    Operation = Install
    Operation = Upgrade
    Type = Path
    Target = usr/lib/systemd/boot/efi/systemd-bootx64.efi

    [Action]
    Description = NixBoot: rebuild declared UKIs after native boot artifact update
    When = PostTransaction
    Depends = systemd
    Depends = mkinitcpio
    Exec = /usr/bin/systemctl start nixboot-systemd-boot-stage.service
  '';

  kernelCalls = lib.concatMapStrings (kernel: ''
    build_uki ${lib.escapeShellArg kernel.packageBase} ${lib.escapeShellArg kernel.id} ${if kernel.fallback then "yes" else "no"}
  '') cfg.kernels;

  stageScript = ''
    set -euo pipefail

    esp=${lib.escapeShellArg cfg.esp.mountPoint}
    prefix=${lib.escapeShellArg cfg.uki.prefix}
    secure_boot=${if cfg.secureBoot.enable then "yes" else "no"}

    for command in /usr/bin/findmnt /usr/bin/mkinitcpio /usr/bin/install /usr/bin/mktemp /usr/bin/sbctl; do
      [ -x "$command" ] || {
        echo "nixboot: required native command is absent: $command" >&2
        echo "nixboot: activate the declared native package set before staging." >&2
        exit 1
      }
    done

    [ -d "$esp" ] || { echo "nixboot: ESP mount point does not exist: $esp" >&2; exit 1; }
    [ "$(/usr/bin/findmnt -no FSTYPE --target "$esp")" = "vfat" ] || {
      echo "nixboot: $esp is not the mounted FAT ESP; refusing to write boot artifacts." >&2
      exit 1
    }
    /usr/bin/install -d -m0755 "$esp/EFI/Linux"

    # This intentionally does not write EFI/BOOT/BOOTX64.EFI and does not touch NVRAM. The
    # current loader remains the recovery path until an operator verifies this staged one locally.
    /usr/bin/install -Dm0644 /usr/lib/systemd/boot/efi/systemd-bootx64.efi \
      "$esp/EFI/systemd/systemd-bootx64.efi"
    /usr/bin/install -Dm0644 ${cmdlineFile} /etc/kernel/cmdline
    /usr/bin/install -Dm0644 ${loaderConfFile} "$esp/loader/loader.conf"

    build_uki() {
      local package_base="$1" id="$2" fallback="$3"
      local module_dir pkgbase release output temporary
      local -a matches=()

      for module_dir in /usr/lib/modules/*; do
        [ -f "$module_dir/pkgbase" ] || continue
        pkgbase="$(<"$module_dir/pkgbase")"
        [ "$pkgbase" = "$package_base" ] && matches+=("$module_dir")
      done

      if [ "''${#matches[@]}" -ne 1 ]; then
        echo "nixboot: expected exactly one installed kernel for pkgbase $package_base; found ''${#matches[@]}." >&2
        exit 1
      fi

      release="$(basename "''${matches[0]}")"
      output="$esp/EFI/Linux/$prefix-$id.efi"
      temporary="$(/usr/bin/mktemp "$esp/EFI/Linux/.$prefix-$id.XXXXXX")"
      trap 'rm -f "$temporary"' RETURN

      /usr/bin/mkinitcpio --kernel "$release" --uki "$temporary" --cmdline /etc/kernel/cmdline
      /usr/bin/install -m0644 "$temporary" "$output"
      rm -f "$temporary"

      if [ "$secure_boot" = yes ]; then
        /usr/bin/sbctl sign -s "$output"
      fi

      if [ "$fallback" = yes ]; then
        output="$esp/EFI/Linux/$prefix-$id-fallback.efi"
        temporary="$(/usr/bin/mktemp "$esp/EFI/Linux/.$prefix-$id-fallback.XXXXXX")"
        /usr/bin/mkinitcpio --kernel "$release" --uki "$temporary" --cmdline /etc/kernel/cmdline -S autodetect
        /usr/bin/install -m0644 "$temporary" "$output"
        [ "$secure_boot" != yes ] || /usr/bin/sbctl sign -s "$output"
      fi

      trap - RETURN
      rm -f "$temporary"
    }

    ${kernelCalls}

    echo "nixboot: staged systemd-boot at $esp/EFI/systemd/systemd-bootx64.efi"
    echo "nixboot: current firmware entry and EFI/BOOT fallback were intentionally not changed."
  '';

  verifyScript = ''
    set -euo pipefail

    esp=${lib.escapeShellArg cfg.esp.mountPoint}
    prefix=${lib.escapeShellArg cfg.uki.prefix}
    fail=0

    check_efi() {
      local file="$1"
      if [ -s "$file" ] && [ "$(head -c2 "$file")" = "MZ" ]; then
        echo "PASS  nixboot: $file is a non-empty EFI image"
      else
        echo "FAIL  nixboot: $file is missing or not an EFI image" >&2
        fail=1
      fi
    }

    check_efi "$esp/EFI/systemd/systemd-bootx64.efi"
    [ -s "$esp/loader/loader.conf" ] || { echo "FAIL  nixboot: loader.conf is missing" >&2; fail=1; }
    ${lib.concatMapStrings (kernel: ''
      check_efi "$esp/EFI/Linux/$prefix-${kernel.id}.efi"
      ${lib.optionalString kernel.fallback ''check_efi "$esp/EFI/Linux/$prefix-${kernel.id}-fallback.efi"''}
    '') cfg.kernels}

    if [ "$fail" -ne 0 ]; then
      echo "nixboot: staged systemd-boot verification failed; retain the current boot path." >&2
      exit 1
    fi
    echo "nixboot: staged loader and UKIs verified. Select EFI/systemd/systemd-bootx64.efi once from firmware before any cutover."
  '';
in
{
  options.nixboot.systemdBoot = {
    enable = lib.mkEnableOption "NixBoot's staged native systemd-boot and UKI backend";

    esp.mountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/boot";
      description = "Mounted FAT ESP. This module never partitions, formats, or mounts it.";
    };

    firmwarePackage = lib.mkOption {
      type = lib.types.str;
      default = "linux-firmware";
      description = "Native firmware package kept with the boot-capable kernel set.";
    };

    kernels = lib.mkOption {
      type = lib.types.listOf kernelType;
      default = [ ];
      description = "The native kernels NixBoot stages as UKIs and declares through the Arch backend.";
    };

    kernelCmdline = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Exact kernel command line embedded in every staged UKI.";
    };

    uki.prefix = lib.mkOption {
      type = lib.types.strMatching "[a-z0-9-]+";
      default = "nixboot";
      description = "Unique filename prefix below EFI/Linux; only files with this prefix are NixBoot-owned.";
    };

    loader = {
      default = lib.mkOption { type = lib.types.str; default = "@saved"; };
      timeout = lib.mkOption { type = lib.types.ints.unsigned; default = 3; };
      editor = lib.mkOption { type = lib.types.bool; default = false; };
    };

    secureBoot.enable = lib.mkEnableOption "sign staged NixBoot UKIs with the locally provisioned sbctl key";

    stage.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Render manual `nixboot-systemd-boot-stage` and `nixboot-systemd-boot-verify` units.
        They are never wanted automatically: first activate the declaration, then stage and verify
        while physically present before changing firmware boot order or Secure Boot enrollment.
      '';
    };

    archPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = "Native packages selected by this backend for a host-provided Arch reconciler.";
    };
  };

  config = lib.mkMerge [
    {
      nixboot.systemdBoot.archPackages = if cfg.enable then nativePackages else [ ];
    }
    (lib.mkIf cfg.enable {
      assertions = [
      {
        assertion = !cfg.stage.enable || cfg.kernelCmdline != null;
        message = "nixboot.systemdBoot.stage.enable requires an explicit kernelCmdline; never inherit a potentially temporary /proc/cmdline.";
      }
      {
        assertion = !cfg.stage.enable || cfg.kernels != [ ];
        message = "nixboot.systemdBoot.stage.enable requires at least one declared native kernel.";
      }
      {
        assertion = lib.length (lib.unique (map (kernel: kernel.id) cfg.kernels)) == lib.length cfg.kernels;
        message = "nixboot.systemdBoot.kernels must use unique UKI ids.";
      }
      ];

      systemd.services = lib.mkIf cfg.stage.enable {
      nixboot-systemd-boot-stage = {
        description = "NixBoot: stage systemd-boot and native UKIs without cutover";
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = stageScript;
      };
      nixboot-systemd-boot-verify = {
        description = "NixBoot: verify staged systemd-boot and native UKIs";
        after = [ "nixboot-systemd-boot-stage.service" ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = verifyScript;
      };
      };

      # /etc/pacman.d/hooks has higher precedence than package-provided hooks. `replaceExisting`
      # avoids system-manager's silent existing-file skip, which would otherwise leave a stale
      # lifecycle contract after a manual experiment or an older NixBoot revision.
      environment.etc = lib.mkIf cfg.stage.enable {
        "pacman.d/hooks/95-nixboot-systemd-boot.hook" = {
          source = pacmanHookFile;
          replaceExisting = true;
        };
      };
    })
  ];
}
