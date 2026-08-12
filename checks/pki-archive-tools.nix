{ pkgs, mkPkiArchiveTools }:
let
  tools = mkPkiArchiveTools { inherit pkgs; };
in
pkgs.runCommand "nixboot-pki-archive-tools-contract"
{
  nativeBuildInputs = [ pkgs.gnugrep ];
}
  ''
    set -euo pipefail

    for command in nixboot-encrypt-pki nixboot-with-pki; do
      script=${tools}/bin/$command
      test -x "$script"
      grep -F 'enter the SAME master passphrase used for disk encryption; this is not a second password' \
        "$script" >/dev/null
    done

    # There is deliberately no unattended password ingress that could turn
    # public ciphertext into CI escrow.
    if grep -R -E 'AGE_PASSPHRASE|passphrase-(file|env)|--identity' ${tools}/bin; then
      echo "nixboot: PKI archive tools expose an unattended passphrase/key path" >&2
      exit 1
    fi

    touch "$out"
  ''
