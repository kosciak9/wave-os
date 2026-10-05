{ pkgs, waveRevision, ... }:
{
  environment.systemPackages = [ pkgs.wave ];
  environment.etc."wave-os/revision" = {
    text = "${waveRevision}\n";
  };
}
