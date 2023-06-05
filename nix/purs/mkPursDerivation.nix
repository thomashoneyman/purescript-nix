{
  system,
  stdenv,
  lib,
  zlib,
  gmp,
  fetchurl,
  ncurses5,
}: {
  version,
  tarballs,
}: let
  dynamic-linker = stdenv.cc.bintools.dynamicLinker;

  patchelf = libPath:
    if stdenv.isDarwin
    then ""
    else ''
      chmod u+w $PURS
      patchelf --interpreter ${dynamic-linker} --set-rpath ${libPath} $PURS
      chmod u-w $PURS
    '';
in
  stdenv.mkDerivation rec {
    pname = "purs";
    inherit version;

    needsRosetta = !(builtins.hasAttr system tarballs) && system == "aarch64-darwin";

    src =
      if builtins.hasAttr system tarballs
      then (fetchurl tarballs.${system})
      else if system == "aarch64-darwin"
      then let
        substitute = "x86_64-darwin";
        msg = "This system is an aarch64-darwin, which is not supported. Falling back to the ${substitute} binary, which may run under Rosetta 2 translation.";
      in
        lib.warn msg (fetchurl tarballs.${substitute})
      else throw "Architecture not supported: ${system}";

    buildInputs = [zlib gmp ncurses5];
    libPath = lib.makeLibraryPath buildInputs;
    dontStrip = true;

    installPhase = ''
      mkdir -p $out/bin
      PURS="$out/bin/purs"
      install -D -m555 -T purs $PURS
      ${patchelf libPath}
      mkdir -p $out/etc/bash_completion.d/
      $PURS --bash-completion-script $PURS > $out/etc/bash_completion.d/purs-completion.bash
    '';

    meta = with lib; {
      description = "Compiler for a strongly-typed language that compiles to JavaScript";
      homepage = "https://github.com/purescript/purescript";
    };
  }
