# Verify the complete two-phase signing result against its immutable request
# and the db certificate expected by the destination firmware policy.
{ pkgs, name ? "nixboot-verify-signed-uki" }:
assert builtins.match "^[A-Za-z0-9][A-Za-z0-9._-]*$" name != null;
pkgs.writeShellApplication {
  inherit name;
  runtimeInputs = [
    pkgs.coreutils
    pkgs.diffutils
    pkgs.jq
    pkgs.openssl
    pkgs.sbsigntool
    pkgs.systemdUkify
  ];
  text = ''
    set -euo pipefail

    if [ "$#" -ne 3 ]; then
      echo "usage: ${name} REQUEST-DIRECTORY SIGNED-DIRECTORY DB-CERTIFICATE" >&2
      exit 64
    fi

    request_dir="$1"
    signed_dir="$2"
    certificate="$3"
    request="$request_dir/request.json"
    unsigned="$request_dir/unsigned.efi"
    signed_manifest="$signed_dir/signed.json"
    signed="$signed_dir/signed.efi"

    for file in "$request" "$unsigned" "$signed_manifest" "$signed" "$certificate"; do
      [ -f "$file" ] || { echo "nixboot: signed-UKI verification input is absent: $file" >&2; exit 1; }
    done

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
    ' \
      "$request" >/dev/null || { echo "nixboot: malformed UKI signing request" >&2; exit 1; }
    jq -e '
      .schemaVersion == 1 and
      .type == "signed-uki" and
      .source.requestSchemaVersion == 1 and
      (.source.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      .signed.file == "signed.efi" and
      (.signed.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.signed.certificateSha256 | type == "string" and test("^[0-9a-f]{64}$"))
    ' \
      "$signed_manifest" >/dev/null || { echo "nixboot: malformed signed-UKI manifest" >&2; exit 1; }

    source_sha="$(sha256sum "$unsigned" | cut -d' ' -f1)"
    request_sha="$(jq -r '.source.sha256' "$request")"
    manifest_source_sha="$(jq -r '.source.sha256' "$signed_manifest")"
    [ "$source_sha" = "$request_sha" ] && [ "$source_sha" = "$manifest_source_sha" ] || {
      echo "nixboot: signed UKI does not name the exact immutable signing request" >&2
      exit 1
    }

    request_artifact="$(jq -cS '.artifact' "$request")"
    signed_artifact="$(jq -cS '.artifact' "$signed_manifest")"
    [ "$request_artifact" = "$signed_artifact" ] || {
      echo "nixboot: signed UKI changed artifact identity, class, role, version, or architecture" >&2
      exit 1
    }

    signed_sha="$(sha256sum "$signed" | cut -d' ' -f1)"
    [ "$signed_sha" = "$(jq -r '.signed.sha256' "$signed_manifest")" ] || {
      echo "nixboot: signed UKI digest differs from its manifest" >&2
      exit 1
    }
    certificate_fingerprint="$(openssl x509 -in "$certificate" -noout -fingerprint -sha256 \
      | sed 's/^sha256 Fingerprint=//; s/://g' | tr '[:upper:]' '[:lower:]')"
    [ "$certificate_fingerprint" = "$(jq -r '.signed.certificateSha256' "$signed_manifest")" ] || {
      echo "nixboot: signed UKI names a different db certificate" >&2
      exit 1
    }

    sbverify --cert "$certificate" "$signed" >/dev/null
    ukify inspect "$unsigned" >/dev/null
    ukify inspect "$signed" >/dev/null
    echo "PASS  signed UKI matches its request, manifest, and declared db certificate"
  '';
}
