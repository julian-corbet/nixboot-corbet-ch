# Build the UEFI boot portion of an offline image. The caller owns the disk
# geometry and root filesystem; this function owns the files firmware and
# systemd-boot consume before switch-root.
{ pkgs
, name
, deviceClass
, role ? "primary"
, steadyStateHandoff
, title
, version
, toplevel
, kernel
, initrd
, kernelParams ? [ ]
, entryId ? "${if role == "primary" then "nixos" else "nixrescue"}-generation-1"
, sortKey ? if role == "primary" then "nixos" else "nixrescue"
, timeout ? null
, editor ? false
, consoleMode ? null
, efiArch ? pkgs.stdenv.hostPlatform.efiArch
, systemd ? pkgs.systemd
,
}:
let
  lib = pkgs.lib;

  safeToken = value: builtins.match "^[A-Za-z0-9][A-Za-z0-9._-]*$" value != null;
  oneLine = value: builtins.match "^[^\n\r]*$" value != null;
  parameterIsSafe = value: oneLine value && !(lib.hasPrefix "init=" value);

  loaderName = "systemd-boot${efiArch}.efi";
  fallbackName = "BOOT${lib.toUpper efiArch}.EFI";
  kernelName = "${entryId}-kernel.efi";
  initrdName = "${entryId}-initrd.efi";
  entryName = "${entryId}.conf";
  initPath = "${toplevel}/init";
  completeKernelParams = [ "init=${initPath}" ] ++ kernelParams;
  kernelParamsText = lib.concatStringsSep " " completeKernelParams;

  loaderConf = ''
    timeout ${if timeout == null then "menu-force" else toString timeout}
    default ${entryName}
    ${lib.optionalString (!editor) "editor 0"}
    ${lib.optionalString (consoleMode != null) "console-mode ${consoleMode}"}
  '';

  bootEntry = ''
    title ${title}
    sort-key ${sortKey}
    version ${version}
    linux /EFI/nixos/${kernelName}
    initrd /EFI/nixos/${initrdName}
    options ${kernelParamsText}
  '';

  manifestJson = builtins.toJSON {
    schemaVersion = 2;
    inherit name deviceClass role;
    firmware = {
      interface = "uefi";
      architecture = efiArch;
      # An offline disk cannot contain a firmware variable. Its first boot
      # therefore always enters through the architecture fallback path. The
      # running system may subsequently maintain an NVRAM entry when its
      # declared firmware policy permits that write.
      initialHandoff = "removable";
      inherit steadyStateHandoff;
      removableFallback = "/EFI/BOOT/${fallbackName}";
    };
    loader = {
      family = "systemd-boot";
      executable = "/EFI/systemd/${loaderName}";
      defaultEntry = "/loader/entries/${entryName}";
      selfHealRequired = true;
    };
    integrity = {
      firmwareVerified = false;
      initrdAuthenticatedByKernel = false;
      reason = "Type-1 BLS carries a separate initrd; this artifact must not be represented as a signed-UKI chain";
    };
    payload = {
      type = "bls-type1";
      kernel = "/EFI/nixos/${kernelName}";
      initrd = "/EFI/nixos/${initrdName}";
      init = initPath;
      kernelParams = completeKernelParams;
    };
  };

  loaderConfFile = pkgs.writeText "${name}-loader.conf" loaderConf;
  bootEntryFile = pkgs.writeText "${name}-${entryName}" bootEntry;
  manifestFile = pkgs.writeText "${name}-nixboot-artifact.json" manifestJson;

  artifact = pkgs.runCommand "${name}-${role}-nixboot-artifact"
    {
      outputs = [ "out" "manifest" ];
      nativeBuildInputs = [ pkgs.binutils pkgs.coreutils pkgs.gnugrep ];
    }
    ''
      set -euo pipefail

      install -Dm0444 ${systemd}/lib/systemd/boot/efi/${loaderName} \
        "$out/EFI/systemd/${loaderName}"
      install -Dm0444 ${systemd}/lib/systemd/boot/efi/${loaderName} \
        "$out/EFI/BOOT/${fallbackName}"
      install -Dm0444 ${loaderConfFile} "$out/loader/loader.conf"
      install -Dm0444 ${bootEntryFile} "$out/loader/entries/${entryName}"
      printf 'type1\n' > "$out/loader/entries.srel"
      chmod 0444 "$out/loader/entries.srel"
      install -Dm0444 ${kernel} "$out/EFI/nixos/${kernelName}"
      install -Dm0444 ${initrd} "$out/EFI/nixos/${initrdName}"
      install -Dm0444 ${manifestFile} "$manifest/nixboot-boot-artifact.json"

      # This is a build gate, not a second rendering path. It proves the
      # finished tree has the exact handoff that the manifest describes.
      test -e ${lib.escapeShellArg initPath}
      test -s "$out/EFI/systemd/${loaderName}"
      test -s "$out/EFI/BOOT/${fallbackName}"
      test -s "$out/EFI/nixos/${kernelName}"
      test -s "$out/EFI/nixos/${initrdName}"
      cmp "$out/EFI/systemd/${loaderName}" "$out/EFI/BOOT/${fallbackName}"
      objdump -f "$out/EFI/systemd/${loaderName}" | grep 'file format pei-' >/dev/null
      objdump -f "$out/EFI/nixos/${kernelName}" | grep 'file format pei-' >/dev/null
      grep -Fx 'default ${entryName}' "$out/loader/loader.conf"
      grep -Fx 'linux /EFI/nixos/${kernelName}' "$out/loader/entries/${entryName}"
      grep -Fx 'initrd /EFI/nixos/${initrdName}' "$out/loader/entries/${entryName}"
      grep -Fx ${lib.escapeShellArg "options ${kernelParamsText}"} "$out/loader/entries/${entryName}"
      grep -Fx 'type1' "$out/loader/entries.srel"
    '';
