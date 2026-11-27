# Compile through the real package-source projection, not the raw fixture.
{ pkgs, toolchain, ... }:
let
  inherit (pkgs) lib;
  packaged = import ./crate-source.nix { inherit lib; };
  fixtures = pkgs.runCommand "crate-source-readme-fixtures" { } ''
    make() {
      directory="$out/$1"
      mkdir -p "$directory/src"
      printf '[package]\nname = "fixture"\nversion = "0.1.0"\nedition = "2024"\n%s\n' "$2" > "$directory/Cargo.toml"
      printf 'pub fn marker() {}\n' > "$directory/src/lib.rs"
      printf 'unrelated Markdown\n' > "$directory/UNRELATED.md"
    }
    uses() {
      printf '#![doc = include_str!("../%s")]\npub fn marker() {}\n' "$1" > "$directory/src/lib.rs"
    }

    make implicit ""
    uses README.md
    echo implicit > "$directory/README.md"

    make explicit 'readme = "PACKAGE.md"'
    uses PACKAGE.md
    echo explicit > "$directory/PACKAGE.md"
    echo unselected > "$directory/README.md"

    make affirmative "readme = true"
    uses README.md
    echo affirmative > "$directory/README.md"

    make nested 'readme = "./docs/PACKAGE.md"'
    uses docs/PACKAGE.md
    mkdir "$directory/docs"
    cp "$directory/Cargo.toml" "$directory/docs/Cargo.toml"
    echo nested > "$directory/docs/PACKAGE.md"
    echo unselected > "$directory/docs/UNRELATED.md"

    for name in disabled disabled_edit; do
      make "$name" "readme = false"
      echo "$name" > "$directory/README.md"
    done

    make inherited 'readme.workspace = true'
    echo not-a-local-declaration > "$directory/README.md"

    make ignored 'readme = "tests/README.md"'
    mkdir "$directory/tests"
    echo not-reopened > "$directory/tests/README.md"
    echo not-reopened > "$directory/tests/other"
    echo unselected > "$directory/README.md"

    make excluded_lock 'readme = "Cargo.lock"'
    echo not-reincluded > "$directory/Cargo.lock"
    echo unselected > "$directory/README.md"

    make traversal 'readme = "../escaped/README.md"'
    mkdir "$out/escaped"
    echo forbidden > "$out/escaped/README.md"
    echo unselected > "$directory/README.md"

    make absolute 'readme = "/etc/README.md"'
    echo unselected > "$directory/README.md"

    make symbolic_leaf 'readme = "README.md"'
    ln -s ../escaped/README.md "$directory/README.md"

    make symbolic_ancestor 'readme = "docs/README.md"'
    ln -s ../escaped "$directory/docs"
    echo unselected > "$directory/README.md"
  '';
  source =
    name:
    packaged {
      src = lib.cleanSourceWith { src = "${fixtures}/${name}"; };
      crateName = "fixture";
      version = "0.1.0";
    };
in
pkgs.runCommand "crate-source-readme" { nativeBuildInputs = [ toolchain ]; } ''
  compile() {
    echo "compile $1 through filtered crate source"
    rustc --edition 2024 --crate-name fixture --crate-type lib "$2/src/lib.rs" -o fixture.rlib
  }
  compile implicit ${source "implicit"}
  compile explicit ${source "explicit"}
  compile affirmative ${source "affirmative"}
  compile nested ${source "nested"}

  test ! -e ${source "implicit"}/UNRELATED.md
  test ! -e ${source "explicit"}/README.md
  test ! -e ${source "explicit"}/UNRELATED.md
  test ! -e ${source "nested"}/docs/UNRELATED.md
  test ! -e ${source "disabled"}/README.md
  test "${source "disabled"}" = "${source "disabled_edit"}"
  test ! -e ${source "inherited"}/README.md
  test ! -e ${source "ignored"}/tests
  test ! -e ${source "ignored"}/README.md
  test ! -e ${source "excluded_lock"}/Cargo.lock
  test ! -e ${source "excluded_lock"}/README.md
  test ! -e ${source "traversal"}/README.md
  test ! -e ${source "absolute"}/README.md
  test ! -L ${source "symbolic_leaf"}/README.md
  test ! -e ${source "symbolic_ancestor"}/README.md
  test -L ${source "symbolic_ancestor"}/docs
  test "$(readlink ${source "symbolic_ancestor"}/docs)" = ../escaped
  echo "readme filtering, containment and unchanged disabled-source identity hold"
  touch "$out"
''
