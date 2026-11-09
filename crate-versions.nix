# The check that a workspace's Cargo.lock locks each crate it takes from
# another repository at a version the base's set holds (crate-versions.json),
# so every repository on the base shares one build of it.
#
# A crate taken from another repository is a locked package whose source is a
# registry, held by name and version, or a git repository, held by name and
# version with its one git revision, the full commit after `#` in the lock's
# source. A workspace member, a path source, is held in neither. The lock is
# compared with the set at evaluation; a departure fails the check, naming
# each crate with the lock's version (and revision) and the set's. The set is
# written by the base's generator from the active repositories' locks:
#   nix run github:LiGoldragon/build-base#crate-version-set -- <Cargo.lock ...>
context:
{ lockFile }:
let
  inherit (context) pkgs;
  lib = pkgs.lib;

  set = lib.importJSON ./crate-versions.json;

  registry =
    package:
    let
      sourceId = package.source or "";
    in
    lib.hasPrefix "registry+" sourceId || lib.hasPrefix "sparse+" sourceId;
  git = package: lib.hasPrefix "git+" (package.source or "");
  # The commit after `#` in "git+URL?rev=R#COMMIT".
  commit = package: lib.last (lib.splitString "#" package.source);
  short = revision: builtins.substring 0 7 revision;

  packages = (builtins.fromTOML (builtins.readFile lockFile)).package or [ ];

  registryDepartures = lib.filter (package: !lib.elem package.version (set.registry.${package.name} or [ ])) (
    lib.filter registry packages
  );
  heldGit = name: lib.mapAttrsToList (version: revision: { inherit version revision; }) (set.git.${name} or { });
  gitDepartures = lib.filter (package: (set.git.${package.name}.${package.version} or null) != commit package) (
    lib.filter git packages
  );

  registryDeparture =
    package:
    "  ${package.name}: lock ${package.version} set ${
      if set.registry ? ${package.name} then lib.concatStringsSep " " set.registry.${package.name} else "none"
    }\n";
  gitDeparture =
    package:
    "  ${package.name}: lock ${package.version} ${short (commit package)} set ${
      if set.git ? ${package.name} then
        lib.concatStringsSep ", " (map (held: "${held.version} ${short held.revision}") (heldGit package.name))
      else
        "none"
    }\n";

  departures = registryDepartures ++ gitDepartures;
  listing = lib.concatMapStrings registryDeparture registryDepartures + lib.concatMapStrings gitDeparture gitDepartures;
in
pkgs.runCommand "crate-versions"
  (
    lib.optionalAttrs (departures != [ ]) {
      message = ''
        Cargo.lock departs from the build base's crate version set.
        ${listing}Lock each crate at the set's version and revision, or bump the set in build-base
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
