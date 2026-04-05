{
  description = "nix-apple-sandbox — Hardware-level sandbox for coding agents using Apple Containers + Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = import nixpkgs { inherit system; };

      mkLib = pkgsFor:
        let
          mkSandboxedAgent = import ./lib/mkSandboxedAgent.nix { pkgs = pkgsFor; };
          presets = import ./lib/presets.nix { pkgs = pkgsFor; };
          integrate = import ./lib/integrate.nix { pkgs = pkgsFor; };
        in {
          inherit integrate presets mkSandboxedAgent;
          integrateWith = otherPkgs: import ./lib/integrate.nix { pkgs = otherPkgs; };
          presetsWith = otherPkgs: import ./lib/presets.nix { pkgs = otherPkgs; };
          mkSandboxedAgentWith = otherPkgs: import ./lib/mkSandboxedAgent.nix { pkgs = otherPkgs; };
        };

      exportedLib = mkLib pkgs;
      genericAgentToolbox = exportedLib.presets.mkSandboxedCommand {
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
      };
    in {
      lib.${system} = exportedLib;

      packages.${system}.default = genericAgentToolbox;

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          genericAgentToolbox
          (exportedLib.presets.mkSandboxedShell { })
          pkgs.nixfmt-rfc-style
        ];

        shellHook = ''
          echo ""
          echo "  ┌──────────────────────────────────────────────┐"
          echo "  │  Apple Container Agent Sandbox                │"
          echo "  ├──────────────────────────────────────────────┤"
          echo "  │  nix-apple-sandbox      Any command in VM     │"
          echo "  │  sandboxed-shell        Plain bash in VM      │"
          echo "  └──────────────────────────────────────────────┘"
          echo ""
          echo "  Examples: nix-apple-sandbox -- claude|codex|gemini"
          echo "  Agent can only access: $(pwd)"
          echo ""
        '';
      };
    };
}
