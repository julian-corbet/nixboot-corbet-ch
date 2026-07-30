{
  description = "nixboot - one declarative boot stance per host: firmware handoff through to switch-root";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      nixosModules = {
        # Two files, one option namespace: modules/extra-entries.nix adds
        # nixboot.extraEntries.* alongside modules/nixboot.nix's own option
        # tree, the same "reads options it does not declare" composition
        # this module already uses for boot.lanzaboote.* (see the "ONE
        # EXTERNAL DEPENDENCY" note in modules/nixboot.nix) -- here between
        # two files of the SAME flake rather than across flakes, so both are
        # always composed together.
        nixboot = {
          imports = [ ./modules/nixboot.nix ./modules/extra-entries.nix ];
        };
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
      # `loader.program = "limine"` needs NO such composition -- limine ships
      # inside nixpkgs itself, see the same header note.

      # system-manager plane (Arch/CachyOS hosts): a deliberately narrow
      # `nixboot.limine.*` tree, NOT a reuse of the NixOS module's `nixboot.loader.*` -- see
      # modules/system-manager-limine.nix's own header for exactly why the rest of the NixOS
      # boot stance (remoteUnlock, secureBoot, generations.keep, extraEntries, ...) has no
      # counterpart here at all. Same "carve out only the sound half" shape as nixpower's own
      # systemManagerModules (nixpower/modules/system-manager.nix).
      systemManagerModules = {
        nixboot = ./modules/system-manager-limine.nix;
        default = self.systemManagerModules.nixboot;
      };

      lib = { };

      # EVAL-TIME tests only -- no VM, no lanzaboote input (every fixture
      # below deliberately stays on loader.program = "systemd-boot" / "none"
      # so this flake's own `nix flake check` never needs the external
      # lanzaboote module at all; limine fixtures need no such fixture at all,
      # since limine ships inside nixpkgs -- see checks/default.nix's own
      # header). See checks/default.nix's own header, and checks/system-
      # manager.nix for the separate `lib.evalModules` stub-eval suite
      # covering modules/system-manager-limine.nix (the same technique
      # nixarch's own checks/default.nix uses for its system-manager
      # modules, since no real system-manager flake input is worth pulling
      # in just to prove an option surface renders correctly).
      checks = forAllSystems (system:
        (import ./checks {
          pkgs = pkgsFor system;
          inherit nixpkgs system;
          nixbootModule = self.nixosModules.nixboot;
        })
        // (import ./checks/system-manager.nix {
          pkgs = pkgsFor system;
        })
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
