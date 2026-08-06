# FAQ

These entries exist because the SCOPE block and inline comments in
[`modules/nixboot.nix`](../modules/nixboot.nix) already argue each answer in
detail — this page collects the questions a reader is likely to actually
ask, pointing back at the module comments that answer them, rather than
restating the reasoning twice.

## Why doesn't nixboot partition or format the ESP?

Because physical storage provisioning remains nixstorage or an appliance
layout's job. nixboot owns the ESP's boot role, constraints, contents and
verification, while consuming the device/capacity facts supplied by the
layout owner. The current backend only declares an already-existing ESP;
class-backed boot-medium construction is part of the target migration.

## Does nixboot own kernel packaging?

In the target architecture, yes: the kernel/initrd that actually boots is
part of the boot artifact, so the nixarch/nixnas/nixvps backend selects and
packages it. It does so from facts supplied by the specialist domains:
nixcpu owns architecture/microcode knowledge, nixfs filesystem requirements,
nixstorage physical layout and nixluks encrypted-member semantics. The
current implementation still receives a consumer-packaged kernel; that is
migration status, not the final ownership boundary.

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

The unified architecture described in the README and CONTRACT is a target,
not a claim about today's exports. There is not yet one schema selecting a
`nixarch`/`nixnas`/`nixvps` device class and a `primary`/`nixrescue` boot
role across NixOS, system-manager, and Home Manager. Containers also do not
yet have a first-class cross-plane no-boot declaration. Today NixOS uses
`nixboot.*`, system-manager uses `nixboot.systemdBoot.*`, and there is no
Home Manager backend. Delivery is also still partly implemented by nixboot's
own timers; the target assigns scheduling, transport, materialization, slot
rotation/selection, activation, rollback, reimage, and outcomes solely to
nixdeploy.

The **initrd console keymap** is a known requirement, but is not
implemented in this repo at all yet — called out explicitly in the module's
own SCOPE block rather than silently missing. See `modules/nixboot.nix`'s
header.

The initrd-time **LUKS/ZFS unlock-member** surface (opening the disks that
back the root/data filesystems, in stage 1) is NOT this module's job at
all, and never will be — nixboot has no member list of its own to attach
that mechanism to (see `remoteUnlock`'s own "CROSS-MODULE COUPLING" comment
in `modules/nixboot.nix`). That mechanism now lives in
[nixluks](https://github.com/julian-corbet/nixluks-corbet-ch)'s
`volumes.<name>.initrdUnlock.*` — a previous revision of this page listed
it as a nixboot gap; it was actually a gap between two repos each pointing
at the other, now closed on nixluks's side.

`extraEntries.*` (second, non-default UKIs on the same ESP) and
`remoteUnlock.*` (headless in-initrd SSH, sealed or plaintext host key) were
the other deferred pieces as of earlier revisions of this page — both are
now implemented, in `modules/extra-entries.nix` and `modules/nixboot.nix`
respectively. See the next question, and CONTRACT.md's B21–B24.

## What is `nixboot.extraEntries`, and how is it different from a normal
generation?

A normal generation is one of loader.program's OWN boot entries —
`generations.keep` and `bootCounting.tries` govern those, and they always
carry the `nixos-` prefix both shipped loaders use to garbage-collect their
own history. `extraEntries.<name>` is a SEPARATE, operator-named UKI built
from a DIFFERENT toplevel (a foreign `nixosConfiguration`'s own
`system.build.toplevel` is the common case — a rescue system, a BMC-recovery
image), asserted to never collide with that `nixos-` prefix, so it survives
both loaders' generation GC untouched. It is built, optionally signed,
placed, retained as an explicit bounded history, and optionally
registered as a firmware NVRAM boot entry by its own maintainer service —
one per attrset entry, driven by a timer, never a boot/switch dependency
(the same "never block the boot/switch transaction on an ESP write"
discipline the sibling appliance distribution's own rescue-maintenance
module states and this one absorbs). See `modules/extra-entries.nix`'s
header and CONTRACT.md's B13–B16.

## Why isn't `extraEntries.<name>.sign.enable` just `secureBoot.enable`?

Because `secureBoot.enable` asserts `loader.program == "lanzaboote"` (B5),
but an extra entry is exactly the case where a host's PRIMARY chain may not
be owned by nixboot at all (`loader.program = "none"` — a foreign ESP this
module is only allowed to add ONE entry to). Deriving `sign.enable` from
`secureBoot.enable` the way `tools.sbctl.enable` legitimately does would
make a signed extra entry impossible on precisely the hosts most likely to
want one. `sign.pkiBundle` defaults to `secureBoot.pkiBundle` (the same bare
path fact, with no dependency on `secureBoot.enable` either) but can point
anywhere. See `modules/extra-entries.nix`'s `sign.enable` option doc.

## Why does `loader.program = "limine"` refuse `secureBoot.enable`,
`bootCounting.tries`, `loader.graceful`, `loader.selfHeal` and
`loader.consoleMode` instead of just doing something reasonable with them?

Because none of the five have a reasonable thing to do under limine, and
this module's whole reason for existing is refusing to pretend otherwise.
`secureBoot`/`bootCounting` are built entirely around lanzaboote's
per-generation UKI signing and stub-side boot counting; limine's own Secure
Boot model signs the loader binary *once* and enrolls a hash of the
*entire* config instead — a different trust boundary, not a smaller
version of the same one. `graceful` and `selfHeal` both hardcode `bootctl`,
a binary limine never touches (running `bootctl install` against a
limine-owned ESP would actively install systemd-boot's own EFI stub over
whatever limine placed there, not merely no-op). `consoleMode` writes
`boot.loader.systemd-boot.consoleMode`, an option limine never reads at
all. Every one of these is asserted rather than silently ignored — the
exact "setting requested, quietly not applied" bug class B4 already refuses
for `bootCounting.tries` on a non-lanzaboote host. See
`loader.program`'s own doc in `modules/nixboot.nix` and CONTRACT.md's
B18–B19.

## What does the system-manager backend (`systemManagerModules.nixboot`) actually cover?

It declares a native systemd-boot + UKI contract, not a NixOS kernel
closure. The backend publishes the necessary Arch packages, finds the live
pacman kernel releases by `pkgbase`, and uses `mkinitcpio --uki` to build
declared, uniquely-prefixed UKIs. Its stage/verify units are manual even
after declaration: they leave the active fallback and firmware NVRAM alone
until a local boot proves the staged loader. Secure Boot enrollment remains
a separately reviewed, physical-presence operation. See
`modules/system-manager-systemd-boot.nix` and CONTRACT.md's B20.
