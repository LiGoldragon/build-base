# The check that the base's feature set (third-party-features.json) can build
# every third-party crate of a workspace as its Cargo.nix resolves it, so the
# crate is the one build every repository on the base shares.
#
# For each third-party crate (a crate from a registry) this Cargo.nix
# resolves (resolved-features.nix), the set holds its version, holds every
# feature it resolves or holds that feature out pending a ruling, and the
# optional dependencies the set's features attach are ones this Cargo.nix
# gives it. Anything else fails the check, naming the crate. The set is
# written by the base's generator from the active repositories' Cargo.nix:
#   nix run github:LiGoldragon/build-base#third-party-feature-set -- <repository>/Cargo.nix ...
context:
{ generated }:
let
  inherit (context) pkgs;
  lib = pkgs.lib;

  set = lib.importJSON ./third-party-features.json;
  resolved = import ./resolved-features.nix { inherit pkgs generated; };

  departures = lib.concatLists (
    lib.mapAttrsToList (
      name: versions:
      lib.concatLists (
        lib.mapAttrsToList (
          version: entry:
          let
            given = set.${name}.${version} or null;
            beyond = lib.filter (
              feature: !(lib.elem feature given.features) && !(given.held or { } ? ${feature})
            ) entry.features;
            names = map (dependency: dependency.name) entry.dependencies;
            lacking = lib.filter (dependency: !(lib.elem dependency names)) given.attaches;
          in
          if !entry.built then
            [ ]
          else if given == null then
            [ "  ${name} ${version}: not in the set\n" ]
          else
            lib.optional (beyond != [ ]) "  ${name} ${version}: resolves ${toString beyond}, which the set does not hold\n"
            ++ lib.optional (lacking != [ ])
              "  ${name} ${version}: the set's features attach ${toString lacking}, which this Cargo.nix does not give it\n"
        ) versions
      )
    ) resolved
  );
in
pkgs.runCommand "third-party-features"
  (
    lib.optionalAttrs (departures != [ ]) {
      message = ''
        The build base's third-party feature set cannot build this workspace's crates as it resolves them.
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
