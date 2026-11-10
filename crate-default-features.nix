# The features a crate is handed, with `default` normalized, so a crate
# handed the same effective features is one derivation.
#
# `default` names the features it implies, yet buildRustCrate passes it to
# rustc as a feature of its own: a crate reached once with its default
# features and once without, every feature they imply otherwise on, would be
# two builds of one input. A crate holds `default` exactly where its [features]
# table declares it and everything it implies is on, every feature in its
# closure and every optional dependency it attaches; otherwise `default` is
# dropped. crate2nix writes no empty `default`, so a crate whose `default` is
# empty is built without it.
#   normalized <its [features] table> <the features crate2nix resolves>
{ lib }:
let
  closure =
    featureMap: features:
    map (item: item.key) (
      builtins.genericClosure {
        startSet = map (key: { inherit key; }) features;
        operator = item: map (key: { inherit key; }) (featureMap.${item.key} or [ ]);
      }
    );
  # crate2nix's doesFeatureEnableDependency.
  enables =
    dependency: feature:
    feature == dependency || feature == "dep:${dependency}" || lib.hasPrefix "${dependency}/" feature;
  attachedBy =
    feature:
    if lib.hasPrefix "dep:" feature then
      [ (lib.removePrefix "dep:" feature) ]
    else if lib.hasInfix "/" feature && !(lib.hasInfix "?/" feature) then
      [ (lib.head (lib.splitString "/" feature)) ]
    else
      [ ];
in
{
  normalized =
    featureMap: features:
    let
      given = lib.filter (feature: feature != "default") features;
      implied = lib.filter (feature: feature != "default") (closure featureMap (featureMap.default or [ ]));
      plain = lib.filter (feature: !(lib.hasInfix "/" feature) && !(lib.hasPrefix "dep:" feature)) implied;
      attached = lib.unique (lib.concatMap attachedBy implied);
      on =
        featureMap ? default
        && lib.all (feature: lib.elem feature given) plain
        && lib.all (dependency: lib.any (enables dependency) given) attached;
    in
    lib.sort lib.lessThan (given ++ lib.optional on "default");
}
