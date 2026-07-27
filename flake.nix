{
  description = "nixboot - one declarative boot stance per host: firmware handoff through to switch-root";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
    in
    {
      nixosModules = {
        nixboot = ./modules/nixboot.nix;
        default = self.nixosModules.nixboot;
      };

      # ONE EXTERNAL DEPENDENCY THIS FLAKE DOES NOT PROVIDE: consumers who set
      # nixboot.loader.program = "lanzaboote" must compose the
      # separate lanzaboote flake's own NixOS module (github:nix-community/
      # lanzaboote) into their host alongside this one -- see the "ONE
      # EXTERNAL DEPENDENCY" note at the top of modules/nixboot.nix. Not
      # listed as an input here on purpose: this module writes to
      # boot.lanzaboote.* options but never imports that module itself, so
      # nixboot stays usable on hosts that never touch lanzaboote at all.

      lib = { };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
