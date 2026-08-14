# Capacity-accounted Lanzaboote retention.
#
# Upstream lzbt chooses only the newest profile links and garbage-collects only
# after it has written their artifacts. On a small ESP that is the wrong order:
# a long-running system can be omitted from the input set, and a full ESP can
# reject a new initrd before upstream reaches its own collector. This wrapper
# chooses the booted generation plus the newest alternatives, vacuums only
# unreferenced Lanzaboote files before the install, and leaves a declared write
# reserve. It deliberately owns no non-nixos-* EFI/Linux files; durable rescue
# UKIs remain extraEntries' separate ownership domain.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixboot;
  capacity = cfg.generations.capacity;
  extraEntries = config.nixboot.extraEntries or { };

  entryBudgetMiB = lib.foldl'
    (total: entry:
      total + (if entry.espCapacityMiB == null then 0 else entry.history.keep * entry.espCapacityMiB))
    0
    (lib.attrValues extraEntries);

  everyExtraEntryBudgeted = lib.all (entry: entry.espCapacityMiB != null) (lib.attrValues extraEntries);
  requiredMiB = capacity.fixedMiB + capacity.reserveMiB + capacity.generationMiB * cfg.generations.keep + capacity.extraReservedMiB + entryBudgetMiB;

  # TEST SEAM, and nothing else. Every command below is invoked by absolute
  # store path deliberately, so no caller's PATH can redirect the tools whose
  # answers decide which boot files get deleted -- which also means the
  # PATH-order stubbing lib/register-boot-entry.nix uses for its own execution
  # test cannot reach them. The three tools worth stubbing (bootctl, findmnt,
  # lsblk) are exactly the ones the guards below interrogate the live system
  # with, and a guard that is only ever proved by grepping this file for a
  # string is not proved at all. These four arguments let checks/default.nix
  # rebuild this same text against stand-ins, a scratch ESP and a scratch
  # profile directory; production passes none of them and gets the defaults.
  mkRetainedLzbt =
    { systemdPackage ? pkgs.systemd
    , utilLinuxPackage ? pkgs.util-linux
    , bootedSystemLink ? "/run/booted-system"
    , profilesDirectory ? "/nix/var/nix/profiles"
    }: pkgs.writeShellApplication {
      name = "lzbt";
      runtimeInputs = [
        capacity.lanzabootePackage
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.gawk
        utilLinuxPackage
        systemdPackage
      ];
      text = ''
        set -euo pipefail

        real_lzbt=${lib.escapeShellArg (lib.getExe capacity.lanzabootePackage)}
        esp=${lib.escapeShellArg cfg.esp.mountPoint}
        keep=${toString cfg.generations.keep}
        reserve_bytes=$(( ${toString capacity.reserveMiB} * 1024 * 1024 ))

        # Only `lzbt install` writes the ESP. Preserve upstream behavior for all
        # other invocations so this package remains a transparent lzbt command.
        if [ "''${1:-}" != install ]; then
          exec "$real_lzbt" "$@"
        fi

        [ -d "$esp" ] || { echo "nixboot: ESP mount point does not exist: $esp" >&2; exit 1; }
        [ "$(${utilLinuxPackage}/bin/findmnt -no FSTYPE --target "$esp")" = vfat ] || {
          echo "nixboot: $esp is not the mounted FAT ESP; refusing retention collection." >&2
          exit 1
        }

        # bootctl can report a valid loader while also saying firmware loaded it
        # from a different ESP. Firmware records that partition ONCE, at boot, in
        # LoaderDevicePartUUID: it is a snapshot of the medium systemd-boot was
        # started from, never a live pointer, and no installer can refresh it --
        # only a reboot can. So the mismatch has two very different causes, and
        # only one of them is a reason to stop:
        #
        #   - The partition firmware named is STILL PRESENT, and it is not this
        #     ESP. Two media can serve this host's boot path, this one is
        #     demonstrably not the one firmware read, and a collection here would
        #     prune and install the wrong partition. Genuinely ambiguous: refuse.
        #
        #   - NO partition on this system carries that UUID any more, and this
        #     ESP is the only EFI System Partition present. The recording names a
        #     medium that no longer exists -- a boot medium rebuilt under the
        #     running system, its partition GUID regenerated, is the ordinary
        #     way to get here. There is no second candidate to be wrong about,
        #     and the only escape from the state is the reboot that this very
        #     refusal prevents: every switch fails at the bootloader install, so
        #     the host keeps running the generation it has and reboots onto the
        #     same stale record. Refusing there makes the fault permanent and
        #     protects nothing. Warn, naming both partitions, and proceed.
        #
        # Which of the two it is comes from the live partition table, never from
        # the mere existence of the warning.
        boot_status="$(LC_ALL=C ${systemdPackage}/bin/bootctl --esp-path="$esp" status 2>&1 || true)"
        loader_esp_stale=no
        mismatch="$(printf '%s\n' "$boot_status" |
          ${pkgs.gnugrep}/bin/grep -m1 '^WARNING: The boot loader reports a different partition UUID' || true)"

        if [ -n "$mismatch" ]; then
          # bootctl names both partitions on that one line, as "(<loader> vs. <esp>)".
          uuids="$(printf '%s\n' "$mismatch" |
            ${pkgs.gnused}/bin/sed -n -E 's/.*\(([0-9a-fA-F-]+) vs\. ([0-9a-fA-F-]+)\).*/\1 \2/p' |
            ${pkgs.coreutils}/bin/tr '[:upper:]' '[:lower:]')"
          loader_uuid="''${uuids%% *}"
          esp_uuid="''${uuids##* }"
          if [ -z "$uuids" ] || [ -z "$loader_uuid" ] || [ -z "$esp_uuid" ]; then
            echo "nixboot: firmware booted a different ESP from $esp and bootctl named no partition pair to compare; refusing retention collection." >&2
            exit 1
          fi

          # c12a7328-f81f-11d2-ba4b-00a0c93ec93b is the GPT EFI System Partition
          # type GUID; 0xef is its MBR equivalent, which some firmware still
          # boots. Both count towards "how many media on this system could be
          # the one firmware read".
          partitions="$(${utilLinuxPackage}/bin/lsblk --noheadings --raw --output PARTUUID,PARTTYPE 2>/dev/null || true)"
          esp_partuuids="$(printf '%s\n' "$partitions" |
            ${pkgs.gawk}/bin/awk 'tolower($2) == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" || tolower($2) == "0xef" { print tolower($1) }')"
          esp_partitions="$(printf '%s' "$esp_partuuids" | ${pkgs.gnugrep}/bin/grep -c . || true)"

          if printf '%s\n' "$partitions" |
            ${pkgs.gawk}/bin/awk -v want="$loader_uuid" 'tolower($1) == want { found = 1 } END { exit !found }'; then
            echo "nixboot: firmware booted a different ESP from $esp ($esp_uuid): partition $loader_uuid is still present on this system, so the medium firmware read is reachable and it is not this one; refusing retention collection." >&2
            exit 1
          fi

          if [ "$esp_partitions" != 1 ] || [ "$esp_partuuids" != "$esp_uuid" ]; then
            echo "nixboot: firmware booted a different ESP from $esp ($esp_uuid): partition $loader_uuid is gone, but this system carries $esp_partitions EFI System Partition(s), so which medium firmware read cannot be decided from here; refusing retention collection." >&2
            exit 1
          fi

          loader_esp_stale=yes
          echo "nixboot: WARNING: firmware recorded LoaderDevicePartUUID $loader_uuid, no partition on this system carries it any more, and $esp ($esp_uuid) is the only EFI System Partition present." >&2
          echo "nixboot: WARNING: systemd-boot writes that variable once, at boot, from the medium it was loaded from; no installation can refresh it, so it stays stale until this host reboots. Proceeding on the single unambiguous ESP." >&2
        fi

        shopt -s nullglob

        profiles=()
        passthrough=()
        have_limit=no
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --configuration-limit)
              [ "$#" -ge 2 ] || { echo "nixboot: lzbt install omitted the value for --configuration-limit." >&2; exit 1; }
              passthrough+=("--configuration-limit=0")
              have_limit=yes
              shift 2
              continue
              ;;
            --configuration-limit=*)
              passthrough+=("--configuration-limit=0")
              have_limit=yes
              ;;
            ${lib.escapeShellArg profilesDirectory}/system-*-link)
              [ -L "$1" ] || [ -e "$1" ] || { shift; continue; }
              profiles+=("$1")
              shift
              continue
              ;;
            *)
              passthrough+=("$1")
              ;;
          esac
          shift
        done
        [ "$have_limit" = yes ] || passthrough+=("--configuration-limit=0")

        linux_dir="$esp/EFI/Linux"
        nixos_dir="$esp/EFI/nixos"

        current_entry=""
        current_generation=""
        if [ -e ${lib.escapeShellArg bootedSystemLink} ]; then
          current_entry="$(printf '%s\n' "$boot_status" |
            ${pkgs.gnused}/bin/sed -n -E 's/^[[:space:]]*Current Entry:[[:space:]]*(nixos-generation-[^[:space:]]+\.efi).*$/\1/p')"
          # systemd-boot can report the attempt-counter form. The file may have
          # been blessed to its bare name since then, so compare the stable
          # entry identity while retaining whichever counter form exists.
          current_entry="''${current_entry%.efi}"
          current_entry="''${current_entry%%+*}.efi"
          if [[ "$current_entry" =~ ^nixos-generation-([0-9]+)-[a-z0-9]+\.efi$ ]]; then
            current_generation="''${BASH_REMATCH[1]}"
          else
            echo "nixboot: could not identify the exact booted Lanzaboote entry from bootctl; refusing a capacity collection that might drop it." >&2
            exit 1
          fi
        fi

        # Real Lanzaboote garbage collection roots ONLY the generation links it
        # receives. Reserving the booted generation in our slot count is not enough:
        # locate its immutable profile link and prove that it resolves to the exact
        # booted system before either preserving or reconstructing its UKI.
        booted_profile=""
        if [ -n "$current_generation" ]; then
          for profile in "''${profiles[@]}"; do
            base="''${profile##*/}"
            generation="''${base#system-}"
            generation="''${generation%-link}"
            if [ "$generation" = "$current_generation" ]; then
              booted_profile="$profile"
              break
            fi
          done

          booted_system="$(${pkgs.coreutils}/bin/readlink -f ${lib.escapeShellArg bootedSystemLink} 2>/dev/null || true)"
          booted_profile_system="$(${pkgs.coreutils}/bin/readlink -f "$booted_profile" 2>/dev/null || true)"
          if [ -z "$booted_profile" ] || [ -z "$booted_system" ] || [ "$booted_profile_system" != "$booted_system" ]; then
            if [ "$loader_esp_stale" = yes ]; then
              echo "nixboot: WARNING: the recorded boot medium is gone and no exact generation-$current_generation profile link can root the booted system; treating it as an ordinary retention candidate." >&2
              current_entry=""
              current_generation=""
              booted_profile=""
            else
              echo "nixboot: generation $current_generation does not resolve through an exact profile link to ${lib.escapeShellArg bootedSystemLink}; refusing to collect or install boot artifacts." >&2
              exit 1
            fi
          fi
        fi

        # Resolve the booted entry to a file on THIS ESP before choosing
        # anything. An absent file is reconstructable only because the profile
        # proof above binds the bootctl generation to /run/booted-system.
        booted_stub=""
        if [ -n "$current_entry" ] && [ -d "$linux_dir" ]; then
          for stub in "$linux_dir"/nixos-generation-*.efi; do
            base="''${stub##*/}"
            stable_entry="''${base%.efi}"
            stable_entry="''${stable_entry%%+*}.efi"
            if [ "$stable_entry" = "$current_entry" ]; then
              booted_stub="$stub"
              break
            fi
          done
        fi
        if [ -n "$current_entry" ] && [ -z "$booted_stub" ]; then
          echo "nixboot: WARNING: the exact booted entry $current_entry is absent from $linux_dir; reconstructing it from $booted_profile, which resolves exactly to ${lib.escapeShellArg bootedSystemLink}." >&2
        fi

        declare -A retained_generations=()
        selected=()
        selected_count=0
        if [ -n "$current_generation" ]; then
          retained_generations["$current_generation"]=1
          # Passing the immutable generation link is load-bearing: upstream lzbt
          # roots only the profiles it receives, then garbage-collects every other
          # nixos-* entry. If the stub already exists lzbt registers it without
          # rewriting; if it is missing, this exact bootspec reconstructs it.
          selected+=("$booted_profile")
          selected_count=1
        fi

        # lzbt sorts by the numeric generation component. Do the same explicitly,
        # excluding the booted generation so `keep` is a true total slot count.
        # The sorted list arrives through process substitution rather than a
        # scratch file: the loop must run in THIS shell to keep the selections it
        # makes, and a bootloader installer should not need a writable directory
        # of its own to decide what to retain.
        while IFS=$'\t' read -r _profile_order profile; do
          base="''${profile##*/}"
          generation="''${base#system-}"
          generation="''${generation%-link}"
          [ "$generation" = "$current_generation" ] && continue
          [ "$selected_count" -lt "$keep" ] || break
          retained_generations["$generation"]=1
          selected+=("$profile")
          selected_count=$((selected_count + 1))
        done < <(
          for profile in "''${profiles[@]}"; do
            base="''${profile##*/}"
            generation="''${base#system-}"
            generation="''${generation%-link}"
            [[ "$generation" =~ ^[0-9]+$ ]] || continue
            printf '%020d\t%s\n' "$generation" "$profile"
          done | ${pkgs.coreutils}/bin/sort -rn
        )

        [ "$selected_count" -gt 0 ] || {
          echo "nixboot: no NixOS generation links are available for Lanzaboote installation." >&2
          exit 1
        }

        selected_stubs=()
        if [ -d "$linux_dir" ]; then
          for stub in "$linux_dir"/nixos-generation-*.efi; do
            base="''${stub##*/}"
            if [[ "$base" =~ ^nixos-generation-([0-9]+)- ]]; then
              generation="''${BASH_REMATCH[1]}"
              if [ "$stub" = "$booted_stub" ]; then
                selected_stubs+=("$stub")
              elif [ "$generation" != "$current_generation" ] && [ -n "''${retained_generations[$generation]:-}" ]; then
                selected_stubs+=("$stub")
              else
                ${pkgs.coreutils}/bin/rm -f -- "$stub"
              fi
            fi
          done
        fi

        # Kernels/initrds are content-addressed, shared by the stubs that name
        # them, and are owned exclusively by Lanzaboote's EFI/nixos directory.
        # Remove only a file no retained stub references; unknown files stay put.
        if [ -d "$nixos_dir" ]; then
          for artifact in "$nixos_dir"/initrd-*.efi "$nixos_dir"/kernel-*.efi; do
            base="''${artifact##*/}"
            referenced=no
            for stub in "''${selected_stubs[@]}"; do
              if ${pkgs.gnugrep}/bin/grep -aFq -- "$base" "$stub"; then
                referenced=yes
                break
              fi
            done
            [ "$referenced" = yes ] || ${pkgs.coreutils}/bin/rm -f -- "$artifact"
          done
          # A failed lzbt copy leaves only these temporary files. They cannot be
          # referenced by a bootable stub and are safe to reclaim before retrying.
          ${pkgs.coreutils}/bin/rm -f -- "$nixos_dir"/initrd-*.efi.tmp "$nixos_dir"/kernel-*.efi.tmp
        fi

        ${pkgs.coreutils}/bin/sync
        available_bytes="$(${pkgs.coreutils}/bin/df -B1 --output=avail "$esp" | ${pkgs.coreutils}/bin/tail -n1 | ${pkgs.coreutils}/bin/tr -d '[:space:]')"
        case "$available_bytes" in
          ""|*[!0-9]*)
            echo "nixboot: could not determine free ESP space after collection." >&2
            exit 1
            ;;
        esac
        if [ "$available_bytes" -lt "$reserve_bytes" ]; then
          echo "nixboot: $esp has $available_bytes bytes free after safe collection, below the declared ${toString capacity.reserveMiB} MiB write reserve; refusing installation." >&2
          exit 1
        fi

        echo "nixboot: retaining $selected_count normal generation(s), including exact booted entry ''${current_entry:-none}; $available_bytes bytes free before lzbt install."
        exec "$real_lzbt" "''${passthrough[@]}" "''${selected[@]}"
      '';
    };

  # Production takes the defaults; `passthru.mkTestVariant` is the ONLY caller
  # that ever supplies the seam arguments above, exactly as
  # lib/register-boot-entry.nix exposes its own.
  retainedLzbt =
    if capacity.lanzabootePackage == null then null
    else
      (mkRetainedLzbt { }).overrideAttrs (old: {
        passthru = (old.passthru or { }) // {
          mkTestVariant = args: mkRetainedLzbt args;
        };
      });
