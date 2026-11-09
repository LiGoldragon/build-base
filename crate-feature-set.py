"""Writes crate-features.json from the active repositories' Cargo.nix.

Each crate a repository takes from another repository gets one feature set:
the union of the features each Cargo.nix resolves for it
(resolved-features.nix), so it has one build in every repository. A registry
crate and a git crate each have one set per name and version, whatever
revisions of a git crate the Cargo.nix files lock (the version set holds one
revision per version); a workspace member has none.

A crate may instead hold named sets, written by hand in crate-features.json
and kept when it is written again: each set a name, its features and the
vision line placing a feature per consumer. Every crate with named sets lists
the same names in the same order, and each member's build takes the first name
whose sets hold what the member resolves for every such crate. The generator
never adds a set: where a member resolves a crate with named sets as no listed
set holds, or as no one name holds for all of them, it names the member, the
crates, their features and the listed sets, and writes nothing. Named sets of
a crate no repository resolves any longer are dropped, and named.

Where a feature of a set attaches an optional dependency some Cargo.nix
building the crate under it, or under a later name, does not give it, that repository carries the
edge: each is named, by repository, crate, the features attaching it and the
dependency, and the set is written whole. A crate that asks of another, under
any set name, a feature the other's set of that name lacks is reported, and
nothing is written.

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


def label(name, version, is_git):
    return f"{name} {version}" + (" (git)" if is_git else "")


def refuse(heading, lines):
    print(heading, file=sys.stderr)
    for line in lines:
        print(f"  {line}", file=sys.stderr)
    sys.exit(1)


def named_sets():
    """The named sets crate-features.json holds, by crate, written by hand."""
    if not os.path.exists(OUTPUT):
        return {}
    with open(OUTPUT) as handle:
        document = json.load(handle)
    named = {}
    for kind in ("registry", "git"):
        for name, versions in document.get(kind, {}).items():
            for version, entry in versions.items():
                if isinstance(entry, dict) and "sets" in entry:
                    named[(name, version, kind == "git")] = [
                        {"name": given["name"], "features": sorted(given["features"]), "vision": given.get("vision", "")}
                        for given in entry["sets"]
                    ]
    return named


def main(paths):
    if not paths:
        sys.exit("usage: crate-feature-set <repository>/Cargo.nix ...")
    named = named_sets()
    repositories = {
        os.path.basename(os.path.dirname(os.path.abspath(path))): resolve(os.path.abspath(path))
        for path in paths
    }

    # Every crate with named sets lists the same names in the same order, each
    # set naming its vision line.
    orders = {tuple(given["name"] for given in sets) for sets in named.values()}
    if len(orders) > 1:
        refuse(
            "Crates with named sets list different names:",
            [f"{label(*identity)}: {' '.join(given['name'] for given in sets)}" for identity, sets in sorted(named.items())],
        )
    unreasoned = [
        f"{label(*identity)}: {given['name']}" for identity, sets in sorted(named.items()) for given in sets if not given["vision"]
    ]
    if unreasoned:
        refuse("Named sets naming no vision line:", unreasoned)
    names = list(orders.pop()) if orders else [None]

    # A crate is its name, its version and its kind, registry or git.
    crates = {}
    for repository, resolved in repositories.items():
        for entry in resolved:
            identity = (entry["name"], entry["version"], entry["revision"] is not None)
            crates.setdefault(identity, {})[repository] = entry

    dropped = sorted(identity for identity in named if identity not in crates)
    named = {identity: sets for identity, sets in named.items() if identity in crates}

    # Each member's build takes the first name whose sets hold what it resolves
    # for every crate with named sets.
    unheld = []
    taken = {}
    for repository, resolved in sorted(repositories.items()):
        reached = {}
        for entry in resolved:
            identity = (entry["name"], entry["version"], entry["revision"] is not None)
            if identity in named:
                for member, features in entry["resolutions"].items():
                    reached.setdefault(member, {})[identity] = set(features)
        for member, resolutions in sorted(reached.items()):

            def holding(name, identity):
                given = next(given for given in named[identity] if given["name"] == name)
                return resolutions[identity] <= set(given["features"])

            name = next((name for name in names if all(holding(name, identity) for identity in resolutions)), None)
            if name is not None:
                taken[(repository, member)] = name
                continue
            # The crates no listed set holds, or, where each is held by some
            # name, every crate with the names holding it.
            held = {identity: [name for name in names if holding(name, identity)] for identity in resolutions}
            alone = any(not names_holding for names_holding in held.values())
            for identity, features in sorted(resolutions.items()):
                listed = ", ".join(f"{given['name']} [{' '.join(given['features'])}]" for given in named[identity])
                if held[identity]:
                    if alone:
                        continue
                    where = f"held by {' '.join(held[identity])}"
                else:
                    where = f"which no listed set holds: {listed}"
                unheld.append(f"{repository} {member}: {label(*identity)} resolves [{' '.join(sorted(features))}], {where}")
    if unheld:
        refuse(
            "Members resolve crates with named sets as no one set name holds; a named set is written by hand, "
            "a second set only where a vision line places a feature per consumer:",
            unheld,
        )

    sets = {}
    edges = []
    for (name, version, is_git), holders in sorted(crates.items()):
        identity = (name, version, is_git)
        # Revisions of one git crate version may differ in their feature maps.
        feature_map = {}
        for entry in holders.values():
            for feature, implied in entry["featureMap"].items():
                feature_map[feature] = sorted(set(feature_map.get(feature, [])) | set(implied))
        optional_names = {
            dependency["name"]
            for entry in holders.values()
            for dependency in entry["dependencies"]
            if dependency["optional"]
        }

        def attaching(features):
            optional = optional_names | {feature[len("dep:"):] for feature in features if feature.startswith("dep:")}
            return sorted(dependency for dependency in optional if any(enables(feature, dependency) for feature in features))

        def carried(features, holding, set_name):
            # A repository that never builds the crate under this set carries
            # no edge for it, as checks.crate-features asks nothing of a crate
            # not built.
            for dependency in attaching(features):
                causes = " ".join(
                    feature
                    for feature in sorted(features)
                    if any(enables(implied, dependency) for implied in expand(feature_map, [feature]))
                )
                for repository, entry in sorted(holding.items()):
                    if dependency not in {given["name"] for given in entry["dependencies"]}:
                        under = f" under {set_name}" if set_name else ""
                        edges.append(f"{repository}: {label(*identity)}{under}, {causes} attaches {dependency}")

        if identity in named:
            entry = {"sets": []}
            for given in named[identity]:
                features = set(given["features"])
                # A narrower build of a member, its default features, takes
                # the name its widest build takes or one before it.
                at = names.index(given["name"])
                holding = {
                    repository: holders[repository]
                    for (repository, member), name in taken.items()
                    if repository in holders and member in holders[repository]["resolutions"] and names.index(name) >= at
                }
                carried(features, holding, given["name"])
                entry["sets"].append(dict(given, attaches=attaching(features)))
        else:
            features = set().union(*(set(entry["features"]) for entry in holders.values()))
            carried(features, {repository: entry for repository, entry in holders.items() if entry["built"]}, None)
            entry = {"features": sorted(features), "attaches": attaching(features)}
        sets[identity] = entry

    def under(identity, name):
        entry = sets.get(identity)
        if entry is None or "sets" not in entry:
            return entry
        return next(given for given in entry["sets"] if given["name"] == name)

    # Within the set, under each set name, what a crate asks of another is in
    # the other's set of that name, so each crate's build under a name gives
    # its dependencies their features under it and no more.
    conflicts = []
    for repository, resolved in repositories.items():
        for entry in resolved:
            if not entry["built"]:
                continue
            identity = (entry["name"], entry["version"], entry["revision"] is not None)
            for name in names:
                features = under(identity, name)["features"]
                for dependency in entry["dependencies"]:
                    target_identity = (dependency["crate"], dependency["version"], dependency["revision"] is not None)
                    target = under(target_identity, name)
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
                        under_name = f" under {name}" if name else ""
                        conflicts.append(
                            f"{label(*identity)} asks {label(*target_identity)} "
                            f"for {' '.join(sorted(missing))}{under_name} in {repository}"
                        )
    if conflicts:
        refuse("The set does not hold what its crates ask of each other:", sorted(set(conflicts)))

    document = {"registry": {}, "git": {}}
    for (name, version, is_git), entry in sets.items():
        document["git" if is_git else "registry"].setdefault(name, {})[version] = entry
    with open(OUTPUT, "w") as handle:
        json.dump(document, handle, indent=2, sort_keys=True)
        handle.write("\n")
    git = sum(1 for identity in sets if identity[2])
    print(
        f"{OUTPUT}: {len(sets) - git} registry crate versions and {git} git crate versions "
        f"from {len(repositories)} repositories, {len(named)} with named sets"
    )
    if dropped:
        print("Named sets dropped, of crates no repository resolves:")
    for identity in dropped:
        print(f"  {label(*identity)}")
    if edges:
        print("Edges each repository carries, in its manifest, lock and Cargo.nix:")
    for line in edges:
        print(f"  {line}")


main(sys.argv[1:])
