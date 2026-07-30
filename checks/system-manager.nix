# checks/system-manager.nix
#
# EVAL-TIME checks for modules/system-manager-limine.nix -- the same `lib.evalModules` + stubbed
# option-surface technique nixarch's own checks/default.nix uses for ITS system-manager modules
# (see that file's own header): no real system-manager flake input, since this only needs to
# prove the module's OWN option surface renders correctly, and a real system-manager evaluation
# is exactly the kind of expensive, unnecessary dependency the measured-cost rule this repo's own
# design work was built on argues against pulling in for a check that does not need it.
#
# `assertionFails` below proves nixboot's OWN assertion CONDITION is correct -- that this
# module's contributed `assertions` entries evaluate to `assertion = false` exactly when they
# should. It does NOT prove a real `system-manager switch` actually refuses to apply a bad
# config: that enforcement lives in the real system-manager tool's own build, not in this stub.
# Contrast with the NixOS backend's checks/default.nix, whose `evalFailsBuild` proves the
# STRONGER claim by forcing `system.build.toplevel` -- that works there because nixpkgs' own
# `nixos/lib/eval-config.nix` wires `config.assertions` into a real throw for free; a bare
# `lib.evalModules` stub has no such wiring, and building a second one here would mean
# re-implementing (and maintaining, and risking drift from) system-manager's own assertion-
# enforcement mechanism, sight unseen -- worse than being honest about the boundary.
{ pkgs }:
let
  lib = pkgs.lib;

  renderLimineHeader = import ../lib/render-limine-header.nix { inherit lib; };

  # Stub of the surface only system-manager itself provides: `systemd.services` and
  # `environment.systemPackages` (the same two nixarch's own checks/default.nix stubs), plus
  # `assertions`/`warnings` -- nixarch's own system-manager modules never emit either, so its
  # stub has no need to declare them, but this module does. Shaped exactly like nixpkgs' own
  # `nixos/modules/misc/assertions.nix` so a real system-manager evaluation (which, being
  # NixOS-module-shaped, does carry that module) sees the identical option, not a look-alike.
  systemManagerSurfaceStub = { lib, ... }: {
    options = {
      systemd.services = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
      environment.systemPackages = lib.mkOption { type = lib.types.listOf lib.types.package; default = [ ]; };
      assertions = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
      warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    };
  };

  evalMod = modules: (lib.evalModules {
    modules = [ systemManagerSurfaceStub { _module.args.pkgs = pkgs; } ] ++ modules;
  }).config;

  evalLimine = extraConfig: evalMod [ ../modules/system-manager-limine.nix extraConfig ];

  check = name: ok: detail: { inherit name ok detail; };

  assertionFails = extraConfig:
    let cfg = evalLimine extraConfig;
    in lib.any (a: !a.assertion) cfg.assertions;

  minimalConfigText = "/Test\n  comment: test\n  protocol: linux\n  kernel_path: boot():/vmlinuz\n";

  minimalEnable = {
    nixboot.limine = {
      enable = true;
      efiVariables = "removable";
      configText = minimalConfigText;
    };
  };

  cfgDefault = evalLimine minimalEnable;

  cfgWriteVariant = evalLimine (lib.recursiveUpdate minimalEnable {
    nixboot.limine.efiVariables = "write";
  });

  cfgDisabled = evalMod [ ../modules/system-manager-limine.nix ];

  install = "nixboot-limine-install";
  verify = "nixboot-limine-verify";
  registerBootEntry = "nixboot-limine-register-boot-entry";

  results = [
    # --- rendering: the pure header function itself (B18-equivalent for this backend) --------
    (check "header/editor-always-rendered-timeout-omitted-when-null"
      (renderLimineHeader { timeout = null; editor = false; } == "editor_enabled: no")
      "got: ${builtins.toJSON (renderLimineHeader { timeout = null; editor = false; })}")

    (check "header/timeout-rendered-when-set-editor-yes-when-true"
      (renderLimineHeader { timeout = 7; editor = true; } == "timeout: 7\neditor_enabled: yes")
      "got: ${builtins.toJSON (renderLimineHeader { timeout = 7; editor = true; })}")

    # --- disabled: a clean no-op, same contract as the NixOS backend's own no-entries case ----
    (check "disabled/no-nixboot-limine-units"
      (!(lib.any (n: lib.hasPrefix "nixboot-limine-" n) (builtins.attrNames cfgDisabled.systemd.services)))
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames cfgDisabled.systemd.services)}")

    # --- enabled: install + verify units exist, correctly ordered and NOT boot/sysinit-wanted -
    (check "enabled/install-service-exists"
      (cfgDefault.systemd.services ? "${install}")
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames cfgDefault.systemd.services)}")

    (check "enabled/install-wantedBy-multi-user-target-not-sysinit"
      (cfgDefault.systemd.services.${install}.wantedBy == [ "multi-user.target" ])
      "got: ${builtins.toJSON cfgDefault.systemd.services.${install}.wantedBy}")

    (check "enabled/verify-service-exists-ordered-after-install"
      (cfgDefault.systemd.services ? "${verify}"
        && lib.elem "${install}.service" cfgDefault.systemd.services.${verify}.after)
      "verify.after: ${builtins.toJSON (cfgDefault.systemd.services.${verify}.after or [ ])}")

    (check "enabled/verify-script-checks-shadow-path-and-efi-intactness"
      (
        lib.hasInfix "ACTIVE config the moment" cfgDefault.systemd.services.${verify}.script
        && lib.hasInfix "intact EFI binary" cfgDefault.systemd.services.${verify}.script
      )
      "nixboot-limine-verify script is missing the shadow-path or EFI-intactness check")

    # --- efiVariables: "removable" registers no NVRAM entry, "write" does -------------------
    (check "removable/no-register-boot-entry-service"
      (!(cfgDefault.systemd.services ? "${registerBootEntry}"))
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames cfgDefault.systemd.services)}")

    (check "write/register-boot-entry-service-exists-ordered-after-install"
      (cfgWriteVariant.systemd.services ? "${registerBootEntry}"
        && lib.elem "${install}.service" cfgWriteVariant.systemd.services.${registerBootEntry}.after
        && cfgWriteVariant.systemd.services.${registerBootEntry}.wantedBy == [ "multi-user.target" ])
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames cfgWriteVariant.systemd.services)}")

    (check "write/register-boot-entry-relpath-under-efi-limine-not-efi-boot"
      (lib.hasInfix "/efi/limine/BOOTX64.EFI" cfgWriteVariant.systemd.services.${registerBootEntry}.script)
      "script: ${cfgWriteVariant.systemd.services.${registerBootEntry}.script}")

    (check "removable/environment-systemPackages-excludes-registrar"
      (builtins.length cfgDefault.environment.systemPackages == 1)
      "environment.systemPackages count: ${toString (builtins.length cfgDefault.environment.systemPackages)}")

    (check "write/environment-systemPackages-includes-registrar"
      (builtins.length cfgWriteVariant.environment.systemPackages == 2)
      "environment.systemPackages count: ${toString (builtins.length cfgWriteVariant.environment.systemPackages)}")

    # --- assertions fire, both directions (requirement: fires when violated, silent when
    # satisfied -- proved on nixboot's OWN condition, see this file's header for the boundary) --
    (check "empty-configText/assertion-fires"
      (assertionFails {
        nixboot.limine = {
          enable = true;
          efiVariables = "removable";
          configText = "";
        };
      })
      "expected assertions to contain a failing entry for configText = \"\", but none did")

    (check "non-empty-configText/assertion-silent"
      (!(assertionFails minimalEnable))
      "expected no failing assertion for a valid config, but at least one fired")
  ];

  failed = builtins.filter (r: !r.ok) results;

  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;

  eval-tests =
    if failed != [ ]
    then
      throw ''
        nixboot system-manager eval-tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length results)}):
        ${report}
      ''
    else
      pkgs.runCommand "nixboot-system-manager-eval-tests"
        { passedCount = toString (builtins.length results); }
        ''
          echo "all $passedCount nixboot system-manager eval tests passed"
          touch $out
        '';
in
{
  system-manager-eval-tests = eval-tests;
}
