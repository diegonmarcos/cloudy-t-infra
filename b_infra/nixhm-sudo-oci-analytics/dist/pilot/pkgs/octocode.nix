# ╔══════════════════════════════════════════════════════════════════╗
# ║                                                                  ║
# ║   GENERATED FILE — DO NOT EDIT                                   ║
# ║                                                                  ║
# ║   Source : cloudy-t-infra/b_infra/nixhm-sudo-oci-analytics/src/pilot/pkgs/octocode.nix
# ║   Engine : 1_cicd/src/scripts/cloud-ship-nix-homemanager-engine.sh
# ║   Rebuild: ./9_others/build.sh
# ║                                                                  ║
# ║   Manual edits will be overwritten on next build.                ║
# ║                                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝

{ lib, stdenv, fetchurl, autoPatchelfHook, openssl, zstd }:

let
  version = "0.12.2";
  assets = {
    x86_64-linux = {
      # Custom build with --features huggingface (local Jina AI embeddings, no API key)
      url = "https://github.com/diegonmarcos/cloud-infra-desktop/releases/download/octocode-${version}-hf/octocode-${version}-huggingface-x86_64-linux-nixos.tar.gz";
      hash = "sha256:0irb6rirddsazirzwmjw22j3mpskgqw94nc3zzs8mag4i1lzpn3x";
    };
    aarch64-linux = {
      url = "https://github.com/Muvon/octocode/releases/download/${version}/octocode-${version}-aarch64-unknown-linux-musl.tar.gz";
      hash = "sha256:1qkk96xqbsi1jzgrlkgyzsqnzyvfz1nc132cj87ppm1fskylaagg";
    };
  };
  asset = assets.${stdenv.hostPlatform.system} or (throw "octocode: unsupported platform ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "octocode";
  inherit version;

  src = fetchurl {
    inherit (asset) url hash;
  };

  sourceRoot = ".";
  unpackPhase = "tar xf $src";

  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = [ openssl zstd stdenv.cc.cc.lib ];

  installPhase = ''
    mkdir -p $out/bin
    cp octocode $out/bin/
    chmod +x $out/bin/octocode
  '';

  meta = with lib; {
    description = "Semantic code search and indexing tool with local HuggingFace embeddings";
    homepage = "https://github.com/Muvon/octocode";
    license = licenses.mit;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}
