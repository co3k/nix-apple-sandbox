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
      mkTemplate = { path, description, welcomeText }: {
        inherit path description welcomeText;
      };
    in {
      lib.${system} = exportedLib;

      packages.${system}.default = genericAgentToolbox;

      templates = {
        "generic-command" = mkTemplate {
          path = ./examples/generic-command;
          description = "Generic `mkSandboxedCommand` wrapper for `nix-apple-sandbox -- <command>`.";
          welcomeText = ''
            # nix-apple-sandbox generic command template

            Run `nix develop`, then start the sandbox with `nix-apple-sandbox -- claude`.
            The same wrapper also works for `codex`, `gemini`, or any other command you install into the image.
          '';
        };

        "nix-packages" = mkTemplate {
          path = ./examples/nix-packages;
          description = "Project template that maps existing `nixPackages` into the sandbox image.";
          welcomeText = ''
            # nix-apple-sandbox nixPackages template

            Add your project packages to `projectPackages`, then run `nix develop`.
            The sandbox preset reuses that list and maps supported packages into apt automatically.
          '';
        };

        "from-devbox" = mkTemplate {
          path = ./examples/from-devbox;
          description = "Project template that derives sandbox packages from `devbox.json`.";
          welcomeText = ''
            # nix-apple-sandbox fromDevboxJson template

            Edit `devbox.json`, then run `nix develop`.
            The sandbox wrapper reads the declared packages and maps them into the container image.
          '';
        };

        "from-project-dir" = mkTemplate {
          path = ./examples/from-project-dir;
          description = "Project template that auto-detects packages from files in the project directory.";
          welcomeText = ''
            # nix-apple-sandbox fromProjectDir template

            Drop this into an existing repository, then run `nix develop`.
            The sandbox wrapper inspects files like `package.json`, `go.mod`, or `Cargo.toml` and adds matching packages automatically.
          '';
        };

        default = self.templates."generic-command";
      };

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
