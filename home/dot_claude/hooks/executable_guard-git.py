#!/usr/bin/python3
"""PreToolUse guard for Bash, on the mini only.

Agents here may commit, push and open draft PRs on their own branches. This
blocks (exit 2) the rest: any force-push, a push to the default branch, a
commit or merge while the default branch is checked out, merging or readying
a PR, and a PR opened as anything but a draft. The default branch is main,
master, or whatever the repo's origin says it is.
t3-pstack's Shipping and Autopilot-full playbooks do several of these by
default.

A repo in Dropbox's repositories folder, the repos' old home, is online-only
on this Mac and never used here, attended or not: no git command runs in it,
not even to read, since a status or diff would rewrite its index, and no gh
command runs there either, since gh reads the repo it runs in. It is read on
GitHub, and changed in a clone from GitHub under ~/worktrees. The dotfiles
source's main checkout, which is this Mac's live config, is only ever read
here, attended or not, chezmoi add and chezmoi git included, and is changed in
a worktree of it there. That clone and that worktree count as ordinary repos.

An agent repo is one of the clones chezmoi makes in ~/src. Its main checkout
there keeps its HEAD, index and working tree as they are: no switch to another
branch, commit, reset or restore there, and no merge but a fast-forward from
origin. Fetching, pushing a branch and making a worktree outside ~/src are
fine; the work happens in that worktree, and a worktree of an agent repo,
wherever it is, counts as an ordinary repo. ~/src holds only those clones, so
a clone, git init or worktree made there is blocked, as one made in Dropbox's
repositories folder or the dotfiles checkout is.

git gc, repack, prune, maintenance and worktree prune are blocked only in a
repo under ~/Library/CloudStorage/Dropbox, which syncs its .git between the
Macs.

A git command is judged by every checkout it names: the folder it runs in,
after cd, pushd, -C or env -C, and any repo, working tree or index that
--git-dir, --work-tree, core.worktree or GIT_DIR and the other GIT_ variables
point it at, whether set on the command, after env or by an export earlier.
git run by xargs or find -exec is judged too, and since the words they hand
it aren't known here, it may only read in those checkouts. A folder worked out
only when the command runs, for those variables (from a substitution, read,
printf -v or a for loop) or for what xargs and find hand over, could be a repo
in Dropbox, so no git or gh command runs there at all. Another repo that git
clone, fetch, pull, push, ls-remote, archive, remote add or set-url, or
submodule add names by its path counts as one the command names. Commands run
in zsh, as agents' commands do here, so the last command of a pipeline runs in
the current shell; under bash -c or sh -c it doesn't.

It reads the command, so a determined script can get past it. The ruleset on
each repo's default branch on GitHub is the lock; this catches the ordinary
case early and says what to do instead. When a command can't be parsed, it
falls back to plain pattern checks and blocks on any match. A command nested
too deeply to check, or one the guard itself fails on, is blocked.
"""

import json
import os
import re
import shlex
import subprocess
import sys

ALWAYS_PROTECTED = {"main", "master"}
CONTROL = {"&&", "||", ";", "|", "&", "|&", "(", ")"}
# What a quoted or escaped ; & | ( or ) becomes while shlex splits the
# command, so that find's \( and \; stay words and only the shell's own
# operators split it, and what each becomes again in its word.
HIDDEN = {ch: chr(0xE000 + n) for n, ch in enumerate(";&|()")}
SHOWN = {ord(stand_in): ch for ch, stand_in in HIDDEN.items()}
# Commands that run the command after them, and their options that take the
# next word as a value. env and timeout have their own handling.
WRAPPERS = {"command": (), "nohup": (), "time": ("-f", "-o"), "exec": ("-a",), "builtin": (),
            "caffeinate": ("-t", "-w"), "stdbuf": ("-i", "-o", "-e")}
KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "}"}
SHELLS = {"bash", "sh", "zsh"}
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
CHANGES_BRANCH = ("commit", "cherry-pick", "revert", "am", "merge", "pull", "rebase")
CREATES = ("-c", "-C", "-b", "-B", "--create", "--force-create", "--orphan")
# A commit is never co-authored by an AI agent, and says nothing about one:
# no trailer, no "Generated with" line and no link back to the session. A
# trailer's key may end in = as well as :, as git commit --trailer takes it.
CREDITED = r"\b(claude|anthropic|codex|openai|chatgpt|gpt|copilot|cursor|gemini|devin|noreply@anthropic)"
GENERATED = (r"generated (with|by|using) (an? )?((github|openai|google|anthropic)('s)?\s+)?\[?"
             r"(claude|codex|chatgpt|copilot|cursor|gemini|ai)\b")
AI_CREDIT = re.compile(
    r"(?im)^\s*co-authored-by\s*[:=].*" + CREDITED + "|" + GENERATED
    + r"|^\s*claude-session\s*[:=]|claude\.ai/code/session_|chatgpt\.com/codex/tasks/"
)
# The same lines in the text of a command that builds a message some other
# way, as printf, echo or a pipe into git commit -F - do: a trailer counts at
# the start of a line, right after a quote, or as what echo or printf prints.
# The text is read with its \n escapes as newlines.
BUILT_CREDIT = re.compile(
    r"(?im)(^|['\"]|\b(echo|printf)\s+(-\w+\s+)*)\s*(co-authored-by\s*[:=].*" + CREDITED
    + r"|claude-session\s*[:=])"
    + "|" + GENERATED + r"|claude\.ai/code/session_|chatgpt\.com/codex/tasks/"
)
ASSIGNMENT = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
# Commands that set a variable some other way than NAME=value.
SETTERS = {"export", "local", "declare", "typeset", "readonly", "read", "unset", "mapfile", "readarray",
           "getopts", "let", "printf", "for", "select"}
# The ones of those that take plain NAME=value words, as in `export WT=~/x`.
DECLARERS = {"export", "local", "declare", "typeset", "readonly"}
# A folder or file mktemp makes, which is never in a repo. Each $(mktemp ...)
# in a command becomes this path before it is split.
MKTEMP = re.compile(r"\$\(\s*mktemp\b[^()`]*\)|`\s*mktemp\b[^`]*`")
MKTEMP_PATH = "/tmp/mktemp.XXXXXX"
# A redirection, found on the quote-masked line so a quoted < or > is left
# alone: an optional file descriptor, the operator and its target, attached or
# not. Process substitution, <(...), is not one.
REDIRECT = re.compile(r"(?:(?:^|(?<=[\s;&|()]))(?:\d+|\{[A-Za-z_]\w*\}))?"
                      r"(?:&>>?|<<<|<>|>>|>\||>&|<&|>|<)(?!\()[ \t]*[^\s;&|()<>]*")
