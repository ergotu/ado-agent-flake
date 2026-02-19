{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.azure-pipelines-agent;

  instanceModule =
    { name, config, ... }:
    {
      options = {
        enable = lib.mkEnableOption "Azure DevOps Pipelines agent instance '${name}'";

        package = lib.mkOption {
          type = lib.types.package;
          description = "The azure-pipelines-agent package to use. Must be provided from this flake.";
          example = lib.literalExpression "inputs.ado-agent-flake.packages.\${pkgs.system}.azure-pipelines-agent";
        };

        url = lib.mkOption {
          type = lib.types.str;
          description = "Azure DevOps organization URL (e.g. `https://dev.azure.com/myorg`).";
          example = "https://dev.azure.com/myorg";
        };

        pool = lib.mkOption {
          type = lib.types.str;
          default = "Default";
          description = "Agent pool name.";
        };

        tokenFile = lib.mkOption {
          type = lib.types.path;
          description = ''
            Path to a file containing the Personal Access Token (PAT) for authentication.
            The file only needs to be readable by root — systemd's `LoadCredential`
            securely passes it to the service.
            The file should not be in the Nix store to protect the secret.
          '';
          example = "/run/secrets/azure-pipelines-token";
        };

        name = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Agent name as registered in Azure DevOps. Defaults to the instance name.";
        };

        workDir = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Work directory path. Defaults to `_work` inside the agent's state directory.
          '';
        };

        replace = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Replace an existing agent with the same name during registration.";
        };

        extraPackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
          description = "Additional packages to make available in the agent's PATH (e.g. docker, nodejs).";
          example = lib.literalExpression "[ pkgs.docker pkgs.nodejs ]";
        };

        extraEnvironment = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = "Additional environment variables to set for the agent service.";
          example = lib.literalExpression ''
            {
              DOTNET_CLI_TELEMETRY_OPTOUT = "1";
            }
          '';
        };
      };
    };

  enabledInstances = lib.filterAttrs (_: inst: inst.enable) cfg.instances;

  mkService =
    instanceName: inst:
    let
      stateDir = "azure-pipelines-agent/${instanceName}";
      agentDir = "/var/lib/${stateDir}";
      workDir = if inst.workDir != null then inst.workDir else "${agentDir}/_work";
      configArgs = lib.concatStringsSep " " (
        [
          "--unattended"
          "--url ${lib.escapeShellArg inst.url}"
          "--auth pat"
          "--token $(cat \"$CREDENTIALS_DIRECTORY/token\")"
          "--pool ${lib.escapeShellArg inst.pool}"
          "--agent ${lib.escapeShellArg inst.name}"
          "--work ${lib.escapeShellArg workDir}"
          "--disableupdate"
          "--acceptTeeEula"
        ]
        ++ lib.optional inst.replace "--replace"
      );
    in
    {
      description = "Azure DevOps Pipelines Agent (${instanceName})";
      wants = [ "network-online.target" ];
      after = [
        "network.target"
        "network-online.target"
      ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        AGENT_ROOT = agentDir;
      } // inst.extraEnvironment;

      path = [
        inst.package
      ] ++ inst.extraPackages;

      serviceConfig = {
        Type = "simple";
        User = "azure-pipelines-agent";
        Group = "azure-pipelines-agent";
        StateDirectory = stateDir;
        WorkingDirectory = agentDir;
        LoadCredential = "token:${toString inst.tokenFile}";

        ExecStartPre = "${pkgs.writeShellScript "configure-azure-pipelines-agent-${instanceName}" ''
          mkdir -p ${lib.escapeShellArg workDir}
          if [ ! -f "${agentDir}/.credentials" ]; then
            ${inst.package}/bin/config.sh ${configArgs}
          fi
        ''}";

        ExecStart = "${inst.package}/bin/run.sh";

        Restart = "always";
        RestartSec = 5;

        # Hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [
          agentDir
          workDir
        ];
      };
    };

in
{
  options.services.azure-pipelines-agent = {
    instances = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule instanceModule);
      default = { };
      description = "Azure DevOps Pipelines agent instances.";
    };
  };

  config = lib.mkIf (enabledInstances != { }) {
    users.users.azure-pipelines-agent = {
      isSystemUser = true;
      group = "azure-pipelines-agent";
      home = "/var/lib/azure-pipelines-agent";
    };

    users.groups.azure-pipelines-agent = { };

    systemd.services = lib.mapAttrs' (
      instanceName: inst:
      lib.nameValuePair "azure-pipelines-agent-${instanceName}" (mkService instanceName inst)
    ) enabledInstances;
  };
}
