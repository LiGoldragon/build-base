# The check that the version set generator holds a git crate to one revision
# per version: Cargo.lock fixtures of two repositories lock protos 0.33.0 at
# two revisions, and the generator must refuse, name the crate with each
# revision and the repository at each, and write nothing. Two compatible
# versions of one git crate are refused alike, and one revision shared by
# both repositories is written as that version's revision.
context:
{ generator }:
let
  inherit (context) pkgs;

  lock =
    packages:
    pkgs.writeText "Cargo.lock" (
      "version = 4\n"
      + builtins.concatStringsSep "" (
        map (package: ''

          [[package]]
          name = "protos"
          version = "${package.version}"
          source = "git+https://github.com/LiGoldragon/protos?rev=${package.revision}#${package.revision}"
        '') packages
      )
    );
  first = "c93b598025984f8a73e70aa18b8e8a6fdfdfdfd8";
  second = "4024614f1298bafcce7cb1bf1741005df6b0ef88";
  repositories = packages: ''
    mkdir -p alpha beta
    cp ${lock packages.alpha} alpha/Cargo.lock
    cp ${lock packages.beta} beta/Cargo.lock
  '';
  refuses = name: packages: expected: ''
    mkdir ${name} && cd ${name}
    ${repositories packages}
    if ${generator}/bin/crate-version-set alpha/Cargo.lock beta/Cargo.lock 2> refusal; then
      echo "${name}: the generator accepted the drift" >&2
      exit 1
    fi
    cat refusal
    test ! -e crate-versions.json
    ${expected}
    cd ..
  '';
in
pkgs.runCommand "crate-version-set-one-revision" { } ''
  ${refuses "two-revisions"
    {
      alpha = [ { version = "0.33.0"; revision = first; } ];
      beta = [ { version = "0.33.0"; revision = second; } ];
    }
    ''
      grep -q '^  protos$' refusal
      grep -q '^    0.33.0 c93b598: alpha$' refusal
      grep -q '^    0.33.0 4024614: beta$' refusal
    ''
  }
  ${refuses "compatible-versions"
    {
      alpha = [ { version = "0.33.0"; revision = first; } ];
      beta = [ { version = "0.33.1"; revision = second; } ];
    }
    ''
      grep -q '^    0.33.0 c93b598: alpha$' refusal
      grep -q '^    0.33.1 4024614: beta$' refusal
    ''
  }
  mkdir one-revision && cd one-revision
  ${repositories {
    alpha = [
      { version = "0.32.2"; revision = second; }
      { version = "0.33.0"; revision = first; }
    ];
    beta = [ { version = "0.33.0"; revision = first; } ];
  }}
  ${generator}/bin/crate-version-set alpha/Cargo.lock beta/Cargo.lock
  grep -q '"0.33.0": "${first}"' crate-versions.json
  grep -q '"0.32.2": "${second}"' crate-versions.json
  touch $out
''
