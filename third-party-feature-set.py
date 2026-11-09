"""Writes third-party-features.json from the active repositories' Cargo.nix.

Each third-party crate (a crate from a registry) gets one feature set: the
union of the features each Cargo.nix resolves for it (resolved-features.nix),
so it has one build in every repository. Where a feature of the union
attaches an optional dependency some Cargo.nix holding the crate does not
give it, that repository carries the edge: each is named, by repository,
crate, the features attaching it and the dependency, and the set is written
whole. A third-party crate that asks of another, within the set, a feature
the other's set lacks is reported, and nothing is written.

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
    edges = []
    for (name, version), holders in sorted(crates.items()):
        features = set().union(*(set(entry["features"]) for entry in holders.values()))
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
                    edges.append(f"{repository}: {name} {version} {attaching} attaches {dependency}")
        sets[(name, version)] = {"features": sorted(features), "attaches": attaches}

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
    if edges:
        print("Edges each repository carries, in its manifest, lock and Cargo.nix:")
    for line in edges:
        print(f"  {line}")


main(sys.argv[1:])
