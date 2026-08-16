# nixboot's system-manager backend for Arch-family hosts.
#
# This is intentionally a clean systemd-boot + UKI backend. A system-manager host has no
# NixOS `boot.*` surface and continues to use its native pacman kernel/mkinitcpio toolchain;
# NixBoot therefore renders the native contract and builds UKIs with `mkinitcpio --uki` rather
# than pretending to own a NixOS kernel closure.
#
# The migration is two-step on purpose. Enabling this module only declares the native packages.
# `stage.enable` renders manual stage/verify units, but does not start them. The stage writes a
# separate EFI/systemd loader and UKIs under a unique prefix; it deliberately leaves the current
# firmware entry and EFI/BOOT fallback untouched. A physical, one-time boot through the staged
# loader proves the chain before a later, separately reviewed firmware cutover or Secure Boot
# enrollment. This preserves a known-good boot path while making every desired file/versioned
# command declarative and reviewable.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixboot.systemdBoot;

  # NixCPU owns microcode: which vendor blob a host needs is a CPU-keyed fact, and NixCPU already
  # models it (vendor detection, lib/package-catalogue.nix) while NixBoot cannot know the CPU
  # vendor at all. NixBoot therefore reads this contract ONLY to assert its presence below -- early
  # microcode is a hard boot-path requirement for a UKI, so an enabled backend must fail loudly
  # when no vendor package was selected -- and never adds the name to its own `nativePackages`.
  # Installing it is NixCPU's system-manager backend's job (nixcpu.packages.archPackages feeds
  # nixarch.packages.pacman directly); NixBoot repeating the name here was a second, redundant
  # declaration of the same pacman package into the same reconciler. Read defensively so importing
  # NixBoot alone remains evaluable; an enabled backend asserts below that the consuming host
  # actually composed NixCPU's package contract.
  microcodePackage = config.nixcpu.packages.bootMicrocode.archPackage or null;

  kernelType = lib.types.submodule ({ ... }: {
    options = {
      package = lib.mkOption {
        type = lib.types.str;
        description = "Native pacman kernel package to declare.";
      };
      packageBase = lib.mkOption {
        type = lib.types.str;
        description = "Expected content of /usr/lib/modules/<release>/pkgbase for this kernel.";
      };
      headersPackage = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Native headers package needed by this kernel's external modules, if any.";
      };
      id = lib.mkOption {
        type = lib.types.strMatching "[a-z0-9-]+";
        description = "Stable NixBoot UKI file suffix, distinct from the mutable kernel release.";
      };
      fallback = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Also build a fallback UKI without mkinitcpio's autodetect hook.";
      };
    };
  });

  kernelPackages = lib.concatMap
    (kernel:
      [ kernel.package ] ++ lib.optional (kernel.headersPackage != null) kernel.headersPackage
    )
    cfg.kernels;

  firmwareToolPackages = config.nixboot.firmware.packageNames;
  efitoolsPackage = lib.optional config.nixboot.tools.efitools.enable "efitools";

  # `hwdetect` -- the module-set LISTER, not a config writer; see its own option doc for why the
  # read-only half is the point. system-manager only: the package is Arch-family and nixpkgs has
  # no attribute for it at all (checked, not assumed), so unlike `efitools` there is no NixOS
  # counterpart for modules/nixboot.nix to select.
  hwdetectPackage = lib.optional config.nixboot.tools.hwdetect.enable "hwdetect";

  # `plymouth` -- boot COSMETICS, and deliberately NOT a member of tool-options.nix's `tools.*`
  # group. That group is shared with the NixOS backend and every member of it is a CLI whose
  # entire effect is being on PATH; plymouth is none of the three (see its option doc for what
  # selecting it actually rewires, and for the two things it does NOT arrange). Declaring it on
  # `nixboot.systemdBoot.*` instead makes "Arch plane only" structural rather than a promise in
  # prose: a NixOS host cannot set an option it does not have, so there is no silent no-op to
  # warn about -- it uses stock `boot.plymouth.*`.
  plymouthPackage = lib.optional cfg.plymouth.enable "plymouth";
  secureBootPackages = lib.optional cfg.secureBoot.enable "sbctl";

  # Microcode is deliberately absent from this list: it is a NixCPU-owned Arch package (see
  # `microcodePackage` above), installed once through NixCPU's own system-manager backend. Once
  # pacman has it installed, mkinitcpio's `-S autodetect` hook picks up the vendor ucode image on
  # its own -- NixBoot's UKI build needs the blob to exist, not to be the one that names it.
  nativePackages = lib.unique (
    [ "mkinitcpio" "systemd-ukify" "efibootmgr" cfg.firmwarePackage ]
    ++ kernelPackages
    ++ firmwareToolPackages
    ++ efitoolsPackage
    ++ hwdetectPackage
    ++ plymouthPackage
    ++ secureBootPackages
  );

  cmdlineFile = pkgs.writeText "nixboot-kernel-cmdline" "${cfg.kernelCmdline}\n";
  loaderConfFile = pkgs.writeText "nixboot-loader.conf" ''
    default ${cfg.loader.default}
    timeout ${toString cfg.loader.timeout}
    editor ${if cfg.loader.editor then "yes" else "no"}
  '';

  # Pacman owns the native kernel packages on a system-manager host, so it is the event source
  # for UKI regeneration. The hook is deliberately absent until the explicit stage gate is on:
  # before a local staged-loader test, no package upgrade may create a second boot path.
  pacmanHookFile = pkgs.writeText "95-nixboot-systemd-boot.hook" ''
    [Trigger]
    Operation = Install
    Operation = Upgrade
    Type = Path
    Target = usr/lib/modules/*/pkgbase

    [Trigger]
    Operation = Install
    Operation = Upgrade
    Type = Path
    Target = usr/lib/systemd/boot/efi/systemd-bootx64.efi

    [Action]
    Description = NixBoot: rebuild declared UKIs after native boot artifact update
    When = PostTransaction
    Depends = systemd
    Depends = mkinitcpio
    Exec = /usr/bin/systemctl start nixboot-systemd-boot-stage.service
  '';

  # Read by an operator and by anything that aggregates host health. /run, not /var, on purpose:
  # the fact this file states is scoped to the current boot and a reboot is what resolves it, so a
  # copy surviving into the next boot could only ever be a lie. It exists at all because the
  # journal is not a durable channel here — a system-manager host may run a volatile journal, and
  # on the host this check was written for `systemctl status` answered a 22-hour-old failure with
  # "journal has been rotated since unit was started, output may be incomplete".
  bootedKernelStatusFile = "/run/nixboot/booted-kernel";

  # Pacman owns the native kernel packages, so the transaction that replaces a module tree is the
  # only precise moment to re-ask this question. Ordered after the stage hook (95-) so a staged UKI
  # rebuild and this check report against the same post-transaction state. `restart`, not `start`:
  # the unit is a RemainAfterExit oneshot, and `start` on an already-succeeded oneshot is a no-op,
  # which would leave the previous run's verdict standing after the very event that invalidated it.
  # `Remove` is a trigger too — uninstalling a kernel deletes a module tree exactly like an upgrade.
  bootedKernelHookText = ''
    [Trigger]
    Operation = Install
    Operation = Upgrade
    Operation = Remove
    Type = Path
    Target = usr/lib/modules/*/pkgbase

    [Action]
    Description = NixBoot: re-check whether the booted kernel still matches the installed one
    When = PostTransaction
    Depends = systemd
    Exec = /usr/bin/systemctl restart nixboot-booted-kernel-verify.service
  '';

  bootedKernelHookFile = pkgs.writeText "96-nixboot-booted-kernel.hook" bootedKernelHookText;

  kernelCalls = lib.concatMapStrings
    (kernel: ''
      build_uki ${lib.escapeShellArg kernel.packageBase} ${lib.escapeShellArg kernel.id} ${if kernel.fallback then "yes" else "no"}
    '')
    cfg.kernels;

  # The exact ESP filenames the DECLARATION asks for. Derived from `kernels`, not from what a
  # build produced -- that difference is what lets collection run before staging, which is the
  # whole point of separating them (see collectFunction).
  desiredUkiNames = lib.concatMap
    (kernel:
      [ "${cfg.uki.prefix}-${kernel.id}.efi" ]
      ++ lib.optional kernel.fallback "${cfg.uki.prefix}-${kernel.id}-fallback.efi"
    )
    cfg.kernels;

  # Reclamation of NixBoot-owned ESP files that no declared kernel wants.
  #
  # This used to run only AFTER a successful staging, which deadlocks: staging needs ESP space,
  # the space is held by artifacts only collection can free, and collection sat behind the step it
  # was supposed to unblock. On a 512 MiB ESP carrying several UKIs that is not a theoretical
  # ordering nit -- it is the state where the boot subsystem can no longer update itself and says
  # so only as a capacity error. Collection therefore depends on nothing but the declaration: no
  # mkinitcpio run, no staging directory, no free space.
  #
  # Ownership is unchanged: the unique UKI prefix is still the only thing considered. A foreign
  # rescue image, vendor firmware capsule, Limine artifact or the active fallback is never a
  # candidate, before or after this change.
  collectFunction = ''
    collect_stale_ukis() {
      local linux_dir="$esp/EFI/Linux"
      local existing base current_entry size boot_status
      local pruned=0 freed=0

      # Read by the caller. NOT local: the standalone unit turns a refusal into a failed unit,
      # while staging only notes it and lets the capacity gate speak for itself.
      collect_skipped=no

      [ -d "$linux_dir" ] || return 0

      # Never collect the entry this host actually booted, even if the declaration has since moved
      # on and no longer names it. Same invariant the Lanzaboote retention path enforces one layer
      # over: a running kernel's boot entry is not garbage because a config changed, and firmware
      # is the only authority on which entry that is.
      #
      # So this DELETION path runs only when firmware can be asked and answers. "Is it in the
      # declared set?" is a different question and not a fallback for this one -- the booted entry
      # being absent from the declared set is precisely the case this guard exists for (a kernel
      # dropped from `kernels` while the host still runs it), and precisely the case where matching
      # on the declared set alone would delete it. Collection is an optimisation; a running
      # kernel's boot entry is not, so when the authority is unavailable nothing is collected.
      if [ ! -x /usr/bin/bootctl ]; then
        echo "nixboot: /usr/bin/bootctl is absent, so the booted entry cannot be identified; refusing to collect anything." >&2
        collect_skipped=yes
        return 0
      fi

      boot_status="$(LC_ALL=C /usr/bin/bootctl --esp-path="$esp" status 2>&1 || true)"

      # bootctl can report a valid loader while also saying firmware loaded it from a DIFFERENT
      # ESP. `Current Entry` then names a file on that other partition, so matching it by basename
      # against this one could protect the wrong file and delete the right one.
      case "$boot_status" in
        *"reports a different partition UUID"*)
          echo "nixboot: firmware booted a different ESP from $esp; refusing to collect anything." >&2
          collect_skipped=yes
          return 0
          ;;
      esac

      current_entry="$(printf '%s\n' "$boot_status" |
        /usr/bin/sed -n -E 's/^[[:space:]]*Current Entry:[[:space:]]*(.+\.efi).*$/\1/p')"

      if [ -z "$current_entry" ]; then
        echo "nixboot: firmware did not report a Current Entry for $esp, so the booted entry cannot be identified; refusing to collect anything." >&2
        collect_skipped=yes
        return 0
      fi

      for existing in "$linux_dir/$prefix-"*.efi "$linux_dir/$prefix-"*.efi.new "$linux_dir/$prefix-"*.efi.tmp; do
        base="$(/usr/bin/basename "$existing")"

        if [ "$base" = "$current_entry" ]; then
          echo "nixboot: keeping $base -- firmware reports it as the entry this host booted"
          continue
        fi
    ${lib.optionalString (desiredUkiNames != [ ]) ''
        case "$base" in
          ${lib.concatMapStringsSep "|" lib.escapeShellArg desiredUkiNames}) continue ;;
        esac
    ''}
        size="$(/usr/bin/stat --format=%s "$existing" 2>/dev/null || echo 0)"
        /usr/bin/rm -f -- "$existing"
        pruned=$((pruned + 1))
        freed=$((freed + size))
      done

      echo "nixboot: collected $pruned stale NixBoot UKI artifact(s), $((freed / 1024 / 1024)) MiB reclaimed."
    }
  '';

  collectScript = ''
    set -euo pipefail

    # Native PATH -- see the note on `stageScript` below for why an absolutely-invoked
    # /usr/bin/* script still needs it.
    export PATH=/usr/bin:/usr/local/bin:''${PATH:-}

    esp=${lib.escapeShellArg cfg.esp.mountPoint}
    prefix=${lib.escapeShellArg cfg.uki.prefix}

    # bootctl is a hard requirement HERE, unlike in staging: this unit's entire job is a deletion
    # sweep, and it cannot prove which entry booted this host without it.
    for command in /usr/bin/basename /usr/bin/bootctl /usr/bin/findmnt /usr/bin/rm /usr/bin/sed /usr/bin/stat; do
      [ -x "$command" ] || {
        echo "nixboot: required native command is absent: $command" >&2
        exit 1
      }
    done

    [ -d "$esp" ] || { echo "nixboot: ESP mount point does not exist: $esp" >&2; exit 1; }
    [ "$(/usr/bin/findmnt -no FSTYPE --target "$esp")" = "vfat" ] || {
      echo "nixboot: $esp is not the mounted FAT ESP; refusing to collect boot artifacts." >&2
      exit 1
    }
    shopt -s nullglob

    ${collectFunction}

    collect_stale_ukis

    # An operator asked this unit to reclaim space and it declined. That must be visible as a
    # failed unit, not a green one that quietly did nothing.
    [ "$collect_skipped" = no ] || {
      echo "nixboot: no artifacts were collected -- see the refusal above. This unit reclaims space only when firmware can name the entry this host booted." >&2
      exit 1
    }
  '';

  stageScript = ''
    set -euo pipefail

    # THE NATIVE PATH, AND WHY EVERY SCRIPT HERE NEEDS IT DESPITE CALLING BY ABSOLUTE PATH.
    #
    # Every native command below is invoked as `/usr/bin/<name>`, so a unit's own PATH looks
    # irrelevant. It is not. Those absolute paths are SHELL SCRIPTS on Arch --
    # `/usr/bin/mkinitcpio` begins `#!/usr/bin/env bash` -- and `env bash` resolves through the
    # PATH of the process that execs it. A generated unit's PATH is a handful of nix store
    # directories (coreutils, findutils, gnugrep, gnused, systemd-minimal) and contains no bash.
    #
    # MEASURED, not theorised: without this, the UKI build died with `env: 'bash': No such file or
    # directory` and `status=127`, on every kernel update, for five days -- while every preflight
    # check below passed, because the binaries genuinely were present and executable. The result
    # was a machine running a kernel whose package had already been replaced, carrying no UKI for
    # the kernel it actually had installed, and nothing anywhere saying so.
    #
    # `/usr/bin` and not `pkgs.bash`: this module is the native-Arch plane, it installs nothing,
    # and it already hardcodes `/usr/bin/*` throughout. Handing a native script a nix bash would be
    # a different and less honest coupling than letting it find its own interpreter.
    export PATH=/usr/bin:/usr/local/bin:''${PATH:-}

    esp=${lib.escapeShellArg cfg.esp.mountPoint}
    prefix=${lib.escapeShellArg cfg.uki.prefix}
    secure_boot=${if cfg.secureBoot.enable then "yes" else "no"}
    sbctl_config=${if cfg.secureBoot.sbctlConfig == null then "''" else lib.escapeShellArg cfg.secureBoot.sbctlConfig}

    required_commands=(/usr/bin/basename /usr/bin/df /usr/bin/du /usr/bin/findmnt /usr/bin/install /usr/bin/mkinitcpio /usr/bin/mktemp /usr/bin/rm /usr/bin/sed /usr/bin/stat)
    [ "$secure_boot" != yes ] || required_commands+=(/usr/bin/sbctl)
    for command in "''${required_commands[@]}"; do
      [ -x "$command" ] || {
        echo "nixboot: required native command is absent: $command" >&2
        echo "nixboot: activate the declared native package set before staging." >&2
        exit 1
      }
    done

    [ -d "$esp" ] || { echo "nixboot: ESP mount point does not exist: $esp" >&2; exit 1; }
    [ "$(/usr/bin/findmnt -no FSTYPE --target "$esp")" = "vfat" ] || {
      echo "nixboot: $esp is not the mounted FAT ESP; refusing to write boot artifacts." >&2
      exit 1
    }
    staging_dir="$(/usr/bin/mktemp -d /var/tmp/nixboot-systemd-boot.XXXXXX)"
    trap '/usr/bin/rm -rf "$staging_dir"' EXIT
    shopt -s nullglob

    ${collectFunction}

    # BEFORE the capacity check, not after the install. Collection needs nothing this staging run
    # produces, so running it first is what keeps a full ESP recoverable: the artifacts that would
    # free the space are exactly the ones no declared kernel wants. Deleting them cannot break a
    # declared boot path, and the booted entry is excluded regardless of what the declaration says.
    #
    # A refusal (no bootctl, a different ESP, no Current Entry) is NOT fatal here: it has already
    # printed why, and staging is not a reclamation request. Either the declared set still fits --
    # in which case nothing was needed -- or the capacity gate below refuses with its own explicit
    # shortfall. Collection is never a precondition for staging, only an aid to it.
    collect_stale_ukis

    build_uki() {
      local package_base="$1" id="$2" fallback="$3"
      local module_dir pkgbase release output
      local -a matches=()

      for module_dir in /usr/lib/modules/*; do
        [ -f "$module_dir/pkgbase" ] || continue
        pkgbase="$(<"$module_dir/pkgbase")"
        [ "$pkgbase" = "$package_base" ] && matches+=("$module_dir")
      done

      if [ "''${#matches[@]}" -ne 1 ]; then
        echo "nixboot: expected exactly one installed kernel for pkgbase $package_base; found ''${#matches[@]}." >&2
        exit 1
      fi

      release="$(/usr/bin/basename "''${matches[0]}")"
      output="$staging_dir/$prefix-$id.efi"
      /usr/bin/mkinitcpio --kernel "$release" --uki "$output" --cmdline ${cmdlineFile}

      if [ "$fallback" = yes ]; then
        output="$staging_dir/$prefix-$id-fallback.efi"
        /usr/bin/mkinitcpio --kernel "$release" --uki "$output" --cmdline ${cmdlineFile} -S autodetect
      fi
    }

    ${kernelCalls}

    # Build everything off the ESP first. The ESP remains untouched until the exact new UKI
    # sizes fit, so a small ESP fails closed instead of leaving a partial staged boot path.
    loader_source=/usr/lib/systemd/boot/efi/systemd-bootx64.efi
    loader_output="$esp/EFI/systemd/systemd-bootx64.efi"
    mapfile -t df_lines < <(/usr/bin/df -B1 --output=avail "$esp")
    available_bytes="''${df_lines[1]//[[:space:]]/}"
    case "$available_bytes" in
      ""|*[!0-9]*)
        echo "nixboot: could not determine free space on $esp." >&2
        exit 1
        ;;
    esac

    required_bytes=$((1024 * 1024)) # FAT allocation and metadata reserve.
    add_required_bytes() {
      local source="$1" destination="$2" source_bytes destination_bytes
      source_bytes="$(/usr/bin/stat --format=%s "$source")"
      destination_bytes=0
      [ ! -f "$destination" ] || destination_bytes="$(/usr/bin/stat --format=%s "$destination")"
      if [ "$source_bytes" -gt "$destination_bytes" ]; then
        required_bytes=$((required_bytes + source_bytes - destination_bytes))
      fi
    }

    add_required_bytes "$loader_source" "$loader_output"
    for uki in "$staging_dir"/*.efi; do
      add_required_bytes "$uki" "$esp/EFI/Linux/$(/usr/bin/basename "$uki")"
    done
    if [ "$available_bytes" -lt "$required_bytes" ]; then
      # Say the number in the unit the declaration is written in. `esp.capacityMiB`,
      # `generations.capacity.*` and every ESP budget in this family are MiB, so a bare byte count
      # forces an operator to do arithmetic before they can act on it. Bytes stay for precision.
      echo "nixboot: insufficient ESP capacity on $esp -- need $((required_bytes / 1024 / 1024)) MiB, have $((available_bytes / 1024 / 1024)) MiB (need $required_bytes bytes, have $available_bytes)." >&2
      echo "nixboot: stale NixBoot artifacts were already collected above, so this is what the declared UKI set genuinely costs; no ESP files were changed." >&2
      echo "nixboot: reduce the declared set (a kernel's fallback = false is usually the largest single UKI), or grow the ESP. NixBoot will not drop a declared boot artifact on its own." >&2
      exit 1
    fi

    /usr/bin/install -d -m0755 "$esp/EFI/Linux"
    # This intentionally does not write EFI/BOOT/BOOTX64.EFI and does not touch NVRAM. The
    # current loader remains the recovery path until an operator verifies this staged one locally.
    /usr/bin/install -Dm0644 "$loader_source" "$loader_output"
    [ "$secure_boot" != yes ] || /usr/bin/sbctl --config "$sbctl_config" sign -s "$loader_output"
    /usr/bin/install -Dm0644 ${cmdlineFile} /etc/kernel/cmdline
    /usr/bin/install -Dm0644 ${loaderConfFile} "$esp/loader/loader.conf"

    for uki in "$staging_dir"/*.efi; do
      output="$esp/EFI/Linux/$(/usr/bin/basename "$uki")"
      /usr/bin/install -m0644 "$uki" "$output"
      [ "$secure_boot" != yes ] || /usr/bin/sbctl --config "$sbctl_config" sign -s "$output"
    done

    # Second pass, same collector: the pre-staging call cannot see a `.new`/`.tmp` leftover this
    # run's own install may have produced. It is deliberately the SAME function rather than a
    # second prune loop -- two implementations of "what does NixBoot own" is how one of them ends
    # up deleting something the other protects.
    collect_stale_ukis

    echo "nixboot: staged systemd-boot at $esp/EFI/systemd/systemd-bootx64.efi"
    echo "nixboot: current firmware entry and EFI/BOOT fallback were intentionally not changed."
  '';

  verifyScript = ''
    set -euo pipefail

    # Native PATH -- see the note on `stageScript` below for why an absolutely-invoked
    # /usr/bin/* script still needs it.
    export PATH=/usr/bin:/usr/local/bin:''${PATH:-}

    esp=${lib.escapeShellArg cfg.esp.mountPoint}
    prefix=${lib.escapeShellArg cfg.uki.prefix}
    fail=0

    for command in /usr/bin/head; do
      [ -x "$command" ] || {
        echo "nixboot: required native command is absent: $command" >&2
        exit 1
      }
    done

    check_efi() {
      local file="$1"
      if [ -s "$file" ] && [ "$(/usr/bin/head -c2 "$file")" = "MZ" ]; then
        echo "PASS  nixboot: $file is a non-empty EFI image"
      else
        echo "FAIL  nixboot: $file is missing or not an EFI image" >&2
        fail=1
      fi
    }

    check_efi "$esp/EFI/systemd/systemd-bootx64.efi"
    [ -s "$esp/loader/loader.conf" ] || { echo "FAIL  nixboot: loader.conf is missing" >&2; fail=1; }
    ${lib.concatMapStrings (kernel: ''
      check_efi "$esp/EFI/Linux/$prefix-${kernel.id}.efi"
      ${lib.optionalString kernel.fallback ''check_efi "$esp/EFI/Linux/$prefix-${kernel.id}-fallback.efi"''}
    '') cfg.kernels}

    if [ "$fail" -ne 0 ]; then
      echo "nixboot: staged systemd-boot verification failed; retain the current boot path." >&2
      exit 1
    fi
    echo "nixboot: staged loader and UKIs verified. Select EFI/systemd/systemd-bootx64.efi once from firmware before any cutover."
  '';

  # Staleness of the BOOTED kernel, which is a different question from every other check in this
  # backend: those ask whether the artifacts on the ESP are the ones NixBoot declared, this asks
  # whether the kernel this host is actually executing still exists on disk. A native kernel
  # upgrade replaces /usr/lib/modules/<release> wholesale. Modules already resident keep working,
  # so nothing looks wrong; the next on-demand modprobe is what fails, in whichever subsystem
  # happens to ask first, with an error that describes that subsystem and not the kernel. This
  # unit exists so the condition is stated where it is true rather than rediscovered from a
  # downstream symptom.
  #
  # It reports and stops there. No reboot, no install, no restore — the same ownership line
  # nixnet draws in its own BEHAVIORS.md (OWN-2): a layer that acts on its own judgement destroys
  # the evidence of the fault underneath it and makes its own action the story. Rebooting is a
  # deploy concern with a different blast radius and a different owner. What this unit owes the
  # operator is an unambiguous statement, not a decision.
  bootedKernelVerifyScript = ''
    set -euo pipefail

    # Native PATH -- see the note on `stageScript` below for why an absolutely-invoked
    # /usr/bin/* script still needs it.
    export PATH=/usr/bin:/usr/local/bin:''${PATH:-}

    for command in /usr/bin/basename /usr/bin/install /usr/bin/mv /usr/bin/uname; do
      [ -x "$command" ] || {
        echo "nixboot: required native command is absent: $command" >&2
        exit 1
      }
    done

    status_file=${lib.escapeShellArg bootedKernelStatusFile}
    running="$(/usr/bin/uname -r)"
    modules_dir="/usr/lib/modules/$running"
    fail=0
    lines=()
    shopt -s nullglob

    # Every verdict goes to both the log and the status file, so the two can never disagree about
    # what this run found. FAIL additionally goes to stderr, where systemd marks it.
    record() {
      lines+=("$1")
      if [ "''${2:-pass}" = fail ]; then
        fail=1
        echo "$1" >&2
      else
        echo "$1"
      fi
    }

    # Same discovery the stage script uses: pkgbase, not a filename convention, is what ties an
    # installed module tree back to the native package that owns it.
    installed_releases() {
      local base="$1" candidate
      for candidate in /usr/lib/modules/*; do
        [ -f "$candidate/pkgbase" ] || continue
        [ "$(<"$candidate/pkgbase")" = "$base" ] || continue
        /usr/bin/basename "$candidate"
      done
    }

    # Check 1 — does the running kernel still have a module tree at all?
    if [ -d "$modules_dir" ]; then
      record "PASS  nixboot: booted kernel $running still owns its module tree at $modules_dir"
    else
      record "FAIL  nixboot: booted kernel $running has no module tree at $modules_dir. A native kernel transaction removed it. Modules already loaded keep working, so this host looks healthy while every on-demand module load from now on fails — the symptom will appear in whichever subsystem asks for a module first and will describe that subsystem, not this. Reboot into the installed kernel to resolve it. NixBoot will not reboot, install, or restore anything on its own." fail
    fi

    # Check 2 — is the running release still the installed release of its own native package?
    # This is the half that stays true when a module-preserving hook keeps Check 1 green: the tree
    # is there, but the package has moved on and this host is executing yesterday's kernel.
    booted_base=""
    [ ! -f "$modules_dir/pkgbase" ] || booted_base="$(<"$modules_dir/pkgbase")"

    if [ -n "$booted_base" ]; then
      releases=()
      while IFS= read -r release; do
        releases+=("$release")
      done < <(installed_releases "$booted_base")

      others=()
      for release in "''${releases[@]}"; do
        [ "$release" = "$running" ] || others+=("$release")
      done

      if [ "''${#others[@]}" -eq 0 ]; then
        record "PASS  nixboot: native package $booted_base is installed at $running, the release this host booted"
      else
        # A second tree for the SAME package is what a module-preserving native hook
        # (kernel-modules-hook, mkmm) deliberately leaves behind, and it is exactly the state those
        # hooks make invisible: Check 1 stays green because the old tree was kept, so nothing else
        # on the host reports that the running kernel is no longer the installed one. Distinguished
        # from plain absence because the two need different words to be actionable.
        record "FAIL  nixboot: this host booted $running from native package $booted_base, but $booted_base also has ''${others[*]} installed. A newer kernel is on disk and this host is still executing the older one; a reboot is what converges them. NixBoot will not reboot anything." fail
      fi
    else
      # Check 1 has already failed here — the tree that would name the owning package is the tree
      # that is gone. Report the declared kernels' installed releases anyway: that is the operator's
      # answer to "what replaced it", and it costs nothing to state.
      record "SKIP  nixboot: $modules_dir/pkgbase is unreadable, so the booted kernel's native package identity cannot be established; the declared kernels below are what is installed now"
      ${lib.concatMapStrings (kernel: ''
        declared_releases=()
        while IFS= read -r release; do
          declared_releases+=("$release")
        done < <(installed_releases ${lib.escapeShellArg kernel.packageBase})
        record "SKIP  nixboot: declared kernel ${kernel.packageBase} (UKI id ${kernel.id}) is installed at ''${declared_releases[*]:-nothing}"
      '') cfg.kernels}
    fi

    /usr/bin/install -d -m0755 "$(/usr/bin/dirname "$status_file")"
    printf '%s\n' "''${lines[@]}" > "$status_file.new"
    /usr/bin/mv -f "$status_file.new" "$status_file"

    if [ "$fail" -ne 0 ]; then
      echo "nixboot: the booted kernel no longer matches what is installed on this host. Full verdict: $status_file" >&2
      exit 1
    fi
    echo "nixboot: booted kernel and installed kernel agree; module tree intact."
  '';

  cutoverScript = ''
    set -euo pipefail

    # Native PATH -- see the note on `stageScript` below for why an absolutely-invoked
    # /usr/bin/* script still needs it.
    export PATH=/usr/bin:/usr/local/bin:''${PATH:-}

    esp=${lib.escapeShellArg cfg.esp.mountPoint}
    secure_boot=${if cfg.secureBoot.enable then "yes" else "no"}
    sbctl_config=${if cfg.secureBoot.sbctlConfig == null then "''" else lib.escapeShellArg cfg.secureBoot.sbctlConfig}

    for command in /usr/bin/bootctl /usr/bin/findmnt /usr/bin/head /usr/bin/systemctl; do
      [ -x "$command" ] || {
        echo "nixboot: required native command is absent: $command" >&2
        exit 1
      }
    done
    [ "$(/usr/bin/findmnt -no FSTYPE --target "$esp")" = "vfat" ] || {
      echo "nixboot: $esp is not the mounted FAT ESP; refusing final cutover." >&2
      exit 1
    }

    # Restart is intentional: a successful oneshot verify unit may still describe an older stage.
    /usr/bin/systemctl restart nixboot-systemd-boot-verify.service

    # This is the one explicit point that replaces the active fallback and writes the firmware
    # boot entry. Do not add `--graceful`: inability to write EFI variables is a failed cutover.
    /usr/bin/bootctl --esp-path="$esp" --variables=yes \
      --efi-boot-option-description=${lib.escapeShellArg cfg.cutover.efiBootOptionDescription} install

    loader_output="$esp/EFI/systemd/systemd-bootx64.efi"
    fallback_output="$esp/EFI/BOOT/BOOTX64.EFI"
    if [ "$secure_boot" = yes ]; then
      /usr/bin/sbctl --config "$sbctl_config" sign -s "$loader_output"
      /usr/bin/sbctl --config "$sbctl_config" sign -s "$fallback_output"
    fi

    for file in "$loader_output" "$fallback_output"; do
      [ -s "$file" ] && [ "$(/usr/bin/head -c2 "$file")" = "MZ" ] || {
        echo "nixboot: final loader artifact is missing or invalid: $file" >&2
        exit 1
      }
    done
    /usr/bin/bootctl --esp-path="$esp" is-installed

    echo "nixboot: final systemd-boot cutover completed. Reboot only through the separately approved recovery test."
  '';

  retireLimineScript = ''
    set -euo pipefail

    # Native PATH -- see the note on `stageScript` below for why an absolutely-invoked
    # /usr/bin/* script still needs it.
    export PATH=/usr/bin:/usr/local/bin:''${PATH:-}

    esp=${lib.escapeShellArg cfg.esp.mountPoint}
    legacy_artifacts=( ${lib.concatMapStringsSep " " lib.escapeShellArg cfg.retireLimine.legacyArtifacts} )
    legacy_empty_directories=( ${lib.concatMapStringsSep " " lib.escapeShellArg cfg.retireLimine.legacyEmptyDirectories} )
    protected_paths=( ${lib.concatMapStringsSep " " lib.escapeShellArg cfg.retireLimine.protectedPaths} )
    limine_packages=( ${lib.concatMapStringsSep " " lib.escapeShellArg cfg.retireLimine.packages} )

    for command in /usr/bin/bootctl /usr/bin/cmp /usr/bin/efibootmgr /usr/bin/find /usr/bin/findmnt /usr/bin/install /usr/bin/ln /usr/bin/mktemp /usr/bin/pacman /usr/bin/readlink /usr/bin/rm /usr/bin/rmdir /usr/bin/sed /usr/bin/sha256sum /usr/bin/sort /usr/bin/systemctl /usr/bin/xargs; do
      [ -x "$command" ] || { echo "nixboot: required native command is absent: $command" >&2; exit 1; }
    done
    [ "$(/usr/bin/findmnt -no FSTYPE --target "$esp")" = "vfat" ] || {
      echo "nixboot: $esp is not the mounted FAT ESP; refusing Limine retirement." >&2
      exit 1
    }

    # A staged file set is not enough. This host must be running the systemd-boot path that the
    # final cutover registered before any fallback or Limine artifact can be retired.
    /usr/bin/systemctl restart nixboot-systemd-boot-verify.service
    /usr/bin/bootctl --esp-path="$esp" is-installed

    boot_table="$(/usr/bin/efibootmgr -v)"
    boot_current="$(printf '%s\n' "$boot_table" | /usr/bin/sed -n -E 's/^BootCurrent:[[:space:]]*([[:xdigit:]]{4})$/\1/p')"
    boot_order="$(printf '%s\n' "$boot_table" | /usr/bin/sed -n -E 's/^BootOrder:[[:space:]]*([[:xdigit:],]+)$/\1/p')"
    [ -n "$boot_current" ] && [ -n "$boot_order" ] || {
      echo "nixboot: firmware did not report BootCurrent and BootOrder; refusing Limine retirement." >&2
      exit 1
    }
    current_line="$(printf '%s\n' "$boot_table" | /usr/bin/sed -n -E "/^Boot$boot_current([*[:space:]])/p")"
    first_boot="''${boot_order%%,*}"
    first_line="$(printf '%s\n' "$boot_table" | /usr/bin/sed -n -E "/^Boot$first_boot([*[:space:]])/p")"
    case "$current_line" in
      *'\EFI\systemd\systemd-bootx64.efi'*|*'\EFI\BOOT\BOOTX64.EFI'*) ;;
      *)
        echo "nixboot: BootCurrent $boot_current is not systemd-boot; keep Limine as recovery and investigate." >&2
        exit 1
        ;;
    esac
    case "$first_line" in
      *'\EFI\systemd\systemd-bootx64.efi'*) ;;
      *)
        echo "nixboot: first BootOrder entry is not the NixBoot systemd-boot entry; refusing Limine retirement." >&2
        exit 1
        ;;
    esac

    # NVRAM identifiers drift. Match the actual Limine device path and insist on exactly one
    # match instead of assuming today's Boot0007 remains the correct target.
    limine_entries=()
    while IFS= read -r line; do
      if [[ "$line" == Boot????* && "$line" == *'\EFI\limine\limine_x64.efi'* ]]; then
        entry="''${line:4:4}"
        [[ "$entry" =~ ^[[:xdigit:]]{4}$ ]] && limine_entries+=("$entry")
      fi
    done <<< "$boot_table"
    if [ "''${#limine_entries[@]}" -ne 1 ]; then
      echo "nixboot: expected exactly one Limine EFI entry, found ''${#limine_entries[@]}; refusing NVRAM changes." >&2
      exit 1
    fi

    # A declaration error must not turn an explicit legacy-artifact list into a way to erase a
    # recovery or vendor path. Check both child and parent relationships before anything changes.
    for protected in "''${protected_paths[@]}"; do
      for target in "''${legacy_artifacts[@]}" "''${legacy_empty_directories[@]}"; do
        case "$target:$protected" in
          "$protected":*|"$protected"/*:*|*:"$target"|*:"$target"/*)
            echo "nixboot: legacy target $target overlaps protected path $protected; refusing retirement." >&2
            exit 1
            ;;
        esac
      done
    done

    hash_snapshot() {
      local path
      for path in "''${protected_paths[@]}"; do
        [ -e "$path" ] || { echo "nixboot: protected path is missing: $path" >&2; return 1; }
        if [ -f "$path" ]; then
          /usr/bin/sha256sum "$path"
        else
          /usr/bin/find "$path" -type f -print0 | /usr/bin/sort -z | /usr/bin/xargs -0r /usr/bin/sha256sum
        fi
      done
    }

    before="$(/usr/bin/mktemp /run/nixboot-retire-limine.XXXXXX)"
    after="$(/usr/bin/mktemp /run/nixboot-retire-limine.XXXXXX)"
    trap '/usr/bin/rm -f "$before" "$after"' EXIT
    hash_snapshot > "$before"

    # Native hooks with these exact names have higher-precedence /etc masks. The generic
    # mkinitcpio and global sbctl hooks would otherwise recreate non-UKI artifacts or sign a
    # broader mutable set outside NixBoot's declared lifecycle.
    for hook in 90-mkinitcpio-install.hook zz-sbctl.hook; do
      hook_path="/etc/pacman.d/hooks/$hook"
      /usr/bin/install -d -m0755 /etc/pacman.d/hooks
      /usr/bin/rm -f "$hook_path"
      /usr/bin/ln -s /dev/null "$hook_path"
      [ "$(/usr/bin/readlink "$hook_path")" = /dev/null ] || {
        echo "nixboot: failed to mask native hook $hook_path" >&2
        exit 1
      }
    done

    installed_packages=()
    for package in "''${limine_packages[@]}"; do
      /usr/bin/pacman -Q "$package" >/dev/null 2>&1 && installed_packages+=("$package")
    done
    if [ "''${#installed_packages[@]}" -gt 0 ]; then
      /usr/bin/pacman -Rns --noconfirm --nosave "''${installed_packages[@]}"
    fi

    /usr/bin/efibootmgr --delete-bootnum --bootnum "''${limine_entries[0]}"
    for path in "''${legacy_artifacts[@]}"; do
      /usr/bin/rm -f "$path"
    done
    for path in "''${legacy_empty_directories[@]}"; do
      /usr/bin/rmdir --ignore-fail-on-non-empty "$path"
    done

    hash_snapshot > "$after"
    if ! /usr/bin/cmp -s "$before" "$after"; then
      echo "nixboot: protected EFI artifact changed during Limine retirement; investigate immediately." >&2
      exit 1
    fi
    echo "nixboot: Limine retirement completed; systemd-boot is now the sole loader path."
  '';
in
{
  imports = [ ./firmware-tools.nix ./tool-options.nix ];

  options.nixboot.systemdBoot = {
    enable = lib.mkEnableOption "NixBoot's staged native systemd-boot and UKI backend";

    esp.mountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/boot";
      description = "Mounted FAT ESP. This module never partitions, formats, or mounts it.";
    };

    firmwarePackage = lib.mkOption {
      type = lib.types.str;
      default = "linux-firmware";
      description = "Native firmware package kept with the boot-capable kernel set.";
    };

    kernels = lib.mkOption {
      type = lib.types.listOf kernelType;
      default = [ ];
      description = "The native kernels NixBoot stages as UKIs and declares through the Arch backend.";
    };

    kernelCmdline = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = "Exact kernel command line embedded in every staged UKI.";
    };

    ## ── Boot cosmetics: the one thing in this backend that is not a mechanism ──
    ## Everything else here answers "what boots this machine"; a splash answers "what does a
    ## human see while it does". It is here anyway because the two things a splash actually
    ## needs are this backend's own two surfaces and nobody else's -- the word `splash` on the
    ## KERNEL COMMAND LINE (`kernelCmdline` directly above, rendered into every staged UKI) and a
    ## `plymouth` HOOK in the initramfs generator (`mkinitcpio`, which this backend drives) -- and
    ## because plymouth's whole job is over before any desktop exists, so nothing on the desktop
    ## side can own it. The widening stops at selection; the gap is stated, not papered over.
    plymouth.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Select `plymouth`, the graphical boot splash, into this backend's native package set.

        THIS OPTION SELECTS THE PACKAGE AND ARRANGES NOTHING ELSE, AND THAT GAP IS THE POINT. A
        splash needs three things; NixBoot does exactly one of them:

          1. the package -- this option, and the whole of it;
          2. `splash` on the kernel command line -- NOT arranged. `kernelCmdline` above is an
             opaque string this backend renders VERBATIM into every staged UKI; nothing here
             composes or appends to it, so the word is the consumer's to write. (The requirement
             is the vendor's own: plymouth's mkinitcpio hook says in its `help()` that it shows
             a splash "if the 'splash' kernel parameter is specified".)
          3. `plymouth` in `HOOKS=()` in `/etc/mkinitcpio.conf` -- NOT arranged, and not from
             here ever. NixBoot does not write that file; that is the same line
             `nixboot.tools.hwdetect` draws, for the same reason -- a declared `mkinitcpio.conf`
             with a second writer is a declaration that has quietly stopped describing the
             machine. The package ships the hook DEFINITION at
             `/usr/lib/initcpio/install/plymouth`, and a definition that no `HOOKS=()` names
             contributes nothing to the initramfs.

        SELECTING THE PACKAGE IS NOT INERT, WHICH IS PRECISELY WHY IT IS A BOOT DECISION AND NOT
        A LINE IN A PACKAGE LIST. Unlike `tools.efitools` / `tools.hwdetect`, whose entire effect
        is a binary on PATH, pacman's payload here rewires the stage-2 unit graph the moment it
        lands: the package ships its own `.wants` symlinks, pulling `plymouth-start.service` and
        `plymouth-read-write.service` into `sysinit.target` and `plymouth-quit.service` +
        `plymouth-quit-wait.service` into `multi-user.target`. And `plymouth-start.service` gates
        only on `ConditionKernelCommandLine=!plymouth.enable=0` and
        `ConditionVirtualization=!container` -- never on `splash` -- so on bare metal `plymouthd
        --mode=boot` starts on the next boot from the package alone, with no hook and no command
        line word anywhere. (Measured, not assumed: `pacman -Fl plymouth` for the symlinks and
        the unit files themselves out of package 26.134.222-2.)

        THE TRAP IS A COLD-BOOT ONE. `quiet splash` on a host whose initramfs carries no plymouth
        hook buys no splash and still pays the `quiet`: the kernel log is gone for exactly the
        boot that now has nothing in its place. On THIS backend there is no boot-menu escape from
        that -- the command line is baked into the UKI at build time, `loader.editor` defaults to
        false, and a signed UKI's stub ignores an externally supplied command line anyway. Nor is
        the fallback UKI one: it is built from the same `kernelCmdline`. Recovery is re-staging
        with a different declared command line or removing the package, both of which need the
        box to boot far enough to run them.

        DELIBERATELY NOT ASSERTED AGAINST `kernelCmdline`. NixBoot could grep that string for
        `splash` and refuse the mismatch, and elsewhere it would: a setting that does nothing is
        a bug here, not a shrug. It does not here because a splash rollout on a machine that must
        be physically rebooted is legitimately three separate steps -- package, hook, command
        line -- taken in whatever order the operator can test one at a time, and refusing the
        intermediate states would refuse the only safe way to do it. The command line stays
        opaque, as it is everywhere else in this backend.

        Arch plane only, for a DIFFERENT reason than `tools.hwdetect`'s (which is Arch-only
        because nixpkgs has no such package at all): nixpkgs does have plymouth, and NixOS's
        stock `boot.plymouth.*` already does the whole job -- initrd contents and kernel
        parameters both. NixBoot writing into that would be a second owner of a knob that already
        has one, so the NixOS backend declares nothing here and a NixOS host sets
        `boot.plymouth.enable` directly.
      '';
    };

    uki.prefix = lib.mkOption {
      type = lib.types.strMatching "[a-z0-9-]+";
      default = "nixboot";
      description = "Unique filename prefix below EFI/Linux; only files with this prefix are NixBoot-owned.";
    };

    loader = {
      default = lib.mkOption { type = lib.types.str; default = "@saved"; };
      timeout = lib.mkOption { type = lib.types.ints.unsigned; default = 3; };
      editor = lib.mkOption { type = lib.types.bool; default = false; };
    };

    secureBoot = {
      enable = lib.mkEnableOption "sign staged NixBoot UKIs with a host-provisioned sbctl key";

      sbctlConfig = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Root-owned runtime path to an sbctl configuration whose key and GUID paths are supplied
          outside the Nix store. NixBoot never copies, generates, or persists Secure Boot private
          material; the host's private secret-delivery module owns that lifecycle.
        '';
      };
    };

    bootedKernel.verify.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run `nixboot-booted-kernel-verify` after boot and after every native kernel transaction:
        report whether the running kernel still has a module tree, and whether its release is
        still the one its native package installs. Defaults on, like the NixOS backend's own
        `verify.enable`, and for the same reason — the failure it names is silent by
        construction. Unlike `stage`, `cutover` and `retireLimine` this unit writes nothing
        outside its own status file, so it needs no manual gate; it never reboots, installs, or
        restores anything, and it is not a substitute for a module-preserving native hook.
      '';
    };

    stage.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Render manual `nixboot-systemd-boot-stage` and `nixboot-systemd-boot-verify` units.
        They are never wanted automatically: first activate the declaration, then stage and verify
        while physically present before changing firmware boot order or Secure Boot enrollment.
      '';
    };

    cutover = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Render the manual final-cutover unit. It replaces the active fallback loader and writes
          a systemd-boot EFI variable only after a verified staged-loader test. The unit is never
          wanted automatically.
        '';
      };

      efiBootOptionDescription = lib.mkOption {
        type = lib.types.str;
        default = "NixBoot systemd-boot";
        description = "Firmware boot-option description passed to bootctl during the final manual cutover.";
      };
    };

    retireLimine = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Render the manual post-boot Limine-retirement unit. It removes only the declared
          Limine packages, files, NVRAM entry, and native hooks after a physical systemd-boot
          boot has succeeded. It is never wanted automatically.
        '';
      };

      packages = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "limine" "limine-mkinitcpio-hook" ];
        description = "Native packages removed with --nosave after the systemd-boot cutover is proven.";
      };

      legacyArtifacts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Exact legacy Limine files to remove; directories are refused here and handled separately.";
      };

      legacyEmptyDirectories = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Legacy directories to remove only when empty after the exact artifact retirement.";
      };

      protectedPaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Non-NixBoot EFI paths whose complete SHA-256 file set must remain unchanged during retirement.";
      };
    };

    archPackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      description = "Native packages selected by this backend for a host-provided Arch reconciler.";
    };

    bootedKernel.hookText = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "The generated pacman hook (same text the rendered file holds). Exposed for checks/system-manager.nix's static-text assertions; not a stable interface.";
    };
  };

  config = lib.mkMerge [
    {
      nixboot.systemdBoot.archPackages = if cfg.enable then nativePackages else [ ];
      nixboot.systemdBoot.bootedKernel.hookText = bootedKernelHookText;
    }
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = microcodePackage != null;
          message = ''
            nixboot.systemdBoot.enable requires nixcpu.capabilities.microcode.enable and an explicit
            bare-metal Intel/AMD NixCPU declaration. NixBoot only READS
            nixcpu.packages.bootMicrocode.archPackage to confirm early microcode was selected for
            this boot path; it never installs the package itself, so a host declares the vendor
            blob exactly once, in NixCPU.
          '';
        }
        {
          assertion = !cfg.stage.enable || cfg.kernelCmdline != null;
          message = "nixboot.systemdBoot.stage.enable requires an explicit kernelCmdline; never inherit a potentially temporary /proc/cmdline.";
        }
        {
          assertion = !cfg.stage.enable || cfg.kernels != [ ];
          message = "nixboot.systemdBoot.stage.enable requires at least one declared native kernel.";
        }
        {
          assertion = lib.length (lib.unique (map (kernel: kernel.id) cfg.kernels)) == lib.length cfg.kernels;
          message = "nixboot.systemdBoot.kernels must use unique UKI ids.";
        }
        {
          assertion = !cfg.secureBoot.enable || cfg.secureBoot.sbctlConfig != null;
          message = "nixboot.systemdBoot.secureBoot.enable requires secureBoot.sbctlConfig: declare a root-owned runtime sbctl configuration through the host's secret-delivery mechanism, never a Nix store key path.";
        }
        {
          assertion = !cfg.cutover.enable || cfg.stage.enable;
          message = "nixboot.systemdBoot.cutover.enable requires stage.enable: a final fallback/NVRAM change is only valid after the separate staged path exists.";
        }
        {
          assertion = !cfg.retireLimine.enable || cfg.cutover.enable;
          message = "nixboot.systemdBoot.retireLimine.enable requires cutover.enable: Limine is retired only after final systemd-boot fallback/NVRAM ownership is declared.";
        }
        {
          assertion = !cfg.retireLimine.enable || cfg.retireLimine.legacyArtifacts != [ ];
          message = "nixboot.systemdBoot.retireLimine.enable requires explicit legacyArtifacts; never use a broad directory deletion on an ESP.";
        }
        {
          assertion = !cfg.retireLimine.enable || cfg.retireLimine.protectedPaths != [ ];
          message = "nixboot.systemdBoot.retireLimine.enable requires protectedPaths to detect unintended changes to recovery or firmware artifacts.";
        }
      ];

      systemd.services = lib.mkMerge [
        # Wanted by multi-user.target, unlike every other unit in this backend. The others write the
        # ESP, NVRAM, or the package set and are therefore manual by contract; this one only reads,
        # and the question it answers is only meaningful about a boot that has actually happened.
        (lib.mkIf cfg.bootedKernel.verify.enable {
          nixboot-booted-kernel-verify = {
            description = "NixBoot: report whether the booted kernel still matches the installed one";
            wantedBy = [ "multi-user.target" ];
            after = [ "multi-user.target" ];
            serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
            script = bootedKernelVerifyScript;
          };
        })

        (lib.mkIf cfg.stage.enable ({
          nixboot-systemd-boot-stage = {
            description = "NixBoot: stage systemd-boot and native UKIs without cutover";
            # system-manager's switch script starts changed services even without WantedBy=. This
            # unit writes the ESP and must run only through the explicit pacman hook or an operator.
            restartIfChanged = false;
            serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
            script = stageScript;
          };
          nixboot-systemd-boot-verify = {
            description = "NixBoot: verify staged systemd-boot and native UKIs";
            after = [ "nixboot-systemd-boot-stage.service" ];
            restartIfChanged = false;
            serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
            script = verifyScript;
          };
          # Independently runnable, and deliberately NOT ordered after the stage unit. Staging already
          # collects first; this exists so an operator facing a full ESP can reclaim NixBoot's own
          # garbage without needing a staging run to succeed — the ordering that used to be impossible.
          nixboot-systemd-boot-collect = {
            description = "NixBoot: reclaim NixBoot-owned UKIs that no declared kernel wants";
            restartIfChanged = false;
            serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
            script = collectScript;
          };
        } // lib.optionalAttrs cfg.cutover.enable {
          nixboot-systemd-boot-cutover = {
            description = "NixBoot: replace active fallback and create the systemd-boot firmware entry";
            after = [ "nixboot-systemd-boot-stage.service" ];
            restartIfChanged = false;
            serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
            script = cutoverScript;
          };
        } // lib.optionalAttrs cfg.retireLimine.enable {
          nixboot-systemd-boot-retire-limine = {
            description = "NixBoot: retire Limine only after a proven systemd-boot cutover";
            after = [ "nixboot-systemd-boot-cutover.service" ];
            restartIfChanged = false;
            serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
            script = retireLimineScript;
          };
        }))
      ];

      # /etc/pacman.d/hooks has higher precedence than package-provided hooks. `replaceExisting`
      # avoids system-manager's silent existing-file skip, which would otherwise leave a stale
      # lifecycle contract after a manual experiment or an older NixBoot revision.
      environment.etc = lib.mkMerge [
        (lib.mkIf cfg.bootedKernel.verify.enable {
          "pacman.d/hooks/96-nixboot-booted-kernel.hook" = {
            source = bootedKernelHookFile;
            replaceExisting = true;
          };
        })
        (lib.mkIf cfg.stage.enable {
          "pacman.d/hooks/95-nixboot-systemd-boot.hook" = {
            source = pacmanHookFile;
            replaceExisting = true;
          };
        })
      ];
    })
  ];
}
