#compdef sendspin-go

_arguments \
  '--help[Show help]' \
  '--daemon[Run without a terminal or log file]' \
  '--server[Server WebSocket address]:address:' \
  '--name[Player name]:name:' \
  '--client-id[Stable player identity]:identity:' \
  '--config[Player configuration]:file:_files' \
  '--audio-device[ALSA playback device]:device:' \
  '--list-audio-devices[List playback devices]' \
  '--max-sample-rate[Maximum sample rate]:rate:(44100 48000)' \
  '--max-bit-depth[Maximum bit depth]:bits:(16 24 32)' \
  '--preferred-codec[Preferred codec]:codec:(pcm flac opus)' \
  '--buffer-ms[Jitter buffer duration]:milliseconds:' \
  '--buffer-capacity[Advertised buffer size]:bytes:' \
  '--static-delay-ms[Hardware latency compensation]:milliseconds:' \
  '--port[mDNS advertisement port]:port:' \
  '--no-reconnect[Disable reconnection]' \
  '--no-tui[Disable terminal interface]' \
  '--stream-logs[Write logs to standard output]' \
  '--log-file[Log file]:file:_files' \
  '--product-name[Reported product name]:name:' \
  '--manufacturer[Reported manufacturer]:name:'
