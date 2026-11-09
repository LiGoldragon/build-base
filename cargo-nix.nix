# The check that a workspace's committed Cargo.nix is what the base's
# crate2nix generates from the workspace as it stands.
#
# Two steps. First, at evaluation, the packages Cargo.lock locks are compared
# with the crates Cargo.nix records: name, version, and the registry checksum
# or the git url and revision. A difference fails the check at once, naming
# the packages. Only when they agree is the second step built: crate2nix
# generate runs in the sandbox, offline, over the source with its locked
# crates vendored from those same checksums and git hashes, and its output
# must equal the committed Cargo.nix byte for byte. That catches what the lock
# cannot show: features, targets, editions, build scripts, members.
#
# source is the Cargo workspace, holding Cargo.toml and Cargo.lock. cargoNix
# is the committed Cargo.nix generated from it, at the workspace root or kept
# apart from it. crateHashes is the crate-hashes.json committed with that
# Cargo.nix, laid into the source before generation; null when the source
# holds its own, or has no git dependency.
context:
{
  source,
  cargoNix,
  crateHashes ? null,
  generated ? import cargoNix { inherit (context) pkgs; },
}:
let
  inherit (context) pkgs crate2nix;
  lib = pkgs.lib;

  fix = "nix run github:LiGoldragon/build-base#crate2nix -- generate";

  lockFile = source + "/Cargo.lock";
  locked = (builtins.fromTOML (builtins.readFile lockFile)).package;

  # "git+URL?rev=R#COMMIT" -> { url, commit }
  parseGit =
    sourceId:
    let
      parts = builtins.match "git\\+([^?#]+)(\\?[^#]*)?#(.*)" sourceId;
    in
    {
      url = lib.elemAt parts 0;
      commit = lib.elemAt parts 2;
    };

  base16 =
    hash:
    builtins.convertHash {
      inherit hash;
      hashAlgo = "sha256";
      toHashFormat = "base16";
    };

  lockedKey =
    package:
    let
      sourceId = package.source or null;
    in
    if sourceId == null then
      "path ${package.name} ${package.version}"
    else if lib.hasPrefix "registry+" sourceId then
      "registry ${package.name} ${package.version} ${package.checksum or "no-checksum"}"
    else if lib.hasPrefix "git+" sourceId then
      let
        git = parseGit sourceId;
      in
      "git ${package.name} ${package.version} ${git.url} ${git.commit}"
    else
      "unknown ${package.name} ${package.version} ${sourceId}";

  recordedKey =
    crate:
    if crate ? sha256 then
      "registry ${crate.crateName} ${crate.version} ${base16 crate.sha256}"
    else if crate.src ? rev then
      "git ${crate.crateName} ${crate.version} ${crate.src.url} ${crate.src.rev}"
    else
      "path ${crate.crateName} ${crate.version}";

  lockedKeys = map lockedKey locked;
  recordedKeys = map recordedKey (lib.attrValues generated.internal.crates);
  unrecorded = lib.subtractLists recordedKeys lockedKeys;
  unlocked = lib.subtractLists lockedKeys recordedKeys;
  agree = unrecorded == [ ] && unlocked == [ ];

  failure =
    pkgs.runCommand "cargo-nix"
      {
        message = ''
          Cargo.nix does not match Cargo.lock.
          ${lib.concatMapStrings (key: "  in Cargo.lock, not in Cargo.nix: ${key}\n") unrecorded}${
            lib.concatMapStrings (key: "  in Cargo.nix, not in Cargo.lock: ${key}\n") unlocked
          }Regenerate it: ${fix}
        '';
      }
      ''
        printf '%s' "$message" >&2
        exit 1
      '';

  # The locked crates, vendored as cargo reads them offline. Registry crates
  # are fetched under the name Cargo.nix fetches them by, so both share one
  # store path; git crates take the hash Cargo.nix records.
  vendor =
    (pkgs.rustPlatform.importCargoLock.override {
      fetchurl = arguments: pkgs.fetchurl (arguments // { name = lib.removePrefix "crate-" arguments.name; });
    })
      {
        inherit lockFile;
        outputHashes = lib.listToAttrs (
          lib.concatMap (
            crate:
            lib.optional (crate ? src && crate.src ? rev) {
              name = "${crate.crateName}-${crate.version}";
              value = crate.src.outputHash;
            }
          ) (lib.attrValues generated.internal.crates)
        );
      };

  regeneration =
    pkgs.runCommand "cargo-nix"
      {
        nativeBuildInputs = [ crate2nix ];
        CARGO_NET_OFFLINE = "true";
      }
      ''
        export HOME="$NIX_BUILD_TOP/home" CARGO_HOME="$NIX_BUILD_TOP/cargo-home"
        mkdir -p "$HOME" "$CARGO_HOME"
        sed 's|^directory = .*|directory = "${vendor}"|' ${vendor}/.cargo/config.toml > "$CARGO_HOME/config.toml"

        cp -r ${source} "$NIX_BUILD_TOP/source"
        chmod -R u+w "$NIX_BUILD_TOP/source"
        cd "$NIX_BUILD_TOP/source"
        rm -f Cargo.nix${lib.optionalString (crateHashes != null) "\ncp ${crateHashes} crate-hashes.json"}

        if ! crate2nix generate >"$NIX_BUILD_TOP/generate.log" 2>&1; then
          cat "$NIX_BUILD_TOP/generate.log" >&2
          echo "crate2nix generate failed on this source, offline (a git dependency with no hash in a committed crate-hashes.json fails here)." >&2
          echo "Regenerate it: ${fix}" >&2
          exit 1
        fi
        if ! diff -u ${cargoNix} Cargo.nix >&2; then
          echo "Cargo.nix is not what crate2nix ${crate2nix.version} generates from this source." >&2
          echo "Regenerate it: ${fix}" >&2
          exit 1
        fi
        touch $out
      '';
in
if agree then regeneration else failure
