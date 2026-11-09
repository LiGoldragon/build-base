# Every crate the base's sets cover built with its one feature set from the
# base (crate-features.json), so it has one build in every repository.
#
# Given an imported Cargo.nix and the function that builds one crate, returns
# that function made to build each crate the set holds (a registry crate, by
# name and version, or a git crate, by name and version; a workspace member is
# neither) whole: the crate with the set's features, the optional
# dependencies those features attach, and every crate beneath it under its own
# set, whatever the build that reaches it resolves. A crate the set lacks, or
# whose resolution in this build asks a feature the set does not hold (a set
# not yet regenerated for this workspace), is built as the build resolves it,
# over dependencies built from the set. The Cargo.nix is imported with the
# returned function:
#   generated = import cargoNix { buildRustCrateForPkgs = crate-builds { inherit generated; buildRustCrateForPkgs = …; }; };
context:
{ generated, buildRustCrateForPkgs }:
let
  inherit (context) pkgs;
  lib = pkgs.lib;

  set = lib.importJSON ./crate-features.json;
  identity = import ./crate-identity.nix { inherit lib; };

  internal = generated.internal;
  crates = internal.crates;
  setOf = identity.entry set;

  # The crates, each asking of every crate it depends on that the set holds
  # that crate's set besides what it asks itself, so a resolution from any
  # such crate gives each one beneath it its set.
  asking =
    edge:
    let
      own = setOf crates.${edge.packageId};
    in
    if own == null then edge else edge // { features = edge.features or [ ] ++ own.features; };
  edges = [
    "dependencies"
    "buildDependencies"
  ];
  crateConfigs = lib.mapAttrs (
    _: crate: crate // lib.mapAttrs (_: map asking) (lib.getAttrs (lib.filter (edge: crate ? ${edge}) edges) crate)
  ) crates;

  packageIds = lib.listToAttrs (
    lib.mapAttrsToList (packageId: crate: lib.nameValuePair (identity.key crate) packageId) (
      lib.filterAttrs (_: crate: setOf crate != null) crates
    )
  );

  # One build per crate the set holds, whichever build reaches it.
  fromSet = lib.mapAttrs (
    _: packageId:
    (internal.builtRustCratesWithFeatures {
      inherit packageId crateConfigs;
      features = (setOf crates.${packageId}).features;
      buildRustCrateForPkgsFunc = buildRustCrateForPkgs;
      runTests = false;
    }).crates.${packageId}
  ) packageIds;
in
p:
let
  # buildRustCrate as it is called, and overridden, by the Cargo.nix.
  through = build: {
    __functor =
      _: attributes:
      let
        key = identity.key attributes;
        features = (setOf crates.${packageIds.${key}}).features;
      in
      if key != null && packageIds ? ${key} && lib.all (feature: lib.elem feature features) attributes.features then
        fromSet.${key}
      else
        build attributes;
    override = arguments: through (build.override arguments);
  };
in
through (buildRustCrateForPkgs p)
