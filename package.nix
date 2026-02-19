{
  buildDotnetModule,
  dotnetCorePackages,
  fetchFromGitHub,
  gitMinimal,
  glibc,
  lib,
  nodejs_20,
  stdenv,
  buildPackages,
  runtimeShell,
}:

buildDotnetModule (finalAttrs: {
  pname = "azure-pipelines-agent";
  version = "4.268.0";

  src = fetchFromGitHub {
    owner = "microsoft";
    repo = "azure-pipelines-agent";
    tag = "v${finalAttrs.version}";
    hash = "sha256-Cq10gqOlPBTc68beqHZAE6R1vPSJ3A0AqoaCrKuBtIM=";
  };

  patches = [
    ./patches/agent-root-knob.patch
    ./patches/env-sh-use-agent-root.patch
  ];

  # Azure DevOps private feed for azuredevops-testresultparser
  nugetAzureFeed = "https://pkgs.dev.azure.com/mseng/PipelineTools/_packaging/nugetvssprivate/nuget/v3/index.json";

  preConfigure = ''
    if curl --connect-timeout 5 -sS "${finalAttrs.nugetAzureFeed}" > /dev/null 2>&1; then
      dotnet nuget add source "${finalAttrs.nugetAzureFeed}" --name azure-feed
    fi
  '';

  dotnet-sdk = dotnetCorePackages.sdk_8_0;
  dotnet-runtime = dotnetCorePackages.runtime_8_0;
  nugetDeps = ./deps.json;

  projectFile = [
    "src/Microsoft.VisualStudio.Services.Agent/Microsoft.VisualStudio.Services.Agent.csproj"
    "src/Agent.Listener/Agent.Listener.csproj"
    "src/Agent.Worker/Agent.Worker.csproj"
    "src/Agent.PluginHost/Agent.PluginHost.csproj"
    "src/Agent.Sdk/Agent.Sdk.csproj"
    "src/Agent.Plugins/Agent.Plugins.csproj"
  ];

  dotnetFlags = [
    "-p:PackageRuntime=${dotnetCorePackages.systemToDotnetRid stdenv.hostPlatform.system}"
    "-p:TargetFrameworks=net8.0"
  ];

  dotnetInstallFlags = [ "--framework net8.0" ];

  # Git repo needed for GenerateConstant MSBuild target (git rev-parse HEAD)
  unpackPhase = ''
    cp -r $src $TMPDIR/src
    chmod -R +w $TMPDIR/src
    cd $TMPDIR/src
    (
      export PATH=${buildPackages.git}/bin:$PATH
      export HOME=$TMPDIR
      git init
      git config user.email "root@localhost"
      git config user.name "root"
      git add .
      git commit -m "v${finalAttrs.version}"
    )
  '';

  postConfigure = ''
    dotnet msbuild \
      -t:GenerateConstant \
      -p:ContinuousIntegrationBuild=true \
      -p:Deterministic=true \
      -p:PackageRuntime="${dotnetCorePackages.systemToDotnetRid stdenv.hostPlatform.system}" \
      -p:AgentVersion="${finalAttrs.version}" \
      src/dir.proj
  '';

  nativeBuildInputs = [
    gitMinimal
  ];

  postInstall = ''
    # Install shell scripts from layoutroot
    install -m755 src/Misc/layoutroot/config.sh $out/lib/azure-pipelines-agent/
    install -m755 src/Misc/layoutroot/run.sh    $out/lib/azure-pipelines-agent/
    install -m755 src/Misc/layoutroot/env.sh    $out/lib/azure-pipelines-agent/

    # Fix config.sh: use Nix-provided ldd, point ldd checks at .NET runtime libs
    substituteInPlace $out/lib/azure-pipelines-agent/config.sh \
      --replace-fail 'command -v ldd' 'command -v ${glibc.bin}/bin/ldd' \
      --replace-fail 'ldd ./bin' '${glibc.bin}/bin/ldd ${finalAttrs.dotnet-runtime}/share/dotnet/shared/Microsoft.NETCore.App/${finalAttrs.dotnet-runtime.version}/' \
      --replace-fail './bin/Agent.Listener' "$out/bin/Agent.Listener"

    # Bypass ldconfig ICU check (Nix guarantees deps are present)
    substituteInPlace $out/lib/azure-pipelines-agent/config.sh \
      --replace-fail '$LDCONFIG -NXv "''${libpath//:/}" 2>&1 | grep libicu >/dev/null 2>&1' 'true'

    # Fix run.sh: use wrapped Agent.Listener binary
    substituteInPlace $out/lib/azure-pipelines-agent/run.sh \
      --replace-fail '"$DIR"/bin/Agent.Listener' "$out/bin/Agent.Listener"

    # Link Nix-provided Node.js for task execution
    mkdir -p $out/lib/externals
    ln -s ${nodejs_20} $out/lib/externals/node20_1

    # Install localization files (required for CLI output strings)
    cp -r src/Misc/layoutbin/en-US $out/lib/azure-pipelines-agent/
    cp -r src/Misc/layoutbin/de-DE $out/lib/azure-pipelines-agent/
    cp -r src/Misc/layoutbin/es-ES $out/lib/azure-pipelines-agent/
    cp -r src/Misc/layoutbin/fr-FR $out/lib/azure-pipelines-agent/
    cp -r src/Misc/layoutbin/it-IT $out/lib/azure-pipelines-agent/
    cp -r src/Misc/layoutbin/ja-JP $out/lib/azure-pipelines-agent/
    cp -r src/Misc/layoutbin/ko-KR $out/lib/azure-pipelines-agent/
    cp -r src/Misc/layoutbin/ru-RU $out/lib/azure-pipelines-agent/
    cp -r src/Misc/layoutbin/zh-CN $out/lib/azure-pipelines-agent/
    cp -r src/Misc/layoutbin/zh-TW $out/lib/azure-pipelines-agent/

    # Wrapper args for all executables
    makeWrapperArgs+=(
      --run 'export AGENT_ROOT="''${AGENT_ROOT:-"$HOME/.azure-pipelines-agent"}"'
      --run 'mkdir -p "$AGENT_ROOT/_diag"'
      --set-default AGENT_DIAGLOGPATH '$AGENT_ROOT/_diag'
      --set AGENT_DISABLEUPDATE 1
      --prefix PATH : ${lib.makeBinPath [ gitMinimal ]}
    )
  '';

  executables = [
    "config.sh"
    "run.sh"
    "env.sh"
    "Agent.Listener"
    "Agent.Worker"
    "Agent.PluginHost"
  ];

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    export AGENT_ROOT="$TMPDIR"
    version=$($out/bin/Agent.Listener --version)
    if [[ "$version" != "${finalAttrs.version}" ]]; then
      printf 'Unexpected version: %s\n' "$version"
      exit 1
    fi
    runHook postInstallCheck
  '';

  meta = {
    description = "Azure DevOps Pipelines self-hosted agent";
    homepage = "https://github.com/microsoft/azure-pipelines-agent";
    license = lib.licenses.mit;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    sourceProvenance = with lib.sourceTypes; [ fromSource ];
    mainProgram = "run.sh";
  };
})
