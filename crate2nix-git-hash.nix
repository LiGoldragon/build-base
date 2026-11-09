# The check that crate2nix reads a git crate's hash under its own revision.
#
# A repository holds two crates, dependency and its sibling dependency-derive,
# which keep their versions across two commits. A workspace takes the
# repository at the first commit and crate2nix generate writes
# crate-hashes.json; the workspace is then repinned to the second commit,
# keeping that crate-hashes.json, and generated again. The file must now hold
# the hash of the second commit, prefetched fresh: crate2nix 0.15.0 read the
# first commit's hash for the second, because a sibling of the same name and
# version had one (crate2nix-git-hash-by-rev.patch).
#
# The prefetch is stood in for by a script printing a hash of the revision it
# is asked for, so the check needs neither the network nor the Nix store.
context:
let
  inherit (context) pkgs toolchain crate2nix;
  prefetch = pkgs.writeShellScriptBin "nix-prefetch-git" ''
    while [ $# -gt 0 ]; do
      case "$1" in
        --rev) rev="$2"; shift ;;
      esac
      shift
    done
    hash=$(printf '%s' "$rev" | sha256sum | cut -d' ' -f1)
    printf '{"sha256":"%s","rev":"%s"}\n' \
      "$(${pkgs.nix}/bin/nix-hash --type sha256 --to-base32 "$hash")" "$rev"
  '';
in
pkgs.runCommand "crate2nix-git-hash"
  {
    nativeBuildInputs = [
      prefetch
      crate2nix
      toolchain
      pkgs.git
    ];
  }
  ''
    export HOME="$NIX_BUILD_TOP/home" CARGO_HOME="$NIX_BUILD_TOP/cargo-home"
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
    mkdir -p "$HOME" "$CARGO_HOME"
    git config --global user.email test@example.org
    git config --global user.name test
    git config --global init.defaultBranch main

    repository="$NIX_BUILD_TOP/repository"
    mkdir -p "$repository/dependency/src" "$repository/dependency-derive/src"
    cat > "$repository/Cargo.toml" <<'EOF'
    [workspace]
    members = ["dependency", "dependency-derive"]
    resolver = "2"
    EOF
    cat > "$repository/dependency/Cargo.toml" <<'EOF'
    [package]
    name = "dependency"
    version = "0.1.0"
    edition = "2021"
    [dependencies]
    dependency-derive = { path = "../dependency-derive", version = "0.1.0" }
    EOF
    cat > "$repository/dependency-derive/Cargo.toml" <<'EOF'
    [package]
    name = "dependency-derive"
    version = "0.1.0"
    edition = "2021"
    EOF
    echo 'pub fn one() {}' > "$repository/dependency/src/lib.rs"
    echo 'pub fn two() {}' > "$repository/dependency-derive/src/lib.rs"
    git -C "$repository" init -q
    git -C "$repository" add .
    git -C "$repository" commit -q -m first
    first=$(git -C "$repository" rev-parse HEAD)
    echo 'pub fn three() {}' >> "$repository/dependency/src/lib.rs"
    git -C "$repository" commit -q -a -m second
    second=$(git -C "$repository" rev-parse HEAD)

    workspace="$NIX_BUILD_TOP/workspace"
    mkdir -p "$workspace/src"
    echo 'fn main() {}' > "$workspace/src/main.rs"
    cd "$workspace"
    pin() {
      cat > Cargo.toml <<EOF
    [package]
    name = "workspace"
    version = "0.1.0"
    edition = "2021"
    [dependencies]
    dependency = { git = "file://$repository", rev = "$1" }
    EOF
      rm -f Cargo.lock Cargo.nix
      cargo generate-lockfile
      crate2nix generate 2> generate.log || { cat generate.log >&2; exit 1; }
    }

    pin "$first"
    grep -q "$first" Cargo.lock
    cp crate-hashes.json first.json

    pin "$second"
    grep -q "$second" Cargo.lock
    cat generate.log
    cat crate-hashes.json

    expected=$(${pkgs.nix}/bin/nix-hash --type sha256 --to-base32 "$(printf '%s' "$second" | sha256sum | cut -d' ' -f1)")
    stale=$(${pkgs.nix}/bin/nix-hash --type sha256 --to-base32 "$(printf '%s' "$first" | sha256sum | cut -d' ' -f1)")
    if grep -q "$stale" crate-hashes.json; then
      echo "crate-hashes.json holds the first revision's hash for the second revision" >&2
      exit 1
    fi
    test "$(grep -c "$expected" crate-hashes.json)" = 2
    touch $out
  ''
