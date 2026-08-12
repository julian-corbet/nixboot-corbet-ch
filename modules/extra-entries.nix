# modules/extra-entries.nix
#
# nixboot.extraEntries -- SECOND, non-default UKIs on an ESP that
# loader.program may or may not own at all. This is the mechanism
# modules/nixboot.nix's own SCOPE block named and deferred: "building and
# signing an extra UKI touches the same ukify+sbsign pipeline as a sibling
# appliance distribution's rescue-maintenance script, sight unseen from this
# port." That sibling script (a durable rescue system kept current on a
# shared ESP by the running main) is the field-proven pipeline this file
# absorbs and generalises: resolve a toplevel, build a self-contained UKI
# from its kernel+initrd+cmdline (init= pins the toplevel directly -- no
# on-ESP store bookkeeping needed), optionally sign it, place it under an
# operator-named file, retain an explicit bounded UKI history, and optionally
# register a firmware NVRAM boot entry pointing at it.
#
# WHAT THIS FILE DOES NOT DO, on purpose:
#   - It never touches loader.program's own generations, `generations.keep`,
#     or `bootCounting.tries`. Those govern the ESP entries loader.program
#     itself writes (nixos-generation-*.efi / .conf); an extra entry's name
#     is asserted to never collide with the "nixos-" prefix those mechanisms
#     key their own garbage collection on (see espFileName below), so it is
#     structurally invisible to both -- composition by non-interference, not
#     by coordination.
#   - It never derives `sign.enable` from `secureBoot.enable`. A host may
#     need a signed extra entry while nixboot does not own its primary boot
#     chain at all (loader.program = "none" -- a foreign ESP this module is
#     only allowed to add ONE entry to), and secureBoot.enable itself
#     requires loader.program == "lanzaboote" (see nixboot.nix's own B5
#     assertion) -- so deriving from it would make a signed extra entry
#     impossible on exactly the hosts most likely to want one. Equally, a
#     host with Secure Boot off and no PKI anywhere must still be able to
#     place an UNSIGNED extra entry with no pkiBundle required at all.
#   - It never adds its own filenames to `esp.foreignPaths`. foreignPaths is
#     for paths nixboot itself never touches -- these are the opposite: paths
#     nixboot actively writes and rotates. Mixing the two would make
#     nixboot-verify's Check 4 (survival of paths nixboot promised never to
#     touch) meaningless for an entry this same module maintains.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixboot;

  # Derives a bounded history from one operator-owned filename. Index zero is
  # current; the first and later history entries are -prev and -prev-N. These
  # names are pure derivations so a declared retention count cannot drift from
  # a separately-maintained path list.
  historyFileNameFor = fn: index:
    if index == 0 then fn
    else if index == 1 then "${lib.removeSuffix ".efi" fn}-prev.efi"
    else "${lib.removeSuffix ".efi" fn}-prev-${toString index}.efi";
  historyFileNamesFor = fn: keep: map (index: historyFileNameFor fn index) (lib.range 0 (keep - 1));

  # ── The shared, reusable boot-entry registrar ────────────────────────────
  # ONE tool, parameterised by CLI arguments, used by every entry that turns
  # on bootEntry.enable -- rather than a bespoke script per entry for
  # mechanically identical work. This is also what makes it independently
  # buildable and testable (see checks/default.nix's idempotency proof)
  # without needing a real kernel, a real UKI, or real firmware NVRAM.
  #
  # Lives in lib/register-boot-entry.nix, not inline here, so every NixOS extra entry reuses the
  # same independently buildable idempotency logic rather than maintaining a hand-copy.
  regTool = import ../lib/register-boot-entry.nix { inherit lib pkgs; };
  inherit (regTool) mkRegisterBootEntry registerBootEntry;

  # ── The per-entry build/sign/place/rotate pipeline ───────────────────────
  # One writeShellApplication per attrsOf entry -- writeShellApplication runs
  # shellcheck at BUILD time, which is the cheap guard on this pipeline the
  # way the source artifact pipeline relies on the same thing.
  mkExtraEntryMaintainer = name: entry:
    let
      espDir = "${cfg.esp.mountPoint}/EFI/Linux";
      historyFileNames = historyFileNamesFor entry.espFileName entry.history.keep;
      espFile = "${espDir}/${builtins.head historyFileNames}";
      relPath = "/EFI/Linux/${entry.espFileName}";

      # EVAL SAFETY, same technique as nixram's own documented convention
      # (modules/default.nix's "EVAL SAFETY" header): never index or
      # interpolate a possibly-null value directly. `entry.sign.pkiBundle`
      # can legitimately be null while `entry.sign.enable = true` is an
      # INVALID configuration this module rejects via the assertion below
      # -- but assertions only fire when something forces
      # `system.build.toplevel` (or another assertion-guarded path), and
      # this derivation is exposed UNCONDITIONALLY (see the bottom of this
      # file) so CI can build and shellcheck every maintainer even on a
      # host, or a check fixture, that never reaches that gate. A poison
      # placeholder keeps construction eval-safe either way; the real
      # enforcement is the assertion, not this fallback.
      dbKeyDir =
        if entry.sign.pkiBundle != null
        then "${entry.sign.pkiBundle}/keys/db"
        else "/nixboot-extra-entries-MISSING-sign.pkiBundle-see-assertions";
    in
    pkgs.writeShellApplication {
      name = "nixboot-extra-entry-${name}";
      runtimeInputs = [ pkgs.systemdUkify pkgs.coreutils pkgs.diffutils ]
        ++ lib.optional entry.sign.enable pkgs.sbsigntool
        ++ lib.optional entry.bootEntry.enable registerBootEntry;
      text = ''
        set -euo pipefail
        work="$(mktemp -d)"
        trap 'rm -rf "$work"' EXIT

        # ── 1. build a SELF-CONTAINED UKI ──────────────────────────────────
        # init= pins the toplevel directly, exactly as the source pipeline's
        # own comment states it: "so no stick-side Nix profile bookkeeping is
        # needed". Whether ${entry.toplevel}'s own closure is actually present
        # in whatever /nix/store this host's boot mounts at switch-root is
        # the CONSUMER's responsibility -- nixboot only builds and places the
        # boot artifact, the same boundary it already draws for the ESP
        # itself (declared, never created).
        cmdline="init=${entry.toplevel}/init $(cat ${entry.toplevel}/kernel-params)"
        uki="$work/${entry.espFileName}"
        osrel=()
        [ -e "${entry.toplevel}/etc/os-release" ] && osrel=(--os-release="@${entry.toplevel}/etc/os-release")
        ukify build \
          --linux="${entry.toplevel}/kernel" \
          --initrd="${entry.toplevel}/initrd" \
          --cmdline="$cmdline" \
          "''${osrel[@]}" \
          --output="$uki"

        ${lib.optionalString entry.sign.enable ''
          # ── 2. sign with the declared PKI's db key ───────────────────────
          signed="$work/${entry.espFileName}.signed"
          if [ ! -r "${dbKeyDir}/db.key" ] || [ ! -r "${dbKeyDir}/db.pem" ]; then
            echo "nixboot-extra-entry-${name}: signing key not readable at ${dbKeyDir} -- refusing to place an entry that was declared signed but cannot actually be signed" >&2
            exit 1
          fi
          sbsign --key "${dbKeyDir}/db.key" --cert "${dbKeyDir}/db.pem" --output "$signed" "$uki"
          placed="$signed"
        ''}
        ${lib.optionalString (!entry.sign.enable) ''
          placed="$uki"
        ''}

        # ── 3. retain history + place atomically ──────────────────────────
        mkdir -p "${espDir}"
        ${lib.optionalString (entry.history.keep > 1) ''
          if [ -f "${espFile}" ] && ! cmp -s "$placed" "${espFile}"; then
            ${lib.concatMapStringsSep "\n" (index: ''
              if [ -f "${espDir}/${historyFileNameFor entry.espFileName (index - 1)}" ]; then
                cp -f "${espDir}/${historyFileNameFor entry.espFileName (index - 1)}" "${espDir}/${historyFileNameFor entry.espFileName index}"
              fi
            '') (lib.reverseList (lib.range 1 (entry.history.keep - 1)))}
          fi
        ''}
        install -m0644 "$placed" "${espFile}.new"
        mv -f "${espFile}.new" "${espFile}"   # rename = atomic on the same fs
        ${lib.optionalString (entry.history.keep > 1) ''
          # A newly-adopted history depth can start with only the current UKI
          # on disk. Backfill missing slots from the nearest known-good image;
          # this never replaces an existing older slot.
          ${lib.concatMapStringsSep "\n" (index: ''
            if [ ! -f "${espDir}/${historyFileNameFor entry.espFileName index}" ]; then
              cp -f "${espDir}/${historyFileNameFor entry.espFileName (index - 1)}" "${espDir}/${historyFileNameFor entry.espFileName index}"
            fi
          '') (lib.range 1 (entry.history.keep - 1))}
        ''}
        sync

        ${lib.optionalString entry.bootEntry.enable ''
          # ── 4. register a firmware boot entry (idempotent, self-healing) ──
          nixboot-register-boot-entry --esp ${lib.escapeShellArg cfg.esp.mountPoint} --label ${lib.escapeShellArg entry.bootEntry.label} --relpath ${lib.escapeShellArg relPath}
        ''}

        echo "nixboot-extra-entry-${name}: placed ${espFile}"
      '';
    };
