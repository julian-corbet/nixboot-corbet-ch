# nixboot — the option-surface contract

This file is the **fixed target**: *what* `services.nixboot` must guarantee
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

## Which behaviors become automated tests vs. stay observed

- **Automatable** (a `pkgs.testers.nixosTest` VM can assert these directly):
  B1, B2, B3, B4, B5, B7, B9, B10, B12.
- **Observed / operational** (need real firmware, a real TPM, or real NVRAM
  state that a disposable VM cannot faithfully reproduce): B6 (Setup Mode
  gating against real UEFI variables), B8 (a real ESP actually approaching
  its declared capacity over many generations).

No automated test suite exists yet in this repo — see
[`experiments/README.md`](experiments/README.md) and
[`studies/README.md`](studies/README.md) for where that work would land.

## Priority discipline (how B1 and the loader writes are actually enforced)

`mkOverride 500` is not an arbitrary number: NixOS's own `mkDefault` sits at
priority 1000 and plain `=` at priority 100. 500 is the one value that beats
a profile's default while still losing cleanly to anything more specific a
host says about itself — including that host's own `mkForce` (priority 50).
Reaching for `mkForce` inside this module instead would risk two
same-priority definitions disagreeing the moment a host *also* used
`mkForce` for a different value on the same option — an eval error, not a
graceful override. Full reasoning: `modules/nixboot.nix:75-86`.
