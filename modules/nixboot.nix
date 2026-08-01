# modules/nixboot.nix
#
# ONE declarative boot stance per host: firmware handoff through to
# switch-root. This exists because the boot domain had been living inside a
# single appliance distribution's own `nixnas.boot.*` option tree -- correct
# for that appliance, and no reuse path for any other host. Boot is not an
# appliance concern; every machine has one. Shaped after a sibling per-host
# hardware-power module in the same house style: prose options, one knob one
# owner, and a *-verify
# service because a boot setting that is requested and silently refused is
# worse here than anywhere else -- the only evidence appears at the NEXT
# boot, on hardware with a ~15-minute POST and (on some server boards) a
# keyboard-dead IPMI-KVM during the UEFI phase. Every boot-affecting change
# on hardware like that is effectively unvalidated until the next real
# boot, and must be treated as such.
#
# SCOPE -- what this module owns, so no knob has two managers:
#   OWNED : which program installs to the ESP (loader.program: systemd-boot,
#           lanzaboote, limine, or none) and every knob of ITS menu that
#           actually transfers across all three (timeout/editor/efiVariables)
#           -- consoleMode does NOT (asserted below: it is a systemd-boot-
#           family-only concept, limine's own menu resolution is a different
#           option with a different value shape, see loader.consoleMode's own
#           doc); whether a failed bootloader install aborts the switch
#           (loader.graceful) or self-heals every boot (loader.selfHeal) --
#           BOTH also systemd-boot-family-only (asserted below): limine has
#           no `graceful`-shaped install-failure knob, and selfHeal's unit
#           hardcodes `bootctl`, a binary limine never uses;
#           the DECLARED shape of the ESP (esp.*) for assertions and
#           verify -- see below, nixboot never creates any of it; how many
#           past generations stay in the menu (generations.keep) and
#           whether the lanzaboote stub counts down failed boots
#           (bootCounting.tries); the Secure Boot posture (secureBoot.*)
#           and its operator-run enrollment command; the per-tool CLI
#           exposure for sbctl/efitools/sbsigntool; the initrd-SSH remote
#           unlock surface (remoteUnlock.*) -- NIC-up + sshd in the
#           initrd, the choice between a TPM2-sealed systemd credential
#           and a plaintext build-time key for the host key, and the
#           self-healing seal service that survives a Secure Boot key
#           enrollment -- while only READING the TPM2 enable/pcrs/device
#           values it seals against, never declaring that policy itself
#           (see remoteUnlock.tpm2.* below and the NOT note underneath);
#           SECOND, non-default UKIs on the same ESP (extraEntries.*,
#           modules/extra-entries.nix) -- built and signed by the same
#           ukify+sbsign pipeline, placed under an operator-named file,
#           optionally rotated as a current/previous pair and optionally
#           registered as an idempotent firmware NVRAM boot entry --
#           deliberately independent of generations.keep/bootCounting.tries
#           (which only ever govern loader.program's OWN generations) and
#           of secureBoot.enable (see extraEntries.*.sign.enable's own
#           description for why signing an extra entry cannot be derived
#           from a policy that requires loader.program == "lanzaboote");
#           and nixboot-verify, which reads every one of the above back
#           from the live system; whether the initrd must be able to find
#           and drive a USB-attached boot device at all (media.usb.enable)
#           -- the one knob in this file that is DELIBERATELY independent
#           of `cfg.enable` (see that option's own doc, and the config-side
#           comment where it is wired, for why: the same "usable without
#           taking on this module's whole boot-stance ownership" shape
#           `extraEntries.*`'s unconditionally-exposed build outputs
#           already use).
#   NOT   : the ESP is never partitioned, formatted, or mounted here --
#           that is disko (modules/nixos/disko/*.nix on these hosts) or,
#           on a host running nixnas, its `disko.memSize` appliance layout.
#           nixboot only DECLARES where an ESP that already exists lives
#           (esp.mountPoint) and what must already be true about it
#           (esp.byLabel, esp.capacityMiB) so it can assert and verify. The
#           same line applies to `media.usb.enable`: it says nothing about
#           the STICK a USB-booted host actually uses -- device path, image
#           size, ESP size, partition count are all geometry that stays
#           with whoever lays out that stick (e.g. nixnas's own
#           `boot.usb.*`); this module only ever answers whether the
#           initrd can see a USB device at all.
#   NOT   : kernel packaging -- variant/march/lto, the ZFS kernel module
#           pairing, substituter choice. A foreign domain by the same rule
#           that put PCI/USB power in nixpower and not nixbmc: this stays
#           with whoever packages the kernel (nixnas today; a future
#           `nixkernel` is the right home, not this file).
#   NOT   : disk-layout identity -- LUKS members, ZFS pool import, the
#           store/hot vs store/usb split, impermanence/persist.*, and the
#           TPM2 policy that guards the DATA unlock itself (PCR set / PIN
#           requirement / device -- nixnas's `crypto.tpm2.*`). Those are
#           appliance state that happens to be consulted from stage 1.
#           remoteUnlock.tpm2.* is deliberately NOT that policy: it is a
#           same-shaped enable/pcrs/device MIRROR a composing module feeds
#           a value into, so the initrd-SSH host-key seal has something
#           honest to bind to without this module re-declaring a second
#           TPM2 owner -- see the option doc for exactly why the two can
#           legitimately disagree on PCRs. The initrd console keymap is
#           real and evidenced but is NOT implemented in this first cut.
#   NOT   : power policy (nixpower's `sleep.allowed`, ASPM, EPP) even
#           though a suspend/resume cycle is boot-adjacent. Two managers
#           on one kernel-param list is exactly the mistake nixpower's own
#           header warns against.
# ONE EXTERNAL DEPENDENCY THIS MODULE DOES NOT PROVIDE: `boot.lanzaboote.*`
# is not a stock NixOS option -- it is defined by the separate lanzaboote
# flake's own NixOS module. nixboot WRITES to those options when
# loader.program = "lanzaboote" but does not import that module itself
# (self-contained on purpose, same reasoning as a sibling hardware-power
# module in this house style, so this can be lifted into a public `nixboot`
# flake unchanged). Whoever composes host module lists MUST include
# lanzaboote's module on every host this module is imported on, not just
# the hosts that use it -- an LXC guest (loader.program = "none") still
# needs `boot.lanzaboote.enable` to EXIST as an option so this module can
# set it to `false` without an eval error. This is the same shape as the
# existing composition: the lanzaboote module is already added once across every host,
# not per-host (evidence: one top-level flake composes the lanzaboote module
# once, at the top level, not per host).
#
# `loader.program = "limine"` needs NO SUCH COMPOSITION STEP: unlike
# lanzaboote, `boot.loader.limine.*` ships INSIDE nixpkgs itself
# (nixos/modules/system/boot/loader/limine/limine.nix, landed as a stock
# module -- nothing to add to a host's module list, nothing this flake
# could accidentally break by not tracking it). This is also why limine's
# own eval-tests in checks/default.nix need no fake stand-in module the way
# `fakeLanzabooteModule` does there for lanzaboote: nixpkgs already provides
# the real thing.
#
# PRIORITY DISCIPLINE -- read before touching any `boot.loader.*` write in
# this file: always `lib.mkOverride 500`, NEVER `lib.mkForce`. `mkOverride
# 500` beats a profile's `mkDefault` (priority 1000, e.g. base.nix's
# `boot.loader.grub.enable = mkDefault true`) while still losing cleanly to
# a host's own plain `=` (priority 100) or `mkForce` (priority 50) --
# no eval error, the more specific definition just wins, silently and
# correctly. Two image hosts already carry `boot.loader.grub.enable =
# mkForce false;` in their own host files; if this module also reached for
# `mkForce` for a DIFFERENT desired value anywhere, that would be two
# same-priority definitions disagreeing -- an eval error, not a warning.
# `mkOverride 500` is the only priority that cannot collide with a host's
# `mkForce` no matter what either side wants.
{ config
, lib
, pkgs
, ...
}:
let
  cfg = config.nixboot;

  # Every knob this module wires straight into `boot.loader.systemd-boot.*` -- editor, graceful,
  # consoleMode, configurationLimit -- is a systemd-boot MENU concept that lanzaboote's own stub
  # also reads from the same namespace (it builds on the systemd-boot stub, it does not replace
  # its options). limine has its OWN, differently-shaped option tree
  # (`boot.loader.limine.enableEditor`/`.maxGenerations`, no `graceful` or `consoleMode`
  # equivalent at all) and must never fall through to writing `systemd-boot.*` silently --
  # every write and assertion below that is specific to the systemd-boot/lanzaboote pair gates on
  # this, so adding a FOURTH loader later only ever means adding a fourth branch, never widening
  # this one by accident.
  isSystemdBootFamily = cfg.loader.program == "systemd-boot" || cfg.loader.program == "lanzaboote";
  isLimine = cfg.loader.program == "limine";

  # ── nixstorage.layout: read defensively, see the ESP option block for why ──
  # Which layout image describes THIS host's medium cannot be guessed, so it is named by
  # esp.fromLayout. Absent that (or absent nixstorage entirely) every derived default
  # falls back to null and the operator states the facts directly.
  nsImages = config.nixstorage.layout.images or { };
  espSourceImage =
    if cfg.esp.fromLayout != null && nsImages ? "${cfg.esp.fromLayout}"
    then nsImages."${cfg.esp.fromLayout}"
    else null;
  espSourcePart =
    if espSourceImage == null then null
    else lib.findFirst (p: p.role or null == "esp") null (espSourceImage.partitions or [ ]);


  # Measured, not guessed (contract evidence: a live production ESP
  # measured at 187 MiB used of 2048 MiB declared). A lanzaboote UKI stub is
  # ~195 KiB; rounding up to a flat 1 MiB/generation is a deliberately
  # generous ceiling so this warning fires early rather than late.
  # Kernel+initrd are shared per DISTINCT kernel version at ~50 MiB
  # regardless of loader.program; budget for 2 in flight (a kernel bump
  # briefly needs both old and new). Both `nixnas/modules/options.nix`
  # ("~80 MiB per generation") and a private per-host config ("150-300 MiB
  # each") document this wrong -- do not copy those numbers forward.
  espProjectedMiB = cfg.generations.keep + (2 * 50);

  ## ── Remote unlock (initrd SSH) plumbing ─────────────────────────────────
  ## `ru` short-hands `cfg.remoteUnlock` the same way `cfg` short-hands
  ## `config.nixboot` above -- both are read lazily, so binding them here
  ## ahead of the options section they describe is the same pattern
  ## `espProjectedMiB` already uses for `cfg.generations.keep`.
  ru = cfg.remoteUnlock;

  # Whether the TPM2-sealed-credential path (Path A) is actually active.
  # Folds in `ru.tpm2.enable` -- the one value this module READS instead of
  # OWNING; see the option doc on `remoteUnlock.tpm2.enable` for why nixboot
  # never declares its own TPM2 policy the way nixnas's `crypto.tpm2.*` does.
  sealActive = ru.sealHostKey && ru.tpm2.enable;

  # Same openssh package whose sshd the nixpkgs initrd-ssh module copies in
  # -- reusing it for ssh-keygen adds (almost) nothing to the initrd closure.
  # Also used by nixboot-verify below, on the STAGE-2 system, where it's
  # already a normal store path (not initrd-embedded).
  sshPackage = config.programs.ssh.package;

  # ── Path B (plaintext): non-store destination for the host key inside the initrd.
  hostKeyDest = "/etc/ssh/nixboot_initrd_host_ed25519_key";
  # Source as its own tracked store path (proper context so builtins.path
  # actually resolves at eval time). Guarded with a null check so Nix never
  # forces builtins.path on a null path when Path A is in use instead.
  hostKeySource =
    if ru.hostKeyPath != null
    then builtins.path { path = ru.hostKeyPath; name = "nixboot-initrd-host-key"; }
    else null;

  # The host key travels as a TPM2-sealed *systemd credential*. This name is
  # shared across three touch-points: the sealed file `<credName>.cred`, the
  # `--name=` baked into the ciphertext, and sshd's `LoadCredentialEncrypted=`
  # that inherits + decrypts it.
  credName = "nixboot-initrd-hostkey";
  # The ESP's global credential drop-in dir, relative to THIS module's own
  # `esp.mountPoint` -- deliberately not a hardcoded `/boot` the way nixnas's
  # source is, since nixboot already owns esp.mountPoint as a declared fact
  # and a host that mounts its ESP somewhere else must not get a silently
  # wrong credential path. lanzaboote's stub is what scans
  # `\loader\credentials\*.cred` and packs it into the initrd on every boot
  # after the first seal.
  credEspPath = "${cfg.esp.mountPoint}/loader/credentials/${credName}.cred";
  # Where systemd hands the DECRYPTED credential to the sshd unit ($CREDENTIALS_DIRECTORY).
  hostKeyCredPath = "/run/credentials/sshd.service/${credName}";
  # The seal service drops the PUBLIC half beside the .cred for out-of-band verification
  # (and for nixboot-verify's Check 7, below).
  pubEspPath = "${lib.removeSuffix ".cred" credEspPath}.pub";

  # ── Path A first-boot fallback: EPHEMERAL host key, generated in the initrd. ──
  # Both paths live on the initrd's RAM-backed rootfs -- discarded at
  # switch-root, never persisted anywhere. /etc/ssh already exists in the
  # initrd (sshd_config lives there).
  ephemeralKeyPath = "/etc/ssh/nixboot_initrd_ephemeral_ed25519_key";
  bannerPath = "/etc/ssh/nixboot_initrd_banner";

  # `--tpm2-pcrs=` wants a comma-joined list; `ru.tpm2.pcrs` is the
  # nixboot-side option a composing module (e.g. nixnas's `crypto.tpm2.pcrs`)
  # feeds a value into -- see that option's doc for why this is NOT
  # necessarily the same PCR set as the data-unlock policy.
  tpm2PcrsArg = lib.concatMapStringsSep "," toString ru.tpm2.pcrs;

  # ── nixboot-enroll-sb: the operator-run firmware key enrollment ─────────
  # Bound here, rather than inline at its `environment.systemPackages` call
  # site, so it can ALSO be exposed as `system.build.nixbootEnrollSb` below --
  # the same "expose the derivation, not just the installed binary" shape
  # `extraEntries.nix` already uses for `system.build.extraEntryMaintainers`
  # and `system.build.nixbootRegisterBootEntry`. Without a `system.build.*`
  # handle, nothing but a live host with `secureBoot.enrollTool.enable &&
  # secureBoot.enable` ever forces this derivation, so `nix flake check`
  # alone could not catch a shellcheck regression in it.
  enrollSb =
    let
      # EVAL SAFETY, the same technique `extra-entries.nix`'s own `dbKeyDir`
      # uses (see its comment): `secureBoot.pkiBundle` is legitimately `null`
      # whenever `secureBoot.enable = false` (its type is `nullOr str`, no
      # default), and this derivation is now built UNCONDITIONALLY (exposed
      # as `system.build.nixbootEnrollSb` regardless of `secureBoot.enable`,
      # so `nix flake check` forces + shellchecks it on every fixture, not
      # just ones that turn Secure Boot on). Interpolating a `null` straight
      # into a Nix string throws "cannot coerce null to a string" at
      # DERIVATION-CONSTRUCTION time, not merely at runtime.
      # A poison placeholder keeps construction eval-safe either way; the
      # real enforcement stays the runtime `[ -z "$pki" ]` check below, which
      # still fires exactly the same friendly message on a genuinely-unset
      # bundle at a host that actually runs this tool.
      pkiBundleArg =
        if cfg.secureBoot.pkiBundle != null
        then cfg.secureBoot.pkiBundle
        else "";
      # `opromPolicy` is resolved at NIX eval time (a plain enum string, never a
      # shell-runtime variable) -- computed here as a Nix-level mapping rather
      # than as a shell `case` branching on an already-known-at-build-time
      # literal. A `case "${...}"` over a Nix constant is not just redundant,
      # it is a genuine shellcheck finding (SC2194, "this word is constant").
      opromFlag = {
        "tpm-eventlog" = "--tpm-eventlog";
        "microsoft" = "--microsoft";
        "none" = "";
      }.${cfg.secureBoot.opromPolicy};
    in
    pkgs.writeShellApplication {
      name = "nixboot-enroll-sb";
      runtimeInputs = [
        pkgs.sbctl
        pkgs.util-linux
        pkgs.coreutils
      ];
      text = ''
        set -euo pipefail

        pki="${pkiBundleArg}"
        if [ -z "$pki" ]; then
          echo "nixboot-enroll-sb: nixboot.secureBoot.pkiBundle is not set." >&2
          exit 1
        fi

        # Readability check BEFORE touching firmware state, with a guided message: a bundle
        # path that resolves but whose key material was never actually staged (a fresh keydir
        # before generate-sb-keys / the TUI's own staging step has run) otherwise reaches
        # `sbctl enroll-keys` and fails with a raw, unexplained sbctl error instead of naming
        # the real cause.
        if [ ! -r "$pki/keys/db/db.key" ]; then
          echo "nixboot-enroll-sb: no Secure Boot key material at $pki/keys/db/db.key." >&2
          echo "  A stable-keyed host stages its PKI bundle onto this path BEFORE first boot" >&2
          echo "  (e.g. a build-machine step materialising sops-encrypted keys); an" >&2
          echo "  autogenerate host's own generate-sb-keys.service creates it on first boot" >&2
          echo "  instead -- if that unit exists and has not run yet, this is expected until" >&2
          echo "  it does. Either way, there is nothing to enroll yet." >&2
          exit 1
        fi

        # Firmware must be in Setup Mode (PK cleared) before enrollment.
        # SetupMode is efivarfs byte offset 4 -- bytes 0-3 are the
        # variable's attributes flag, not part of the value.
        setupmode_var="/sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c"
        if [ ! -r "$setupmode_var" ]; then
          echo "nixboot-enroll-sb: cannot read $setupmode_var -- not a UEFI system, or efivarfs is not mounted." >&2
          exit 1
        fi
        setupmode() { od -An -tu1 -j4 -N1 "$setupmode_var" | tr -d '[:space:]'; }
        if [ "$(setupmode)" != "1" ]; then
          echo "nixboot-enroll-sb: firmware is NOT in Setup Mode (SetupMode=$(setupmode)). Clear the platform key (PK) from the UEFI setup menu first, then re-run this." >&2
          exit 1
        fi

        # sbctl needs a stable owner GUID; mint one into the bundle once
        # so re-enrollment (e.g. after a key rotation) is idempotent.
        if [ ! -s "$pki/GUID" ]; then
          uuidgen > "$pki/GUID"
        fi

        # Stage the bundle where sbctl looks by default, independent of
        # sbctlCompat's /etc/sbctl/sbctl.conf redirect -- this mirrors
        # what nixnas's original enrollment script did and is the path
        # actually exercised at enrollment time.
        install -d -m 0700 /var/lib/sbctl
        cp -a "$pki/keys" /var/lib/sbctl/keys
        cp -a "$pki/GUID" /var/lib/sbctl/GUID

        sbctl enroll-keys --disable-landlock ${opromFlag}

        # VERIFY, don't just hope: re-read SetupMode after enrollment and say what firmware
        # actually reports, rather than a static "you're done" regardless of outcome. Ported
        # from the nixnas appliance's own tool (field-proven 2026-07-04 caveat): many boards
        # keep REPORTING SetupMode=1 until the NEXT reboot even after a successful enrollment
        # -- the efivar is latched. That is a note, not a failure; sbctl's own exit status
        # above already aborted this script on a real failure.
        if [ "$(setupmode)" = "0" ]; then
          echo "nixboot-enroll-sb: firmware left Setup Mode -- keys are live."
        else
          echo "nixboot-enroll-sb: NOTE: SetupMode still reads 1. Many boards latch the reported value until the next reboot (field-proven); sbctl succeeded above, so proceed."
        fi

        echo "nixboot-enroll-sb: enrollment complete."
        echo "PCR 7 changes ONCE, right now -- any TPM-sealed secret (e.g. an initrd unlock key) sealed BEFORE this enrollment will need to be re-sealed AFTER it, or it will fail to unseal on the next boot."
        echo "Some boards latch SetupMode=1 in the efivar until the next reboot even though enrollment succeeded -- trust sbctl's exit status above, not a lingering SetupMode=1."
        echo "Next: reboot; verify with \`bootctl status\` (expect \"Secure Boot: enabled (user)\"); then set the firmware ADMIN PASSWORD -- without it, an evil maid can simply re-enter Setup Mode and swap the keys, undoing all of this."
      '';
    };
