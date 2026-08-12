# Interactive custody tools for a passphrase-encrypted Secure Boot PKI archive.
# The ciphertext may be public; decryption is deliberately unsuitable for an
# unattended build because the passphrase is read by age from the terminal.
{ pkgs }:
let
  signer = import ./mk-uki-signer.nix { inherit pkgs; };
  encrypt = pkgs.writeShellApplication {
    name = "nixboot-encrypt-pki";
    runtimeInputs = [ pkgs.age pkgs.coreutils pkgs.findutils pkgs.gnutar pkgs.util-linux ];
    text = ''
      set -euo pipefail
      umask 077

      if [ "$#" -ne 2 ]; then
        echo "usage: nixboot-encrypt-pki PKI-DIRECTORY OUTPUT.tar.age" >&2
        exit 64
      fi

      source_dir="$1"
      output="$2"
      [ -d "$source_dir" ] || { echo "nixboot: PKI directory is absent: $source_dir" >&2; exit 1; }
      [ ! -e "$output" ] || { echo "nixboot: encrypted archive already exists; refusing to replace it: $output" >&2; exit 1; }
      if find "$source_dir" -type l -print -quit | grep . >/dev/null; then
        echo "nixboot: PKI directory contains a symlink; refusing an ambiguous archive" >&2
        exit 1
      fi
      for relative in keys/PK/PK.key keys/KEK/KEK.key keys/db/db.key keys/db/db.pem; do
        [ -f "$source_dir/$relative" ] || {
          echo "nixboot: PKI directory lacks required file: $relative" >&2
          exit 1
        }
      done

      output_parent="$(dirname "$output")"
      mkdir -p "$output_parent"
      temporary="$(mktemp -p "$output_parent" .nixboot-pki.XXXXXX.tar.age)"
      cleanup() {
        shred -u "$temporary" 2>/dev/null || true
      }
      trap cleanup EXIT

      # age passphrase mode asks interactively. No environment-variable or
      # file-based passphrase path is offered, so CI cannot silently become
      # the key escrow.
      echo "nixboot: enter the SAME master passphrase used for disk encryption; this is not a second password" >&2
      tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
        -C "$source_dir" -cf - . \
        | age --passphrase --output "$temporary"
      chmod 0600 "$temporary"
      sync -f "$temporary"
      mv "$temporary" "$output"
      trap - EXIT
      sync -f "$output_parent"
      echo "nixboot: encrypted PKI archive written to $output"
      echo "nixboot: the ciphertext is suitable for a public repository; keep an independent recovery copy too"
    '';
  };

  withPki = pkgs.writeShellApplication {
    name = "nixboot-with-pki";
    runtimeInputs = [ pkgs.age pkgs.coreutils pkgs.findutils pkgs.gnutar pkgs.util-linux ];
    text = ''
      set -euo pipefail
      umask 077

      if [ "$#" -lt 3 ] || [ "$2" != -- ]; then
        echo "usage: nixboot-with-pki ARCHIVE.tar.age -- COMMAND [ARGUMENT ...]" >&2
        exit 64
      fi

      archive="$1"
      shift 2
      [ -f "$archive" ] || { echo "nixboot: encrypted PKI archive is absent: $archive" >&2; exit 1; }

      uid="$(id -u)"
      if [ -n "''${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
        runtime_root="$XDG_RUNTIME_DIR"
      elif [ -d "/run/user/$uid" ]; then
        runtime_root="/run/user/$uid"
      else
        runtime_root=/run
      fi
      [ "$(findmnt -no FSTYPE --target "$runtime_root")" = tmpfs ] || {
        echo "nixboot: runtime directory is not tmpfs; refusing to write plaintext PKI bytes there: $runtime_root" >&2
        exit 1
      }

      work="$(mktemp -d -p "$runtime_root" nixboot-pki.XXXXXX)"
      cleanup() {
        find "$work" -type f -exec shred -u {} \; 2>/dev/null || true
        find "$work" -depth -type d -empty -delete 2>/dev/null || true
      }
      trap cleanup EXIT

      echo "nixboot: enter the SAME master passphrase used for disk encryption; this is not a second password" >&2
      age --decrypt "$archive" \
        | tar --extract --file=- --directory="$work" --no-same-owner --no-same-permissions
      if find "$work" -type l -print -quit | grep . >/dev/null; then
        echo "nixboot: decrypted PKI archive contains a symlink; refusing it" >&2
        exit 1
      fi
      for relative in keys/PK/PK.key keys/KEK/KEK.key keys/db/db.key keys/db/db.pem; do
        [ -f "$work/$relative" ] || {
          echo "nixboot: decrypted PKI archive lacks required file: $relative" >&2
          exit 1
        }
      done

      export NIXBOOT_PKI_DIR="$work"
      "$@"
    '';
  };

  signWithPki = pkgs.writeShellApplication {
    name = "nixboot-sign-uki-with-pki";
    runtimeInputs = [ pkgs.bash withPki signer ];
    text = ''
      set -euo pipefail

      if [ "$#" -ne 3 ]; then
        echo "usage: nixboot-sign-uki-with-pki ARCHIVE.tar.age REQUEST-DIRECTORY OUTPUT-DIRECTORY" >&2
        exit 64
      fi

      archive="$1"
      request="$2"
      output="$3"
      # Expanded by the inner shell after nixboot-with-pki exports the
      # temporary location, not by this wrapper.
      # shellcheck disable=SC2016
      nixboot-with-pki "$archive" -- bash -c '
        exec nixboot-sign-uki "$1" \
          "$NIXBOOT_PKI_DIR/keys/db/db.key" \
          "$NIXBOOT_PKI_DIR/keys/db/db.pem" \
          "$2"
      ' nixboot-sign-uki-with-pki "$request" "$output"
    '';
  };
in
pkgs.symlinkJoin {
  name = "nixboot-pki-archive-tools";
  paths = [ encrypt withPki signWithPki ];
}
