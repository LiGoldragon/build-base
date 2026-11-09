# Every crate the base's sets cover built with its feature set from the base
# (crate-features.json), so it has one build in every repository.
#
# A crate the set holds (a registry crate, by name and version, or a git
# crate, by name and version; a workspace member is neither) has one union or
# named sets (crate-identity.nix). A build takes one set name, the first, in
# the set's order, whose sets hold what the build resolves for every crate
# with named sets (`nameOf`); under that name each such crate is built with
# its set of the name and every other crate with its union. `under name` is
# the function that builds one crate under a name: it builds each crate the
# set holds whole, with its features under the name, the optional
# dependencies those features attach, and every crate beneath it under the
# same name, whatever the build that reaches it resolves. A crate the set
# lacks, or whose resolution in this build asks a feature its features under
# the name do not hold (a set not yet regenerated for this workspace), is
# built as the build resolves it, over dependencies built from the set. The
# Cargo.nix is imported with that function:
#   generated = import cargoNix { buildRustCrateForPkgs = (crate-builds { inherit generated; buildRustCrateForPkgs = …; }).under name; };
context:
{ generated, buildRustCrateForPkgs }:
let
  inherit (context) pkgs;
  lib = pkgs.lib;

  set = lib.importJSON ./crate-features.json;
  identity = import ./crate-identity.nix { inherit lib; };

  internal = generated.internal;
  crates = internal.crates;
  names = identity.setNames set;

  packageIds = lib.listToAttrs (
    lib.mapAttrsToList (packageId: crate: lib.nameValuePair (identity.key crate) packageId) (
      lib.filterAttrs (_: crate: identity.entry set crate != null) crates
    )
  );

  # One build per crate the set holds under one name, whichever build reaches it.
  builds =
    name:
    let
      setOf = identity.setIn set name;

      # The crates, each asking of every crate it depends on that the set holds
      # that crate's features under the name besides what it asks itself, so a
      # resolution from any such crate gives each one beneath it its features.
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

      fromSet = lib.mapAttrs (
        _: packageId:
        (internal.builtRustCratesWithFeatures {
          inherit packageId crateConfigs;
          features = (setOf crates.${packageId}).features;
          buildRustCrateForPkgsFunc = buildRustCrateForPkgs;
          runTests = false;
        }).crates.${packageId}
      ) (lib.filterAttrs (_: packageId: setOf crates.${packageId} != null) packageIds);
    in
    p:
    let
      # buildRustCrate as it is called, and overridden, by the Cargo.nix.
      through = build: {
        __functor =
          _: attributes:
          let
            key = identity.key attributes;
          in
          if
            key != null
            && fromSet ? ${key}
            && lib.all (feature: lib.elem feature (setOf crates.${packageIds.${key}}).features) attributes.features
          then
            fromSet.${key}
          else
            build attributes;
        override = arguments: through (build.override arguments);
      };
    in
    through (buildRustCrateForPkgs p);

  memo = lib.listToAttrs (map (name: lib.nameValuePair (toString name) (builds name)) names);
in
{
  inherit names;

  # The function building one crate under the set name `name`.
  under = name: memo.${toString name};

  # The name a build takes: the build of `packageId` with `features`, with
  # its dev-dependencies where `runTests`, takes the first name whose sets
  # hold what it resolves for every crate with named sets; the first name
  # where none does, the check refusing such a workspace.
  nameOf =
    {
      packageId,
      features,
      runTests,
    }:
    let
      resolution = internal.mergePackageFeatures {
        inherit packageId features runTests;
        target = internal.makeDefaultTarget pkgs.stdenv.hostPlatform // {
          test = runTests;
        };
      };
      named = lib.filter (resolved: identity.named set crates.${resolved}) (lib.attrNames resolution);
      holds =
        name:
        lib.all (
          resolved:
          let
            given = identity.setIn set name crates.${resolved};
          in
          given != null && lib.all (feature: lib.elem feature given.features) resolution.${resolved}
        ) named;
    in
    lib.findFirst holds (lib.head names) names;
}
