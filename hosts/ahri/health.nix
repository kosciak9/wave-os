{ lib, pkgs, ... }:
let
  jq = lib.getExe pkgs.jq;
  util = lib.getExe' pkgs.util-linux;
in
{
  wave.health.checks = {
    # The root filesystem stays on USB members of its btrfs; a missing mirror is allowed.
    usb-root = ''
      mount=$(${util "findmnt"} --json --target / --output FSTYPE,SOURCE,OPTIONS)
      ${jq} -e '.filesystems | length == 1 and .[0].fstype == "btrfs"
        and (.[0].options | split(",") | index("rw") and index("subvol=/@root"))' <<<"$mount" >/dev/null
      source=$(${jq} -r '.filesystems[0].source | sub("\\[.*"; "")' <<<"$mount")
      [[ $source == /dev/* ]]
      device=$(${lib.getExe' pkgs.coreutils "readlink"} -f "$source")
      ${util "lsblk"} --json --tree --output PATH,TYPE,TRAN,FSTYPE,UUID | ${jq} -e --arg device "$device" '
        def members(transport): .[] | (.tran // transport) as $t
          | (select(.fstype == "btrfs" and (.uuid // "") != "") | {path, uuid, tran: $t}),
            ((.children // []) | members($t));
        [.blockdevices | members(null)] as $members
        | ($members | map(select(.path == $device)) | first | .uuid) as $uuid
        | $uuid != null and ($members | map(select(.uuid == $uuid)) | all(.tran == "usb"))' >/dev/null
    '';
  };
}
