{ pkgs
, name
, image
, espTree
, sectorSize
, espPartitionLabel
, requiredPartitions
, imageMaterializer ? null
, allowedExtraEspFiles ? [ ]
, bootArtifactManifest ? null
, rootPathProjection ? null
,
}:
let
  verifier = import ./mk-efi-disk-image-verifier.nix {
    inherit pkgs name espTree sectorSize espPartitionLabel requiredPartitions imageMaterializer allowedExtraEspFiles bootArtifactManifest rootPathProjection;
  };
in
pkgs.runCommand "${name}-nixboot-disk-image-check"
{
  nativeBuildInputs = [ verifier ];
}
  ''
    nixboot-verify-${name}-disk-image ${pkgs.lib.escapeShellArg (toString image)}
    touch "$out"
  ''