# The word a command substitution, backquote or process substitution becomes
# before the command is split, and what each one runs. The word carries a
# number fresh for each run, so a command can't spell one out itself.
NONCE = os.urandom(4).hex()
SUBSTITUTION = re.compile(r"\$\{GUARD_SUB_" + NONCE + r"_(\d+)\}")
SUBS = {}
# What xargs adds to the command it runs, or puts where its -I string or
# find's {} stands: words that are known only when the command runs.
XARGS = "${GUARD_XARGS}"
POSITIONAL = re.compile(r"\$(\{[0-9@*]\}|[0-9@*])")
# A folder worked out only when the command runs, where that could be any
# checkout: a GIT_DIR or --work-tree value from a substitution, or what xargs
# or find hands a command. A git command there may only read.
UNKNOWN = "/guard-git/worked-out-at-run-time"
# Environment variables that point git at another repo, index or object store
# than the folder it runs in, and at another working tree.
GIT_DIRS = ("GIT_DIR", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY")
GIT_VARS = GIT_DIRS + ("GIT_WORK_TREE",)

# Git subcommands that only read, whatever their arguments.
READS = {"status", "log", "show", "diff", "blame", "annotate", "grep", "ls-files", "ls-tree", "rev-parse",
         "rev-list", "for-each-ref", "cat-file", "describe", "shortlog", "help", "version", "var",
         "check-ignore", "check-attr", "name-rev", "merge-base", "cherry", "range-diff", "whatchanged",
         "count-objects", "verify-commit", "verify-tag", "show-ref", "show-branch", "ls-remote",
         "diff-tree", "diff-files", "diff-index"}
# The flags git branch and git tag take when they only list, and the ones that
# make a name after them a pattern or a commit rather than a branch to create.
LISTS = {"-a", "--all", "-r", "--remotes", "-l", "--list", "-v", "-vv", "--verbose", "--show-current",
         "--contains", "--no-contains", "--merged", "--no-merged", "--points-at", "--sort", "--format",
         "--column", "--no-column", "--color", "--no-color", "-i", "--ignore-case", "--abbrev",
         "--no-abbrev", "--omit-empty"}
FILTERS = {"-l", "--list", "--contains", "--no-contains", "--merged", "--no-merged", "--points-at"}
CONFIG_WRITES = {"--unset", "--unset-all", "--add", "--replace-all", "--remove-section", "--rename-section",
                 "-e", "--edit"}
CONFIG_READS = {"--get", "--get-all", "--get-regexp", "--get-urlmatch", "--get-color", "--get-colorbool",
                "-l", "--list"}
# Options of git clone and git init that take the next word as their value.
NEW_REPO_VALUES = {"-b", "--branch", "-o", "--origin", "-c", "--config", "-u", "--upload-pack", "--depth",
                   "--reference", "--reference-if-able", "--separate-git-dir", "--template", "-j", "--jobs",
                   "--shallow-since", "--shallow-exclude", "--server-option", "--bundle-uri", "--filter",
                   "--initial-branch", "--object-format", "--ref-format", "--revision"}
GH_READS = ("view", "list", "ls", "diff", "checks", "status", "")
# A URL, an scp-style host:path or a refspec such as HEAD:main, rather than a
# repo named by its path: a colon comes before any slash.
URL = re.compile(r"^[^/]*:")
# Git subcommands that move a checkout's HEAD, index or working tree, whatever
# their arguments. check_git weighs switch, checkout, merge, pull, apply,
# submodule, fetch and worktree add by their arguments.
MOVES = {"reset", "restore", "add", "rm", "mv", "commit", "clean", "am", "cherry-pick", "revert", "rebase",
         "bisect", "read-tree", "checkout-index", "update-index"}
# Options of xargs, BSD and GNU, that take a value, attached or as the next word.
XARGS_VALUES = "EIJLnPRSsad"
XARGS_LONG_VALUES = ("--arg-file", "--delimiter", "--max-args", "--max-procs", "--max-chars",
                     "--process-slot-var")
# chezmoi's options that take the next word as their value.
CHEZMOI_VALUES = {"-S", "--source", "-W", "--working-tree", "-D", "--destination", "-c", "--config",
                  "--config-format", "--cache", "--persistent-state", "--color", "--mode", "-o", "--output",
                  "--override-data", "--override-data-file", "--progress", "--use-builtin-age",
                  "--use-builtin-git", "--age-recipient", "--age-recipient-file"}
# chezmoi commands that write its source folder.
CHEZMOI_WRITES = {"add", "re-add", "edit", "edit-encrypted", "edit-config-template", "chattr", "forget",
                  "import", "merge", "merge-all", "push", "update"}
# chezmoi commands that change this Mac whatever --source or --destination
# says: they write chezmoi's config and state, apply runs the setup scripts
# against the real machine, destroy deletes the live file with its source, and
# purge deletes chezmoi's config, state and the source folder it is given.
CHEZMOI_LIVE = {"apply", "init", "update", "destroy", "purge", "edit-config"}
# chezmoi state's subcommands that write its persistent state.
CHEZMOI_STATE_WRITES = {"delete", "delete-bucket", "reset", "set"}

# The branches a command has switched each folder to so far, oldest first.
HISTORY = {}
# Each folder's default branch on origin.
DEFAULTS = {}
# Each folder's owner, as owner_of() works it out.
OWNERS = {}
HOME = os.path.expanduser("~")
SRC = os.path.realpath(os.path.join(HOME, "src"))
DROPBOX = os.path.realpath(os.path.join(HOME, "Library/CloudStorage/Dropbox"))
DROPBOX_REPOS = os.path.realpath(os.path.join(HOME, "Library/CloudStorage/Dropbox/repositories"))
DOTFILES = os.path.realpath(os.path.join(HOME, ".local/share/chezmoi"))


def block(reason):
    print(f"BLOCKED by guard-git.py: {reason}", file=sys.stderr)
    sys.exit(2)


def git_out(directory, *args):
    try:
        result = subprocess.run(
            ["git", "-C", directory, *args], capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def is_unknown(path):
    return path == UNKNOWN or path.startswith(UNKNOWN + os.sep)


def resolve(cwd, path):
    """A folder or file the command names, from cwd.

    A name worked out only when the command runs, such as
    `cd "$(git rev-parse --show-toplevel)"`, almost always stays in the same
    repo, so it counts as cwd. A $(mktemp ...) never gets here: check() has
    already made it MKTEMP_PATH, which is in no repo. What xargs or find hands
    over could be anywhere, so it is UNKNOWN."""
    if XARGS in path:
        return UNKNOWN
    path = os.path.expanduser(os.path.expandvars(path))
    if "$" in path or "`" in path:
        return cwd
    if is_unknown(cwd) and not os.path.isabs(path):
        return UNKNOWN
    return os.path.join(cwd, path)


def resolve_dest(cwd, path, new=True):
    """Where a folder that git worktree add, git clone, gh repo clone or chezmoi
    --source names would be, from cwd.

    A name with a part worked out when the command runs, as in
    ~/worktrees/<repo>/fix-$(date +%s), is judged by the folder its literal
    part names, as long as no protected checkout could sit below that folder.
    Otherwise a new folder could be anywhere, so it is UNKNOWN, and an existing
    one counts as cwd, as resolve() has it."""
    if XARGS in path:
        return UNKNOWN
    path = os.path.expanduser(os.path.expandvars(path))
    cut = min([path.find(c) for c in "$`" if c in path] or [-1])
    if cut < 0:
        return resolve(cwd, path)
    head = path[:cut]
    if not head:
        return UNKNOWN if new else cwd
    folder = resolve(cwd, head[:head.rfind("/") + 1] if "/" in head else ".")
    real = os.path.realpath(folder)
    if is_unknown(folder) or any(root == real or root.startswith(real.rstrip(os.sep) + os.sep)
                                 for root in (DROPBOX_REPOS, SRC, DOTFILES)):
        return UNKNOWN if new else cwd
    return folder


def place(directory, value, file=False):
    """The folder a --git-dir, --work-tree or GIT_ variable's value names, from
    directory: for GIT_INDEX_FILE, the folder holding the file."""
    if value is None or XARGS in value:
        return UNKNOWN
    value = os.path.expanduser(os.path.expandvars(value))
    if "$" in value or "`" in value or is_unknown(value) or (is_unknown(directory) and not os.path.isabs(value)):
        return UNKNOWN
    path = os.path.join(directory, value)
    return os.path.dirname(path) if file else path


def branch(directory):
    history = HISTORY.get(os.path.realpath(directory))
    if history:
        return history[-1]
    return git_out(directory, "symbolic-ref", "--short", "-q", "HEAD")


def protected(directory):
    directory = os.path.realpath(directory)
    if directory not in DEFAULTS:
        origin_head = git_out(directory, "symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD")
        DEFAULTS[directory] = origin_head.split("/", 1)[-1] if origin_head else ""
    return ALWAYS_PROTECTED | ({DEFAULTS[directory]} - {""})


def mask_quotes(line):
    """The line with every quoted character replaced, so patterns only see shell syntax.

    $'...' quoting counts, with its backslash escapes."""
    out, quote, escaped, i = [], None, False, 0
    while i < len(line):
        ch = line[i]
        if escaped:
            out.append("x")
            escaped = False
        elif ch == "\\" and quote != "'":
            out.append("x")
            escaped = True
        elif quote:
            out.append(ch if ch == quote[-1] else "x")
            if ch == quote[-1]:
                quote = None
        elif ch == "$" and line[i + 1:i + 2] == "'":
            out.append("$'")
            quote = "$'"
            i += 1
        elif ch in "'\"":
            out.append(ch)
            quote = ch
        else:
            out.append(ch)
        i += 1
    return "".join(out)


def unfold(command):
    """The command as the shell reads it: comments dropped and continued lines joined.

    One pass over the whole text, so a quote opened on one line is still open
    on the next. A comment is an unquoted # that starts a word. A backslash
    and newline outside single quotes join two lines into one, unless the
    backslash is itself escaped. In $'...' a backslash escapes the quote."""
    out, quote, starts_word, i = [], None, True, 0
    while i < len(command):
        ch = command[i]
        if ch == "\\" and quote != "'":
            if command[i + 1:i + 2] == "\n":
                i += 2
                continue
            out.append(command[i:i + 2])
            starts_word = False
            i += 2
            continue
        if quote:
            if ch == quote[-1]:
                quote = None
        elif ch == "$" and command[i + 1:i + 2] == "'":
            out.append("$'")
            quote = "$'"
            starts_word = False
            i += 2
            continue
        elif ch in "'\"":
            quote = ch
        elif ch == "#" and starts_word:
            end = command.find("\n", i)
            i = len(command) if end < 0 else end
            continue
        out.append(ch)
        starts_word = quote is None and ch in " \t\n;&|()"
        i += 1
    return "".join(out)


def feeds_shell(prefix):
    """The shell, such as bash, that the command a here-document belongs to
    is, when it reads its script from it, or ''."""
    prefix = REDIRECT.sub(lambda m: " " * len(m.group()), prefix)
    piece = re.split(r"[;&|(]", prefix)[-1]
    try:
        words = shlex.split(piece)
    except ValueError:
        words = piece.split()
    words = strip_prefix(words)
    if words and os.path.basename(words[0]) in SHELLS and all(w.startswith("-") for w in words[1:]):
        return os.path.basename(words[0])
    return ""


def heredocs(command):
    """The command without here-document bodies, the bodies a shell runs as
    scripts, each with that shell's name, and the other bodies, which may
    become a commit message or PR body."""
    lines, out, scripts, texts, i = command.split("\n"), [], [], [], 0
    while i < len(lines):
        line, masked = lines[i], mask_quotes(lines[i])
        # Matched on the line itself, so a quoted terminator keeps its name,
        # but only where the << is outside quotes and before any comment.
        comment = re.search(r"(^|[\s;&|()])#", masked)
        cut = comment.end() - 1 if comment else len(line)
        operators = [m for m in HEREDOC.finditer(line)
                     if m.start() < cut and masked[m.start():m.start() + 2] == "<<"]
        j, bodies = i + 1, []
        for match in operators:
            body = []
            while j < len(lines) and lines[j].strip() != match.group(2):
                body.append(lines[j])
                j += 1
            if j >= len(lines):
                # No terminator: not a here-document after all, so drop nothing.
                bodies = None
                break
            j += 1
            bodies.append((match, body))
        if not operators or bodies is None:
            out.append(line)
            i += 1
            continue
        kept, last = [], 0
        for match, body in bodies:
            kept.append(line[last:match.start()])
            last = match.end()
            shell = feeds_shell(masked[:match.start()])
            if shell:
                scripts.append((shell, "\n".join(body)))
            else:
                texts.append("\n".join(body))
        kept.append(line[last:])
        out.append(" ".join(kept))
        i = j
    return "\n".join(out), scripts, texts


def no_credit(command, texts):
    """Block a commit or PR when text this command writes on its way to one credits an AI.

    That text is a here-document body or a variable's value: `git commit -F -`
    reads one, and `cat > msg.txt <<EOF` or `body=$(cat <<EOF ...)` hand one
    to a later `git commit -F msg.txt` or `--body "$body"`, whose file doesn't
    exist yet when this runs. It is also the command itself, for a message
    printf or echo writes to a file or pipes into git commit -F -. Any such
    text counts once the command commits or opens or edits a PR."""
    built = BUILT_CREDIT.search(re.sub(r"\\+n", "\n", command))
    if not built and not any(AI_CREDIT.search(text) for text in texts):
        return
    elsewhere = ("If that text is a file's content rather than the {}, write the file in one "
                 "command and run {} in the next.")
    if re.search(r"\bgit\b[\s\S]*\bcommit\b", command):
        block("this commit message credits an AI. A commit here is never co-authored by an AI agent: "
              "drop the Co-Authored-By or Generated-with line and commit again. "
              + elsewhere.format("message", "git commit"))
    if re.search(r"\bgh\b[\s\S]*\bpr\s+(create|new|edit)\b", command):
        block("this PR credits an AI. Nothing here is credited to an AI agent: drop the line and try again. "
              + elsewhere.format("PR body", "gh pr"))


def ansi_end(command, i):
    """Where the $'...' whose text starts at i closes, or None."""
    while i < len(command):
        if command[i] == "\\":
            i += 2
            continue
        if command[i] == "'":
            return i
        i += 1
    return None


def ansi(text):
    """The text of $'...' with its common escapes turned into what they stand for."""
    escapes = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f",
               "v": "\v", "\\": "\\", "'": "'", '"': '"', "?": "?"}
    return re.sub(r"\\(.)", lambda m: escapes.get(m.group(1), m.group(0)), text, flags=re.S)


def closing(command, i, close=")"):
    """Where the substitution whose text starts at i ends: the index of its ) or
    closing backquote, or None. A here-document inside it is skipped whole."""
    if close == "`":
        while i < len(command):
            if command[i] == "\\":
                i += 2
                continue
            if command[i] == "`":
                return i
            i += 1
        return None
    depth, quote = 1, None
    while i < len(command):
        ch = command[i]
        if quote == "'":
            if ch == "'":
                quote = None
        elif ch == "\\":
            i += 1
        elif quote == '"':
            if ch == '"':
                quote = None
            elif command.startswith("$(", i) or ch == "`":
                end = closing(command, i + (1 if ch == "`" else 2), "`" if ch == "`" else ")")
                if end is None:
                    return None
                i = end
        elif ch == "#" and (i == 0 or command[i - 1] in " \t\n;&|()"):
            # A comment, which runs to the end of its line; a quote in it
            # opens nothing.
            end = command.find("\n", i)
            if end < 0:
                return None
            i = end
        elif ch in "'\"":
            quote = ch
        elif command.startswith("$'", i):
            end = ansi_end(command, i + 2)
            if end is None:
                return None
            i = end
        elif ch == "`":
            end = closing(command, i + 1, "`")
            if end is None:
                return None
            i = end
        elif command.startswith("<<", i) and not command.startswith("<<<", i) and HEREDOC.match(command, i):
            match = HEREDOC.match(command, i)
            eol = command.find("\n", match.end())
            terminator = re.compile(r"^[ \t]*" + re.escape(match.group(2)) + r"[ \t]*$", re.M)
            found = terminator.search(command, eol + 1) if eol >= 0 else None
            if found is None:
                return None
            i = found.end() - 1
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return None


def lift(command):
    """The command with each command substitution, backquote and process
    substitution outside single quotes made one ${GUARD_SUB_n} word, and $'...'
    quoting made plain, so shlex can split it as the shell would. SUBS keeps
    what each substitution runs, and the second value lists their numbers.

    One with a here-document inside stays as it is, so its text still counts
    as a message, as in -m "$(cat <<'EOF' ...)". When one is left open, the
    command comes back unchanged."""
    out, quote, lifted, i = [], None, [], 0
    while i < len(command):
        ch = command[i]
        if quote == "'":
            if ch == "'":
                quote = None
            out.append(ch)
            i += 1
            continue
        if ch == "\\":
            out.append(command[i:i + 2])
            i += 2
            continue
        if quote is None and command.startswith("$'", i):
            end = ansi_end(command, i + 2)
            if end is None:
                return command, []
            out.append(shlex.quote(ansi(command[i + 2:end])))
            i = end + 1
            continue
        if ch == '"' or (quote is None and ch == "'"):
            quote = None if quote == ch else ch
            out.append(ch)
            i += 1
            continue
        start = None
        if command.startswith("$(", i) and not command.startswith("$((", i):
            start = i + 2
        elif quote is None and command[i:i + 2] in ("<(", ">("):
            start = i + 2
        elif ch == "`":
            start = i + 1
        if start is None:
            out.append(ch)
            i += 1
            continue
        end = closing(command, start, "`" if ch == "`" else ")")
        if end is None:
            return command, []
        inner = command[start:end]
        if re.search(r"(?<!<)<<(?!<)-?\s*['\"]?[A-Za-z_]", inner):
            out.append(command[i:end + 1])
        else:
            number = len(SUBS)
            SUBS[number] = inner.replace("\\`", "`") if ch == "`" else inner
            lifted.append(number)
            out.append("${GUARD_SUB_%s_%d}" % (NONCE, number))
        i = end + 1
    return "".join(out), lifted


def tokens(command):
    """The command as simple commands, each a list of words, and the separators
    between them, each the string shlex gives, such as ';', '&&' or ')|'.
    Redirections are dropped first, wherever they sit."""
    # A newline outside quotes ends a command; one inside quotes stays in its
    # word, so each line of a quoted message is still a line. A quoted or
    # escaped operator character, which mask_quotes() has replaced, is hidden
    # from shlex until it is back in its word, so `find . \( -name a \)` and
    # `-exec git add {} \;` stay one command.
    masked = mask_quotes(command)
    chars = list(command)
    for match in REDIRECT.finditer(masked):
        chars[match.start():match.end()] = " " * (match.end() - match.start())
    command = "".join(";" if m == "\n" else HIDDEN.get(c, c) if c != m else c for c, m in zip(chars, masked))
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()")
    lexer.whitespace_split = True
    lexer.commenters = ""
    words, out = [], []
    for token in lexer:
        # An empty token is a quoted empty word, such as find's -name "".
        if token and (token in CONTROL or set(token) <= set(";&|()")):
            if words:
                out.append(words)
            words = []
            out.append(token)
        else:
            words.append(token.translate(SHOWN))
    if words:
        out.append(words)
    return out


def segments(command):
    """Split a command line into simple commands, each a list of words."""
    return [item for item in tokens(command) if isinstance(item, list)]


def separators(item):
    """The operators in a separator token, in order: shlex runs neighbours
    together, as in ')&&' or '));'. Nothing for a list of words."""
    if not isinstance(item, str):
        return []
    return re.findall(r"\(|\)|&&|\|\||;;|\|&|[;&|]", item)


def split_prefix(words):
    """The command's own words, after shell keywords, NAME=value assignments and
    wrappers such as env or timeout, and what those set for it: the assignments
    in order, as (name, value), with None as the value env -u drops; whether
    env -i left nothing else set; and the folder env -C runs it in."""
    assigned, cleared, chdir = [], False, None
    while words:
        head = words[0]
        if head in KEYWORDS:
            words = words[1:]
        elif ASSIGNMENT.match(head):
            assigned.append(ASSIGNMENT.match(head).groups())
            words = words[1:]
        elif head == "env":
            words = words[1:]
            while words and words[0].startswith("-"):
                flag, words = words[0], words[1:]
                if flag == "--":
                    break
                name, eq, value = flag.partition("=")
                if flag in ("-", "--ignore-environment"):
                    cleared, assigned = True, []
                    continue
                if name in ("--unset", "--chdir", "--split-string"):
                    if not eq and words:
                        value, words = words[0], words[1:]
                    letter = {"--unset": "u", "--chdir": "C", "--split-string": "S"}[name]
                elif flag.startswith("--"):
                    continue
                else:
                    letter, value = "", ""
                    for n, ch in enumerate(flag[1:], 1):
                        if ch == "i":
                            cleared, assigned = True, []
                        elif ch in "uCPSLU":
                            letter, value = ch, flag[n + 1:]
                            if not value and words:
                                value, words = words[0], words[1:]
                            break
                if letter == "u":
                    assigned.append((value, None))
                elif letter == "C":
                    chdir = value
                elif letter == "S":
                    try:
                        words = shlex.split(value) + words
                    except ValueError:
                        words = value.split() + words
        elif head in WRAPPERS:
            takes_value = WRAPPERS[head]
            words = words[1:]
            while words and words[0].startswith("-"):
                words = words[2:] if words[0] in takes_value else words[1:]
        elif head == "timeout":
            words = words[1:]
            while words and words[0].startswith("-"):
                takes_value = words[0] in ("-s", "-k", "--signal", "--kill-after")
                words = words[2:] if takes_value else words[1:]
            if words and re.match(r"^\d+(\.\d+)?[smhd]?$", words[0]):
                words = words[1:]
        elif head == "nice":
            words = words[1:]
            if words and words[0] == "-n":
                words = words[2:]
            elif words and re.match(r"^-\d+$", words[0]):
                words = words[1:]
        else:
            break
    return words, assigned, cleared, chdir


def strip_prefix(words):
    """Drop shell keywords, VAR=value assignments and wrappers such as env or timeout."""
    return split_prefix(words)[0]


def plain_values(parts):
    """The variables a command sets only as plain NAME=value commands, all to the same value.

    That is the `b=fix-x; git push origin "$b"` or `WT="$HOME/worktrees/x";
    cd "$WT"` case, with ~, the environment's variables and the plain values
    set before it expanded, as in `b=fix; wt=~/worktrees/x/$b`, and export,
    local, declare, typeset or readonly in front counting as plain. A name
    assigned any other way anywhere in the command (from a substitution, by
    read or for, or as a prefix on another command) is left out, and so is one
    built from a name left out, so its value is worked out as before."""
    values, spoiled, uses = {}, set(), {}
    for words in parts:
        assigned = None
        if words and all(ASSIGNMENT.match(w) for w in words):
            assigned = words
        elif words and words[0] in DECLARERS and all(
                ASSIGNMENT.match(w) or re.match(r"^(-[xrg]+|[A-Za-z_][A-Za-z0-9_]*)$", w) for w in words[1:]):
            assigned = [w for w in words[1:] if ASSIGNMENT.match(w)]
        if assigned is not None:
            for word in assigned:
                name, value = ASSIGNMENT.match(word).groups()
                uses.setdefault(name, set()).update(a or b for a, b in re.findall(
                    r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))", value))
                plain = {n: v for n, v in values.items() if n not in spoiled}
                value = os.path.expanduser(os.path.expandvars(substitute(value, plain)))
                if "$" in value or "`" in value or values.get(name, value) != value:
                    spoiled.add(name)
                values.setdefault(name, value)
            continue
        spoiled.update(ASSIGNMENT.match(w).group(1) for w in words if ASSIGNMENT.match(w))
        command = strip_prefix(words)
        if command and os.path.basename(command[0]) in SETTERS:
            spoiled.update(w.split("=", 1)[0] for w in command[1:])
    # A name reassigned later, as in a loop, leaves the values built from it stale.
    while True:
        stale = {name for name, used in uses.items() if name not in spoiled and used & spoiled}
        if not stale:
            break
        spoiled |= stale
    return {name: value for name, value in values.items() if name not in spoiled}


def assigned_names(parts):
    """Every name the command assigns, in any way."""
    names = set()
    for words in parts:
        names.update(ASSIGNMENT.match(w).group(1) for w in words if ASSIGNMENT.match(w))
        command = strip_prefix(words)
        if command and os.path.basename(command[0]) in SETTERS:
            names.update(w.split("=", 1)[0] for w in command[1:])
    return names


def substitute(word, known):
    return re.sub(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))",
                  lambda m: known.get(m.group(1) or m.group(2), m.group(0)), word)


