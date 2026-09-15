{
  jq,
  lib,
  podman,
  writeShellApplication,
}:

let
  machineName = "openclaw-sandbox";
  expected = {
    rootful = false;
    cpus = 4;
    memoryMiB = 4096;
    diskSizeGiB = 40;
    vmType = "applehv";
    swapMiB = 0;
  };
  podmanExe = lib.getExe podman;
  jqExe = lib.getExe jq;
in
writeShellApplication {
  name = "openclaw-sandbox-machine-check";
  runtimeInputs = [
    podman
    jq
  ];
  text = ''
    set -euo pipefail

    machine_name=${lib.escapeShellArg machineName}
    if ! machine_config=$(${podmanExe} machine inspect \
      --format '{{.Rootful}}\t{{.Resources.CPUs}}\t{{.Resources.Memory}}\t{{.Resources.DiskSize}}' \
      "$machine_name" 2>/dev/null); then
      printf '%s\n' "openclaw-sandbox machine inspection failed" >&2
      exit 1
    fi
    if [[ "$machine_config" != $'${
      if expected.rootful then "true" else "false"
    }\t${toString expected.cpus}\t${toString expected.memoryMiB}\t${toString expected.diskSizeGiB}' ]]; then
      printf '%s\n' \
        "openclaw-sandbox machine configuration drift detected: expected Rootful=${
          if expected.rootful then "true" else "false"
        }, CPUs=${toString expected.cpus}, Memory=${toString expected.memoryMiB}, DiskSize=${toString expected.diskSizeGiB}; found machine configuration with unexpected values" >&2
      exit 1
    fi

    if ! machine_list=$(${podmanExe} machine list --format json 2>/dev/null); then
      printf '%s\n' "openclaw-sandbox machine metadata inspection failed" >&2
      exit 1
    fi
    if ! ${jqExe} -e \
      --arg name "$machine_name" \
      '[.[] | select(.Name == $name)] | length == 1' \
      <<<"$machine_list" >/dev/null 2>&1; then
      printf '%s\n' \
        "openclaw-sandbox machine metadata is absent or ambiguous" >&2
      exit 1
    fi
    if ! ${jqExe} -e \
      --arg name "$machine_name" \
      --arg vm_type ${lib.escapeShellArg expected.vmType} \
      --argjson swap ${toString expected.swapMiB} \
      '[.[] | select(.Name == $name)] | .[0] |
        (.Swap? // null) as $swap_value |
        ($swap_value |
          if type == "number" then .
          elif type == "string" and test("^[0-9]+$") then tonumber
          else null
          end) as $normalized_swap |
        (.VMType? | type == "string" and . == $vm_type) and
        $normalized_swap == $swap' \
      <<<"$machine_list" >/dev/null 2>&1; then
      printf '%s\n' \
        "openclaw-sandbox machine metadata drift detected: expected VMType=${expected.vmType}, Swap=${toString expected.swapMiB}" >&2
      exit 1
    fi
  '';

  passthru = {
    inherit machineName;
  };
}
