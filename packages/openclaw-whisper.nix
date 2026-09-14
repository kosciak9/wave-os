{
  coreutils,
  ffmpeg,
  lib,
  openclaw-whisper-model,
  whisper-cpp,
  writeShellApplication,
}:

writeShellApplication {
  name = "openclaw-whisper";
  runtimeInputs = [
    coreutils
    ffmpeg
    whisper-cpp
  ];
  text = ''
    set -euo pipefail

    if [ "$#" -ne 1 ] || [ ! -f "$1" ] || [ ! -r "$1" ]; then
      printf '%s\n' "openclaw-whisper: expected one readable regular-file audio path" >&2
      exit 2
    fi

    input_file=$1
    runtime_root="''${XDG_RUNTIME_DIR:-''${TMPDIR:-/tmp}}"
    lock_file="''${runtime_root%/}/openclaw-whisper-''${UID:-$(id -u)}.lock"
    lock_acquired=0
    for _ in $(seq 1 1200); do
      if /usr/bin/shlock -f "$lock_file" -p "$$" >/dev/null 2>&1; then
        lock_acquired=1
        break
      fi
      sleep 0.1
    done
    if [ "$lock_acquired" -ne 1 ]; then
      printf '%s\n' "openclaw-whisper: another transcription is still running" >&2
      exit 1
    fi

    tmp_dir=
    cleanup() {
      if [ -n "$tmp_dir" ]; then
        rm -rf -- "$tmp_dir"
      fi
      if [ "$lock_acquired" -eq 1 ]; then
        rm -f -- "$lock_file"
      fi
    }
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    tmp_dir=$(mktemp -d "''${TMPDIR:-/tmp}/openclaw-whisper.XXXXXX")
    wav_file="$tmp_dir/input.wav"
    transcript_file="$tmp_dir/transcript.txt"

    if ! timeout --foreground --signal=TERM --kill-after=5s 60s ffmpeg -nostdin -v error -i "$input_file" -map 0:a:0 -vn -ac 1 -ar 16000 -c:a pcm_s16le -f wav "$wav_file" \
      >"$tmp_dir/ffmpeg.stdout" 2>"$tmp_dir/ffmpeg.stderr"; then
      printf '%s\n' "openclaw-whisper: audio normalization failed" >&2
      exit 1
    fi

    if ! timeout --foreground --signal=TERM --kill-after=5s 180s whisper-cli \
      --model "${openclaw-whisper-model}/share/openclaw/models/ggml-large-v3-turbo-q5_0.bin" \
      --file "$wav_file" \
      --language auto \
      --output-txt \
      --output-file "$tmp_dir/transcript" \
      --no-timestamps \
      --no-prints \
      >"$tmp_dir/whisper.stdout" 2>"$tmp_dir/whisper.stderr"; then
      printf '%s\n' "openclaw-whisper: transcription failed" >&2
      exit 1
    fi

    if [ ! -s "$transcript_file" ]; then
      printf '%s\n' "openclaw-whisper: transcription produced no text" >&2
      exit 1
    fi

    cat "$transcript_file"
  '';

  passthru.model = openclaw-whisper-model;

  meta = {
    description = "Local speech-to-text wrapper for OpenClaw using Whisper";
    homepage = "https://github.com/ggerganov/whisper.cpp";
    license = lib.licenses.mit;
    mainProgram = "openclaw-whisper";
    platforms = [ "aarch64-darwin" ];
  };
}
