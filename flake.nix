{
  description = "Wave OS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-ahri.url = "github:NixOS/nixpkgs/7fd4004d0511991fff3a0524856a9be09e28c5f0";
    deploy-rs.url = "github:serokell/deploy-rs/45ba3f8c5cb28396fff71671806e2550b464ac86";
    devenv-nixpkgs.url = "github:NixOS/nixpkgs/7fd4004d0511991fff3a0524856a9be09e28c5f0";
    # Keep the release-tested pin for Darwin's qtkeychain; Linux uses system packages in the home module.
    vicinae = {
      url = "github:vicinaehq/vicinae/v0.29.1";
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

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-flatpak.url = "github:gmodena/nix-flatpak?ref=v0.8.0";

    sqlit = {
      url = "github:Maxteabag/sqlit";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    spotifast = {
      url = "github:crmne/spotifast/v0.13.1";
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
      url = "github:yayuuu/hyprland-scroll-overview/7ff22457dc016239eff1b19c3ea57de93404b5c9";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      nixos-hardware,
      home-manager,
      nix-flatpak,
      nix-darwin,
      determinate,
      ...
    }:
    let
      system = "x86_64-linux";
      darwinSystem = "aarch64-darwin";
      ahriSystem = "aarch64-linux";
      zacSystem = "armv7l-linux";
      packageOverlay =
        final: prev:
        let
          wrapAgentHarness = import ./packages/agent-harness.nix {
            inherit (final) lib makeBinaryWrapper runCommand;
          };
        in
        {
          wave = final.callPackage ./packages/wave.nix {
            deploy-rs =
              inputs.deploy-rs.packages.${final.stdenv.hostPlatform.system}.deploy-rs
                or final.deploy-rs.deploy-rs;
            deployNodes = builtins.attrNames self.deploy.nodes;
          };
          t3code-cli = final.callPackage ./packages/t3code-cli.nix { };
          cliproxyapi = final.callPackage ./packages/cliproxyapi.nix { inherit prev; };
          wave-dashboard = final.callPackage ./packages/wave-dashboard.nix { };
          slack-mirror = final.callPackage ./packages/slack-mirror.nix { };
          slack-mirror-context = final.callPackage ./packages/slack-mirror-context.nix { };
          slack-mirror-image = final.callPackage ./packages/slack-mirror-image.nix {
            context = final.slack-mirror-context;
          };
          opencode = final.callPackage ./packages/opencode-darwin.nix { };
          opencode-rescue = final.callPackage ./packages/opencode-rescue.nix { };
          kanagawa-gtk-theme = final.callPackage ./packages/kanagawa-gtk-theme.nix { };
          openclaw-sandbox-machine-check =
            final.callPackage ./packages/openclaw-sandbox-machine-check.nix
              { };
          openclaw-languagetool-mcp-context =
            final.callPackage ./packages/openclaw-languagetool-mcp-context.nix
              { };
          openclaw-languagetool-mcp-image = final.callPackage ./packages/openclaw-languagetool-mcp-image.nix {
            context = final.openclaw-languagetool-mcp-context;
          };
          openclaw-whisper-model = final.callPackage ./packages/openclaw-whisper-model.nix { };
          anytype-mcp = final.callPackage ./packages/anytype-mcp.nix { };
          substack-mcp = final.callPackage ./packages/substack-mcp.nix { };
          twikit-x-mcp = final.callPackage ./packages/twikit-x-mcp.nix { };
          workspace-mcp = final.callPackage ./packages/workspace-mcp.nix { };
          camofox-browser-source = final.callPackage ./packages/camofox-browser-source.nix { };
          camofox-browser-cli = final.callPackage ./packages/camofox-browser-cli.nix { };
          claude-code = wrapAgentHarness (final.callPackage ./packages/claude-code.nix {
            inherit prev;
          }) "claude-code";
          codex = wrapAgentHarness (final.callPackage ./packages/codex.nix { inherit prev; }) "codex";
        }
        // prev.lib.optionalAttrs prev.stdenv.hostPlatform.isLinux {
          t3code-desktop = final.callPackage ./packages/t3code-desktop.nix { };
          sendspin-player = final.callPackage ./packages/sendspin-player.nix { };
          pr-cockpit = final.callPackage ./packages/pr-cockpit.nix { };
          spotifast = final.callPackage ./packages/spotifast.nix {
            spotifast = inputs.spotifast.packages.${final.stdenv.hostPlatform.system}.default;
          };
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
          browser-decision = final.callPackage ./packages/browser-decision.nix { };
        };
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [ packageOverlay ];
      };
      darwinPkgs = import nixpkgs {
        system = darwinSystem;
        config.allowUnfree = true;
        overlays = [ packageOverlay ];
      };
      ahriPkgs = import inputs.nixpkgs-ahri {
        system = ahriSystem;
        overlays = [ packageOverlay ];
      };
      zacPkgs = import nixpkgs {
        localSystem = system;
        crossSystem = nixpkgs.lib.systems.examples.armv7l-hf-multiplatform;
        config.allowUnfree = true;
        overlays = [
          inputs.deploy-rs.overlays.default
          packageOverlay
          (_: prev: {
            # rdma-core does not cross-compile (CMake rejects the build Python), and no RDMA hardware exists here.
            libpcap = prev.libpcap.override { withRdma = false; };
            # GCC rejects opus's NEON intrinsics for this target's baseline FPU, which lacks NEON.
            opus = prev.opus.overrideAttrs (old: {
              cmakeFlags = old.cmakeFlags or [ ] ++ [ "-DOPUS_DISABLE_INTRINSICS=ON" ];
            });
          })
        ];
      };
      kanagawa-kvantum = pkgs.callPackage ./packages/kanagawa-kvantum.nix {
        src = inputs.kanagawa-kvantum;
      };
      renektonNode = import ./tools/deploy-node.nix {
        pkgs = darwinPkgs;
        deployLib = inputs.deploy-rs.lib.${darwinSystem};
        configuration = self.darwinConfigurations.renekton;
        hostname = "renekton";
      };
      ahriNode = import ./tools/deploy-node.nix {
        pkgs = ahriPkgs;
        deployLib = inputs.deploy-rs.lib.${ahriSystem};
        configuration = self.nixosConfigurations.ahri;
        hostname = "ahri";
      };
      zileanNode = import ./tools/deploy-node.nix {
        inherit pkgs;
        deployLib = inputs.deploy-rs.lib.${system};
        configuration = self.nixosConfigurations.zilean;
        hostname = "zilean";
      };
      zacNode = import ./tools/deploy-node.nix {
        pkgs = zacPkgs;
        deployLib = zacPkgs.deploy-rs.lib;
        configuration = self.nixosConfigurations.zac;
        hostname = "zac";
      };
    in
    {
      # TODO: Generated manuals remain enabled despite Determinate Nix's contextless options.json warning.
      # Remove this note after NixOS/nixpkgs#485682, nix-community/home-manager#8942,
      # and a matching nix-darwin fix land.
      nixosConfigurations = {
        jayce = nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs.waveRevision = self.rev or "unknown";
          modules = [
            nixos-hardware.nixosModules.framework-16-7040-amd
            inputs.vicinae.nixosModules.default
            inputs.sops-nix.nixosModules.sops
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

        ahri = inputs.nixpkgs-ahri.lib.nixosSystem {
          system = ahriSystem;
          specialArgs = {
            inherit inputs;
            waveRevision = self.rev or "unknown";
          };
          modules = [
            inputs.sops-nix.nixosModules.sops
            ./hosts/ahri/default.nix
            (_: { nixpkgs.pkgs = ahriPkgs; })
          ];
        };

        zilean = nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs.waveRevision = self.rev or "unknown";
          modules = [
            inputs.sops-nix.nixosModules.sops
            home-manager.nixosModules.home-manager
            ./hosts/zilean/default.nix
            (_: { nixpkgs.pkgs = pkgs; })
            (_: {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                extraSpecialArgs = { inherit inputs; };
                users.kosciak = ./hosts/zilean/home.nix;
              };
            })
          ];
        };

        zac = nixpkgs.lib.nixosSystem {
          system = zacSystem;
          specialArgs.waveRevision = self.rev or "unknown";
          modules = [
            ./hosts/zac/default.nix
            (_: { nixpkgs.pkgs = zacPkgs; })
          ];
        };

      };

      darwinConfigurations.renekton = nix-darwin.lib.darwinSystem {
        system = darwinSystem;
        specialArgs.waveRevision = self.rev or "unknown";
        modules = [
          determinate.darwinModules.default
          home-manager.darwinModules.home-manager
          (import ./modules/sops-darwin.nix {
            inherit (nixpkgs) lib;
            inherit (inputs) sops-nix;
          })
          ./hosts/renekton/default.nix
          (_: {
            nixpkgs.overlays = [ packageOverlay ];
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

      packages = {
        ${system} = {
          deploy-rs = inputs.deploy-rs.packages.${system}.deploy-rs;
          zac-cache = pkgs.linkFarm "zac-cache" [
            {
              name = "system";
              path = zacNode.profiles.system.path;
            }
            {
              name = "image";
              path = self.nixosConfigurations.zac.config.system.build.sdImage;
            }
            {
              name = "player-check";
              path = pkgs.sendspin-player;
            }
          ];
          inherit kanagawa-kvantum;
          inherit (pkgs)
            wave
            camofox-browser-cli
            slack-mirror
            slack-mirror-context
            slack-mirror-image
            spotifast
            pr-cockpit
            t3code-cli
            t3code-desktop
            ;
        };
        ${darwinSystem} = {
          deploy-rs = inputs.deploy-rs.packages.${darwinSystem}.deploy-rs;
          inherit (darwinPkgs)
            wave
            openclaw-sandbox-machine-check
            t3code-cli
            slack-mirror
            slack-mirror-context
            slack-mirror-image
            openclaw-languagetool-mcp-context
            openclaw-languagetool-mcp-image
            openclaw-whisper-model
            anytype-mcp
            substack-mcp
            twikit-x-mcp
            workspace-mcp
            camofox-browser-source
            browser-decision
            camofox-browser-cli
            ;
        };
        ${ahriSystem} = {
          deploy-rs = inputs.deploy-rs.packages.${ahriSystem}.deploy-rs;
          inherit (ahriPkgs) wave;
        };
      };
      deploy.nodes = {
        renekton = renektonNode;
        ahri = ahriNode;
        zilean = zileanNode;
        zac = zacNode;
      };
      checks = {
        ${system} =
          let
            configuration = self.nixosConfigurations.jayce.config;
            home = configuration.home-manager.users.kosciak;
          in
          {
            quickshell = home.programs.quickshell.package;
            hyprland = configuration.programs.hyprland.package;
          };
        ${darwinSystem} = inputs.deploy-rs.lib.${darwinSystem}.deployChecks {
          nodes.renekton = renektonNode;
        };
        ${ahriSystem} = inputs.deploy-rs.lib.${ahriSystem}.deployChecks {
          nodes.ahri = ahriNode;
        };
      };
    };
}
