# Eval-time checks for the system-manager systemd-boot/UKI backend. A small option-surface stub
# is enough here: these tests prove generated declarations and guards without pretending a real
# Arch ESP or firmware can be exercised in a Nix evaluation.
{ pkgs }:
let
  lib = pkgs.lib;

  systemManagerSurfaceStub = { lib, ... }: {
    options = {
      systemd.services = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
      environment.etc = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
      assertions = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
    };
  };

  evalMod = modules: (lib.evalModules {
    modules = [ systemManagerSurfaceStub { _module.args.pkgs = pkgs; } ] ++ modules;
  }).config;

  evalBoot = extra: evalMod [ ../modules/system-manager-systemd-boot.nix extra ];
  assertionFails = extra:
    let cfg = evalBoot extra;
    in lib.any (assertion: !assertion.assertion) cfg.assertions;

  base = {
    nixboot.systemdBoot = {
      enable = true;
      kernels = [
        {
          package = "linux-cachyos";
          packageBase = "linux-cachyos";
          headersPackage = "linux-cachyos-headers";
          id = "cachyos";
        }
        {
          package = "linux-cachyos-lts";
          packageBase = "linux-cachyos-lts";
          headersPackage = "linux-cachyos-lts-headers";
          id = "cachyos-lts";
        }
      ];
      kernelCmdline = "rd.luks.name=example=cryptroot root=/dev/mapper/cryptroot rw";
    };
  };

  disabled = evalBoot { };
  declared = evalBoot base;
  staged = evalBoot (lib.recursiveUpdate base { nixboot.systemdBoot.stage.enable = true; });
  stagedSecure = evalBoot (lib.recursiveUpdate base {
    nixboot.systemdBoot = {
      stage.enable = true;
      secureBoot = {
        enable = true;
        sbctlConfig = "/run/nixboot/secure-boot/sbctl.conf";
      };
    };
  });
  cutover = evalBoot (lib.recursiveUpdate base {
    nixboot.systemdBoot = {
      stage.enable = true;
      cutover.enable = true;
    };
  });
  retirement = evalBoot (lib.recursiveUpdate base {
    nixboot.systemdBoot = {
      stage.enable = true;
      cutover.enable = true;
      retireLimine = {
        enable = true;
        legacyArtifacts = [ "/boot/limine.conf" ];
        protectedPaths = [ "/boot/EFI/Linux/nixrescue.efi" ];
      };
    };
  });

  check = name: ok: detail: { inherit name ok detail; };
  stage = "nixboot-systemd-boot-stage";
  verify = "nixboot-systemd-boot-verify";
  cutoverUnit = "nixboot-systemd-boot-cutover";
  retireLimineUnit = "nixboot-systemd-boot-retire-limine";
  pacmanHook = "pacman.d/hooks/95-nixboot-systemd-boot.hook";

  results = [
    (check "disabled/no-units-or-native-package-selection"
      (disabled.systemd.services == { } && disabled.nixboot.systemdBoot.archPackages == [ ])
      "units: ${builtins.toJSON (builtins.attrNames disabled.systemd.services)}")

    (check "declared/native-package-selection-is-complete"
      (lib.all (package: lib.elem package declared.nixboot.systemdBoot.archPackages) [
        "mkinitcpio" "systemd-ukify" "sbctl" "efibootmgr" "linux-firmware"
        "linux-cachyos" "linux-cachyos-headers" "linux-cachyos-lts" "linux-cachyos-lts-headers"
      ])
      "packages: ${builtins.toJSON declared.nixboot.systemdBoot.archPackages}")

    (check "declared/no-stage-units-before-explicit-gate"
      (
        !(declared.systemd.services ? "${stage}")
        && !(declared.systemd.services ? "${verify}")
        && !(declared.environment.etc ? "${pacmanHook}")
      )
      "units: ${builtins.toJSON (builtins.attrNames declared.systemd.services)}")

    (check "stage/manual-stage-and-verify-units-exist"
      (staged.systemd.services ? "${stage}" && staged.systemd.services ? "${verify}")
      "units: ${builtins.toJSON (builtins.attrNames staged.systemd.services)}")

    (check "cutover/manual-unit-verifies-stage-and-replaces-fallback"
      (
        cutover.systemd.services ? "${cutoverUnit}"
        && !(cutover.systemd.services.${cutoverUnit} ? "wantedBy")
        && lib.hasInfix "restart nixboot-systemd-boot-verify.service" cutover.systemd.services.${cutoverUnit}.script
        && lib.hasInfix "--variables=yes" cutover.systemd.services.${cutoverUnit}.script
        && lib.hasInfix "--efi-boot-option-description" cutover.systemd.services.${cutoverUnit}.script
        && lib.hasInfix "EFI/BOOT/BOOTX64.EFI" cutover.systemd.services.${cutoverUnit}.script
      )
      "final cutover unit is missing a manual verification or firmware/fallback gate")

    (check "retire-limine/manual-unit-runs-only-after-proven-systemd-boot"
      (
        retirement.systemd.services ? "${retireLimineUnit}"
        && !(retirement.systemd.services.${retireLimineUnit} ? "wantedBy")
        && lib.elem "nixboot-systemd-boot-cutover.service" retirement.systemd.services.${retireLimineUnit}.after
        && lib.hasInfix "BootCurrent" retirement.systemd.services.${retireLimineUnit}.script
        && lib.hasInfix "BootOrder" retirement.systemd.services.${retireLimineUnit}.script
        && lib.hasInfix "expected exactly one Limine EFI entry" retirement.systemd.services.${retireLimineUnit}.script
        && lib.hasInfix "pacman -Rns --noconfirm --nosave" retirement.systemd.services.${retireLimineUnit}.script
        && lib.hasInfix "90-mkinitcpio-install.hook" retirement.systemd.services.${retireLimineUnit}.script
        && lib.hasInfix "zz-sbctl.hook" retirement.systemd.services.${retireLimineUnit}.script
        && lib.hasInfix "/usr/bin/cmp" retirement.systemd.services.${retireLimineUnit}.script
        && lib.hasInfix "/usr/bin/ln" retirement.systemd.services.${retireLimineUnit}.script
        && lib.hasInfix "overlaps protected path" retirement.systemd.services.${retireLimineUnit}.script
      )
      "Limine retirement lost its manual current-boot, NVRAM, package, or native-hook guard")

    (check "stage/does-not-auto-start-or-overwrite-fallback"
      (
        !(staged.systemd.services.${stage} ? "wantedBy")
        && lib.hasInfix "does not write EFI/BOOT/BOOTX64.EFI" staged.systemd.services.${stage}.script
        && lib.hasInfix "does not touch NVRAM" staged.systemd.services.${stage}.script
      )
      "stage script lost its explicit no-cutover guard")

    (check "stage/builds-uki-from-native-kernel-pkgbase"
      (
        lib.hasInfix "/usr/lib/modules/*" staged.systemd.services.${stage}.script
        && lib.hasInfix "/usr/bin/mkinitcpio --kernel" staged.systemd.services.${stage}.script
        && lib.hasInfix "--uki" staged.systemd.services.${stage}.script
        && lib.hasInfix "-S autodetect" staged.systemd.services.${stage}.script
        && lib.hasInfix "/var/tmp/nixboot-systemd-boot" staged.systemd.services.${stage}.script
        && lib.hasInfix "no ESP files were changed" staged.systemd.services.${stage}.script
        && lib.hasInfix "required_bytes" staged.systemd.services.${stage}.script
      )
      "stage script does not render the native mkinitcpio UKI and ESP-capacity contract")

    (check "stage/pacman-hook-rebuilds-ukis-after-native-boot-updates"
      (
        staged.environment.etc ? "${pacmanHook}"
        && staged.environment.etc.${pacmanHook}.replaceExisting
        # `source` is the Nix store path, not the hook text. Its basename makes the rendered
        # immutable source observable at eval time; the module's lexical hook text remains the
        # single source used for that path.
        && lib.hasSuffix "-95-nixboot-systemd-boot.hook" (toString staged.environment.etc.${pacmanHook}.source)
      )
      "NixBoot did not declare the pacman lifecycle hook")

    (check "secure-stage/signs-the-staged-loader-and-ukis"
      (
        lib.hasInfix "loader_output=\"$esp/EFI/systemd/systemd-bootx64.efi\"" stagedSecure.systemd.services.${stage}.script
        && lib.hasInfix "/usr/bin/sbctl --config \"$sbctl_config\" sign -s \"$loader_output\"" stagedSecure.systemd.services.${stage}.script
        && lib.hasInfix "/usr/bin/sbctl --config \"$sbctl_config\" sign -s \"$output\"" stagedSecure.systemd.services.${stage}.script
      )
      "secure stage does not sign every staged EFI artifact through the runtime sbctl configuration")

    (check "secure-stage-without-runtime-sbctl-config-asserts"
      (assertionFails {
        nixboot.systemdBoot = {
          enable = true;
          secureBoot.enable = true;
        };
      })
      "expected secureBoot.enable without secureBoot.sbctlConfig to fail an assertion")

    (check "secure-cutover-signs-the-final-fallback-loader"
      (lib.hasInfix "sign -s \"$fallback_output\"" cutover.systemd.services.${cutoverUnit}.script)
      "secure final cutover does not sign the active fallback loader")

    (check "cutover-without-stage-asserts"
      (assertionFails {
        nixboot.systemdBoot = {
          enable = true;
          cutover.enable = true;
        };
      })
      "expected cutover.enable without stage.enable to fail an assertion")

    (check "retire-limine-without-cutover-or-artifact-guards-asserts"
      (assertionFails {
        nixboot.systemdBoot = {
          enable = true;
          stage.enable = true;
          retireLimine.enable = true;
        };
      })
      "expected Limine retirement without cutover and explicit artifact protection to fail assertions")

    (check "stage-without-explicit-kernel-cmdline-asserts"
      (assertionFails {
        nixboot.systemdBoot = {
          enable = true;
          stage.enable = true;
          kernels = [ { package = "linux"; packageBase = "linux"; id = "linux"; } ];
        };
      })
      "expected a stage configuration without kernelCmdline to fail an assertion")

    (check "stage-without-kernels-asserts"
      (assertionFails {
        nixboot.systemdBoot = {
          enable = true;
          stage.enable = true;
          kernelCmdline = "root=/dev/mapper/cryptroot rw";
        };
      })
      "expected a stage configuration without kernels to fail an assertion")

    (check "duplicate-uki-id-asserts-even-before-stage"
      (assertionFails {
        nixboot.systemdBoot = {
          enable = true;
          kernels = [
            { package = "linux"; packageBase = "linux"; id = "same"; }
            { package = "linux-lts"; packageBase = "linux-lts"; id = "same"; }
          ];
        };
      })
      "expected duplicate UKI ids to fail an assertion")
  ];

  failed = builtins.filter (result: !result.ok) results;
  report = lib.concatMapStringsSep "\n" (result: "  - ${result.name}: ${result.detail}") failed;
in
{
  system-manager-eval-tests =
    if failed != [ ] then
      throw "nixboot system-manager eval-tests failed:\n${report}"
    else
      pkgs.runCommand "nixboot-system-manager-eval-tests" { } ''
        echo "all ${toString (builtins.length results)} system-manager eval tests passed" > $out
      '';
}
