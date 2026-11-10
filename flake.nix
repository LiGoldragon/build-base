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
            # crate2nix 0.15.0, which reads a git crate's hash under its own
            # revision alone (crate2nix-git-hash-by-rev.patch).
            crate2nix = pkgs.crate2nix.overrideAttrs (old: {
              patches = (old.patches or [ ]) ++ [ ./crate2nix-git-hash-by-rev.patch ];
            });
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

      # The base's own checks.
      checks = lib.genAttrs systems (system: {
        crate2nix-git-hash = import ./crate2nix-git-hash.nix contexts.${system};
        crate-version-set-one-revision = import ./crate-version-set-test.nix contexts.${system} {
          generator = self.packages.${system}.crate-version-set;
        };
        crate-features-named-sets = import ./crate-features-test.nix contexts.${system};
        crate-default-features = import ./crate-default-features-test.nix contexts.${system};
      });

      packages = lib.genAttrs systems (
        system:
        let
          pkgs = contexts.${system}.pkgs;
        in
        {
          toolchain = contexts.${system}.toolchain;
          crate2nix = contexts.${system}.crate2nix;
          # Writes crate-versions.json from the active repositories' locks,
          # the registry crates and the git crates they take, one revision per
          # git crate version, or names the registry and git crates they
          # misalign on, with each version and revision and the repositories:
          #   nix run github:LiGoldragon/build-base#crate-version-set -- <Cargo.lock ...>
          crate-version-set = pkgs.writers.writePython3Bin "crate-version-set" {
            flakeIgnore = [ "E501" ];
          } (builtins.readFile ./crate-version-set.py);
          # Writes crate-features.json, one feature set per registry crate
          # version and per git crate version, from what the active
          # repositories' Cargo.nix resolve, keeping each crate's named sets,
          # written by hand:
          #   nix run github:LiGoldragon/build-base#crate-feature-set -- <repository>/Cargo.nix ...
          crate-feature-set =
            pkgs.writers.writePython3Bin "crate-feature-set" { flakeIgnore = [ "E501" ]; }
              (
                builtins.replaceStrings [ "@resolver@" "@nixpkgs@" "@system@" ] [
                  "${self}/resolved-features.nix"
                  "${pkgs.path}"
                  system
                ] (builtins.readFile ./crate-feature-set.py)
              );
        }
      );
    };
}
