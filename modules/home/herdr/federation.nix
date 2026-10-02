{ config, lib, ... }:
let
  federation = config.programs.herdr.federation;
in
{
  options.programs.herdr.federation = {
    coordinator = lib.mkEnableOption "Herdr saved-machine federation coordinator behavior";
    savedMachines = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Map local saved SSH profile IDs to expected remote Herdr machine IDs; connection details remain in the native endpoint catalog.";
    };
  };

  config = {
    xdg.configFile."herdr/config.toml".text =
      lib.mkIf (federation.coordinator || federation.savedMachines != { })
        (
          lib.mkAfter (
            lib.optionalString federation.coordinator ''

              [federation]
              coordinator = true
            ''
            + lib.concatStrings (
              lib.mapAttrsToList (profileId: machineId: ''

                [federation.saved_machines.${builtins.toJSON profileId}]
                expected_machine_id = ${builtins.toJSON machineId}
              '') federation.savedMachines
            )
          )
        );

    assertions = [
      {
        assertion = lib.all (profileId: builtins.match "[0-9a-f]{32}" profileId != null) (
          builtins.attrNames federation.savedMachines
        );
        message = "Herdr federation savedMachines keys must be native saved profile IDs (32 lowercase hexadecimal characters).";
      }
      {
        assertion = lib.all (
          machineId:
          builtins.stringLength machineId <= 128 && builtins.match "[!-~]([ -~]*[!-~])?" machineId != null
        ) (builtins.attrValues federation.savedMachines);
        message = "Herdr federation saved machine IDs must be 1–128 printable ASCII bytes with no leading or trailing whitespace.";
      }
    ];
  };
}
