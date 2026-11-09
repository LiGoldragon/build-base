{
  description = "The build base: one nixpkgs, one Rust toolchain and one set of crate overrides for every repository, so a crate at one version and feature set has one hash everywhere.";

  inputs = {
    nixpkgs.url = "github:LiGoldragon/nixpkgs";
    fenix.url = "github:nix-community/fenix";
    fenix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, nixpkgs, fenix }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];

      # Everything a repository builds with on one system.
      context =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          toolchain = fenix.packages.${system}.stable.withComponents [
            "cargo"
            "rustc"
            "rustfmt"
            "clippy"
            "rust-src"
          ];
        in
        {
          inherit pkgs toolchain;
          # Native inputs a crate needs to build. Extend here, never in a
          # repository, so every repository hashes the crate the same.
          crateOverrides = pkgs.defaultCrateOverrides;
          # The one crate2nix every repository generates its Cargo.nix with.
          crate2nix = pkgs.crate2nix;
          buildRustCrateForPkgs =
            p:
            p.buildRustCrate.override {
              rustc = toolchain;
              cargo = toolchain;
            };
        };

      contexts = lib.genAttrs systems context;
      forSystems = function: lib.genAttrs systems (system: function contexts.${system});
    in
    {
      lib = {
        inherit systems contexts forSystems;
        # A repository's whole flake output for a Cargo workspace:
        #   outputs = { base, ... }: base.lib.workspaceOutputs { cargoNix = ./Cargo.nix; };
        workspaceOutputs =
          arguments:
          let
            workspaces = forSystems (context: import ./workspace.nix context arguments);
          in
          {
            packages = lib.mapAttrs (_: workspace: workspace.packages) workspaces;
            checks = lib.mapAttrs (_: workspace: workspace.checks) workspaces;
            devShells = lib.mapAttrs (_: workspace: { default = workspace.devShell; }) workspaces;
          };
      };

      packages = lib.genAttrs systems (system: {
        toolchain = contexts.${system}.toolchain;
        crate2nix = contexts.${system}.crate2nix;
      });
    };
}
