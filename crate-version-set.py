"""Writes crate-versions.json from the active repositories' Cargo.lock files.

The set holds every crate a repository takes from another repository:

  registry  a locked package whose source is a registry, by name: every
            version the given locks carry. Two locks may carry
            semver-incompatible versions of one crate (syn 1 and syn 2), as
            one lock may; two semver-compatible versions of one crate are a
            misalignment, which is reported, naming the crate, each version
            and its lock, and nothing is written.
  git       a locked package whose source is a git repository, by name and
            version: the one git revision (the full commit after `#` in the
            lock's source) the given locks carry. A git crate is one crate at
            one revision per version, and two semver-compatible versions of it
            are a misalignment, as for a registry crate. A git crate locked at
            more than one revision of one version, or at two compatible
            versions, is refused: nothing is written, and every such crate is
            listed with each version and revision and the repositories at
            each. That list is the work queue that closes the drift.

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

    # A git crate holds one revision per version and no two compatible
    # versions: every held (version, revision) of an offending group is listed.
    drift_lines = []
    for name, held in sorted(git.items()):
        groups = {}
        for version, revision in held:
            groups.setdefault(compatibility(version), []).append((version, revision))
        for group in groups.values():
            if len(group) > 1:
                drift_lines.append(f"  {name}")
                for version, revision in sorted(group, key=lambda entry: (release(entry[0]), entry[1])):
                    repositories = " ".join(sorted(held[(version, revision)]))
                    drift_lines.append(f"    {version} {revision[:7]}: {repositories}")

    if misaligned or drift_lines:
        print("The locks are not aligned; nothing is written.", file=sys.stderr)
        if misaligned:
            print("Registry crates at semver-compatible versions:", file=sys.stderr)
            for line in misaligned:
                print(f"  {line}", file=sys.stderr)
        if drift_lines:
            print("Git crates at more than one revision of a version, or at compatible versions, with the repositories at each:", file=sys.stderr)
            for line in drift_lines:
                print(line, file=sys.stderr)
        sys.exit(1)

    registry_entries = [
        f"    {json.dumps(name)}: {json.dumps(sorted(versions, key=release))}"
        for name, versions in sorted(registry.items())
    ]
    git_entries = []
    for name, held in sorted(git.items()):
        lines = [
            f"      {json.dumps(version)}: {json.dumps(revision)}"
            for version, revision in sorted(held, key=lambda entry: release(entry[0]))
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
        f"{len(git_entries)} git crates in {sum(map(len, git.values()))} versions, "
        f"from {len(locks)} locks"
    )


main(sys.argv[1:])
