{
  description = "Wave OS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    devenv-nixpkgs.url = "github:NixOS/nixpkgs/34ab99075ac4f7e40cf037eef32cb1c360bb85e9";
    # Vicinae intentionally keeps its release-tested Nixpkgs pin; following repository Nixpkgs triggers the known qtkeychain Darwin ld64 crash.
    vicinae = {
      url = "github:vicinaehq/vicinae/v0.27.5";
    };
    vicinae-extensions = {
      url = "github:vicinaehq/extensions";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.vicinae.follows = "vicinae";
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

    nix-openclaw = {
      url = "github:kosciak9/nix-openclaw/2d5a1169afe5b495e66f32fed5896f186a537913";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    nix-flatpak.url = "github:gmodena/nix-flatpak?ref=v0.7.0";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sqlit = {
      url = "github:Maxteabag/sqlit";
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

    hyprland-scroll-overview = {
      url = "github:yayuuu/hyprland-scroll-overview/f9248ab6bee770e9d68813b48cc6ca12b3271254";
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
      packageOverlay =
        final: prev:
        {
          plannotator = final.callPackage ./packages/plannotator.nix { };
          opencode = final.callPackage ./packages/opencode-darwin.nix { };
          kanagawa-gtk-theme = final.callPackage ./packages/kanagawa-gtk-theme.nix { };
          openclaw-sandbox-context = final.callPackage ./packages/openclaw-sandbox-context.nix { };
          openclaw-embeddinggemma = final.callPackage ./packages/openclaw-embeddinggemma.nix { };
          openclaw-llama-server = final.callPackage ./packages/openclaw-llama-server.nix { };
          anytype-mcp = final.callPackage ./packages/anytype-mcp.nix { };
          substack-mcp = final.callPackage ./packages/substack-mcp.nix { };
          camofox-browser-source = final.callPackage ./packages/camofox-browser-source.nix { };
          camofox-openclaw-plugin = final.callPackage ./packages/camofox-openclaw-plugin.nix { };
          openclawRuntimePlugins = (prev.openclawRuntimePlugins or { }) // {
            "camofox-browser" = final.camofox-openclaw-plugin;
          };
        }
        // prev.lib.optionalAttrs prev.stdenv.hostPlatform.isLinux {
          wave-hyprland = prev.hyprland.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [ ./hosts/jayce/desktop/hyprland-niri-parity.patch ];
          });
          hyprland-scroll-overview = final.callPackage ./packages/hyprland-scroll-overview.nix {
            src = inputs.hyprland-scroll-overview;
            hyprland = final.wave-hyprland;
            version = inputs.hyprland-scroll-overview.shortRev or "unstable";
          };
        }
        // prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
          mac-apps-mcp-host = final.callPackage ./packages/mac-apps-mcp-host.nix { };
          mac-apps-mcp-server = final.callPackage ./packages/mac-apps-mcp-server.nix { };
          openclawPackages = prev.openclawPackages // {
            openclaw-app = prev.openclawPackages.openclaw-app.overrideAttrs (_: {
              dontFixup = true;
            });
          };
        };
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [ packageOverlay ];
      };
      darwinPkgs = import nixpkgs {
        system = darwinSystem;
        config.allowUnfree = true;
        overlays = [
          inputs.nix-openclaw.overlays.default
          packageOverlay
        ];
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
          inputs.vicinae.nixosModules.default
          ./hosts/jayce/default.nix
          home-manager.nixosModules.home-manager
          (_: { nixpkgs.overlays = [ packageOverlay ]; })
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
          (
            { config, ... }:
            {
              programs.vicinae.input-server.package = config.home-manager.users.kosciak.programs.vicinae.package;
            }
          )
        ];
      };

      darwinConfigurations.renekton = nix-darwin.lib.darwinSystem {
        system = darwinSystem;
        modules = [
          determinate.darwinModules.default
          home-manager.darwinModules.home-manager
          inputs.nix-openclaw.darwinModules.openclaw
          ./hosts/renekton/default.nix
          (_: {
            nixpkgs.overlays = [
              inputs.nix-openclaw.overlays.default
              packageOverlay
            ];
          })
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
          inputs.nix-openclaw.homeManagerModules.openclaw
          ./hosts/renekton/home.nix
        ];
      };

      packages.${system}.kanagawa-kvantum = kanagawa-kvantum;
      packages.${darwinSystem} = {
        inherit (darwinPkgs)
          openclaw-sandbox-context
          openclaw-embeddinggemma
          openclaw-llama-server
          anytype-mcp
          substack-mcp
          camofox-browser-source
          camofox-openclaw-plugin
          ;
      };
    };
}
