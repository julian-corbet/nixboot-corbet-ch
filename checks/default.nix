# checks/default.nix
#
# EVAL-TIME tests for nixboot.extraEntries (modules/extra-entries.nix), plus one BUILD-level
# (still no VM, no KVM, no real firmware) proof that the firmware boot-entry registrar
# (nixboot-register-boot-entry) is genuinely idempotent and self-healing -- run three times
# against a faked efibootmgr on PATH inside the Nix build sandbox, converging to exactly one
# NVRAM entry across a simulated ESP-path change.
#
# No lanzaboote input exists on this flake (see flake.nix's own note) -- every fixture that needs
# `boot.lanzaboote.*` to merely EXIST as an option stays on loader.program = "systemd-boot" or
# "none" and uses `fakeLanzabooteModule` below, so this file needs nothing beyond nixpkgs itself.
# limine fixtures need no such stand-in: `boot.loader.limine` ships INSIDE nixpkgs (see
# modules/nixboot.nix's own "ONE EXTERNAL DEPENDENCY" header note), so those fixtures exercise
# the real module directly.
#
# checks/system-manager.nix is the separate suite for modules/system-manager-systemd-boot.nix (the
# system-manager backend) -- a different technique (a bare `lib.evalModules` stub, no
# `nixos/lib/eval-config.nix`) because that backend has no NixOS-shaped `config` to evaluate at
# all. See that file's own header for why.

{ pkgs, nixpkgs, system, nixbootModule }:

let
  lib = pkgs.lib;

  # A stand-in system.build.toplevel: only its SHAPE matters here (the four paths
  # extra-entries.nix's maintainer script references), never its actual bootability --
  # these are eval/build-level tests, not VM tests.
  fakeToplevel = pkgs.runCommand "fake-toplevel" { } ''
    mkdir -p $out
    : > $out/kernel
    : > $out/initrd
    : > $out/init
    printf 'console=ttyS0\n' > $out/kernel-params
  '';

  # nixboot.nix writes `boot.lanzaboote.enable` and
  # `boot.lanzaboote.bootCounting.initialTries` UNCONDITIONALLY (see its own
  # "ONE EXTERNAL DEPENDENCY" header note: every host importing nixboot must
  # compose the real lanzaboote flake module, even hosts that leave it
  # disabled). This flake deliberately does not carry lanzaboote as an input
  # (see flake.nix), so these eval-only fixtures need just enough of that
  # option surface to exist -- a bare stand-in, never the real stub/signing
  # behavior, which is exactly why every fixture below stays on
  # loader.program = "systemd-boot" / "none" rather than "lanzaboote".
  fakeLanzabooteModule = { lib, ... }: {
    options.boot.lanzaboote = {
      enable = lib.mkOption { type = lib.types.bool; default = false; };
      pkiBundle = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
      bootCounting.initialTries = lib.mkOption { type = lib.types.nullOr lib.types.int; default = null; };
      package = lib.mkOption { type = lib.types.package; default = pkgs.lzbt; };
      # autoGenerateKeys.enable: added alongside pkiBundle/keySource actually reaching
      # boot.lanzaboote.* (modules/nixboot.nix) -- see the secureBoot fixtures below.
      autoGenerateKeys.enable = lib.mkOption { type = lib.types.bool; default = false; };
    };
  };

  evalFor = extraConfig:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system;
      modules = [
        nixbootModule
        fakeLanzabooteModule
        {
          nixboot.enable = true;
          # loader.program has NO default by design (nixboot.nix's own
          # header note: guessing it wrong is an outage) -- every enabled
          # fixture needs SOME value for the mkIf conditions that read it to
          # even evaluate, so this default gives every fixture below one for
          # free (mkDefault, so any fixture overriding it -- e.g.
          # cfg-signed-decoupled's "systemd-boot" -- wins cleanly, no
          # conflicting-definition error).
          nixboot.loader.program = lib.mkDefault "none";
        }
        extraConfig
        {
          boot.loader.grub.enable = false;
          fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
          system.stateVersion = "25.05";
        }
      ];
    }).config;

  # NixOS's real assertion enforcement lives at system.build.toplevel (lib.asserts wraps it
  # in a throw); reading config.assertions is passive and proves nothing on its own.
  evalFailsBuild = extraConfig:
    !(builtins.tryEval (builtins.seq (evalFor extraConfig).system.build.toplevel true)).success;

  check = name: ok: detail: { inherit name ok detail; };

  # Package derivations render to their store path's basename in a `path` list, not a
  # human-readable name -- used only to make a failing check's `detail` line legible.
  pathNames = cfg: map (p: p.pname or p.name or (builtins.toString p)) cfg.systemd.services.nixboot-verify.path;

  # ── Fixture 1: the minimal working case -- no primary chain owned at all. ──
  # loader.program = "none" is exactly nixrescue's own described scenario: an ESP nixboot
  # does not own, adding ONE unsigned entry.
  cfg-none-unsigned = evalFor {
    nixboot.extraEntries.rescue = {
      toplevel = fakeToplevel;
      espFileName = "myhost-rescue.efi";
    };
  };

  # ── Fixture 2: signing decoupled from BOTH loader.program AND secureBoot.enable. ──
  # loader.program = "systemd-boot" (not lanzaboote) => secureBoot.enable is necessarily
  # false (it asserts loader.program == "lanzaboote") -- yet a SIGNED entry still builds,
  # because sign.pkiBundle is its own independent fact, not derived from secureBoot.enable.
  cfg-signed-decoupled = evalFor {
    nixboot.loader.program = "systemd-boot";
    nixboot.loader.efiVariables = "removable";
    nixboot.extraEntries.bmc = {
      toplevel = fakeToplevel;
      espFileName = "myhost-bmc.efi";
      sign.enable = true;
      sign.pkiBundle = "/var/lib/myhost-extra-entries-pki";
      bootEntry.enable = true;
    };
  };

  # ── Fixture 3: system.build.extraEntryMaintainers is exposed even when nixboot itself is
  # disabled -- the same "CI can build and shellcheck it regardless" contract the source
  # rescue-maintenance module states for its own maintainer script.
  cfg-disabled-still-exposes-maintainer = evalFor {
    nixboot.enable = lib.mkForce false;
    nixboot.extraEntries.rescue = {
      toplevel = fakeToplevel;
      espFileName = "myhost-rescue.efi";
    };
  };

  # ── Fixture 4: media.usb.enable works with nixboot.enable FORCED OFF -- the same
  # "usable without adopting this module's whole boot stance" shape fixture 3 already
  # proves for extraEntries, here for the other knob in this file with that shape (B17).
  cfg-media-usb-standalone = evalFor {
    nixboot.enable = lib.mkForce false;
    nixboot.media.usb.enable = true;
  };

  # ── Fixture 5: media.usb.enable=true alongside the "write" NVRAM stance it warns
  # about (needs cfg.enable, since loader.efiVariables is only ever read there).
  cfg-media-usb-mismatched-efi = evalFor {
    nixboot.loader.program = "systemd-boot";
    nixboot.loader.efiVariables = "write";
    nixboot.media.usb.enable = true;
  };

  # ── Fixture 6: same, but the loader stance the warning wants -- no warning expected.
  cfg-media-usb-removable = evalFor {
    nixboot.loader.program = "systemd-boot";
    nixboot.loader.efiVariables = "removable";
    nixboot.media.usb.enable = true;
  };

  # ── Fixture 7: limine -- the third loader.program value. No fake stand-in module needed
  # (unlike lanzaboote): `boot.loader.limine` ships inside nixpkgs itself, so `evalFor`'s real
  # nixpkgs already provides it. Exercises the options that DO carry over (editor,
  # generations.keep, efiVariables) with efiVariables = "removable" -- limine's own
  # `efiInstallAsRemovable` default reads `!canTouchEfiVariables`, so this also proves that
  # cross-option default resolves correctly through nixboot's write.
  cfg-limine = evalFor {
    nixboot.loader.program = "limine";
    nixboot.loader.editor = true;
    nixboot.loader.efiVariables = "removable";
    nixboot.generations.keep = 12;
  };

  # ── Fixture 8: limine with efiVariables = "write" -- canTouchEfiVariables flips, and
  # limine's own efiInstallAsRemovable default (unwritten by nixboot) should flip with it.
  cfg-limine-write = evalFor {
    nixboot.loader.program = "limine";
    nixboot.loader.efiVariables = "write";
  };

  # ── Fixture 9: proves nixboot genuinely does not write `boot.loader.systemd-boot.editor`
  # under limine -- see the "limine/does-not-touch-systemd-boot-editor" check's own comment for
  # why a plain value comparison can't tell this apart from NixOS' own systemd-boot default.
  cfg-limine-editor-isolation = evalFor {
    nixboot.loader.program = "limine";
    nixboot.loader.editor = true;
    nixboot.loader.efiVariables = "removable";
    boot.loader.systemd-boot.editor = lib.mkDefault false;
  };

  # ── secureBoot.pkiBundle / keySource actually reaching boot.lanzaboote.* ──────────────
  # loader.program = "lanzaboote" needs fakeLanzabooteModule's option surface to exist (this
  # flake carries no real lanzaboote input -- see this file's own header), which is exactly why
  # no earlier fixture in this suite used it. These four do, now that fakeLanzabooteModule
  # declares autoGenerateKeys.enable too.
  cfg-sb-stable = evalFor {
    nixboot.loader.program = "lanzaboote";
    nixboot.secureBoot.enable = true;
    nixboot.secureBoot.pkiBundle = "/nix/lanzaboote/pki";
    nixboot.secureBoot.keySource = "stable";
  };

  cfg-sb-autogenerate = evalFor {
    nixboot.loader.program = "lanzaboote";
    nixboot.secureBoot.enable = true;
    nixboot.secureBoot.pkiBundle = "/nix/lanzaboote/pki";
    nixboot.secureBoot.keySource = "autogenerate";
  };

  # Boot counting is deliberately tested on its own fixture: its runtime proof reads
  # systemd-bless-boot, not merely the lanzaboote `initialTries` value it writes. Keeping
  # this separate prevents a Secure Boot fixture from accidentally exercising the wrong
  # branch just because it happens to use the same loader.
  cfg-boot-counting = evalFor {
    nixboot.loader.program = "lanzaboote";
    nixboot.bootCounting.tries = 3;
  };

  cfg-capacity-retention = evalFor {
    nixboot.loader.program = "lanzaboote";
    nixboot.esp.capacityMiB = 512;
    nixboot.generations.keep = 4;
    nixboot.generations.capacity = {
      enable = true;
      lanzabootePackage = pkgs.hello;
    };
    nixboot.extraEntries.rescue = {
      toplevel = fakeToplevel;
      espFileName = "myhost-rescue.efi";
      history.keep = 3;
      espCapacityMiB = 50;
    };
  };

  # ── remoteUnlock.tpm2.enable -> tpm_crb/tpm_tis reach the initrd's own module set ──────
  # boot.initrd.systemd.enable = true is REQUIRED here: the sealed path (Path A) writes
  # entirely into boot.initrd.systemd.services.*, which the classic initrd builder never
  # renders. A representative valid sealed-path host sets it, exactly as nixnas's own
  # boot glue does as a side effect of its LUKS TPM2 unlock wiring.
  cfg-remoteunlock-tpm2 = evalFor {
    nixboot.remoteUnlock.enable = true;
    nixboot.remoteUnlock.authorizedKeys = [ "ssh-ed25519 AAAAfake test@example" ];
    nixboot.remoteUnlock.tpm2.enable = true;
    nixboot.secureBoot.enable = true;
    nixboot.loader.program = "lanzaboote";
    nixboot.secureBoot.pkiBundle = "/nix/lanzaboote/pki";
    boot.initrd.systemd.enable = true;
  };

  # Flip side: remoteUnlock enabled but the sealed/TPM2 path is NOT in use (plaintext
  # hostKeyPath instead) -- the driver modules must NOT appear.
  cfg-remoteunlock-no-tpm2 = evalFor {
    nixboot.remoteUnlock.enable = true;
    nixboot.remoteUnlock.authorizedKeys = [ "ssh-ed25519 AAAAfake test@example" ];
    nixboot.remoteUnlock.sealHostKey = false;
    nixboot.remoteUnlock.hostKeyPath = ./default.nix; # any real path; content is irrelevant here
  };

  results = [
    # --- decoupling from loader.program / secureBoot.enable (requirement 3) -------------
    (check "none-unsigned/builds-with-no-primary-chain-owned"
      (cfg-none-unsigned.systemd.services ? "nixboot-extra-entry-rescue")
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames cfg-none-unsigned.systemd.services)}")

    (check "signed-decoupled/builds-with-secureBoot-enable-necessarily-false"
      (cfg-signed-decoupled.nixboot.secureBoot.enable == false
        && cfg-signed-decoupled.nixboot.loader.program == "systemd-boot"
        && cfg-signed-decoupled.systemd.services ? "nixboot-extra-entry-bmc")
      "secureBoot.enable: ${builtins.toJSON cfg-signed-decoupled.nixboot.secureBoot.enable}, loader.program: ${cfg-signed-decoupled.nixboot.loader.program}")

    (check "signed-decoupled/sign-pkiBundle-is-independent-of-secureBoot-pkiBundle"
      (cfg-signed-decoupled.nixboot.extraEntries.bmc.sign.pkiBundle == "/var/lib/myhost-extra-entries-pki"
        && cfg-signed-decoupled.nixboot.secureBoot.pkiBundle == null)
      "sign.pkiBundle: ${builtins.toJSON cfg-signed-decoupled.nixboot.extraEntries.bmc.sign.pkiBundle}, secureBoot.pkiBundle: ${builtins.toJSON cfg-signed-decoupled.nixboot.secureBoot.pkiBundle}")

    # --- sign.pkiBundle's default composes with secureBoot.pkiBundle -------------------
    (check "sign-pkiBundle-defaults-to-secureBoot-pkiBundle"
      (
        let
          cfg = evalFor {
            nixboot.secureBoot.pkiBundle = "/var/lib/shared-pki";
            nixboot.extraEntries.x = { toplevel = fakeToplevel; espFileName = "x.efi"; };
          };
        in
        cfg.nixboot.extraEntries.x.sign.pkiBundle == "/var/lib/shared-pki"
      )
      "sign.pkiBundle did not inherit secureBoot.pkiBundle by default")

    # --- bootEntry.label defaults to the attribute name ---------------------------------
    (check "bootEntry-label-defaults-to-attribute-name"
      (cfg-signed-decoupled.nixboot.extraEntries.bmc.bootEntry.label == "bmc")
      "got: ${builtins.toJSON cfg-signed-decoupled.nixboot.extraEntries.bmc.bootEntry.label}")

    # --- extra-entry history has an explicit one-UKI default -------------------------
    (check "history-defaults-to-current-only"
      (cfg-none-unsigned.nixboot.extraEntries.rescue.history.keep == 1)
      "got: ${builtins.toJSON cfg-none-unsigned.nixboot.extraEntries.rescue.history.keep}")

    (check "capacity-retention/wraps-lzbt-and-accounts-extra-ukis"
      (
        cfg-capacity-retention.boot.lanzaboote.package == cfg-capacity-retention.system.build.nixbootLanzabooteRetention
        && cfg-capacity-retention.nixboot.extraEntries.rescue.history.keep == 3
        && cfg-capacity-retention.nixboot.generations.capacity.generationMiB == 64
      )
      "capacity-retention did not render the lzbt wrapper or preserve the declared rescue history budget")

    # --- systemd wiring: async by the timer, never wantedBy multi-user.target ----------
    (check "timer-drives-it-not-boot"
      (!(lib.elem "multi-user.target" (cfg-none-unsigned.systemd.services."nixboot-extra-entry-rescue".wantedBy or [ ]))
        && lib.elem "timers.target" cfg-none-unsigned.systemd.timers."nixboot-extra-entry-rescue".wantedBy)
      "service wantedBy: ${builtins.toJSON (cfg-none-unsigned.systemd.services."nixboot-extra-entry-rescue".wantedBy or [ ])}, timer wantedBy: ${builtins.toJSON cfg-none-unsigned.systemd.timers."nixboot-extra-entry-rescue".wantedBy}")

    (check "timer-persistent-and-daily"
      (cfg-none-unsigned.systemd.timers."nixboot-extra-entry-rescue".timerConfig.Persistent == true
        && cfg-none-unsigned.systemd.timers."nixboot-extra-entry-rescue".timerConfig.OnUnitActiveSec == "1d")
      "timerConfig: ${builtins.toJSON cfg-none-unsigned.systemd.timers."nixboot-extra-entry-rescue".timerConfig}")

    # --- exposed unconditionally, even with nixboot.enable = false (CI buildability) ---
    (check "maintainer-exposed-when-nixboot-disabled"
      (cfg-disabled-still-exposes-maintainer.system.build.extraEntryMaintainers ? "rescue")
      "system.build.extraEntryMaintainers keys: ${builtins.toJSON (builtins.attrNames cfg-disabled-still-exposes-maintainer.system.build.extraEntryMaintainers)}")

    (check "no-systemd-wiring-when-nixboot-disabled"
      (!(cfg-disabled-still-exposes-maintainer.systemd.services ? "nixboot-extra-entry-rescue"))
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames cfg-disabled-still-exposes-maintainer.systemd.services)}")

    (check "register-boot-entry-tool-exposed-unconditionally"
      (cfg-none-unsigned.system.build ? "nixbootRegisterBootEntry")
      "system.build keys: ${builtins.toJSON (builtins.attrNames cfg-none-unsigned.system.build)}")

    # --- verify-script proof: the checks this task added are actually IN the rendered
    # nixboot-verify script (eval-level proof that the runtime checks exist, without
    # executing them -- execution is what the idempotency test below covers separately
    # for the boot-entry registrar, and what a real boot would cover for the rest). ---
    (check "verify-script-mentions-extraEntries"
      (lib.hasInfix "extraEntries.rescue" cfg-none-unsigned.systemd.services.nixboot-verify.script)
      "nixboot-verify script does not reference the declared extraEntries.rescue entry")

    (check "verify-script-checks-signature-when-signed"
      (lib.hasInfix "does NOT verify against" cfg-signed-decoupled.systemd.services.nixboot-verify.script)
      "nixboot-verify script has no signature-verification branch for a signed extraEntries entry")

    (check "verify-script-enhances-foreignPaths-with-integrity-check"
      (
        let
          cfg = evalFor { nixboot.esp.foreignPaths = [ "EFI/BOOT/BOOTX64.EFI" ]; };
        in
        lib.hasInfix "intact EFI binary" cfg.systemd.services.nixboot-verify.script
      )
      "nixboot-verify script does not check foreign .efi paths for intactness, not just existence")

    # `bootctl status` reports this warning when firmware's LoaderDevicePartUUID names a
    # different ESP from the one the declarative configuration mounted. The loader can still
    # look healthy in that state, so pin the extra check explicitly rather than letting a
    # future tidy-up reduce Check 1 back to a loader-identity-only test.
    (check "verify-script-detects-loader-esp-handoff-mismatch"
      (
        lib.hasInfix "loader.espHandoff" cfg-signed-decoupled.systemd.services.nixboot-verify.script
        && lib.hasInfix "different partition UUID" cfg-signed-decoupled.systemd.services.nixboot-verify.script
      )
      "nixboot-verify script does not reject a firmware loader/declared-ESP UUID mismatch")

    (check "verify-script-checks-boot-counting-completion"
      (
        lib.hasInfix "systemd-bless-boot.service" cfg-boot-counting.systemd.services.nixboot-verify.script
        && lib.hasInfix "increase generations.keep" cfg-boot-counting.systemd.services.nixboot-verify.script
      )
      "nixboot-verify script does not read systemd-bless-boot for a boot-counting host")

    # --- nixboot-verify's OWN unit `path` must actually carry what its script resolves by bare
    # name (2026-08-01 incident: findmnt was never on it, so Check 2 could not PASS on ANY
    # consumer, ever -- it left zero trace anywhere, discovered only by hand on a live host).
    # Reading `.systemd.services.nixboot-verify.path` back is a pure eval-time check (the SAME
    # option NixOS actually renders Environment=PATH= from), so this catches the exact class of
    # regression -- a check whose external dependency quietly falls off the unit's PATH -- before
    # it ever reaches a real host, without needing a VM boot to prove it. util-linux (findmnt,
    # Check 2) is unconditional, since Check 2 is never gated behind a tools.*.enable option;
    # sbctl/sbsigntool (Checks 5/9) are asserted BOTH ways against the same tools.sbctl.enable /
    # tools.sbsigntool.enable flags `environment.systemPackages` already gates them on above, so
    # this also proves the two lists can't drift out of sync with each other again.
    (check "verify-path-includes-util-linux-unconditionally"
      (lib.elem pkgs.util-linux cfg-none-unsigned.systemd.services.nixboot-verify.path)
      "nixboot-verify path: ${builtins.toJSON (pathNames cfg-none-unsigned)}")

    (check "verify-path-excludes-sbctl-and-sbsigntool-when-secureBoot-disabled"
      (!(lib.elem pkgs.sbctl cfg-none-unsigned.systemd.services.nixboot-verify.path)
        && !(lib.elem pkgs.sbsigntool cfg-none-unsigned.systemd.services.nixboot-verify.path))
      "nixboot-verify path: ${builtins.toJSON (pathNames cfg-none-unsigned)}")

    (check "verify-path-includes-sbctl-and-sbsigntool-when-secureBoot-enabled"
      (lib.elem pkgs.sbctl cfg-sb-stable.systemd.services.nixboot-verify.path
        && lib.elem pkgs.sbsigntool cfg-sb-stable.systemd.services.nixboot-verify.path)
      "nixboot-verify path: ${builtins.toJSON (pathNames cfg-sb-stable)}")

    # --- tools.* is three INDEPENDENT decisions, not one lumped toggle. sbctl and sbsigntool
    # default from secureBoot.enable because a signing host always wants both; efitools does
    # not, because it inspects the firmware's own NVRAM and is wanted (or not) for reasons a
    # signing posture cannot predict -- see its option doc. That asymmetry is easy to
    # "tidy up" into a single tools.enable by someone who reads the three options and not the
    # reasons, so both halves are pinned: efitools stays OFF on a Secure Boot host that never
    # asked for it, and a host that asks for ONLY efitools gets ONLY efitools -- no sbctl, no
    # sbsigntool, and no need to turn on secureBoot.enable to reach an NVRAM-backup tool. ---
    (check "efitools-stays-off-on-a-secureBoot-host-that-did-not-ask"
      (!(lib.elem pkgs.efitools cfg-sb-stable.environment.systemPackages))
      "efitools was installed by secureBoot.enable alone -- tools.efitools is its own decision")

    (check "efitools-alone-installs-efitools-alone"
      (
        let
          cfg = evalFor { nixboot.tools.efitools.enable = true; };
        in
        lib.elem pkgs.efitools cfg.environment.systemPackages
        && !(lib.elem pkgs.sbctl cfg.environment.systemPackages)
        && !(lib.elem pkgs.sbsigntool cfg.environment.systemPackages)
      )
      "tools.efitools.enable did not install efitools on its own, or dragged a signing tool along with it")

    # --- secureBoot.sbctlCompat: the /etc/sbctl/sbctl.conf write, and the Check 5 branches
    # that read it back. sbctl.conf is YAML (sbctl.conf(5)); an earlier draft of this write
    # emitted a TOML-shaped `keydir = "..."` that sbctl could not parse at all -- and because
    # sbctl exits 0 on a config parse error, the ONLY thing that ever noticed was
    # nixboot-verify's own output grep, on a live host, after the fact. So both halves get
    # pinned here: that the rendered file is machine-valid (parsed, not eyeballed) and that
    # the runtime check still carries a distinct branch for each way it can be wrong. ---
    (check "sbctl-conf-parses-as-json-and-names-the-declared-pkiBundle"
      (
        let
          raw = cfg-sb-stable.environment.etc."sbctl/sbctl.conf".text;
          # Parsed rather than string-compared: builtins.toJSON emits JSON, JSON is a strict
          # subset of YAML, so a successful fromJSON is a machine proof that sbctl's YAML
          # parser can read this file -- exactly the property the old hand-written template
          # lacked. Comparing exact bytes instead would pin builtins.toJSON's spacing and key
          # order, which is not the property under test.
          #
          # The shape guard is load-bearing and deliberately NOT builtins.tryEval: fromJSON's
          # parse failure is a C++-level exception tryEval does not catch, so handing it the
          # old TOML-shaped `keydir = "..."` aborts the entire suite with a raw
          # json.exception.parse_error rather than reporting this one check red. Verified by
          # reintroducing that exact text and watching it happen. `&&` short-circuits and
          # `parsed` is lazy, so requiring a JSON object first keeps the realistic regression
          # -- builtins.toJSON swapped back for a hand-rolled template -- a NAMED failure with
          # the offending bytes in `detail`, which is the whole point of a check suite.
          looksJson = lib.hasPrefix "{" raw && lib.hasSuffix "}" raw;
          parsed = builtins.fromJSON raw;
        in
        looksJson
          && parsed.keydir == "/nix/lanzaboote/pki/keys"
          && parsed.guid == "/nix/lanzaboote/pki/GUID"
      )
      "rendered /etc/sbctl/sbctl.conf: ${cfg-sb-stable.environment.etc."sbctl/sbctl.conf".text}")

    # The gate, both directions. sbctlCompat (true) and keySource ("stable") are BOTH
    # satisfied by their own defaults, so before pkiBundle joined the condition, every host
    # that merely enabled nixboot got this file containing the literal path "null/keys" --
    # cfg-none-unsigned is exactly that host, and asserts the file is now absent entirely.
    (check "sbctl-conf-not-written-without-a-pkiBundle"
      (!(cfg-none-unsigned.environment.etc ? "sbctl/sbctl.conf"))
      "a host with no secureBoot.pkiBundle still got /etc/sbctl/sbctl.conf")

    (check "sbctl-conf-not-written-for-autogenerate-keys"
      (!(cfg-sb-autogenerate.environment.etc ? "sbctl/sbctl.conf"))
      "lanzaboote writes this file itself on autogenerate hosts -- two definitions of one /etc path is a build failure")

    # B9's "config file for an absent tool" warning has to track the WRITE, not merely the
    # sbctlCompat flag. Before the pkiBundle condition existed it fired on hosts that never
    # got the file at all, announcing a write that does not happen -- a warning that cries
    # wolf is the same class of bug as a check that does, just quieter.
    (check "sbctlCompat-absent-tool-warning-fires-when-the-file-is-written"
      (
        let
          cfg = evalFor {
            nixboot.secureBoot.pkiBundle = "/nix/lanzaboote/pki";
            nixboot.tools.sbctl.enable = false;
          };
        in
        lib.any (w: lib.hasInfix "tools.sbctl.enable is false" w) cfg.warnings
      )
      "no warning for a written /etc/sbctl/sbctl.conf whose sbctl binary is absent")

    (check "sbctlCompat-absent-tool-warning-silent-when-no-file-is-written"
      (!(lib.any (w: lib.hasInfix "tools.sbctl.enable is false" w) cfg-none-unsigned.warnings))
      "warned about an /etc/sbctl/sbctl.conf that a host with no pkiBundle never receives")

    (check "verify-script-has-a-branch-for-an-unparseable-sbctl-conf"
      (lib.hasInfix "sbctl returned no status at all"
        cfg-sb-stable.systemd.services.nixboot-verify.script)
      "nixboot-verify has no branch for the one sbctl failure mode that exits 0 -- an unparseable /etc/sbctl/sbctl.conf")

    # `installed` is decided by sbctl purely on the keydir PATH existing, so an empty or
    # half-populated bundle satisfies it just as happily as a real one. Without this branch
    # Check 5 would go green on a host whose signing key is simply gone.
    (check "verify-script-checks-db-key-material-not-just-installed"
      (lib.hasInfix "db/db.key" cfg-sb-stable.systemd.services.nixboot-verify.script)
      "nixboot-verify trusts sbctl's 'installed' line without checking the bundle actually holds key material")

    (check "verify-script-omits-db-key-material-check-without-a-pkiBundle"
      (!(lib.hasInfix "db/db.key" cfg-none-unsigned.systemd.services.nixboot-verify.script))
      "nixboot-verify asserts key material on a host that declared no pkiBundle to hold any")

    # Guards the reason the check reads --json: the human table marks installed with a U+2713
    # inside an English sentence, which makes matching it hostage to sbctl's phrasing and the
    # unit's locale.
    (check "verify-script-reads-sbctl-json-not-the-human-table"
      (lib.hasInfix "sbctl status --json" cfg-sb-stable.systemd.services.nixboot-verify.script
        && !(lib.hasInfix "Installed:" cfg-sb-stable.systemd.services.nixboot-verify.script))
      "nixboot-verify is back to grepping sbctl's human-readable status output")

    # --- assertions fire, verified by actually forcing system.build.toplevel -----------
    (check "espFileName-nixos-prefix-collision/eval-fails"
      (evalFailsBuild {
        nixboot.extraEntries.x = { toplevel = fakeToplevel; espFileName = "nixos-extra.efi"; };
      })
      "expected forcing system.build.toplevel to fail (espFileName starts with the reserved 'nixos-' GC prefix) but it succeeded")

    (check "espFileName-must-end-in-efi/eval-fails"
      (evalFailsBuild {
        nixboot.extraEntries.x = { toplevel = fakeToplevel; espFileName = "myhost-rescue"; };
      })
      "expected forcing system.build.toplevel to fail (espFileName has no .efi suffix) but it succeeded")

    (check "sign-enable-without-any-pkiBundle/eval-fails"
      (evalFailsBuild {
        nixboot.extraEntries.x = {
          toplevel = fakeToplevel;
          espFileName = "x.efi";
          sign.enable = true;
        };
      })
      "expected forcing system.build.toplevel to fail (sign.enable = true with no pkiBundle anywhere) but it succeeded")

    (check "duplicate-espFileName-across-entries/eval-fails"
      (evalFailsBuild {
        nixboot.extraEntries.a = { toplevel = fakeToplevel; espFileName = "shared.efi"; };
        nixboot.extraEntries.b = { toplevel = fakeToplevel; espFileName = "shared.efi"; };
      })
      "expected forcing system.build.toplevel to fail (two entries resolve to the same ESP path) but it succeeded")

    (check "history-target-collides-with-another-entrys-espFileName/eval-fails"
      (evalFailsBuild {
        nixboot.extraEntries.a = { toplevel = fakeToplevel; espFileName = "x.efi"; history.keep = 2; };
        nixboot.extraEntries.b = { toplevel = fakeToplevel; espFileName = "x-prev.efi"; };
      })
      "expected forcing system.build.toplevel to fail (a retained-history target collides with b's own espFileName) but it succeeded")

    (check "capacity-retention/requires-an-extra-entry-budget/eval-fails"
      (evalFailsBuild {
        nixboot.loader.program = "lanzaboote";
        nixboot.esp.capacityMiB = 512;
        nixboot.generations.capacity = {
          enable = true;
          lanzabootePackage = pkgs.hello;
        };
        nixboot.extraEntries.rescue = { toplevel = fakeToplevel; espFileName = "myhost-rescue.efi"; };
      })
      "expected capacity retention with an unbudgeted extra entry to fail but it succeeded")

    (check "capacity-retention/requires-the-composed-lanzaboote-package/eval-fails"
      (evalFailsBuild {
        nixboot.loader.program = "lanzaboote";
        nixboot.esp.capacityMiB = 512;
        nixboot.generations.capacity.enable = true;
      })
      "expected capacity retention without its composed lzbt package to fail but it succeeded")

    (check "invalid-attribute-name/eval-fails"
      (evalFailsBuild {
        nixboot.extraEntries."has a space" = { toplevel = fakeToplevel; espFileName = "x.efi"; };
      })
      "expected forcing system.build.toplevel to fail (attribute name is not a valid systemd unit name component) but it succeeded")

    (check "toplevel-required/eval-fails"
      (evalFailsBuild {
        nixboot.extraEntries.x = { espFileName = "x.efi"; };
      })
      "expected forcing system.build.toplevel to fail (toplevel has no default and was not set) but it succeeded")

    # --- no extraEntries declared at all: everything stays a clean no-op ----------------
    (check "no-entries-declared/no-systemd-units"
      (
        let cfg = evalFor { };
        in !(lib.any (n: lib.hasPrefix "nixboot-extra-entry-" n) (builtins.attrNames cfg.systemd.services))
      )
      "unexpected nixboot-extra-entry- units with zero entries declared")

    (check "no-entries-declared/verify-script-skips-cleanly"
      (
        let cfg = evalFor { };
        in lib.hasInfix "SKIP  extraEntries: none declared" cfg.systemd.services.nixboot-verify.script
      )
      "nixboot-verify script does not SKIP cleanly when nixboot.extraEntries is empty")

    # --- media.usb.enable (B17): usable standalone, adds exactly the USB-controller
    # modules, and cross-checks against loader.efiVariables without ever overriding it ---
    (check "media-usb/works-with-nixboot-enable-forced-off"
      (
        let mods = cfg-media-usb-standalone.boot.initrd.availableKernelModules;
        in lib.all (m: lib.elem m mods) [ "usb_storage" "uas" "xhci_pci" "ehci_pci" ]
      )
      "boot.initrd.availableKernelModules: ${builtins.toJSON cfg-media-usb-standalone.boot.initrd.availableKernelModules}")

    (check "media-usb/default-off-adds-nothing"
      (
        let cfg = evalFor { }; # nixboot.enable = true (fixture default), media.usb.enable at its own default (false)
        in !(lib.elem "usb_storage" cfg.boot.initrd.availableKernelModules)
      )
      "boot.initrd.availableKernelModules unexpectedly carries usb_storage with media.usb.enable left at its default")

    (check "media-usb/warns-when-loader-efiVariables-is-write"
      (lib.any (w: lib.hasInfix "media.usb.enable" w && lib.hasInfix "loader.efiVariables" w) cfg-media-usb-mismatched-efi.warnings)
      "warnings: ${builtins.toJSON cfg-media-usb-mismatched-efi.warnings}")

    (check "media-usb/no-warning-when-loader-efiVariables-is-removable"
      (!(lib.any (w: lib.hasInfix "media.usb.enable" w) cfg-media-usb-removable.warnings))
      "warnings: ${builtins.toJSON cfg-media-usb-removable.warnings}")

    # --- limine: the knobs that DO carry over render into boot.loader.limine.*, never into
    # boot.loader.systemd-boot.* -------------------------------------------------------------
    (check "limine/enable-and-editor-and-generations-keep-render-into-limine-namespace"
      (cfg-limine.boot.loader.limine.enable == true
        && cfg-limine.boot.loader.limine.enableEditor == true
        && cfg-limine.boot.loader.limine.maxGenerations == 12)
      "limine.enable: ${builtins.toJSON cfg-limine.boot.loader.limine.enable}, enableEditor: ${builtins.toJSON cfg-limine.boot.loader.limine.enableEditor}, maxGenerations: ${builtins.toJSON cfg-limine.boot.loader.limine.maxGenerations}")

    # A plain value check here would be too weak to prove anything: NixOS' own systemd-boot
    # module ALSO defaults `editor` to `true` (see loader.editor's own doc: "NixOS defaults this
    # true"), so `cfg-limine`'s `loader.editor = true` reading back as `true` would pass whether
    # or not nixboot ever wrote it. Race a `mkDefault` (priority 1000) host-level definition
    # instead (bound in the outer `let`, `cfg-limine-editor-isolation`): if nixboot's boot.loader
    # merge block incorrectly still wrote `systemd-boot.editor = mkOverride 500 ...` for limine
    # (e.g. isSystemdBootFamily regressed to always-true), that `mkOverride 500` would beat this
    # `mkDefault false` and the result would read back `true`, not `false` -- so this only stays
    # green while the write is genuinely scoped away from limine, proving the isolation rather
    # than assuming it.
    (check "limine/does-not-touch-systemd-boot-editor"
      (cfg-limine-editor-isolation.boot.loader.systemd-boot.editor == false)
      "expected the host's own mkDefault false to stand unopposed (nixboot must not write systemd-boot.editor under limine); got: ${builtins.toJSON cfg-limine-editor-isolation.boot.loader.systemd-boot.editor}")

    (check "limine/systemd-boot-enable-stays-at-its-own-default"
      (cfg-limine.boot.loader.systemd-boot.enable == false)
      "got: ${builtins.toJSON cfg-limine.boot.loader.systemd-boot.enable}")

    (check "limine/grub-still-forced-off"
      (cfg-limine.boot.loader.grub.enable == false)
      "got: ${builtins.toJSON cfg-limine.boot.loader.grub.enable}")

    (check "limine/efiVariables-removable-leaves-limine-efiInstallAsRemovable-default-true"
      (cfg-limine.boot.loader.efi.canTouchEfiVariables == false
        && cfg-limine.boot.loader.limine.efiInstallAsRemovable == true)
      "canTouchEfiVariables: ${builtins.toJSON cfg-limine.boot.loader.efi.canTouchEfiVariables}, efiInstallAsRemovable: ${builtins.toJSON cfg-limine.boot.loader.limine.efiInstallAsRemovable}")

    (check "limine/efiVariables-write-flips-canTouchEfiVariables-and-limine-follows"
      (cfg-limine-write.boot.loader.efi.canTouchEfiVariables == true
        && cfg-limine-write.boot.loader.limine.efiInstallAsRemovable == false)
      "canTouchEfiVariables: ${builtins.toJSON cfg-limine-write.boot.loader.efi.canTouchEfiVariables}, efiInstallAsRemovable: ${builtins.toJSON cfg-limine-write.boot.loader.limine.efiInstallAsRemovable}")

    # --- limine: verify-script gains a limine-shaped Check 1 / Check 6, never the bootctl one -
    # "lanzastub" / "Product: *systemd-boot" are Check 1's bootctl-based detection strings,
    # gated on isSystemdBootFamily -- their absence proves that whole block was skipped for a
    # limine host, not merely that a limine-specific branch was ALSO added alongside it. (Check
    # 6, tested separately below, legitimately renders `case "limine" in` for its OWN
    # generation-count logic, so that substring is not a valid thing to assert absent here.)
    (check "limine/verify-script-checks-limine-conf-path-not-bootctl"
      (
        lib.hasInfix "limine/limine.conf" cfg-limine.systemd.services.nixboot-verify.script
        && !(lib.hasInfix "lanzastub" cfg-limine.systemd.services.nixboot-verify.script)
        && !(lib.hasInfix "Product: *systemd-boot" cfg-limine.systemd.services.nixboot-verify.script)
      )
      "nixboot-verify script does not check the limine config path, or wrongly still renders the bootctl-based Check 1 branch for a limine host")

    (check "limine/verify-script-check6-counts-generation-entries-in-limine-conf"
      (lib.hasInfix ''grep -cE '^/+\+?Generation [0-9]+$' "$esp/limine/limine.conf"'' cfg-limine.systemd.services.nixboot-verify.script)
      "nixboot-verify script is missing Check 6's limine generation-count branch")

    (check "limine/verify-script-warns-on-config-shadow-trap"
      (lib.hasInfix "ACTIVE config the moment" cfg-limine.systemd.services.nixboot-verify.script)
      "nixboot-verify script is missing the limine config-shadow WARN")

    # --- limine: the systemd-boot/lanzaboote-only knobs are refused, not silently ignored -----
    # `efiVariables` is set in every one of these (it has NO default -- modules/nixboot.nix's
    # own header note on why guessing it is an outage) purely so the ONLY reason
    # `evalFailsBuild` can fail is the assertion actually under test, not an unrelated
    # required-option error masking whether that assertion is even wired correctly.
    (check "limine-with-consoleMode/eval-fails"
      (evalFailsBuild {
        nixboot.loader.program = "limine";
        nixboot.loader.efiVariables = "removable";
        nixboot.loader.consoleMode = "auto";
      })
      "expected forcing system.build.toplevel to fail (consoleMode has no limine equivalent) but it succeeded")

    (check "limine-with-graceful/eval-fails"
      (evalFailsBuild {
        nixboot.loader.program = "limine";
        nixboot.loader.efiVariables = "removable";
        nixboot.loader.graceful = true;
      })
      "expected forcing system.build.toplevel to fail (graceful has no limine equivalent) but it succeeded")

    (check "limine-with-selfHeal/eval-fails"
      (evalFailsBuild {
        nixboot.loader.program = "limine";
        nixboot.loader.efiVariables = "removable";
        nixboot.loader.selfHeal = true;
      })
      "expected forcing system.build.toplevel to fail (selfHeal hardcodes bootctl, which limine never uses) but it succeeded")

    (check "limine-with-bootCounting/eval-fails"
      (evalFailsBuild {
        nixboot.loader.program = "limine";
        nixboot.loader.efiVariables = "removable";
        nixboot.bootCounting.tries = 3;
      })
      "expected forcing system.build.toplevel to fail (bootCounting.tries is lanzaboote-stub-only) but it succeeded")

    (check "limine-with-secureBoot/eval-fails"
      (evalFailsBuild {
        nixboot.loader.program = "limine";
        nixboot.loader.efiVariables = "removable";
        nixboot.secureBoot.enable = true;
        nixboot.secureBoot.pkiBundle = "/var/lib/some-pki";
      })
      "expected forcing system.build.toplevel to fail (secureBoot.enable requires loader.program == \"lanzaboote\") but it succeeded")

    (check "systemd-boot-with-consoleMode/eval-succeeds"
      (
        !(evalFailsBuild {
          nixboot.loader.program = "systemd-boot";
          nixboot.loader.efiVariables = "removable";
          nixboot.loader.consoleMode = "auto";
        })
      )
      "expected forcing system.build.toplevel to succeed (consoleMode is valid on the systemd-boot family) but it failed")

    # --- the flip side of every limine-with-X/eval-fails check above: a clean limine host with
    # NONE of the systemd-boot/lanzaboote-only knobs touched builds fine -- proving the new
    # combined assertion is silent when satisfied, not merely that it fires when violated ---
    (check "limine-clean/eval-succeeds"
      (
        !(evalFailsBuild {
          nixboot.loader.program = "limine";
          nixboot.loader.efiVariables = "removable";
          nixboot.loader.editor = true;
          nixboot.generations.keep = 10;
        })
      )
      "expected forcing system.build.toplevel to succeed (a clean limine config touches none of the refused knobs) but it failed")

    # --- secureBoot.pkiBundle / keySource actually reach boot.lanzaboote.* -----------------
    (check "secureboot/pkiBundle-reaches-lanzaboote-stable"
      (cfg-sb-stable.boot.lanzaboote.pkiBundle == "/nix/lanzaboote/pki")
      "got boot.lanzaboote.pkiBundle = ${builtins.toJSON cfg-sb-stable.boot.lanzaboote.pkiBundle}, expected it to match nixboot.secureBoot.pkiBundle")

    (check "secureboot/keySource-stable-leaves-autoGenerateKeys-off"
      (cfg-sb-stable.boot.lanzaboote.autoGenerateKeys.enable == false)
      "got: ${builtins.toJSON cfg-sb-stable.boot.lanzaboote.autoGenerateKeys.enable}")

    (check "secureboot/keySource-stable-does-not-touch-generate-sb-keys"
      (!(cfg-sb-stable.systemd.services ? "generate-sb-keys"))
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames cfg-sb-stable.systemd.services)} -- the landlock workaround must be inert on a stable-keyed host, since lanzaboote itself never creates this unit there")

    (check "secureboot/keySource-autogenerate-turns-on-lanzaboote-autoGenerateKeys"
      (cfg-sb-autogenerate.boot.lanzaboote.autoGenerateKeys.enable == true)
      "got: ${builtins.toJSON cfg-sb-autogenerate.boot.lanzaboote.autoGenerateKeys.enable}")

    (check "secureboot/keySource-autogenerate-applies-the-landlock-workaround"
      (lib.hasInfix "--disable-landlock" (cfg-sb-autogenerate.systemd.services.generate-sb-keys.serviceConfig.ExecStart or ""))
      "generate-sb-keys ExecStart: ${builtins.toJSON (cfg-sb-autogenerate.systemd.services.generate-sb-keys.serviceConfig.ExecStart or null)}")

    (check "secureboot/pkiBundle-inert-when-secureBoot-disabled"
      (
        let cfg = evalFor { nixboot.loader.program = "systemd-boot"; nixboot.loader.efiVariables = "removable"; };
        in cfg.boot.lanzaboote.pkiBundle == null
      )
      "secureBoot.enable = false must never force boot.lanzaboote.pkiBundle away from lanzaboote's own default")

    # --- remoteUnlock.tpm2.enable -> tpm_crb/tpm_tis reach the initrd's own module set -----
    (check "remoteunlock/tpm2-enable-adds-tpm-driver-modules"
      (
        let mods = cfg-remoteunlock-tpm2.boot.initrd.availableKernelModules;
        in lib.elem "tpm_crb" mods && lib.elem "tpm_tis" mods
      )
      "boot.initrd.availableKernelModules: ${builtins.toJSON cfg-remoteunlock-tpm2.boot.initrd.availableKernelModules}")

    (check "remoteunlock/no-tpm2-means-no-tpm-driver-modules"
      (
        let mods = cfg-remoteunlock-no-tpm2.boot.initrd.availableKernelModules;
        in !(lib.elem "tpm_crb" mods) && !(lib.elem "tpm_tis" mods)
      )
      "boot.initrd.availableKernelModules: ${builtins.toJSON cfg-remoteunlock-no-tpm2.boot.initrd.availableKernelModules}")

    # --- remoteUnlock (either host-key path) requires boot.initrd.systemd.enable, proved
    # both ways: the common NIC/DHCP block both paths share writes
    # boot.initrd.systemd.network.enable = true unconditionally, which nixpkgs' own
    # resolved.nix then refuses outside systemd stage 1 -----------------------------
    (check "remoteunlock/sealed-without-systemd-initrd/eval-fails"
      (evalFailsBuild {
        nixboot.remoteUnlock.enable = true;
        nixboot.remoteUnlock.authorizedKeys = [ "ssh-ed25519 AAAAfake test@example" ];
        nixboot.remoteUnlock.tpm2.enable = true;
        nixboot.secureBoot.enable = true;
        nixboot.loader.program = "lanzaboote";
        nixboot.secureBoot.pkiBundle = "/nix/lanzaboote/pki";
        # boot.initrd.systemd.enable EXPLICITLY false -- current nixpkgs defaults this
        # to true (systemd stage-1 is the default initrd today), so leaving it unset
        # would not exercise this assertion at all; a host (or an OLDER nixpkgs pin)
        # that turns it back off is exactly the case B23 exists to catch.
        boot.initrd.systemd.enable = false;
      })
      "expected forcing system.build.toplevel to fail (Path A's systemd-credential writes are silently discarded without boot.initrd.systemd.enable) but it succeeded")

    (check "remoteunlock/sealed-with-systemd-initrd/eval-succeeds"
      (
        !(evalFailsBuild {
          nixboot.remoteUnlock.enable = true;
          nixboot.remoteUnlock.authorizedKeys = [ "ssh-ed25519 AAAAfake test@example" ];
          nixboot.remoteUnlock.tpm2.enable = true;
          nixboot.secureBoot.enable = true;
          nixboot.loader.program = "lanzaboote";
          nixboot.secureBoot.pkiBundle = "/nix/lanzaboote/pki";
          boot.initrd.systemd.enable = true;
        })
      )
      "expected forcing system.build.toplevel to succeed (boot.initrd.systemd.enable = true satisfies Path A's requirement) but it failed")

    (check "remoteunlock/plaintext-path-b-without-systemd-initrd/eval-fails"
      (evalFailsBuild {
        nixboot.remoteUnlock.enable = true;
        nixboot.remoteUnlock.authorizedKeys = [ "ssh-ed25519 AAAAfake test@example" ];
        nixboot.remoteUnlock.sealHostKey = false;
        nixboot.remoteUnlock.hostKeyPath = ./default.nix;
        # boot.initrd.systemd.enable EXPLICITLY false -- proves the COMMON block's
        # unconditional boot.initrd.systemd.network.enable write requires systemd
        # stage 1 even on the plaintext path, which never touches a credential at all.
        boot.initrd.systemd.enable = false;
      })
      "expected forcing system.build.toplevel to fail (the common NIC/DHCP block's boot.initrd.systemd.network.enable write is refused by nixpkgs' own resolved.nix outside systemd stage 1, regardless of which host-key path is in use) but it succeeded")

    (check "remoteunlock/plaintext-path-b-with-systemd-initrd/eval-succeeds"
      (
        !(evalFailsBuild {
          nixboot.remoteUnlock.enable = true;
          nixboot.remoteUnlock.authorizedKeys = [ "ssh-ed25519 AAAAfake test@example" ];
          nixboot.remoteUnlock.sealHostKey = false;
          nixboot.remoteUnlock.hostKeyPath = ./default.nix;
          boot.initrd.systemd.enable = true;
        })
      )
      "expected forcing system.build.toplevel to succeed (boot.initrd.systemd.enable = true satisfies the shared requirement, and Path B needs no credential machinery on top of it) but it failed")

    # --- nixboot-enroll-sb is exposed as a system.build output, like extraEntries' own
    # maintainer derivations, so CI forces + shellchecks it even when no host currently
    # turns on secureBoot.enrollTool.enable && secureBoot.enable -----------------------
    (check "secureboot/nixbootEnrollSb-exposed-unconditionally"
      (
        let cfg = evalFor { }; # nixboot.enable = true (fixture default), secureBoot untouched
        in cfg.system.build ? "nixbootEnrollSb"
      )
      "system.build keys did not include nixbootEnrollSb")
  ];

  failed = builtins.filter (r: !r.ok) results;

  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;

  eval-tests =
    if failed != [ ]
    then
      throw ''
        nixboot eval-tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length results)}):
        ${report}
      ''
    else
    # Depending on `passedCount` forces `results`, so the tests genuinely run under
    # `nix flake check` rather than merely being defined.
      pkgs.runCommand "nixboot-eval-tests"
        { passedCount = toString (builtins.length results); }
        ''
          echo "all $passedCount nixboot eval tests passed"
          touch $out
        '';

  # ── BUILD-level idempotency + self-heal proof for nixboot-register-boot-entry ───────
  #
  # `efibootmgr --create` is not idempotent on its own (see modules/extra-entries.nix's
  # own header) -- this proves the wrapper actually is, and that it self-heals across a
  # simulated path change (an ESP resize, in reality), entirely inside the Nix build
  # sandbox: fake `efibootmgr`/`findmnt`/`lsblk` binaries, placed AHEAD of the real
  # packages in the registrar's own PATH via `passthru.mkTestVariant` (plain PATH
  # prepending from the OUTSIDE does not work here: `writeShellApplication` always
  # rewrites PATH to put its own `runtimeInputs` first, which is exactly what makes the
  # REAL tool immune to a caller's PATH tampering -- `mkTestVariant` is the one
  # deliberate, test-only escape hatch for that). A plain file stands in for NVRAM
  # state; the REAL registrar logic (unmodified `text`) is invoked three times in
  # sequence.
  #
  #   run 1 (fresh)                  -> 1 create,  0 deletes
  #   run 2 (same label + same path) -> 1 create,  0 deletes  (true no-op, not a re-create)
  #   run 3 (same label, NEW path)   -> 2 creates, 1 delete   (self-heals: stale entry
  #                                                            removed, correct one added)
  #   final NVRAM state              -> exactly ONE entry for the label
  fakeEfiTools = pkgs.runCommand "nixboot-test-fake-efi-tools" { } ''
    mkdir -p $out/bin

    cat > $out/bin/findmnt <<'EOF'
    #!/bin/sh
    # Only ever called as: findmnt -no SOURCE <mountpoint>
    echo "/dev/fakedisk1"
    EOF

    cat > $out/bin/lsblk <<'EOF'
    #!/bin/sh
    # Called as: lsblk -no PKNAME <dev>  |  lsblk -no PARTN <dev>
    case "$1$2" in
      -noPKNAME) echo "fakedisk" ;;
      -noPARTN) echo "1" ;;
      *) echo "lsblk-stub: unexpected args: $*" >&2; exit 1 ;;
    esac
    EOF

    cat > $out/bin/efibootmgr <<'EOF'
    #!/bin/sh
    set -eu
    state="$NIXBOOT_TEST_STATE"
    log="$NIXBOOT_TEST_LOG"
    if [ "$1" = "-v" ]; then
      cat "$state" 2>/dev/null || true
      exit 0
    fi
    if [ "$1" = "-b" ]; then
      num="$2"
      echo "delete $num" >> "$log"
      grep -v "^Boot$num" "$state" > "$state.tmp" 2>/dev/null || true
      mv "$state.tmp" "$state" 2>/dev/null || true
      exit 0
    fi
    if [ "$1" = "--create" ]; then
      shift
      label=""
      loader=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --disk|--part) shift 2 ;;
          --label) label="$2"; shift 2 ;;
          --loader) loader="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      disp="$(printf '%s' "$loader" | tr '/' '\\')"
      n=0
      while grep -q "^Boot$(printf '%04d' "$n")\*" "$state" 2>/dev/null; do n=$((n+1)); done
      printf 'Boot%04d* %s\tHD(1,GPT,fake)/File(%s)\n' "$n" "$label" "$disp" >> "$state"
      echo "create $label $disp" >> "$log"
      exit 0
    fi
    echo "efibootmgr-stub: unexpected args: $*" >&2
    exit 1
    EOF

    chmod +x $out/bin/findmnt $out/bin/lsblk $out/bin/efibootmgr
  '';

  registerBootEntryIdempotencyTest =
    let
      registrar = (evalFor { }).system.build.nixbootRegisterBootEntry;
      testRegistrar = registrar.passthru.mkTestVariant [ fakeEfiTools ];
    in
    pkgs.runCommand "nixboot-register-boot-entry-idempotency-test" { } ''
      set -eu
      export NIXBOOT_TEST_STATE="$PWD/nvram-state"
      export NIXBOOT_TEST_LOG="$PWD/call-log"
      : > "$NIXBOOT_TEST_STATE"
      : > "$NIXBOOT_TEST_LOG"

      # ── run 1: nothing registered yet -> exactly one create ──
      ${testRegistrar}/bin/nixboot-register-boot-entry --esp /fake/esp --label TestLabel --relpath /EFI/Linux/test.efi

      creates="$(grep -c '^create ' "$NIXBOOT_TEST_LOG" || true)"
      deletes="$(grep -c '^delete ' "$NIXBOOT_TEST_LOG" || true)"
      [ "$creates" -eq 1 ] || { echo "run 1: expected 1 create, got $creates"; cat "$NIXBOOT_TEST_LOG"; exit 1; }
      [ "$deletes" -eq 0 ] || { echo "run 1: expected 0 deletes, got $deletes"; cat "$NIXBOOT_TEST_LOG"; exit 1; }

      # ── run 2: identical label + path -> TRUE no-op ──
      ${testRegistrar}/bin/nixboot-register-boot-entry --esp /fake/esp --label TestLabel --relpath /EFI/Linux/test.efi

      creates="$(grep -c '^create ' "$NIXBOOT_TEST_LOG" || true)"
      deletes="$(grep -c '^delete ' "$NIXBOOT_TEST_LOG" || true)"
      [ "$creates" -eq 1 ] || { echo "run 2 (idempotent re-run): expected still 1 create, got $creates"; cat "$NIXBOOT_TEST_LOG"; exit 1; }
      [ "$deletes" -eq 0 ] || { echo "run 2 (idempotent re-run): expected still 0 deletes, got $deletes"; cat "$NIXBOOT_TEST_LOG"; exit 1; }

      # ── run 3: SAME label, DIFFERENT path (simulates an ESP resize) -> self-heals ──
      ${testRegistrar}/bin/nixboot-register-boot-entry --esp /fake/esp --label TestLabel --relpath /EFI/Linux/test-new.efi

      creates="$(grep -c '^create ' "$NIXBOOT_TEST_LOG" || true)"
      deletes="$(grep -c '^delete ' "$NIXBOOT_TEST_LOG" || true)"
      [ "$creates" -eq 2 ] || { echo "run 3 (path change): expected 2 creates total, got $creates"; cat "$NIXBOOT_TEST_LOG"; exit 1; }
      [ "$deletes" -eq 1 ] || { echo "run 3 (path change): expected 1 delete (the stale entry), got $deletes"; cat "$NIXBOOT_TEST_LOG"; exit 1; }

      survivors="$(grep -c "TestLabel" "$NIXBOOT_TEST_STATE" || true)"
      [ "$survivors" -eq 1 ] || { echo "expected exactly 1 surviving NVRAM entry for TestLabel, got $survivors"; cat "$NIXBOOT_TEST_STATE"; exit 1; }

      echo "nixboot-register-boot-entry: idempotency + self-heal proof PASSED (creates=$creates, deletes=$deletes, survivors=$survivors)"
      touch $out
    '';

  # ── BUILD-level proof that the per-entry maintainer scripts are actually
  # shellcheck-clean, not merely "the attribute exists" ──
  # `? "rescue"` in the eval-tests above only proves the attribute is
  # PRESENT in the lazy config tree -- it never forces the derivation, so it
  # never runs `writeShellApplication`'s own shellcheck pass. Referencing
  # these two derivations by string interpolation below forces Nix to
  # actually BUILD both branches `mkExtraEntryMaintainer` can generate
  # (unsigned, and signed-with-bootEntry) -- exactly the class of shellcheck
  # regression that would otherwise slip through silently.
  extraEntryMaintainerBuilds =
    let
      unsigned = cfg-none-unsigned.system.build.extraEntryMaintainers.rescue;
      signedWithBootEntry = cfg-signed-decoupled.system.build.extraEntryMaintainers.bmc;
      # Same "reference it to force the build, not just prove the attribute exists"
      # technique, now covering nixboot-enroll-sb too (added alongside the
      # boot.initrd.systemd.enable assertion above) -- forces its own
      # writeShellApplication shellcheck pass under `nix flake check`.
      enrollSbTool = (evalFor { }).system.build.nixbootEnrollSb;
    in
    pkgs.runCommand "nixboot-extra-entry-maintainers-build-check"
      { }
      ''
        echo "unsigned maintainer built: ${unsigned}"
        echo "signed + bootEntry maintainer built: ${signedWithBootEntry}"
        echo "nixboot-enroll-sb built: ${enrollSbTool}"
        touch $out
      '';
in
{
  inherit eval-tests;
  register-boot-entry-idempotency = registerBootEntryIdempotencyTest;
  extra-entry-maintainer-builds = extraEntryMaintainerBuilds;
}
