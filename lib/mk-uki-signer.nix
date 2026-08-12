# Runtime UKI signer. The private key and certificate are command-line paths
# supplied outside evaluation; neither can become a Nix store dependency.
{ pkgs, name ? "nixboot-sign-uki" }:
assert builtins.match "^[A-Za-z0-9][A-Za-z0-9._-]*$" name != null;
pkgs.writeShellApplication {
  inherit name;
  runtimeInputs = [
    pkgs.coreutils
    pkgs.jq
    pkgs.openssl
    pkgs.sbsigntool
    pkgs.systemdUkify
  ];
  text = ''
    set -euo pipefail
    umask 077

    if [ "$#" -ne 4 ]; then
      echo "usage: ${name} REQUEST-DIRECTORY DB-PRIVATE-KEY DB-CERTIFICATE OUTPUT-DIRECTORY" >&2
      exit 64
    fi

    request_dir="$1"
    private_key="$2"
    certificate="$3"
    output_dir="$4"
    request="$request_dir/request.json"
    unsigned="$request_dir/unsigned.efi"

    [ -f "$request" ] || { echo "nixboot: signing request manifest is absent: $request" >&2; exit 1; }
    [ -f "$unsigned" ] || { echo "nixboot: unsigned UKI is absent: $unsigned" >&2; exit 1; }
    [ -r "$private_key" ] || { echo "nixboot: Secure Boot db private key is unreadable: $private_key" >&2; exit 1; }
    [ -r "$certificate" ] || { echo "nixboot: Secure Boot db certificate is unreadable: $certificate" >&2; exit 1; }
    [ ! -e "$output_dir" ] || { echo "nixboot: output already exists; refusing to replace it: $output_dir" >&2; exit 1; }

    jq -e '
      .schemaVersion == 1 and
      .type == "uki-signing-request" and
      .source.file == "unsigned.efi" and
      (.source.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.artifact.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
      (.artifact.deviceClass == "nixarch" or .artifact.deviceClass == "nixnas" or .artifact.deviceClass == "nixvps") and
      (.artifact.role == "primary" or .artifact.role == "nixrescue") and
      (.artifact.version | type == "string" and test("^[^\\r\\n]+$")) and
      (.artifact.architecture | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
    ' "$request" >/dev/null || {
      echo "nixboot: malformed UKI signing request: $request" >&2
      exit 1
    }

    expected_source_sha="$(jq -r '.source.sha256' "$request")"
    actual_source_sha="$(sha256sum "$unsigned" | cut -d' ' -f1)"
    [ "$actual_source_sha" = "$expected_source_sha" ] || {
      echo "nixboot: unsigned UKI digest differs from its signing request" >&2
      exit 1
    }
    ukify inspect "$unsigned" >/dev/null

    output_parent="$(dirname "$output_dir")"
    mkdir -p "$output_parent"
    work="$(mktemp -d -p "$output_parent" .nixboot-signed-uki.XXXXXX)"
    cleanup() {
      find "$work" -type f -exec shred -u {} \; 2>/dev/null || true
      rmdir "$work" 2>/dev/null || true
    }
    trap cleanup EXIT

    sbsign --key "$private_key" --cert "$certificate" \
      --output "$work/signed.efi" "$unsigned"
    sbverify --cert "$certificate" "$work/signed.efi" >/dev/null
    ukify inspect "$work/signed.efi" >/dev/null

    signed_sha="$(sha256sum "$work/signed.efi" | cut -d' ' -f1)"
    certificate_fingerprint="$(openssl x509 -in "$certificate" -noout -fingerprint -sha256 \
      | sed 's/^sha256 Fingerprint=//; s/://g' | tr '[:upper:]' '[:lower:]')"
    jq -n \
      --slurpfile request "$request" \
      --arg source_sha256 "$actual_source_sha" \
      --arg signed_sha256 "$signed_sha" \
      --arg certificate_sha256 "$certificate_fingerprint" \
      '{
        schemaVersion: 1,
        type: "signed-uki",
        artifact: $request[0].artifact,
        source: {
          requestSchemaVersion: $request[0].schemaVersion,
          sha256: $source_sha256
        },
        signed: {
          file: "signed.efi",
          sha256: $signed_sha256,
          certificateSha256: $certificate_sha256
        }
      }' > "$work/signed.json"
    chmod 0444 "$work/signed.efi" "$work/signed.json"
    sync -f "$work/signed.efi"
    sync -f "$work/signed.json"
    mv "$work" "$output_dir"
    trap - EXIT
    sync -f "$output_parent"

    echo "nixboot: signed UKI written to $output_dir/signed.efi"
    echo "nixboot: db certificate SHA-256 fingerprint: $certificate_fingerprint"
  '';
}
