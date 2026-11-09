# What a Cargo.nix resolves for each third-party crate: the features
# crate2nix gives it when every workspace member is built with every one of
# its features and its dev-dependencies, the widest build the workspace can
# ask for, as `cargo test --workspace --all-features` resolves it.
#
# A third-party crate is a crate from a registry, one with no src of its
# own in Cargo.nix. Each is given by name and version:
#   built         whether any member's build on this platform reaches it;
#   features      the features crate2nix resolves for it, as buildRustCrate
#                 receives them, the names of optional dependencies they
#                 attach among them;
#   featureMap    its [features] table;
#   dependencies  each crate this Cargo.nix locks for it: the name it is
#                 depended on under, whether optional, the crate's name and
#                 version, the features the dependency asks of it, and
#                 whether it applies to this platform.
# Read by the feature set's generator and by its check.
{ pkgs, generated }:
let
  lib = pkgs.lib;
  internal = generated.internal;
  crates = internal.crates;
  target = internal.makeDefaultTarget pkgs.stdenv.hostPlatform // {
    test = true;
  };

  thirdParty = lib.filterAttrs (_: crate: !(crate ? src)) crates;

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
      requests = lib.optional (edge.usesDefaultFeatures or true) "default" ++ edge.features or [ ];
      applies = (edge.target or (_: true)) { inherit features target; };
    };
  dependencies =
    packageId: crate:
    map (dependency (resolved packageId)) ((crate.dependencies or [ ]) ++ (crate.buildDependencies or [ ]));

  entries = lib.mapAttrsToList (packageId: crate: {
    name = crate.crateName;
    inherit (crate) version;
    value = {
      built = lib.any (resolution: resolution ? ${packageId}) resolutions;
      features = resolved packageId;
      featureMap = crate.features or { };
      dependencies = dependencies packageId crate;
    };
  }) thirdParty;
in
lib.mapAttrs (_: group: lib.listToAttrs (map (entry: lib.nameValuePair entry.version entry.value) group)) (
  lib.groupBy (entry: entry.name) entries
)
