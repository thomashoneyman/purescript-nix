{
  system,
  fetchurl,
  lib,
  callPackage,
  ncurses,
}: let
  version = "0.15.9";

  # produced with nix-prefetch-url then nix hash to-sri --type sha256 <hash>
  urls = {
    "x86_64-linux" = {
      url = "https://github.com/purescript/purescript/releases/download/v${version}/linux64.tar.gz";
      hash = "sha256-A8v0N75PGMT4fP9v3gUnm4ZmZDz7D+BM0As1TaeNS2U=";
    };
    "x86_64-darwin" = {
      url = "https://github.com/purescript/purescript/releases/download/v${version}/macos.tar.gz";
      hash = "sha256-LuGl4ChXbbs+6dz46++3kHjfgot8NT6OS5EeR3M6r/c=";
    };
    "aarch64-darwin" = {
      url = "https://github.com/purescript/purescript/releases/download/v${version}/macos-arm64.tar.gz";
      hash = "sha256-Sni8ez6TPPcqYvRhmD/HjAiTfBJB/mC9rR/w/K4RkZk=";
    };
  };

  src =
    if builtins.hasAttr system urls
    then (fetchurl urls.${system})
    else if system == "aarch64-darwin"
    then let
      arch = "x86_64-darwin";
      msg = "Using the non-native ${arch} binary. While this binary may run under Rosetta 2 translation, no guarantees can be made about stability or performance.";
    in
      lib.warn msg (fetchurl urls.${arch})
    else throw "Architecture not supported: ${system}";
in
  callPackage ./mkPurs.nix {
    inherit version src ncurses;
  }
