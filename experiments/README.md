# Experiments

Runnable experiments with recorded results. Each experiment gets its own
directory with a README stating hypothesis, method, and outcome.
Cross-linked from [`studies/`](../studies/README.md) where a study motivated
it.

The first disposable-VM experiments are now permanent checks:

- `checks/tpm-ssh-credential.nix` boots a real swtpm guest, creates and
  decrypts the SSH identity credential, proves an unchanged PCR preserves
  its exact bytes, extends PCR 7, proves the old credential fails closed, and
  verifies one controlled reseal restores the remote identity. It never
  creates or changes a LUKS keyslot.
- `checks/secure-boot-uki.nix` starts OVMF in Setup Mode, signs a common
  nixrescue UKI under a synthetic per-device db key outside the Nix store,
  independently verifies it, enrolls only the disposable guest, reboots, and
  proves both Secure Boot user mode and execution of that exact UKI.

Remaining candidates, in order the contract in [CONTRACT.md](../CONTRACT.md)
suggests them:

- Additional `pkgs.testers.nixosTest` coverage for the automatable behaviors
  listed in CONTRACT.md's "Which behaviors become automated tests" section
  (B1–B5, B7, B9, B10, B12, B13, B14, B16). The stateful Secure Boot and TPM
  boundaries are covered now; remaining candidates concern other activation,
  retention, and failure transitions.
- A real-hardware trial of `secureBoot.opromPolicy` values against a board
  with an add-in card whose option ROM matters, to confirm `"none"` actually
  fails POST the way `modules/nixboot.nix:283-289` predicts, rather than
  assuming it from the sbctl documentation alone.