def env_value(value, known):
    """A GIT_ variable's value as the command sets it, or UNKNOWN when it is worked out at run time."""
    value = os.path.expanduser(os.path.expandvars(substitute(value, known)))
    return UNKNOWN if "$" in value or "`" in value else value


def is_branch(directory, name):
    return bool(git_out(directory, "rev-parse", "--verify", "-q", f"refs/heads/{name}")
                or git_out(directory, "rev-parse", "--verify", "-q", f"refs/remotes/origin/{name}"))


def switched(directory, name):
    key = os.path.realpath(directory)
    history = HISTORY.setdefault(key, [])
    if not history:
        history.append(git_out(directory, "symbolic-ref", "--short", "-q", "HEAD"))
    history.append(name)


def tracked(directory, name):
    """The local branch checkout --track makes for name: origin/fix becomes fix."""
    name = re.sub(r"^refs/remotes/", "", name)
    remote, _, rest = name.partition("/")
    return rest if rest and remote in git_out(directory, "remote").split() else name


def previous_branch(directory):
    history = HISTORY.get(os.path.realpath(directory))
    if history and len(history) >= 2:
        return history[-2]
    return git_out(directory, "rev-parse", "--abbrev-ref", "@{-1}")


def owner_of(directory):
    """Whose checkout this is, and its name: ("agent", name) for a clone in
    ~/src, ("dropbox", name) for a repo in Dropbox's repositories folder,
    the repos' old home, ("dotfiles", name), ("unknown", "") for a
    folder worked out only when the command runs, or ("", "") for an ordinary
    repo or no repo at all.

    Every worktree of an agent repo counts, and so does a submodule inside
    one; in_main_checkout() tells its main checkout from the rest. Every
    worktree of a repo in Dropbox shares its .git there, so they all count.
    Only the dotfiles' main checkout counts: a worktree of them elsewhere
    leaves the live config's files alone. A repo's .git folder counts as its
    checkout."""
    if is_unknown(directory):
        return ("unknown", "")
    key = os.path.realpath(directory)
    if key not in OWNERS:
        OWNERS[key] = ("", "")
        common = git_out(directory, "rev-parse", "--path-format=absolute", "--git-common-dir")
        top = os.path.realpath(os.path.dirname(common)) if common else ""
        if top == DOTFILES:
            here = os.path.realpath(git_out(directory, "rev-parse", "--show-toplevel") or directory)
            if here == DOTFILES or here.startswith(DOTFILES + os.sep):
                OWNERS[key] = ("dotfiles", "dotfiles")
        elif top.startswith(DROPBOX_REPOS + os.sep):
            OWNERS[key] = ("dropbox", os.path.relpath(top, DROPBOX_REPOS).split(os.sep)[0])
        elif top.startswith(SRC + os.sep):
            # A submodule's git dir sits inside its superproject's .git/modules.
            OWNERS[key] = ("agent", os.path.relpath(top, SRC).split(os.sep)[0])
    return OWNERS[key]


