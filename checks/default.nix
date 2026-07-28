# checks/default.nix
#
# EVAL-TIME tests for nixboot.extraEntries (modules/extra-entries.nix), plus one BUILD-level
# (still no VM, no KVM, no real firmware) proof that the firmware boot-entry registrar
# (nixboot-register-boot-entry) is genuinely idempotent and self-healing -- run three times
# against a faked efibootmgr on PATH inside the Nix build sandbox, converging to exactly one
# NVRAM entry across a simulated ESP-path change.
#
# No lanzaboote input exists on this flake (see flake.nix's own note) -- every fixture below
# deliberately stays on loader.program = "systemd-boot" or "none" so this file needs nothing
# beyond nixpkgs itself.

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

    # --- rotate defaults true --------------------------------------------------------
    (check "rotate-defaults-true"
      (cfg-none-unsigned.nixboot.extraEntries.rescue.rotate == true)
      "got: ${builtins.toJSON cfg-none-unsigned.nixboot.extraEntries.rescue.rotate}")

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

    (check "rotate-prev-collides-with-another-entrys-espFileName/eval-fails"
      (evalFailsBuild {
        nixboot.extraEntries.a = { toplevel = fakeToplevel; espFileName = "x.efi"; rotate = true; };
        nixboot.extraEntries.b = { toplevel = fakeToplevel; espFileName = "x-prev.efi"; rotate = false; };
      })
      "expected forcing system.build.toplevel to fail (a's auto-derived -prev.efi collides with b's own espFileName) but it succeeded")

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
  # (unsigned, and signed-with-bootEntry) -- exactly the class of bug the
  # signing pipeline's own SC1003 finding (fixed during this work) would
  # otherwise have slipped through silently.
  extraEntryMaintainerBuilds =
    let
      unsigned = cfg-none-unsigned.system.build.extraEntryMaintainers.rescue;
      signedWithBootEntry = cfg-signed-decoupled.system.build.extraEntryMaintainers.bmc;
    in
    pkgs.runCommand "nixboot-extra-entry-maintainers-build-check"
      { }
      ''
        echo "unsigned maintainer built: ${unsigned}"
        echo "signed + bootEntry maintainer built: ${signedWithBootEntry}"
        touch $out
      '';
in
{
  inherit eval-tests;
  register-boot-entry-idempotency = registerBootEntryIdempotencyTest;
  extra-entry-maintainer-builds = extraEntryMaintainerBuilds;
}
