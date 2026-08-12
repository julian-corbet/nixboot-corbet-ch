# Turn one already-built UKI into a reproducible signing request. The request
# contains no key material and is therefore safe to build and publish through
# ordinary Nix infrastructure.
{ pkgs
, name
, deviceClass
, role
, version
, unsignedUki
, efiArch ? pkgs.stdenv.hostPlatform.efiArch
}:
let
  lib = pkgs.lib;
  safeToken = value: builtins.match "^[A-Za-z0-9][A-Za-z0-9._-]*$" value != null;
  oneLine = value: builtins.match "^[^\n\r]+$" value != null;
in
assert lib.assertMsg (safeToken name) "mkUkiSigningRequest: name must be a safe token";
assert lib.assertMsg (lib.elem deviceClass [ "nixarch" "nixnas" "nixvps" ])
  "mkUkiSigningRequest: deviceClass must be nixarch, nixnas, or nixvps";
assert lib.assertMsg (lib.elem role [ "primary" "nixrescue" ])
  "mkUkiSigningRequest: role must be primary or nixrescue";
assert lib.assertMsg (oneLine version) "mkUkiSigningRequest: version must be one non-empty line";
assert lib.assertMsg (efiArch != null && safeToken efiArch)
  "mkUkiSigningRequest: the target platform must expose a safe UEFI architecture name";
pkgs.runCommand "${name}-${role}-uki-signing-request"
{
  nativeBuildInputs = [ pkgs.binutils pkgs.coreutils pkgs.jq pkgs.systemdUkify ];
}
  ''
    set -euo pipefail

    install -Dm0444 ${unsignedUki} "$out/unsigned.efi"
    test "$(head -c2 "$out/unsigned.efi")" = MZ
    objdump -f "$out/unsigned.efi" | grep 'file format pei-' >/dev/null
    ukify inspect "$out/unsigned.efi" >/dev/null

    sha256="$(sha256sum "$out/unsigned.efi" | cut -d' ' -f1)"
    jq -n \
      --arg name ${lib.escapeShellArg name} \
      --arg device_class ${lib.escapeShellArg deviceClass} \
      --arg role ${lib.escapeShellArg role} \
      --arg version ${lib.escapeShellArg version} \
      --arg architecture ${lib.escapeShellArg efiArch} \
      --arg sha256 "$sha256" \
      '{
        schemaVersion: 1,
        type: "uki-signing-request",
        artifact: {
          name: $name,
          deviceClass: $device_class,
          role: $role,
          version: $version,
          architecture: $architecture
        },
        source: {
          file: "unsigned.efi",
          sha256: $sha256
        }
      }' > "$out/request.json"
    chmod 0444 "$out/request.json"
  ''
