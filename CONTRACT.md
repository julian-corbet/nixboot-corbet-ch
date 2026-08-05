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
- **The ESP already exists; nixboot never creates it.** Partitioning,
  formatting, and mounting are a disk-layout tool's job. nixboot only
  *declares* what must already be true about an ESP so it can assert and
  verify (`modules/nixboot.nix:30-35, 182-207`).
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

**B7 — `generations.keep` must outlive this host's own rebuild cadence.**
The kept-generation count is the guaranteed manual rollback path; it must
exceed how many generations this host can build in one uptime, or the
*currently running* system drains out of its own boot menu before anyone
needs it. This is a documented, previously-shipped incident, not a
hypothetical: `keep = 5` at roughly 10 generations/day emptied the menu
within hours (`modules/nixboot.nix:210-222`).
For a lanzaboote host using `bootCounting.tries`, the same loss leaves
`systemd-bless-boot` unable to mark the running entry good. `nixboot-verify`
therefore reads that unit's final state, rather than treating a retained count
alone as evidence that the active generation survived.

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
output and treats "no status at all" as its own distinct failure.

**B10 — Every managed knob is read back after boot, not just requested.**
`nixboot-verify` runs after boot, reads every managed knob straight off the
live system, and logs `PASS`/`FAIL`/`SKIP` per check, exiting non-zero on
any `FAIL` (`modules/nixboot.nix:355-367, 522-529, 660-664`). Requesting a
boot setting is not evidence it took.

**B11 — Kernel packaging, disk-layout identity, and power policy are foreign
domains, always.**
Even though all three are boot-adjacent, nixboot never touches kernel
variant/march/LTO choices, LUKS/ZFS/impermanence identity, or sleep/ASPM/EPP
policy — a second manager on any of those surfaces is exactly the
two-mechanisms-one-knob failure this module's own layering rule forbids
(`modules/nixboot.nix:36-50`).

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
`mkinitcpio --uki` from an explicitly declared command line. The stage and
verify units are manual even when declared: staging writes a separate
`EFI/systemd/systemd-bootx64.efi`, `loader.conf`, and NixBoot-owned UKIs,
but never changes `EFI/BOOT/BOOTX64.EFI`, NVRAM, or Secure Boot enrollment.
An operator must physically boot the staged loader once before a separately
reviewed cutover. This is the retained recovery path, not an imperative
escape hatch: the files, commands, package set, and gates are all declared.
Once the explicit stage gate is enabled, NixBoot also renders its own
post-transaction pacman hook: native kernel `pkgbase` or systemd-boot EFI
updates rerun the declared stage unit, so later upgrades rebuild the same
UKI set rather than depending on a retired foreign-loader hook.
When Secure Boot signing is enabled, an explicit root-owned runtime
`secureBoot.sbctlConfig` is mandatory. That configuration is the host's
secret-delivery boundary: NixBoot invokes `sbctl` through it but never
materializes or defaults a private-key location.

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
direct reproduction on the source host, gated on the identical condition
lanzaboote itself gates that unit's existence on
(`modules/nixboot.nix`, the `boot.lanzaboote.pkiBundle` /
`autoGenerateKeys.enable` writes and the `generate-sb-keys` override).