def lands_in(path):
    """The owner of the checkout a new folder at path would be made in, or
    ("src", "") for one in ~/src, which holds only the clones chezmoi makes."""
    if is_unknown(path):
        return ("unknown", "")
    real = os.path.realpath(path)
    parent = real
    while not os.path.isdir(parent) and parent != os.path.dirname(parent):
        parent = os.path.dirname(parent)
    kind, name = owner_of(parent)
    if kind in ("dropbox", "dotfiles"):
        return kind, name
    if real.startswith(DROPBOX_REPOS + os.sep):
        # A new repo in Dropbox's repositories folder would be one of its repos too.
        return "dropbox", os.path.relpath(real, DROPBOX_REPOS).split(os.sep)[0]
    if real == SRC or real.startswith(SRC + os.sep):
        return "src", ""
    return kind, name


def unknown_place(what):
    """Block any use of a folder worked out only when the command runs. what names the command."""
    block(f"{what} would use a folder worked out only when the command runs, from a substitution, read, "
          "a for loop, xargs or find, so there's no telling whether it is a repo in Dropbox, an agent repo's "
          "main checkout in ~/src or the dotfiles checkout. Name the folder in the command, or run the command "
          "from inside it.")


def never_written(kind, name, what):
    """Block any use of a repo in Dropbox or a folder worked out at run time, a
    write to the dotfiles' main checkout, or a new folder in ~/src. what names
    the command."""
    if kind == "unknown":
        unknown_place(what)
    if kind == "dropbox":
        block(f"{what} would use {name} in Dropbox's repositories folder, the repos' old home, which "
              "nothing on this Mac uses, not even to read. Read it on GitHub, or "
              f"clone it from GitHub into ~/worktrees/{name}/<branch>.")
    if kind == "dotfiles":
        block(f"{what} would write the dotfiles checkout, this Mac's live config, which is never "
              "changed in place, attended or not. Reading is fine, and so are git fetch, git remote set-head, "
              "git worktree add to a folder outside it, and git worktree lock or unlock. Make a worktree in "
              "~/worktrees/dotfiles/<branch> and work there.")
    if kind == "src":
        block(f"{what} would make a new repo or worktree in ~/src. That folder holds only the clones chezmoi "
              "makes, and nothing here adds to it, attended or not. Clone a repo into ~/worktrees/<repo>/<branch> "
              "instead, or for one of the clones in ~/src, make a worktree there: git fetch origin, then git "
              "worktree add --no-track -b <branch> ~/worktrees/<repo>/<branch> origin/HEAD")


def in_main_checkout(directory, name):
    """Whether directory is part of agent repo name's main checkout, its clone
    in ~/src: its working tree, a submodule inside it, or its own .git folder,
    rather than a worktree of it, wherever that is, or a worktree's folder in
    .git/worktrees."""
    dirs = git_out(directory, "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir")
    dirs = dirs.splitlines()
    if len(dirs) == 2 and dirs[0] != dirs[1]:
        return False
    top = os.path.realpath(git_out(directory, "rev-parse", "--show-toplevel") or directory)
    root = os.path.join(SRC, name)
    return top == root or top.startswith(root + os.sep)


def under_dropbox(directory):
    """Whether the repo at directory, or the .git it uses, is under Dropbox,
    which syncs it between the Macs. A folder worked out only when the command
    runs could be."""
    if is_unknown(directory):
        return True
    common = git_out(directory, "rev-parse", "--path-format=absolute", "--git-common-dir")
    return any(os.path.realpath(p) == DROPBOX or os.path.realpath(p).startswith(DROPBOX + os.sep)
               for p in (directory, common) if p)


def in_place(name, what):
    """Block a change to an agent repo's main checkout in ~/src. what names the command."""
    block(f"{what} would change {name}'s main checkout in ~/src, which T3's threads and FirstMate start "
          "from, and nothing here switches, commits or resets it, attended or not. Reading is fine, and so "
          "are git fetch, pushing your own branch, git branch -d, git remote set-head and git worktree add "
          "outside ~/src. Work in a worktree: git fetch origin, then git worktree add --no-track -b <branch> "
          f"~/worktrees/{name}/<branch> origin/HEAD")


