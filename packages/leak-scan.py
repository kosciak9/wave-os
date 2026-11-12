"""Block personal and company data on its way to GitHub.

`leak-scan pre-push <remote> <url>` runs as a git pre-push hook and scans the
messages of the commits being pushed. Code is not scanned: repositories keep
made-up companies and checksum-valid numbers in seeds and tests on purpose.

`leak-scan gh <args>` wraps gh: it scans the texts that PR and issue commands
publish (and `title`/`body` fields of `gh api`), then runs the real gh from
$LEAK_SCAN_GH.

A value already on the remote's default branch is not reported: it is public
already, which keeps example data that the repository uses on purpose quiet.
"""

import os
import re
import subprocess
import sys

TEXT_COMMANDS = {
    "pr": {"create", "edit", "comment", "review", "merge", "close", "reopen"},
    "issue": {"create", "edit", "comment", "close", "reopen"},
}
TEXT_FLAGS = {"-t", "--title", "--subject", "-b", "--body"}
# `pr review --comment` is a switch; only close and reopen take a comment text.
COMMENT_FLAGS = {"-c", "--comment"}
FILE_FLAGS = {"-F", "--body-file"}
API_FIELD_FLAGS = {"-f", "--raw-field", "-F", "--field"}
API_TEXT_FIELD = re.compile(r"(^|\[)(title|body)\]?$")

PLACEHOLDER_WORDS = {"acme", "example", "przykład", "przykładowa", "test", "foo", "bar", "demo"}
# Commit authors are public on GitHub anyway.
AUTHOR_TRAILER = re.compile(r"(?im)^(co-authored-by|signed-off-by):.*$")
PUBLIC_EMAIL = re.compile(r"(?i)(^git@|@example\.(com|org|net|pl)$|noreply|no-reply)")


def nip_ok(value):
    digits = re.sub(r"\D", "", value)
    weights = [6, 5, 7, 2, 3, 4, 5, 6, 7]
    total = sum(int(d) * w for d, w in zip(digits, weights))
    return len(set(digits)) > 1 and total % 11 == int(digits[9])


def pesel_ok(digits):
    weights = [1, 3, 7, 9, 1, 3, 7, 9, 1, 3]
    check = (10 - sum(int(d) * w for d, w in zip(digits, weights)) % 10) % 10
    month = int(digits[2:4]) % 20
    return 1 <= month <= 12 and 1 <= int(digits[4:6]) <= 31 and check == int(digits[10])


def account_ok(value):
    digits = re.sub(r"\D", "", value)
    return int(digits[2:] + "2521" + digits[:2]) % 97 == 1


def company_ok(name):
    return not {w.lower().strip(".,") for w in name.split()} & PLACEHOLDER_WORDS


# Checksums keep timestamps, ids and made-up numbers such as 1234567890 quiet.
RULES = [
    (
        "NIP",
        re.compile(r"(?<![\w-])(?:PL ?)?(\d{3}[- ]?\d{3}[- ]?\d{2}[- ]?\d{2}|\d{3}[- ]\d{2}[- ]\d{2}[- ]\d{3})(?![\w-])"),
        nip_ok,
    ),
    ("PESEL", re.compile(r"(?<![\w-])(\d{11})(?![\w-])"), pesel_ok),
    ("bank account", re.compile(r"(?<![\w-])(?:PL ?)?(\d{2}(?: ?\d{4}){6})(?![\w-])"), account_ok),
    (
        "e-mail",
        re.compile(r"(?<![\w.+-])([\w.+-]+@[\w-]+(?:\.[\w-]+)*\.[A-Za-z]{2,})(?![\w-])"),
        lambda v: not PUBLIC_EMAIL.search(v),
    ),
    ("phone", re.compile(r"(?<![\w+])(\(?\+48\)?[ -]?\d{2,3}(?:[ -]?\d{2,3}){2,3})(?!\d)"), lambda v: True),
    (
        "company",
        re.compile(r"(?<![\w&'.-])((?:[A-ZĄĆĘŁŃÓŚŹŻ][\w&'.-]*\s+){1,4}(?i:sp\.\s?z\s?o\.\s?o\.?|s\.a\.|sp\.\s?k\.|sp\.\s?j\.))"),
        company_ok,
    ),
]


def findings(texts):
    """Yield (rule, place, value) for every text given as (place, text)."""
    for place, text in texts:
        for rule, pattern, ok in RULES:
            for match in pattern.finditer(text):
                # One line, so `git grep` does not split it into separate patterns.
                value = " ".join(match.group(1).split())
                if ok(value):
                    line = text.count("\n", 0, match.start(1)) + 1
                    yield rule, f"{place} line {line}", value


