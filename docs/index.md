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

That common schema is not completely implemented today. The offline NixOS
path now carries `imageArtifact.deviceClass` / `.role` and the provider-neutral disk gate; the
remaining NixOS option tree is
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

**`remoteUnlock.*`** — a headless in-initrd passphrase prompt answered
over SSH: a NIC and sshd come up in the initrd, an operator connects with a
key from `remoteUnlock.authorizedKeys`, and hands the secret to systemd's
password agent. The host key is a TPM2-sealed systemd credential that
`nixboot-seal-hostkey` generates after the first successful local boot and self-heals
across the one PCR change a Secure Boot key enrollment causes. Until that
credential exists, or whenever TPM/PCR unseal fails, initrd SSH has no host
identity and stays down; the local/IPMI console remains usable. There is no plaintext or
ephemeral fallback. Remote unlock requires `boot.initrd.systemd.enable = true` and
operator Secure Boot; a no-TPM device class leaves remote unlock disabled. See
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

**`imageArtifact.*`** — a provider-neutral, checked UEFI/systemd-boot tree for
an offline-baked NixOS disk. Its required `deviceClass` and independent `role`
are generic mechanism selectors, never provider or machine names. It derives
one Type-1 entry from the evaluated
system's exact kernel, initrd, toplevel and command line, always carries the
removable-media fallback, and records that unavoidable first-boot handoff
separately from the running host's removable/NVRAM policy. It requires the
existing bootloader self-heal on every real boot; self-heal repairs NVRAM too
when that policy is `write`. `lib.mkEfiDiskImageCheck` then proves the final disk's
declared sector interpretation, GPT types, filesystems and packed ESP bytes
before upload. See [Cloud and VM boot artifacts](cloud-images.md) and
CONTRACT.md's B29–B30.

**`lib.mkUkiSigningRequest` / `lib.mkUkiSigner` /
`lib.mkSignedUkiVerifier`** — a two-phase signed-UKI boundary. The reproducible
request contains the common UKI and its digest but no key. Signing receives db
key paths only at runtime, outside the Nix store; verification binds the result
back to the exact request and intended db certificate. This is how one shared
nixrescue payload can receive the signature required by each firmware trust
root without becoming a host-specific rescue build.

**`lib.mkPkiArchiveTools`** — interactive `age --passphrase` custody for the
Secure Boot PKI. The encrypted archive may live in a public GitHub repository;
`nixboot-with-pki` decrypts it only into tmpfs for one command. No unattended
or second-password path is introduced. See [Boot Security And Recovery](security-recovery.md)
and CONTRACT.md's B31.

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
native kernel or systemd-boot EFI updates. Reclaiming stale UKIs below
NixBoot's uniquely-owned prefix is a separate step that depends only on the
declaration, so it runs before staging's capacity gate and as its own
`nixboot-systemd-boot-collect` unit — collecting only after a successful stage
deadlocks a full ESP against itself. The booted entry is never collected. See
CONTRACT.md's B20 for the exact boundary and gates, and B26 for the ordering.

`bootedKernel.verify.enable` is the one unit here that is neither staged nor
manual, because it only reads. A native kernel upgrade deletes the running
kernel's module tree, and nothing on the host notices: resident modules keep
working and the first on-demand module load fails somewhere else entirely,
naming that subsystem instead of the kernel. `nixboot-booted-kernel-verify`
runs after boot and after every native kernel transaction, reports whether the
running release still has a module tree and is still the only release its
package installs, and writes its verdict to `/run/nixboot/booted-kernel`. It
reports and stops there — see CONTRACT.md's B25.

`lib.mkTpmSshCredential` is the cross-plane producer for the global
`loader/credentials/nixboot-initrd-hostkey.cred` consumed by systemd-stub. A
NixOS remote-unlock host instantiates it automatically; a system-manager host
can run the same package after a successful local boot so a shared rescue UKI
gets a per-device PCR-bound SSH identity without embedding one in its image.
Failure never creates a plaintext fallback.

`plymouth.enable` widens this backend, on purpose, past what boots a machine to
what a human sees while it does. The argument for putting a splash in a boot
repo is that its two requirements are this backend's own surfaces — the word
`splash` on the kernel command line and a `plymouth` hook in the initramfs
generator — and that plymouth is done before any desktop exists, so no
desktop-side module can own it. The option arranges neither of those two: it
selects the native package, and says so plainly rather than half-wiring the
rest. The command line stays verbatim and `/etc/mkinitcpio.conf` keeps its
single writer. What it does change is real, though — the package's own `.wants`
symlinks start `plymouth-start.service` from `sysinit.target` on the next boot,
gated on `plymouth.enable=0` rather than on `splash` — which is why it is off by
default. NixOS hosts use stock `boot.plymouth.*`. See CONTRACT.md's B28.

For a clean break from Limine, `retireLimine.enable` renders one more manual
post-cutover unit. It refuses to run until firmware is booting systemd-boot,
then removes only explicitly named legacy artifacts and the matching Limine
NVRAM entry while hash-checking host-declared recovery and firmware files.

See [`docs/faq.md`](faq.md) for the boundary questions this design
provokes, and [`CONTRACT.md`](../CONTRACT.md) for the full behavior list.
