# modules/system-manager-limine.nix
#
# nixboot's system-manager backend -- for hosts with NO `boot.*` option surface at all
# (system-manager, e.g. an Arch/CachyOS laptop). See modules/nixboot.nix's own SCOPE
# header for the full NixOS boot stance this is NOT: system-manager has no `boot.loader.*`,
# `boot.initrd.*`, or `boot.kernelParams`, and no `system.build.toplevel` to chainload either
# (a system-manager host boots ITS OWN pacman-managed kernel, not a Nix-built generation) -- so
# remoteUnlock, secureBoot's sbctl/pkiBundle machinery, generations.keep, console.primary,
# extraEntries, and every systemd-boot/lanzaboote-specific knob the NixOS module owns have NO
# COUNTERPART HERE, full stop. That is the honest ceiling this file states plainly rather than
# faking: what IS soundly possible under system-manager is rendering a limine.conf and driving
# limine's own installer CLI, and that is the entire surface below -- a deliberately narrow,
# separately-named option tree (`nixboot.limine.*`, not a reuse of `nixboot.loader.*`), the same
# shape nixpower's own system-manager module carves the "sleep half only" out of its NixOS twin
# (nixpower/modules/system-manager.nix: "Only the sleep half, because the rest of the NixOS
# module emits ... kernel parameters that a system-manager host either cannot set or should
# not").
#
# WHY NIXBOOT RENDERS THE HEADER ITSELF BUT NOT THE MENU ENTRIES, AND DOES NOT PORT THE AUR
# TOOLING THIS LAPTOP USED BEFORE: `limine-mkinitcpio-hook`/`limine-entry-tool` (the third-party
# AUR package that gave this host its "declarative-feeling" limine.conf before nixboot) tracks
# installed kernels/initramfs images itself via its own machine-id/kernel-id bookkeeping under
# /boot. system-manager (like NixOS) knows its OWN closed set of things it manages at activation
# time and needs no such bookkeeping for THAT -- but unlike NixOS, it has no visibility at all
# into which kernels a pacman-managed distro has installed; that is pacman/mkinitcpio state,
# entirely foreign to this module, the same foreign/Nix split modules/foreign-service.nix already
# draws for other pacman-owned services. So `configText` below is the operator's own,
# hand-authored menu-entry text -- nixboot renders the config HEADER (timeout/editor) it DOES
# have an honest opinion about, installs the loader binary, and enrolls the config hash, but does
# not and cannot honestly generate menu entries for kernels it never sees.
#
# CONFIG PATH SHADOWING TRAP (same one modules/nixboot.nix's loader.program doc describes for the
# NixOS backend): limine's config search order is FIXED and not configurable --
# `<esp.mountPoint>/limine/limine.conf` wins over `<esp.mountPoint>/limine.conf`, and whichever
# loses is ignored SILENTLY. This module installs to the winning path and its own verify unit
# WARNs if the shadowed, losing path also exists.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixboot.limine;

  # Same idempotent/self-healing NVRAM registrar the NixOS backend's extraEntries.*.bootEntry
  # uses -- see lib/register-boot-entry.nix's own header for why this must not be a second,
  # independently-drifting copy of that logic.
  regTool = import ../lib/register-boot-entry.nix { inherit lib pkgs; };

  # Pure function, tested directly (no module eval, no build) in checks/system-manager.nix --
  # see lib/render-limine-header.nix's own header for why this is a separate file rather than
  # inlined here.
  renderLimineHeader = import ../lib/render-limine-header.nix { inherit lib; };

  renderedConfig = renderLimineHeader { inherit (cfg) timeout editor; } + "\n\n" + cfg.configText;
  configFile = pkgs.writeText "nixboot-limine.conf" renderedConfig;

  confDestPath = "${cfg.esp.mountPoint}/limine/limine.conf";
  # The shadow-trap path -- see the module header and loader.efiVariables' own doc.
  shadowPath = "${cfg.esp.mountPoint}/limine.conf";

  # x86_64 only. limine also ships BOOTIA32.EFI/BOOTAA64.EFI for other architectures (nixpkgs'
  # own NixOS installer picks between them by hostPlatform); out of scope here -- the
  # system-manager host this backend was built for is x86_64, and BIOS/legacy install
  # (`limine bios-install`) is not implemented at all in this first cut.
  efiBinaryName = "BOOTX64.EFI";
  efiDestSubdir = if cfg.efiVariables == "removable" then "efi/boot" else "efi/limine";
  efiRelPath = "/${efiDestSubdir}/${efiBinaryName}";
  efiDestPath = "${cfg.esp.mountPoint}${efiRelPath}";
  efiSourcePath = "${cfg.package}/share/limine/${efiBinaryName}";
