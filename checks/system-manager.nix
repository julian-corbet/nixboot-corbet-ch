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
      nixcpu.packages.bootMicrocode = {
        archPackage = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
        vendor = lib.mkOption { type = lib.types.nullOr (lib.types.enum [ "amd" "intel" ]); default = null; };
      };
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
    nixcpu.packages.bootMicrocode = {
      archPackage = "intel-ucode";
      vendor = "intel";
    };

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
  firmwareTools = evalBoot (lib.recursiveUpdate base {
    nixboot.firmware = {
      fwupd.enable = true;
      dmidecode.enable = true;
    };
  });
  efitools = evalBoot (lib.recursiveUpdate base {
    nixboot.tools.efitools.enable = true;
  });
  hwdetect = evalBoot (lib.recursiveUpdate base {
    nixboot.tools.hwdetect.enable = true;
  });
  plymouth = evalBoot (lib.recursiveUpdate base {
    nixboot.systemdBoot.plymouth.enable = true;
  });
  missingMicrocode = assertionFails (lib.recursiveUpdate base {
    nixcpu.packages.bootMicrocode = {
      archPackage = null;
      vendor = null;
    };
  });
  bootedKernelOff = evalBoot (lib.recursiveUpdate base {
    nixboot.systemdBoot.bootedKernel.verify.enable = false;
  });
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
  bootedKernelUnit = "nixboot-booted-kernel-verify";
  bootedKernelHook = "pacman.d/hooks/96-nixboot-booted-kernel.hook";
  collectUnit = "nixboot-systemd-boot-collect";

  # Everything the stage script does BEFORE it reaches the capacity gate. Used to assert ordering
  # rather than mere presence -- the deadlock this fixes was a correctly-implemented collector
  # placed after the step it needed to unblock.
  stageBeforeCapacityGate =
    lib.head (lib.splitString "insufficient ESP capacity" staged.systemd.services.${stage}.script);

  results = [
    (check "disabled/no-units-or-native-package-selection"
      (disabled.systemd.services == { } && disabled.nixboot.systemdBoot.archPackages == [ ])
      "units: ${builtins.toJSON (builtins.attrNames disabled.systemd.services)}")

    (check "declared/native-package-selection-is-complete"
      (lib.all (package: lib.elem package declared.nixboot.systemdBoot.archPackages) [
        "mkinitcpio"
        "systemd-ukify"
        "sbctl"
        "efibootmgr"
        "linux-firmware"
        "linux-cachyos"
        "linux-cachyos-headers"
        "linux-cachyos-lts"
        "linux-cachyos-lts-headers"
      ])
      "packages: ${builtins.toJSON declared.nixboot.systemdBoot.archPackages}")

    # NixCPU owns microcode (CPU-keyed fact, vendor detection lives there); NixBoot cannot know
    # the CPU vendor and must not re-declare the vendor package into its own archPackages, even
    # though it reads nixcpu.packages.bootMicrocode.archPackage for the presence assertion below.
    # This regression-tests the ownership boundary itself, not just that the base list is complete.
    (check "declared/nixboot-does-not-re-declare-nixcpus-microcode-package"
      (!(lib.elem "intel-ucode" declared.nixboot.systemdBoot.archPackages))
      "packages: ${builtins.toJSON declared.nixboot.systemdBoot.archPackages}")

    (check "firmware-tools/selects-fwupd-and-dmidecode"
      (
        lib.elem "fwupd" firmwareTools.nixboot.systemdBoot.archPackages
        && lib.elem "dmidecode" firmwareTools.nixboot.systemdBoot.archPackages
        && firmwareTools.nixboot.firmware.packageNames == [ "fwupd" "dmidecode" ]
      )
      "packages: ${builtins.toJSON firmwareTools.nixboot.systemdBoot.archPackages}")

    (check "tools/efitools-selects-efitools-for-system-manager"
      (lib.elem "efitools" efitools.nixboot.systemdBoot.archPackages)
      "packages: ${builtins.toJSON efitools.nixboot.systemdBoot.archPackages}")

    (check "tools/hwdetect-selects-hwdetect-for-system-manager"
      (lib.elem "hwdetect" hwdetect.nixboot.systemdBoot.archPackages)
      "packages: ${builtins.toJSON hwdetect.nixboot.systemdBoot.archPackages}")

    # Its own decision, like efitools: a declared kernel set does not imply wanting the lister
    # that audits it, and a tool that can also WRITE mkinitcpio.conf is not something to acquire
    # by side effect of enabling the backend.
    (check "tools/hwdetect-is-not-installed-by-the-backend-alone"
      (!(lib.elem "hwdetect" declared.nixboot.systemdBoot.archPackages))
      "packages: ${builtins.toJSON declared.nixboot.systemdBoot.archPackages}")

    (check "plymouth/selects-plymouth-for-system-manager"
      (lib.elem "plymouth" plymouth.nixboot.systemdBoot.archPackages)
      "packages: ${builtins.toJSON plymouth.nixboot.systemdBoot.archPackages}")

    # Harder than efitools' and hwdetect's version of this test, because the package is not inert:
    # its own `.wants` symlinks put plymouth-start.service into sysinit.target and the quit units
    # into multi-user.target on arrival. A boot chain that acquired that by declaring kernels
    # would be changing the stage-2 unit graph of every host on this backend.
    (check "plymouth/is-not-installed-by-the-backend-alone"
      (!(lib.elem "plymouth" declared.nixboot.systemdBoot.archPackages))
      "packages: ${builtins.toJSON declared.nixboot.systemdBoot.archPackages}")

    # The option's doc promises it never touches the command line, and the promise is load-bearing:
    # a later revision that "helpfully" appended `splash` would silently change what every staged
    # UKI boots with, on a surface whose whole contract is that it is rendered verbatim.
    (check "plymouth/never-composes-the-kernel-command-line"
      (plymouth.nixboot.systemdBoot.kernelCmdline == declared.nixboot.systemdBoot.kernelCmdline)
      "cmdline: ${builtins.toJSON plymouth.nixboot.systemdBoot.kernelCmdline}")

    (check "declared/microcode-must-come-from-nixcpu"
      missingMicrocode
      "an enabled NixBoot backend without nixcpu.packages.bootMicrocode.archPackage must fail")

    (check "declared/no-stage-units-before-explicit-gate"
      (
        !(declared.systemd.services ? "${stage}")
        && !(declared.systemd.services ? "${verify}")
        && !(declared.environment.etc ? "${pacmanHook}")
      )
      "units: ${builtins.toJSON (builtins.attrNames declared.systemd.services)}")

    # B25 --------------------------------------------------------------------
    (check "booted-kernel/guard-needs-no-stage-gate"
      (
        declared.systemd.services ? "${bootedKernelUnit}"
        && declared.environment.etc ? "${bootedKernelHook}"
        && declared.environment.etc.${bootedKernelHook}.replaceExisting
      )
      "the booted-kernel guard must exist as soon as the backend is enabled: it only reads, so unlike stage/cutover/retireLimine it has no reason to wait for a manual gate")

    (check "booted-kernel/runs-at-boot-and-after-every-kernel-transaction"
      (
        declared.systemd.services.${bootedKernelUnit}.wantedBy == [ "multi-user.target" ]
        && lib.hasInfix "Target = usr/lib/modules/*/pkgbase" declared.nixboot.systemdBoot.bootedKernel.hookText
        && lib.hasInfix "Operation = Remove" declared.nixboot.systemdBoot.bootedKernel.hookText
        && lib.hasInfix "When = PostTransaction" declared.nixboot.systemdBoot.bootedKernel.hookText
        # `restart`, never `start`: this is a RemainAfterExit oneshot, and `start` on one that has
        # already succeeded is a no-op -- it would leave the previous verdict standing after the
        # exact transaction that invalidated it, which is the whole failure this guard exists for.
        && lib.hasInfix "systemctl restart nixboot-booted-kernel-verify.service" declared.nixboot.systemdBoot.bootedKernel.hookText
        && !(lib.hasInfix "systemctl start nixboot-booted-kernel-verify.service" declared.nixboot.systemdBoot.bootedKernel.hookText)
      )
      "hook: ${builtins.toJSON declared.nixboot.systemdBoot.bootedKernel.hookText}")

    (check "booted-kernel/detects-tree-absence-and-release-drift"
      (
        lib.hasInfix "/usr/lib/modules/$running" declared.systemd.services.${bootedKernelUnit}.script
        && lib.hasInfix "uname -r" declared.systemd.services.${bootedKernelUnit}.script
        # The second half must survive a module-preserving native hook: the tree is still there,
        # but the package that owns it has moved on and this host runs the older release.
        && lib.hasInfix "pkgbase" declared.systemd.services.${bootedKernelUnit}.script
        && lib.hasInfix "/run/nixboot/booted-kernel" declared.systemd.services.${bootedKernelUnit}.script
      )
      "the guard lost one of its two conditions, or the readable status file it must leave behind")

    (check "booted-kernel/reports-and-never-remediates"
      (
        # Prose may say "reboot"; this script must never CALL anything that acts. No systemctl, no
        # pacman, no depmod/modprobe, no restoring a module tree -- nixnet's OWN-2 line, applied
        # here: a layer that acts on its own judgement destroys the evidence underneath it.
        !(lib.hasInfix "systemctl" declared.systemd.services.${bootedKernelUnit}.script)
        && !(lib.hasInfix "pacman" declared.systemd.services.${bootedKernelUnit}.script)
        && !(lib.hasInfix "depmod" declared.systemd.services.${bootedKernelUnit}.script)
        && !(lib.hasInfix "modprobe" declared.systemd.services.${bootedKernelUnit}.script)
      )
      "the booted-kernel guard gained a remediation verb; it reports and stops there")

    (check "booted-kernel/opt-out-removes-both-unit-and-hook"
      (
        !(bootedKernelOff.systemd.services ? "${bootedKernelUnit}")
        && !(bootedKernelOff.environment.etc ? "${bootedKernelHook}")
      )
      "units: ${builtins.toJSON (builtins.attrNames bootedKernelOff.systemd.services)}")

    (check "stage/manual-stage-and-verify-units-exist"
      (staged.systemd.services ? "${stage}" && staged.systemd.services ? "${verify}")
      "units: ${builtins.toJSON (builtins.attrNames staged.systemd.services)}")

    # Absence of WantedBy= is not enough with system-manager: its switch script starts any changed
    # service unless X-RestartIfChanged=false is rendered. Every manual unit must opt out explicitly,
    # especially cutover, which writes the fallback loader and firmware variables.
    (check "manual-units/do-not-run-during-system-manager-switch"
      (
        lib.all
          (unit: staged.systemd.services.${unit}.restartIfChanged == false)
          [ stage verify collectUnit ]
        && cutover.systemd.services.${cutoverUnit}.restartIfChanged == false
        && retirement.systemd.services.${retireLimineUnit}.restartIfChanged == false
      )
      "every manual stage, verify, collect, cutover, and retirement unit must set restartIfChanged=false")

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
        && lib.hasInfix "collect_stale_ukis" staged.systemd.services.${stage}.script
        && lib.hasInfix "stale NixBoot UKI artifact(s)" staged.systemd.services.${stage}.script
        && lib.hasInfix "\"$linux_dir/$prefix-\"*.efi" staged.systemd.services.${stage}.script
      )
      "stage script does not render the native mkinitcpio UKI, ESP-capacity, and stale-artifact collection contract")

    # The ordering defect this replaced: collection ran only AFTER a successful staging, so a full
    # ESP could not be staged into and the garbage that would free it could not be collected. The
    # assertion is positional on purpose -- "the script mentions collection somewhere" was already
    # true of the broken version.
    # Matches the bare CALL statement, not `collect_stale_ukis() {`. The function definition is
    # necessarily in this prefix too, so a substring test on the name alone passes even with the
    # call deleted -- verified by deleting it and watching the weaker assertion stay green.
    (check "stage/collects-before-the-capacity-gate-not-after-the-install"
      (lib.hasInfix "\ncollect_stale_ukis\n" stageBeforeCapacityGate)
      "collection must run before the ESP capacity check, otherwise a full ESP deadlocks: staging needs the space that only collection frees")

    (check "collect/runs-independently-of-staging"
      (
        staged.systemd.services ? "${collectUnit}"
        && !(staged.systemd.services.${collectUnit} ? "after")
        && !(staged.systemd.services.${collectUnit} ? "wantedBy")
        # Nothing a staging run produces may be required to collect.
        && !(lib.hasInfix "mkinitcpio" staged.systemd.services.${collectUnit}.script)
        && !(lib.hasInfix "staging_dir" staged.systemd.services.${collectUnit}.script)
      )
      "the collect unit must not depend on staging, its build, or its staging directory")

    (check "collect/never-reclaims-the-booted-entry"
      (
        lib.hasInfix "Current Entry:" staged.systemd.services.${collectUnit}.script
        && lib.hasInfix "firmware reports it as the entry this host booted" staged.systemd.services.${collectUnit}.script
        # Ownership boundary is unchanged: only the declared prefix is ever a candidate.
        && lib.hasInfix "$prefix-" staged.systemd.services.${collectUnit}.script
      )
      "collection lost the booted-entry exclusion or its prefix ownership boundary")

    # The declared set is NOT a fallback for the booted-entry check. A booted entry that is no
    # longer declared is exactly the case the exclusion exists for, so if firmware cannot be asked,
    # collection must delete nothing at all -- an earlier revision let that case fall through to
    # `rm`, which is the very bug this whole change exists to prevent.
    (check "collect/refuses-entirely-when-the-booted-entry-cannot-be-named"
      (lib.all (marker: lib.hasInfix marker staged.systemd.services.${collectUnit}.script) [
        "/usr/bin/bootctl is absent"
        "reports a different partition UUID"
        "did not report a Current Entry"
        "refusing to collect anything"
        "collect_skipped=yes"
      ])
      "collection must refuse outright when bootctl is absent, reports a different ESP, or names no Current Entry")

    (check "collect/refusal-is-a-failed-unit-not-a-quiet-success"
      (
        lib.hasInfix "[ \"$collect_skipped\" = no ]" staged.systemd.services.${collectUnit}.script
        # bootctl is a hard preflight requirement for the unit whose whole job is deletion.
        && lib.hasInfix "/usr/bin/bootctl" (lib.head (lib.splitString "collect_stale_ukis()" staged.systemd.services.${collectUnit}.script))
        # Staging must NOT inherit that hard failure: collection is an aid to it, never a gate on it.
        && !(lib.hasInfix "[ \"$collect_skipped\" = no ]" staged.systemd.services.${stage}.script)
      )
      "a refused collection must fail the collect unit, and must not block staging")

    (check "stage/capacity-failure-names-the-shortfall-in-declared-units"
      (
        lib.hasInfix "insufficient ESP capacity" staged.systemd.services.${stage}.script
        && lib.hasInfix "MiB, have" staged.systemd.services.${stage}.script
        && lib.hasInfix "no ESP files were changed" staged.systemd.services.${stage}.script
      )
      "a capacity failure must state need and have in MiB -- the unit every ESP budget in this family is declared in")

    # Every command these scripts run must be absolute or preflight-checked. A bare name resolves
    # against the unit's PATH, which on a system-manager host holds no native tools at all, and the
    # result is a bare 127 instead of this backend's named "required native command is absent".
    (check "scripts/no-bare-native-command-invocations"
      (lib.all
        (script:
          !(lib.hasInfix "$(head " script)
          && !(lib.hasInfix "| sed " script)
          && !(lib.hasInfix "$(dirname " script)
        )
        (map (unit: unit.script) (lib.attrValues retirement.systemd.services)))
      "a script invokes head/sed/dirname by bare name; use /usr/bin/<tool> and add it to that script's preflight loop")

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
      (assertionFails (lib.recursiveUpdate base {
        nixboot.systemdBoot = {
          secureBoot.enable = true;
        };
      }))
      "expected secureBoot.enable without secureBoot.sbctlConfig to fail an assertion")

    (check "secure-cutover-signs-the-final-fallback-loader"
      (lib.hasInfix "sign -s \"$fallback_output\"" cutover.systemd.services.${cutoverUnit}.script)
      "secure final cutover does not sign the active fallback loader")

    (check "cutover-without-stage-asserts"
      (assertionFails (lib.recursiveUpdate base {
        nixboot.systemdBoot = {
          cutover.enable = true;
        };
      }))
      "expected cutover.enable without stage.enable to fail an assertion")

    (check "retire-limine-without-cutover-or-artifact-guards-asserts"
      (assertionFails (lib.recursiveUpdate base {
        nixboot.systemdBoot = {
          stage.enable = true;
          retireLimine.enable = true;
        };
      }))
      "expected Limine retirement without cutover and explicit artifact protection to fail assertions")

    (check "stage-without-explicit-kernel-cmdline-asserts"
      (assertionFails (lib.recursiveUpdate base {
        nixboot.systemdBoot = {
          stage.enable = true;
          kernelCmdline = null;
        };
      }))
      "expected a stage configuration without kernelCmdline to fail an assertion")

    (check "stage-without-kernels-asserts"
      (assertionFails (lib.recursiveUpdate base {
        nixboot.systemdBoot = {
          stage.enable = true;
          kernels = [ ];
        };
      }))
      "expected a stage configuration without kernels to fail an assertion")

    (check "duplicate-uki-id-asserts-even-before-stage"
      (assertionFails (lib.recursiveUpdate base {
        nixboot.systemdBoot = {
          kernels = [
            { package = "linux"; packageBase = "linux"; id = "same"; }
            { package = "linux-lts"; packageBase = "linux-lts"; id = "same"; }
          ];
        };
      }))
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
