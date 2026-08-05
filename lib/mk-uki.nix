# Build one self-contained UKI from a NixOS toplevel.
#
# This is deliberately a library primitive rather than a NixOS module: a
# system-manager host can build an emergency NixOS entry without pretending
# that its normal Arch kernel is a NixOS generation. The resulting EFI file
# is a Nix derivation, so a build host produces it and the receiving machine
# only installs already-built bytes onto its ESP.
{ pkgs
, name
, toplevel
, osRelease ? "${toplevel}/etc/os-release"
}:

pkgs.runCommand "${name}.efi"
{
  nativeBuildInputs = [ pkgs.systemdUkify ];
}
  ''
    set -euo pipefail

    ukify build \
      --linux="${toplevel}/kernel" \
      --initrd="${toplevel}/initrd" \
      --cmdline="init=${toplevel}/init $(cat ${toplevel}/kernel-params)" \
      --os-release="@${osRelease}" \
      --output="$out"

    test "$(head -c2 "$out")" = MZ
  ''
