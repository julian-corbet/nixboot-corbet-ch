{ pkgs
, mkUki
, mkUkiSigningRequest
, mkUkiSigner
, mkSignedUkiVerifier
}:
let
  fakeToplevel = pkgs.runCommand "nixboot-uki-signing-toplevel" { } ''
    mkdir -p "$out/etc"
    install -m0444 ${pkgs.systemd}/lib/systemd/boot/efi/systemd-bootx64.efi "$out/kernel"
    printf 'synthetic initrd\n' > "$out/initrd"
    printf 'console=ttyS0,115200n8\n' > "$out/kernel-params"
    printf 'NAME=nixrescue\nID=nixrescue\n' > "$out/etc/os-release"
    printf '#!/bin/sh\nexit 0\n' > "$out/init"
    chmod 0555 "$out/init"
  '';
  unsignedUki = mkUki {
    inherit pkgs;
    name = "generic-nixrescue";
    toplevel = fakeToplevel;
  };
  request = mkUkiSigningRequest {
    inherit pkgs unsignedUki;
    name = "generic-nixrescue";
    deviceClass = "nixnas";
    role = "nixrescue";
    version = "release-1";
  };
  signer = mkUkiSigner { inherit pkgs; };
  verifier = mkSignedUkiVerifier { inherit pkgs; };
  pki = pkgs.runCommand "nixboot-synthetic-secure-boot-pki"
    { nativeBuildInputs = [ pkgs.openssl ]; }
    ''
      mkdir -p "$out/expected" "$out/wrong"
      openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 \
        -subj /CN=nixboot-synthetic-expected/ \
        -keyout "$out/expected/db.key" -out "$out/expected/db.pem" >/dev/null 2>&1
      openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 \
        -subj /CN=nixboot-synthetic-wrong/ \
        -keyout "$out/wrong/db.key" -out "$out/wrong/db.pem" >/dev/null 2>&1
    '';
in
pkgs.runCommand "nixboot-two-phase-uki-signing"
{
  nativeBuildInputs = [ signer verifier pkgs.coreutils pkgs.jq ];
}
  ''
    set -euo pipefail

    test "$(jq -r '.artifact.deviceClass' ${request}/request.json)" = nixnas
    test "$(jq -r '.artifact.role' ${request}/request.json)" = nixrescue
    test "$(jq -r '.source.file' ${request}/request.json)" = unsigned.efi

    nixboot-sign-uki ${request} ${pki}/expected/db.key ${pki}/expected/db.pem "$PWD/signed"
    nixboot-verify-signed-uki ${request} "$PWD/signed" ${pki}/expected/db.pem

    if nixboot-verify-signed-uki ${request} "$PWD/signed" ${pki}/wrong/db.pem \
      >"$PWD/out" 2>"$PWD/err"; then
      echo "nixboot accepted a UKI under the wrong firmware db certificate" >&2
      exit 1
    fi
    grep -F "different db certificate" "$PWD/err" >/dev/null

    cp -a "$PWD/signed" "$PWD/tampered"
    chmod u+w "$PWD/tampered/signed.efi"
    printf x >> "$PWD/tampered/signed.efi"
    if nixboot-verify-signed-uki ${request} "$PWD/tampered" ${pki}/expected/db.pem \
      >"$PWD/out" 2>"$PWD/err"; then
      echo "nixboot accepted a signed UKI whose bytes changed after signing" >&2
      exit 1
    fi
    grep -F "digest differs" "$PWD/err" >/dev/null

    touch "$out"
  ''
