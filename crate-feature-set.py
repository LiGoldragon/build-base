"""Writes crate-features.json from the active repositories' Cargo.nix.

Each crate a repository takes from another repository gets one feature set:
the union of the features each Cargo.nix resolves for it
(resolved-features.nix), so it has one build in every repository. A registry
crate and a git crate each have one set per name and version, whatever
revisions of a git crate the Cargo.nix files lock (the version set holds one
revision per version); a workspace member has none. Where a feature of the union
attaches an optional dependency some Cargo.nix building the crate does not
give it, that repository carries the edge: each is named, by repository,
crate, the features attaching it and the dependency, and the set is written
whole. A crate that asks of another, within the set, a feature the other's
set lacks is reported, and nothing is written.

    crate-feature-set <repository>/Cargo.nix ...

A repository is named by the directory its Cargo.nix sits in.
"""

import json
import os
import subprocess
import sys

OUTPUT = "crate-features.json"
RESOLVER = "@resolver@"
NIXPKGS = "@nixpkgs@"
SYSTEM = "@system@"


def resolve(cargo_nix):
    pkgs = f'import {NIXPKGS} {{ system = "{SYSTEM}"; }}'
    expression = (
        f"let pkgs = {pkgs}; in import {RESOLVER} "
        f"{{ inherit pkgs; generated = import {json.dumps(cargo_nix)} {{ inherit pkgs; }}; }}"
    )
    result = subprocess.run(
        ["nix", "eval", "--json", "--impure", "--expr", expression],
        check=True,
        stdout=subprocess.PIPE,
    )
    return json.loads(result.stdout)


def enables(feature, name):
    # crate2nix's doesFeatureEnableDependency.
    return feature == name or feature == "dep:" + name or feature.startswith(name + "/")


def expand(feature_map, features):
    # crate2nix's expandFeatures.
    seen = set()
    pending = list(features)
    while pending:
        feature = pending.pop()
        if feature not in seen:
            seen.add(feature)
            pending.extend(feature_map.get(feature, []))
    return seen


def main(paths):
    if not paths:
        sys.exit("usage: crate-feature-set <repository>/Cargo.nix ...")
    repositories = {
        os.path.basename(os.path.dirname(os.path.abspath(path))): resolve(os.path.abspath(path))
        for path in paths
    }

    # A crate is its name, its version and its kind, registry or git.
    crates = {}
    for repository, resolved in repositories.items():
        for entry in resolved:
            identity = (entry["name"], entry["version"], entry["revision"] is not None)
            crates.setdefault(identity, {})[repository] = entry

    sets = {}
    edges = []
    for (name, version, is_git), holders in sorted(crates.items()):
        label = f"{name} {version}" + (" (git)" if is_git else "")
        features = set().union(*(set(entry["features"]) for entry in holders.values()))
        # Revisions of one git crate version may differ in their feature maps.
        feature_map = {}
        for entry in holders.values():
            for feature, implied in entry["featureMap"].items():
                feature_map[feature] = sorted(set(feature_map.get(feature, [])) | set(implied))
        # A repository that never builds the crate carries no edge for it, as
        # checks.crate-features asks nothing of a crate not built.
        given = {
            repository: {dependency["name"] for dependency in entry["dependencies"]}
            for repository, entry in holders.items()
            if entry["built"]
        }
        optional = {
            dependency["name"]
            for entry in holders.values()
            for dependency in entry["dependencies"]
            if dependency["optional"]
        } | {feature[len("dep:"):] for feature in features if feature.startswith("dep:")}
        attaches = sorted(dependency for dependency in optional if any(enables(feature, dependency) for feature in features))
        for dependency in attaches:
            attaching = " ".join(
                feature
                for feature in sorted(features)
                if any(enables(implied, dependency) for implied in expand(feature_map, [feature]))
            )
            for repository, names in sorted(given.items()):
                if dependency not in names:
                    edges.append(f"{repository}: {label} {attaching} attaches {dependency}")
        sets[(name, version, is_git)] = {"features": sorted(features), "attaches": attaches}

    # Within the set, what a crate asks of another is in the other's set, so
    # each crate's set build gives its dependencies their set and no more.
    conflicts = []
    for repository, resolved in repositories.items():
        for entry in resolved:
            if not entry["built"]:
                continue
            name, version, is_git = entry["name"], entry["version"], entry["revision"] is not None
            features = sets[(name, version, is_git)]["features"]
            for dependency in entry["dependencies"]:
                target = sets.get((dependency["crate"], dependency["version"], dependency["revision"] is not None))
                if target is None or not dependency["applies"]:
                    continue
                if dependency["optional"] and not any(enables(f, dependency["name"]) for f in features):
                    continue
                prefixes = (dependency["name"] + "/", dependency["name"] + "?/")
                asked = set(dependency["requests"]) | {
                    feature.split("/", 1)[1] for feature in features if feature.startswith(prefixes)
                }
                missing = asked - set(target["features"])
                if missing:
                    conflicts.append(
                        f"{name} {version}{' (git)' if is_git else ''} asks "
                        f"{dependency['crate']} {dependency['version']}{' (git)' if dependency['revision'] else ''} "
                        f"for {' '.join(sorted(missing))} in {repository}"
                    )
    if conflicts:
        print("The set does not hold what its crates ask of each other:", file=sys.stderr)
        for line in sorted(set(conflicts)):
            print(f"  {line}", file=sys.stderr)
        sys.exit(1)

    document = {"registry": {}, "git": {}}
    for (name, version, is_git), entry in sets.items():
        document["git" if is_git else "registry"].setdefault(name, {})[version] = entry
    with open(OUTPUT, "w") as handle:
        json.dump(document, handle, indent=2, sort_keys=True)
        handle.write("\n")
    git = sum(1 for identity in sets if identity[2])
    print(
        f"{OUTPUT}: {len(sets) - git} registry crate versions and {git} git crate versions "
        f"from {len(repositories)} repositories"
    )
    if edges:
        print("Edges each repository carries, in its manifest, lock and Cargo.nix:")
    for line in edges:
        print(f"  {line}")


main(sys.argv[1:])
