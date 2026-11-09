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
          built = {
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
        in
        built
        // {
          # The check that a committed Cargo.nix is what this crate2nix
          # generates from its Cargo workspace (cargo-nix.nix), for a Cargo.nix
          # kept apart from the workspace it was generated from:
          #   cargoNixCheck { source = <workspace>; cargoNix = ./Cargo.nix;
          #                   crateHashes = ./crate-hashes.json; }
          cargoNixCheck = import ./cargo-nix.nix built;
        };

      contexts = lib.genAttrs systems context;
      forSystems = function: lib.genAttrs systems (system: function contexts.${system});
      # One system's workspace: { packages; tests; checks; devShell; }.
      workspace = lib.genAttrs systems (system: import ./workspace.nix contexts.${system});
    in
    {
      lib = {
        inherit systems contexts forSystems workspace;
        # A repository's whole flake output for a Cargo workspace:
        #   outputs = { base, ... }: base.lib.workspaceOutputs { cargoNix = ./Cargo.nix; };
        # with its own member checks and its own further checks, which join
        # checks.default:
        #   base.lib.workspaceOutputs {
        #     cargoNix = ./Cargo.nix;
        #     memberChecks = { pkgs, tests, check, ... }: {
        #       some-member = check "some-member" [ "default" "a-feature" ];
        #       untested-member = null;
        #     };
        #     extraChecks = { pkgs, toolchain, workspace, tests, doc, clippy, ... }: {
        #       fmt = ...;
        #       doc = doc "some-member" [ "default" ] [ "-D" "warnings" ];
        #       clippy = clippy "some-member" [ "default" ] [ "-D" "warnings" ];
        #     };
        #   };
        # A flake that composes its own outputs takes one system's workspace,
        # test builds included, from lib.workspace.<system> with the same
        # arguments.
        workspaceOutputs =
          arguments:
          let
            workspaces = lib.mapAttrs (_: forSystem: forSystem arguments) workspace;
          in
          {
            packages = lib.mapAttrs (_: workspace: workspace.packages) workspaces;
            checks = lib.mapAttrs (_: workspace: workspace.checks) workspaces;
            devShells = lib.mapAttrs (_: workspace: { default = workspace.devShell; }) workspaces;
          };
      };

      packages = lib.genAttrs systems (
        system:
        let
          pkgs = contexts.${system}.pkgs;
        in
        {
          toolchain = contexts.${system}.toolchain;
          crate2nix = contexts.${system}.crate2nix;
          # Writes third-party-versions.json from the active repositories'
          # aligned locks, or names the crates they misalign on:
          #   nix run github:LiGoldragon/build-base#third-party-version-set -- <Cargo.lock ...>
          third-party-version-set = pkgs.writers.writePython3Bin "third-party-version-set" {
            flakeIgnore = [ "E501" ];
          } (builtins.readFile ./third-party-version-set.py);
          # Writes third-party-features.json, one feature set per third-party
          # crate, from what the active repositories' Cargo.nix resolve:
          #   nix run github:LiGoldragon/build-base#third-party-feature-set -- <repository>/Cargo.nix ...
          third-party-feature-set =
            pkgs.writers.writePython3Bin "third-party-feature-set" { flakeIgnore = [ "E501" ]; }
              (
                builtins.replaceStrings [ "@resolver@" "@nixpkgs@" "@system@" ] [
                  "${./resolved-features.nix}"
                  "${pkgs.path}"
                  system
                ] (builtins.readFile ./third-party-feature-set.py)
              );
        }
      );
    };
}
