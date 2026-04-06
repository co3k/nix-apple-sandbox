{
  description = "Example: nixPackages integration with nix-apple-sandbox";

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
      projectPackages = with pkgs; [ go gopls postgresql ];
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = projectPackages ++ [
          (sandbox.mkSandboxedClaudeCode {
            nixPackages = projectPackages;
            sshForward = true;
          })
          (sandbox.mkSandboxedShell {
            nixPackages = projectPackages;
          })
        ];
      };
    };
}
