# What a crate is to the base's sets, read from an imported Cargo.nix.
#
# The sets hold every crate a repository takes from another repository: a
# registry crate or a git crate, each identified by its name and version (the
# version set holds one revision per git crate version). A workspace member, a
# path source, is in neither. crate2nix writes each kind apart: a registry crate
# carries the registry's `sha256`, a git crate a `pkgs.fetchgit` src, which
# carries its full `rev`, and a member a local src without one.
#
# A crate's entry is its union, { features; attaches; }, or its named sets,
# { sets = [ { name; features; attaches; vision; } ... ]; }, each set a
# deliberate entry naming the vision line that places a feature per consumer.
# Every crate holding named sets lists the same names in the same order, and a
# build takes one name: each crate with named sets is built with its set of
# that name, every other crate with its union.
{ lib }:
rec {
  isRegistry = crate: crate ? sha256;
  isGit = crate: crate ? src && crate.src ? rev;
  held = crate: isRegistry crate || isGit crate;

  # A git crate's locked commit; null for any other crate.
  revision = crate: if isGit crate then crate.src.rev else null;

  # The set's key for a crate: "name version" for a registry crate, "git name
  # version" for a git crate; null for a member.
  key =
    crate:
    if isGit crate then
      "git ${crate.crateName} ${crate.version}"
    else if isRegistry crate then
      "${crate.crateName} ${crate.version}"
    else
      null;

  # The crate's entry in a feature set, or null where the set lacks it.
  entry =
    set: crate:
    if isGit crate then
      set.git.${crate.crateName}.${crate.version} or null
    else if isRegistry crate then
      set.registry.${crate.crateName}.${crate.version} or null
    else
      null;

  # The crate's features in a build taking the set name `name`: its named set
  # of that name where it holds named sets, its union otherwise; null where
  # the set lacks the crate or the name.
  setIn =
    set: name: crate:
    let
      given = entry set crate;
    in
    if given == null then
      null
    else if given ? sets then
      lib.findFirst (named: named.name == name) null given.sets
    else
      given;

  # Whether the crate holds named sets.
  named = set: crate: (entry set crate).sets or null != null;

  # The set names, in the order a build prefers them; [ null ] where no crate
  # holds named sets, every crate then built with its union.
  setNames =
    set:
    let
      entries = lib.concatMap lib.attrValues (lib.attrValues set.registry ++ lib.attrValues set.git);
      lists = lib.unique (map (given: map (named: named.name) given.sets) (lib.filter (given: given ? sets) entries));
    in
    if lists == [ ] then
      [ null ]
    else
      assert lib.assertMsg (lib.length lists == 1)
        "crate-features.json: crates with named sets list different names: ${toString (map toString lists)}";
      lib.head lists;
}