def moves_checkout(sub, args, repo, directory):
    """Whether this git command moves the HEAD, index or working tree of the checkout it runs in."""
    flags = [a for a in args if a.startswith("-")]
    names = [a for a in args if not a.startswith("-")]
    if sub in MOVES:
        return True
    if sub in ("switch", "checkout"):
        # Back to the default branch is the way out of a stray one.
        back = not names or (len(names) == 1 and names[0] in protected(repo))
        return not (back and all(f in ("-q", "--quiet") for f in flags))
    if sub in ("merge", "pull"):
        return not ("--ff-only" in args and from_origin(sub, args, repo))
    if sub == "apply":
        return "--apply" in flags or not {"--check", "--stat", "--numstat", "--summary"} & set(flags)
    if sub == "submodule":
        return names[:1] in (["update"], ["add"], ["deinit"], ["absorbgitdirs"], ["set-branch"], ["set-url"])
    if sub == "fetch":
        return any(a in ("-u", "--update-head-ok") for a in args)
    if sub == "worktree" and args[:1] == ["add"]:
        return not makes_worktree(sub, args, directory, SRC)
    return False


def short_flags(flags):
    """The flags with each single-dash cluster, such as -av, split into its
    letters, and a count after -n, as in -ln3, kept with it."""
    out = []
    for flag in flags:
        cluster = re.match(r"^-([A-Za-z]+?)(n\d*)?$", flag)
        if cluster and len(flag) > 2:
            out += ["-" + letter for letter in cluster.group(1)]
            out += ["-" + cluster.group(2)] if cluster.group(2) else []
        else:
            out.append(flag)
    return out


def only_reads(sub, args):
    """Whether this git command only reads, as the dotfiles checkout allows."""
    flags = [a.split("=", 1)[0] for a in args if a.startswith("-")]
    names = [a for a in args if not a.startswith("-")]
    if sub in READS:
        return True
    if sub in ("branch", "tag"):
        # Listing only: no name to create, delete, rename or move, unless a
        # flag such as --list or --contains takes it as a pattern or a commit.
        flags = short_flags(flags)
        return (all(f in LISTS or re.match(r"^-n\d*$", f) for f in flags)
                and (not names or any(f in FILTERS for f in flags)))
    if sub == "config":
        values = ("-f", "--file", "--blob", "--default", "--type", "--comment")
        names = [a for n, a in enumerate(args) if not a.startswith("-") and not (n and args[n - 1] in values)]
        if set(flags) & CONFIG_WRITES or names[:1] in (["set"], ["unset"], ["rename-section"],
                                                        ["remove-section"], ["edit"]):
            return False
        return bool(set(flags) & CONFIG_READS) or names[:1] in (["get"], ["list"]) or len(names) == 1
    if sub == "remote":
        return all(f in ("-v", "--verbose", "-n", "--push", "--all") for f in flags) and names[:1] in (
            [], ["show"], ["get-url"])
    if sub == "worktree":
        return names[:1] == ["list"]
    if sub == "stash":
        return names[:1] in (["list"], ["show"])
    if sub == "notes":
        return names[:1] in ([], ["list"], ["show"])
    if sub == "submodule":
        return names[:1] in ([], ["status"], ["summary"])
    if sub == "symbolic-ref":
        return len(names) == 1 and not {"-d", "--delete"} & set(flags)
    if sub == "reflog":
        return names[:1] not in (["expire"], ["delete"], ["drop"], ["write"])
    if sub == "lfs":
        return names[:1] in (["ls-files"], ["status"], ["env"], ["version"])
    return False


def repo_paths(sub, args, directory):
    """The folders a git clone, fetch, pull, push, ls-remote or archive, a git
    remote add or set-url, or a git submodule add could take as the other repo
    it reads or writes: each word but a flag, a URL, a refspec or a name worked
    out when the command runs, and the value of each --option=value. A
    file:// URL counts as its path, and what xargs or find hands over as a
    folder that can't be told."""
    if sub == "remote":
        if args[:1] not in (["add"], ["set-url"]):
            return []
    elif sub == "submodule":
        if args[:1] != ["add"]:
            return []
    elif sub not in ("clone", "fetch", "pull", "push", "ls-remote", "archive"):
        return []
    paths = []
    for arg in args:
        if arg.startswith("--") and "=" in arg:
            arg = arg.split("=", 1)[1]
        elif arg.startswith("-"):
            continue
        if arg.startswith("file://"):
            arg = arg[len("file://"):]
        elif URL.match(arg):
            continue
        if XARGS not in arg:
            arg = os.path.expanduser(os.path.expandvars(arg))
            if "$" in arg or "`" in arg:
                continue
        paths.append(resolve(directory, arg))
    return paths


def worktree_dest(args, directory):
    """Where git worktree add puts the new worktree, or None if it names no folder."""
    positional, n = [], 1
    while n < len(args):
        if args[n] in ("-b", "-B", "--reason"):
            n += 2
            continue
        if not args[n].startswith("-"):
            positional.append(args[n])
        n += 1
    return resolve_dest(directory, positional[0]) if positional else None


def makes_worktree(sub, args, directory, root=DOTFILES):
    """Whether this is a step in making a worktree of the dotfiles outside their checkout:
    git fetch, git remote set-head, or git worktree add to a folder outside root."""
    if sub == "fetch":
        # Not into a local branch: that could move the one checked out.
        return not any(":" in a or a in ("-u", "--update-head-ok") for a in args)
    if sub == "remote":
        return args[:1] == ["set-head"]
    if sub == "worktree" and args[:1] == ["add"]:
        dest = worktree_dest(args, directory)
        if dest is None or is_unknown(dest):
            return False
        path = os.path.realpath(dest)
        return path != root and not path.startswith(root + os.sep)
    return False


def keeps_worktree(sub, args):
    """git worktree lock or unlock, which AGENTS.md uses to keep a worktree: it only
    writes that worktree's folder in .git/worktrees, and git refuses it on the main one."""
    return sub == "worktree" and args[:1] in (["lock"], ["unlock"])


def made_by(sub, args, directory):
    """The folders `git clone` or `git init` writes: the new checkout, and any --separate-git-dir."""
    positional, made, n = [], [], 0
    while n < len(args):
        arg = args[n]
        if arg in NEW_REPO_VALUES and n + 1 < len(args):
            if arg == "--separate-git-dir":
                made.append(args[n + 1])
            n += 2
            continue
        if arg.startswith("--separate-git-dir="):
            made.append(arg.split("=", 1)[1])
        elif not arg.startswith("-"):
            positional.append(arg)
        n += 1
    if sub == "init":
        made.append(positional[0] if positional else ".")
    elif len(positional) > 1:
        made.append(positional[1])
    elif positional:
        made.append(re.sub(r"\.git$", "", re.split(r"[/:]", positional[0].rstrip("/"))[-1]))
    return [resolve_dest(directory, path) for path in made]


def from_origin(sub, args, directory):
    """Whether a --ff-only merge or pull takes only origin's default branch,
    the one way the default branch moves here."""
    sources = [a for a in args if not a.startswith("-")]
    defaults = protected(directory)
    if sub == "pull":
        return not sources or (sources[0] == "origin" and all(s in defaults for s in sources[1:]))
    upstream = {f"origin/{d}" for d in defaults} | {"origin", "origin/HEAD", "@{u}", "@{upstream}"}
    return all(s in upstream for s in sources)


