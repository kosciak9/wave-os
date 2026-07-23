{
  description = "Wave OS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    determinate = {
      url = "https://flakehub.com/f/DeterminateSystems/determinate/3";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
      nix-darwin,
      determinate,
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
      kanagawa-kvantum = pkgs.callPackage ./packages/kanagawa-kvantum.nix {
        src = inputs.kanagawa-kvantum;
      };
    in
    {
      # TODO: Generated manuals remain enabled despite Determinate Nix's contextless options.json warning.
      # Remove this note after NixOS/nixpkgs#485682, nix-community/home-manager#8942,
      # and a matching nix-darwin fix land.
      nixosConfigurations.jayce = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          nixos-hardware.nixosModules.framework-16-7040-amd
          ./hosts/jayce/default.nix
          home-manager.nixosModules.home-manager
          ({ ... }:
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.extraSpecialArgs = {
                inherit inputs kanagawa-kvantum;
              };
              home-manager.sharedModules = [ sops-nix.homeManagerModules.sops ];
              home-manager.users.kosciak = ./hosts/jayce/home.nix;
            })
        ];
      };

      darwinConfigurations.renekton = nix-darwin.lib.darwinSystem {
        system = darwinSystem;
        modules = [
          determinate.darwinModules.default
          home-manager.darwinModules.home-manager
          ./hosts/renekton/default.nix
          ({ ... }:
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.kosciak = ./hosts/renekton/home.nix;
            })
        ];
      };

      homeConfigurations."kosciak@jayce" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = {
          inherit inputs kanagawa-kvantum;
        };
        modules = [
          sops-nix.homeManagerModules.sops
          ./hosts/jayce/home.nix
        ];
      };

      homeConfigurations."kosciak@renekton" = home-manager.lib.homeManagerConfiguration {
        pkgs = darwinPkgs;
        modules = [
          ./hosts/renekton/home.nix
        ];
      };

      packages.${system}.kanagawa-kvantum = kanagawa-kvantum;
    };
}
