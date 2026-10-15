{ config, lib, ... }:
let
  federation = config.programs.herdr.federation;
in
{
  options.programs.herdr.federation = {
    coordinator = lib.mkEnableOption "Herdr saved-machine federation coordinator behavior";
    savedMachines = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            profileId = lib.mkOption {
              type = lib.types.str;
              description = "Local saved SSH profile ID, also the alias prefixing this machine's Herdr ids.";
            };
            machineId = lib.mkOption {
              type = lib.types.str;
              description = "Expected remote Herdr machine ID.";
            };
          };
        }
      );
      default = { };
      description = "Saved SSH machines by host name; connection details remain in the native endpoint catalog.";
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
              lib.mapAttrsToList (_host: machine: ''

                [federation.saved_machines.${builtins.toJSON machine.profileId}]
                expected_machine_id = ${builtins.toJSON machine.machineId}
              '') federation.savedMachines
            )
          )
        );

    assertions = [
      {
        assertion = lib.all (machine: builtins.match "[0-9a-f]{32}" machine.profileId != null) (
          builtins.attrValues federation.savedMachines
        );
        message = "Herdr federation savedMachines profile IDs must be native saved profile IDs (32 lowercase hexadecimal characters).";
      }
      {
        assertion = lib.all (
          { machineId, ... }:
          builtins.stringLength machineId <= 128 && builtins.match "[!-~]([ -~]*[!-~])?" machineId != null
        ) (builtins.attrValues federation.savedMachines);
        message = "Herdr federation saved machine IDs must be 1–128 printable ASCII bytes with no leading or trailing whitespace.";
      }
    ];
  };
}
