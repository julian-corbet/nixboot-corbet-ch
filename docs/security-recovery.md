# Boot Security And Recovery

This is the decision record for a host that uses nixboot to defend its
pre-OS path without making its encrypted data depend on firmware state. It
is deliberately host-neutral: public nixboot documents mechanisms and
recovery contracts; a private consumer supplies its own keys, disk layout,
and access values.

In the target architecture, nixrescue produces recovery content and runtime,
nixboot produces and verifies the boot artifact, and nixdeploy alone delivers
and selects `primary` or `nixrescue` artifacts and records rollout outcomes.
The current nixboot and nixrescue maintainer/cutover helpers predate that
split and remain documented as current behavior only, not as ownership
precedent.

## Non-Negotiable Invariants

1. **Data requires the one existing operator passphrase.** Every LUKS volume
   that recovery needs uses that same passphrase; recovery never introduces a
   second password. No data-bearing LUKS volume may have a TPM, network, or
   plaintext-keyfile auto-unlock path. A TPM reset, firmware update, missing
   network, or failed boot must never make the data unrecoverable or silently
   unlock it.
2. **A rescue system is not a data key.** A rescue entry may contain repair
   tools and its own disposable encrypted store, but it does not mount or
   unlock data pools without the same explicit operator passphrase.
3. **The passphrase is entered only after the boot path is trusted.** On a
   Secure-Boot host, firmware verifies the selected loader and the signed
   UKI before its initrd can ask for the passphrase. An unexpected boot
   screen or initrd SSH identity is a recovery event, not an occasion to
   enter the data passphrase.
4. **A TPM is never a data-recovery prerequisite.** A host may optionally
   use one for a non-data credential, such as the initrd SSH host key. That
   is a remote-channel hardening choice, not a LUKS-unlock mechanism. Its
   loss may remove that convenience for one boot; local or BMC passphrase
   recovery remains available.
5. **Recovery does not depend on one device.** The signing identity and
   LUKS-header backups have independently stored, tested recovery copies.
   A boot disk, TPM, or firmware reset may fail without becoming a data-loss
   event.

## Key Custody

Nixboot is a public repository. It contains no Secure Boot private key, SOPS
payload, recovery passphrase, host name, or recipient list.

A consumer may commit an encrypted Secure Boot PKI archive to a public or
private GitHub repository. Repository visibility is not part of the security
boundary: the archive must remain safe when an attacker has the complete
ciphertext and the public db certificate. The operator may use the same one
master passphrase already used for data encryption; nixboot does not introduce
or require a second password. Publishing the ciphertext lets anyone attempt
offline passphrase guesses, so this design is valid only when that existing
master passphrase already has enough entropy for offline attack resistance;
making the GitHub repository private is not a substitute for that property.

This repository exports `lib.mkPkiArchiveTools`, which provides:

From a checkout, `nix shell .#pki-archive-tools` puts all three commands on
`PATH`; a consumer flake may instead instantiate `lib.mkPkiArchiveTools`.

| Command | Contract |
|---|---|
| `nixboot-encrypt-pki PKI-DIRECTORY OUTPUT.tar.age` | Creates an `age --passphrase` archive interactively and refuses to overwrite an existing ciphertext. |
| `nixboot-with-pki ARCHIVE.tar.age -- COMMAND ...` | Decrypts interactively into a private tmpfs directory, exports `NIXBOOT_PKI_DIR`, runs one command, and destroys the temporary plaintext. |
| `nixboot-sign-uki-with-pki ARCHIVE.tar.age REQUEST-DIRECTORY OUTPUT-DIRECTORY` | Combines the tmpfs unlock with the two-phase signer, using the archived db key and certificate without exposing their paths to the caller. |

The archive is suitable for GitHub when all of the following are true:

- the archive is encrypted before it is committed;
- the master passphrase is entered interactively and is never committed as a
  GitHub Actions secret or written to a passphrase file;
- the plaintext exists only in controlled build or recovery environments;
- an offline copy independent of GitHub and the boot disk exists; and
- recovery from that copy is exercised before the key is treated as durable.

