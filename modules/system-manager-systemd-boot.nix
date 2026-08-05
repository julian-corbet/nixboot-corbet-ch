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

  # NixCPU owns the declared CPU vendor and resolves the matching native package. Read this
  # defensively so importing NixBoot alone remains evaluable; an enabled backend asserts below
  # that the consuming host actually composed NixCPU's package contract.
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

  kernelPackages = lib.concatMap (kernel:
    [ kernel.package ] ++ lib.optional (kernel.headersPackage != null) kernel.headersPackage
  ) cfg.kernels;

  nativePackages = lib.unique (
    [ "mkinitcpio" "systemd-ukify" "sbctl" "efibootmgr" cfg.firmwarePackage ]
    ++ lib.optional (microcodePackage != null) microcodePackage
    ++ kernelPackages
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

  kernelCalls = lib.concatMapStrings (kernel: ''
    build_uki ${lib.escapeShellArg kernel.packageBase} ${lib.escapeShellArg kernel.id} ${if kernel.fallback then "yes" else "no"}
  '') cfg.kernels;

  stageScript = ''
    set -euo pipefail

    esp=${lib.escapeShellArg cfg.esp.mountPoint}
    prefix=${lib.escapeShellArg cfg.uki.prefix}
    secure_boot=${if cfg.secureBoot.enable then "yes" else "no"}
    sbctl_config=${if cfg.secureBoot.sbctlConfig == null then "''" else lib.escapeShellArg cfg.secureBoot.sbctlConfig}

    for command in /usr/bin/basename /usr/bin/df /usr/bin/du /usr/bin/findmnt /usr/bin/install /usr/bin/mkinitcpio /usr/bin/mktemp /usr/bin/rm /usr/bin/sbctl /usr/bin/stat; do
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
      echo "nixboot: $esp has $available_bytes free bytes, but staging requires $required_bytes bytes." >&2
      echo "nixboot: no ESP files were changed; free space or adjust the declared UKI set before retrying." >&2
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

    echo "nixboot: staged systemd-boot at $esp/EFI/systemd/systemd-bootx64.efi"
    echo "nixboot: current firmware entry and EFI/BOOT fallback were intentionally not changed."
  '';

  verifyScript = ''
    set -euo pipefail

    esp=${lib.escapeShellArg cfg.esp.mountPoint}
    prefix=${lib.escapeShellArg cfg.uki.prefix}
    fail=0

    check_efi() {
      local file="$1"
      if [ -s "$file" ] && [ "$(head -c2 "$file")" = "MZ" ]; then
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

  cutoverScript = ''
    set -euo pipefail

    esp=${lib.escapeShellArg cfg.esp.mountPoint}
    secure_boot=${if cfg.secureBoot.enable then "yes" else "no"}
    sbctl_config=${if cfg.secureBoot.sbctlConfig == null then "''" else lib.escapeShellArg cfg.secureBoot.sbctlConfig}

    for command in /usr/bin/bootctl /usr/bin/findmnt /usr/bin/systemctl; do
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
      [ -s "$file" ] && [ "$(head -c2 "$file")" = "MZ" ] || {
        echo "nixboot: final loader artifact is missing or invalid: $file" >&2
        exit 1
      }
    done
    /usr/bin/bootctl --esp-path="$esp" is-installed

    echo "nixboot: final systemd-boot cutover completed. Reboot only through the separately approved recovery test."
  '';

  retireLimineScript = ''
    set -euo pipefail

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
    boot_current="$(printf '%s\n' "$boot_table" | sed -n -E 's/^BootCurrent:[[:space:]]*([[:xdigit:]]{4})$/\1/p')"
    boot_order="$(printf '%s\n' "$boot_table" | sed -n -E 's/^BootOrder:[[:space:]]*([[:xdigit:],]+)$/\1/p')"
    [ -n "$boot_current" ] && [ -n "$boot_order" ] || {
      echo "nixboot: firmware did not report BootCurrent and BootOrder; refusing Limine retirement." >&2
      exit 1
    }
    current_line="$(printf '%s\n' "$boot_table" | sed -n -E "/^Boot$boot_current([*[:space:]])/p")"
    first_boot="''${boot_order%%,*}"
    first_line="$(printf '%s\n' "$boot_table" | sed -n -E "/^Boot$first_boot([*[:space:]])/p")"
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
  };

  config = lib.mkMerge [
    {
      nixboot.systemdBoot.archPackages = if cfg.enable then nativePackages else [ ];
    }
    (lib.mkIf cfg.enable {
      assertions = [
      {
        assertion = microcodePackage != null;
        message = ''
          nixboot.systemdBoot.enable requires nixcpu.capabilities.microcode.enable and an explicit
          bare-metal Intel/AMD NixCPU declaration. NixBoot consumes
          nixcpu.packages.bootMicrocode.archPackage so a host never repeats a vendor package name
          in its boot configuration.
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

      systemd.services = lib.mkIf cfg.stage.enable ({
      nixboot-systemd-boot-stage = {
        description = "NixBoot: stage systemd-boot and native UKIs without cutover";
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = stageScript;
      };
      nixboot-systemd-boot-verify = {
        description = "NixBoot: verify staged systemd-boot and native UKIs";
        after = [ "nixboot-systemd-boot-stage.service" ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = verifyScript;
      };
      } // lib.optionalAttrs cfg.cutover.enable {
      nixboot-systemd-boot-cutover = {
        description = "NixBoot: replace active fallback and create the systemd-boot firmware entry";
        after = [ "nixboot-systemd-boot-stage.service" ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = cutoverScript;
      };
      } // lib.optionalAttrs cfg.retireLimine.enable {
      nixboot-systemd-boot-retire-limine = {
        description = "NixBoot: retire Limine only after a proven systemd-boot cutover";
        after = [ "nixboot-systemd-boot-cutover.service" ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = retireLimineScript;
      };
      });

      # /etc/pacman.d/hooks has higher precedence than package-provided hooks. `replaceExisting`
      # avoids system-manager's silent existing-file skip, which would otherwise leave a stale
      # lifecycle contract after a manual experiment or an older NixBoot revision.
      environment.etc = lib.mkIf cfg.stage.enable {
        "pacman.d/hooks/95-nixboot-systemd-boot.hook" = {
          source = pacmanHookFile;
          replaceExisting = true;
        };
      };
    })
  ];
}
