{
  stdenv,
  purs,
  buildSpagoLock,
}: let
  lock = buildSpagoLock.workspaces {
    src = ./.;
    lockfile = ./spago.lock;
  };
in
  stdenv.mkDerivation {
    name = "bin";
    src = ./.;
    buildPhase = ''
      echo ${lock.simple.dependencies.globs}
      touch $out
    '';
    installPhase = ''
      touch $out
    '';
  }