{
  description = "Wave OS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-ahri.url = "github:NixOS/nixpkgs/825e2028c29b702a4a5f085f08095d12099784f2";
    herdr = {
      url = "github:jerryfane/herdr/6e165d6e9111a8b4863c26d627c49441a22528f9";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    herdr-gpui = {
      url = "github:penso/herdr-gpui/v20261008.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    herdr-worktrunk = {
      url = "github:devashish2203/herdr-worktrunk/f9df9ba700b8a4f4d97ddfe3ea3eb345e80b880b";
      flake = false;
    };
    herdr-auto-title = {
      url = "github:kryptamine/herdr-auto-title/9de68183c8a95141871cd3c0eff0c5be4e3fc6af";
      flake = false;
    };
    deploy-rs.url = "github:serokell/deploy-rs/cf64c8cbadd9b13ea79ba7720aa2930500f2ece7";
    devenv-nixpkgs.url = "github:NixOS/nixpkgs/e7439b6b14ad3cc35d05608ebca9bce01a25f5f8";
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

    nix-openclaw = {
      url = "github:openclaw/nix-openclaw/f62d33f760bcbdbc6a52ac589eae22bf99201f90";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    nix-flatpak.url = "github:gmodena/nix-flatpak?ref=v0.7.0";

    sqlit = {
      url = "github:Maxteabag/sqlit";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    spotifast = {
      url = "github:crmne/spotifast/v0.12.0";
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
      url = "github:yayuuu/hyprland-scroll-overview/10eeefa0519e09992b68a1d2949781a876230f5c";
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
      packageOverlay =
        final: prev:
        let
          wrapAgentHarness = import ./packages/agent-harness.nix {
            inherit (final) lib makeBinaryWrapper runCommand;
          };
        in
        {
          wave = final.callPackage ./packages/wave.nix {
            deploy-rs = inputs.deploy-rs.packages.${final.stdenv.hostPlatform.system}.deploy-rs;
          };
          herdr-auto-title = final.callPackage ./packages/herdr-auto-title.nix {
            src = inputs.herdr-auto-title;
          };
          plannotator = final.callPackage ./packages/plannotator.nix { };
          wave-dashboard = final.callPackage ./packages/wave-dashboard.nix { };
          slack-mirror = final.callPackage ./packages/slack-mirror.nix { };
          slack-mirror-context = final.callPackage ./packages/slack-mirror-context.nix { };
          slack-mirror-image = final.callPackage ./packages/slack-mirror-image.nix {
            context = final.slack-mirror-context;
          };
          opencode = final.callPackage ./packages/opencode-darwin.nix { };
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
          openclaw-embeddinggemma = final.callPackage ./packages/openclaw-embeddinggemma.nix { };
          openclaw-whisper-model = final.callPackage ./packages/openclaw-whisper-model.nix { };
          openclaw-llama-server = final.callPackage ./packages/openclaw-llama-server.nix { };
          anytype-mcp = final.callPackage ./packages/anytype-mcp.nix { };
          substack-mcp = final.callPackage ./packages/substack-mcp.nix { };
          workspace-mcp = final.callPackage ./packages/workspace-mcp.nix { };
          camofox-browser-source = final.callPackage ./packages/camofox-browser-source.nix { };
          camofox-browser-cli = final.callPackage ./packages/camofox-browser-cli.nix { };
          claude-code = wrapAgentHarness (final.callPackage ./packages/claude-code.nix {
            inherit prev;
          }) "claude-code";
          codex = wrapAgentHarness (final.callPackage ./packages/codex.nix { inherit prev; }) "codex";
          antigravity-cli = wrapAgentHarness (final.callPackage ./packages/antigravity-cli.nix {
            inherit prev;
          }) "antigravity";
        }
        // prev.lib.optionalAttrs prev.stdenv.hostPlatform.isLinux {
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
          asr-benchmark = final.callPackage ./packages/asr-benchmark.nix { };
          browser-decision = final.callPackage ./packages/browser-decision.nix { };
          camofox-openclaw-plugin = final.callPackage ./packages/camofox-openclaw-plugin.nix { };
          openclawRuntimePlugins = (prev.openclawRuntimePlugins or { }) // {
            "camofox-browser" = final.camofox-openclaw-plugin;
          };
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
      ahriPkgs = import inputs.nixpkgs-ahri {
        system = ahriSystem;
        overlays = [ packageOverlay ];
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
    in
    {
      # TODO: Generated manuals remain enabled despite Determinate Nix's contextless options.json warning.
      # Remove this note after NixOS/nixpkgs#485682, nix-community/home-manager#8942,
      # and a matching nix-darwin fix land.
      nixosConfigurations.jayce = nixpkgs.lib.nixosSystem {
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

      nixosConfigurations.ahri = inputs.nixpkgs-ahri.lib.nixosSystem {
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

      darwinConfigurations.renekton = nix-darwin.lib.darwinSystem {
        system = darwinSystem;
        specialArgs.waveRevision = self.rev or "unknown";
        modules = [
          determinate.darwinModules.default
          home-manager.darwinModules.home-manager
          inputs.nix-openclaw.darwinModules.openclaw
          inputs.sops-nix.darwinModules.sops
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

      packages = {
        ${system} = {
          deploy-rs = inputs.deploy-rs.packages.${system}.deploy-rs;
          inherit kanagawa-kvantum;
          inherit (pkgs)
            wave
            camofox-browser-cli
            slack-mirror
            slack-mirror-context
            slack-mirror-image
            herdr-auto-title
            spotifast
            ;
        };
        ${darwinSystem} = {
          deploy-rs = inputs.deploy-rs.packages.${darwinSystem}.deploy-rs;
          inherit (darwinPkgs)
            wave
            herdr-auto-title
            openclaw-sandbox-machine-check
            slack-mirror
            slack-mirror-context
            slack-mirror-image
            openclaw-languagetool-mcp-context
            openclaw-languagetool-mcp-image
            openclaw-embeddinggemma
            openclaw-whisper-model
            openclaw-llama-server
            anytype-mcp
            substack-mcp
            workspace-mcp
            camofox-browser-source
            camofox-openclaw-plugin
            asr-benchmark
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
      };
      checks.${darwinSystem} = inputs.deploy-rs.lib.${darwinSystem}.deployChecks {
        nodes.renekton = renektonNode;
      };
      checks.${ahriSystem} = inputs.deploy-rs.lib.${ahriSystem}.deployChecks {
        nodes.ahri = ahriNode;
      };
    };
}
