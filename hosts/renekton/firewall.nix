{ pkgs, ... }:

let
  anchorName = "com.apple/100.WaveRenekton";

  anchorRules = pkgs.writeText "wave-renekton-pf-anchor" ''
    # Tailscale ranges are required because utun interfaces are shared by tunnels.
    pass in quick on utun* inet from 100.64.0.0/10 to any keep state label "wave tailscale ipv4"
    pass in quick on utun* inet6 from fd7a:115c:a1e0::/48 to any keep state label "wave tailscale ipv6"

    pass quick on lo0 all label "wave loopback"
    pass out quick all keep state label "wave outbound"

    pass in quick inet proto udp from any port 5353 to 224.0.0.251 port 5353 keep state label "wave bonjour ipv4"
    pass in quick inet6 proto udp from any port 5353 to ff02::fb port 5353 keep state label "wave bonjour ipv6"

    pass in quick inet proto udp from any port 67 to any port 68 keep state label "wave dhcp ipv4"
    pass in quick inet6 proto udp from any port 547 to any port 546 keep state label "wave dhcp ipv6"
    pass in quick inet6 proto icmp6 icmp6-type { 1, 2, 3, 4, 130, 131, 132, 134, 135, 136, 143 } keep state label "wave ipv6 control"

    # UDP 41641 is Tailscale's direct WireGuard path.
    pass in quick proto tcp to any port 22 flags S/SA keep state label "wave ssh"
    pass in quick proto udp to any port 41641 keep state label "wave tailscale wireguard"

    # Keep non-quick so Apple's later dynamic AirDrop anchor can override this deny.
    block in all label "wave default deny"
  '';

  pfLoader = pkgs.writeShellScript "wave-renekton-pf-loader" ''
    set -eu
    token=""
    sleepPid=""

    cleanup() {
      status="$1"
      trap - EXIT HUP INT TERM
      if /bin/test -n "$sleepPid"; then
        /bin/kill "$sleepPid" || true
        wait "$sleepPid" || true
      fi
      /sbin/pfctl -a ${anchorName} -F rules || true
      if /bin/test -n "$token"; then
        /sbin/pfctl -X "$token" || true
      fi
      exit "$status"
    }

    trap 'cleanup "$?"' EXIT
    trap 'cleanup 129' HUP
    trap 'cleanup 130' INT
    trap 'cleanup 143' TERM

    # pfctl atomically replaces only this anchor; the stock /etc/pf.conf is untouched.
    /sbin/pfctl -a ${anchorName} -f ${anchorRules}

    if ! enableOutput=$(/sbin/pfctl -E); then
      /usr/bin/printf '%s\n' "pfctl -E failed" >&2
      exit 1
    fi
    if ! token=$(/usr/bin/printf '%s\n' "$enableOutput" | /usr/bin/awk '/^Token[[:space:]]*:/ { print $3; exit }'); then
      /usr/bin/printf '%s\n' "could not parse pfctl enable token" >&2
      exit 1
    fi
    if ! /bin/test -n "$token"; then
      /usr/bin/printf '%s\n' "pfctl -E returned no enable token" >&2
      exit 1
    fi

    while :; do
      /bin/sleep 3600 &
      sleepPid="$!"
      wait "$sleepPid"
      sleepPid=""
    done
  '';
in

{
  environment.etc."pf.anchors/wave-renekton".source = anchorRules;

  networking.applicationFirewall = {
    enable = false;
    blockAllIncoming = false;
  };

  launchd.daemons.wave-renekton-firewall = {
    serviceConfig = {
      ProgramArguments = [ "${pfLoader}" ];
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 10;
      StandardErrorPath = "/var/log/wave-renekton-firewall-error.log";
      StandardOutPath = "/var/log/wave-renekton-firewall.log";
    };
  };
}
