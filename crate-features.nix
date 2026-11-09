# The check that the base's feature set (crate-features.json) can build every
# crate a workspace takes from another repository as its Cargo.nix resolves
# it, so the crate is the one build every repository on the base shares.
#
# For each such crate (a registry crate, by name and version, or a git crate,
# by name, version and revision; a workspace member is neither) this Cargo.nix
# resolves (resolved-features.nix), the set holds it and every feature it
# resolves, and the optional dependencies the set's features attach are ones
# this Cargo.nix gives it. Anything else fails the check, naming the crate.
# The set is written by the base's generator from the active repositories'
# Cargo.nix:
#   nix run github:LiGoldragon/build-base#crate-feature-set -- <repository>/Cargo.nix ...
context:
{ generated }:
let
  inherit (context) pkgs;
  lib = pkgs.lib;

  set = lib.importJSON ./crate-features.json;
  resolved = import ./resolved-features.nix { inherit pkgs generated; };

  departure =
    crate:
    let
      given =
        if crate.revision == null then
          set.registry.${crate.name}.${crate.version} or null
        else
          set.git.${crate.name}.${crate.version}.${crate.revision} or null;
      label = "${crate.name} ${crate.version}${lib.optionalString (crate.revision != null) " ${builtins.substring 0 7 crate.revision}"}";
      beyond = lib.filter (feature: !(lib.elem feature given.features)) crate.features;
      names = map (dependency: dependency.name) crate.dependencies;
      lacking = lib.filter (dependency: !(lib.elem dependency names)) given.attaches;
    in
    if !crate.built then
      [ ]
    else if given == null then
      [ "  ${label}: not in the set\n" ]
    else
      lib.optional (beyond != [ ]) "  ${label}: resolves ${toString beyond}, which the set does not hold\n"
      ++ lib.optional (lacking != [ ])
        "  ${label}: the set's features attach ${toString lacking}, which this Cargo.nix does not give it\n";

  departures = lib.concatMap departure resolved;
in
pkgs.runCommand "crate-features"
  (
    lib.optionalAttrs (departures != [ ]) {
      message = ''
        The build base's crate feature set cannot build this workspace's crates as it resolves them.
        ${lib.concatStrings departures}Regenerate the set in build-base from every active repository's Cargo.nix.
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
