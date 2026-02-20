{
  buildDotnetModule,
  dotnetCorePackages,
  fetchFromGitHub,
  gitMinimal,
  glibc,
  lib,
  nodejs_20,
  stdenv,
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

  # Root-level NuGet.Config so both the build and fetch-deps can resolve
  # packages from the Azure DevOps private feed (used by Agent.Sdk).
  # The upstream repo only has a NuGet.Config inside src/Agent.Listener/.
  postPatch = ''
    cat > NuGet.Config <<'NUGETEOF'
    <?xml version="1.0" encoding="utf-8"?>
    <configuration>
      <packageSources>
        <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
        <add key="azure-feed" value="https://pkgs.dev.azure.com/mseng/PipelineTools/_packaging/nugetvssprivate/nuget/v3/index.json" />
      </packageSources>
    </configuration>
    NUGETEOF
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
    export HOME=$TMPDIR
    git init
    git config user.email "root@localhost"
    git config user.name "root"
    git add .
    git commit -m "v${finalAttrs.version}"
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

    # Fix config.sh: use Nix-provided ldd, point ldd checks at .NET runtime libs,
    # bypass ldconfig ICU check (Nix guarantees deps are present)
    substituteInPlace $out/lib/azure-pipelines-agent/config.sh \
      --replace-fail 'command -v ldd' 'command -v ${glibc.bin}/bin/ldd' \
      --replace-fail 'ldd ./bin' '${glibc.bin}/bin/ldd ${finalAttrs.dotnet-runtime}/share/dotnet/shared/Microsoft.NETCore.App/${finalAttrs.dotnet-runtime.version}/' \
      --replace-fail './bin/Agent.Listener' "$out/bin/Agent.Listener" \
      --replace-fail '$LDCONFIG -NXv "''${libpath//:/}" 2>&1 | grep libicu >/dev/null 2>&1' 'true'

    # Fix run.sh: use wrapped Agent.Listener binary
    substituteInPlace $out/lib/azure-pipelines-agent/run.sh \
      --replace-fail '"$DIR"/bin/Agent.Listener' "$out/bin/Agent.Listener"

    # Link Nix-provided Node.js for task execution
    mkdir -p $out/lib/externals
    ln -s ${nodejs_20} $out/lib/externals/node20_1

    # Install localization files (required for CLI output strings)
    for dir in src/Misc/layoutbin/*-*; do
      [ -d "$dir" ] && cp -r "$dir" $out/lib/azure-pipelines-agent/
    done

    # Wrapper args for all executables
    makeWrapperArgs+=(
      --run 'export AGENT_ROOT="''${AGENT_ROOT:-"$HOME/.azure-pipelines-agent"}"'
      --run 'mkdir -p "$AGENT_ROOT/_diag"'
      --run 'export AGENT_DIAGLOGPATH="''${AGENT_DIAGLOGPATH:-"$AGENT_ROOT/_diag"}"'
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
    mainProgram = "Agent.Listener";
  };
})