def check_git(words, cwd, env=None, blind=False):
    """Check one git command. env holds the GIT_ variables set for it; blind
    means xargs or find runs it, with words not known here."""
    env = env or {}
    directory = cwd
    dirs, trees = [], []
    i = 1
    while i < len(words) and words[i].startswith("-"):
        flag = words[i]
        if flag in ("-C", "--git-dir", "--work-tree") and i + 1 < len(words):
            value, i = words[i + 1], i + 2
        elif flag.startswith(("--git-dir=", "--work-tree=")):
            flag, value = flag.split("=", 1)
            i += 1
        else:
            if flag in ("-c", "--namespace", "--config-env", "--attr-source") and i + 1 < len(words):
                if flag == "-c" and re.match(r"(?i)^core\.worktree=", words[i + 1]):
                    trees.append(words[i + 1].split("=", 1)[1])
                i += 1
            i += 1
            continue
        if flag == "-C":
            directory = resolve(directory, value)
        else:
            (dirs if flag == "--git-dir" else trees).append(value)
    if i >= len(words):
        # What xargs or find hands over may be an option's value and the
        # subcommand after it, as in `echo ~/src/x reset --hard | xargs git -C`.
        if blind and any(XARGS in w for w in words):
            block("a git command whose subcommand xargs or find supplies when it runs. Name the subcommand.")
        return
    sub, args = words[i], words[i + 1:]

    # Every checkout the command names: the repo it uses, its index and object
    # store, and the working tree it writes, which with a repo named but no
    # working tree is the folder it runs in. The strictest of them rules.
    gitdirs = [place(directory, v) for v in dirs]
    gitdirs += [place(directory, env[n], n == "GIT_INDEX_FILE") for n in GIT_DIRS if n in env]
    worktrees = [place(directory, v) for v in trees]
    worktrees += [place(directory, env["GIT_WORK_TREE"])] if "GIT_WORK_TREE" in env else []
    named = dirs or "GIT_DIR" in env
    repo = gitdirs[len(dirs) - 1] if dirs else place(directory, env["GIT_DIR"]) if named else directory
    places = [repo] + gitdirs + worktrees + ([directory] if named and not worktrees else [])

    # Another repo it reads or writes by its path, such as a clone's source or
    # what fetch and push take, is never one in Dropbox either, nor one that
    # can't be told.
    for path in repo_paths(sub, args, directory):
        kind, name = lands_in(path)
        if kind in ("dropbox", "unknown"):
            never_written(kind, name, f"`git {sub}`")
    if sub in ("clone", "init"):
        # These write a new folder, not the repo they run in, and init
        # writes the one GIT_DIR names.
        for path in made_by(sub, args, directory) + (gitdirs + worktrees if named or worktrees else []):
            never_written(*lands_in(path), f"`git {sub}`")
        return
    what = f"`git {sub}`"
    if blind and XARGS in sub:
        block("a git command whose subcommand xargs or find supplies when it runs. Name the subcommand.")
    reads = sub in READS if blind else only_reads(sub, args)
    for where in places:
        kind, name = owner_of(where)
        if kind in ("unknown", "dropbox"):
            # Not even a read: a folder that can't be told could be in Dropbox.
            never_written(kind, name, what)
        if kind == "dotfiles" and not (reads or (not blind and (makes_worktree(sub, args, directory)
                                                              or keeps_worktree(sub, args)))):
            never_written(kind, name, what)
        if kind == "agent" and in_main_checkout(where, name) and (
                not reads if blind else moves_checkout(sub, args, repo, directory)):
            in_place(name, what)
    dest = worktree_dest(args, directory) if sub == "worktree" and args[:1] == ["add"] else None
    if dest is not None:
        # A new worktree goes nowhere a clone may not: not in ~/src, Dropbox's
        # repositories folder or the dotfiles checkout.
        never_written(*lands_in(dest), "`git worktree add`")

    if sub in ("gc", "repack", "prune", "maintenance") or (sub == "worktree" and args[:1] == ["prune"]):
        if any(under_dropbox(where) for where in places):
            label = "worktree prune" if sub == "worktree" else sub
            block(f"`git {label}` rewrites the repo's .git, and this repo is under ~/Library/CloudStorage/Dropbox, "
                  "which syncs it between the Macs; an object store there has already been destroyed once. It "
                  "runs as usual outside Dropbox, as in the clones in ~/src.")
    if sub == "worktree" and args[:1] == ["remove"] and any(a in ("--force", "-f") for a in args):
        block("`git worktree remove --force` throws away uncommitted work. Commit it, or leave the worktree.")
    if sub == "stash" and args[:1] not in (["list"], ["show"]):
        block("`git stash`: its stack is shared by every worktree of the repo. Commit work in progress on your branch.")
    if sub == "branch" and ("-D" in args or ("--delete" in args and ("--force" in args or "-f" in args))):
        block("`git branch -D` deletes unmerged work. Leave the branch, or ask in the PR.")
    skips_checks = "--no-verify" in args or (sub == "commit" and "-n" in args)
    if sub in ("commit", "push") and skips_checks:
        block(f"`git {sub} --no-verify` skips the repo's own checks. Fix what they report instead.")
    if sub == "push" and (any(a in ("--delete", "-d") for a in args) or any(r.startswith(":") for r in args if not r.startswith("-"))):
        block("`git push` that deletes a remote branch. Leave branches on GitHub to Carlos.")

    if sub == "push":
        if blind and any(XARGS in a for a in args):
            block("`git push` whose branch or options xargs or find supplies when it runs. Name the branch "
                  "in the command: git push -u origin <branch>.")
        for arg in args:
            if arg in ("--force", "--mirror", "--all") or arg.startswith(("--force-with-lease", "--force-if-includes")):
                block(f"`git push {arg}`. Never force-push or push every branch here; "
                      "if a branch needs rewritten history, push it under a new name.")
            if re.match(r"^-[A-Za-z]*f[A-Za-z]*$", arg):
                block("`git push -f`. Never force-push here; push a new branch instead.")
        refspecs = [a for a in args if not a.startswith("-")][1:]
        for ref in refspecs:
            if ref.startswith("+"):
                block(f"`git push {ref}` forces the update. Push a new branch instead.")
            target = re.sub(r"^refs/heads/", "", ref.split(":")[-1])
            if target in ("HEAD", "@") or "$" in ref or "`" in ref:
                # A name worked out when the command runs almost always means
                # the branch checked out now.
                target = branch(repo)
            if target in protected(repo):
                block(f"`git push` to {target}, the default branch. Push your own branch and open a draft PR.")
        current = branch(repo) if not refspecs else ""
        if current in protected(repo):
            block(f"`git push` while {current} is checked out. Work on your own branch, in a worktree "
                  "if this is the repo's main checkout.")

    elif sub in ("switch", "checkout"):
        names = [a for a in args if not a.startswith("-")]
        creating = any(a in CREATES for a in args)
        tracking = any(a in ("-t", "--track") or a.startswith("--track=") for a in args)
        if "-" in args:
            previous = previous_branch(repo)
            if previous:
                switched(repo, previous)
        elif "--" in args or not names:
            pass
        elif tracking and not creating and len(names) == 1:
            # --track names the branch after the remote one: origin/fix makes fix.
            switched(repo, tracked(repo, names[0]))
        elif creating or sub == "switch":
            # The first name is the branch, new or existing: `switch -c new`, `checkout -b new base`.
            switched(repo, names[0])
        elif len(names) == 1 and is_branch(repo, names[0]):
            switched(repo, names[0])
        # Anything else is a checkout of files, not a switch.

    if sub == "commit":
        message = []
        for n, arg in enumerate(args):
            # -m and -F may close a cluster of short flags, as in -am or -aF.
            cluster = re.match(r"^-[A-Za-z]*?([mF])(.*)$", arg) if not arg.startswith("--") else None
            name = value = None
            if arg in ("--message", "--trailer", "--file") and n + 1 < len(args):
                name, value = arg, args[n + 1]
            elif arg.startswith(("--message=", "--trailer=", "--file=")):
                name, value = arg.split("=", 1)
            elif cluster:
                name = "-" + cluster.group(1)
                value = cluster.group(2) or (args[n + 1] if n + 1 < len(args) else "")
            if name in ("-F", "--file"):
                try:
                    with open(resolve(directory, value), encoding="utf-8", errors="replace") as f:
                        message.append(f.read())
                except OSError:
                    pass
            elif name:
                message.append(value)
        if AI_CREDIT.search("\n".join(message)):
            block("this commit credits an AI. A commit here is never co-authored by an AI agent: "
                  "drop the Co-Authored-By or Generated-with line and commit again.")

    if sub in CHANGES_BRANCH:
        if sub in ("merge", "pull") and "--ff-only" in args and from_origin(sub, args, repo):
            return
        if any(a in ("--abort", "--quit") for a in args):
            return
        current = branch(repo)
        if current in protected(repo):
            block(f"`git {sub}` with {current}, the default branch, checked out. Work on your own "
                  "branch, in a worktree if this is the repo's main checkout; the default branch only "
                  "ever moves by a fast-forward from origin.")


def check_gh(words, cwd, blind=False):
    rest = [w for w in words[1:] if not w.startswith("-")]
    group = next((w for w in rest if w in ("pr", "issue", "api", "repo")), "")
    after = rest[rest.index(group) + 1:] if group else []
    action = after[0] if after else ""
    if blind and XARGS in ((rest or [XARGS])[0] + action):
        block("a gh command whose action xargs or find supplies when it runs. Name the action.")
    kind, name = owner_of(cwd)
    if kind in ("dropbox", "unknown") and (group, action) != ("repo", "clone"):
        # gh reads the repo it runs in, through git, to know which repo and
        # branch it works on. gh repo clone takes its repo as an argument.
        never_written(kind, name, f"`gh {group} {action}`" if group else "`gh`")
    if group in ("pr", "issue") and action not in GH_READS:
        never_written(kind, name, f"`gh {group} {action}`")
    if group == "repo" and action == "clone":
        tail = words[words.index("clone") + 1:]
        tail = tail[:tail.index("--")] if "--" in tail else tail
        names = [w for n, w in enumerate(tail) if not w.startswith("-")
                 and not (n and tail[n - 1] in ("-u", "--upstream-remote-name"))]
        if names:
            path = names[1] if len(names) > 1 else re.sub(r"\.git$", "", re.split(r"[/:]", names[0].rstrip("/"))[-1])
            never_written(*lands_in(resolve_dest(cwd, path)), "`gh repo clone`")
    if group == "pr":
        if action in ("merge", "ready"):
            block(f"`gh pr {action}`. PRs from here stay drafts; Carlos marks them "
                  "ready and merges them.")
        if action in ("create", "new") and not any(w == "-d" or w.startswith("--draft") for w in words):
            block(f"`gh pr {action}` without --draft. Open it again with --draft, even "
                  "where a playbook says to open it ready.")
        if action == "checkout":
            if kind == "agent" and in_main_checkout(cwd, name):
                in_place(name, "`gh pr checkout`")
            # It switches to the PR's branch: the one -b names, none with
            # --detach, or one named after the PR's head, never the default.
            chosen = next((w.split("=", 1)[1] if "=" in w else words[n + 1] for n, w in enumerate(words)
                           if (w in ("-b", "--branch") and n + 1 < len(words)) or w.startswith("--branch=")),
                          None)
            switched(cwd, chosen if chosen is not None else "" if "--detach" in words else "(the PR's branch)")
        if action in ("create", "new", "edit"):
            text = []
            for n, w in enumerate(words):
                if w in ("-t", "--title", "-b", "--body") and n + 1 < len(words):
                    text.append(words[n + 1])
                elif w.startswith(("--title=", "--body=")):
                    text.append(w.split("=", 1)[1])
                elif (w in ("-F", "--body-file") and n + 1 < len(words) and words[n + 1] != "-") or w.startswith("--body-file="):
                    path = w.split("=", 1)[1] if "=" in w else words[n + 1]
                    try:
                        with open(resolve(cwd, path), encoding="utf-8", errors="replace") as f:
                            text.append(f.read())
                    except OSError:
                        pass
            if AI_CREDIT.search("\n".join(text)):
                block("this PR credits an AI. Nothing here is credited to an AI agent: drop the line and try again.")
    if group == "api":
        joined = " ".join(words)
        if re.search(r"/pulls/\d+/merge|/merges\b", joined) or re.search(
                r"mergePullRequest|markPullRequestReadyForReview|enablePullRequestAutoMerge", joined):
            block("`gh api` call that merges or readies a PR. PRs from here stay drafts.")


