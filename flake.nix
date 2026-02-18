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
      ];

      perSystem =
        { pkgs, system, ... }:
        {
          packages = {
            azure-pipelines-agent = pkgs.callPackage ./package.nix { };
            default = pkgs.callPackage ./package.nix { };
          };
        };

      flake = {
        nixosModules.default = import ./module.nix;
      };
    };
}
