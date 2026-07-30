{ pkgs, ... }:

let
  weave = pkgs.callPackage ../../../packages/weave.nix { };
  worktrunk = pkgs.worktrunk.overrideAttrs {
    # TODO: Re-enable checks when Worktrunk process-table tests support Darwin sandboxes.
    # Darwin sandboxes hide the process table, breaking upstream shell-probe tests.
    # Skip the slow test suite there; Linux keeps the nixpkgs checks enabled.
    doCheck = !pkgs.stdenv.hostPlatform.isDarwin;
  };
in
{
  home.packages = with pkgs; [
    bat
    gh
    httpie
    infisical
    weave
    worktrunk
  ];
}
