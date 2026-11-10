# The source a crate builds from: its own crate directory, the one holding
# its Cargo.toml, without what rustc never reads while building it, named for
# the crate and its version.
#
# A crate's store path is then decided by what the build reads and nothing
# else. The same crate at two commits that differ in a README, a test, a lock
# or a flake, or in another crate of its repository, is one path, so one
# build; and a crate built in its own repository, a member, is the same path
# as the same commit taken as a git dependency, whether it sits at the root of
# its repository or in a subdirectory. A member's source is its crate
# directory already (crate2nix gives it so); a git crate's is a fetchgit of the
# whole checkout, in which its directory is found as cargo finds it, by the
# package name in a Cargo.toml. The filter is a copy (builtins.path), made at
# evaluation, which gives a path determined by the remaining content and the
# name; a derivation over the fetchgit would give a path determined by the
# fetchgit's, and so by the commit.
#
# Dropped, in every directory that holds a Cargo.toml (the crate's directory,
# and any crate nested in it): the directories and files named below, and
# Markdown. Left whole: src/, build.rs, and every other file or directory,
# which a crate may read with include_str! or from its build script. A crate
# reading a file outside its own directory (include_str!("../../x"), a build
# script reading the workspace root) finds it absent; no active crate does.
{ lib }:
let
  # Read by tests, examples and benchmarks, by the repository's tools, or by
  # nothing a build runs. Cargo.lock is read by cargo, which a crate build
  # does not run: the dependencies are the derivations the Cargo.nix gives.
  directories = [
    "tests"
    "benches"
    "examples"
    ".beads"
    ".github"
  ];
  files = [
    "Cargo.lock"
    "Cargo.nix"
    "crate-hashes.json"
    "flake.nix"
    "flake.lock"
    "rust-toolchain.toml"
    "tests.nix"
    ".gitignore"
  ];

  unread =
    path: type:
    let
      name = baseNameOf path;
    in
    builtins.pathExists (dirOf path + "/Cargo.toml")
    && (
      if type == "directory" then
        lib.elem name directories
      else
        lib.elem name files || lib.hasSuffix ".md" name
    );

  # The directories under `directory`, itself first, that hold a Cargo.toml,
  # relative to it; hidden directories and target are not searched.
  manifests =
    directory: relative:
    let
      entries = builtins.readDir directory;
      below = lib.filter (
        name: entries.${name} == "directory" && !(lib.hasPrefix "." name) && name != "target"
      ) (lib.attrNames entries);
    in
    lib.optional (entries ? "Cargo.toml") relative
    ++ lib.concatMap (
      name: manifests "${directory}/${name}" (if relative == "" then name else "${relative}/${name}")
    ) below;

  # The crate's directory in a checkout: the one whose Cargo.toml names the
  # package.
  directoryOf =
    checkout: crateName:
    let
      packageName = relative: (builtins.fromTOML (builtins.readFile "${checkout}/${relative}/Cargo.toml")).package.name or null;
      found = lib.findFirst (relative: packageName relative == crateName) null (manifests "${checkout}" "");
    in
    if found == null then
      throw "crate-source.nix: no Cargo.toml in ${checkout} names the package ${crateName}"
    else if found == "" then
      checkout
    else
      "${checkout}/${found}";
in
# The crate's source: a fetchgit of its repository, or a member's path source
# (itself a cleanSourceWith, whose own filter holds as well).
crate:
lib.cleanSourceWith {
  src = if crate.src ? rev then directoryOf crate.src crate.crateName else crate.src;
  filter = path: type: !(unread path type);
  name = "${crate.crateName}-${crate.version}";
}