in
{
  options.nixboot = {
    enable = lib.mkEnableOption "nixboot: one declarative boot stance for this host, firmware handoff through to switch-root";

    ## ── Loader ────────────────────────────────────────────────────────────
    loader = {
      program = lib.mkOption {
        type = lib.types.enum [ "systemd-boot" "lanzaboote" "limine" "none" ];
        # NO default -- every enabled host must answer this in its own file.
        description = ''
          Which program owns this ESP? "lanzaboote" hands installation to
          lzbt and disables systemd-boot's own installer (they fight over
          the same ESP otherwise -- both would try to write loader.conf and
          the type-1/UKI entries). "none" is for hosts with no firmware of
          their own to hand off to, such as an LXC container.

          "limine" hands installation to `boot.loader.limine` (a stock
          nixpkgs module, unlike lanzaboote -- see this file's own "ONE
          EXTERNAL DEPENDENCY" header note for why that composition
          question does not even arise here). Its Secure Boot model is
          CATEGORICALLY different from lanzaboote's: instead of signing
          each generation's own UKI stub, limine signs the LOADER BINARY
          once and enrolls a BLAKE2b hash of the ENTIRE rendered
          limine.conf into it (`limine enroll-config`) -- a whole-config
          trust boundary, not a per-generation one. Because that model
          shares no mechanism with `secureBoot.*` (built entirely around
          sbctl + per-UKI lanzaboote signing) or `bootCounting.tries`
          (decremented by the lanzaboote stub specifically), both are
          asserted to require `loader.program == "lanzaboote"` and are
          therefore REFUSED outright on a limine host, below -- rather
          than silently doing something that looks similar but is not the
          same guarantee. `loader.graceful`, `loader.selfHeal` and
          `loader.consoleMode` are asserted off here too: all three are
          wired straight into `boot.loader.systemd-boot.*`/`bootctl`,
          which limine never touches (see each option's own doc).

          Also load-bearing: limine's own config file search order is
          FIXED and not configurable -- of the two paths this module knows
          about, `<esp.mountPoint>/limine/limine.conf` wins over
          `<esp.mountPoint>/limine.conf`, and whichever loses is ignored
          SILENTLY, not reported as a conflict. `nixboot-verify`'s Check 1
          places nixpkgs' own installer output at the winning path (it
          already does, unprompted) and separately WARNs if the losing,
          shadowed path also exists -- inert today, but it would become the
          ACTIVE config the moment the winning file ever goes missing, with
          zero warning from limine itself. The system-manager backend
          (modules/system-manager-limine.nix, for hosts with no `boot.*` at
          all) hits the exact same trap and applies the same rule.
        '';
      };

      timeout = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "How many seconds does the menu wait for a human before booting the default entry? null = don't manage. A 1-second flash is unusable for reaching the rollback menu; nixnas chose 5.";
      };

      editor = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "May someone at the console edit the kernel command line from the boot menu? NixOS defaults this true. Harmless under a signed UKI (the stub ignores an externally supplied cmdline) but loose posture on a host whose whole point is operator-owned keys -- turn it off there.";
      };

      consoleMode = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "0" "1" "2" "auto" "max" "keep" ]);
        default = null;
        description = ''
          Which UEFI console resolution does the boot menu render at? null
          = don't manage. Writes `boot.loader.systemd-boot.consoleMode` --
          a systemd-boot/lanzaboote-only option (asserted below to require
          `loader.program` be one of those two). limine has its own,
          differently-shaped menu-resolution knob
          (`boot.loader.limine.style.interface.resolution`, a raw
          "WIDTHxHEIGHT" string, not this enum) that this option does not
          attempt to drive -- setting consoleMode on a limine host would
          write into `systemd-boot.consoleMode`, which limine never reads,
          exactly the silent no-op this module exists to refuse.
        '';
      };

      efiVariables = lib.mkOption {
        type = lib.types.enum [ "write" "removable" ];
        # NO default -- see the description for why guessing wrong is an outage.
        description = ''
          Does firmware get an NVRAM boot entry for this host, or does it
          rely on the removable-media fallback path \EFI\BOOT\BOOTX64.EFI?
          Named for the decision itself, not for the underlying
          `boot.loader.efi.canTouchEfiVariables`, because that option's
          name hides the real incident it can cause: "write" on a box that
          only ever boots via the fallback path makes `bootctl status`
          return non-zero, which aborts the bootloader-install step of
          EVERY switch-to-configuration. "removable" is also what lets a
          nixnas rescue stick boot on any spare box regardless of what is
          already in that box's NVRAM.
        '';
      };

      graceful = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Should a bootloader-install failure during switch-to-configuration
          be a warning instead of aborting the switch? Kept separate from
          efiVariables on purpose -- a PULL-only host with no console to fix
          a stuck switch needs both, but they answer different questions
          and a host can legitimately want only one. Writes
          `boot.loader.systemd-boot.graceful` -- systemd-boot/lanzaboote
          only (asserted below): limine's own installer
          (`limine-install.py`, shipped by nixpkgs) has no equivalent
          "warn instead of abort" flag to wire this into.
        '';
      };

      selfHeal = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Does this host's ESP arrive without ever having run `bootctl
          install` -- a VM-less repart-baked image whose disk was written
          by a build step, not by a live NixOS activation? Every boot must
          then re-assert the install. When true this ships a oneshot
          running `bootctl --esp-path=<esp.mountPoint> --no-variables
          --graceful install`, `SuccessExitStatus = "0 1"`, guarded by
          `ConditionPathIsMountPoint=<esp.mountPoint>` so it is a no-op
          before the ESP is mounted rather than a boot-blocking failure.

          Hardcodes `bootctl` -- systemd-boot/lanzaboote only (asserted
          below). Running `bootctl install` against an ESP limine owns
          would not merely no-op: it would write systemd-boot's OWN
          `\EFI\systemd\systemd-bootx64.efi` and `loader.conf` onto that
          ESP, actively contending with whatever limine already placed
          there for the removable/NVRAM boot path -- the exact
          two-managers-one-knob failure this whole module exists to
          prevent, not a merely inert setting.
        '';
      };
    };

    ## ── Console (the `console=` kernel command line -- NOT the UEFI boot
    ## menu's loader.consoleMode above; that picks the menu's resolution,
    ## this picks /dev/console) ─────────────────────────────────────────────
    console = {
      primary = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "video" "serial" ]);
        default = null;
        description = ''
          Which console becomes `/dev/console` -- i.e. which `console=`
          kernel parameter is LAST on the command line? null = don't manage,
          leave `boot.kernelParams`'s console= entries to whatever else (or
          nothing) sets them.

          Dropping a console= entry to demote it, instead of reordering,
          would silence that console's kernel log, getty, and
          password-agent prompt EVERYWHERE, not just stop it from being
          primary -- this option only ever reorders, never drops (see the
          config-side comment where the list is built).

            "video": `tty0` last -- the attached DISPLAY is `/dev/console`.
              Boot status messages, the emergency shell, and any
              interactive prompt (e.g. a LUKS passphrase, if the host's own
              crypto config wires one into the initrd) land on the monitor.
              Right for a human at the machine with a monitor + keyboard and
              no IPMI.

            "serial": console.serialDevice last -- the SERIAL port is
              `/dev/console`. For headless boxes administered over
              IPMI-SOL/BMC serial, and for a QEMU CI suite that observes the
              VM only through the serial port.

          Left nullable rather than given a default (unlike nixnas, which
          always defaults to "video"): nixboot targets hosts generically,
          and unlike the appliance this was ported from, it has no way to
          know a given host even HAS a console worth arbitrating. Where it
          IS wrong, the failure is silent, not loud -- a "video"-primary box
          with nobody at its monitor loses whatever prompt lands on
          `/dev/console` with no error -- the same class of footgun
          `loader.program` and `loader.efiVariables` above answer by
          refusing a default; this option answers it by refusing to guess
          that the host wants console management at all.
        '';
      };

      serialDevice = lib.mkOption {
        type = lib.types.str;
        default = "ttyS0";
        description = ''
          Which serial tty device is the "serial" half of console.primary's
          `console=` pair? Only read when console.primary != null. Default
          `ttyS0` is the first legacy UART -- what IPMI-SOL/BMC serial
          redirection and QEMU's `-serial` both present by default.
        '';
      };

      serialBaud = lib.mkOption {
        type = lib.types.ints.positive;
        default = 115200;
        description = ''
          Baud rate for console.serialDevice. Only read when console.primary
          != null. Default 115200 is the SOL/BMC and QEMU default rate.
          Changing it without also changing the far end (BMC config,
          `qemu -serial`, a physical null-modem's own setting) turns the
          console into line noise, not a slower prompt.
        '';
      };
    };

    ## ── ESP (declared, never created -- nixboot does not partition) ────────
    #
    # nixboot OWNS the ESP as a boot concern -- what must be on it, that its label and
    # capacity are what this host expects, that foreign paths survive GC. It does NOT own
    # the ESP as a PARTITION: size, label and position are storage shape, and nixstorage's
    # layout is where a medium is carved.
    #
    # THOSE TWO FACTS USED TO BE TYPED SEPARATELY, AND IT NEARLY COST A STICK. Three repos
    # each carried an ESP fact with no edge between them -- nixnas.boot.usb.espSizeMiB said
    # 2048 MiB, nixstorage's layout said 512, nixboot asserted its own capacityMiB, and
    # nothing compared any of them. Re-flashing from the wrong one would have replaced a
    # 5-partition medium with a 2-partition one, destroying three rescue slots and a vault,
    # with every declaration still looking locally correct.
    #
    # So byLabel and capacityMiB now DEFAULT to whatever nixstorage's layout declares for
    # this host's ESP, read DEFENSIVELY (`config.nixstorage.layout … or null`) exactly as
    # nixstorage itself reads nixiam -- so importing nixboot without nixstorage keeps
    # working, and a host that carves its medium elsewhere can still state these by hand.
    # nixboot does not import nixstorage and never will; it only reads a value if one is
    # there. The direction is fixed: BOOT reads STORAGE, never the reverse.
    esp = {
      mountPoint = lib.mkOption {
        type = lib.types.str;
        default = "/boot";
        description = "Where is the ESP mounted? nixboot never mounts it -- this is only the path its own units and nixboot-verify read.";
      };

      fromLayout = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "nixnas-stick";
        description = ''
          Name of the `nixstorage.layout.images.<name>` describing the medium this host's
          ESP lives on. When set, `byLabel` and `capacityMiB` default to whatever that
          layout declares for its `esp`-role partition, instead of being restated here.

          Which image describes THIS host cannot be inferred -- a host may declare several
          (its own stick, plus another machine's rescue medium it builds images for) -- so
          it is named rather than guessed.

          Leave null on a host whose medium is carved by something other than nixstorage;
          the two options below then behave exactly as before. nixboot never imports
          nixstorage and reads it defensively, so this is inert if nixstorage is absent.
        '';
      };

      byLabel = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        # Derived from the layout when esp.fromLayout names one -- see the block header.
        default = if espSourcePart == null then null else (espSourcePart.espLabel or null);
        defaultText = lib.literalExpression "the esp partition's espLabel from esp.fromLayout, else null";
        description = "Which FAT label must the filesystem at esp.mountPoint carry? Assert/verify only -- never used to mount anything. On a host whose ESP is not placed by disko (e.g. the appliance MAIN never runs disko), any other FAT volume labelled the same is a boot-time coin flip nixboot-verify exists to catch.";
      };

      capacityMiB = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = if espSourcePart == null then null else (espSourcePart.sizeMiB or null);
        defaultText = lib.literalExpression "the esp partition's sizeMiB from esp.fromLayout, else null";
        description = "How big is this ESP, so nixboot can warn before it overflows? Declared, never enforced -- resizing an ESP is an image reprovision, not something a deploy can do, so nixboot only ever warns loudly and lets a human schedule the reprovision.";
      };

      foreignPaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Which paths on this ESP, relative to esp.mountPoint, belong to someone else and must never be touched or garbage-collected by nixboot or its loader? For example a vendor firmware-update capsule tree, fwupd's own loader entry, or a rescue-media directory. nixboot-verify checks each one still exists.";
      };
    };

    ## ── Media: is the boot device fixed internal storage, or a USB stick
    ## that might be plugged into any spare box? DELIBERATELY independent of
    ## `cfg.enable` -- see the config-side comment on `media.usb` below for
    ## why, and `extraEntries.*` for the one other surface in this module
    ## with the same shape.
    media = {
      usb.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Does the initrd need to find and drive a USB-ATTACHED storage
          device before ANY root filesystem exists -- because the boot
          device (and, usually, the whole OS store) is a USB stick rather
          than storage fixed inside the machine? When true, nixboot adds
          the kernel modules early userspace needs to even SEE such a
          device to `boot.initrd.availableKernelModules`: `usb_storage`,
          `uas`, and the two common USB host-controller drivers --
          `xhci_pci` (USB 3) and `ehci_pci` (USB 2). Without them the
          stage-1 boot hangs waiting for a root device it can never see,
          since only what THIS list names ships in the initrd (the full
          stage-2 module tree is not available yet).

          DELIBERATELY INDEPENDENT of `loader.efiVariables`: a stick can
          rely on the removable-media EFI fallback path while the initrd
          it boots reads from FIXED storage once switch-root happens (an
          appliance image meant to be portable but with its real store
          elsewhere), and a USB-attached device can legitimately keep
          `efiVariables = "write"` if it is a dongle permanently wired
          into one specific machine and never swapped. nixboot does not
          derive one from the other -- it only warns when the common,
          field-proven combination (`media.usb.enable = true` with
          `loader.efiVariables = "write"`) looks like a host that forgot
          to say "removable" (see the warnings list, below).

          The SIZE of the stick, its partition layout, and the filesystem
          the store itself uses are NOT this option's business -- those
          stay with whoever lays out the disk (a disk-layout tool's own
          geometry options); this option only ever answers "can the
          initrd SEE a USB device at all".
        '';
      };
    };

    ## ── Generations / rollback ──────────────────────────────────────────────
    generations.keep = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8;
      description = ''
        How many past systems stay bootable from the menu? This is the
        GUARANTEED manual rollback path, so it must exceed the number of
        generations this host can build in one uptime -- a host that
        rebuilds faster than this drains generations it is currently
        running off of, out of the menu, before anyone would need to use
        it. That is a real, previously-shipped bug, not a hypothetical:
        at `keep = 5` and roughly 10 generations/day, the running system
        left the boot menu within hours.
      '';
    };

    bootCounting.tries = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = ''
        How many boots does a fresh generation get before the loader
        judges it bad and falls back to the previous one? null = no
        counting. This is a lanzaboote-stub-only mechanism (the stub is
        what decrements the `+N` suffix and hands off to
        systemd-bless-boot / boot-complete.target) -- ASSERTED to require
        `loader.program = "lanzaboote"` rather than silently doing
        nothing on any other loader, which is exactly the kind of "setting
        requested, quietly not applied" bug this whole module exists to
        stop turning up as an unexplained gap.
      '';
    };

    ## ── Secure Boot ─────────────────────────────────────────────────────────
    secureBoot = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Are this host's boot images signed with operator-owned keys and verified by firmware, instead of relying on Microsoft's shipped keys or no verification at all?";
      };

      pkiBundle = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Where on this host does the sbctl PKI (the PK/KEK/db key and
          certificate tree) live? Must be on storage that survives a
          tmpfs root. nixboot consumes a PATH and is deliberately
          agnostic about how the bundle got there -- decrypting a sops
          secret or injecting one at image-build time is a secrets/build
          concern, not a boot option.
        '';
      };

      keySource = lib.mkOption {
        type = lib.types.enum [ "stable" "autogenerate" ];
        default = "stable";
        description = ''
          Did an operator supply a stable, durable key set (pkiBundle),
          or may this host mint its own the first time it boots?
          Replaces an implicit "is pkiBundle set" inference with a
          decision that is stated, not guessed at. "autogenerate" implies
          the host trusts whatever key it happens to generate first --
          fine for a throwaway or single-purpose box, wrong for anything
          that needs its enrollment to survive a reinstall.
        '';
      };

      opromPolicy = lib.mkOption {
        type = lib.types.enum [ "tpm-eventlog" "microsoft" "none" ];
        default = "tpm-eventlog";
        description = ''
          Which option-ROM allowance does firmware key enrollment make?
          Passed straight through to `sbctl enroll-keys` as
          `--tpm-eventlog`, `--microsoft`, or no flag at all for "none".
          "none" can leave a board unable to POST if it has an add-in
          card whose option ROM sbctl would otherwise have permitted --
          nixboot deliberately never passes sbctl's own
          `--yes-this-might-brick-my-machine` override to work around
          that; if "none" is genuinely wrong for a board, the fix is to
          pick a different value, not to force through the refusal.
        '';
      };

      enrollTool.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Does this host carry the operator-run firmware enrollment
          command (`nixboot-enroll-sb`)? Deliberately never a systemd
          unit and never wired to run automatically: firmware NVRAM is
          the one piece of state nixboot cannot roll back, so enrollment
          only ever happens because a human, at the machine, ran the
          command while firmware Setup Mode was on.
        '';
      };

      sbctlCompat = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Can a bare `sbctl status` / `sbctl verify` run on this box and
          actually find the PKI, rather than reporting "not installed"?
          Writes /etc/sbctl/sbctl.conf pointing at secureBoot.pkiBundle.
          Fixes a live wart: lanzaboote only writes that file on KEYLESS
          (autogenerate) hosts, so on a "stable"-keyed host `sbctl status`
          reports not-installed and `sbctl verify` fails on every ESP
          file for a pure configuration reason, not a real signature
          problem -- and nixboot-verify cannot check real signatures
          until this file exists and is correct.
        '';
      };
    };

    ## ── Remote unlock (initrd SSH for a headless in-initrd secret prompt) ──
    ## nixnas hangs this off its own `crypto.tpm2.enable`; nixboot has no
    ## such option of its own -- see remoteUnlock.tpm2.* for how the
    ## boundary is drawn.
    remoteUnlock = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Does this host need an in-initrd secret prompt (a LUKS
          passphrase/PIN, most commonly) answered over SSH, because
          nobody can type it at a console? Brings a NIC up in the initrd
          and runs sshd there: `ssh root@<host>` (a key in
          `remoteUnlock.authorizedKeys`) and hand the secret to systemd's
          own password agent, then boot proceeds. Off by default -- unlike
          nixnas, where this is mandatory because the appliance is ALWAYS
          headless, nixboot targets hosts generically and has no way to
          know a given host even blocks on an initrd secret in the first
          place. Where IPMI-SOL or a physical console covers the unlock
          instead, leave this off.
        '';
      };

      authorizedKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          SSH public keys allowed to answer the initrd prompt. A
          DELIBERATELY SEPARATE list from any running-system sshd config
          this host declares elsewhere: nixboot does not own the running
          system's admin/auth surface any more than it owns kernel
          packaging (see the header SCOPE note) -- whoever composes
          nixboot alongside their own `services.openssh` /
          `users.users.root.openssh.authorizedKeys` is responsible for
          keeping the two lists in sync BY HAND, if that is even the
          intent (nixnas instead reuses ONE list, `nixnas.admin.authorizedKeys`,
          for both, because nixnas, unlike nixboot, already owns that whole
          admin surface). Initrd sshd is
          key-only; leaving this empty while `remoteUnlock.enable = true`
          means literally nothing can ever answer the prompt over the
          network, asserted below.
        '';
      };

      sealHostKey = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Does the initrd-SSH host key ride as a TPM2-sealed systemd
          CREDENTIAL instead of a plaintext key baked into the initrd at
          build time? On first boot the key is generated and sealed
          (the `nixboot-seal-hostkey` service, below, stage 2); on every
          later boot the lanzaboote stub delivers the sealed credential
          straight into the initrd and sshd itself unseals it during
          credential activation -- no bespoke unseal service, systemd
          does the unwrap. A tampered boot chain (a PCR 7 mismatch) cannot
          recover the plaintext key, so a stolen stick cannot impersonate
          this host's unlock prompt to phish the real secret out of an
          operator who trusts the fingerprint.

          REQUIRES `secureBoot.enable` -- asserted below, not left to fail
          quietly -- because only the lanzaboote (UKI) stub scans the
          ESP's `\loader\credentials\*.cred` drop-in and packs it into the
          initrd; plain systemd-boot boots kernel+initrd directly, so the
          sealed credential would simply never arrive and every single
          boot (not just the first) would fall back to a freshly
          generated EPHEMERAL key -- a DIFFERENT fingerprint every time,
          never pinnable, defeating the entire point of a stable host
          identity. Also folds in `remoteUnlock.tpm2.enable` (this module
          reads, not owns, whether a TPM2 is even present -- see below);
          with either half false, this whole path is inactive and
          `hostKeyPath` becomes required instead (also asserted).

          Set false to use a fixed plaintext key at `hostKeyPath`
          (LAN/tailnet-only: it lands on the plaintext ESP).
        '';
      };

      hostKeyPath = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Plaintext initrd-SSH host key (a BUILD-MACHINE Nix path), used
          only when `sealHostKey = false` -- no TPM2 on this board, or an
          operator who deliberately wants a fixed, offline-inspectable
          key instead of a sealed one. Embedded in the initrd at build
          time and landed on the plaintext ESP inside the signed (or
          unsigned) UKI, hence LAN/tailnet-only: anyone who reads the ESP
          reads this key. Ignored while `sealHostKey = true` (the
          default).
        '';
      };

      tpm2 = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          # NO default worth guessing beyond false -- see the NOT note in
          # the header SCOPE comment: this mirrors, and is fed by, a real
          # TPM2 policy owned elsewhere (nixnas's `crypto.tpm2.enable`).
          description = ''
            Does a TPM2 chip actually back this host, for the purpose of
            sealing the initrd-SSH host key? nixboot does NOT own TPM2
            configuration -- the real enable/pcrs/device policy for the
            DATA unlock is a disk-layout+crypto concern that stays with
            whoever declares it (e.g. nixnas's `crypto.tpm2.enable`). This
            option exists ONLY so `sealHostKey` has something honest to read instead of
            inventing its own TPM2 detection: set it to the SAME value as
            that real policy's own enable flag. This is the boundary the
            header SCOPE note promises -- nixboot READS a TPM2
            configuration here, it never re-declares one. Left false
            while `sealHostKey = true` (the default) is not an error by
            itself: sealing is simply inactive (see `sealHostKey`'s own
            "folds in" note), and `hostKeyPath` becomes the required
            fallback, exactly as on a board with no TPM2 at all.

            The host-key seal and the DATA unlock's own TPM2 policy are
            otherwise UNRELATED cryptographic operations that merely
            happen to share one physical chip: the host key uses
            `--with-key=auto-initrd` (TPM2-only key derivation, no PIN,
            because the initrd has no `/var` credential secret to combine
            it with), while the data keyslot may additionally require a
            PIN every boot (`crypto.tpm2.requirePin`). Do not assume
            enabling one says anything about the PIN policy of the other.
          '';
        };

        pcrs = lib.mkOption {
          type = lib.types.listOf lib.types.ints.unsigned;
          default = [ 7 ];
          description = ''
            Which TPM2 PCRs the initrd-SSH host-key seal is bound to,
            passed straight through as `--tpm2-pcrs=` to `systemd-creds
            encrypt` / `decrypt`. The default, PCR 7 (Secure Boot state),
            is what the self-healing reseal logic in
            `nixboot-seal-hostkey` (below) is WRITTEN AGAINST: PCR 7 is
            stable across kernel/UKI updates but changes EXACTLY ONCE, at
            Secure Boot key enrollment (`nixboot-enroll-sb`), and the
            whole self-test-then-reseal design exists to survive that one
            change cleanly without a stale credential permanently
            bricking the unlock path (see the incident this whole
            self-heal exists to prevent, cited on `nixboot-seal-hostkey`
            below). Pointing this at a different PCR set is mechanically
            supported, but the "changes once, at enrollment" reasoning
            throughout this file is specifically about PCR 7 -- verify it
            still holds for whatever set you pick.

            This is a SEPARATE seal from any TPM2 policy guarding the
            DATA unlock (nixnas's `crypto.tpm2.pcrs`, also defaults `[ 7 ]`
            but is independently configurable there) -- nixnas itself never
            reads that option for the host-key seal either, it hardcodes
            `--tpm2-pcrs=7`. The two seals are structurally decoupled (a
            systemd credential vs. a LUKS keyslot) and nixboot does not assert they agree;
            whatever composes nixboot alongside a real TPM2-backed data
            unlock is responsible for deciding whether they SHOULD.
          '';
        };

        device = lib.mkOption {
          type = lib.types.str;
          default = "auto";
          description = ''
            The `--tpm2-device=` value passed to `systemd-creds
            encrypt`/`decrypt` when sealing or verifying the initrd-SSH
            host key. `auto` picks the one TPM2 device present -- true of
            every host this was evidenced against; override only for a
            multi-TPM or TPM-passthrough setup where more than one device
            could otherwise match.
          '';
        };
      };
    };

    ## ── Tools (per-tool, sibling hardware-power module shape -- no lumped
    ## tools.enable) ─────────────────────────────────────────────────────
    ## Deliberately not a single toggle: a host that wants signature CLIs
    ## should not silently acquire an NVRAM-backup tool it never asked for,
    ## and "which tool is on this box, and why" should be readable straight
    ## from the host file, the same discipline that sibling module states.
    tools = {
      sbctl.enable = lib.mkOption {
        type = lib.types.bool;
        default = cfg.secureBoot.enable;
        description = "Is the sbctl key/enrollment/signature-status CLI on PATH? Defaults to secureBoot.enable, since sbctlCompat's whole point is a working `sbctl status` on this box -- override to false only to strip the tool while keeping the config file nixboot-verify can still fail loudly against.";
      };

      efitools.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Is `efi-readvar` on PATH, to back up the current PK/KEK/db/dbx
          before a vendor BIOS flash? Worth turning on for any board whose
          vendor update tooling reprograms NVRAM wholesale -- GIGABYTE's
          F21 AFU update scripts, for example, pass `/n` (program NVRAM),
          which should be treated as "enrollment wiped", not merely
          "enrollment at risk".
        '';
      };

      sbsigntool.enable = lib.mkOption {
        type = lib.types.bool;
        default = cfg.secureBoot.enable;
        description = "Is `sbsign`/`sbverify` on PATH? `sbverify --cert <pkiBundle>/keys/db/db.pem <file>` is the only way to hand-check a signature nixboot-verify already checked programmatically, and it is the tool any future extraEntries-style UKI signing would shell out to -- kept separate from tools.sbctl because sbctl's own signing path and a bare sbsigntool check answer different questions when they disagree.";
      };
    };

    ## ── Verify ───────────────────────────────────────────────────────────
    verify.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run nixboot-verify after boot: read every managed boot knob back
        from the live system and log PASS/FAIL/SKIP per knob. Exists for
        the same reason nixpower-verify does, with a sharper edge here --
        requesting a boot setting is not evidence it took, and in this
        domain the evidence for a wrong setting often only appears at the
        NEXT boot, by which point the box may not come back up at all.
      '';
    };
  };

  config = lib.mkMerge [
    # ── media.usb: DELIBERATELY independent of `cfg.enable` ─────────────────
    # A consumer who wants nixboot to own its WHOLE boot stance sets
    # `nixboot.enable = true` and gets everything below this block. A
    # consumer who already owns its own loader/Secure Boot/remote-unlock
    # wiring (the exact position a sibling appliance distribution's own
    # boot glue is in today) should not have to take all of that on just to
    # reuse this ONE mechanism -- so it is wired unconditionally, the same
    # shape `extraEntries.nix` already uses for its own unconditionally-
    # exposed `system.build.extraEntryMaintainers` (see that file's header).
    # `boot.initrd.availableKernelModules` is a list-type option that
    # MERGES across every module that contributes to it, so this needs no
    # priority discipline the way the `boot.loader.*` writes further down
    # do -- it can never collide with a host's own list, only add to it.
    {
      boot.initrd.availableKernelModules = lib.mkIf cfg.media.usb.enable [
        "usb_storage"
        "uas"
        "xhci_pci"
        "ehci_pci"
      ];
    }

    (lib.mkIf cfg.enable (lib.mkMerge [
      {
        assertions = [
          {
            assertion = cfg.bootCounting.tries == null || cfg.loader.program == "lanzaboote";
            message = "nixboot.bootCounting.tries is set but loader.program != \"lanzaboote\" -- boot counting is a lanzaboote-stub-only mechanism (it is the lanzaboote stub that decrements the +N suffix) and would silently do nothing on any other loader, including limine, which has no such counter at all. Either drop bootCounting.tries or switch loader.program.";
          }
          {
            # limine's own Secure Boot model (sign the LOADER once, enroll a hash of the whole
            # rendered config -- see loader.program's own doc) shares no mechanism with this
            # subsystem, which is built entirely around per-UKI lanzaboote signing + sbctl. Reusing
            # secureBoot.enable for limine would silently promise a guarantee (per-generation signed
            # boot) it cannot deliver under that model -- refused outright rather than half-applied.
            assertion = !cfg.secureBoot.enable || (cfg.loader.program == "lanzaboote" && cfg.secureBoot.pkiBundle != null);
            message = "nixboot.secureBoot.enable = true requires loader.program = \"lanzaboote\" (the only loader that signs and verifies what it boots) and secureBoot.pkiBundle set (a signed chain with nowhere to keep its keys is not a real chain). limine's own Secure Boot model (whole-config-hash enrollment, not per-generation signing) is a different mechanism this subsystem does not cover -- see nixboot.limine.enrollConfig on the system-manager backend, or boot.loader.limine.secureBoot.* directly on a NixOS host.";
          }
          {
            # See loader.consoleMode/graceful/selfHeal's own option docs for exactly what each
            # writes and why limine has no equivalent to write it into. Grouped as one assertion
            # (rather than three) because all three fail for the identical reason: a systemd-boot/
            # bootctl-shaped knob has no meaning outside that family, and "requested but ignored" is
            # precisely the bug class this module exists to refuse, not merely the lanzaboote-only
            # mechanisms above.
            assertion = isSystemdBootFamily || (cfg.loader.consoleMode == null && !cfg.loader.graceful && !cfg.loader.selfHeal);
            message = "nixboot.loader.consoleMode / .graceful / .selfHeal are systemd-boot/lanzaboote-only (they write boot.loader.systemd-boot.* or hardcode bootctl) but loader.program = \"${cfg.loader.program}\". Drop whichever of consoleMode/graceful/selfHeal is set, or switch loader.program to \"systemd-boot\" or \"lanzaboote\".";
          }
          {
            # Enabling the surface with NEITHER a working seal path NOR a
            # plaintext fallback leaves the initrd with no host key at
            # all, not a graceful default -- sshd would come up keyless and
            # loop-crash ("no hostkeys available").
            assertion = !ru.enable || sealActive || ru.hostKeyPath != null;
            message = ''
              nixboot.remoteUnlock.enable is set but no initrd-SSH host key is configured. Either:
                - Set remoteUnlock.tpm2.enable = true to the SAME value as this host's real TPM2-backed
                  unlock policy (keeps sealHostKey = true, the default): the key is generated + sealed on
                  first boot, and every boot after that the initrd unseals it. The very first boot still
                  serves initrd-SSH -- with a loudly-flagged EPHEMERAL, RAM-only host key (fingerprint
                  changes once the sealed identity exists) -- no monitor or IPMI needed even on boot #1.
                - Or set remoteUnlock.sealHostKey = false and supply a plaintext key via
                  remoteUnlock.hostKeyPath (embedded in the initrd at build time, lands on the plaintext
                  ESP -- LAN/tailnet-only).
                - Or set remoteUnlock.enable = false if this host is unlocked over IPMI-SOL / a physical
                  console instead.
            '';
          }
          {
            # Path A's delivery vehicle is the LANZABOOTE stub: it is what scans
            # \loader\credentials\*.cred and packs the sealed key into the
            # initrd. Plain systemd-boot boots kernel+initrd directly -- no
            # stub, no credential, so the sealed key would never arrive and
            # EVERY boot (not just the first) would instead serve a fresh
            # ephemeral key with a bogus "first boot" banner. Fail the build
            # instead of shipping a permanently-unpinnable unlock channel.
            assertion = !sealActive || cfg.secureBoot.enable;
            message = ''
              nixboot.remoteUnlock.sealHostKey = true (the default) with remoteUnlock.tpm2.enable
              = true requires nixboot.secureBoot.enable: only the lanzaboote (UKI) stub delivers
              the TPM2-sealed host-key credential into the initrd. Enable secureBoot, or set
              remoteUnlock.sealHostKey = false with a plaintext hostKeyPath, or set remoteUnlock.tpm2.enable
              = false / remoteUnlock.enable = false.
            '';
          }
          {
            # SSH is key-only in the initrd, same as the running system's own
            # sshd -- an empty list here is a silently-inert remoteUnlock.enable,
            # exactly the "setting requested, quietly not applied" class of bug
            # this whole module exists to stop.
            assertion = !ru.enable || ru.authorizedKeys != [ ];
            message = "nixboot.remoteUnlock.enable is set but remoteUnlock.authorizedKeys is empty -- initrd sshd is key-only, so nothing could ever answer the unlock prompt over the network.";
          }
          {
            # THE GAP THIS CLOSES -- WIDER THAN IT FIRST LOOKS: it is tempting to
            # scope this to the sealed path only (Path A's `LoadCredentialEncrypted`
            # / credential-aware `preStart` / `boot.initrd.systemd.storePaths` do
            # live entirely under `boot.initrd.systemd.services.*`, a tree nixpkgs'
            # own systemd-initrd module only ever renders when
            # `config.boot.initrd.systemd.enable = true` -- verified against that
            # module's own `config = mkIf (config.boot.initrd.enable && cfg.enable)`
            # gate). But the COMMON block both paths share (just below) ALSO writes
            # `boot.initrd.systemd.network.enable = true` UNCONDITIONALLY, for
            # EITHER path -- and that option's own module
            # (nixos/modules/system/boot/resolved.nix) defaults
            # `boot.initrd.services.resolved.enable` to
            # `config.boot.initrd.systemd.network.enable`, which that same module
            # then asserts CANNOT be true without systemd stage 1 ("'boot.initrd.
            # services.resolved.enable' can only be enabled with systemd stage 1").
            # So `remoteUnlock.enable = true` ALONE -- Path A or Path B, sealed or
            # plaintext -- already fails to EVALUATE at all without
            # `boot.initrd.systemd.enable`, a fact this repo's own eval-tests
            # exposed (a first, narrower draft of this assertion that scoped only
            # to Path A left Path B's own fixture failing for an unrelated,
            # unasserted reason instead of a clear message). Refused HERE, with an
            # honest explanation, rather than left for nixpkgs' own unrelated
            # resolved.nix assertion to surface with no mention of remoteUnlock at
            # all.
            assertion = !ru.enable || config.boot.initrd.systemd.enable;
            message = ''
              nixboot.remoteUnlock.enable requires boot.initrd.systemd.enable = true. The
              common NIC/DHCP wiring this feature shares between both host-key paths writes
              boot.initrd.systemd.network.enable = true unconditionally, which nixpkgs' own
              resolved.nix then refuses outside systemd stage 1 -- and the sealed host-key
              path (sealHostKey = true, the default, with remoteUnlock.tpm2.enable = true)
              separately needs it for its systemd CREDENTIAL delivery
              (LoadCredentialEncrypted), which the classic (non-systemd) initrd builder
              silently discards instead of erroring. Set boot.initrd.systemd.enable = true
              (nixnas's own boot glue does this as a side effect of its LUKS TPM2 unlock
              wiring -- a host composing nixboot without nixnas must set it directly), or
              set remoteUnlock.enable = false
              if this host is unlocked over IPMI-SOL / a physical console instead.
            '';
          }
        ];

        warnings =
          lib.optional (cfg.esp.capacityMiB != null && espProjectedMiB * 100 > cfg.esp.capacityMiB * 75) ''
            nixboot: projected ESP usage is ~${toString espProjectedMiB} MiB (${toString cfg.generations.keep} kept generation(s) at a rounded-up 1 MiB/stub, plus a 100 MiB floor for two in-flight kernel versions) against a declared esp.capacityMiB = ${toString cfg.esp.capacityMiB}, over the 75% line. This is only an eval-time estimate -- nixboot-verify's headroom check reads the real number after boot -- but an ESP resize is an image reprovision, not a deploy, so this is worth planning for before it becomes a live "no space left on device" failure during switch-to-configuration.
          ''
          ++ lib.optional (cfg.secureBoot.sbctlCompat && !cfg.tools.sbctl.enable) ''
            nixboot: secureBoot.sbctlCompat writes /etc/sbctl/sbctl.conf, but tools.sbctl.enable is false, so the sbctl binary that file exists for is not installed on this host. Either turn tools.sbctl.enable on or drop sbctlCompat -- a config file for an absent tool is exactly the kind of setting-that-does-nothing this module exists to surface, not to ship quietly.
          ''
          ++ lib.optional (cfg.media.usb.enable && cfg.loader.efiVariables == "write") ''
            nixboot: media.usb.enable is set (the initrd is wired to find a USB-attached boot device) but loader.efiVariables = "write" -- firmware then gets an NVRAM entry pointing at THIS specific device path, so a stick meant to move between boxes stops booting reliably the moment it is plugged into a different one (or even the same one after a port change that renumbers the USB topology). Set loader.efiVariables = "removable" unless this device is permanently, physically fixed to one machine.
          '';

        boot.loader = lib.mkMerge [
          # nixboot never supports grub, on any host, regardless of loader.program
          # -- always disable it so it cannot win by default (base.nix's
          # `mkDefault true`) on a host that forgot to say so itself. mkOverride
          # 500, never mkForce: see the priority-discipline note at the top of
          # this file for exactly why.
          { grub.enable = lib.mkOverride 500 false; }

          # `boot.loader.efi.canTouchEfiVariables` is the one write every real loader
          # (systemd-boot, lanzaboote -- which never redefines it, and limine, which reads it
          # directly to default its own `efiInstallAsRemovable`) shares unmodified -- see
          # loader.efiVariables' own doc for the incident this exists to prevent.
          (lib.mkIf (cfg.loader.program != "none") {
            efi.canTouchEfiVariables = lib.mkOverride 500 (cfg.loader.efiVariables == "write");
          })
          (lib.mkIf (cfg.loader.program != "none" && cfg.loader.timeout != null) {
            # `boot.loader.timeout` is ALSO a shared top-level option, read by systemd-boot,
            # lanzaboote (via the same stub) and limine's own installer alike -- no per-family
            # branch needed here, unlike every other write in this block.
            timeout = lib.mkOverride 500 cfg.loader.timeout;
          })

          # ── systemd-boot / lanzaboote family: everything below writes into the
          # `systemd-boot.*` namespace, which limine never reads at all (see isSystemdBootFamily's
          # own binding comment, and loader.consoleMode/graceful/selfHeal's option docs) ──
          (lib.mkIf isSystemdBootFamily {
            systemd-boot.enable = lib.mkOverride 500 (cfg.loader.program == "systemd-boot");
            systemd-boot.editor = lib.mkOverride 500 cfg.loader.editor;
            systemd-boot.graceful = lib.mkOverride 500 cfg.loader.graceful;
          })
          (lib.mkIf (isSystemdBootFamily && cfg.loader.consoleMode != null) {
            systemd-boot.consoleMode = lib.mkOverride 500 cfg.loader.consoleMode;
          })
          # generations.keep bounds the SAME configurationLimit for either loader
          # -- lanzaboote's ESP garbage collection inherits systemd-boot's own
          # option rather than defining a second one.
          (lib.mkIf isSystemdBootFamily {
            systemd-boot.configurationLimit = lib.mkOverride 500 cfg.generations.keep;
          })

          # ── limine: its OWN option tree, never systemd-boot's -- editor and generation-retention
          # concepts exist here too, just under different names and with no graceful/consoleMode
          # equivalent (asserted above). `efiInstallAsRemovable` needs no write of its own: its
          # default already reads `!efi.canTouchEfiVariables`, set above, and NixOS module defaults
          # are resolved against the FINAL merged config, not per-module snapshots, so it tracks
          # loader.efiVariables correctly with no extra wiring. ──
          (lib.mkIf isLimine {
            limine.enable = lib.mkOverride 500 true;
            limine.enableEditor = lib.mkOverride 500 cfg.loader.editor;
            limine.maxGenerations = lib.mkOverride 500 cfg.generations.keep;
          })
        ];

        # boot.lanzaboote.* is defined by the external lanzaboote flake module,
        # not by this one -- see the header note on why that module must be
        # composed alongside nixboot on every host, including ones that leave
        # it disabled.
        boot.lanzaboote.enable = lib.mkOverride 500 (cfg.loader.program == "lanzaboote");
        boot.lanzaboote.bootCounting.initialTries = lib.mkIf (cfg.bootCounting.tries != null) (
          lib.mkOverride 500 cfg.bootCounting.tries
        );

        # ── secureBoot.pkiBundle / keySource actually reach lanzaboote's own knobs ──
        # THE GAP THIS CLOSES: every OTHER piece of this module that touches Secure Boot keys
        # (sbctlCompat's /etc/sbctl/sbctl.conf, nixboot-enroll-sb, tools.sbctl's default,
        # extraEntries.*.sign.pkiBundle's own default) reads `cfg.secureBoot.pkiBundle` as THE
        # bundle location -- but until this write existed, lanzaboote's OWN `lzbt install` hook
        # (the thing that actually SIGNS every UKI) was never told about it and would fall back to
        # ITS OWN default key location instead, completely decoupled from every other piece of
        # this module that assumes `cfg.secureBoot.pkiBundle` is where the real keys live. A host
        # setting `secureBoot.pkiBundle` got a config file, an enrollment tool, and a signing
        # default that all agreed with each other and NONE of which lanzaboote itself ever read --
        # `secureBoot.enable = true` would build, boot, and PRODUCE UKIs, just never verify them
        # against the keys the rest of this module thought were in charge. `keySource` had the same
        # problem: declared, described in prose, never once read -- see `keySource`'s own option doc.
        boot.lanzaboote.pkiBundle = lib.mkIf cfg.secureBoot.enable (
          lib.mkOverride 500 cfg.secureBoot.pkiBundle
        );
        boot.lanzaboote.autoGenerateKeys.enable = lib.mkIf cfg.secureBoot.enable (
          lib.mkOverride 500 (cfg.secureBoot.keySource == "autogenerate")
        );

        # ── generate-sb-keys landlock/ENOENT workaround (autogenerate path only) ──
        # CONFIRMED BY DIRECT REPRODUCTION on the source host:
        # lanzaboote's `generate-sb-keys.service` runs plain `sbctl create-keys` with its landlock
        # sandbox left on. `sbctl create-keys` adds a Landlock RWDirs rule for the GRANDPARENT of
        # `keydir` (`dirname(pkiBundle)`) WITHOUT `IgnoreIfMissing()`. On a genuine first boot that
        # parent does not exist yet -- nothing pre-creates it -- so Landlock's `open(O_PATH)` on
        # that path fails with ENOENT and `sbctl create-keys` exits 1 BEFORE creating any directory
        # or writing any key: the service fails silently and `<pkiBundle>/keys/db/db.key` never
        # appears. `--disable-landlock` skips the landlock setup entirely and succeeds. Gated on
        # the SAME condition lanzaboote itself gates the unit's existence on
        # (`autoGenerateKeys.enable`, written just above) -- this override is inert, not merely
        # absent, on a "stable" host, since the unit itself does not exist there.
        systemd.services.generate-sb-keys = lib.mkIf
          (
            cfg.secureBoot.enable && cfg.secureBoot.keySource == "autogenerate"
          )
          {
            serviceConfig.ExecStart = lib.mkForce "${pkgs.sbctl}/bin/sbctl create-keys --disable-landlock";
          };

        # boot.initrd.systemd.enable is DELIBERATELY NOT owned here, unlike the
        # console= wiring below, for two reasons: it is the supported path for
        # TPM2-LUKS unlock, which is squarely the disk-layout/crypto appliance
        # identity this module's SCOPE note at the top already excludes from
        # this first cut ("LUKS members, ZFS pool import, the store/hot vs
        # store/usb split ... NOT implemented in this first cut"); and nixboot
        # already owns and writes the two lanzaboote options that matter to IT
        # (enable, bootCounting.initialTries) without needing an opinion on
        # stage-1's init system otherwise -- if a host's own crypto/appliance
        # config needs systemd in the initrd (as nixnas's does), that host sets
        # `boot.initrd.systemd.enable` itself, the same way it will declare its
        # own LUKS members itself. Judged appliance identity, not generic
        # boot-chain wiring; left out.

        # Console ordering: reorder, never drop. Both console= parameters are
        # ALWAYS present when console.primary is managed -- removing
        # console=ttyS0 would silence the serial LUKS prompt and the serial
        # getty everywhere, headless boxes and the entire CI suite at once.
        # Only the LAST console= becomes /dev/console -- see console.primary's
        # own description for the full reasoning.
        #
        # PLAIN priority here -- DELIBERATELY NOT `mkOverride 500`, unlike every
        # `boot.loader.*` write in this file (see the priority-discipline note at
        # the top). THE GAP THIS CLOSES (found consuming this module on a real,
        # otherwise-ordinary host): `boot.kernelParams` is a LIST-typed option,
        # and NixOS's module system does not "concatenate regardless of
        # priority" the way the top-of-file note's `boot.loader.*` reasoning
        # assumes -- it picks ONE winning priority TIER for the option and
        # merges only THAT tier's contributions, discarding every other tier
        # WHOLESALE. `boot.loader.*` options are each a single SCALAR value, so
        # `mkOverride 500` beating a profile's `mkDefault` (1000) while losing
        # to a host's own plain `=` (100) is exactly "the more specific
        # definition wins, cleanly" -- there is only ever one winning value
        # either way. `boot.kernelParams` is different in kind: on any
        # non-trivial host MULTIPLE unrelated modules each contribute their OWN
        # plain-priority (100) kernel parameters that all need to coexist
        # (kernel/security/power-management defaults, a board-specific
        # `video=` fix, etc.) -- confirmed live: a host with nothing more exotic
        # than its own plain `boot.kernelParams = [ "video=..." ];` line
        # silently lost EVERY console= entry this module tried to add, because
        # that plain-100 tier out-ranked (and therefore fully excluded) this
        # write's `mkOverride 500` tier -- nixboot-verify's own Check 7 below
        # exists specifically to catch this class of loss at runtime, but the
        # right fix is to not manufacture the conflict in the first place. Once
        # this is plain (100, the same tier basically everything else already
        # uses for this option), it CONCATENATES with every sibling
        # contributor instead of racing them for a tier that usually loses.
        boot.kernelParams = lib.mkIf (cfg.console.primary != null) (
          if cfg.console.primary == "serial" then
            [
              "console=tty0"
              "console=${cfg.console.serialDevice},${toString cfg.console.serialBaud}"
            ]
          else
            [
              "console=${cfg.console.serialDevice},${toString cfg.console.serialBaud}"
              "console=tty0"
            ]
        );

        systemd.services.nixboot-self-heal = lib.mkIf cfg.loader.selfHeal {
          description = "nixboot: re-assert the bootloader install on an ESP that was baked into an image and never ran `bootctl install`";
          wantedBy = [ "multi-user.target" ];
          after = [ "local-fs.target" ];
          unitConfig.ConditionPathIsMountPoint = cfg.esp.mountPoint;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.systemd}/bin/bootctl --esp-path=${cfg.esp.mountPoint} --no-variables --graceful install";
            SuccessExitStatus = "0 1";
          };
        };

        # DELIBERATELY EXCLUDES the autogenerate keyset: lanzaboote's OWN module already
        # writes this exact file whenever `boot.lanzaboote.autoGenerateKeys.enable` is true
        # (`environment.etc."sbctl/sbctl.conf" = mkIf (cfg.autoGenerateKeys.enable ||
        # cfg.autoEnrollKeys.enable) { source = sbctlConfigFile; }`, nix/modules/
        # lanzaboote.nix) -- exactly the keyless host this option's own doc already names
        # as the one class `sbctlCompat` is NOT for ("Fixes a live wart: lanzaboote only
        # writes that file on KEYLESS (autogenerate) hosts... on a stable-keyed host sbctl
        # status reports not-installed"). Before this exclusion, a host with BOTH
        # `secureBoot.sbctlCompat = true` (the default) AND `secureBoot.keySource =
        # "autogenerate"` had TWO real, same-priority definitions for the identical `/etc`
        # file -- a genuine "The option ... has conflicting definition values" build failure
        # discovered forcing `system.build.toplevel` (not merely `nix flake check`'s shallower
        # NixOS-configuration check, which never instantiates the derivation strictly enough
        # to hit it) the first time a real consumer actually turned `secureBoot.enable` on for
        # a keyless/autogenerate host. `keySource != "autogenerate"` is the exact condition
        # `autoGenerateKeys.enable` itself is derived from two writes above, so this can never
        # drift out of sync with lanzaboote's own gate.
        environment.etc."sbctl/sbctl.conf" = lib.mkIf
          (cfg.secureBoot.sbctlCompat && cfg.secureBoot.keySource != "autogenerate")
          {
          # NOTE: sbctl's config schema was not directly readable from the
          # evidence this module was written against -- only that lanzaboote
          # writes this file for keyless hosts and that its absence is what
          # makes `sbctl status` report "not installed" on a keyed host. This
          # is the minimal field nixboot-verify's sbctl check needs to be
          # meaningful. Confirm the field name against the sbctl version
          # actually installed before relying on this in place of the manual
          # /var/lib/sbctl staging nixnas's enrollment script does today --
          # if it is wrong, nixboot-verify's sbctl check will FAIL loudly
          # rather than silently, which is the point of shipping both.
          text = ''
            keydir = "${cfg.secureBoot.pkiBundle}/keys"
          '';
        };

        environment.systemPackages =
          lib.optional cfg.tools.sbctl.enable pkgs.sbctl
          ++ lib.optional cfg.tools.efitools.enable pkgs.efitools
          ++ lib.optional cfg.tools.sbsigntool.enable pkgs.sbsigntool
          ++ lib.optional (cfg.secureBoot.enrollTool.enable && cfg.secureBoot.enable) enrollSb;

        # Exposed unconditionally (like `system.build.extraEntryMaintainers` /
        # `nixbootRegisterBootEntry` above) so `nix flake check` forces and
        # shellchecks this derivation even on a host, or a check fixture, that
        # never turns on `secureBoot.enrollTool.enable && secureBoot.enable` --
        # see the `enrollSb` binding's own comment for why this closes a real
        # coverage gap nixnas's own `system.build.sbEnroller` already avoided.
        system.build.nixbootEnrollSb = enrollSb;

        systemd.services.nixboot-verify = lib.mkIf cfg.verify.enable {
          description = "nixboot: read every managed boot knob back and report what actually took";
          wantedBy = [ "multi-user.target" ];
          after = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          # `path`, not left to systemd's own per-unit default -- MEASURED live 2026-08-01 on a
          # real deployment: a plain `script = ...` service gets NixOS's baseline unit PATH
          # (coreutils/findutils/gnugrep/gnused/systemd only, confirmed via `systemctl cat`),
          # which does not include util-linux at all. Check 2 below shells out to a bare
          # `command -v findmnt` / `findmnt -n "$esp"` -- with no util-linux on this unit's PATH,
          # `command -v findmnt` ALWAYS fails, so Check 2 unconditionally takes its else branch
          # and prints "FAIL esp.mountPoint: $esp is not a mountpoint", regardless of whether the
          # ESP is actually mounted. It was: `findmnt /boot`, `mount`, and `/proc/self/mountinfo`
          # all agreed the ESP was mounted the whole time, `boot.mount` was `active (mounted)`,
          # and every OTHER check in the same run (generations.keep, extraEntries.*, remoteUnlock)
          # read real files under $esp successfully -- impossible if $esp were actually unmounted.
          # A check that can never pass on ANY consumer is worse than no check: it trains an
          # operator to stop reading a red unit, exactly the failure mode this module exists to
          # prevent. `pkgs.util-linux` fixes it unconditionally (findmnt is not behind any
          # `tools.*.enable` gate -- Check 2 always runs).
          #
          # sbctl/sbsigntool have the SAME bug for a DIFFERENT reason: `environment.systemPackages`
          # (above, gated on `cfg.tools.sbctl.enable` / `cfg.tools.sbsigntool.enable`) puts them on
          # the system-wide interactive-shell PATH, but systemd services do NOT inherit
          # `environment.systemPackages` -- so even with `tools.sbctl.enable = true`, Check 5's
          # `command -v sbctl` would still fail and print "SKIP ... sbctl is not on PATH
          # (tools.sbctl.enable is off)" while that option is actually ON, blaming the wrong
          # cause. Mirrored here, conditionally, so the `command -v` gates stay meaningful:
          # SKIP means the operator genuinely disabled the tool, not that this unit's PATH forgot
          # about it. `pkgs.systemd`/`pkgs.openssh` are NOT needed here -- Checks 1 and 8 already
          # call bootctl/systemd-creds/ssh-keygen via `${pkgs.X}/bin/Y` absolute interpolation
          # (immune to PATH by construction), the same pattern nixboot-seal-hostkey below uses via
          # its own `path` for systemd-creds/ssh-keygen. This `path` line only needs to cover the
          # tools THIS script still resolves by bare name.
          path = lib.optional cfg.tools.sbctl.enable pkgs.sbctl
            ++ lib.optional cfg.tools.sbsigntool.enable pkgs.sbsigntool
            ++ [ pkgs.util-linux ];
          script = ''
            set -uo pipefail   # no -e: a failed readback is data, not an engine crash
            fail=0
            esp="${cfg.esp.mountPoint}"

            # ── Check 1: loader identity, the "masked/enabled loader state" check ──
            # There is no systemd unit representing "which program owns the ESP"
            # the way sleep targets represent sleep policy, so this reads the
            # active stub identity straight off the ESP via bootctl. This is also
            # what catches the wrong-mechanism-still-active case: if the stub
            # bootctl reports does not match loader.program, the UNINTENDED
            # loader silently kept (or regained) control of the ESP.
            #
            # limine is NOT a `bootctl`-family loader at all (see isSystemdBootFamily's own
            # comment), so it gets its own branch below instead of a third `case` arm here: `bootctl
            # status` on a limine-owned ESP reports whatever it finds (nothing limine-related, since
            # limine never touches bootctl's own on-disk state) and would only ever produce a
            # confusing FAIL, not a meaningful one.
            ${lib.optionalString isSystemdBootFamily ''
              if [ -d "$esp" ]; then
                status="$(${pkgs.systemd}/bin/bootctl --esp-path="$esp" status 2>/dev/null || true)"
                case "${cfg.loader.program}" in
                  lanzaboote)
                    if echo "$status" | grep -qi 'lanzastub'; then
                      echo "PASS  loader.program = lanzaboote (lanzastub active on $esp)"
                    else
                      echo "FAIL  loader.program = lanzaboote requested, but bootctl status on $esp shows no lanzastub entry"
                      fail=1
                    fi
                    ;;
                  systemd-boot)
                    if echo "$status" | grep -Eq 'Product: *systemd-boot'; then
                      echo "PASS  loader.program = systemd-boot ($esp)"
                    else
                      echo "FAIL  loader.program = systemd-boot requested, but bootctl status on $esp shows no systemd-boot Product line"
                      fail=1
                    fi
                    ;;
                esac
              else
                echo "SKIP  loader.program: $esp does not exist yet"
              fi
            ''}
            # limine's config search order is FIXED and not configurable: of the two paths this
            # module knows about, "$esp/limine/limine.conf" (where nixpkgs' own installer places it)
            # wins over "$esp/limine.conf", and the loser is ignored SILENTLY -- see loader.program's
            # own doc for the full trap. PASS/FAIL on the winning path's presence; separately WARN
            # (never FAIL -- it is inert today) if the shadowed loser also exists, since it would
            # become the ACTIVE config the instant the winning file ever disappears, with zero
            # warning from limine itself at that moment.
            ${lib.optionalString isLimine ''
              if [ -f "$esp/limine/limine.conf" ]; then
                echo "PASS  loader.program = limine ($esp/limine/limine.conf exists)"
              else
                echo "FAIL  loader.program = limine requested, but $esp/limine/limine.conf is missing"
                fail=1
              fi
              if [ -f "$esp/limine.conf" ]; then
                echo "WARN  loader.program = limine: $esp/limine.conf ALSO exists -- limine's fixed search order means $esp/limine/limine.conf (checked above) wins today, but this shadowed file would become the ACTIVE config the moment that one disappears, with no warning from limine itself. Remove it."
              fi
            ''}
            ${lib.optionalString (cfg.loader.program == "none") ''
              echo "SKIP  loader.program = none, nothing to verify"
            ''}

            # ── Check 2: ESP mountpoint + label ──
            if command -v findmnt >/dev/null 2>&1 && findmnt -n "$esp" >/dev/null 2>&1; then
              echo "PASS  esp.mountPoint: $esp is mounted"
              ${lib.optionalString (cfg.esp.byLabel != null) ''
                label="$(findmnt -n -o LABEL "$esp" 2>/dev/null || true)"
                if [ "$label" = "${cfg.esp.byLabel}" ]; then
                  echo "PASS  esp.byLabel = ${cfg.esp.byLabel}"
                else
                  echo "FAIL  esp.byLabel: wanted '${cfg.esp.byLabel}', filesystem at $esp reports LABEL='$label'"
                  fail=1
                fi
              ''}
            else
              echo "FAIL  esp.mountPoint: $esp is not a mountpoint"
              fail=1
            fi

            # ── Check 3: ESP free space vs esp.capacityMiB ──
            ${lib.optionalString (cfg.esp.capacityMiB != null) ''
              if [ -d "$esp" ]; then
                pcent="$(df --output=pcent "$esp" 2>/dev/null | tail -n1 | tr -d ' %')"
                sizeMiB="$(df --output=size -BM "$esp" 2>/dev/null | tail -n1 | tr -d ' M')"
                if [ -n "$pcent" ]; then
                  if [ "$pcent" -ge 90 ]; then
                    echo "FAIL  esp.capacityMiB: $esp is $pcent% full (declared ${toString cfg.esp.capacityMiB} MiB)"
                    fail=1
                  elif [ "$pcent" -ge 75 ]; then
                    echo "WARN  esp.capacityMiB: $esp is $pcent% full (declared ${toString cfg.esp.capacityMiB} MiB) -- an ESP resize is an image reprovision, plan it now"
                  else
                    echo "PASS  esp.capacityMiB: $esp is $pcent% full"
                  fi
                else
                  echo "SKIP  esp.capacityMiB: could not read df output for $esp"
                fi
                if [ -n "''${sizeMiB:-}" ] && [ "$sizeMiB" != "${toString cfg.esp.capacityMiB}" ]; then
                  echo "WARN  esp.capacityMiB: declared ${toString cfg.esp.capacityMiB} MiB, filesystem at $esp reports ~$sizeMiB MiB -- update the declaration or investigate the mismatch"
                fi
              fi
            ''}

            # ── Check 4: foreign paths still present -- AND, for anything that
            # looks like an EFI binary (a foreign fallback loader is the common
            # case: EFI/BOOT/BOOTX64.EFI, a vendor rescue stub), actually intact,
            # not merely present. Existence alone is a weaker claim than it
            # looks: a `-e` check is satisfied equally by the real binary and by
            # a zero-byte or truncated file left behind by some other write that
            # failed partway -- present-but-corrupted is a real, closable gap an
            # existence-only check silently misses. PE/COFF images (which every
            # EFI binary is) start with the two bytes "MZ"; checking that plus a
            # non-zero size catches gross corruption without needing a full
            # parse of the executable.
            ${lib.concatMapStringsSep "\n" (p: ''
              if [ -e "$esp/${p}" ]; then
                ${
                  if lib.hasSuffix ".efi" (lib.toLower p) then ''
                    sz="$(stat -c%s "$esp/${p}" 2>/dev/null || echo 0)"
                    magic="$(head -c2 "$esp/${p}" 2>/dev/null | tr -d '\0')"
                    if [ "$sz" -gt 0 ] && [ "$magic" = "MZ" ]; then
                      echo "PASS  esp.foreignPaths: ${p} present and looks like an intact PE/EFI binary ($sz bytes)"
                    else
                      echo "FAIL  esp.foreignPaths: ${p} exists but is not an intact EFI binary (size=$sz bytes, magic='$magic') -- present-but-corrupted is exactly what an existence-only check misses"
                      fail=1
                    fi
                  '' else ''
                    echo "PASS  esp.foreignPaths: ${p} present"
                  ''
                }
              else
                echo "FAIL  esp.foreignPaths: ${p} is MISSING -- something removed a path nixboot promised never to touch or garbage-collect"
                fail=1
              fi
            '') cfg.esp.foreignPaths}

            # ── Check 5: sbctl status, only meaningful once sbctlCompat exists ──
            ${lib.optionalString cfg.secureBoot.sbctlCompat ''
              if command -v sbctl >/dev/null 2>&1; then
                sbctl_out="$(sbctl status 2>&1 || true)"
                if echo "$sbctl_out" | grep -Eqi 'Installed:.*(true|yes|✓)'; then
                  echo "PASS  secureBoot.sbctlCompat: sbctl status reports installed"
                else
                  echo "FAIL  secureBoot.sbctlCompat: sbctl status does not report installed -- check /etc/sbctl/sbctl.conf against secureBoot.pkiBundle"
                  echo "      sbctl status (first lines): $(echo "$sbctl_out" | head -n5 | tr '\n' ' ')"
                  fail=1
                fi
              else
                echo "SKIP  secureBoot.sbctlCompat: sbctl is not on PATH (tools.sbctl.enable is off) -- nothing to check it with"
              fi
            ''}

            # ── Check 6: kept-generation count vs generations.keep ──
            ${lib.optionalString (cfg.loader.program != "none") ''
              count=0
              case "${cfg.loader.program}" in
                lanzaboote)
                  count="$(find "$esp/EFI/Linux" -maxdepth 1 -name 'nixos-generation-*.efi' 2>/dev/null | wc -l)"
                  ;;
                systemd-boot)
                  count="$(find "$esp/loader/entries" -maxdepth 1 -name 'nixos-generation-*.conf' 2>/dev/null | wc -l)"
                  ;;
                limine)
                  # limine has no per-generation FILE to `find` at all -- systemd-boot and
                  # lanzaboote each write one file per kept generation, limine writes ONE
                  # limine.conf containing every generation as a menu entry instead (see
                  # nixpkgs' own limine-install.py, `generate_config_entry`). Count menu-entry
                  # title lines instead: each generation renders as "/+...Generation <N>" at
                  # whatever menu depth that generation's own specialisation count puts it at
                  # (1-3 leading slashes, an optional "+" marking the default), always ending
                  # the line in "Generation <N>" with nothing after it -- a specialisation's own
                  # "Default"/"+Default" sub-entries never match this pattern, so this counts
                  # generations, not every menu line.
                  count="$(grep -cE '^/+\+?Generation [0-9]+$' "$esp/limine/limine.conf" 2>/dev/null || true)"
                  ;;
              esac
              if [ "$count" -gt 0 ]; then
                if [ "$count" -le ${toString cfg.generations.keep} ]; then
                  echo "PASS  generations.keep: $count generation(s) on $esp, limit ${toString cfg.generations.keep}"
                else
                  echo "FAIL  generations.keep: $count generation(s) on $esp, over the declared limit ${toString cfg.generations.keep} -- check for a plain-priority configurationLimit definition elsewhere beating nixboot's mkOverride 500"
                  fail=1
                fi
              else
                echo "SKIP  generations.keep: no generation entries found under $esp yet"
              fi
            ''}

            # ── Check 7: console ordering, i.e. what /dev/console actually IS ──
            # A requested console.primary that silently did not take is worse
            # here than anywhere else in this file to miss: the only OTHER way
            # to notice is an initrd prompt (or the emergency shell) landing on
            # the wrong physical port at the NEXT boot -- see console.primary's
            # own description. /proc/cmdline is read back from the RUNNING
            # kernel, not from any config file, so this catches a `mkForce`
            # (or a same-tier but differently-ordered) boot.kernelParams
            # definition elsewhere beating this module's own plain-priority
            # write (see that write's own comment for why kernelParams stays
            # plain rather than `mkOverride 500`) just as surely as it catches
            # a typo. Checks the LAST console= token specifically (not
            # literally the end of the line -- other, non-console kernel
            # params may follow it), because it is the last console= that the
            # kernel makes /dev/console.
            ${lib.optionalString (cfg.console.primary != null) (
              let
                expectedLast =
                  if cfg.console.primary == "serial" then
                    "console=${cfg.console.serialDevice},${toString cfg.console.serialBaud}"
                  else
                    "console=tty0";
              in
              ''
                cmdline="$(cat /proc/cmdline 2>/dev/null || true)"
                actualLast="$(echo "$cmdline" | tr ' ' '\n' | grep '^console=' | tail -n1)"
                if [ "$actualLast" = "${expectedLast}" ]; then
                  echo "PASS  console.primary = ${cfg.console.primary}: /proc/cmdline's last console= is ${expectedLast}"
                else
                  echo "FAIL  console.primary = ${cfg.console.primary}: wanted the LAST console= on /proc/cmdline to be '${expectedLast}', got '$actualLast'"
                  fail=1
                fi
              ''
            )}
            ${lib.optionalString (cfg.console.primary == null) ''
              echo "SKIP  console.primary: not managed by nixboot"
            ''}

            # ── Check 8: the sealed initrd-SSH host key, i.e. what the NEXT
            # boot's initrd will actually present ── Nothing on the running
            # system records which fingerprint THIS boot's initrd actually
            # served (the ephemeral-vs-sealed choice is made, and the ephemeral
            # key thrown away, in stage 1, before nixboot-verify exists) -- so
            # this checks the only thing that honestly IS verifiable post-boot
            # without reaching into TPM internals: does the credential
            # nixboot-seal-hostkey left on the ESP still decrypt against the
            # LIVE TPM/PCR state (the exact self-test that service itself runs
            # -- reusing it here is not a new TPM operation, just reading the
            # same answer back, ordered `after` that service so it always runs
            # against a freshly-(re)sealed .cred), and does the decrypted key's
            # fingerprint match the PUBLIC one published for operators to pin.
            # A mismatch there means an operator pinning `${pubEspPath}` would
            # trust the WRONG key on their NEXT initrd-SSH connection --
            # exactly the class of bug this module exists to catch before the
            # next boot, not after.
            ${lib.optionalString (ru.enable && sealActive) ''
              cred="${credEspPath}"
              pub="${pubEspPath}"
              if [ -f "$cred" ]; then
                tmpkey="$(mktemp -t nixboot-verify-hostkey-XXXXXX)"
                if ${pkgs.systemd}/bin/systemd-creds decrypt --tpm2-device=${ru.tpm2.device} --name=${credName} "$cred" "$tmpkey" >/dev/null 2>&1; then
                  if [ -f "$pub" ]; then
                    sealed_fp="$(${sshPackage}/bin/ssh-keygen -y -f "$tmpkey" 2>/dev/null | ${sshPackage}/bin/ssh-keygen -lf - 2>/dev/null)"
                    published_fp="$(${sshPackage}/bin/ssh-keygen -lf "$pub" 2>/dev/null)"
                    if [ -n "$sealed_fp" ] && [ "$sealed_fp" = "$published_fp" ]; then
                      echo "PASS  remoteUnlock: sealed initrd SSH host key decrypts and matches the published fingerprint at $pub"
                    else
                      echo "FAIL  remoteUnlock: sealed credential decrypts, but its fingerprint ('$sealed_fp') does not match the published $pub ('$published_fp') -- an operator pinning $pub would trust the WRONG key on their next initrd-SSH connect"
                      fail=1
                    fi
                  else
                    echo "WARN  remoteUnlock: $cred decrypts fine but $pub is missing -- an operator has no fingerprint to pin for the next initrd-SSH connect"
                  fi
                else
                  echo "WARN  remoteUnlock: $cred does not decrypt against the CURRENT TPM/PCR state -- EXPECTED exactly once, right after Secure Boot key enrollment (PCR 7 changes then); nixboot-seal-hostkey runs before this check and should already have re-sealed it THIS boot -- if this persists across a SECOND boot in a row, investigate rather than assume self-heal"
                fi
                shred -u "$tmpkey" 2>/dev/null || rm -f "$tmpkey"
              else
                echo "SKIP  remoteUnlock: $cred does not exist yet -- genuine first boot, or nixboot-seal-hostkey has not run; initrd-SSH is currently serving the EPHEMERAL fallback key instead"
              fi
            ''}
            ${lib.optionalString (ru.enable && !sealActive) ''
              echo "SKIP  remoteUnlock: sealHostKey = false (or tpm2.enable = false) -- the plaintext hostKeyPath fingerprint is fixed at build time, nothing to verify post-boot"
            ''}
            ${lib.optionalString (!ru.enable) ''
              echo "SKIP  remoteUnlock: not managed by nixboot"
            ''}

            # ── Check 9: extraEntries -- the placed UKI exists under its
            # declared name, and, if signed, verifies against the enrolled db
            # key. This is the same "requesting a setting is not evidence it
            # took" contract Check 1-8 already enforce, applied to
            # nixboot.extraEntries: the maintainer unit ran on a TIMER (never a
            # boot/switch dependency, see modules/extra-entries.nix), so nothing
            # else in this system ever confirms it actually succeeded.
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (extraName: entry: ''
              ef="$esp/EFI/Linux/${entry.espFileName}"
              if [ -f "$ef" ]; then
                echo "PASS  extraEntries.${extraName}: $ef exists"
                ${lib.optionalString entry.sign.enable ''
                  if command -v sbverify >/dev/null 2>&1; then
                    if sbverify --cert "${lib.escapeShellArg (if entry.sign.pkiBundle != null then "${entry.sign.pkiBundle}/keys/db/db.pem" else "/dev/null")}" "$ef" >/dev/null 2>&1; then
                      echo "PASS  extraEntries.${extraName}: signature verifies against the enrolled db key"
                    else
                      echo "FAIL  extraEntries.${extraName}: $ef does NOT verify against ${lib.escapeShellArg (if entry.sign.pkiBundle != null then "${entry.sign.pkiBundle}/keys/db/db.pem" else "(no pkiBundle declared)")}"
                      fail=1
                    fi
                  else
                    echo "SKIP  extraEntries.${extraName}: sbverify not on PATH (tools.sbsigntool.enable is off) -- cannot check the signature"
                  fi
                ''}
              else
                echo "FAIL  extraEntries.${extraName}: declared UKI $ef is MISSING"
                fail=1
              fi
            '') cfg.extraEntries)}
            ${lib.optionalString (cfg.extraEntries == { }) ''
              echo "SKIP  extraEntries: none declared"
            ''}

            if [ "$fail" -ne 0 ]; then
              echo "nixboot-verify: at least one boot knob did not take. The setting was requested correctly and something declined or overrode it -- see the FAIL lines above. On this host the next real evidence of a wrong boot setting is the NEXT boot, so treat any FAIL here as urgent, not cosmetic."
              exit 1
            fi
            echo "nixboot-verify: every managed boot knob verified against the live system."
          '';
        };
      }

      ## ── Remote unlock: common initrd wiring (NIC up + sshd, either path) ──
      (lib.mkIf ru.enable {
        # Bring networking up in the initrd, then run sshd there for the
        # unlock hand-off. Neither of these is a `boot.loader.*` write, so
        # the priority-discipline note at the top of this file (mkOverride
        # 500 for loader options) does not apply -- plain `=` is correct
        # here the same way it now is for boot.kernelParams's sibling
        # console.primary wiring above (see that write's own comment: a
        # LIST-typed option like kernelParams needs plain priority precisely
        # so it concatenates with every other module's own contributions,
        # rather than racing them for a tier that usually loses). Nothing
        # else in this module or a typical base profile sets
        # boot.initrd.network.* or boot.initrd.systemd.network.*, so plain
        # `=` is the honest priority here -- see the Restart override further
        # down for the one case in this whole feature where that stops being
        # true and mkForce becomes genuinely necessary.
        boot.initrd.network.enable = true;
        boot.initrd.network.ssh = {
          enable = true;
          port = 22;
          authorizedKeys = ru.authorizedKeys;
        };
        # With systemd-initrd the classic udhcpc path is off; networkd
        # handles the link, but `network.enable` alone declares no
        # `.network` unit, so the NIC would get no lease. DHCP every
        # ethernet link explicitly so the box is reachable for the unlock.
        boot.initrd.systemd.network = {
          enable = true;
          networks."10-uplink" = {
            matchConfig.Name = "en* eth*";
            networkConfig.DHCP = "yes";
          };
        };

        # The NIC drivers the initrd must load to get on the network.
        boot.initrd.availableKernelModules = [
          "virtio_net" # VM testing
          "e1000e"
          "igb"
          "igc"
          "r8169"
          "tg3"
          "atlantic" # common server/desktop NICs
        ]
        # ── TPM2 driver, only when the sealed-host-key path needs to talk to a chip ──
        # THE GAP THIS CLOSES: `remoteUnlock.tpm2.enable = true` makes sshd's
        # LoadCredentialEncrypted= run `systemd-creds decrypt --tpm2-device=...` INSIDE THE
        # INITRD (see nixboot-seal-hostkey/the sshd credential wiring above) -- which needs the
        # kernel to already be talking to the TPM chip (/dev/tpmrm0) by then. Without the driver
        # in the initrd's own module set, that decrypt simply cannot reach the chip at all,
        # regardless of whether the PCR/passphrase side of things is otherwise correct.
        # `remoteUnlock.tpm2.enable` is documented (see that option's own doc) as a value nixboot
        # only READS, never a policy it owns -- but a driver MODULE is mechanics, not policy, and
        # nixboot is the one module that actually knows the sealed-key path needs it; nixnas's own
        # `crypto/tpm2.nix` adds the identical two modules as a side effect of its OWN
        # `crypto.tpm2.enable`, but a host that composes nixboot's remoteUnlock WITHOUT nixnas (the
        # explicitly-supported "usable on hosts generically" case this module's own header claims)
        # got no driver at all until this line. Additive-only (a list-type option merges), so this
        # can never collide with a host that already lists these some other way.
        ++ lib.optionals ru.tpm2.enable [ "tpm_crb" "tpm_tis" ];

        # ── CROSS-MODULE COUPLING nixboot cannot see, let alone fix ──
        # Everything above only gets an operator AS FAR AS a live sshd
        # session in the initrd. Whether that operator then has time to type
        # the secret at all is decided by disk-layout config this module
        # deliberately does not own (see the header SCOPE note): systemd's
        # own DefaultDeviceTimeoutSec (90s) kills the DEVICE JOB behind a
        # neededForBoot LUKS mount independently of the crypttab password
        # PROMPT's own "wait forever" default -- a slow-POST server plus an
        # unanswered prompt hits this even though initrd-SSH itself is up
        # and reachable the whole time. nixnas's fix lives entirely in its
        # own disk-layout module, one `x-systemd.device-timeout=0` on the
        # crypttab entry and one on the neededForBoot mount's fileSystems
        # options (nixnas/modules/boot/disk.nix:40-79, field-proven incident
        # dated 2026-07-04) -- NOT ported here, because nixboot has no LUKS
        # member list to attach it to. Whoever composes remoteUnlock.enable
        # = true alongside their own initrd LUKS config on THIS flake must
        # carry that same fix themselves, or remote-unlock's entire "wait
        # forever for a human" promise is false past 90 seconds.
      })

      ## ── Path B: sealHostKey = false -- embed the plaintext key in the initrd.
      (lib.mkIf (ru.enable && !sealActive && ru.hostKeyPath != null) {
        # A non-store STRING destination (NixOS uses it verbatim as the
        # in-initrd HostKey path).
        boot.initrd.network.ssh.hostKeys = [ hostKeyDest ];
        # Override the auto-derived secret SOURCE with the real, tracked key
        # so it is copied into the initrd during the image build. mkForce,
        # not mkOverride 500: `boot.initrd.secrets` is an attrsOf where THIS
        # module's own auto-derivation (from `boot.initrd.network.ssh.hostKeys`
        # above, via the nixpkgs initrd-ssh module) would otherwise supply a
        # plain-priority (100) default source for the same destination path --
        # not a `boot.loader.*` write, so the top-of-file priority-discipline
        # note does not constrain it, and mkOverride 500 (priority 500) would
        # simply lose to that plain-priority default silently.
        boot.initrd.secrets.${hostKeyDest} = lib.mkForce hostKeySource;
      })

      ## ── Path A: sealHostKey = true + remoteUnlock.tpm2.enable -- TPM2-sealed
      ## key, delivered as a systemd CREDENTIAL (no bespoke unseal service).
      ## See the remoteUnlock.sealHostKey option doc for the bootstrap story.
      (lib.mkIf (ru.enable && sealActive) {

        # No static key in the initrd. sshd itself loads the TPM2-sealed
        # credential the stub delivered and systemd decrypts it during
        # activation -- the plaintext lands in the unit's
        # $CREDENTIALS_DIRECTORY, which the first HostKey points at. The
        # second HostKey is the first-boot EPHEMERAL fallback (generated by
        # the preStart below); on every other boot that file simply does not
        # exist -- sshd logs "Unable to load host key" for the absent one
        # and carries on with whichever is present (verified against a live
        # sshd on the source host). The Banner file is only written on the
        # ephemeral path; when it is absent sshd sends no banner.
        # ignoreEmptyHostKeys silences the NixOS empty-hostKeys assertion.
        # No ESP mount of its own here, no vfat/codepage modules, no
        # bespoke unseal unit -- systemd's credential machinery does it all.
        boot.initrd.network.ssh.ignoreEmptyHostKeys = true;
        boot.initrd.network.ssh.extraConfig = ''
          HostKey ${hostKeyCredPath}
          HostKey ${ephemeralKeyPath}
          Banner ${bannerPath}
        '';

        # sshd inherits the stub-provided credential by name and TPM2-decrypts
        # it (`--with-key=auto-initrd`, sealed below). Failure semantics
        # (systemd's exec-credential.c) are load-bearing here:
        #   - credential DELIVERED + decrypts        -> boot 2+ normal path,
        #     stable identity.
        #   - credential DELIVERED + decrypt FAILS    -> tampered chain / PCR
        #     mismatch: the unit hard-fails during credential setup, BEFORE
        #     any ExecStartPre -- NO ephemeral fallback, the box stays locked
        #     (intentional: a stolen stick cannot present a plausible unlock
        #     prompt).
        #   - credential MISSING (genuine first boot)  -> an ID-only
        #     LoadCredentialEncrypted= is "missing_ok": non-fatal, the unit
        #     starts with an empty $CREDENTIALS_DIRECTORY and the preStart
        #     below generates the ephemeral key + warning banner.
        boot.initrd.systemd.services.sshd.serviceConfig.LoadCredentialEncrypted = [ credName ];

        # ── BOUND THE FAILED-UNSEAL HAMMER (the DA-lockout defense) ──
        # nixpkgs' initrd-ssh module (nixos/modules/system/boot/initrd-ssh.nix,
        # its `services.sshd.serviceConfig.Restart = "on-failure";`) sets this
        # at PLAIN priority (100), not `lib.mkDefault` -- so, unlike every
        # `boot.loader.*` write elsewhere in this file (which only ever needs
        # to beat a profile's `mkDefault` at 1000), `lib.mkOverride 500` here
        # would LOSE to nixpkgs' own definition and silently do nothing: 500
        # is a higher (weaker) priority number than 100, and NixOS keeps the
        # LOWEST-priority-number definition. This is the one write in this
        # whole file that genuinely needs `lib.mkForce`, verified by reading
        # nixpkgs' own module rather than assumed -- the top-of-file priority
        # discipline note is scoped to `boot.loader.*`, where the competing
        # definitions really are all `mkDefault`; it was never a blanket ban
        # on ever beating a plain-priority nixpkgs default, only on reaching
        # for `mkForce` where `mkOverride 500` already does the job.
        #
        # On the ONE post-Secure-Boot-enrollment boot, the delivered .cred no
        # longer decrypts against the new PCR 7, so credential setup
        # hard-fails -- and with `on-failure` systemd RETRIES the whole
        # activation, each retry firing another TPM2 unseal attempt. Those
        # repeated failed unseals are exactly what drove an fTPM into
        # dictionary-attack lockout (TPM_RC_LOCKOUT) in the field on the
        # source host, which then defeats the stage-2 self-heal too (its own
        # `systemd-creds encrypt` also needs the TPM). Force NO restart
        # instead: a stale cred costs exactly ONE failed unseal, sshd stays
        # down for that single boot (the console prompt, if this host has
        # one, is still there -- Secure Boot enrollment is a
        # physically-present step anyway), and `nixboot-seal-hostkey`
        # RE-SEALS in stage 2 so the NEXT boot's initrd-SSH comes up clean.
        # The intentional anti-downgrade semantics stay UNCHANGED: still no
        # ephemeral fallback for a credential that WAS delivered.
        boot.initrd.systemd.services.sshd.serviceConfig.Restart = lib.mkForce "no";

        # make-initrd-ng copies listed objects + ELF library deps only -- it
        # does NOT chase store references inside script text, so the
        # ssh-keygen the preStart calls must be listed explicitly (same
        # pattern the nixpkgs module itself uses for the sshd binaries).
        boot.initrd.systemd.storePaths = [ "${sshPackage}/bin/ssh-keygen" ];

        # ── First-boot fallback: serve an EPHEMERAL host key rather than not
        # serving at all. A host with `remoteUnlock.enable = true` must be
        # unlockable without IPMI and without a monitor even on the very
        # first boot, before any credential has ever been sealed. The key
        # lives on the initrd's RAM rootfs; nothing survives switch-root.
        # Loud, honest UX: the SSH banner (shown before authentication) says
        # the fingerprint is a throwaway and where to verify the real one
        # from boot #2 on.
        boot.initrd.systemd.services.sshd.preStart = ''
          # Boot 2+: systemd decrypted the sealed credential -- stable
          # identity, nothing to do.
          if [ -s "''${CREDENTIALS_DIRECTORY:-/run/credentials/sshd.service}/${credName}" ]; then
            exit 0
          fi
          # GENUINE first boot: no credential was delivered by the stub. (A
          # delivered-but-undecryptable credential never reaches this script
          # -- see the Restart comment above: that case hard-fails earlier.)
          if [ ! -s ${ephemeralKeyPath} ] || [ ! -s ${ephemeralKeyPath}.pub ]; then
            rm -f ${ephemeralKeyPath} ${ephemeralKeyPath}.pub
            ${sshPackage}/bin/ssh-keygen -t ed25519 -N "" -C "nixboot-ephemeral-first-boot" \
              -f ${ephemeralKeyPath} -q
          fi
          fp="$(${sshPackage}/bin/ssh-keygen -lf ${ephemeralKeyPath}.pub)"
          {
            echo "=================================================================="
            echo " nixboot FIRST BOOT: initrd SSH is using an EPHEMERAL host key"
            echo "   $fp"
            echo " RAM-only, thrown away at switch-root. The fingerprint WILL"
            echo " CHANGE once the TPM-sealed identity is created later this boot"
            echo " (nixboot-seal-hostkey, right after you unlock). From the NEXT"
            echo " boot on, verify the new fingerprint against"
            echo "   ${pubEspPath}"
            echo " (also printed on console+journal by the seal service) and expect"
            echo " a one-time ssh known-hosts change warning -- that one is expected."
            echo "=================================================================="
          } > ${bannerPath}
          echo "nixboot: FIRST BOOT - initrd sshd is serving an EPHEMERAL host key: $fp"
        '';

        # ── Stage-2 seal service (SELF-HEALING) ──────────────────────────────
        # Generates the ed25519 key and TPM2-seals it into the ESP's
        # loader/credentials/ dir with `--with-key=auto-initrd` (TPM2-only key
        # derivation -- the /var credential secret is not available in the
        # initrd) bound to `remoteUnlock.tpm2.pcrs`. `esp.mountPoint` is
        # already mounted in stage 2 (nixboot never mounts it itself, but a
        # host with remoteUnlock.enable = true necessarily has it up by
        # multi-user.target), so this is a plain file write. From here on the
        # lanzaboote stub auto-delivers it to every initrd.
        #
        # Runs on EVERY boot (`wantedBy = multi-user.target`, no
        # ConditionPathExists gate) and decides idempotency IN THE SCRIPT with
        # a real DECRYPT self-test: if the .cred exists AND still decrypts
        # against the LIVE TPM/PCR state, it does nothing (fingerprint
        # unchanged); if the .cred is MISSING or FAILS to decrypt, it
        # (re)generates + (re)seals. This is what makes the one-time PCR 7
        # change from Secure Boot key enrollment SELF-HEAL on the next boot
        # instead of leaving a permanently-undecryptable .cred -- the field
        # incident this exists to prevent: a pre-enrollment seal plus an
        # existence-only gate left the initrd-SSH host key NEVER re-sealed,
        # bricking remote unlock, while the repeated failed-unseal retries
        # (see the Restart comment above) drove the fTPM into DA lockout on
        # top of it. Correctness: firmware extends PCR 7 before the
        # bootloader and does NOT re-extend it between stage 1 and stage 2, so
        # a stage-2 decrypt success here GUARANTEES the stage-1 initrd-sshd
        # unseal succeeds next boot.
        systemd.services.nixboot-seal-hostkey = {
          description = "nixboot: generate + TPM2-seal the initrd SSH host key credential (self-healing across PCR changes)";
          wantedBy = [ "multi-user.target" ];
          after = [ "local-fs.target" "sysinit.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            StandardOutput = "journal+console";
            StandardError = "journal+console";
          };
          path = [ pkgs.systemd sshPackage pkgs.coreutils ];
          script = ''
            echo "=== NIXBOOT-SEAL-START ==="

            # ── Self-healing idempotency: gate the reseal on a REAL decrypt
            # self-test against the live TPM/PCR state -- NOT on the .cred
            # merely existing (the exact gate that bricked the source
            # host's first implementation). `-` writes the decrypted
            # plaintext to stdout, discarded to /dev/null so the key never
            # hits the journal. A successful unseal does NOT touch the TPM
            # dictionary-attack counter, so this per-boot self-test is free;
            # a STALE cred costs exactly one failed unseal (one DA
            # increment) and then heals below -- never a retry loop.
            if [ -f "${credEspPath}" ]; then
              if systemd-creds decrypt --tpm2-device=${ru.tpm2.device} --name=${credName} "${credEspPath}" - >/dev/null 2>&1; then
                echo "nixboot: sealed initrd SSH host key still decrypts against the current TPM/PCR state -- no reseal."
                ssh-keygen -lf "${pubEspPath}" 2>/dev/null || true
                echo "=== NIXBOOT-SEAL-END ==="
                exit 0
              fi
              echo "!! nixboot: the sealed initrd SSH host key credential no longer decrypts against the"
              echo "!! current TPM / PCR state. EXPECTED exactly once -- right after Secure Boot key"
              echo "!! enrollment (nixboot-enroll-sb) changed PCR 7. RE-SEALING now; the initrd host-key"
              echo "!! FINGERPRINT WILL CHANGE this once -- re-pin it on your next initrd-SSH connect."
            fi

            # (Re)generate + (re)seal. Temp DIRECTORY so the key file does not
            # pre-exist (ssh-keygen -f would prompt). A stale .cred/.pub from
            # a pre-enrollment seal is OVERWRITTEN below.
            tmpdir="$(mktemp -d -t nixboot-initrd-hostkey-XXXXXX)"
            tmpkey="$tmpdir/key"
            cleanup() { find "$tmpdir" -type f -exec shred -u {} \; 2>/dev/null || true; rm -rf "$tmpdir"; }
            trap cleanup EXIT
            ssh-keygen -t ed25519 -N "" -C "${credName}" -f "$tmpkey" -q
            mkdir -p "$(dirname "${credEspPath}")"
            # --with-key=auto-initrd: seal to the TPM2 only (no /var secret),
            # so the initrd can decrypt it; --name must match sshd's
            # LoadCredentialEncrypted= name; --tpm2-pcrs anchors it.
            # Remove any stale blob first -- systemd-creds encrypt refuses to
            # clobber an existing output file, and on the self-heal path the
            # old .cred is still present.
            rm -f "${credEspPath}"
            if ! systemd-creds encrypt \
                --with-key=auto-initrd \
                --tpm2-device=${ru.tpm2.device} \
                --tpm2-pcrs=${tpm2PcrsArg} \
                --name=${credName} \
                "$tmpkey" \
                "${credEspPath}"; then
              echo "!! nixboot: FAILED to TPM2-seal the initrd SSH host key. If the TPM is in"
              echo "!! dictionary-attack lockout (TPM_RC_LOCKOUT), clear it and re-run this service:"
              echo "!!   tpm2_dictionarylockout --clear-lockout && systemctl start nixboot-seal-hostkey"
              echo "=== NIXBOOT-SEAL-END ==="
              exit 1
            fi
            chmod 600 "${credEspPath}"
            # Surface the PUBLIC half (it is public -- plaintext ESP is fine)
            # so the operator can VERIFY the initrd-SSH connection instead of
            # TOFU-accepting it, and so nixboot-verify's Check 8 (below) has
            # something to compare the sealed credential against. Overwrites
            # any stale .pub. Without this the fingerprint would be destroyed
            # with the tmpdir and the channel unverifiable.
            install -m 0644 "$tmpkey.pub" "${pubEspPath}"
            echo "nixboot: initrd SSH host key fingerprint (verify this on your next initrd-SSH connect):"
            ssh-keygen -lf "$tmpkey.pub"
            echo "nixboot: initrd SSH host key sealed to ${credEspPath} (public key beside it)"
            echo "=== NIXBOOT-SEAL-END ==="
          '';
        };

        # nixboot-verify reads the sealed credential back (Check 8, in its
        # script) -- order it after this so a normal boot always reads a
        # freshly-(re)sealed .cred rather than racing it. `after`, not
        # `requires`/`wants`: a failed seal should still let the rest of
        # verify's checks run, not vanish along with this unit.
        systemd.services.nixboot-verify.after = lib.mkIf cfg.verify.enable [ "nixboot-seal-hostkey.service" ];
      })
    ]))
  ];
}
