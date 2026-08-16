# nixboot

**One declarative boot subsystem per host: the booted kernel/initrd artifact,
firmware handoff and everything required to reach `switch-root` — with
physical storage facts, runtime policy and delivery supplied by their own
specialists.**

## What nixboot is

A NixOS module, plus a narrower system-manager backend, that currently
declares the mechanisms between firmware and `switch-root`: which program
produces the ESP artifact — `systemd-boot`, `lanzaboote`, or `limine` —
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

For offline cloud and VM disks, `nixboot.imageArtifact` now produces the
checked UEFI/systemd-boot portion directly from the evaluated NixOS system.
The separate `lib.mkEfiDiskImageCheck` proves the final raw disk's sector
interpretation, GPT partition types/filesystems and byte-exact ESP contents
before upload. Provider adapters supply facts; they do not grow another ESP
renderer. The manifest keeps the offline disk's mandatory removable-media
first boot distinct from the live host's later removable/NVRAM policy. See
[Cloud and VM boot artifacts](docs/cloud-images.md).

It also owns one thing that is deliberately usable **without** taking on any
of the above: `media.usb.enable` adds the initrd kernel modules a stage-1
boot needs to find and drive a USB-attached device — a stick — before any
root filesystem exists. Every other knob in this module lives behind
`nixboot.enable`; this one is wired independently of it (the same shape
`extraEntries`'s own unconditionally-exposed build outputs use), so a host
that already owns its whole boot chain can reuse just this one mechanism.

The current implementation is narrower than the target architecture below.
Its source SCOPE block records that current boundary; it is migration status,
not a permanent exclusion of kernel/initrd or boot-medium work.

**What remains outside nixboot permanently**, so no knob ever has two
managers fighting over it:

- **Physical storage provisioning and source facts.** nixstorage or an
  appliance layout creates partitions/filesystems and supplies device,
  capacity and role facts. nixluks supplies encrypted-member identity,
  ordering and criticality. nixboot owns their boot-time projection and the
  constraints required to reach switch-root; it never retypes or destroys
  the underlying storage.
- **Source-domain policy.** nixcpu, nixfs, nixgpu and related domains supply
  architecture, microcode, filesystem and hardware requirements. The target
  nixboot class backend selects and packages the booted kernel/initrd from
  those facts; it does not become a second source of CPU, filesystem or GPU
  policy.
- **Power policy.** Sleep/suspend, ASPM, EPP — boot-adjacent, but a second
  manager on the same kernel-param surface is exactly the failure mode this
  module's own layering rule forbids.
- **Post-boot service ordering.** nixboot's job ends at `switch-root`; what
  systemd does with targets and units afterward belongs to whoever owns that
  service, not to a boot-stance module.
- **Delivery.** Scheduling, transport, materialization, slot selection and
  rotation, activation, rollback, reimage, and outcome reporting belong to
  nixdeploy. Current nixboot timers and cutover units predate that target
  boundary and are migration debt, not an invitation to add more rollout
  policy here.

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

## Target architecture: one schema, class adapters, two roles

The target is one boot-intent schema shared across the NixOS,
system-manager, and Home Manager module systems wherever that plane can
meaningfully participate. "Shared schema" does not mean every plane may
write firmware:

- the NixOS backend produces and verifies artifacts for a Nix-built kernel,
  initrd, loader, and ESP;
- the system-manager backend produces and verifies equivalent artifacts
  around the native distro kernel and package manager;
- Home Manager may consume read-only status or expose user-scoped tooling,
  but it must never become a second ESP, Secure Boot, or NVRAM actuator.

Two independent axes describe a bootable system:

| Axis | Values | Meaning |
|---|---|---|
| Device class | `nixarch`, `nixnas`, `nixvps` | The public adapter that translates class capabilities into the common boot schema. It supplies mechanism-specific facts, not a private host's policy. |
| Boot role | `primary`, `nixrescue` | Whether the artifact is the everyday operating system or a recovery system. The role does not imply a device class. |

A container or other target with no firmware handoff is an explicit
**no-boot** case, not a `primary` system with a conveniently disabled loader.
It composes no boot actuator and has no ESP, NVRAM, or Secure Boot contract.
The current NixOS `loader.program = "none"` remains useful for a guest whose
configuration still owns an extra artifact, but it is not yet the complete
cross-plane no-boot model above.

The composition layer owns all actual host facts and policy: hostnames,
addresses, cloud identities, disk identifiers, accounts, keys, endpoints,
and chosen production values. Public class repos contain only adapters,
generic defaults that are true for the class, examples, and tests. A class
adapter may translate a fact; it must not become a second source for it.

The other two ownership boundaries are equally strict:

- [nixrescue](https://github.com/julian-corbet/nixrescue-corbet-ch) produces
  the recovery content and runtime;
- nixboot produces and verifies the boot artifact around either a `primary`
  or `nixrescue` payload;
- [nixdeploy](https://github.com/julian-corbet/nixdeploy-corbet-ch) alone owns
  delivery: scheduling, transport, materialization, slot rotation and
  selection, activation, rollback, reimage, and typed outcomes.

This remains the architectural target, not the complete current option
surface. The NixOS offline-image path has landed the first class-and-role-bearing
common artifact (`nixboot.imageArtifact.deviceClass` / `.role`) and
provider-neutral disk gate. Today the
NixOS backend uses `nixboot.*`, the system-manager backend uses the separate
`nixboot.systemdBoot.*` tree, no Home Manager module is exported, and no
complete cross-plane device-class/boot-role schema has landed. Kernel selection/packaging and some
boot-medium construction also still live in class or consumer repos. Those
move into the class backends here while their source facts stay in the
specialist domains. nixboot's current maintainer timers and slot rotation are
implemented behavior, but delivery responsibility moves to nixdeploy rather
than remaining a second deployment system.

## The system-manager backend

`systemManagerModules.nixboot` (`modules/system-manager-systemd-boot.nix`)
is a separate backend for a plain Arch/CachyOS host managed by
[system-manager](https://github.com/numtide/system-manager). It does not
pretend the host has a NixOS kernel closure: it declares the native
packages, discovers the installed kernel releases through their `pkgbase`
files, and builds Type #2 UKIs with `mkinitcpio --uki`.

The backend is deliberately staged. Merely enabling it selects packages;
setting `stage.enable` makes manual stage/verify units available, but never
starts them. Each manual unit sets system-manager's `restartIfChanged = false`
explicitly: omitting `wantedBy` alone does not stop a switch from starting a
changed service. Staging first builds all UKIs under `/var/tmp`, measures the
additional ESP space they require, and fails without changing the ESP when it
will not fit. Only then does it install `EFI/systemd/systemd-bootx64.efi`, a
loader configuration, and NixBoot-prefixed UKIs. It does **not** replace
`EFI/BOOT/BOOTX64.EFI`, change NVRAM, or enroll Secure Boot keys. That gives
an operator a physical one-shot firmware test before any cutover. Native
kernel and firmware package names are published as `archPackages` for the consumer's package
reconciler rather than installed by a second package manager. The matching microcode package comes
from NixCPU's read-only boot contract, so the vendor is declared once and NixBoot never carries a
second Intel/AMD string. After the explicit stage gate is enabled, NixBoot also declares the
post-transaction pacman hook that rebuilds its UKIs when the native kernel or
systemd-boot EFI artifact changes.

Reclaiming NixBoot's own stale UKIs is a **separate** step from staging, and
that separation is load-bearing rather than tidiness. Collection derives the
wanted file set from the declaration (`kernels` → `<prefix>-<id>[-fallback].efi`),
not from what a build produced, so it needs no `mkinitcpio` run, no staging
directory, and no free space. It runs before staging's capacity gate and also
as its own `nixboot-systemd-boot-collect` unit ordered after nothing. The
alternative — collecting only after a successful stage — deadlocks a full ESP:
staging cannot write without space, and the space is held by exactly the
artifacts collection would free. Foreign rescue, vendor, Limine and fallback
paths remain outside the ownership boundary, and the entry firmware reports as
`Current Entry` is never collected even if the declaration stopped naming it.
When the ESP genuinely cannot hold what the host declares, staging refuses with
the shortfall in MiB and changes nothing; shrinking the declared set (a
kernel's `fallback = false` is usually the largest single UKI) or growing the
ESP is the operator's call.

One unit in this backend is **not** staged and **not** manual, because it only
reads: `nixboot-booted-kernel-verify` (`bootedKernel.verify.enable`, on by
default). A native kernel upgrade replaces `/usr/lib/modules/<release>`
wholesale, and the kernel that is still executing does not notice — modules
already resident keep working, so the host looks healthy right up until the
first on-demand module load, which then fails inside whatever subsystem asked
for it and reports itself, not the kernel, as the cause. This unit runs after
boot and again after every native kernel transaction (its own pacman hook), and
answers two questions: does the running release still have a module tree, and
is that release still the only one its native package installs. The second
matters even when a module-preserving hook (`kernel-modules-hook`, `mkmm`)
keeps the first green — that combination is precisely the state nothing else
reports. A failure is a failed unit plus the full verdict at
`/run/nixboot/booted-kernel`. It never reboots, installs, or restores anything,
and it is not a substitute for a module-preserving hook: it reports the
condition, it does not prevent it.

`plymouth.enable` is the one option in this backend that is not a boot
mechanism — it is boot cosmetics, and it is a deliberate widening of what this
repo covers. It is here because a splash needs the kernel command line and the
initramfs, this backend's own two surfaces, and because plymouth is finished
before any desktop exists, so nothing on the desktop side can own it. It
selects the native package and stops there: it does **not** put `splash` on
`kernelCmdline` (an opaque string, rendered verbatim into every staged UKI) and
it does **not** add the `plymouth` hook to `/etc/mkinitcpio.conf` (NixBoot never
writes that file). Both remain the consumer's. Selecting it is still a boot
decision rather than a package-list line: the package's own `.wants` symlinks
pull `plymouth-start.service` into `sysinit.target` and the quit units into
`multi-user.target`, and that unit gates on `plymouth.enable=0`, not on
`splash`. `quiet splash` without the hook is the trap — no splash, and the
kernel log gone for exactly the boot that needed it, with no boot-menu escape
because the command line is baked into the UKI. NixOS hosts use stock
`boot.plymouth.*` instead. See CONTRACT.md's B28.

Secure Boot signing is deliberately incomplete until a host supplies an explicit
root-owned runtime `secureBoot.sbctlConfig` path. NixBoot signs only through that
configuration; it never receives a private key, invents a default key directory,
or puts key material in the Nix store. A secure stage signs both its separate
systemd-boot binary and its NixBoot-owned UKIs; it never signs or replaces the
current fallback path before the separately reviewed cutover.

When a Secure Boot PKI is stored as an encrypted archive, its interactive
`age` prompt means the **same master passphrase used for disk encryption**.
It is not a new or rescue-specific password. The ciphertext may be public;
the master passphrase and plaintext keys may not be committed or supplied to
unattended CI. See [Boot Security And Recovery](docs/security-recovery.md).

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
  inputs.nixcpu.url = "github:julian-corbet/nixcpu-corbet-ch";

  # a system-manager flake's own host config:
  imports = [
    inputs.nixcpu.systemManagerModules.packages
    inputs.nixboot.systemManagerModules.default
  ];

  # Illustrative values only. The private composition supplies the actual
  # hardware facts, native package choices, and boot policy.
  nixcpu = {
    enable = true;
    arch = "x86_64";
    vendor = "intel";
    execution = "bare-metal";
    cores = 4;
    threads = 8;
    capabilities.microcode.enable = true;
  };

  nixboot.systemdBoot = {
    enable = true;
    kernels = [{
      package = "linux";
      packageBase = "linux";
      headersPackage = "linux-headers";
      id = "main";
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

Pre-alpha. The NixOS and system-manager backends, their assertions, and their
eval/build checks exist today. OVMF now proves the signed-UKI Secure Boot
handoff and swtpm proves the TPM-gated SSH identity lifecycle; physical
firmware and TPM quirks still require physical-host verification.

Two pieces that an earlier revision of this file called out as deliberately
deferred are now implemented: `extraEntries.*`
(the `ukify`+`sbsign`+place+rotate pipeline for a durable rescue/BMC boot
entry — [`modules/extra-entries.nix`](modules/extra-entries.nix)), and
`remoteUnlock.*` (headless in-initrd SSH with a fail-closed TPM2-sealed
host identity — see `secureBoot.pkiBundle`/`keySource` and
`remoteUnlock.*` in [`modules/nixboot.nix`](modules/nixboot.nix), and
[CONTRACT.md](CONTRACT.md)'s B21–B24). What genuinely remains outside this
module, stated as a ceiling rather than an oversight: the initrd-time
LUKS/ZFS **unlock-member** surface belongs to whichever disk-layout module
declares those members — [nixluks](https://github.com/julian-corbet/nixluks-corbet-ch)'s
own `volumes.<name>.initrdUnlock.*`, not nixboot, which has no member list
of its own to attach that mechanism to (see the "CROSS-MODULE COUPLING"
comment on `remoteUnlock`'s common initrd-network block); and the initrd
**console keymap** is a known requirement but is not yet implemented in this
repo.

The former `remoteUnlock.sealHostKey`, `remoteUnlock.hostKeyPath`, and
`remoteUnlock.tpm2.enable` compatibility paths are intentionally gone.
`remoteUnlock.enable = true` now means exactly one thing: use a TPM-sealed
SSH identity under operator Secure Boot. Device classes without a TPM leave
remote unlock disabled and use their local, serial, or BMC console.

The offline NixOS artifact now carries an explicit device class and boot role.
The complete cross-plane schema described above is not implemented yet.
Existing class integrations therefore remain adapters over
the current backend-specific option trees. New documentation and code should
converge toward the common schema and the nixdeploy delivery boundary rather
than add another mirrored boot or rollout surface.

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
          # Illustrative values only. Real host policy belongs in the private
          # composition that imports this public mechanism.
          nixboot = {
            enable = true;
            loader.program = "systemd-boot";
            loader.efiVariables = "write"; # this host owns real NVRAM
            loader.timeout = 10;

            esp.mountPoint = "/boot";
            esp.byLabel = "ESP";
            esp.capacityMiB = 1024;

            generations = {
              keep = 4; # booted generation plus three newest alternatives
              capacity = {
                enable = true; # small Lanzaboote ESP
                # `lzbt` comes from the exact Lanzaboote input this host imports.
                lanzabootePackage = inputs.lanzaboote.packages.${pkgs.stdenv.hostPlatform.system}.lzbt;
              };
            };
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

The physical device and layout facts — device identity, capacity and
partition geometry — stay with nixstorage or the host's disk-layout owner.
nixboot owns the stick's boot role, the boot-medium constraints derived from
those facts, and the boot artifact placed on it. Writing or rotating that
artifact is delivery and therefore belongs to nixdeploy.

## Repository layout

| Path | Purpose |
|---|---|
| `flake.nix` | Flake entry point: `nixosModules.nixboot` / `.default`, `systemManagerModules.nixboot` / `.default`. |
| `modules/nixboot.nix` | The NixOS module itself. |
| `modules/extra-entries.nix` | `nixboot.extraEntries.*` — second, non-default UKIs on the same ESP (NixOS only). |
| `modules/image-artifact.nix` | Checked offline UEFI/systemd-boot artifact derived from the evaluated NixOS system. |
| `modules/system-manager-systemd-boot.nix` | Staged native systemd-boot and UKI backend for system-manager hosts. |
| `lib/mk-efi-disk-image-{verifier,check}.nix` | Provider-neutral final raw-disk acceptance gate. |
| `lib/mk-uki-{signing-request,signer}.nix` / `lib/mk-signed-uki-verifier.nix` | Secret-safe two-phase UKI signing: reproducible request, runtime signature, independent verification. |
| `lib/mk-pki-archive-tools.nix` | Interactive passphrase encryption/decryption for a Secure Boot PKI ciphertext that may live in a public Git repository. |
| `lib/register-boot-entry.nix` | The idempotent/self-healing NVRAM registrar, shared by both backends. |
| `docs/` | Reader-facing option-surface walkthrough and FAQ. |
| `CONTRACT.md` | The option surface as a fixed behavioral contract. |
| `checks/default.nix` | Eval-time tests for the NixOS module (+ one build-level idempotency proof). |
| `checks/system-manager.nix` | Eval-time tests for the system-manager backend. |
| `experiments/` | Runnable trials with recorded results — see [`experiments/README.md`](experiments/README.md). |
| `studies/` | Written investigations that motivate design decisions — see [`studies/README.md`](studies/README.md). |

## Related projects

Part of the same small, independently usable module family:
[nixarch](https://github.com/julian-corbet/nixarch-corbet-ch),
[nixnas](https://github.com/julian-corbet/nixnas),
[nixvps](https://github.com/julian-corbet/nixvps-corbet-ch),
[nixrescue](https://github.com/julian-corbet/nixrescue-corbet-ch), and
[nixdeploy](https://github.com/julian-corbet/nixdeploy-corbet-ch) meet at the
class, role, and delivery boundaries above. [nixram](https://github.com/julian-corbet/nixram-corbet-ch)
and [nixgpu](https://github.com/julian-corbet/nixgpu-corbet-ch) remain
separate subsystems; boot does not absorb their policy.

## License

[MIT License](LICENSE) &copy; 2026 Julian Corbet
