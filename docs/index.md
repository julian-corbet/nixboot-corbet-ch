# nixboot

nixboot currently provides a full NixOS boot module and a narrower
system-manager backend. The NixOS module declares a coherent loader, ESP,
generation-retention, boot-counting, Secure Boot, and post-boot verification
contract. The system-manager backend produces the equivalent safe subset
through a foreign host's native kernel and package tooling.

This page is the reader-facing walkthrough. The option-by-option contract —
what nixboot guarantees, with assertions and warnings as the enforcement
mechanism — is [`CONTRACT.md`](../CONTRACT.md). The module itself, with
every option's own description, is
[`modules/nixboot.nix`](../modules/nixboot.nix).

The security posture and firmware-recovery decisions that guide a consumer's
host values live in [Boot Security And Recovery](security-recovery.md). It
records the passphrase-only data-unlock invariant, rescue boundary, key
custody, and the different interactive and headless recovery paths without
putting any private host values into this public repository.

## Target schema and current boundary

The target is one boot-intent schema across NixOS, system-manager, and Home
Manager wherever a plane can participate without becoming a second boot
actuator. NixOS and system-manager produce and verify boot artifacts; Home
Manager may expose read-only status or user-scoped tooling, never ESP,
Secure Boot, or NVRAM writes.

Device class (`nixarch`, `nixnas`, or `nixvps`) and boot role (`primary` or
`nixrescue`) are independent axes. A container has an explicit no-boot case:
no role, no ESP, and no actuator. nixrescue owns the recovery content and
runtime; nixboot owns construction and verification of the boot artifact.
nixdeploy alone owns delivery across every plane, class, and role, including
scheduling, transport, materialization, slot rotation and selection,
activation, rollback, reimage, and typed outcomes. The private composition
supplies all host identities and chosen production values.

