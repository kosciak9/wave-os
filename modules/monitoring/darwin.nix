{ lib, pkgs, ... }:

let
  textfileDir = "/var/lib/node-exporter";
  # process-exporter reads procfs, so macOS gets per-executable CPU and RSS from ps instead.
  # ps reports %CPU as a decaying recent average, hence a gauge rather than a CPU-seconds counter.
  processMetrics = pkgs.writeShellScript "process-metrics" ''
    set -euo pipefail
    tmp=$(mktemp ${textfileDir}/.processes.XXXXXX)
    /bin/ps -axo rss=,pcpu=,comm= | /usr/bin/awk '
      {
        rss = $1; cpu = $2
        sub(/^ *[0-9]+ +[0-9.,]+ +/, ""); sub(/.*\//, "")
        gsub(/\\/, "\\\\"); gsub(/"/, "\\\"")
        mem[$0] += rss * 1024; pcpu[$0] += cpu
      }
      END {
        print "# TYPE darwin_process_resident_bytes gauge"
        for (n in mem) printf "darwin_process_resident_bytes{groupname=\"%s\"} %d\n", n, mem[n]
        print "# TYPE darwin_process_cpu_percent gauge"
        for (n in pcpu) printf "darwin_process_cpu_percent{groupname=\"%s\"} %.1f\n", n, pcpu[n]
      }' > "$tmp"
    chmod 644 "$tmp"
    mv "$tmp" ${textfileDir}/processes.prom
  '';
in
{
  system.activationScripts.postActivation.text = ''
    mkdir -p ${textfileDir}
    chown nobody:nobody ${textfileDir}
  '';

  launchd.daemons = {
    # pf admits inbound traffic only from Tailscale, so the exporter can listen on all interfaces.
    node-exporter.serviceConfig = {
      ProgramArguments = [
        (lib.getExe pkgs.prometheus-node-exporter)
        "--web.listen-address=:9100"
        "--collector.textfile.directory=${textfileDir}"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      UserName = "nobody";
      GroupName = "nobody";
    };
    process-metrics.serviceConfig = {
      ProgramArguments = [ "${processMetrics}" ];
      StartInterval = 30;
      RunAtLoad = true;
      ProcessType = "Background";
      UserName = "nobody";
      GroupName = "nobody";
    };
  };
}
