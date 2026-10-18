{ lib, sops-nix }:
let
  moduleDirectory = "${sops-nix}/modules/nix-darwin";
  original = builtins.readFile "${moduleDirectory}/default.nix";
  oldHook = "postActivation.text = lib.mkAfter installScript;";
  newHook = "launchd.text = lib.mkBefore installScript;";
  # Secrets must exist before launchd starts their consumers, including Home Manager.
  patched =
    builtins.replaceStrings
      [
        oldHook
        "./manifest-for.nix"
        "./with-environment.nix"
        "./templates"
        "./secrets-for-users"
        "../.."
      ]
      [
        newHook
        "${moduleDirectory}/manifest-for.nix"
        "${moduleDirectory}/with-environment.nix"
        "${moduleDirectory}/templates"
        "${moduleDirectory}/secrets-for-users"
        (toString sops-nix)
      ]
      original;
in
assert lib.assertMsg (lib.hasInfix oldHook original)
  "sops-nix Darwin activation changed; review the secrets-before-launchd compatibility patch.";
builtins.toFile "sops-darwin-ordered.nix" patched
