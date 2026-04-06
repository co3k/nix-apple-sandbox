{
  description = "Example: Generic command wrapper with mkSandboxedCommand";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    apple-sandbox = {
      url = "github:co3k/nix-apple-sandbox";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, apple-sandbox, ... }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      sandbox = apple-sandbox.lib.${system}.integrateWith pkgs;
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          (sandbox.mkSandboxedCommand {
            extraAptPackages = [ "nodejs" "npm" ];
            extraAllowedDomains = [ "api.openai.com" "generativelanguage.googleapis.com" ];
            installCommands = ''
              RUN npm install -g @anthropic-ai/claude-code @openai/codex @google/gemini-cli
            '';
            autoPassEnvByCommand = {
              claude = [ "ANTHROPIC_API_KEY" ];
              codex = [ "OPENAI_API_KEY" ];
              gemini = [ "GEMINI_API_KEY" "GOOGLE_API_KEY" ];
            };
            homeMounts = [ ".claude" ".agents" ];
            sshForward = true;
          })
        ];
      };
    };
}
