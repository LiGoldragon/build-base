# The check that the base's feature set (crate-features.json) can build every
# crate a workspace takes from another repository as its Cargo.nix resolves
# it, so the crate is the one build every repository on the base shares.
#
# For each such crate (a registry crate or a git crate, by name and version; a
# workspace member is neither) this Cargo.nix resolves (resolved-features.nix),
# the set holds it. A crate with a union: the union holds every feature it
# resolves, and the optional dependencies the union attaches are ones this
# Cargo.nix gives it. Crates with named sets (crate-identity.nix): each
# member's build takes the first set name whose sets hold what the member
# resolves for every such crate, a resolution no listed set holds is refused,
# naming the crate, the features and the listed sets, and the optional
# dependencies each crate's sets attach, of that name and of every name before
# it, which a narrower build of the member takes, are ones this Cargo.nix gives
# it. Anything else fails the check, naming the crate. The set is
# written by the base's generator from the active repositories' Cargo.nix, its
# named sets written by hand:
#   nix run github:LiGoldragon/build-base#crate-feature-set -- <repository>/Cargo.nix ...
# `set` and `resolved` stand in for the base's set and this Cargo.nix's
# resolution in the base's own test of the check.
context:
{
  generated ? null,
  set ? null,
  resolved ? null,
}:
let
  inherit (context) pkgs;
  lib = pkgs.lib;

  features = if set == null then lib.importJSON ./crate-features.json else set;
  crates = if resolved == null then import ./resolved-features.nix { inherit pkgs generated; } else resolved;
  names = (import ./crate-identity.nix { inherit lib; }).setNames features;

  entryOf =
    crate:
    if crate.revision == null then
      features.registry.${crate.name}.${crate.version} or null
    else
      features.git.${crate.name}.${crate.version} or null;
  label = crate: "${crate.name} ${crate.version}${lib.optionalString (crate.revision != null) " (git)"}";
  holds = given: resolution: lib.all (feature: lib.elem feature given.features) resolution;
  lacking =
    crate: given:
    let
      names = map (dependency: dependency.name) crate.dependencies;
    in
    lib.filter (dependency: !(lib.elem dependency names)) given.attaches;
  listed = given: lib.concatMapStringsSep ", " (named: "${named.name} [${toString named.features}]") given.sets;

  union =
    crate:
    let
      given = entryOf crate;
      beyond = lib.filter (feature: !(lib.elem feature given.features)) crate.features;
      absent = lacking crate given;
    in
    lib.optional (beyond != [ ]) "  ${label crate}: resolves ${toString beyond}, which the set does not hold\n"
    ++ lib.optional (absent != [ ])
      "  ${label crate}: the set's features attach ${toString absent}, which this Cargo.nix does not give it\n";

  built = lib.filter (crate: crate.built) crates;
  absent = lib.filter (crate: entryOf crate == null) built;
  unions = lib.filter (crate: entryOf crate != null && !(entryOf crate ? sets)) built;
  withSets = lib.filter (crate: entryOf crate ? sets) built;

  # Each member's build takes the first name whose sets hold what it resolves.
  members = lib.unique (lib.concatMap (crate: lib.attrNames crate.resolutions) withSets);
  member =
    who:
    let
      reached = lib.filter (crate: crate.resolutions ? ${who}) withSets;
      holding =
        name: crate:
        let
          given = lib.findFirst (named: named.name == name) null (entryOf crate).sets;
        in
        given != null && holds given crate.resolutions.${who};
      name = lib.findFirst (name: lib.all (holding name) reached) null names;
      unheld = lib.filter (crate: !(lib.any (name: holding name crate) names)) reached;
      apart = map (
        crate:
        "  ${label crate} in ${who}: resolves [${toString crate.resolutions.${who}}], held by ${
          toString (lib.filter (name: holding name crate) names)
        }\n"
      ) reached;
    in
    if unheld != [ ] then
      map (
        crate:
        "  ${label crate} in ${who}: resolves [${toString crate.resolutions.${who}}], which no listed set holds: ${listed (entryOf crate)}\n"
      ) unheld
    else if name == null then
      [ "  ${who}: no one set name holds what it resolves:\n" ] ++ apart
    else
      # A narrower build of the member, its default features, takes this name
      # or one before it, so every set up to this name is one it may be built
      # with.
      lib.concatMap (
        crate:
        lib.concatMap (
          given:
          let
            missing = lacking crate given;
          in
          lib.optional (missing != [ ])
            "  ${label crate}: its ${given.name} set attaches ${toString missing}, which this Cargo.nix does not give it\n"
        ) (lib.take (lib.lists.findFirstIndex (each: each == name) 0 names + 1) (entryOf crate).sets)
      ) reached;

  departures =
    map (crate: "  ${label crate}: not in the set\n") absent
    ++ lib.concatMap union unions
    ++ lib.unique (lib.concatMap member members);
in
pkgs.runCommand "crate-features"
  (
    {
      passthru = { inherit departures; };
    }
    // lib.optionalAttrs (departures != [ ]) {
      message = ''
        The build base's crate feature set cannot build this workspace's crates as it resolves them.
        ${lib.concatStrings departures}Regenerate the set in build-base from every active repository's Cargo.nix. A crate's named sets are written there by hand, a second set only where a vision line places a feature per consumer.
      '';
    }
  )
  (
    if departures == [ ] then
      "touch $out"
    else
      ''
        printf '%s' "$message" >&2
        exit 1
      ''
  )
