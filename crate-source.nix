# The source a crate builds from: its checkout without what rustc never reads
# while building it, named for the crate and its version.
#
# A crate's store path is then decided by what the build reads and nothing
# else. The same crate at two commits that differ in a README, a test, a lock
# or a flake is one path, so one build; and a crate built in its own
# repository, a path source, is the same path as the same commit taken as a git
# dependency, a fetchgit of the whole checkout. The filter is a copy of the
# fetched path (builtins.path), made at evaluation, which gives a path
# determined by the remaining content and the name; a derivation over the
# fetchgit would give a path determined by the fetchgit's, and so by the commit.
#
# Dropped, in every directory that holds a Cargo.toml (a crate's directory, the
# workspace's root among them): the directories and files named below, and
# Markdown. Left whole: src/, build.rs, and every other file or directory,
# which a crate may read with include_str! or from its build script.
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
in
# The crate's source: a fetchgit, or a member's path source (itself a
# cleanSourceWith, whose own filter holds as well).
crate:
lib.cleanSourceWith {
  src = crate.src;
  filter = path: type: !(unread path type);
  name = "${crate.crateName}-${crate.version}";
}
