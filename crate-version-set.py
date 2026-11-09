"""Writes crate-versions.json from the active repositories' Cargo.lock files.

The set holds every crate a repository takes from another repository:

  registry  a locked package whose source is a registry, by name: every
            version the given locks carry. Two locks may carry
            semver-incompatible versions of one crate (syn 1 and syn 2), as
            one lock may; two semver-compatible versions of one crate are a
            misalignment, which is reported, naming the crate, each version
            and its lock, and nothing is written.
  git       a locked package whose source is a git repository, by name and
            version: every locked git revision (the full commit after `#` in
            the lock's source) the given locks carry. A crate locked at more
            than one revision is written whole, each revision held, and
            listed with the repositories at each: that list is the measure of
            the drift between the repositories.

A workspace member, a path source, is in neither. A repository is named by the
directory its Cargo.lock sits in.

    crate-version-set Cargo.lock ...
"""

import json
import os
import sys
import tomllib

OUTPUT = "crate-versions.json"


def is_registry(package):
    source = package.get("source", "")
    return source.startswith("registry+") or source.startswith("sparse+")


def is_git(package):
    return package.get("source", "").startswith("git+")


def commit(package):
    return package["source"].rsplit("#", 1)[1]


def release(version):
    core = version.split("+")[0].split("-")[0]
    return tuple(int(part) for part in core.split("."))


def compatibility(version):
    # Cargo's semver compatibility: the leftmost non-zero component and
    # everything before it; 0.0.z is compatible only with itself.
    major, minor, patch = release(version)
    if major:
        return (major,)
    if minor:
        return (0, minor)
    return (0, 0, patch, version)


def main(locks):
    if not locks:
        sys.exit("usage: crate-version-set Cargo.lock ...")
    registry = {}
    git = {}
    for lock in locks:
        repository = os.path.basename(os.path.dirname(os.path.abspath(lock)))
        with open(lock, "rb") as handle:
            packages = tomllib.load(handle).get("package", [])
        for package in filter(is_registry, packages):
            versions = registry.setdefault(package["name"], {})
            versions.setdefault(package["version"], []).append(lock)
        for package in filter(is_git, packages):
            held = git.setdefault(package["name"], {})
            holders = held.setdefault((package["version"], commit(package)), [])
            if repository not in holders:
                holders.append(repository)

    misaligned = []
    for name, versions in sorted(registry.items()):
        groups = {}
        for version in versions:
            groups.setdefault(compatibility(version), []).append(version)
        for group in groups.values():
            if len(group) > 1:
                where = ", ".join(
                    f"{version} in {' '.join(versions[version])}"
                    for version in sorted(group, key=release)
                )
                misaligned.append(f"{name}: {where}")
    if misaligned:
        print("The locks are not aligned:", file=sys.stderr)
        for line in misaligned:
            print(f"  {line}", file=sys.stderr)
        sys.exit(1)

    registry_entries = [
        f"    {json.dumps(name)}: {json.dumps(sorted(versions, key=release))}"
        for name, versions in sorted(registry.items())
    ]
    git_entries = []
    for name, held in sorted(git.items()):
        by_version = {}
        for version, revision in held:
            by_version.setdefault(version, []).append(revision)
        lines = [
            f"      {json.dumps(version)}: {json.dumps(sorted(by_version[version]))}"
            for version in sorted(by_version, key=release)
        ]
        git_entries.append(f"    {json.dumps(name)}: {{\n" + ",\n".join(lines) + "\n    }")
    document = "".join(
        [
            '{\n  "registry": {\n',
            ",\n".join(registry_entries),
            '\n  },\n  "git": {\n',
            ",\n".join(git_entries),
            "\n  }\n}\n",
        ]
    )
    with open(OUTPUT, "w") as handle:
        handle.write(document)
    print(
        f"{OUTPUT}: {len(registry_entries)} registry crates, "
        f"{len(git_entries)} git crates in {sum(map(len, git.values()))} revisions, "
        f"from {len(locks)} locks"
    )

    drifted = {name: held for name, held in sorted(git.items()) if len(held) > 1}
    if drifted:
        print("Git crates held at more than one revision, with the repositories at each:")
    for name, held in drifted.items():
        print(f"  {name}")
        for (version, revision), repositories in sorted(held.items(), key=lambda item: (release(item[0][0]), item[0][1])):
            print(f"    {version} {revision[:7]}: {' '.join(sorted(repositories))}")


main(sys.argv[1:])
