# Build a host-side maintainer for the systemd-stub global credential consumed by initrd and
# nixrescue sshd. It contains no host identity at build time: the successful, passphrase-unlocked
# host generates an Ed25519 key and seals it to its own TPM/PCR state at runtime.
{ pkgs
, name ? "host"
, espMountPoint ? "/boot"
, credentialName ? "nixboot-initrd-hostkey"
, pcrs ? [ 7 ]
, tpm2Device ? "auto"
}:

assert builtins.match "[A-Za-z0-9._-]+" name != null;
assert builtins.match "[A-Za-z0-9._-]+" credentialName != null;
assert pcrs != [ ];

let
  inherit (pkgs) lib;
  pcrsArg = lib.concatMapStringsSep "," toString pcrs;
in
pkgs.writeShellApplication {
  name = "nixboot-seal-${name}-ssh-credential";
  runtimeInputs = [ pkgs.coreutils pkgs.diffutils pkgs.openssh pkgs.systemd ];
  text = ''
    set -euo pipefail
    umask 077

    credential_name=${lib.escapeShellArg credentialName}
    tpm_device=${lib.escapeShellArg tpm2Device}
    esp=${lib.escapeShellArg espMountPoint}
    credential_dir="$esp/loader/credentials"
    credential="$credential_dir/$credential_name.cred"
    public_key="$credential_dir/$credential_name.pub"

    tmpdir=$(mktemp -d -p /run nixboot-ssh-credential.XXXXXX)
    cleanup() {
      find "$tmpdir" -type f -exec shred -u {} \; 2>/dev/null || true
      rmdir "$tmpdir" 2>/dev/null || true
    }
    trap cleanup EXIT

    # Existence is not enough: PCR changes make an old blob undecryptable. One real self-test per
    # boot either proves the credential or triggers one controlled reseal; there is no retry loop.
    if [ -f "$credential" ] \
      && systemd-creds decrypt --tpm2-device="$tpm_device" --name="$credential_name" \
        "$credential" "$tmpdir/current" >/dev/null 2>&1; then
      ssh-keygen -y -f "$tmpdir/current" > "$tmpdir/current.pub"
      if [ ! -f "$public_key" ] \
        || ! cmp -s "$tmpdir/current.pub" "$public_key"; then
        install -m0644 "$tmpdir/current.pub" "$public_key"
      fi
      echo "nixboot: TPM-sealed SSH credential matches the current PCR state"
      ssh-keygen -lf "$public_key"
      exit 0
    fi

    # Generate a new per-device identity only after the encrypted host has booted successfully.
    # Write the replacement beside the live credential and rename it only after encryption and
    # fsync succeed, so a TPM failure cannot destroy the last valid blob.
    ssh-keygen -t ed25519 -N "" -C "$credential_name" -f "$tmpdir/key" -q
    mkdir -p "$credential_dir"
    new_credential="$credential_dir/.$credential_name.cred.new"
    rm -f "$new_credential"
    systemd-creds encrypt \
      --with-key=auto-initrd \
      --tpm2-device="$tpm_device" \
      --tpm2-pcrs=${lib.escapeShellArg pcrsArg} \
      --name="$credential_name" \
      "$tmpdir/key" "$new_credential"
    chmod 0600 "$new_credential"
    sync -f "$new_credential"
    mv -f "$new_credential" "$credential"
    install -m0644 "$tmpdir/key.pub" "$public_key"
    sync -f "$credential_dir"

    echo "nixboot: generated a new TPM/PCR-bound SSH identity; pin this fingerprint:"
    ssh-keygen -lf "$public_key"
  '';
}
