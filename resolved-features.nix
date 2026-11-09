# What a Cargo.nix resolves for each crate the base's sets cover: the
# features crate2nix gives it when every workspace member is built with every
# one of its features and its dev-dependencies, the widest build the workspace
# can ask for, as `cargo test --workspace --all-features` resolves it.
#
# A crate the sets cover is a registry crate or a git crate (crate-identity.nix);
# a workspace member is not. The result is a list with one element per crate:
#   name, version   the crate;
#   revision        the full git commit of a git crate, null for a registry crate;
#   built           whether any member's build on this platform reaches it;
#   features        the features crate2nix resolves for it, as buildRustCrate
#                   receives them, the names of optional dependencies they
#                   attach among them;
#   featureMap      its [features] table;
#   dependencies    each crate this Cargo.nix locks for it: the name it is
#                   depended on under, whether optional, the crate's name,
#                   version and revision, the features the dependency asks of
#                   it, and whether it applies to this platform.
# Read by the feature set's generator and by its check.
{ pkgs, generated }:
let
  lib = pkgs.lib;
  identity = import ./crate-identity.nix { inherit lib; };
  internal = generated.internal;
  crates = internal.crates;
  target = internal.makeDefaultTarget pkgs.stdenv.hostPlatform // {
    test = true;
  };

  held = lib.filterAttrs (_: identity.held) crates;

  everyFeature = packageId: [ "default" ] ++ lib.attrNames (crates.${packageId}.features or { });
  resolutions = map (
    member:
    internal.mergePackageFeatures {
      packageId = member.packageId;
      features = everyFeature member.packageId;
      inherit target;
      runTests = true;
    }
  ) (lib.attrValues generated.workspaceMembers);
  resolved = packageId: lib.unique (lib.sort lib.lessThan (lib.concatMap (resolution: resolution.${packageId} or [ ]) resolutions));

  dependency =
    features: edge:
    let
      depended = crates.${edge.packageId};
    in
    {
      name = edge.rename or edge.name;
      optional = edge.optional or false;
      crate = depended.crateName;
      inherit (depended) version;
      revision = identity.revision depended;
      requests = lib.optional (edge.usesDefaultFeatures or true) "default" ++ edge.features or [ ];
      applies = (edge.target or (_: true)) { inherit features target; };
    };
  dependencies =
    packageId: crate:
    map (dependency (resolved packageId)) ((crate.dependencies or [ ]) ++ (crate.buildDependencies or [ ]));
in
lib.mapAttrsToList (packageId: crate: {
  name = crate.crateName;
  inherit (crate) version;
  revision = identity.revision crate;
  built = lib.any (resolution: resolution ? ${packageId}) resolutions;
  features = resolved packageId;
  featureMap = crate.features or { };
  dependencies = dependencies packageId crate;
}) held
