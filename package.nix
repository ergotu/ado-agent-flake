{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  libkrb5,
  zlib,
  icu,
  openssl,
  lttng-ust_2_12,
  git,
}:

let
  version = "4.268.0";

  sources = {
    x86_64-linux = {
      url = "https://download.agent.dev.azure.com/agent/${version}/vsts-agent-linux-x64-${version}.tar.gz";
      hash = "sha256-ACiOE2lrHvDmgXsyt4CrGX9wIv5WACHWISIkr/Wl5BE=";
    };
    aarch64-linux = {
      url = "https://download.agent.dev.azure.com/agent/${version}/vsts-agent-linux-arm64-${version}.tar.gz";
      hash = "sha256-/mA3v8l/a74KOlk6HGA3kLqXkzYmQqmcG2M260N4IUM=";
    };
  };

  currentSource =
    sources.${stdenv.hostPlatform.system}
      or (throw "Unsupported system: ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "azure-pipelines-agent";
  inherit version;

  src = fetchurl {
    inherit (currentSource) url hash;
  };

  sourceRoot = ".";

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];

  buildInputs = [
    stdenv.cc.cc.lib
    libkrb5
    zlib
    icu
    openssl
    lttng-ust_2_12
  ];

  # Libraries loaded via dlopen at runtime
  runtimeDependencies = [
    stdenv.cc.cc.lib
    libkrb5
    zlib
    icu
    openssl
    lttng-ust_2_12
  ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/azure-pipelines-agent
    cp -r . $out/share/azure-pipelines-agent/

    # Remove bundled git — we provide our own via PATH
    rm -rf $out/share/azure-pipelines-agent/externals/git

    mkdir -p $out/bin

    # Wrapper for config.sh
    makeWrapper $out/share/azure-pipelines-agent/config.sh $out/bin/azure-pipelines-agent-config \
      --set AGENT_DISABLEUPDATE 1 \
      --prefix PATH : ${lib.makeBinPath [ git ]}

    # Wrapper for run.sh
    makeWrapper $out/share/azure-pipelines-agent/run.sh $out/bin/azure-pipelines-agent-run \
      --set AGENT_DISABLEUPDATE 1 \
      --prefix PATH : ${lib.makeBinPath [ git ]}

    # Wrapper for env.sh
    makeWrapper $out/share/azure-pipelines-agent/env.sh $out/bin/azure-pipelines-agent-env \
      --set AGENT_DISABLEUPDATE 1 \
      --prefix PATH : ${lib.makeBinPath [ git ]}

    runHook postInstall
  '';

  # The agent ships with its own copy of Node.js in externals/ — let autoPatchelf fix those too
  dontPatchShebangs = false;

  meta = with lib; {
    description = "Azure DevOps Pipelines self-hosted agent";
    homepage = "https://github.com/microsoft/azure-pipelines-agent";
    license = licenses.mit;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    mainProgram = "azure-pipelines-agent-run";
  };
}
