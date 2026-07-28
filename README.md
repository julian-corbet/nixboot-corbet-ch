# nixboot

**One declarative boot stance per host: firmware handoff through to
switch-root — not the kernel package, not disk layout, not power policy, and
not post-boot service ordering.**

## What nixboot is

A single NixOS module that owns everything between firmware and
`switch-root`: which program installs to the ESP and every knob of its menu,
the declared shape of the ESP itself (for assertions and verification —
nixboot never partitions, formats, or mounts anything), how many past
generations stay in the rollback menu, whether the loader counts down failed
boots, the Secure Boot posture and its operator-run enrollment command, and
a `nixboot-verify` service that reads every one of those knobs back from the
live system after boot and reports PASS/FAIL/SKIP per knob.

It exists because a boot setting that is requested and silently refused is
worse than almost any other kind of misconfiguration: on real hardware the
only evidence often appears at the *next* boot, by which point the box may
not come back at all. `nixboot-verify` closes that gap by checking, not
assuming.

It also owns one thing that is deliberately usable **without** taking on any
of the above: `media.usb.enable` adds the initrd kernel modules a stage-1
boot needs to find and drive a USB-attached device — a stick — before any
root filesystem exists. Every other knob in this module lives behind
`nixboot.enable`; this one is wired independently of it (the same shape
`extraEntries`'s own unconditionally-exposed build outputs use), so a host
that already owns its whole boot chain can reuse just this one mechanism.

**What it explicitly does not own**, so no knob ever has two managers
fighting over it (see the SCOPE block in
[`modules/nixboot.nix`](modules/nixboot.nix#L17-L87) for the full reasoning
behind each line):

- **The ESP's existence.** Partitioning, formatting, and mounting are a
  disk-layout tool's job (disko, or an appliance's own image build). nixboot
  only *declares* where an ESP that already exists lives and what must
  already be true about it.
- **Kernel packaging.** Kernel variant, `march`, LTO, the ZFS kernel-module
  pairing, substituter choice — a foreign domain, the same way PCI/USB power
  policy stays out of a BMC module.
- **Disk-layout identity.** LUKS members, ZFS pool import, impermanence /
  persist paths. Appliance state that happens to get consulted from stage 1,
  not boot policy.
- **Power policy.** Sleep/suspend, ASPM, EPP — boot-adjacent, but a second
  manager on the same kernel-param surface is exactly the failure mode this
  module's own layering rule forbids.
- **Post-boot service ordering.** nixboot's job ends at `switch-root`; what
  systemd does with targets and units afterward belongs to whoever owns that
  service, not to a boot-stance module.

The one thing nixboot *writes to* without *owning* is `boot.lanzaboote.*` —
options defined by the separate [lanzaboote](https://github.com/nix-community/lanzaboote)
flake's own NixOS module. nixboot never imports that module itself (kept
self-contained on purpose); whoever composes a host's module list must
import lanzaboote's module too, on every host nixboot is imported on, not
just the hosts that use it — see the "ONE EXTERNAL DEPENDENCY" note in
[`modules/nixboot.nix`](modules/nixboot.nix#L88-L101).

The full option-by-option contract, including every assertion and warning
this module ships, lives in [CONTRACT.md](CONTRACT.md).

## Status

Pre-alpha. The module is complete and was extracted verbatim from a private
fleet's boot-stance audit (see the header of
[`modules/nixboot.nix`](modules/nixboot.nix) for the extraction story), but
this standalone flake has not yet been re-verified live as its own input —
only as an in-tree module in the fleet it came from. Two real, evidenced
pieces of the source contract are deliberately **not** implemented in this
first cut: the `extraEntries` UKI-build mechanism for a durable rescue/BMC
boot entry, and the initrd unlock/SSH-unlock/console-keymap surface. Both
are noted in the module's own SCOPE block rather than silently missing.

## Usage

```nix
{
  inputs.nixboot.url = "github:julian-corbet/nixboot-corbet-ch";
  # A host that ever sets loader.program = "lanzaboote" also needs
  # lanzaboote's own module composed in — see "What nixboot is" above.
  inputs.lanzaboote.url = "github:nix-community/lanzaboote";

  outputs = { self, nixpkgs, nixboot, lanzaboote, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixboot.nixosModules.default
        lanzaboote.nixosModules.lanzaboote

        {
          nixboot = {
            enable = true;
            loader.program = "systemd-boot";
            loader.efiVariables = "write"; # this host owns real NVRAM
            loader.timeout = 5;

            esp.mountPoint = "/boot";
            esp.byLabel = "ESP";
            esp.capacityMiB = 512;

            generations.keep = 8; # must outlast this host's builds/uptime
          };
        }
      ];
    };
  };
}
```

A host that instead needs Secure Boot turns on `loader.program =
"lanzaboote"`, `secureBoot.enable = true`, and points `secureBoot.pkiBundle`
at a durable key location — nixboot asserts that combination is complete
before it will evaluate. See [CONTRACT.md](CONTRACT.md) for every option and
the assertions/warnings that keep them from silently disagreeing with each
other.

A host that owns its own boot chain already (so `nixboot.enable` stays
`false`) can still reuse just the removable-media mechanism:

```nix
{
  nixboot.media.usb.enable = true; # find + drive a USB stick in the initrd
  # ... this host's own loader.program / secureBoot / etc. wiring, unchanged.
}
```

The stick's own geometry — device path, image size, partition count — is
never nixboot's business; that stays with whichever disk-layout tool the
host already uses.

## Repository layout

| Path | Purpose |
|---|---|
| `flake.nix` | Flake entry point: `nixosModules.nixboot` / `nixosModules.default`. |
| `modules/nixboot.nix` | The module itself. |
| `docs/` | Reader-facing option-surface walkthrough and FAQ. |
| `CONTRACT.md` | The option surface as a fixed behavioral contract. |
| `experiments/` | Runnable trials with recorded results — see [`experiments/README.md`](experiments/README.md). |
| `studies/` | Written investigations that motivate design decisions — see [`studies/README.md`](studies/README.md). |

## Related projects

Part of the same small, independently-usable NixOS module family:
[nixnas](https://github.com/julian-corbet/nixnas) (the appliance this module
was extracted out of), [nixgpu](https://github.com/julian-corbet/nixgpu-corbet-ch),
[nixram](https://github.com/julian-corbet/nixram-corbet-ch). A sibling
hardware-power module in the same house style exists but is not yet a
public repo of its own.

## License

[MIT License](LICENSE) &copy; 2026 Julian Corbet
