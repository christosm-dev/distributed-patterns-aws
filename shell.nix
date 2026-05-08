{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    jq
    curl
  ];

  shellHook = ''
    if [ ! -d .venv ]; then
      python -m venv .venv
    fi
    source .venv/bin/activate
    pip install awscli awscli-local aws-sam-cli --quiet
    echo "Start LocalStack: cd localstack && docker compose up -d"
  '';
}