in
assert lib.assertMsg (safeToken name) "mkSystemdBootArtifact: name must be a safe token";
assert lib.assertMsg (lib.elem deviceClass [ "nixarch" "nixnas" "nixvps" ])
  "mkSystemdBootArtifact: deviceClass must be nixarch, nixnas, or nixvps";
assert lib.assertMsg (lib.elem role [ "primary" "nixrescue" ])
  "mkSystemdBootArtifact: role must be primary or nixrescue";
assert lib.assertMsg (lib.elem steadyStateHandoff [ "removable" "write" ])
  "mkSystemdBootArtifact: steadyStateHandoff must be removable or write";
assert lib.assertMsg (safeToken entryId) "mkSystemdBootArtifact: entryId must be a safe token";
assert lib.assertMsg (safeToken sortKey) "mkSystemdBootArtifact: sortKey must be a safe token";
assert lib.assertMsg (oneLine title && title != "") "mkSystemdBootArtifact: title must be one non-empty line";
assert lib.assertMsg (oneLine version && version != "") "mkSystemdBootArtifact: version must be one non-empty line";
assert lib.assertMsg (lib.all parameterIsSafe kernelParams)
  "mkSystemdBootArtifact: kernelParams must be single-line values and must not supply init=; nixboot owns the exact toplevel init path";
assert lib.assertMsg (timeout == null || (builtins.isInt timeout && timeout >= 0))
  "mkSystemdBootArtifact: timeout must be null or an unsigned integer";
assert lib.assertMsg (consoleMode == null || lib.elem consoleMode [ "0" "1" "2" "auto" "max" "keep" ])
  "mkSystemdBootArtifact: unsupported systemd-boot console mode";
assert lib.assertMsg (efiArch != null && safeToken efiArch)
  "mkSystemdBootArtifact: the target platform must expose a safe UEFI architecture name";
{
  tree = artifact;
  manifest = artifact.manifest;
}
