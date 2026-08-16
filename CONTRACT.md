# nixboot — the option-surface contract

This file is the **fixed target**: *what* `nixboot` must guarantee
about every knob it exposes. The behaviors are the spec; `modules/nixboot.nix`
is one implementation. When implementation and contract disagree, the
contract wins — and if a goal itself is wrong, fix it *here*, not in a chat
log or a commit message. (Same convention as the sibling
[nixgpu](https://github.com/julian-corbet/nixgpu-corbet-ch) project's own
`CONTRACT.md`.)

This contract was written after finding the whole domain — loader
arbitration, ESP declaration, generation retention, boot counting, Secure
Boot enrollment — living behind one appliance's own option tree, with zero
reuse path for any other host (`modules/nixboot.nix:4-15`).

## The reality nixboot is built for (constraints, not choices)

- **A boot setting that silently doesn't take is worse than almost any other
  misconfiguration.** On real hardware the only evidence a knob didn't take
  often appears at the *next* boot — by which point the box may not come
  back up at all (`modules/nixboot.nix:9-15`).
- **`switch-root` is the boundary.** nixboot owns firmware → bootloader →
  kernel/initrd handoff. What happens after `switch-root` — service
  ordering, targets — is not this module's problem, on purpose.
- **Physical storage and the boot-medium contract have different owners.**
  nixstorage (or an equivalent layout owner) provisions and identifies the
  physical partition. nixboot owns the ESP's boot role, constraints,
  contents and verification, including construction of the boot portion of
  an image artifact. The current NixOS backend only declares and verifies an
  already-existing ESP; that is an implementation limit, not the permanent
  architecture (`modules/nixboot.nix:30-35, 182-207`).
- **Firmware NVRAM cannot be rolled back.** Every other nixboot mistake is
  fixable by another rebuild; a bad Secure Boot enrollment is not — which is
  why enrollment is the one piece of this module that is never automatic.

## Principles that govern every "how" decision

- **One knob, one owner.** Every `boot.loader.*` write nixboot makes uses
  `lib.mkOverride 500`, never `lib.mkForce` — high enough to beat a
  profile's `mkDefault` (priority 1000), low enough to lose cleanly to a
  host's own plain `=` (priority 100) or `mkForce` (priority 50), so two
  same-priority definitions never collide into an eval error
  (`modules/nixboot.nix:75-86`).
- **Declare and verify, never assume.** Anything nixboot cannot enforce at
  eval time (ESP capacity, which loader stub is actually active, how many
  generations are actually on disk) gets a runtime check in
  `nixboot-verify`, not a comment promising it's fine.
- **A setting that does nothing is a bug, not a shrug.** Options that could
  silently produce no effect (`bootCounting.tries` on a non-lanzaboote host,
  `secureBoot.sbctlCompat` with the tool not installed) are asserted or
  warned against explicitly, not left to fail quietly.

## Architecture target beyond the current option surface

The behavioral options below are the current implementation contract. The
next interface revision must preserve them behind one boot-intent schema with
these additional invariants:

1. **One schema, several backends.** NixOS and system-manager produce and
   verify the same boot intent through different native mechanisms. Home
   Manager may consume read-only boot state or user-scoped tooling where
   useful, but never writes the ESP, Secure Boot state, or NVRAM.
2. **Device class and boot role are independent.** `nixarch`, `nixnas`, and
   `nixvps` are device-class adapters. `primary` and `nixrescue` are boot
   roles. A class translates capabilities; a role identifies the artifact's
   purpose.
3. **No boot is explicit.** A container or other target without firmware
   handoff is neither a degraded `primary` nor an implicit loader choice. It
   composes no boot actuator and declares no ESP, signing, or NVRAM contract.
4. **Policy stays in the private composition.** Public repositories contain
   generic mechanisms, adapters, examples, and tests. Host identity, network,
   cloud, disk, account, key, endpoint, and production-policy facts are
   inputs, never public defaults or embedded incident records.
5. **Artifacts and delivery have separate owners.** nixrescue produces the
   recovery content and runtime. nixboot produces and verifies boot artifacts.
   nixdeploy alone schedules, transports, materializes, rotates and selects
   slots, activates, rolls back, reimages, and reports typed outcomes across
   every plane, class, and boot role.
6. **The booted kernel/initrd and boot-medium contract are boot work.** Class
   backends select and package the boot artifact from facts supplied by
   nixcpu, nixfs, nixstorage, nixluks and other specialist domains. Those
   specialists remain authoritative for the source facts and physical
   provisioning; nixboot owns the projection required to reach switch-root.

This target is not completely implemented yet. The offline NixOS path now
exposes one class-and-role-bearing artifact through `nixboot.imageArtifact` plus the
provider-neutral final-disk gate in B29–B30. The current NixOS backend otherwise exposes
`nixboot.*`; the current system-manager backend exposes
`nixboot.systemdBoot.*`; no Home Manager backend or class/role schema is
exported. Current nixboot maintainer timers and artifact rotation are
therefore migration debt against the nixdeploy boundary, not precedent for a
second delivery system.

## Behaviors

**B1 — grub never wins by accident.**
Regardless of `loader.program`, `boot.loader.grub.enable` is forced to
`false` via `mkOverride 500` so a profile's own `mkDefault true` can never
win on a host that forgot to say otherwise (`modules/nixboot.nix:390-396`).

**B2 — The ESP is declared, never created.**
nixboot never partitions, formats, or mounts the ESP. `esp.mountPoint`,
`esp.byLabel`, and `esp.capacityMiB` are read-only facts it asserts and
verifies against, not instructions it acts on (`modules/nixboot.nix:182-207`).

**B3 — Foreign paths on the ESP are inviolable.**
Every path listed in `esp.foreignPaths` (a vendor firmware-capsule tree,
`fwupd`'s own entry, a rescue-media directory) must still exist after boot.
`nixboot-verify` Check 4 fails loudly if one goes missing
(`modules/nixboot.nix:202-206, 611-619`).

**B4 — Boot counting cannot silently do nothing.**
`bootCounting.tries` is a lanzaboote-stub-only mechanism. Setting it while
`loader.program != "lanzaboote"` is an **assertion failure**, not a
no-op — the exact "setting requested, quietly not applied" bug this module
exists to prevent (`modules/nixboot.nix:225-239, 373-375`).

**B5 — Secure Boot requires the whole chain or none of it.**
`secureBoot.enable = true` asserts `loader.program == "lanzaboote"` *and*
`secureBoot.pkiBundle != null` in the same check — a signed chain with
nowhere to keep its keys is rejected before it can half-exist
(`modules/nixboot.nix:376-379`).

**B6 — Firmware enrollment is always human-run, at the console, in Setup
Mode.**
`nixboot-enroll-sb` is a plain CLI, never a systemd unit, never wired to run
automatically. It refuses to proceed unless it reads
`SetupMode=1` from `efivarfs` itself (`modules/nixboot.nix:292-303,
477-489`). Firmware NVRAM is the one piece of state this module cannot roll
back, so enrollment only happens because a human chose to run it.

**B7 — capacity retention never silently drops the booted generation.**
Stock Lanzaboote chooses only the newest profile links and collects only after
writing them. On a small ESP, that can both evict a long-running current entry
and fail with no space before its own collector runs. With
`generations.capacity.enable`, NixBoot selects the booted generation plus the
newest alternatives within `generations.keep`, removes only unreferenced
Lanzaboote artifacts before installation, and reserves declared write space.
The capacity contract includes fixed files and every protected extra UKI; an
impossible budget is an evaluation failure. `nixboot-verify` still reads
`systemd-bless-boot`, because an existing failed unit is live evidence that a
prior installation violated this invariant.

The retained boot entry is matched by its complete loader-reported identity,
not merely its generation number, and is never reconstructed from
`/run/current-system`: userspace can switch many times while the booted kernel
and `LoaderBootCountPath` remain fixed.

A firmware loader/declared-ESP UUID mismatch is decided from the live
partition table, never from the existence of the mismatch.
`LoaderDevicePartUUID` is written once, at boot, from the medium systemd-boot
was loaded from — a snapshot, not a live pointer, which no installation can
refresh and only a reboot can clear. When the partition firmware recorded is
still reachable on this system, or more than one EFI System Partition is
present, which medium firmware read is in genuine doubt and collection refuses
before touching either partition. When that partition is gone from the system
and the declared ESP is the only one present, there is nothing left to be
wrong about, and refusing is not the safe answer but the fatal one: every
switch then dies inside the bootloader installer, including the switch that
would reach the reboot. Retention warns instead, naming both partitions and
saying only a reboot clears the recording, and installs. If the recorded
booted entry went with the vanished medium, that generation also stops being a
reserved slot and becomes an ordinary retention candidate, so the same
installation puts its entry back. **Not**: an absent booted entry stays fatal
in every other case, including a healthy loader handoff — only the
stale-recording branch may treat it as expected. This is what the unrefined
guard cost: a host that rebuilds its own boot medium (regenerating the ESP's
partition GUID under the running system) built and profile-linked three
generations it never activated, each deployment failing at bootloader
installation and rolling back. B7a is unchanged and deliberately stricter:
`nixboot-verify` still REPORTS the same mismatch as a failure, because a
report cannot deadlock the host it describes.

**B7a — The firmware handoff must name the declared ESP.**
`bootctl status` can find a valid loader on the ESP mounted by NixOS even when
firmware actually loaded one from a different partition. That split would
otherwise let future deployments update one ESP while firmware executes stale
boot code from another. On the systemd-boot/lanzaboote family,
`nixboot-verify` treats bootctl's loader-partition UUID mismatch as a failure;
an operator must recover the firmware handoff before entering a LUKS
passphrase.

**B8 — ESP capacity is warned, never enforced.**
Resizing an ESP is an image reprovision, not a deploy nixboot can perform.
`esp.capacityMiB` only ever produces an eval-time projected-usage warning
(`modules/nixboot.nix:382-385`) and a runtime `df`-based WARN/FAIL in
`nixboot-verify` (`modules/nixboot.nix:588-609`) — it never blocks a switch.

**B9 — A config file for an absent tool is a bug this module surfaces.**
`secureBoot.sbctlCompat` writes `/etc/sbctl/sbctl.conf`; if `tools.sbctl.enable`
is false at the same time, that file exists for a binary that isn't
installed. nixboot emits an explicit warning rather than shipping the
mismatch quietly (`modules/nixboot.nix:386-388`).

The same rule applied to the file's own contents. It is YAML
(`sbctl.conf(5)`), rendered through `builtins.toJSON` so it is valid by
construction rather than by having got the punctuation right, and it is
written only where a `secureBoot.pkiBundle` actually exists to point at —
`sbctlCompat` and `keySource` are both satisfied by their own defaults, so
without that third condition every host enabling nixboot got a config file
naming the literal path `null/keys`. A malformed file here is invisible from
the outside (sbctl exits 0 on a config parse error and simply reports
nothing), which is why `nixboot-verify` Check 5 asserts on sbctl's `--json`
output and treats "no status at all" as its own distinct failure. When
`secureBoot.enable` is declared, the same machine-readable status must also
report `secure_boot: true`; finding the key directory is not proof that the
firmware is actually enforcing those keys.

**B10 — Every managed knob is read back after boot, not just requested.**
`nixboot-verify` runs after boot, reads every managed knob straight off the
live system, and logs `PASS`/`FAIL`/`SKIP` per check, exiting non-zero on
any `FAIL` (`modules/nixboot.nix:355-367, 522-529, 660-664`). Requesting a
boot setting is not evidence it took.

**B11 — Source facts stay authoritative while nixboot owns their boot-time
projection.**
The target class backend owns selection and packaging of the kernel/initrd
that actually boots, plus the boot-medium constraints required to reach
switch-root. nixcpu/nixfs/nixstorage/nixluks remain authoritative for
architecture, filesystem, physical-layout and encrypted-member facts;
nixpower remains authoritative for sleep/ASPM/EPP policy. nixboot consumes
those facts without repeating them or replacing their physical/runtime
mechanisms. The current module has not completed that migration and still
expects consumer-supplied kernel and layout values (`modules/nixboot.nix`,
current SCOPE block).

**B12 — The lanzaboote module is a required composition, not a dependency
this flake pulls in.**
nixboot writes to `boot.lanzaboote.*` — an option surface it does not
define — without importing the lanzaboote flake module itself. Every host
list that imports nixboot must also compose lanzaboote's own module,
including hosts that leave it disabled, or evaluation fails the moment any
host anywhere sets `loader.program = "lanzaboote"`
(`modules/nixboot.nix:60-73, 418-425`).

**B13 — An extra entry's name must not collide with either loader's own
generation-GC prefix, and must resolve to a unique ESP path.**
`extraEntries.<name>.espFileName` has no default and is asserted to end in
`.efi` and never start with `nixos-` — the one prefix both shipped loaders
key their own generation garbage collection on. Two entries (including an
entry's own auto-derived `-prev.efi` rotation target) resolving to the same
ESP path is also an assertion failure, not a silent clobber
(`modules/extra-entries.nix`, the `assertions` block).

**B14 — Signing an extra entry is independent of `secureBoot.enable` and
`loader.program`.**
`extraEntries.<name>.sign.enable` is never derived from `secureBoot.enable`
(which itself requires `loader.program == "lanzaboote"`, per B5) — a host
whose primary chain nixboot does not own at all (`loader.program = "none"`)
can still place a signed extra entry via its own `sign.pkiBundle` (which
defaults to, but is independent of, `secureBoot.pkiBundle`). Equally, a host
with Secure Boot off and no PKI anywhere places an unsigned entry with no
`sign.pkiBundle` required — asserted to be required only when
`sign.enable = true` (`modules/extra-entries.nix`).

**B15 — Registering a firmware boot entry is idempotent and self-healing,
never a naive `efibootmgr --create`.**
`nixboot-register-boot-entry` matches an existing NVRAM entry on BOTH label
and current device path before deciding what to do: a full match is a
true no-op; a label match with a different path (the documented
consequence of an ESP resize changing the `HD()` device path's start LBA
and size) is treated as stale and replaced; no match creates. This is what
makes it safe to run unconditionally on a recurring timer, where a naive
`--create` would pile up duplicate NVRAM entries until firmware boot
variable slots exhaust (`modules/extra-entries.nix`, proved in
`checks/default.nix`'s `register-boot-entry-idempotency`).

**B16 — Every extraEntries entry is read back by `nixboot-verify`.**
The placed UKI's existence under its declared name, and, when signed, its
signature against the declared PKI bundle's db key, are checked the same
way every other managed boot knob is — PASS/FAIL/SKIP, exit non-zero on any
FAIL (`modules/nixboot.nix`, Check 9). `esp.foreignPaths`' own check (B3)
was strengthened alongside this: a `.efi` foreign path is now also checked
for a non-zero size and an intact PE/COFF `MZ` header, not merely
existence — present-but-corrupted is a real, closable gap an existence-only
check silently missed.

**B17 — Booting off USB-attached removable media is one opt-in fact,
deliberately usable without taking on this module's whole boot stance, and
deliberately independent of the removable-vs-NVRAM loader choice.**
`media.usb.enable` only ever adds the initrd kernel modules (`usb_storage`,
`uas`, `xhci_pci`, `ehci_pci`) needed to find and drive a USB-attached boot
device before any root filesystem exists. Two things it deliberately does
NOT do: it never derives, and is never derived from, `loader.efiVariables`
— a warning fires when the two look mismatched (`media.usb.enable = true`
with `efiVariables = "write"`), but nixboot never overrides one from the
other, because a USB dongle permanently wired into one machine is a
legitimate case where they disagree. And unlike every other knob in this
module, its config is wired OUTSIDE the top-level `lib.mkIf cfg.enable` —
the same "usable without adopting this module's whole boot-stance
ownership" shape `extraEntries.*`'s own unconditionally-exposed build
outputs already use — because `nixboot.enable = true` pulls in a bundle of
OTHER opinions (a required `loader.program`, `nixboot-verify`'s readback
checks, `secureBoot.sbctlCompat`'s `/etc/sbctl/sbctl.conf` write) that a host which
already owns its own primary boot chain should not have to take on, or
carefully neutralize one knob at a time, just to reuse this one mechanism
(`modules/nixboot.nix`, the `media` option group + the `config = lib.mkMerge
[...]` restructure at its top).

**B18 — limine is a third `loader.program`, with its own namespace and its
own refusals, never a silent fallthrough into systemd-boot's.**
`loader.program = "limine"` renders into `boot.loader.limine.*` (a stock
nixpkgs module -- unlike lanzaboote, no external flake composition is
needed, `modules/nixboot.nix`'s own "ONE EXTERNAL DEPENDENCY" header note).
Only the knobs that genuinely carry over do: `loader.editor` →
`enableEditor`, `generations.keep` → `maxGenerations`, `loader.efiVariables`
→ the shared `boot.loader.efi.canTouchEfiVariables` (limine's own
`efiInstallAsRemovable` default already reads that). `loader.consoleMode`,
`loader.graceful`, and `loader.selfHeal` are systemd-boot/lanzaboote-only
(they write `boot.loader.systemd-boot.*` or hardcode `bootctl`) and are
**asserted off** under limine, not silently ignored — the same "setting
requested, quietly not applied" bug class B4 refuses for `bootCounting`.
`bootCounting.tries` (B4) and `secureBoot.enable` (B5) are *also* refused
under limine for a sharper reason than mere absence: limine's own Secure
Boot model signs the loader binary once and enrolls a BLAKE2b hash of the
*entire* rendered config (`limine enroll-config`), a whole-config trust
boundary that shares no mechanism with lanzaboote's per-generation UKI
signing — reusing either subsystem would silently promise a guarantee
limine cannot deliver (`modules/nixboot.nix`, the `boot.loader` merge block
and the assertions block).

**B19 — limine's fixed config search order is a shadow trap `nixboot-verify`
checks for on the NixOS backend.**
`<esp.mountPoint>/limine/limine.conf` beats `<esp.mountPoint>/limine.conf`
in limine's own, non-configurable search order; the loser is ignored
SILENTLY, not reported as a conflict. `nixboot-verify`'s Check 1 PASSes or
FAILs on the winning path's presence and separately WARNs if the shadowed,
losing path also exists — inert today, but it would become the ACTIVE config
the instant the winning file ever disappears, with zero warning from limine
itself at that moment.

**B20 — The system-manager backend declares a native systemd-boot + UKI
chain without pretending the host is NixOS.**
`modules/system-manager-systemd-boot.nix` exposes
`nixboot.systemdBoot.*`, not `nixboot.loader.*`, because system-manager has
no `boot.*` option surface or Nix-built kernel closure. It declares the
native Arch package set, discovers actual releases under
`/usr/lib/modules/*/pkgbase`, and builds uniquely-prefixed Type #2 UKIs with
`mkinitcpio --uki` from an explicitly declared command line. The stage,
verify, collect, cutover, and retirement units are manual even when declared:
each sets `restartIfChanged = false` because omitting `wantedBy` alone does not
stop system-manager from starting a changed service during a switch. Staging
builds every UKI outside the ESP, measures the additional ESP bytes required,
and fails with no ESP write if they will not fit. Only then does it write a separate
`EFI/systemd/systemd-bootx64.efi`, `loader.conf`, and NixBoot-owned UKIs; it
never changes `EFI/BOOT/BOOTX64.EFI`, NVRAM, or Secure Boot enrollment.
An operator must physically boot the staged loader once before a separately
reviewed cutover. This is the retained recovery path, not an imperative
escape hatch: the files, commands, package set, and gates are all declared.
Once the explicit stage gate is enabled, NixBoot also renders its own
post-transaction pacman hook: native kernel `pkgbase` or systemd-boot EFI
updates rerun the declared stage unit, so later upgrades rebuild the same
UKI set rather than depending on a retired foreign-loader hook.

**B21 — Limine retirement is a separate, post-boot manual operation.** A
system-manager host may set `nixboot.systemdBoot.retireLimine.enable` only
with `cutover.enable` and explicit legacy-artifact and protected-path lists.
Before removing anything, the unit reruns NixBoot verification, requires a
systemd-boot `BootCurrent` and first `BootOrder` entry, and finds exactly one
Limine NVRAM path to delete. It masks the generic `mkinitcpio` and `sbctl`
hooks, removes only declared files/packages, uses `rmdir` only for declared
empty directories, and checks the protected path hashes afterwards. A staged
loader or an EFI file alone is never grounds to delete the current loader.
When Secure Boot signing is enabled, an explicit root-owned runtime
`secureBoot.sbctlConfig` is mandatory. That configuration is the host's
secret-delivery boundary: NixBoot invokes `sbctl` through it but never
materializes or defaults a private-key location. The explicit stage signs its
separate systemd-boot EFI binary and NixBoot-owned UKIs under that identity;
it does not sign or replace the active fallback until the separately reviewed
cutover.
The optional `cutover.enable` renders a second manual unit only after staging
is enabled. It reruns stage verification, uses `bootctl install` with EFI
variables explicitly enabled, and then signs both final loader copies when
Secure Boot is configured. It never has an automatic systemd dependency.

**B21 — `secureBoot.pkiBundle` / `keySource` actually reach the thing that
signs UKIs, not just the tools that assume it did.**
Every other Secure-Boot-adjacent write in this module (`sbctlCompat`'s
`/etc/sbctl/sbctl.conf`, `nixboot-enroll-sb`, `tools.sbctl`'s default,
`extraEntries.*.sign.pkiBundle`'s own default) reads `secureBoot.pkiBundle`
as *the* bundle location — but `boot.lanzaboote.pkiBundle` and
`boot.lanzaboote.autoGenerateKeys.enable` (the two lanzaboote-owned options
that decide where `lzbt install` actually looks for keys, and whether it
mints its own) are written from `secureBoot.pkiBundle`/`keySource` too, not
left for lanzaboote's own defaults to disagree with everything else
silently. `keySource = "autogenerate"` also carries the landlock/ENOENT
workaround (`generate-sb-keys.service`'s `ExecStart` override) confirmed by
direct reproduction, gated on the identical condition
lanzaboote itself gates that unit's existence on
(`modules/nixboot.nix`, the `boot.lanzaboote.pkiBundle` /
`autoGenerateKeys.enable` writes and the `generate-sb-keys` override).

**B22 — `remoteUnlock.*` delivers a headless in-initrd passphrase prompt over
SSH using only a TPM-gated identity.**
`remoteUnlock.enable` brings up a NIC and sshd and delivers the host key as a TPM2-sealed
systemd CREDENTIAL that `nixboot-seal-hostkey` generates and re-seals
SELF-HEALINGLY (a real decrypt self-test against the live TPM/PCR state,
not mere file existence — the gate required to survive a Secure Boot key
enrollment). Before a credential exists, or when TPM/PCR unseal fails, sshd
has no host identity and the remote channel stays down; no unpinned fallback
is permitted. The sealed path also forces `Restart = "no"` on the initrd sshd unit (`mkForce`,
the one write in this whole file that genuinely needs it rather than
`mkOverride 500` — nixpkgs' own `initrd-ssh.nix` sets `Restart = "on-failure"`
at *plain* priority, which `mkOverride 500` would lose to silently) so a
single post-enrollment stale credential costs exactly one failed TPM2
unseal instead of a retry storm that can drive an fTPM into dictionary-attack
lockout. There is no plaintext or ephemeral fallback. The configuration is
refused, not left silently inert, when it cannot possibly work: enabling
remote unlock without `secureBoot.enable` (only the lanzaboote stub delivers the
sealed credential into the initrd), or an empty `authorizedKeys` (initrd
sshd is key-only) are each an assertion failure. `nixboot-verify`'s Check 8
re-runs the seal service's own decrypt self-test post-boot and additionally
confirms the decrypted key's fingerprint matches the one published for an
operator to pin — a mismatch there would mean an operator trusting the
wrong key on their next connection (`modules/nixboot.nix`, the
`remoteUnlock` option group, the `ru.enable`-gated `config` blocks, and
nixboot-verify Check 8).

**B23 — Remote unlock's systemd-credential writes cannot silently land nowhere.**
Every write it makes — especially `LoadCredentialEncrypted` — lives under
`boot.initrd.systemd.services.*`, an option tree nixpkgs' own systemd-initrd
module only renders into the actual initrd when
`boot.initrd.systemd.enable = true` (verified against that module's own
`config = mkIf (config.boot.initrd.enable && cfg.enable)` gate). Turning on
`remoteUnlock.enable` without also setting `boot.initrd.systemd.enable` is therefore an assertion
failure, not a boot that quietly serves no host key at all — the same
"setting requested, quietly not applied" bug class B4 already refuses for
`bootCounting` (`modules/nixboot.nix`; proved both directions in
`checks/default.nix`).

The runtime producer is also exported as `lib.mkTpmSshCredential`. This keeps
the credential format, name, PCR self-test, atomic replacement, and failure
semantics identical for system-manager hosts whose shared rescue consumes the
credential even though their native primary initrd does not use nixboot's
NixOS `remoteUnlock` module.

**B24 — `nixboot-enroll-sb` is forced and shellchecked by `nix flake check`
even when no host currently turns it on.**
Exposed as `system.build.nixbootEnrollSb` (mirroring
`system.build.extraEntryMaintainers` / `nixbootRegisterBootEntry` above)
rather than only ever
constructed inline at its `environment.systemPackages` call site — a
`writeShellApplication`'s shellcheck pass only runs when something actually
builds the derivation, and reading `environment.systemPackages` alone does
not (`modules/nixboot.nix`, the `enrollSb` binding; forced in
`checks/default.nix`'s `extraEntryMaintainerBuilds`).

**B25 — A booted kernel that no longer exists on disk is stated, not
inferred from a downstream symptom.**
On a system-manager host, pacman owns the kernel and a kernel upgrade
replaces `/usr/lib/modules/<release>` wholesale. Modules already resident in
the running kernel keep working, so nothing observable changes at the moment
of the upgrade; the first on-demand `modprobe` after it is what fails, and it
fails inside whatever subsystem asked first, with an error naming that
subsystem rather than the kernel. `nixboot-booted-kernel-verify` runs after
boot and again after every native kernel transaction (its own
`96-nixboot-booted-kernel.hook`, ordered after the stage hook, `restart`
rather than `start` so a RemainAfterExit oneshot re-reports instead of
no-opping on the very event that invalidated its last verdict). It answers
two questions: whether the running release still has a module tree, and
whether that release is still the one its native package installs — the
second stays meaningful when a module-preserving native hook keeps the first
green while the package has moved on. A failure is a failed unit plus the
full verdict at `/run/nixboot/booted-kernel`; `/run`, because a reboot is
what resolves the condition, so a copy surviving into the next boot could
only be a lie. It is on by default (`bootedKernel.verify.enable`), like the
NixOS backend's `verify.enable` and for the same reason B4 exists: the
failure is silent by construction.
**Not**: this unit never reboots, never installs, never restores a module
tree. That line is the one nixnet draws for itself in its own `BEHAVIORS.md`
(`OWN-2`) — a layer that acts on its own judgement destroys the evidence of
the fault underneath it and makes its own action the story. Reboot and
reimage are deploy concerns, a different blast radius with a different owner;
what this unit owes an operator is an unambiguous statement, not a decision.
Nor is it a substitute for a module-preserving native hook: it reports the
condition, it does not prevent it
(`modules/system-manager-systemd-boot.nix`, the `bootedKernelVerifyScript`
and `bootedKernelHookFile` bindings; proved in `checks/system-manager.nix`).

**B26 — Reclaiming NixBoot's own ESP garbage never depends on the step that
needs the space.**
Collection used to run only after a successful staging. That ordering
deadlocks a full ESP: staging cannot write without space, the space is held
by artifacts only collection frees, and collection sat behind the step it
existed to unblock — so the boot subsystem loses the ability to update itself
and reports it only as a capacity error. The desired file set is therefore
derived from the DECLARATION (`kernels` → `<prefix>-<id>[-fallback].efi`),
never from what a build produced, which is what makes collection possible
with no `mkinitcpio` run, no staging directory, and no free space. It runs
before the capacity gate inside staging, and as its own
`nixboot-systemd-boot-collect` unit ordered after nothing, so an operator can
reclaim without a staging run succeeding first. Exactly one implementation
serves both call sites: two answers to "what does NixBoot own" is how one of
them deletes what the other protects. A capacity failure states need and have
in **MiB** — the unit `esp.capacityMiB` and every other ESP budget in this
family is declared in — and still refuses with no ESP write.
**Not**: collection never removes the entry firmware reports as
`Current Entry`, even when the declaration no longer names it. A running
kernel's boot entry does not become garbage because a config changed, and
firmware is the only authority on which entry that is — the same invariant
B25 and the Lanzaboote retention path enforce at their own layers. Because of
that, **membership in the declared set is not a fallback for asking firmware,
and collection fails closed when firmware cannot be asked**: no `bootctl`, a
`bootctl` reporting a different partition UUID, or no `Current Entry` line
each mean nothing at all is deleted. The two questions only look
interchangeable — a booted entry missing from the declared set is the exact
case this exclusion exists for, so treating the declared set as a second line
of defence deletes precisely the file it was meant to save. (It did: an
earlier revision of this behavior made `bootctl` optional and let that case
fall through to `rm`.) The refusal is a failed
`nixboot-systemd-boot-collect` unit — an operator who asked for reclamation
and got none must see it — while staging only notes the refusal and lets its
own capacity gate speak, since collection aids staging and never gates it. The
ownership boundary is unchanged and unchanged deliberately: only the unique
UKI prefix is ever a candidate, so a foreign rescue image, vendor firmware
capsule, Limine artifact, or the active fallback is never touched. Nor does
collection ever drop a *declared* artifact to make room: an ESP too small for
what the host declares is a declaration to change (a kernel's
`fallback = false` is usually the largest single UKI) or an ESP to grow, and
that is the operator's call, not this module's
(`modules/system-manager-systemd-boot.nix`, the `desiredUkiNames`,
`collectFunction` and `collectScript` bindings; proved in
`checks/system-manager.nix`, including the positional ordering assertion).

**B27 — No script in this family invokes a command by bare name.**
A `systemd.services.<name>.script` gets a unit PATH that on a system-manager
host contains no native tools at all (measured: coreutils, findutils,
gnugrep, gnused, systemd-minimal — no util-linux, no `/usr/bin`). A bare
command name there is a bare `127` with no message, which is precisely the
failure this backend's own `required native command is absent` preflight
exists to replace. Every native tool is reached as `/usr/bin/<tool>` and
listed in its script's preflight loop. The same rule binds the
`writeShellApplication` wrappers from the other direction: every command a
wrapper runs must appear in its `runtimeInputs`, and a Nix build sandbox is
not evidence that it does — stdenv already carries `sed`, `cmp` and friends
on PATH, so an execution test inside the sandbox passes while the systemd
unit that runs the same script in production exits 127
(`lib/register-boot-entry.nix`'s `gnused`; proved in
`checks/system-manager.nix`'s `scripts/no-bare-native-command-invocations`).

**B28 — A boot splash is selected, never half-wired.**
`nixboot.systemdBoot.plymouth.enable` is the first thing in this repo that is
not a boot *mechanism*: it answers what a human sees while a machine boots, not
what boots it. It is here anyway because the two things a splash actually needs
are this backend's own two surfaces and nobody else's — the word `splash` on the
kernel command line, and a `plymouth` hook in the initramfs generator — and
because plymouth's whole job is finished before any desktop exists, so nothing
on the desktop side can own it. **The widening stops at selection.** The option
puts the native package into `archPackages` and arranges neither of the other
two: `kernelCmdline` stays an opaque string rendered verbatim into every staged
UKI, and `/etc/mkinitcpio.conf` keeps the single writer it has always had (the
line `tools.hwdetect` already draws). The option's own description states both
gaps in those words, because an option that overpromises here is worse than a
narrow one — what it would hide is a cold boot with no kernel log and no splash
to replace it, on a backend where the command line is baked into the UKI and
there is no boot-menu escape.
**Not**: selecting the package is not inert, and this contract says so rather
than implying a package-list line. Pacman's payload rewires the stage-2 unit
graph on arrival — its own `.wants` symlinks pull `plymouth-start.service` and
`plymouth-read-write.service` into `sysinit.target`, `plymouth-quit.service` and
`plymouth-quit-wait.service` into `multi-user.target` — and
`plymouth-start.service` gates only on
`ConditionKernelCommandLine=!plymouth.enable=0` and
`ConditionVirtualization=!container`, never on `splash` (measured: `pacman -Fl`
plus the unit files themselves, package 26.134.222-2). That is why it is off by
default and a stated decision rather than a side effect of declaring a boot
chain. It is also the one place this repo touches the far side of the
`switch-root` boundary: those quit units run in stage 2, and NixBoot owns none
of them — it owns the selection, and the package owns its unit graph.
**Not**: no assertion binds this option to `kernelCmdline`. A splash rollout on
a machine that must be physically rebooted is legitimately three separate steps
— package, hook, command line — taken one at a time in whatever order the
operator can test, and refusing the intermediate states would refuse the only
safe way to do it. NixOS hosts get nothing here: nixpkgs' own `boot.plymouth.*`
already owns the initrd contents and the kernel parameters, and a second owner
of one knob is the mistake this whole contract is written against
(`modules/system-manager-systemd-boot.nix`'s `plymouthPackage` binding and the
`plymouth.enable` option; proved in `checks/system-manager.nix`).

**B29 — An offline NixOS image has one checked boot-artifact producer.**
`nixboot.imageArtifact.enable` requires a generic `deviceClass`, independent
of `role`, and derives the ESP payload from the evaluated
system's own toplevel, kernel, initrd and `boot.kernelParams`; it exposes the
checked tree as `system.build.nixbootBootArtifact` and a machine-readable
manifest as `system.build.nixbootBootArtifactManifest`. `init=` is never an
input: `lib.mkSystemdBootArtifact` prepends the exact
`${config.system.build.toplevel}/init` and rejects a second caller-supplied
one. The finished tree carries systemd-boot at its normal path and the UEFI
removable-media fallback, one Type-1 entry, its exact kernel/initrd, and the
`entries.srel` marker. Both EFI executables are checked as PE images and every
entry path and command line is read back during the build.
The manifest distinguishes the immutable image fact
`firmware.initialHandoff = "removable"` from the running host's declared
`firmware.steadyStateHandoff`: an offline disk cannot contain a VM's or
machine's NVRAM entry, even when the system is allowed to create and repair
one after that fallback boot.
The manifest records `firmwareVerified = false` and
`initrdAuthenticatedByKernel = false`: a Type-1 entry with a separate initrd
cannot honestly claim the signed-UKI guarantee.

An offline tree has never run `bootctl install`, so the image artifact derives
`loader.selfHeal = true`; explicitly turning it off is an assertion failure.
This closes the first-switch failure in which the loader files exist and the
ESP still lacks systemd-boot's install state. Self-heal passes
`--no-variables` only for a `removable` steady-state handoff; a host declaring
`write` re-asserts both the loader files and its NVRAM entry after every boot.
The backend currently requires
`loader.program = "systemd-boot"`: it does not relabel an unsigned split
kernel/initrd as a signed-UKI or Limine artifact merely to make another enum
value evaluate (`modules/image-artifact.nix`,
`lib/mk-systemd-boot-artifact.nix`; proved in
`checks/default.nix` and `checks/image-artifact.nix`).

**B30 — The provider receives a checked disk, not merely checked source
files.**
`lib.mkEfiDiskImageVerifier` and `lib.mkEfiDiskImageCheck` consume declarative
storage/provider facts: an optional image-materializer adapter, logical sector
size, the ESP partition label, and a list of required GPT
label/type-GUID/filesystem tuples. They contain no provider-name or
image-format dispatch table. Raw input needs no adapter; any compressed,
qcow2, VHD, VMDK or provider-specific envelope supplies runtime inputs plus a
script that materializes raw bytes, after which the same checks apply.
The verifier parses the final raw disk at
the declared sector size, requires GPT, resolves every required label exactly
once, checks its exact type GUID and filesystem signature, then reads every
file from the FAT ESP without mounting and compares it byte-for-byte with the
checked nixboot artifact. Extra ESP files are refused unless named explicitly
in `allowedExtraEspFiles`; an image assembler cannot smuggle in a second
default candidate through an otherwise valid FAT filesystem. When supplied
with the artifact manifest and a root-path projection, it then maps the
manifest's exact runtime `init` through the declared runtime/image prefixes,
reads the unmounted ext2/3/4 or btrfs partition, and requires that file to
exist and be executable. This is the gate that distinguishes `/@nix/store` from the bootable-
looking but unreachable `/@nix/nix/store`. Without a root projection, output
is explicitly scoped to firmware/loader handoff and never claims to reach
`init`.

**Not**: this does not create, size or format a partition, decide a root
filesystem, upload an image, reimage a VM or select a recovery action. The
layout owner supplies the facts and materializes the disk; nixdeploy decides
whether and where it moves. The gate only turns their disagreement into a
build failure before provider upload (`lib/mk-efi-disk-image-verifier.nix`,
`lib/mk-efi-disk-image-check.nix`; positive and deliberate wrong-GPT-type /
tampered-ESP refusals in `checks/image-artifact.nix`).

**B31 — Secure Boot signing is a two-phase, secret-safe boundary.**
`lib.mkUkiSigningRequest` emits an unsigned UKI and a manifest binding its
SHA-256 digest to a generic device class, boot role, version and target EFI
architecture. `lib.mkUkiSigner` receives the db private key and certificate
only as runtime paths, signs outside the Nix store, refuses to replace an
existing output, and emits the signed digest plus db-certificate fingerprint.
`lib.mkSignedUkiVerifier` independently requires the original request, signed
manifest, signed bytes and expected db certificate to agree. The same common
nixrescue request can therefore receive different device trust-root signatures
without rebuilding or forking its package payload.

`lib.mkPkiArchiveTools` permits the encrypted PKI archive to be public: it uses
interactive `age --passphrase`, offers no unattended passphrase input, decrypts
only into tmpfs for one command, and removes the plaintext afterwards. Nixboot
does not mandate a second password; the passphrase value remains an operator
fact outside this public mechanism. Public ciphertext permits offline guessing,
so the existing master passphrase must already resist that attack
(`lib/mk-uki-signing-request.nix`,
`lib/mk-uki-signer.nix`, `lib/mk-signed-uki-verifier.nix`,
`lib/mk-pki-archive-tools.nix`; positive signature and wrong-certificate /
post-signature-tamper refusals in `checks/uki-signing.nix`).

## Which behaviors become automated tests vs. stay observed

- **Automatable** (a `pkgs.testers.nixosTest` VM can assert these directly):
  B1, B2, B3, B4, B5, B7, B9, B10, B12, B13, B14, B16, B17, B18, B19, B22
  (the real seal/reseal/fail-closed sequence needs a TPM2 — swtpm is
  sufficient — rather than eval alone).
- **Automated today in disposable VMs:** B22's TPM-gated SSH identity lifecycle
  (real swtpm encryption/decryption, stable identity under an unchanged PCR,
  fail-closed behavior after extending PCR 7, and one successful controlled
  reseal) and B31's firmware handoff (OVMF Setup Mode, synthetic key creation,
  signing and independent verification outside the Nix store, enrollment into
  only the disposable guest, reboot with Secure Boot enabled in user mode, and
  execution of the exact signed UKI).
- **Automated today, at the eval/build level, without a VM** (see
  `checks/default.nix` and `checks/system-manager.nix`): B13, B14, B17, B18,
  B19, B20 (the option-surface and rendering half — real system-manager
  enrollment enforcement is out of this repo's reach, see
  `checks/system-manager.nix`'s own header), B21 (pkiBundle/keySource reach
  `boot.lanzaboote.*`, and the landlock workaround applies only on the
  autogenerate path), B23 (the `boot.initrd.systemd.enable` requirement
  fires when remote unlock is active and stays silent when it is not),
  B24 (`nixbootEnrollSb` is present in `system.build` and its derivation
  builds/shellchecks cleanly), B25 (the unit and its pacman hook are rendered
  when enabled and absent when not, the unit is the only one in the backend
  that is `wantedBy` a target, the hook `restart`s rather than `start`s, and
  the script carries no reboot/install/restore verb — the REST of B25, that a
  real pacman kernel transaction actually deletes the running module tree and
  trips the unit, is observed: it needs a real Arch host and a real upgrade),
  B26 (collection is rendered before the capacity gate — asserted
  positionally, not by mere presence, since the broken version also mentioned
  collection; the collect unit is ordered after nothing and references
  neither `mkinitcpio` nor the staging directory; the booted-entry exclusion
  and the MiB-denominated capacity failure are both present), B27 (no
  `head`/`sed`/`dirname` is invoked by bare name in any rendered script),
  B28 (the package is selected when asked for, is absent from a backend that
  merely declares a boot chain, and — the half that actually protects the
  contract's promise — leaves `kernelCmdline` byte-identical, so a later
  revision cannot start composing `splash` in unnoticed; that the initramfs
  hook and the command-line word remain the consumer's is a gap this repo
  states rather than a behavior it can assert), B29 (tree + manifest outputs,
  the exact generated `init=`, fallback loader and self-heal requirement,
  both first-boot/steady-state handoff combinations and their opposite
  `--no-variables` behavior), B30 (complete synthetic btrfs and ext4 GPT
  disks pass, zstd transport passes, and
  a 4096-byte-sector image is refused under a 512-byte provider declaration,
  and otherwise-valid images with a wrong root type, one altered ESP file, an
  undeclared extra entry, or the selected system under `/@nix/nix/store` are
  executed and refused), B31 (the signer and verifier are built and executed
  against a synthetic db key; the expected certificate passes while a wrong
  certificate and a byte appended after signing are both refused; the
  interactive encrypted-PKI tools also build and shellcheck, explicitly tell
  the operator to enter the same disk-encryption master passphrase, and expose
  no unattended passphrase/key ingress, all without receiving a real
  passphrase or key),
  B7's firmware-handoff branches (the retention wrapper's own script is RUN
  against stand-in `bootctl`/`findmnt`/`lsblk` binaries and a scratch ESP,
  once per direction: it installs on a healthy handoff and on a recorded
  partition that is provably gone, and refuses — deleting nothing, running no
  `lzbt` — when that partition is still reachable, when a second EFI System
  Partition exists, or when the booted entry is missing without a stale
  recording to explain it; a `hasInfix` on the module source cannot tell
  "refuses when it must" from "refuses always", and that difference was an
  outage), and B15's idempotency/self-heal proof (a real
  invocation of the registrar against a faked `efibootmgr` inside the Nix
  build sandbox — no VM, no KVM, no real firmware, but a genuine execution
  rather than an eval-only assertion).
- **Observed / operational** (need real firmware, a real TPM, or real NVRAM
  state that a disposable VM cannot faithfully reproduce): B6 (Setup Mode
  gating against real UEFI variables), B8 (a real ESP actually approaching
  its declared capacity over many generations), the REST of B15 (that a
  real firmware implementation accepts the entry and actually offers it at
  POST — the registrar's own logic is proved, real firmware quirks are not),
  and the REST of B22 (a physical TPM dictionary-attack lockout and a physical
  machine's actual Secure Boot enrollment changing PCR 7; the disposable VM
  proves the intended failure/reseal behavior by extending that PCR directly,
  not the quirks of a particular firmware/TPM pair).

`checks/default.nix` is this repo's first automated test suite — eval-level
assertions plus the build-level execution proofs described above (the boot
entry registrar's idempotency, and both directions of the retention wrapper's
firmware-handoff decision). `checks/tpm-ssh-credential.nix` and
`checks/secure-boot-uki.nix` add the stateful VM proofs for swtpm and OVMF.
Remaining physical-hardware experiments are tracked in
[`experiments/README.md`](experiments/README.md) and
[`studies/README.md`](studies/README.md).

## Priority discipline (how B1 and the loader writes are actually enforced)

`mkOverride 500` is not an arbitrary number: NixOS's own `mkDefault` sits at
priority 1000 and plain `=` at priority 100. 500 is the one value that beats
a profile's default while still losing cleanly to anything more specific a
host says about itself — including that host's own `mkForce` (priority 50).
Reaching for `mkForce` inside this module instead would risk two
same-priority definitions disagreeing the moment a host *also* used
`mkForce` for a different value on the same option — an eval error, not a
graceful override. Full reasoning: `modules/nixboot.nix:75-86`.
