# The check that a crate handed the same effective features is one
# derivation (crate-default-features.nix): a fixture crate built by the base's
# buildRustCrate with an empty `default`, as signal 11.0.0 declares it, reached
# with and without default features, is one derivation; a crate whose
# `default` implies `std`, built with `std` and with `default` and `std`, is
# one derivation; and different effective features, no feature and `std`, stay
# two. Evaluated only: nothing is compiled.
context:
let
  inherit (context) pkgs;
  lib = pkgs.lib;
  defaults = import ./crate-default-features.nix { inherit lib; };

  src = pkgs.writeTextDir "src/lib.rs" "pub fn fixture() {}\n";
  build =
    featureMap: features:
    builtins.unsafeDiscardStringContext
      ((context.buildRustCrateForPkgs pkgs) {
        crateName = "fixture";
        version = "1.0.0";
        edition = "2021";
        inherit src;
        features = defaults.normalized featureMap features;
      }).drvPath;

  empty = { };
  standard = {
    default = [ "std" ];
    std = [ ];
  };
  optional = {
    default = [ "dep:extra" ];
  };

  cases = [
    {
      what = "an empty default, with and without default features, is one derivation";
      holds = build empty [ ] == build empty [ "default" ];
    }
    {
      what = "default implying std, built with std and with default and std, is one derivation";
      holds = build standard [ "std" ] == build standard [ "default" "std" ];
    }
    {
      what = "no feature and std are two derivations";
      holds = build standard [ ] != build standard [ "std" ];
    }
    {
      what = "default implying std is dropped where std is off";
      holds = defaults.normalized standard [ "default" ] == [ ];
    }
    {
      what = "default attaching an optional dependency is held where the dependency is attached";
      holds =
        defaults.normalized optional [ "extra" ] == [ "default" "extra" ]
        && defaults.normalized optional [ "default" ] == [ ];
    }
  ];
  failed = lib.filter (case: !case.holds) cases;
in
assert lib.assertMsg (failed == [ ]) "crate-default-features: ${lib.concatMapStringsSep "; " (case: case.what) failed}";
pkgs.runCommand "crate-default-features" { } ''
  ${lib.concatMapStrings (case: "echo ${lib.escapeShellArg "holds: ${case.what}"}\n") cases}
  touch $out
''
