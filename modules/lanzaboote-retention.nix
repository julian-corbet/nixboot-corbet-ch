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

  retainedLzbt = if capacity.lanzabootePackage == null then null else pkgs.writeShellApplication {
    name = "lzbt";
    runtimeInputs = [
      capacity.lanzabootePackage
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gawk
      pkgs.util-linux
      pkgs.systemd
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
      [ "$(${pkgs.util-linux}/bin/findmnt -no FSTYPE --target "$esp")" = vfat ] || {
        echo "nixboot: $esp is not the mounted FAT ESP; refusing retention collection." >&2
        exit 1
      }

      work="$(${pkgs.coreutils}/bin/mktemp -d /run/nixboot-lanzaboote-retention.XXXXXX)"
      trap '${pkgs.coreutils}/bin/rm -rf -- "$work"' EXIT
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
          /nix/var/nix/profiles/system-*-link)
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

      current_generation=""
      if [ -e /run/current-system ]; then
        current_generation="$(${pkgs.systemd}/bin/bootctl --esp-path="$esp" status 2>/dev/null |
          ${pkgs.gnused}/bin/sed -n -E 's/^[[:space:]]*Current Entry:[[:space:]]*nixos-generation-([0-9]+)-.*$/\1/p')"
        if ! [[ "$current_generation" =~ ^[0-9]+$ ]]; then
          echo "nixboot: could not identify the booted Lanzaboote generation from bootctl; refusing a capacity collection that might drop it." >&2
          exit 1
        fi
        ${pkgs.coreutils}/bin/ln -s "$(${pkgs.coreutils}/bin/readlink -f /run/current-system)" "$work/system-$current_generation-link"
      fi

      declare -A retained_generations=()
      selected=()
      if [ -n "$current_generation" ]; then
        retained_generations["$current_generation"]=1
        selected+=("$work/system-$current_generation-link")
      fi

      # lzbt sorts by the numeric generation component. Do the same explicitly,
      # excluding the booted generation so `keep` is a true total slot count.
      newest="$work/newest-profiles"
      for profile in "''${profiles[@]}"; do
        base="''${profile##*/}"
        generation="''${base#system-}"
        generation="''${generation%-link}"
        [[ "$generation" =~ ^[0-9]+$ ]] || continue
        printf '%020d\t%s\n' "$generation" "$profile"
      done | ${pkgs.coreutils}/bin/sort -rn > "$newest"

      selected_count="''${#selected[@]}"
      while IFS=$'\t' read -r _profile_order profile; do
        base="''${profile##*/}"
        generation="''${base#system-}"
        generation="''${generation%-link}"
        [ "$generation" = "$current_generation" ] && continue
        [ "$selected_count" -lt "$keep" ] || break
        retained_generations["$generation"]=1
        selected+=("$profile")
        selected_count=$((selected_count + 1))
      done < "$newest"

      [ "''${#selected[@]}" -gt 0 ] || {
        echo "nixboot: no NixOS generation links are available for Lanzaboote installation." >&2
        exit 1
      }

      linux_dir="$esp/EFI/Linux"
      nixos_dir="$esp/EFI/nixos"
      selected_stubs=()
      booted_stub_present=no
      if [ -d "$linux_dir" ]; then
        for stub in "$linux_dir"/nixos-generation-*.efi; do
          base="''${stub##*/}"
          if [[ "$base" =~ ^nixos-generation-([0-9]+)- ]]; then
            generation="''${BASH_REMATCH[1]}"
            if [ -n "''${retained_generations[$generation]:-}" ]; then
              selected_stubs+=("$stub")
              [ "$generation" != "$current_generation" ] || booted_stub_present=yes
            else
              ${pkgs.coreutils}/bin/rm -f -- "$stub"
            fi
          fi
        done
      fi

      if [ -n "$current_generation" ] && [ "$booted_stub_present" != yes ]; then
        echo "nixboot: the booted generation $current_generation has no ESP stub; refusing to collect more artifacts." >&2
        exit 1
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

      echo "nixboot: retaining ''${#selected[@]} normal generation(s), including booted generation ''${current_generation:-none}; $available_bytes bytes free before lzbt install."
      exec "$real_lzbt" "''${passthrough[@]}" "''${selected[@]}"
    '';
  };
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
    ];
    })

    (lib.mkIf (cfg.enable && capacity.enable && capacity.lanzabootePackage != null) {
      boot.lanzaboote.package = lib.mkOverride 500 retainedLzbt;
      system.build.nixbootLanzabooteRetention = retainedLzbt;
    })
  ];
}
