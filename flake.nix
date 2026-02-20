{
  description = "Azure DevOps Pipelines self-hosted agent for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, ... }:
        {
          packages = rec {
            azure-pipelines-agent = pkgs.callPackage ./package.nix { };
            default = azure-pipelines-agent;
          };
        };

      flake = {
        nixosModules.default = import ./module.nix inputs;

        overlays.default = _final: prev: {
          azure-pipelines-agent = prev.callPackage ./package.nix { };
        };
      };
    };
}
