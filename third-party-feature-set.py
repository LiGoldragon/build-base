"""Writes third-party-features.json from the active repositories' Cargo.nix.

Each third-party crate (a crate from a registry) gets one feature set: the
union of the features each Cargo.nix resolves for it (resolved-features.nix),
so it has one build in every repository. A feature of the union that would
attach an optional dependency some Cargo.nix holding the crate does not give
it is held out of the set, with every feature that implies it, and named
with the dependency and the repositories that lack it; it waits on a ruling.
A third-party crate that asks of another, within the set, a feature the
other's set lacks is reported, and nothing is written.

    third-party-feature-set <repository>/Cargo.nix ...

A repository is named by the directory its Cargo.nix sits in.
"""

import json
import os
import subprocess
import sys

OUTPUT = "third-party-features.json"
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
        sys.exit("usage: third-party-feature-set <repository>/Cargo.nix ...")
    repositories = {
        os.path.basename(os.path.dirname(os.path.abspath(path))): resolve(os.path.abspath(path))
        for path in paths
    }

    crates = {}
    for repository, resolved in repositories.items():
        for name, versions in resolved.items():
            for version, entry in versions.items():
                crates.setdefault((name, version), {})[repository] = entry

    sets = {}
    held_out = []
    for (name, version), holders in sorted(crates.items()):
        union = set().union(*(set(entry["features"]) for entry in holders.values()))
        feature_map = next(iter(holders.values()))["featureMap"]
        given = {
            repository: {dependency["name"] for dependency in entry["dependencies"]}
            for repository, entry in holders.items()
        }
        optional = {
            dependency["name"]
            for entry in holders.values()
            for dependency in entry["dependencies"]
            if dependency["optional"]
        } | {feature[len("dep:"):] for feature in union if feature.startswith("dep:")}
        held = {}
        for dependency in sorted(optional):
            if not any(enables(feature, dependency) for feature in union):
                continue
            lacking = sorted(repository for repository, names in given.items() if dependency not in names)
            if not lacking:
                continue
            for feature in sorted(union):
                if any(enables(implied, dependency) for implied in expand(feature_map, [feature])):
                    held[feature] = f"attaches {dependency}, which {' '.join(lacking)} does not give {name}"
                    held_out.append(f"{name} {version}: {feature} attaches {dependency}, lacking in {' '.join(lacking)}")
        features = union - set(held)
        attaches = sorted(dependency for dependency in optional if any(enables(feature, dependency) for feature in features))
        sets[(name, version)] = {"features": sorted(features), "attaches": attaches}
        if held:
            sets[(name, version)]["held"] = dict(sorted(held.items()))

    # Within the set, what a crate asks of another is in the other's set, so
    # each crate's set build gives its dependencies their set and no more.
    conflicts = []
    for repository, resolved in repositories.items():
        for name, versions in resolved.items():
            for version, entry in versions.items():
                if not entry["built"]:
                    continue
                features = sets[(name, version)]["features"]
                for dependency in entry["dependencies"]:
                    target = sets.get((dependency["crate"], dependency["version"]))
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
                            f"{name} {version} asks {dependency['crate']} {dependency['version']} "
                            f"for {' '.join(sorted(missing))} in {repository}"
                        )
    if conflicts:
        print("The set does not hold what its crates ask of each other:", file=sys.stderr)
        for line in sorted(set(conflicts)):
            print(f"  {line}", file=sys.stderr)
        sys.exit(1)

    document = {}
    for (name, version), entry in sorted(sets.items()):
        document.setdefault(name, {})[version] = entry
    with open(OUTPUT, "w") as handle:
        json.dump(document, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print(f"{OUTPUT}: {len(sets)} crates from {len(repositories)} repositories")
    for line in held_out:
        print(f"  held out: {line}")


main(sys.argv[1:])