That common schema is not implemented today. The NixOS option tree is
`nixboot.*`, system-manager still uses `nixboot.systemdBoot.*`, and no Home
Manager module or class/role schema is exported. Current maintainer timers
and artifact rotation in nixboot are migration debt against the nixdeploy
boundary. See
[`CONTRACT.md`](../CONTRACT.md#architecture-target-beyond-the-current-option-surface)
for the migration invariants.

## The option groups

**`loader.*`** — which program installs to the ESP (`systemd-boot`,
`lanzaboote`, `limine`, or `none` for a guest with no firmware of its own)
and every knob of its menu that actually transfers across all three:
timeout, editor access, whether firmware gets an NVRAM entry
(`efiVariables`). Three knobs are systemd-boot/lanzaboote-only and are
**asserted off** under `limine` rather than silently ignored: console mode,
whether an install failure aborts a `switch-to-configuration` or only warns
(`graceful`), and whether the ESP needs its bootloader install re-asserted
every boot (`selfHeal`, because it hardcodes `bootctl`) — limine has no
equivalent for any of the three. See `loader.program`'s own doc in
[`modules/nixboot.nix`](../modules/nixboot.nix) for exactly why limine's
Secure Boot model (sign the loader once, enroll a hash of the whole config)
also rules out `secureBoot.*` and `bootCounting.tries`.

**`esp.*`** — the declared shape of an ESP that already exists. nixboot
never partitions, formats, or mounts anything; these options are facts it
asserts and verifies against — the mount point, the FAT label the
filesystem there must carry, the declared capacity (for headroom
warnings), and a list of foreign paths (vendor firmware capsules, `fwupd`'s
own entry, rescue media) that must never be touched or garbage-collected.

**`generations.keep` / `.capacity` / `bootCounting.tries`** — how many normal
systems stay selectable, the optional capacity-accounted Lanzaboote collector
that always retains the booted entry and a write reserve, and how many boots a
fresh generation gets before the loader falls back to the previous one.

**`secureBoot.*`** — whether this host's boot chain is signed with
operator-owned keys, where the PKI bundle lives, whether the host trusts a
stable supplied key set or may mint its own, the option-ROM allowance
passed to enrollment, and whether the operator-run `nixboot-enroll-sb`
command is installed.

**`tools.*` / `verify.enable`** — per-tool CLI exposure (`sbctl`,
`efitools`, `sbsigntool`) so a host only carries the signature tooling it
actually asked for, and the toggle for `nixboot-verify` itself (on by
default — turning it off means boot-time misconfiguration goes back to
being silent until the next boot, which is the exact failure mode this
module exists to close).

**`media.usb.enable`** — does the initrd need to find and drive a
USB-attached storage device before any root filesystem exists, because the
boot device is a stick rather than storage fixed inside the machine? The one
option group in this module that is deliberately usable **without**
`nixboot.enable` — a host that already owns its own loader/Secure Boot
wiring can still reuse just this one mechanism, the same "usable standalone"
shape `extraEntries`'s own build outputs use. Deliberately independent of
`loader.efiVariables` (nixboot warns, but never overrides one from the
other) — see CONTRACT.md's B17.

**`extraEntries.*`** — SECOND, non-default UKIs on the same ESP: a durable
rescue, BMC-recovery, or fallback boot entry, built and signed by the same
`ukify`+`sbsign` pipeline, placed under an operator-named file that never
collides with either loader's own generation-GC prefix, retained as an
explicit bounded history, and optionally registered as an idempotent
firmware NVRAM boot entry. Deliberately independent of
`generations.keep`/`bootCounting.tries` (which only ever govern
loader.program's own generations) and of `secureBoot.enable`/`loader.program`
(a host that owns no primary boot chain at all, or runs one with Secure Boot
off, can still carry a signed or unsigned extra entry) — see
`modules/extra-entries.nix` and CONTRACT.md's B13–B16.

**`remoteUnlock.*`** — a headless in-initrd secret prompt (most commonly a
LUKS passphrase/PIN this host's own disk-layout config blocks on) answered
over SSH: a NIC and sshd come up in the initrd, an operator connects with a
key from `remoteUnlock.authorizedKeys`, and hands the secret to systemd's
password agent. The host key defaults to a TPM2-sealed systemd CREDENTIAL
(`sealHostKey = true`, folded with `remoteUnlock.tpm2.enable` — a value this
module *reads*, never a TPM2 policy it owns itself, see that option's own
doc) that `nixboot-seal-hostkey` generates on first boot and SELF-HEALS
across the one PCR change a Secure Boot key enrollment causes, serving a
loudly-flagged EPHEMERAL key before any seal exists so the very first boot
is unlockable too; or a plaintext, build-time `hostKeyPath` (LAN/tailnet-only)
when `sealHostKey = false`. Both require `boot.initrd.systemd.enable = true`
(the common NIC/DHCP wiring depends on it regardless of which host-key path
is chosen) — refused, not silently inert, if it is missing. See
CONTRACT.md's B22–B23 for the full failure-mode reasoning, including the one
`mkForce` this module needs to defend against a TPM dictionary-attack
lockout.

**`console.*`** — which `console=` kernel parameter is LAST on the command
line (i.e. becomes `/dev/console`): the attached display, or a serial port
for IPMI-SOL/BMC-administered boxes and QEMU CI. Both consoles always stay
on the command line regardless — this only ever reorders, never drops one.

**`secureBoot.pkiBundle` / `keySource`** — beyond the enrollment posture
above, these two actually reach the thing that signs UKIs: `pkiBundle`
becomes `boot.lanzaboote.pkiBundle`, and `keySource = "autogenerate"` turns
on `boot.lanzaboote.autoGenerateKeys.enable` plus the landlock/ENOENT
workaround `generate-sb-keys.service` needs on a genuine first boot. The
configuration reaches both the signer and its supporting tools so they
cannot silently disagree — see CONTRACT.md's B21.

## Why a `*-verify` service at all

Every other kind of NixOS misconfiguration gets caught by the next
`nixos-rebuild` or the next time someone notices the wrong behavior at
runtime. A boot misconfiguration is different: the evidence that a knob
didn't take often only shows up at the *next* boot, when the host may no
longer be reachable. `nixboot-verify` runs once after every successful boot, reads
every managed knob back off the live system (loader identity via `bootctl
status`, ESP mount/label/capacity, foreign-path survival, `sbctl status`,
kept-generation count), and fails loudly the same boot a setting turns out
not to have taken — not the next one. `limine` gets its own, differently-
shaped version of the same check (config-file presence instead of `bootctl
status`, since limine never touches bootctl's on-disk state at all), plus a
check the other two loaders don't need: limine's config search order is
fixed, so `nixboot-verify` also warns if a lower-precedence, shadowed
`limine.conf` is lying around — harmless today, but it would become the
*active* config the moment the real one ever disappears.

## The system-manager backend

`systemManagerModules.nixboot` (`modules/system-manager-systemd-boot.nix`)
is the separate Arch/CachyOS backend. It declares a native package set and
uses the installed kernel `pkgbase` records to build Type #2 UKIs through
`mkinitcpio --uki`; it does not pretend a system-manager host has a NixOS
kernel closure. Its stage and verify units are manual by design. Staging first
builds every UKI outside the ESP and refuses to write when its exact additional
space requirement will not fit. It then writes a separate systemd-boot binary
and NixBoot-owned UKIs but never
changes the active fallback, NVRAM, or Secure Boot enrollment. A local boot
of the staged binary proves the path before any cutover. Once that explicit
stage gate is enabled, its declared pacman hook regenerates the same UKIs on
native kernel or systemd-boot EFI updates and removes only stale UKIs below
NixBoot's uniquely-owned prefix. See CONTRACT.md's B20 for the exact boundary
and gates.

For a clean break from Limine, `retireLimine.enable` renders one more manual
post-cutover unit. It refuses to run until firmware is booting systemd-boot,
then removes only explicitly named legacy artifacts and the matching Limine
NVRAM entry while hash-checking host-declared recovery and firmware files.

See [`docs/faq.md`](faq.md) for the boundary questions this design
provokes, and [`CONTRACT.md`](../CONTRACT.md) for the full behavior list.