**B22 — `remoteUnlock.*` delivers a headless in-initrd secret prompt over
SSH, with the sealed host key as the default and a plaintext fallback,
neither of which is allowed to silently fail to arrive.**
Bringing a NIC + sshd up in the initrd is common to both paths
(`remoteUnlock.enable`). Path A (`sealHostKey = true`, the default, folded
with `remoteUnlock.tpm2.enable`) delivers the host key as a TPM2-sealed
systemd CREDENTIAL that `nixboot-seal-hostkey` generates and re-seals
SELF-HEALINGLY (a real decrypt self-test against the live TPM/PCR state,
not mere file existence — the exact gate whose absence bricked the source
host's first implementation across a Secure Boot key enrollment), serves an
EPHEMERAL, loudly-banner-flagged key on a genuine first boot before any
seal exists, and forces `Restart = "no"` on the initrd sshd unit (`mkForce`,
the one write in this whole file that genuinely needs it rather than
`mkOverride 500` — nixpkgs' own `initrd-ssh.nix` sets `Restart = "on-failure"`
at *plain* priority, which `mkOverride 500` would lose to silently) so a
single post-enrollment stale credential costs exactly one failed TPM2
unseal instead of a retry storm that drove a real fTPM into dictionary-attack
lockout. Path B (`sealHostKey = false`) embeds a plaintext, build-time
`hostKeyPath` instead — LAN/tailnet-only, no TPM needed. Both paths are
refused, not left silently inert, when they cannot possibly work: enabling
`remoteUnlock` with neither a working seal path nor a plaintext key,
sealing without `secureBoot.enable` (only the lanzaboote stub delivers the
sealed credential into the initrd), or an empty `authorizedKeys` (initrd
sshd is key-only) are each an assertion failure. `nixboot-verify`'s Check 8
re-runs the seal service's own decrypt self-test post-boot and additionally
confirms the decrypted key's fingerprint matches the one published for an
operator to pin — a mismatch there would mean an operator trusting the
wrong key on their next connection (`modules/nixboot.nix`, the
`remoteUnlock` option group, the `ru.enable`-gated `config` blocks, and
nixboot-verify Check 8).

**B23 — Path A's systemd-credential writes cannot silently land nowhere.**
Every write Path A makes — `LoadCredentialEncrypted`, the credential-aware
`preStart`, `boot.initrd.systemd.storePaths` — lives entirely under
`boot.initrd.systemd.services.*`, an option tree nixpkgs' own systemd-initrd
module only renders into the actual initrd when
`boot.initrd.systemd.enable = true` (verified against that module's own
`config = mkIf (config.boot.initrd.enable && cfg.enable)` gate). Turning on
`remoteUnlock.sealHostKey` (the default) together with `remoteUnlock.tpm2.enable`
without also setting `boot.initrd.systemd.enable` is therefore an assertion
failure, not a boot that quietly serves no host key at all — the same
"setting requested, quietly not applied" bug class B4 already refuses for
`bootCounting`. Path B needs no such assertion: `boot.initrd.network.ssh.hostKeys`
and `boot.initrd.secrets` are rendered by the classic (non-systemd) initrd
builder too (`modules/nixboot.nix`, the new assertion in the `ru.enable`
block; proved both directions in `checks/default.nix`).

**B24 — `nixboot-enroll-sb` is forced and shellchecked by `nix flake check`
even when no host currently turns it on.**
Exposed as `system.build.nixbootEnrollSb` (mirroring
`system.build.extraEntryMaintainers` / `nixbootRegisterBootEntry` above, and
the source host's own `system.build.sbEnroller`) rather than only ever
constructed inline at its `environment.systemPackages` call site — a
`writeShellApplication`'s shellcheck pass only runs when something actually
builds the derivation, and reading `environment.systemPackages` alone does
not (`modules/nixboot.nix`, the `enrollSb` binding; forced in
`checks/default.nix`'s `extraEntryMaintainerBuilds`).

## Which behaviors become automated tests vs. stay observed

- **Automatable** (a `pkgs.testers.nixosTest` VM can assert these directly):
  B1, B2, B3, B4, B5, B7, B9, B10, B12, B13, B14, B16, B17, B18, B19, B22
  (the real seal/reseal/ephemeral-fallback/DA-lockout-avoidance sequence
  needs a real TPM2 — swtpm — and a real reboot to prove, not eval alone).
- **Automated today, at the eval/build level, without a VM** (see
  `checks/default.nix` and `checks/system-manager.nix`): B13, B14, B17, B18,
  B19, B20 (the option-surface and rendering half — real system-manager
  enrollment enforcement is out of this repo's reach, see
  `checks/system-manager.nix`'s own header), B21 (pkiBundle/keySource reach
  `boot.lanzaboote.*`, and the landlock workaround applies only on the
  autogenerate path), B23 (the `boot.initrd.systemd.enable` requirement
  fires when Path A is active and stays silent — proved in both
  directions — when it is not, and Path B is proved unaffected either way),
  B24 (`nixbootEnrollSb` is present in `system.build` and its derivation
  builds/shellchecks cleanly), and B15's idempotency/self-heal proof (a real
  invocation of the registrar against a faked `efibootmgr` inside the Nix
  build sandbox — no VM, no KVM, no real firmware, but a genuine execution
  rather than an eval-only assertion).
- **Observed / operational** (need real firmware, a real TPM, or real NVRAM
  state that a disposable VM cannot faithfully reproduce): B6 (Setup Mode
  gating against real UEFI variables), B8 (a real ESP actually approaching
  its declared capacity over many generations), the REST of B15 (that a
  real firmware implementation accepts the entry and actually offers it at
  POST — the registrar's own logic is proved, real firmware quirks are not),
  and the REST of B22 (a real TPM2 dictionary-attack lockout, and a real
  Secure Boot key enrollment actually changing PCR 7 on real firmware — the
  source host's own field incidents, not reproducible in a disposable VM
  suite without swtpm PCR-extension support this repo does not yet drive).

`checks/default.nix` is this repo's first automated test suite — eval-level
assertions plus the one build-level idempotency proof described above. A
full `pkgs.testers.nixosTest` VM suite covering the boot path itself (real
UEFI via OVMF, real UKI discovery) remains future work — see
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
