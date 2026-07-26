# FAQ

These entries exist because the SCOPE block and inline comments in
[`modules/nixboot.nix`](../modules/nixboot.nix) already argue each answer in
detail — this page collects the questions a reader is likely to actually
ask, pointing back at the module comments that answer them, rather than
restating the reasoning twice.

## Why doesn't nixboot partition or format the ESP?

Because that would make it a disk-layout tool, and disk layout already has
an owner on any given host (disko, or an appliance's own image build).
nixboot's contract is narrower and more testable: given an ESP that already
exists, declare what must be true about it and check that it stays true.
See `modules/nixboot.nix:30-35, 182-207`.

## Why doesn't nixboot own kernel packaging?

Kernel variant, `march`, LTO flags, the ZFS-kernel-module pairing, and
substituter choice are a genuinely separate domain — the same separation
that keeps PCI/USB power policy out of a BMC module in this house's other
projects. Whoever packages the kernel owns that surface; nixboot only cares
that *a* kernel and initrd get handed off correctly. See
`modules/nixboot.nix:36-40`.

## Why doesn't nixboot manage sleep/suspend or CPU power policy?

Because a suspend/resume cycle touching the same kernel-parameter surface
from two different modules is exactly the failure mode this project's own
layering rule forbids — two managers on one knob, silently fighting or
silently losing. Power policy stays with whichever module owns power. See
`modules/nixboot.nix:47-50`.

## Why does nixboot write to `boot.lanzaboote.*` without importing the
lanzaboote module?

Self-containment: nixboot has no opinion about *how* `boot.lanzaboote.*`
gets defined, only about *what value* it should have when
`loader.program = "lanzaboote"`. That keeps nixboot importable into a host
that never touches lanzaboote at all, with zero dead weight. The tradeoff is
explicit: whoever composes a host's module list must import lanzaboote's
own module on every host nixboot is imported on — including hosts that
leave it disabled — or evaluation fails the moment *any* host in the same
flake sets `loader.program = "lanzaboote"`. See
`modules/nixboot.nix:60-73`.

## Why `lib.mkOverride 500` everywhere, never `lib.mkForce`?

Because `mkForce` (priority 50) is the *lowest* priority NixOS has — reach
for it inside a shared module and the first host that also wants `mkForce`
for a *different* value on the same option gets an eval error instead of a
graceful override. `mkOverride 500` sits below a profile's `mkDefault`
(1000, so nixboot's opinion wins over a bare default) and above a host's own
plain `=` (100) or `mkForce` (50, so a host can always override nixboot
back). It is the one priority that cannot collide with anything a host
legitimately wants to say for itself. See `modules/nixboot.nix:75-86`.

## Why is Secure Boot enrollment a manual CLI instead of a systemd unit?

Because firmware NVRAM is the one piece of state nixboot cannot roll back.
Every other mistake this module could make is fixable with another
`nixos-rebuild`; a bad key enrollment is not. `nixboot-enroll-sb` also
refuses to run unless it reads `SetupMode=1` directly from `efivarfs`, so
even running the command by hand on the wrong host, at the wrong time, is a
refusal rather than a silent partial enrollment. See
`modules/nixboot.nix:292-303, 477-489`.

## What isn't implemented yet?

Two pieces of the source contract that motivated this module are real,
evidenced, and deliberately deferred rather than guessed at: the
`extraEntries` UKI-build mechanism for a durable rescue/BMC boot entry
(built with `ukify`+`sbsign`), and the initrd-time surface — unlock members,
SSH-unlock, console keymap. Both are called out explicitly in the module's
own SCOPE block rather than silently missing. See
`modules/nixboot.nix:51-58`.
