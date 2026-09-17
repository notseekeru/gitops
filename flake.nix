{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-infisical.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
  };

  outputs = { self, nixpkgs, nixpkgs-infisical }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
      infisical = nixpkgs-infisical.legacyPackages.${system}.infisical;
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [
          infisical
        ] ++ (with pkgs; [
          kubectl
          terraform
          argocd
          aws-nuke
        ]);
      };
    };
}