def applies(words):
    """Whether chezmoi edit's flags also write the live files: -a or --apply,
    --watch, which applies on save, or --init, which rewrites chezmoi's config."""
    for word in words[1:]:
        if word == "--":
            break
        if word.startswith("--"):
            name, _, value = word.partition("=")
            if name in ("--apply", "--watch", "--init") and value.lower() not in ("false", "f", "0"):
                return True
        elif word.startswith("-"):
            for letter in word[1:]:
                if letter in "cDoSWxi":
                    # The rest of the word is that option's value.
                    break
                if letter == "a":
                    return True
    return False


def check_chezmoi(words, cwd, env=None, blind=False):
    """chezmoi git runs git in the source folder, checked as `git -C <source>`, and
    chezmoi add, re-add and the rest write that folder. The source is the
    dotfiles checkout unless --source or --working-tree names another."""
    options, rest, n = {}, [], 1
    while n < len(words):
        word = words[n]
        if word == "--":
            # The rest is chezmoi git's, for git.
            rest += words[n + 1:]
            break
        if word.startswith("-"):
            flag, eq, value = word.partition("=")
            if re.match(r"^-[SW].", flag):
                flag, value = flag[:2], flag[2:]
            elif not eq and flag in CHEZMOI_VALUES and n + 1 < len(words):
                value = words[n + 1]
                n += 1
            options[flag] = value
        else:
            rest.append(word)
        n += 1
    if not rest:
        # As for git, an option's value and the subcommand may both come from xargs or find.
        if blind and any(XARGS in w for w in words):
            block("a chezmoi command whose subcommand xargs or find supplies when it runs. Name the subcommand.")
        return
    if blind and XARGS in rest[0]:
        block("a chezmoi command whose subcommand xargs or find supplies when it runs. Name the subcommand.")
    if rest[0] == "destroy":
        block("`chezmoi destroy` deletes the live file as well as its source, whatever its --source, and only "
              "Carlos removes what this Mac runs. To stop managing a file, git rm its source file in "
              "~/worktrees/dotfiles/<branch>, or run chezmoi --source ~/worktrees/dotfiles/<branch> forget "
              "<file>, and leave removing the deployed file to Carlos.")
    if rest[0] == "purge":
        block("`chezmoi purge` deletes chezmoi's config and state on this Mac, and the source folder it is "
              "given, whatever its --source, and only Carlos runs it.")
    if rest[0] in CHEZMOI_LIVE:
        block(f"`chezmoi {rest[0]}` changes this Mac's live config, whatever its --source or --destination, "
              "and only Carlos runs it. To see what a change would do, run "
              "chezmoi --source ~/worktrees/dotfiles/<branch> diff, or bash tests/run.sh in that worktree.")
    if rest[0] == "state" and rest[1:2] and rest[1] in CHEZMOI_STATE_WRITES:
        block(f"`chezmoi state {rest[1]}` changes chezmoi's state on this Mac, whatever its --source, and "
              "only Carlos runs it.")
    if rest[0] == "edit" and applies(words):
        block("`chezmoi edit` with --apply, --watch or --init writes this Mac's live files or chezmoi's config "
              "too, whatever its --source, and only Carlos applies. Run chezmoi --source "
              "~/worktrees/dotfiles/<branch> edit without them, or edit the file in that worktree.")
    source = options.get("--source") or options.get("-S")
    source = resolve_dest(cwd, source, new=False) if source else DOTFILES
    if rest[0] == "git":
        tree = options.get("--working-tree") or options.get("-W")
        check_git(["git", "-C", resolve_dest(cwd, tree, new=False) if tree else source] + rest[1:], cwd, env, blind)
    elif rest[0] in CHEZMOI_WRITES:
        if is_unknown(source):
            unknown_place(f"`chezmoi {rest[0]}`")
        real = os.path.realpath(source)
        if real == DOTFILES or real.startswith(DOTFILES + os.sep):
            block(f"`chezmoi {rest[0]}` would write the dotfiles checkout, this Mac's live config, which is "
                  "never changed in place, attended or not. Make a worktree in ~/worktrees/dotfiles/<branch> "
                  f"and run chezmoi --source ~/worktrees/dotfiles/<branch> {rest[0]} there.")


def check_unparsed(command, cwd):
    """Plain pattern checks for a command shlex can't split, one piece at a time. Any match blocks.

    The pieces are judged from the folder a literal cd at the start of the
    command moves to, before any quote opens, and by every folder a cd, pushd
    or git -C anywhere in it names. A git or gh command in it may not name a
    repo in Dropbox anywhere at all."""
    why = "couldn't parse this command, and it"
    where, masked = cwd, mask_quotes(command)
    for piece in re.finditer(r"[^;&|\n]+", masked):
        if re.search(r"['\"`$()]", masked[:piece.end()]):
            break
        words = command[piece.start():piece.end()].split()
        if len(words) == 2 and words[0] in ("cd", "pushd"):
            where = resolve(where, words[1])
    named = re.findall(r"(?:\b(?:cd|pushd)|\s-C)\s+([^\s;&|()'\"`$]+)", command)
    places = [where] + [resolve(where, path) for path in named]
    names = "|".join(sorted(protected(where)))
    current = branch(where)
    if (re.search(r"\bgit\b[\s\S]*\bcommit\b|\bgh\b[\s\S]*\bpr\s+(create|new|edit)\b", command)
            and BUILT_CREDIT.search(re.sub(r"\\+n", "\n", command))):
        block(f"{why} credits an AI. Nothing here is credited to an AI agent: drop the line and try again.")
    subs = re.findall(r"\bgit\s+(?:(?:-C|-c|--git-dir|--work-tree)\s+\S+\s+|-\S+\s+)*([A-Za-z][\w-]*)", command)
    uses_repo = subs or re.search(r"\bgh\b", command)
    if uses_repo:
        # A repo in Dropbox named anywhere in it, as --git-dir, GIT_DIR or a
        # clone's source would name it, is never used.
        for path in re.findall(r"(?<![^\s=:'\"])(?:~|\$HOME|\$\{HOME\}|/)[^\s;&|()'\"`<>]*", command):
            kind, name = lands_in(resolve(where, path))
            if kind == "dropbox":
                never_written(kind, name, "This command, which couldn't be parsed,")
    for directory in places:
        kind, name = owner_of(directory)
        if kind in ("dropbox", "unknown") and uses_repo:
            never_written(kind, name, "This command, which couldn't be parsed,")
        if kind == "dotfiles":
            actions = re.findall(r"\bgh\b.*?\b(?:pr|issue)\s+([a-z-]+)", command)
            if any(s not in READS for s in subs) or any(a not in GH_READS for a in actions):
                never_written(kind, name, "This command, which couldn't be parsed,")
        if (kind == "agent" and any(s in MOVES or s in ("switch", "checkout") for s in subs)
                and in_main_checkout(directory, name)):
            in_place(name, "This command, which couldn't be parsed,")
        if (any(s in ("gc", "repack", "prune", "maintenance") for s in subs)
                or re.search(r"\bgit\b.*\bworktree\s+prune\b", command)) and under_dropbox(directory):
            block(f"{why} looks like a git gc, repack, prune or maintenance in a repo under Dropbox.")
    for piece in re.split(r"&&|\|\||[;&|\n]", command):
        if re.search(r"\bpush\b.*(--force|--mirror|--all|\s-[A-Za-z]*f[A-Za-z]*\b|\s\+)", piece):
            block(f"{why} looks like a force-push.")
        if re.search(r"\bpush\b.*[\s:](" + names + r")\b", piece):
            block(f"{why} looks like a push to the default branch.")
        if re.search(r"\bgh\b.*\bpr\s+(merge|ready)\b", piece) or re.search(
                r"/pulls/\d+/merge|mergePullRequest|markPullRequestReadyForReview|enablePullRequestAutoMerge", piece):
            block(f"{why} looks like a PR merge.")
        if re.search(r"\bgh\b.*\bpr\s+(create|new)\b", piece) and not re.search(r"(^|\s)(-d|--draft)(\s|=|$)", piece):
            block(f"{why} opens a PR without --draft.")
        if (current in protected(where) and "--ff-only" not in piece
                and re.search(r"\bgit\b.*\b(" + "|".join(CHANGES_BRANCH) + r"|push)\b", piece)):
            block(f"{why} would change {current}, the default branch.")


class Shell:
    """What a command has changed so far in the shell it runs in: the folder,
    the one before it for cd -, pushd's stack, and the GIT_ variables set.
    zsh says whether that shell is zsh, which runs agents' commands here, or
    bash or sh, which bash -c and the like start."""

    def __init__(self, cwd, env=None, zsh=True):
        self.cwd, self.oldpwd, self.dirs, self.env, self.zsh = cwd, None, [], dict(env or {}), zsh

    def copy(self):
        other = Shell(self.cwd, self.env, self.zsh)
        other.oldpwd, other.dirs = self.oldpwd, list(self.dirs)
        return other


def change_dir(shell, name, args):
    """Follow a cd, pushd or popd in shell."""
    targets = [w for w in args if not w.startswith("-") or w == "-"]
    if name == "popd" or (name == "pushd" and targets and re.match(r"^[+-]\d+$", targets[0])):
        # popd goes back to the folder the last pushd left; one that rotates
        # the stack is left alone.
        if name == "popd" and not targets and shell.dirs:
            shell.oldpwd, shell.cwd = shell.cwd, shell.dirs.pop()
        return
    if not targets:
        if name == "cd":
            shell.oldpwd, shell.cwd = shell.cwd, HOME
        elif shell.dirs:
            shell.cwd, shell.dirs[-1] = shell.dirs[-1], shell.cwd
        return
    if name == "cd" and targets[0] == "-":
        if shell.oldpwd:
            shell.oldpwd, shell.cwd = shell.cwd, shell.oldpwd
        return
    if name == "pushd":
        shell.dirs.append(shell.cwd)
    shell.oldpwd, shell.cwd = shell.cwd, resolve(shell.cwd, targets[0])


