# nixboot

nixboot is one small NixOS module: declare a host's boot stance, get a
coherent loader configuration, a declared ESP contract, generation
retention, optional boot counting, an optional Secure Boot posture, and a
`nixboot-verify` service that checks every one of those things actually
took after boot. Instead of hand-picking `boot.loader.*` options per host
and hoping they agree with each other and with whatever a NixOS profile
already set as a default, you declare one `nixboot` block and get
a coherent whole.

This page is the reader-facing walkthrough. The option-by-option contract —
what nixboot guarantees, with assertions and warnings as the enforcement
mechanism — is [`CONTRACT.md`](../CONTRACT.md). The module itself, with
every option's own description, is
[`modules/nixboot.nix`](../modules/nixboot.nix).

## The seven option groups

**`loader.*`** — which program installs to the ESP (`systemd-boot`,
`lanzaboote`, or `none` for a guest with no firmware of its own) and every
knob of its menu: timeout, editor access, console mode, whether firmware
gets an NVRAM entry (`efiVariables`), whether an install failure aborts a
`switch-to-configuration` or only warns (`graceful`), and whether the ESP
needs its bootloader install re-asserted every boot (`selfHeal`) because it
arrived pre-baked into an image rather than through a live activation.

**`esp.*`** — the declared shape of an ESP that already exists. nixboot
never partitions, formats, or mounts anything; these options are facts it
asserts and verifies against — the mount point, the FAT label the
filesystem there must carry, the declared capacity (for headroom
warnings), and a list of foreign paths (vendor firmware capsules, `fwupd`'s
own entry, rescue media) that must never be touched or garbage-collected.

**`generations.keep` / `bootCounting.tries`** — how many past systems stay
selectable from the boot menu, and, on a `lanzaboote`-managed host only, how
many boots a fresh generation gets before the loader falls back to the
previous one.

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
collides with either loader's own generation-GC prefix, optionally rotated
as a current/previous pair, and optionally registered as an idempotent
firmware NVRAM boot entry. Deliberately independent of
`generations.keep`/`bootCounting.tries` (which only ever govern
loader.program's own generations) and of `secureBoot.enable`/`loader.program`
(a host that owns no primary boot chain at all, or runs one with Secure Boot
off, can still carry a signed or unsigned extra entry) — see
`modules/extra-entries.nix` and CONTRACT.md's B13–B16.

## Why a `*-verify` service at all

Every other kind of NixOS misconfiguration gets caught by the next
`nixos-rebuild` or the next time someone notices the wrong behavior at
runtime. A boot misconfiguration is different: the evidence that a knob
didn't take often only shows up at the *next* boot — on real hardware, that
can mean a ~15-minute POST and no way to reach the box at all until it's
resolved. `nixboot-verify` runs once after every successful boot, reads
every managed knob back off the live system (loader identity via `bootctl
status`, ESP mount/label/capacity, foreign-path survival, `sbctl status`,
kept-generation count), and fails loudly the same boot a setting turns out
not to have taken — not the next one.

See [`docs/faq.md`](faq.md) for the boundary questions this design
provokes, and [`CONTRACT.md`](../CONTRACT.md) for the full behavior list.