in
{
  config = lib.mkMerge [
    (lib.mkIf (cfg.enable && capacity.enable) {
      assertions = [
        {
          assertion = cfg.loader.program == "lanzaboote";
          message = "nixboot.generations.capacity.enable is a Lanzaboote-specific retention path; set loader.program = \"lanzaboote\" or leave capacity.enable = false.";
        }
        {
          assertion = capacity.lanzabootePackage != null;
          message = "nixboot.generations.capacity.enable requires generations.capacity.lanzabootePackage from the exact Lanzaboote flake composed by this host; lzbt is not a nixpkgs package.";
        }
        {
          assertion = cfg.esp.capacityMiB != null;
          message = "nixboot.generations.capacity.enable needs esp.capacityMiB so its declared normal, rescue and write-reserve budget can be validated before an ESP fills.";
        }
        {
          assertion = everyExtraEntryBudgeted;
          message = "nixboot.generations.capacity.enable requires every declared extraEntries entry to state espCapacityMiB; protected rescue UKIs must be in the ESP budget, never an uncounted afterthought.";
        }
        {
          assertion = cfg.esp.capacityMiB == null || requiredMiB <= cfg.esp.capacityMiB;
          message = "nixboot.generations.capacity budget is ${toString requiredMiB} MiB (fixed ${toString capacity.fixedMiB} + reserve ${toString capacity.reserveMiB} + ${toString cfg.generations.keep} normal generation(s) x ${toString capacity.generationMiB} + externally-maintained protected UKIs ${toString capacity.extraReservedMiB} + extraEntries UKIs ${toString entryBudgetMiB}), but esp.capacityMiB is only ${toString (if cfg.esp.capacityMiB == null then 0 else cfg.esp.capacityMiB)} MiB. Reduce retained entries or increase the ESP; do not ship an impossible boot budget.";
        }
        {
          assertion = cfg.generations.keep >= 2;
          message = "nixboot.generations.capacity requires generations.keep >= 2 so the exact booted entry and at least one new candidate can coexist.";
        }
      ];
    })

    (lib.mkIf (cfg.enable && capacity.enable && capacity.lanzabootePackage != null) {
      boot.lanzaboote.package = lib.mkOverride 500 retainedLzbt;
      system.build.nixbootLanzabooteRetention = retainedLzbt;
    })
  ];
}
