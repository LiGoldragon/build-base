"""Writes third-party-versions.json from already-aligned Cargo.lock files.

A third-party crate is a locked package whose source is a registry. The set
holds, for each one, every version the given locks carry. Two locks may carry
semver-incompatible versions of one crate (syn 1 and syn 2), as one lock may;
two semver-compatible versions of one crate are a misalignment, which is
reported, naming the crate, each version and its lock, and nothing is written.

    third-party-version-set Cargo.lock ...
"""

import json
import sys
import tomllib

OUTPUT = "third-party-versions.json"


def is_registry(package):
    source = package.get("source", "")
    return source.startswith("registry+") or source.startswith("sparse+")


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
        sys.exit("usage: third-party-version-set Cargo.lock ...")
    carried = {}
    for lock in locks:
        with open(lock, "rb") as handle:
            packages = tomllib.load(handle).get("package", [])
        for package in filter(is_registry, packages):
            versions = carried.setdefault(package["name"], {})
            versions.setdefault(package["version"], []).append(lock)

    misaligned = []
    for name, versions in sorted(carried.items()):
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

    entries = [
        f"  {json.dumps(name)}: {json.dumps(sorted(versions, key=release))}"
        for name, versions in sorted(carried.items())
    ]
    with open(OUTPUT, "w") as handle:
        handle.write("{\n" + ",\n".join(entries) + "\n}\n")
    print(f"{OUTPUT}: {len(entries)} crates from {len(locks)} locks")


main(sys.argv[1:])
