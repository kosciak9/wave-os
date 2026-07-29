{
  description = "Wave OS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Vicinae intentionally keeps its release-tested Nixpkgs pin; following repository Nixpkgs triggers the known qtkeychain Darwin ld64 crash.
    vicinae = {
      url = "github:vicinaehq/vicinae/v0.24.0";
    };
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

    nix-flatpak.url = "github:gmodena/nix-flatpak?ref=v0.7.0";

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

    ghostty-cursor-shaders = {
      url = "github:sahaj-b/ghostty-cursor-shaders";
      flake = false;
    };
  };

  outputs =
    inputs@{
      nixpkgs,
      nixos-hardware,
      home-manager,
      nix-flatpak,
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
      darwinOpencodeOverlay = final: _prev: {
        opencode = final.callPackage ./packages/opencode-darwin.nix { };
      };
      darwinPkgs = import nixpkgs {
        system = darwinSystem;
        config.allowUnfree = true;
        overlays = [ darwinOpencodeOverlay ];
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
          (_: {
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              extraSpecialArgs = {
                inherit inputs kanagawa-kvantum;
                ghosttyCursorShaders = inputs.ghostty-cursor-shaders;
              };
              sharedModules = [
                sops-nix.homeManagerModules.sops
                nix-flatpak.homeManagerModules.nix-flatpak
              ];
              users.kosciak = ./hosts/jayce/home.nix;
            };
          })
        ];
      };

      darwinConfigurations.renekton = nix-darwin.lib.darwinSystem {
        system = darwinSystem;
        modules = [
          determinate.darwinModules.default
          home-manager.darwinModules.home-manager
          ./hosts/renekton/default.nix
          (_: { nixpkgs.overlays = [ darwinOpencodeOverlay ]; })
          (_: {
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              extraSpecialArgs = {
                inherit inputs;
                ghosttyCursorShaders = inputs.ghostty-cursor-shaders;
              };
              users.kosciak = ./hosts/renekton/home.nix;
            };
          })
        ];
      };

      homeConfigurations."kosciak@jayce" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = {
          inherit inputs kanagawa-kvantum;
          ghosttyCursorShaders = inputs.ghostty-cursor-shaders;
        };
        modules = [
          sops-nix.homeManagerModules.sops
          nix-flatpak.homeManagerModules.nix-flatpak
          ./hosts/jayce/home.nix
        ];
      };

      homeConfigurations."kosciak@renekton" = home-manager.lib.homeManagerConfiguration {
        pkgs = darwinPkgs;
        extraSpecialArgs = {
          inherit inputs;
          ghosttyCursorShaders = inputs.ghostty-cursor-shaders;
        };
        modules = [
          ./hosts/renekton/home.nix
        ];
      };

      packages.${system}.kanagawa-kvantum = kanagawa-kvantum;
    };
}
