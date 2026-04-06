{
  description = "Example: fromProjectDir auto-detection";

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
          (sandbox.fromProjectDir ./. {
            sshForward = true;
          })
        ];
      };
    };
}