def run_xargs(words, shell, known, depth):
    """Check the command xargs runs, with what it reads from its input standing
    in as XARGS: in place of the -I or -J string, or added at the end."""
    n, replace = 1, None
    while n < len(words) and words[n].startswith("-"):
        word = words[n]
        n += 1
        if word == "--":
            break
        if word.startswith("--"):
            name, eq, value = word.partition("=")
            if name == "--replace":
                replace = value if eq else "{}"
            elif name in XARGS_LONG_VALUES and not eq:
                n += 1
            continue
        for k, letter in enumerate(word[1:], 2):
            if letter in XARGS_VALUES:
                value = word[k:]
                if not value and n < len(words):
                    value, n = words[n], n + 1
                if letter in "IJ":
                    replace = value
                break
            if letter == "i":
                replace = word[k:] or "{}"
                break
            if letter in "el":
                # GNU's -e and -l take a value only when it is attached.
                break
    command = words[n:]
    if not command:
        return
    if replace:
        # BSD xargs, the mini's, replaces only in the arguments, never in the
        # command's name.
        command = command[:1] + [w.replace(replace, XARGS) for w in command[1:]]
    else:
        command = command + [XARGS]
    run(command, shell.copy(), known, depth, True)


def run_find(words, shell, known, depth):
    """Check each command find runs with -exec, -execdir, -ok or -okdir, with
    XARGS for the {} it hands over. -execdir runs in the folder of each file
    found, which is the start folder's checkout when that is in a repo, and
    could be any checkout when it isn't."""
    starts = []
    for word in words[1:]:
        if word.startswith(("-", "!", "(")):
            if starts or word not in ("-H", "-L", "-P", "-E", "-X", "-s", "-x"):
                break
            continue
        starts.append(word)
    starts = starts or ["."]
    n = 1
    while n < len(words):
        if words[n] not in ("-exec", "-execdir", "-ok", "-okdir"):
            n += 1
            continue
        action, n = words[n], n + 1
        end = n
        while end < len(words) and words[end] not in (";", "+"):
            end += 1
        command = [w.replace("{}", XARGS) for w in words[n:end]]
        n = end + 1
        if not command:
            continue
        folders = [shell.cwd]
        if action in ("-execdir", "-okdir"):
            folders = []
            for start in starts:
                folder = resolve(shell.cwd, start)
                inside = not is_unknown(folder) and git_out(folder, "rev-parse", "--show-toplevel")
                folders.append(folder if inside else UNKNOWN)
        for folder in folders:
            here = shell.copy()
            here.cwd = folder
            run(command, here, known, depth, True)


def run(words, shell, known, depth, blind=False):
    """Check one simple command, and carry what its cd, pushd, popd, export,
    unset, read, for and the like change into shell."""
    if words and all(ASSIGNMENT.match(w) or w in KEYWORDS for w in words):
        # Assignments alone set the shell's own variables, for the commands after.
        for word in words:
            if ASSIGNMENT.match(word) and ASSIGNMENT.match(word).group(1) in GIT_VARS:
                name, value = ASSIGNMENT.match(word).groups()
                shell.env[name] = env_value(value, known)
        return
    command, assigned, cleared, chdir = split_prefix(words)
    command = [substitute(w, known) for w in command]
    if not command:
        return
    if blind and XARGS in command[0]:
        block("a command that xargs or find supplies when it runs, as in `xargs env` or `xargs -I{} sh -c {}`. "
              "Name the command, such as git, in the command line, or run a found script as bash {}.")
    env = {} if cleared else dict(shell.env)
    for name, value in assigned:
        if name in GIT_VARS:
            if value is None:
                env.pop(name, None)
            else:
                env[name] = env_value(value, known)
    cwd = resolve(shell.cwd, substitute(chdir, known)) if chdir else shell.cwd
    name = os.path.basename(command[0])
    if name in ("cd", "pushd", "popd"):
        change_dir(shell, name, command[1:])
    elif name in DECLARERS or name == "unset":
        # unset -f removes functions and leaves variables alone.
        drop = (name == "unset" and "-f" not in command[1:]) or "-n" in command[1:]
        for word in command[1:]:
            target, eq, value = word.partition("=")
            if target in GIT_VARS:
                if drop:
                    shell.env.pop(target, None)
                elif eq:
                    shell.env[target] = env_value(value, known)
    elif name in ("read", "mapfile", "readarray", "getopts", "for", "select", "printf", "print"):
        # A GIT_ variable these set holds a value worked out when the command
        # runs: the line read, what printf -v prints, or each word a loop
        # takes. zsh's read takes NAME?prompt.
        if name in ("for", "select"):
            targets = command[1:2]
        elif name in ("printf", "print"):
            targets = [w[2:] or (command[n + 1] if n + 1 < len(command) else "")
                       for n, w in enumerate(command[1:], 1) if w.startswith("-v")]
        else:
            targets = [w.split("?", 1)[0] for w in command[1:]]
        for target in targets:
            if target in GIT_VARS:
                shell.env[target] = UNKNOWN
    elif name in SHELLS:
        # -c, alone or in a cluster such as -lc, takes the script as its next word.
        index = next((n for n, w in enumerate(command[1:], 1) if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", w)), 0)
        if index and index + 1 < len(command):
            check(command[index + 1], cwd, depth + 1, env, blind, known, name == "zsh")
    elif name == "eval":
        check(" ".join(command[1:]), cwd, depth + 1, env, blind, known, shell.zsh)
    elif name == "xargs":
        run_xargs(command, Shell(cwd, env), known, depth)
    elif name == "find":
        run_find(command, Shell(cwd, env), known, depth)
    elif name == "git":
        check_git(command, cwd, env, blind)
    elif name == "gh":
        check_gh(command, cwd, blind)
    elif name == "chezmoi":
        check_chezmoi(command, cwd, env, blind)


def check(command, cwd, depth=0, env=None, blind=False, outer=None, zsh=True):
    """Check a command line from cwd. env holds the GIT_ variables already set,
    blind says xargs or find runs it, outer holds the plain values of the
    command it is part of, and zsh says zsh runs it rather than bash or sh."""
    if depth > 3:
        # No ordinary command nests this deeply, and past here nothing is checked.
        block("this command nests shells, substitutions or eval more than three deep, which is too deep to "
              "check. Split it into separate commands, keeping what an inner one prints in a variable.")
    # Here-document bodies come out first, so their text never counts as
    # comments, quotes or continued lines.
    command, scripts, texts = heredocs(command)
    command = MKTEMP.sub(MKTEMP_PATH, unfold(command))
    if blind:
        # A script xargs or find runs gets what they hand over as its arguments.
        command = POSITIONAL.sub(XARGS, command)
    no_credit(command, texts)
    lifted, numbers = lift(command)
    try:
        items = tokens(lifted)
    except ValueError:
        for name, script in scripts:
            check(script, cwd, depth + 1, env, blind, outer, name == "zsh")
        check_unparsed(command, cwd)
        return
    parts = [item for item in items if isinstance(item, list)]
    no_credit(command, [ASSIGNMENT.match(w).group(2) for words in parts for w in words if ASSIGNMENT.match(w)])
    names = assigned_names(parts)
    known = {name: value for name, value in (outer or {}).items() if name not in names}
    known.update(plain_values(parts))
    for name, script in scripts:
        check(script, cwd, depth + 1, env, blind, known, name == "zsh")
    # The shell as each list of commands starts, since a & at its end runs the
    # whole list in a subshell, and the shells a ( saved.
    shell, pending = Shell(cwd, env, zsh), set(numbers)
    start, saved = shell.copy(), []
    for n, item in enumerate(items):
        if isinstance(item, str):
            # A ( starts a subshell, whose cd and exports end at its ).
            for op in separators(item):
                if op == "(":
                    saved.append((shell.copy(), start))
                    start = shell.copy()
                elif op == ")" and saved:
                    shell, start = saved.pop()
                elif op == "&":
                    shell = start.copy()
                if op in ("(", ")", "&", ";", ";;"):
                    start = shell.copy()
            continue
        # Each substitution runs from where the command it is part of runs.
        for number in SUBSTITUTION.findall(" ".join(item)):
            if int(number) in pending:
                pending.discard(int(number))
                check(SUBS[int(number)], shell.cwd, depth + 1, shell.env, blind, known, zsh)
        # Each command in a pipeline runs in a subshell too, but for the last
        # one in zsh, which runs that in the current shell, so its cd lasts.
        before = [op for op in separators(items[n - 1]) if op not in "()"] if n else []
        after = [op for op in separators(items[n + 1]) if op not in "()"] if n + 1 < len(items) else []
        piped = (["|"], ["|&"])
        apart = after[:1] in piped or (not zsh and before[-1:] in piped)
        run(item, shell.copy() if apart else shell, known, depth, blind)
    for number in sorted(pending):
        check(SUBS[number], cwd, depth + 1, env, blind, known, zsh)


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    try:
        command = (payload.get("tool_input") or {}).get("command") or ""
        cwd = payload.get("cwd") or os.getcwd()
        if command:
            check(command, cwd)
    except RecursionError:
        block("this command nests too deeply to check. Split it into separate commands.")
    except Exception as error:
        # A crash would let the command through, so it blocks instead.
        block(f"couldn't check this command ({type(error).__name__}: {error}). Split it into simpler "
              "commands.")


if __name__ == "__main__":
    main()
