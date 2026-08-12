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
, kernelParamFiles ? [ ]
}:

pkgs.runCommand "${name}.efi"
{
  nativeBuildInputs = [ pkgs.systemdUkify ];
}
  ''
    set -euo pipefail

    cmdline="init=${toplevel}/init $(cat ${toplevel}/kernel-params)"
    parameter_files=(${pkgs.lib.concatMapStringsSep " " pkgs.lib.escapeShellArg kernelParamFiles})
    for parameter_file in "''${parameter_files[@]}"; do
      [ -r "$parameter_file" ] || {
        echo "nixboot.mkUki: kernel parameter file is unreadable: $parameter_file" >&2
        exit 1
      }
      cmdline="$cmdline $(tr '\r\n' '  ' < "$parameter_file")"
    done

    ukify build \
      --linux="${toplevel}/kernel" \
      --initrd="${toplevel}/initrd" \
      --cmdline="$cmdline" \
      --os-release="@${osRelease}" \
      --output="$out"

    test "$(head -c2 "$out")" = MZ
  ''
