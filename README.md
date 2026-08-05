# nixboot

**One declarative boot stance per host: firmware handoff through to
switch-root — not the kernel package, not disk layout, not power policy, and
not post-boot service ordering.**

## What nixboot is

A NixOS module (plus a narrower system-manager backend, for Arch/CachyOS
hosts) that owns everything between firmware and `switch-root`: which
program installs to the ESP — `systemd-boot`, `lanzaboote`, or `limine` —
and every knob of its menu, the declared shape of the ESP itself (for
assertions and verification — nixboot never partitions, formats, or mounts
anything), how many past generations stay in the rollback menu, whether the
loader counts down failed boots, the Secure Boot posture and its
operator-run enrollment command, and a `nixboot-verify` service that reads
every one of those knobs back from the live system after boot and reports
PASS/FAIL/SKIP per knob.

`limine` is the odd one out on purpose: its Secure Boot model (sign the
loader once, enroll a hash of the *whole* config) and its fixed,
non-configurable config search order share no mechanism with the other two
loaders, so nixboot refuses — rather than silently ignores — the knobs that
don't carry over (`secureBoot.*`, `bootCounting.tries`, `loader.graceful`,
`loader.selfHeal`, `loader.consoleMode`). See
[`modules/nixboot.nix`](modules/nixboot.nix)'s `loader.program` option doc,
and [CONTRACT.md](CONTRACT.md)'s B18/B19, for the full reasoning.

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
[`modules/nixboot.nix`](modules/nixboot.nix#L88-L101). `loader.program =
"limine"` needs no such composition step: `boot.loader.limine` ships inside
nixpkgs itself.

The full option-by-option contract, including every assertion and warning
this module ships, lives in [CONTRACT.md](CONTRACT.md).

The companion [Boot Security And Recovery](docs/security-recovery.md)
decision record defines the passphrase-only data-unlock invariant, rescue
boundary, private-key custody, and firmware-recovery procedure for consumers
of this public module.

## The system-manager backend

`systemManagerModules.nixboot` (`modules/system-manager-systemd-boot.nix`)
is a separate backend for a plain Arch/CachyOS host managed by
[system-manager](https://github.com/numtide/system-manager). It does not
pretend the host has a NixOS kernel closure: it declares the native
packages, discovers the installed kernel releases through their `pkgbase`
files, and builds Type #2 UKIs with `mkinitcpio --uki`.

The backend is deliberately staged. Merely enabling it selects packages;
setting `stage.enable` makes manual stage/verify units available, but never
starts them. Staging first builds all UKIs under `/var/tmp`, measures the
additional ESP space they require, and fails without changing the ESP when it
will not fit. Only then does it install `EFI/systemd/systemd-bootx64.efi`, a
loader configuration, and NixBoot-prefixed UKIs. It does **not** replace
`EFI/BOOT/BOOTX64.EFI`, change NVRAM, or enroll Secure Boot keys. That gives
an operator a physical one-shot firmware test before any cutover. Native
kernel, firmware, and host-selected microcode package names are published as `archPackages` for the
consumer's package reconciler rather than installed by a second package
manager. After the explicit stage gate is enabled, NixBoot also declares the
post-transaction pacman hook that rebuilds its UKIs when the native kernel or
systemd-boot EFI artifact changes.

Secure Boot signing is deliberately incomplete until a host supplies an explicit
root-owned runtime `secureBoot.sbctlConfig` path. NixBoot signs only through that
configuration; it never receives a private key, invents a default key directory,
or puts key material in the Nix store. A secure stage signs both its separate
systemd-boot binary and its NixBoot-owned UKIs; it never signs or replaces the
current fallback path before the separately reviewed cutover.

`cutover.enable` is a second, independent manual gate. Its unit first reruns
the stage verification, then uses `bootctl install` with EFI-variable writes
enabled to replace the active fallback and create the systemd-boot firmware
entry. It is never enabled automatically and a source declaration keeps it
off until the staged loader has completed a physical boot test.

`retireLimine.enable` is the final manual gate for a host migrating away from
Limine. It is available only with a declared cutover and explicit artifact and
protection lists. The unit verifies the current boot and first `BootOrder`
entry are systemd-boot, verifies NixBoot's staged artifacts, hashes every
protected foreign EFI path, masks the generic native artifact hooks, removes
the one path-matched Limine NVRAM entry and declared legacy files, then checks
the protected hashes again. It never deletes a directory recursively.

```nix
{
  inputs.nixboot.url = "github:julian-corbet/nixboot-corbet-ch";

  # a system-manager flake's own host config:
  imports = [ inputs.nixboot.systemManagerModules.default ];

  nixboot.systemdBoot = {
    enable = true;
    microcodePackage = "intel-ucode"; # Select the host CPU vendor explicitly.
    kernels = [{
      package = "linux-cachyos";
      packageBase = "linux-cachyos";
      headersPackage = "linux-cachyos-headers";
      id = "cachyos";
    }];
    kernelCmdline = "rd.luks.name=example=cryptroot root=/dev/mapper/cryptroot rw";
    stage.enable = true; # units are manual; this does not change firmware state
  };
}
```

See [CONTRACT.md](CONTRACT.md)'s B20 for the full reasoning, and
`checks/system-manager.nix` for its eval-test suite (the same
`lib.evalModules`-stub technique
[nixarch](https://github.com/julian-corbet/nixarch-corbet-ch)'s own checks
use for its system-manager modules).

## Status

Pre-alpha. The module is complete and was extracted verbatim from a private
operator's boot-stance audit (see the header of
[`modules/nixboot.nix`](modules/nixboot.nix) for the extraction story), but
this standalone flake has not yet been re-verified live as its own input —
only as an in-tree module in the configuration it came from, and — as of
this revision — as a normalised eval-level comparison against that source
configuration's own boot glue, not yet a live cutover on real hardware (see
the note at the end of this section).

Two pieces of the source contract that an earlier revision of this file
called out as deliberately deferred are now implemented: `extraEntries.*`
(the `ukify`+`sbsign`+place+rotate pipeline for a durable rescue/BMC boot
entry — [`modules/extra-entries.nix`](modules/extra-entries.nix)), and
`remoteUnlock.*` (headless in-initrd SSH, both the TPM2-sealed and
plaintext host-key paths — see `secureBoot.pkiBundle`/`keySource` and
`remoteUnlock.*` in [`modules/nixboot.nix`](modules/nixboot.nix), and
[CONTRACT.md](CONTRACT.md)'s B21–B24). What genuinely remains outside this
module, stated as a ceiling rather than an oversight: the initrd-time
LUKS/ZFS **unlock-member** surface belongs to whichever disk-layout module
declares those members — [nixluks](https://github.com/julian-corbet/nixluks-corbet-ch)'s
own `volumes.<name>.initrdUnlock.*`, not nixboot, which has no member list
of its own to attach that mechanism to (see the "CROSS-MODULE COUPLING"
comment on `remoteUnlock`'s common initrd-network block); and the initrd
**console keymap** is real and evidenced from the same source audit but not
yet implemented in this repo at all.

**A note on "one declarative boot stance per host":** that generality is a
property of this MODULE, not automatically of any given consumer. nixnas —
the appliance this module was extracted out of — still owns its own
loader/Secure-Boot/rollback wiring in-tree
(`modules/boot/{disk,rollback,image,secureboot,remote-unlock}.nix`) and
consumes only `extraEntries.*` and `media.usb.enable` from this flake today;
the rest of its boot chain has been compared against this module's option
surface (behaviour-for-behaviour, not merely name-for-name) but not yet
cut over. Two repos owning parts of one boot chain is exactly the shape this
module exists to end — see that repo's own commit history for the ordered
cutover plan such a comparison produces, and CONTRACT.md's B21–B24 for what
had to be added here first to make the comparison honest.

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
| `flake.nix` | Flake entry point: `nixosModules.nixboot` / `.default`, `systemManagerModules.nixboot` / `.default`. |
| `modules/nixboot.nix` | The NixOS module itself. |
| `modules/extra-entries.nix` | `nixboot.extraEntries.*` — second, non-default UKIs on the same ESP (NixOS only). |
| `modules/system-manager-systemd-boot.nix` | Staged native systemd-boot and UKI backend for system-manager hosts. |
| `lib/register-boot-entry.nix` | The idempotent/self-healing NVRAM registrar, shared by both backends. |
| `docs/` | Reader-facing option-surface walkthrough and FAQ. |
| `CONTRACT.md` | The option surface as a fixed behavioral contract. |
| `checks/default.nix` | Eval-time tests for the NixOS module (+ one build-level idempotency proof). |
| `checks/system-manager.nix` | Eval-time tests for the system-manager backend. |
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
