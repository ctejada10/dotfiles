# Shared by the setup scripts. Included with {{ "{{" }} template "script-lib.sh" . {{ "}}" }}.

# Homebrew isn't on PATH in a fresh shell before ~/.zshenv exists.
if ! command -v brew >/dev/null 2>&1 && [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# An apply is attended when someone is at a terminal. Unattended applies on
# the mini and the servers must never wait for a password or a prompt.
attended() { [ -t 0 ] && [ -t 1 ]; }

# Someone is at this Mac's own screen, not in an SSH session. 1Password asks
# for approval on the Mac's screen, so over SSH nobody would see the prompt.
at_the_mac() { attended && [ -z "${SSH_CONNECTION:-}" ]; }

# Runs a command as root. Attended, sudo may ask for the password once.
# Unattended, it only works if sudo can run without asking.
as_root() {
  if attended; then sudo "$@"; else sudo -n "$@"; fi
}

# Whether as_root can work right now, without blocking. Asked only when
# something actually needs root, so a machine in line asks for nothing.
ROOT_STATE=unknown
can_root() {
  if [ "$ROOT_STATE" = unknown ]; then
    if sudo -n true 2>/dev/null || { attended && sudo -v; }; then
      ROOT_STATE=yes
    else
      ROOT_STATE=no
    fi
  fi
  [ "$ROOT_STATE" = yes ]
}

# Runs a command with a time limit, so nothing an unattended apply calls can
# hang it. macOS has no timeout(1) without coreutils, and alarm-then-exec
# doesn't stop Go programs such as op, so perl forks the command and kills it
# when the time is up.
timeout_run() {
  perl -e '
    my $seconds = shift;
    my $pid = fork() // exit 127;
    if ($pid == 0) { exec @ARGV or exit 127 }
    local $SIG{ALRM} = sub { kill "TERM", $pid; sleep 2; kill "KILL", $pid; exit 124 };
    alarm $seconds;
    waitpid $pid, 0;
    exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
  ' "$@"
}

# 1Password's CLI, when someone at the Mac can approve it, or when it can
# answer without anyone approving it. At the Mac it needs an account first:
# with none (1Password not signed in, or its CLI integration off), op asks
# at the terminal whether to add one by hand and waits for an answer.
op_usable() {
  command -v op >/dev/null 2>&1 || return 1
  if at_the_mac; then
    timeout_run 10 op account list --format=json </dev/null 2>/dev/null | grep -q '"url"'
    return
  fi
  timeout_run 10 op whoami >/dev/null 2>&1
}

say()  { printf '%s: %s\n' "$SCRIPT" "$*"; }
warn() { printf '%s: %s\n' "$SCRIPT" "$*" >&2; }
