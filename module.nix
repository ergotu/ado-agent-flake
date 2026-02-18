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
          default = pkgs.azure-pipelines-agent;
          defaultText = lib.literalExpression "pkgs.azure-pipelines-agent";
          description = "The azure-pipelines-agent package to use.";
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
            This file must be readable by the agent's system user.
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

  mkService = instanceName: inst: {
    description = "Azure DevOps Pipelines Agent (${instanceName})";
    wants = [ "network-online.target" ];
    after = [
      "network.target"
      "network-online.target"
    ];
    wantedBy = [ "multi-user.target" ];

    environment =
      let
        agentDir = "/var/lib/azure-pipelines-agent/${instanceName}";
      in
      {
        AGENT_ROOT = agentDir;
        AGENT_DIAGLOGPATH = "${agentDir}/_diag";
      }
      // inst.extraEnvironment;

    path = [
      inst.package
    ] ++ inst.extraPackages;

    serviceConfig =
      let
        stateDir = "azure-pipelines-agent/${instanceName}";
        workDir = if inst.workDir != null then inst.workDir else "/var/lib/${stateDir}/_work";
        agentDir = "/var/lib/${stateDir}";
        configArgs = lib.concatStringsSep " " (
          [
            "--unattended"
            "--url ${lib.escapeShellArg inst.url}"
            "--auth pat"
            "--token $(cat ${lib.escapeShellArg (toString inst.tokenFile)})"
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
        Type = "simple";
        User = "azure-pipelines-agent";
        Group = "azure-pipelines-agent";
        StateDirectory = stateDir;
        WorkingDirectory = agentDir;

        ExecStartPre = "!${pkgs.writeShellScript "configure-azure-pipelines-agent-${instanceName}" ''
          export AGENT_ROOT="${agentDir}"
          if [ ! -f "${agentDir}/.credentials" ]; then
            mkdir -p "${agentDir}"
            ${inst.package}/bin/config.sh ${configArgs}
          fi
        ''}";

        ExecStart = "${pkgs.writeShellScript "run-azure-pipelines-agent-${instanceName}" ''
          export AGENT_ROOT="${agentDir}"
          exec ${inst.package}/bin/run.sh
        ''}";

        ExecStopPost = lib.mkDefault "";

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
