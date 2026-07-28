# Experiments

Runnable experiments with recorded results. Each experiment gets its own
directory with a README stating hypothesis, method, and outcome.
Cross-linked from [`studies/`](../studies/README.md) where a study motivated
it.

No experiments have been run yet. Candidates, in order the contract in
[CONTRACT.md](../CONTRACT.md) suggests them:

- A `pkgs.testers.nixosTest` suite covering the automatable behaviors listed
  in CONTRACT.md's "Which behaviors become automated tests" section (B1–B5,
  B7, B9, B10, B12, B13, B14, B16) — real ephemeral VMs, nothing persists
  after the build, same posture as the disposable-VM experiments in the
  sibling [nixram](https://github.com/julian-corbet/nixram-corbet-ch)
  project. `checks/default.nix` already covers B13/B14/B15 at the eval/build
  level (assertions, plus a real execution of the boot-entry registrar
  against a faked `efibootmgr`) — a VM suite would additionally prove the
  placed UKI is actually discoverable/bootable under real OVMF, which no
  eval-level check can.
- A real-hardware trial of `secureBoot.opromPolicy` values against a board
  with an add-in card whose option ROM matters, to confirm `"none"` actually
  fails POST the way `modules/nixboot.nix:283-289` predicts, rather than
  assuming it from the sbctl documentation alone.