in
{
  options.nixboot.limine = {
    enable = lib.mkEnableOption "nixboot: render limine.conf and install the limine EFI loader (system-manager backend)";

    package = lib.mkPackageOption pkgs "limine" { };

    esp.mountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/boot";
      description = ''
        Where is the ESP mounted? Never partitioned, formatted, or mounted
        here -- same declared-not-created boundary as the NixOS module's
        `esp.mountPoint` (modules/nixboot.nix), just without that module's
        `nixstorage.layout` integration: a system-manager host's disk
        layout is foreign to this Nix-managed slice, not owned by anything
        in the nix* family.
      '';
    };

    efiVariables = lib.mkOption {
      type = lib.types.enum [ "write" "removable" ];
      # NO default -- mirrors modules/nixboot.nix's own loader.efiVariables: guessing wrong
      # here is the same class of outage (an NVRAM entry pointing at a device path that turns
      # out to be removable-only, or a removable-only install on a box that needed the NVRAM
      # entry to boot at all).
      description = ''
        Does firmware get an NVRAM boot entry for the limine EFI binary
        ("write", registered idempotently via the same
        nixboot-register-boot-entry tool the NixOS backend's
        `extraEntries.*.bootEntry` uses -- see lib/register-boot-entry.nix),
        or does it rely on the removable-media fallback path
        \EFI\BOOT\BOOTX64.EFI ("removable")? Also decides WHERE the binary
        is placed: `efi/limine/` for "write", `efi/boot/` for "removable"
        -- the same split nixpkgs' own
        `boot.loader.limine.efiInstallAsRemovable` draws on the NixOS
        backend.
      '';
    };

    timeout = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
      description = ''
        How many seconds does the menu wait before booting the default
        entry? null = omit the header line entirely, i.e. defer to
        limine's own upstream default. Mirrors
        modules/nixboot.nix's `loader.timeout`.
      '';
    };

    editor = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        May someone at the console edit a boot entry's command line before
        booting it? Mirrors modules/nixboot.nix's `loader.editor` -- same
        footgun (`init=/bin/sh` gains root), same default, always rendered
        explicitly (see the module header).
      '';
    };

    enrollConfig = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enroll a BLAKE2b hash of the freshly-installed limine.conf into the
        placed EFI binary (`limine enroll-config <efi-binary> <hash>`), so
        a tampered config is refused at boot. This is limine's WHOLE-CONFIG
        trust boundary -- see `loader.program`'s own doc on
        modules/nixboot.nix for how it differs from lanzaboote's
        per-generation signing.

        Signing the LOADER BINARY itself (`sbctl sign`, the other half of
        limine's Secure Boot story on the NixOS backend) is NOT implemented
        here. That is a one-time, human-run operation even on this operator's
        NixOS hosts (`nixboot-enroll-sb`, modules/nixboot.nix) and has no
        system-manager counterpart in this first cut. `enrollConfig` alone
        raises the bar from "unauthenticated" to "tamper-evident against a
        config edit" -- it does not, on its own, add up to Secure Boot.
      '';
    };

    configText = lib.mkOption {
      type = lib.types.lines;
      # NO default -- see the module header: nixboot has no visibility into which kernels a
      # pacman-managed distro has installed, so guessing menu entries would be worse than
      # refusing to render a config with none (mirrors extraEntries.<name>.toplevel's own "NO
      # DEFAULT" reasoning on the NixOS backend, modules/extra-entries.nix).
      example = ''
        /CachyOS
            comment: current kernel
            protocol: linux
            kernel_path: boot():/vmlinuz-linux-cachyos
            module_path: boot():/initramfs-linux-cachyos.img
            cmdline: root=/dev/mapper/root rw
      '';
      description = ''
        The BODY of limine.conf -- one or more menu entries, in limine's
        own config syntax
        (https://github.com/limine-bootloader/limine/blob/trunk/CONFIG.md).
        Appended after the header this module renders from
        `timeout`/`editor` above.

        nixboot cannot generate this itself: unlike the NixOS backend
        (which reads a real `system.build.toplevel`'s kernel/initrd/cmdline
        directly), a system-manager host's kernels are pacman/mkinitcpio
        state -- entirely foreign to this module. Do NOT port
        `limine-mkinitcpio-hook`'s own machine-id/kernel-id bookkeeping
        here -- see the module header for why.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.configText != "";
        message = "nixboot.limine.configText is empty -- nixboot.limine.enable = true would install a working loader binary pointed at a config with no boot entries at all, an unbootable host. Supply at least one menu entry (see the option's own example).";
      }
    ];

    systemd.services.nixboot-limine-install = {
      description = "nixboot: render limine.conf and install the limine EFI loader";
      # multi-user.target (not sysinit) so system-manager (re)runs this on a live `switch`, not
      # only at boot -- see modules/foreign-service.nix's own header note (this repo's sibling,
      # nixarch) on why a sysinit-wanted unit would silently never fire on activation. On a live
      # system-manager machine this target is remapped to `system-manager.target`.
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.coreutils cfg.package ];
      script = ''
        set -euo pipefail
        install -Dm0644 ${configFile} ${lib.escapeShellArg confDestPath}
        install -Dm0644 ${efiSourcePath} ${lib.escapeShellArg efiDestPath}
        ${lib.optionalString cfg.enrollConfig ''
          # Hash the file AS INSTALLED, not the Nix store source -- guarantees the enrolled
          # hash matches the exact bytes limine itself will read, with no risk of a strip/
          # newline mismatch between what was rendered and what was hashed. GNU coreutils'
          # b2sum defaults to BLAKE2b-512 with no key/salt, bit-for-bit the same digest
          # Python's bare `hashlib.blake2b()` produces (verified: both hash "hello world" to
          # 021ced87...cbc7fd0) -- the exact algorithm `limine enroll-config` expects.
          hash="$(b2sum ${lib.escapeShellArg confDestPath} | cut -d' ' -f1)"
          limine enroll-config ${lib.escapeShellArg efiDestPath} "$hash"
        ''}
      '';
    };

    systemd.services.nixboot-limine-verify = {
      description = "nixboot: read the installed limine config/loader back and report what actually took";
      wantedBy = [ "multi-user.target" ];
      after = [ "nixboot-limine-install.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.coreutils ];
      script = ''
        set -uo pipefail   # no -e: a failed readback is data, not an engine crash -- same
                           # convention as nixboot-verify on the NixOS backend (modules/nixboot.nix)
        fail=0
        conf=${lib.escapeShellArg confDestPath}
        shadow=${lib.escapeShellArg shadowPath}
        efi=${lib.escapeShellArg efiDestPath}

        if [ -s "$conf" ]; then
          echo "PASS  nixboot.limine: $conf exists and is non-empty"
        else
          echo "FAIL  nixboot.limine: $conf is missing or empty -- the install step did not take"
          fail=1
        fi

        # Same shadow-path trap as the NixOS backend's Check 1 (modules/nixboot.nix) -- see
        # loader.program's own doc there for the full reasoning: limine's search order is
        # fixed, $conf wins over $shadow today, but only for as long as $conf keeps existing.
        if [ -f "$shadow" ]; then
          echo "WARN  nixboot.limine: $shadow ALSO exists -- limine's fixed search order means $conf (checked above) wins today, but this shadowed file would become the ACTIVE config the moment $conf disappears, with no warning from limine itself. Remove it."
        fi

        # Same PE/COFF "MZ" intactness check modules/nixboot.nix's Check 4 already uses for
        # foreign .efi paths -- existence alone is satisfied equally by the real binary and by
        # a zero-byte file left behind by a write that failed partway.
        if [ -e "$efi" ]; then
          sz="$(stat -c%s "$efi" 2>/dev/null || echo 0)"
          magic="$(head -c2 "$efi" 2>/dev/null | tr -d '\0')"
          if [ "$sz" -gt 0 ] && [ "$magic" = "MZ" ]; then
            echo "PASS  nixboot.limine: $efi present and looks like an intact PE/EFI binary ($sz bytes)"
          else
            echo "FAIL  nixboot.limine: $efi exists but is not an intact EFI binary (size=$sz bytes, magic='$magic')"
            fail=1
          fi
        else
          echo "FAIL  nixboot.limine: $efi is MISSING -- the install step did not place the loader binary"
          fail=1
        fi

        if [ "$fail" -ne 0 ]; then
          echo "nixboot-limine-verify: at least one check failed -- see FAIL lines above."
          exit 1
        fi
        echo "nixboot-limine-verify: limine.conf and the EFI loader both verified against the live system."
      '';
    };

    systemd.services.nixboot-limine-register-boot-entry = lib.mkIf (cfg.efiVariables == "write") {
      description = "nixboot: register a firmware NVRAM boot entry for the limine EFI loader";
      wantedBy = [ "multi-user.target" ];
      after = [ "nixboot-limine-install.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ regTool.registerBootEntry ];
      script = ''
        nixboot-register-boot-entry --esp ${lib.escapeShellArg cfg.esp.mountPoint} --label limine --relpath ${lib.escapeShellArg efiRelPath}
      '';
    };

    environment.systemPackages = [ cfg.package ]
      ++ lib.optional (cfg.efiVariables == "write") regTool.registerBootEntry;
  };
}