def git(*args):
    try:
        return subprocess.run(["git", *args], capture_output=True, text=True, errors="replace")
    except FileNotFoundError:
        return subprocess.CompletedProcess(args, 127, "", "")


def default_branch(remote):
    for ref in (f"refs/remotes/{remote}/HEAD", f"refs/remotes/{remote}/main", f"refs/remotes/{remote}/master"):
        resolved = git("rev-parse", "--verify", "--quiet", ref)
        if resolved.returncode == 0:
            return resolved.stdout.strip()
    return None


def already_public(value, published):
    if published is None:
        return False
    return git("grep", "-q", "-F", "-e", value, published, "--").returncode == 0


def report(found, published_branch):
    """published_branch() names the public commit; it runs only when something was found."""
    published = published_branch() if found else None
    new = [(rule, place) for rule, place, value in found if not already_public(value, published)]
    if not new:
        return 0
    print("leak-scan: this looks like real personal or company data:", file=sys.stderr)
    for rule, place in new:
        print(f"  {rule} in {place}", file=sys.stderr)
    print(
        "Remove it and describe the case without names, numbers or amounts; examples\n"
        "use made-up values that fail the checksum (1234567890) or Acme names. Never\n"
        "bypass this check: if it is wrong, stop and ask the owner.",
        file=sys.stderr,
    )
    return 1


def pushed_messages(remote, updates):
    for line in updates:
        _local_ref, local_sha, _remote_ref, _remote_sha = line.split()
        if set(local_sha) == {"0"}:
            continue
        log = git("log", "--format=%H%x00%B%x00", local_sha, "--not", f"--remotes={remote}").stdout
        fields = log.split("\0")
        for commit, message in zip(fields[0::2], fields[1::2]):
            yield f"commit {commit.strip()[:10]} message", AUTHOR_TRAILER.sub("", message)


def pre_push(remote):
    found = list(findings(pushed_messages(remote, sys.stdin.read().splitlines())))
    return report(found, lambda: default_branch(remote))


def flag_value(args, i, flags):
    """Return (flag, value, next index) when args[i] is one of flags."""
    arg = args[i]
    if arg.startswith("--"):
        name, has_value, value = arg.partition("=")
        if name in flags:
            if has_value:
                return name, value, i + 1
            return name, args[i + 1] if i + 1 < len(args) else "", i + 2
    elif arg.startswith("-") and arg[:2] in flags:
        if len(arg) > 2:
            return arg[:2], arg[2:].removeprefix("="), i + 1
        return arg[:2], args[i + 1] if i + 1 < len(args) else "", i + 2
    return None, None, i + 1


def gh_texts(args):
    """Return the texts gh would publish and the bytes it would read from stdin."""
    texts, stdin = [], None

    def read(path):
        nonlocal stdin
        if path == "-":
            stdin = sys.stdin.buffer.read()
            return stdin.decode(errors="replace")
        try:
            with open(path, errors="replace") as f:
                return f.read()
        except OSError:
            return ""

    is_api = args[0] == "api"
    flags = API_FIELD_FLAGS if is_api else TEXT_FLAGS | FILE_FLAGS
    if args[1:2] in (["close"], ["reopen"]):
        flags = flags | COMMENT_FLAGS
    i = 1
    while i < len(args):
        flag, value, i = flag_value(args, i, flags)
        if flag is None:
            continue
        if is_api:
            key, _, field = value.partition("=")
            if API_TEXT_FIELD.search(key):
                at_file = flag in {"-F", "--field"} and field.startswith("@")
                texts.append(read(field[1:]) if at_file else field)
        elif flag in FILE_FLAGS:
            texts.append(read(value))
        else:
            texts.append(value)
    return texts, stdin


def gh(args):
    real_gh = os.environ["LEAK_SCAN_GH"]
    if args[:1] == ["api"] or (len(args) > 1 and args[1] in TEXT_COMMANDS.get(args[0], ())):
        texts, stdin = gh_texts(args)
        place = "gh " + " ".join(args[:2])
        if report(list(findings((place, text) for text in texts)), lambda: default_branch("origin")):
            return 1
        if stdin is not None:
            return subprocess.run([real_gh, *args], input=stdin).returncode
    os.execv(real_gh, [real_gh, *args])


def main():
    mode, args = sys.argv[1], sys.argv[2:]
    if mode == "pre-push":
        return pre_push(args[0])
    if mode == "gh":
        return gh(args)
    print("usage: leak-scan pre-push <remote> <url> | leak-scan gh <args>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
