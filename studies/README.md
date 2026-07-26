# Studies

Written investigations that motivate design decisions — comparisons, failed
approaches, upstream research. Cross-linked from
[`experiments/`](../experiments/README.md) where a study led to a runnable
experiment.

No studies have been written yet. The material that would seed the first
one already exists as evidence inside the module itself rather than as a
separate document — see the SCOPE block and the "ONE EXTERNAL DEPENDENCY"
note in [`modules/nixboot.nix`](../modules/nixboot.nix#L17-L73) for why
kernel packaging, disk-layout identity, and power policy were each ruled out
as part of this module's domain, and why lanzaboote is a required
composition rather than a dependency this flake pulls in itself. A written
study belongs here once that reasoning needs to be argued from prior art
(other distros' boot-arbitration modules, other lanzaboote consumers) rather
than restated from the module's own comments.
