"""Transport/cache adapter for a Nix-generated sops-nix installer invocation."""

import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile


def external(path):
    path = Path(path)
    if not path.is_absolute() or path.is_symlink():
        raise ValueError("runtime data needs absolute, non-symlink paths")
    path = path.resolve()
    if path.is_relative_to("/nix/store") or any((p / ".git").exists() for p in path.parents):
        raise ValueError("runtime data must be outside Git and the Nix store")
    return path


def private(path, mode):
    info = path.lstat()
    expected_type = stat.S_ISDIR if mode == 0o700 else stat.S_ISREG
    if (info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != mode
            or not expected_type(info.st_mode) or (mode == 0o600 and info.st_nlink != 1)):
        raise ValueError("runtime state has incorrect ownership or permissions")


def run(command, env):
    result = subprocess.run(command, env=env, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, timeout=60, check=False)
    if result.returncode:
        raise ValueError("bundle validation failed")


def main():
    installer, source_file, cache_file, rclone_config, mode, *args = sys.argv[1:]
    if any(arg in ("--help", "-h", "-check-mode=manifest", "-check-mode=sopsfile") for arg in args):
        return subprocess.call([installer, *args])
    os.umask(0o077)
    cache = external(cache_file)
    cache.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    private(cache.parent, 0o700)
    env = {"PATH": os.environ["PATH"], "HOME": "/var/empty", "XDG_CONFIG_HOME": "/var/empty"}
    for name in ("NIXOS_ACTION", "SOPS_RESTART_UNITS_VIA_SYSTEMCTL"):
        if name in os.environ:
            env[name] = os.environ[name]
    manifest = json.loads(Path(args[-1]).read_text())
    identity = external(manifest["ageKeyFile"])
    private(identity, 0o600)
    lock_path = cache.parent / ".lock"
    descriptor = os.open(lock_path, os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    with os.fdopen(descriptor, "w") as lock:
        private(lock_path, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        if cache.exists():
            private(cache, 0o600)
        # Boot replays cache without network; first provisioning and explicit refresh fetch it.
        if env.get("NIXOS_ACTION") != "dry-activate" and (mode == "refresh" or not cache.exists()):
            source_path = external(source_file)
            private(source_path, 0o600)
            source = source_path.read_text().strip()
            if not source or "\n" in source or source.startswith("-"):
                raise ValueError("source file must contain one local path or rclone remote object")
            if source.startswith("/"):
                source = str(external(source))
            config = external(rclone_config) if rclone_config else Path("/dev/null")
            if rclone_config:
                private(config, 0o600)
            with tempfile.TemporaryDirectory(prefix=".fetch-", dir=cache.parent) as temporary:
                candidate = Path(temporary) / "bundle.enc.json"
                try:
                    fetched = subprocess.run(
                        ["rclone", "copyto", "--config", str(config), "--retries", "1",
                         "--low-level-retries", "1", "--contimeout", "5s", "--timeout", "10s",
                         source, str(candidate)],
                        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        timeout=30, check=False,
                    ).returncode == 0
                except subprocess.TimeoutExpired:
                    fetched = False
                if not fetched:
                    if not cache.exists():
                        raise ValueError("source unavailable and no cached bundle exists")
                    print("wave secrets: source unavailable; using encrypted cache", file=sys.stderr)
                else:
                    if candidate.stat().st_size > 1024 * 1024:
                        raise ValueError("bundle exceeds the 1 MiB limit")
                    # This transport accepts fully encrypted, flat JSON string bundles only.
                    run(["jq", "-e", 'del(.sops) | length > 0 and all(.[]; '
                         'type == "string" and startswith("ENC[") and endswith(",type:str]"))',
                         str(candidate)], env)
                    for secret in manifest["secrets"]:
                        secret["sopsFile"] = str(candidate)
                    validation_manifest = Path(temporary) / "manifest.json"
                    validation_manifest.write_text(json.dumps(manifest))
                    run([installer, "-check-mode=sopsfile", str(validation_manifest)], env)
                    run(["sops", "decrypt", "--input-type", "json", "--output-type", "json",
                         str(candidate)], {**env, "SOPS_AGE_KEY_FILE": str(identity)})
                    os.chmod(candidate, 0o600)
                    os.replace(candidate, cache)
        return subprocess.call([installer, *args], env=env)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
        print("wave secrets: transport, validation or runtime state failed", file=sys.stderr)
        raise SystemExit(1)
