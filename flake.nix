{
  description = "Wave OS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware = {
      url = "github:NixOS/nixos-hardware";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zen-browser = {
      url = "github:youwen5/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    kanagawa-kvantum = {
      url = "github:LuDreamst/Kanagawa-Kvantum";
      flake = false;
    };
  };

  outputs =
    inputs@{
      nixpkgs,
      nixos-hardware,
      home-manager,
      sops-nix,
      ...
    }:
    let
      system = "x86_64-linux";
      darwinSystem = "aarch64-darwin";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      darwinPkgs = import nixpkgs {
        system = darwinSystem;
        config.allowUnfree = true;
      };
      kanagawa-kvantum = pkgs.stdenvNoCC.mkDerivation {
        pname = "kanagawa-kvantum";
        version = "0-unstable-2026-02-10";
        src = inputs.kanagawa-kvantum;
        installPhase = ''
          runHook preInstall
          mkdir -p "$out/share/Kvantum"
          cp -r Kanagawa "$out/share/Kvantum/"
          runHook postInstall
        '';
      };
    in
    {
      nixosConfigurations.jayce = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          nixos-hardware.nixosModules.framework-16-7040-amd
          ./hosts/jayce/configuration.nix
        ];
      };

      homeConfigurations."kosciak@jayce" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = {
          inherit inputs kanagawa-kvantum;
        };
        modules = [
          sops-nix.homeManagerModules.sops
          ./home/kosciak.nix
        ];
      };

      homeConfigurations."kosciak@renekton" = home-manager.lib.homeManagerConfiguration {
        pkgs = darwinPkgs;
        modules = [
          ./home/neovim.nix
          {
            home.username = "kosciak";
            home.homeDirectory = "/Users/kosciak";
            home.stateVersion = "26.05";
            programs.home-manager.enable = true;
            xdg.enable = true;
          }
        ];
      };

      packages.${system}.kanagawa-kvantum = kanagawa-kvantum;
    };
}
