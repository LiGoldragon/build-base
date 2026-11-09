# What a crate is to the base's sets, read from an imported Cargo.nix.
#
# The sets hold every crate a repository takes from another repository: a
# registry crate or a git crate, each identified by its name and version (the
# version set holds one revision per git crate version). A workspace member, a
# path source, is in neither. crate2nix writes each kind apart: a registry crate
# carries the registry's `sha256`, a git crate a `pkgs.fetchgit` src, which
# carries its full `rev`, and a member a local src without one.
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
}
