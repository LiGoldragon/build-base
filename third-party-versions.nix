# The check that a workspace's Cargo.lock locks each third-party crate at a
# version the base's set holds (third-party-versions.json), so every
# repository on the base shares one build of it.
#
# A third-party crate is a locked package whose source is a registry. The
# lock is compared with the set at evaluation; a departure fails the check,
# naming each crate with the lock's version and the set's. The set is written
# by the base's generator from the active repositories' aligned locks:
#   nix run github:LiGoldragon/build-base#third-party-version-set -- <Cargo.lock ...>
context:
{ lockFile }:
let
  inherit (context) pkgs;
  lib = pkgs.lib;

  set = lib.importJSON ./third-party-versions.json;

  registry =
    package:
    let
      sourceId = package.source or "";
    in
    lib.hasPrefix "registry+" sourceId || lib.hasPrefix "sparse+" sourceId;

  locked = lib.filter registry ((builtins.fromTOML (builtins.readFile lockFile)).package or [ ]);
  departures = lib.filter (package: !lib.elem package.version (set.${package.name} or [ ])) locked;

  departure =
    package:
    "  ${package.name}: lock ${package.version} set ${
      if set ? ${package.name} then lib.concatStringsSep " " set.${package.name} else "none"
    }\n";
in
pkgs.runCommand "third-party-versions"
  (
    lib.optionalAttrs (departures != [ ]) {
      message = ''
        Cargo.lock departs from the build base's third-party version set.
        ${lib.concatMapStrings departure departures}Lock each crate at the set's version, or bump the set in build-base
        together with every active repository's lock.
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
