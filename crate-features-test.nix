# The check that crate-features refuses a feature set a crate's named sets do
# not list and passes a listed second set: a fixture set holds signal 11.0.0
# with named sets plain and datom, and fixture resolutions stand in for a
# workspace's. A Nexus resolving signal plain and a CLI resolving it with
# datom pass; a daemon resolving it with transport, a set not listed, is
# refused, naming the crate, its features and the listed sets.
context:
let
  inherit (context) pkgs;
  lib = pkgs.lib;

  vision = ''vision:ethos, "The datom traits are compiled in only where text is spoken"'';
  set = {
    registry = { };
    git.signal."11.0.0".sets = [
      {
        name = "plain";
        features = [ ];
        attaches = [ ];
        inherit vision;
      }
      {
        name = "datom";
        features = [
          "datom"
          "datom-codec"
          "dep:datom-codec"
        ];
        attaches = [ "datom-codec" ];
        inherit vision;
      }
    ];
  };
  signal = resolutions: {
    name = "signal";
    version = "11.0.0";
    revision = "c93b598025984f8a73e70aa18b8e8a6fdfdfdfd8";
    built = true;
    features = lib.unique (lib.concatLists (lib.attrValues resolutions));
    featureMap = {
      datom = [ "dep:datom-codec" ];
      transport = [ "dep:tokio" ];
    };
    dependencies = [
      {
        name = "datom-codec";
        optional = true;
        crate = "datom-codec";
        version = "0.33.1";
        revision = "09a0526949b043f921b6d3ce115b7f455291f2e2";
        requests = [ "default" ];
        applies = true;
      }
    ];
    inherit resolutions;
  };
  check = resolutions: import ./crate-features.nix context {
    inherit set;
    resolved = [ (signal resolutions) ];
  };

  listed = check {
    nexus = [ ];
    cli = [
      "datom"
      "datom-codec"
      "dep:datom-codec"
    ];
  };
  unlisted = check {
    nexus = [ ];
    daemon = [
      "dep:tokio"
      "tokio"
      "transport"
    ];
  };
in
pkgs.runCommand "crate-features-named-sets"
  {
    refusal = lib.concatStrings unlisted.departures;
    passed = toString listed.departures;
  }
  ''
    printf '%s' "$refusal"
    test -n "$refusal"
    grep -qF 'signal 11.0.0 (git) in daemon: resolves [dep:tokio tokio transport], which no listed set holds: plain [], datom [datom datom-codec dep:datom-codec]' <<< "$refusal"
    test -z "$passed"
    test -e ${listed}
    touch $out
  ''