in
{
  options.nixboot.extraEntries = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      options = {
        toplevel = lib.mkOption {
          type = lib.types.package;
          example = lib.literalExpression "self.nixosConfigurations.myhost-rescue.config.system.build.toplevel";
          description = ''
            The system.build.toplevel-shaped derivation this entry boots --
            must expose /kernel, /initrd, /init and /kernel-params exactly as
            a real NixOS system.build.toplevel does (the common case IS a
            foreign nixosConfiguration's own toplevel: a rescue system, a
            BMC-recovery image, anything this host does not run as its OWN
            generation). Built into a self-contained UKI independently of
            whatever loader.program manages -- see sign.enable for why that
            independence matters.

            NO DEFAULT: this is what the entry boots, and guessing one would
            be worse than refusing to build.
          '';
        };

        espFileName = lib.mkOption {
          type = lib.types.str;
          # NO DEFAULT. Surviving whatever GC prefix rule is live on the host
          # is not a coincidence to hope for -- it is asserted below (must not
          # start with "nixos-", the one prefix BOTH shipped loaders key their
          # own generation garbage collection on), and only the person naming
          # a live host's ESP knows a name is genuinely free of every OTHER
          # collision that assertion cannot see (a vendor tool's own entry, a
          # different extra entry, a rescue-media convention already in use).
          description = ''
            The filename this entry is placed under, at
            `<esp.mountPoint>/EFI/Linux/<espFileName>` -- e.g.
            "myhost-rescue.efi". `EFI/Linux/` is where BOTH shipped loaders
            (stock systemd-boot's own UKI auto-discovery, and lanzaboote's
            stub) scan for `.efi` files to add to the boot menu, so an entry
            placed here is auto-discovered whenever loader.program actually
            owns this ESP -- and still reachable via `bootEntry.enable` when
            it does not (loader.program = "none", or a foreign,
            non-systemd-boot-family loader that never scans this directory
            at all -- concretely, `loader.program = "limine"`: limine's
            fixed config search order (see modules/nixboot.nix's own limine
            notes) never scans EFI/Linux/, so an extra entry on a limine
            host is invisible until `bootEntry.enable` gives it an explicit
            NVRAM entry instead).
          '';
        };

        sign = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Sign this entry with sbsign before placing it? Deliberately NOT
              derived from `secureBoot.enable` (unlike `tools.sbctl.enable`
              and `tools.sbsigntool.enable` above, which legitimately are):
              `secureBoot.enable` asserts `loader.program == "lanzaboote"`
              (see B5 in CONTRACT.md), but an extra entry is exactly the case
              where loader.program may be "none" -- a foreign ESP this module
              is only allowed to add ONE entry to, with no opinion about (or
              ownership of) whatever primary chain already lives there.
              Deriving `sign.enable` from `secureBoot.enable` would make a
              signed extra entry structurally impossible on precisely the
              hosts most likely to want one.

              Equally, false is a complete, working answer on its own: a host
              with Secure Boot off and no PKI anywhere places an unsigned UKI
              with no `sign.pkiBundle` required at all (asserted below: this
              only becomes a requirement when `sign.enable = true`).
            '';
          };

          pkiBundle = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = cfg.secureBoot.pkiBundle;
            defaultText = lib.literalExpression "config.nixboot.secureBoot.pkiBundle";
            description = ''
              Which sbctl-shaped PKI bundle's db key signs this entry (the
              same `<bundle>/keys/db/db.{key,pem}` layout `secureBoot.pkiBundle`
              already names). Defaults to `secureBoot.pkiBundle` -- the same
              bundle the primary chain uses, when there is one -- but that
              option is a plain path fact with no dependency on
              `secureBoot.enable` or `loader.program` either, so a host that
              leaves the whole Secure Boot subsystem off can still point this
              at a PKI bundle it maintains for no other reason than signing
              extra entries. Override to use a DIFFERENT bundle than the
              primary chain's. Only read when `sign.enable = true`.
            '';
          };
        };

        history.keep = lib.mkOption {
          type = lib.types.ints.positive;
          default = 1;
          description = ''
            Number of self-contained UKIs to retain for this entry, including
            the current file. History entry one is `-prev.efi`; later entries
            are `-prev-2.efi`, `-prev-3.efi`, and so on. Rotation happens only
            when the newly-built UKI differs byte-for-byte, so a retry cannot
            overwrite a genuine older rescue with an identical current image.
          '';
        };

        espCapacityMiB = lib.mkOption {
          type = lib.types.nullOr lib.types.ints.positive;
          default = null;
          description = ''
            Worst-case ESP budget for one retained UKI of this entry. Required
            when nixboot.generations.capacity.enable is on, so protected extra
            UKIs are accounted for before normal generations are admitted.
          '';
        };

        bootEntry = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Register a firmware NVRAM boot entry (via `efibootmgr`)
              pointing directly at this entry's placed UKI, IN ADDITION TO
              whatever auto-discovery `EFI/Linux/` already gets it from a
              systemd-boot-family loader? Default off: most consumers get
              this for free the moment loader.program actually owns the ESP
              (auto-discovery, no NVRAM write needed) and a duplicate entry
              in both NVRAM and the loader's own menu is more confusing to a
              human at the console than helpful. Turn this on specifically
              for the case auto-discovery cannot cover: `loader.program =
              "none"`, or a foreign, non-systemd-boot-family loader (e.g. one
              that reads its own config format and never scans `EFI/Linux/`
              at all) -- there, a distinct firmware boot entry is the ONLY
              way to ever reach this UKI without a human editing that
              foreign loader's own configuration by hand.

              Registration is idempotent and self-healing across an ESP
              resize -- see `nixboot-register-boot-entry` (this file) for
              exactly how; `efibootmgr --create` on its own is NOT
              idempotent, and this option exists to make it safe to run
              unconditionally on a recurring timer regardless.
            '';
          };

          label = lib.mkOption {
            type = lib.types.str;
            default = name;
            defaultText = lib.literalExpression "<the attribute name>";
            description = "Firmware NVRAM label for this boot entry. Defaults to the entry's own attribute name; override when the attribute name isn't what you want a human choosing from a firmware boot menu to actually read.";
          };
        };
      };
    }));
    default = { };
    description = ''
      SECOND, non-default UKIs on this host's ESP -- a durable rescue,
      BMC-recovery, or fallback boot entry that lives ALONGSIDE
      loader.program's own primary generations, built and signed by the SAME
      ukify+sbsign pipeline a sibling appliance distribution's own
      rescue-maintenance module field-proved, generalised to any host and any
      number of entries. One attrset entry is one maintained UKI.

      Deliberately independent of `generations.keep` / `bootCounting.tries`
      (which only ever govern loader.program's OWN generations -- an extra
      entry's name is asserted to never collide with the prefix those GC
      mechanisms key on) and of `secureBoot.enable` / `loader.program` (see
      `sign.enable`'s own description): an extra entry can exist on a host
      that leaves both those subsystems off entirely, or that runs a
      completely different primary loader nixboot does not own at all
      (`loader.program = "none"`).
    '';
  };

  config = lib.mkMerge [
    {
      # Exposed UNCONDITIONALLY -- same reason nixnas's own rescue-maintenance
      # module exposes its maintainer script outside its own active-gate: a
      # writeShellApplication runs shellcheck at BUILD time, so CI can build
      # and lint every maintainer (and the shared registrar) even on a host,
      # or an eval-tests fixture, that never sets nixboot.enable = true.
      system.build.extraEntryMaintainers = lib.mapAttrs mkExtraEntryMaintainer cfg.extraEntries;
      system.build.nixbootRegisterBootEntry = registerBootEntry;
    }

    (lib.mkIf cfg.enable {
      assertions =
        lib.concatLists
          (lib.mapAttrsToList
            (name: entry: [
              {
                assertion = lib.hasSuffix ".efi" entry.espFileName;
                message = "nixboot.extraEntries.${name}.espFileName ('${entry.espFileName}') must end in .efi -- both stock systemd-boot's own UKI auto-discovery and lanzaboote's stub scan EFI/Linux by that suffix; anything else is invisible to auto-discovery and reachable only via bootEntry, if that is even enabled.";
              }
              {
                assertion = !(lib.hasPrefix "nixos-" entry.espFileName);
                message = "nixboot.extraEntries.${name}.espFileName ('${entry.espFileName}') must not start with \"nixos-\" -- that is the one prefix a sibling appliance distribution's own rescue-maintenance pipeline documents lanzaboote's stub garbage-collecting on every install, and the prefix stock systemd-boot's own configurationLimit GC keys its generation names on too. A name colliding with it vanishes on the very next switch-to-configuration -- silently, since neither GC asks before deleting what looks like one of its own generations.";
              }
              {
                assertion = entry.sign.enable -> entry.sign.pkiBundle != null;
                message = "nixboot.extraEntries.${name}.sign.enable = true but no PKI bundle is available -- set extraEntries.${name}.sign.pkiBundle directly, set nixboot.secureBoot.pkiBundle (sign.pkiBundle's own default), or set sign.enable = false for an unsigned entry.";
              }
              {
                assertion = builtins.match "[A-Za-z0-9_-]+" name != null;
                message = "nixboot.extraEntries attribute name '${name}' must match [A-Za-z0-9_-]+ -- it becomes a systemd unit name verbatim (nixboot-extra-entry-${name}.service).";
              }
            ])
            cfg.extraEntries)
        ++ [
          {
            assertion =
              let
                paths = lib.flatten (lib.mapAttrsToList
                  (_: entry: historyFileNamesFor entry.espFileName entry.history.keep)
                  cfg.extraEntries);
              in
              lib.length paths == lib.length (lib.unique paths);
            message = "nixboot.extraEntries: two entries resolve to the same ESP path (including auto-derived retained-history targets) -- each entry needs an espFileName whose complete history is disjoint from every other entry.";
          }
        ];

      # ── One oneshot + one timer per entry ──────────────────────────────
      # ASYNC BY THE TIMER, never wantedBy multi-user.target -- the same
      # discipline the source rescue-maintenance pipeline documents and for
      # the same reason: a boot/switch-blocking dependency on an ESP write
      # is exactly the class of stall that pipeline's own history records
      # (a 30-minute boot stall from making a slower version of this same
      # kind of unit synchronous). This mechanism's own per-entry work is
      # lighter (no cross-store copy), but the failure mode it is avoiding
      # is about ORDERING against the boot/switch transaction, not about
      # how long the unit happens to take today.
      systemd.services = lib.mapAttrs'
        (name: entry: lib.nameValuePair "nixboot-extra-entry-${name}" {
          description = "nixboot: maintain the extra UKI entry '${name}' on the ESP";
          after = [ "local-fs.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe (mkExtraEntryMaintainer name entry);
            TimeoutStartSec = "5min";
          };
        })
        cfg.extraEntries;

      systemd.timers = lib.mapAttrs'
        (name: _entry: lib.nameValuePair "nixboot-extra-entry-${name}" {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "2min";
            OnUnitActiveSec = "1d";
            Persistent = true;
          };
        })
        cfg.extraEntries;

      environment.systemPackages =
        lib.mapAttrsToList (name: entry: mkExtraEntryMaintainer name entry) cfg.extraEntries
        ++ lib.optional (lib.any (e: e.bootEntry.enable) (lib.attrValues cfg.extraEntries)) registerBootEntry;
    })
  ];
}
