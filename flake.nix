# flake.nix
# Development environment for distributed-patterns-aws.
# Manages all dependencies via Nix - no venv or pip required.
# Usage: direnv allow (auto-activates on cd)
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Python environment with all required packages
      python = pkgs.python312.withPackages (ps: with ps; [
        boto3            # AWS SDK
      ]);

    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          python
          pkgs.jq
          pkgs.curl
          pkgs.aws-sam-cli   # SAM CLI
          pkgs.awscli2       # AWS CLI (system level)
        ];

        shellHook = ''
          echo "Start LocalStack: cd localstack && docker compose up -d"
        '';
      };
    };
}