Plaintext private signing keys do not belong in either public or private Git
history. GitHub is a ciphertext distribution and audit mechanism, not an
unsealing authority and not the only recovery medium.

The signing flow is intentionally two-phase. `lib.mkUkiSigningRequest` builds
the common unsigned UKI plus its digest and generic class/role identity.
`lib.mkUkiSigner` consumes that request and runtime db key paths outside the
Nix store. `lib.mkSignedUkiVerifier` then proves the signed bytes still name
the exact request and verify under the intended db certificate. Thus one
generic rescue payload may receive different outer signatures for different
firmware trust roots without becoming a different package-set rescue build.

Each physical machine has its own Secure Boot identity. A laptop and a
server do not share PK/KEK/db material: revoking, recovering, or replacing
one machine must not change the other machine's trust root.

## User Stories

### Interactive Machine

As a person sitting at a laptop, I want a local passphrase prompt only after
the firmware has verified my signed boot chain. I may also use initrd SSH for
recovery, but it is supplementary: no remote service, TPM state, or network
route is required to boot and unlock the machine locally.

The normal posture is a firmware setup password, restricted external boot,
operator-controlled Secure Boot keys, `loader.program = "lanzaboote"`, and
password-only LUKS. A distinct signed rescue entry remains selectable for a
bad operating-system generation.

### Headless Machine

As an operator of a headless machine, I need initrd SSH and an out-of-band
console so I can enter the normal data passphrase when the main generation
cannot boot. The initrd SSH host key may be TPM-sealed to detect a changed
Secure Boot policy, but TPM failure must only disable that remote channel;
the BMC or local console still reaches the passphrase prompt.

### Rescue Operator

As a recovery operator, I can select a separately signed rescue UKI when a
normal generation fails. It carries repair tools but no data-pool key. I
must explicitly provide the existing operator passphrase to inspect or repair
encrypted storage. A rescue system's own store uses that same passphrase when
it needs one; it never adds a rescue-only password or becomes a hidden path
to data.

### Firmware Maintainer

As a firmware maintainer, I can update firmware without risking data
lockout. A routine update that preserves Secure Boot variables boots
normally. If a TPM resets, only an optional TPM-sealed initrd SSH identity
needs resealing after local or BMC recovery. If firmware loses the Secure
Boot policy, I restore the operator key set from independent recovery media,
re-enable Secure Boot, and only then enter a data passphrase.

## Evil-Maid Boundary

Disk encryption alone does not stop an attacker from replacing a bootloader
or initrd with a fake passphrase prompt. Secure Boot is the enforcement
point: firmware accepts only the loader and UKIs signed by the operator's
trusted key. Lanzaboote packages the kernel, initrd, and command line into a
signed UKI, so an attacker cannot alter one of those components independently
and keep a valid signature.

The defense depends on the firmware key policy remaining protected. A
firmware administrator password and external-boot restrictions make changing
that policy a deliberate, locally visible action. An attacker with physical
control can still deny service, reset firmware, or tamper with hardware; no
operating-system configuration can eliminate those attacks. The response is
to re-establish the trusted Secure Boot policy from recovery material before
supplying the data passphrase.

## Firmware-Update Recovery Contract

Before a firmware update, the operator verifies the active signed boot chain,
the signed rescue entry, the availability of the encrypted PKI archive, the
independent recovery copy, and LUKS-header backups. The operator retains the
data passphrase separately from all of those artefacts.

After the update:

1. If the normal signed entry boots, run `nixboot-verify` and record the
   result.
2. If only the normal generation fails, boot the signed rescue entry, repair
   the generation, and keep data locked until its passphrase is requested.
3. If an optional TPM-sealed initrd SSH identity cannot unseal, use the local
   or BMC passphrase path. Re-seal the SSH identity after the trusted system
   is running; do not change any data LUKS keyslot.
4. If the Secure Boot key policy is gone or disabled, do not enter the data
   passphrase. Restore the operator key policy from recovery media, verify
   it in firmware, then boot the signed system or rescue entry.

This contract deliberately favours an explicit recovery step over a
convenient path that could turn a firmware update or physical attack into a
data-recovery failure.
