{ pkgs ? import <nixpkgs> {} }: with pkgs;

let
  name = "mvnix";
  version = "0.1.0";
  gen-header = "# This file has been generated by ${name} ${version}.";

  default-tmpl = writeText "default-tmpl.nix" ''
    ${gen-header} Configure the build here!
    { pkgs ? import <nixpkgs> { inherit system; }
    , system ? builtins.currentSystem
    , mavenix ? pkgs.callPackage (import ./%%env%%) {}
    }: mavenix {
      src = ./%%src%%;
      infoFile = ./%%info%%;%%settings%%
    }
  '';

  mvnix-init = writeScript "mvnix-init" ''
    #!${bash}/bin/bash
    set -e

    usage() {
      test "$1" && echo -e Error: $1\\n || echo -n
      cat >&2 <<EOF
      Usage: $(basename $0) [OPTIONS] <OUTPUT-NIX-FILE>

      OPTIONS
        --settings|-s <path>    Maven settings.xml file
        --output|-o <dir>       Generated nix files output directory
    EOF
      exit 1
    }

    tmpl() { sed "s|%%$1%%|$2|g"; }

    # Default values
    outputDir="."

    # Parse CLI arguments
    while test $1;do
      case $1 in
        -o|--output) outputDir="$2";shift 2;;
        -s|--settings) settings="$2";shift 2;;
        -d|--debug) set -x;shift;;
        -*) usage;;
        *) config="$1";shift;;
      esac
    done

    mkdir -p "$outputDir"
    config="''${config-$outputDir/default.nix}"
    [ ! -e "$config" ] || usage "\"$config\" already exists"

    test "$settings" && settings="
      settings = ./$(realpath --relative-to="$(dirname $config)" "$settings");"

    relSrc="$(realpath --relative-to="$(dirname $config)" ".")"
    relEnv="$(realpath --relative-to="$(dirname $config)" "$outputDir/mavenix.nix")"
    relInfo="$(realpath --relative-to="$(dirname $config)" "$outputDir/mavenix-info.json")"

    (cat ${default-tmpl} \
    | tmpl src "$relSrc" \
    | tmpl env "$relEnv" \
    | tmpl info "$relInfo" \
    | tmpl settings "$settings"
    ) > "$config"
    cp ${./mavenix.nix} "$outputDir/mavenix.nix"; chmod u+w "$outputDir/mavenix.nix"
    (echo -e '{"name":"","deps":[],"metas":[]}') > "$outputDir/mavenix-info.json"

    echo >&2 "
      Created stubs in '$outputDir'.

      Edit the file '$config'
      To capture dependencies run: 'mvnix-update'
      Then build with: 'nix-build $config -A build'
    "
  '';

  mvnix-update = writeScript "mvnix-update" (''
    #!${bash}/bin/bash
    set -e

    export PATH=${yq}/bin:$PATH

    usage() {
      test "$1" && echo -e Error: $1\\n || echo -n
      cat <<EOF
      Usage: $(basename $0) <NIX-FILE>
    EOF
      exit 1
    }

    # Default values
    config="default.nix"

    # Parse CLI arguments
    while test $1;do
      case $1 in
        -d|--debug) debug=1;set -x;shift;;
        -*) usage;;
        *) config="$1";shift;;
      esac
    done

    eval-env() {
      ${nix}/bin/nix-instantiate 2>&- --eval \
        -E "let env = import \"$(realpath "$config")\" {}; in toString ($1)" \
      | sed 's/^"//;s/"$//'
    }
    build-env() {
      ${nix}/bin/nix-build --no-out-link \
        -E "let env = import \"$(realpath "$config")\" {}; in ($1)"
    }

    initRepo=$(build-env env.emptyRepo)
    output=$(eval-env env.infoFile)
    mvn_path=$(build-env env.maven)/bin/mvn
    settings=$(eval-env env.settings)

    TMP_REPO="$(${mktemp}/bin/mktemp -d --tmpdir mavenix-m2-repo.XXXXXX)"
    cleanup() {
      rm -rf "$TMP_REPO" || echo -n
    }
    trap "trap - TERM; cleanup; kill -- $$" EXIT INT TERM

    cp -rf $initRepo/* $TMP_REPO || true
    chmod -R +w "$TMP_REPO" || echo >&2 Failed to set chmod on temp repo dir.

    mvn_flags="$(test "$debug" && printf %s "-e -X" || true)"
    mvn_() { $mvn_path $mvn_flags -B -nsu --settings "$settings" "$@"; }
    mvn_out() { $mvn_path -B -nsu --settings "$settings" "$@"; }
    export -f mvn_
  '' + (builtins.readFile ./mkinfo.sh));
in runCommand name {} ''
  mkdir -p $out/bin
  ln -s ${mvnix-init} $out/bin/mvnix-init
  ln -s ${mvnix-update} $out/bin/mvnix-update
''
