#!/usr/bin/python3
"""PreToolUse guard for Bash, on the laptop only.

The deny rules keep Read off the vault's .obsidian folder, which holds plugin
settings with tokens in them, but a deny rule never covers a shell command.
This blocks (exit 2) the ordinary ways a command reads into it: naming a path
inside it, a recursive grep or an rg that includes hidden folders over the
vault or any folder above it, and a find there that runs a command on what it
finds. A search below the vault's top folder, or one that leaves .obsidian
out, goes through. Paths are read as the shell would hand them over: from the
folder an earlier cd moved to, with $HOME, ~, brace lists, globs and plain
NAME=value variables set earlier in the command expanded. A command is cut
into pieces only at separators outside quotes, so a pattern such as "foo|bar"
stays whole, and a $(...) inside double quotes has quotes of its own.
Comments are dropped and here-document bodies taken out first, as guard-git.py
does, so an apostrophe in either never pairs with one on another line and
hides the commands between them. Each body is checked on its own, from the
folder its command runs in. A script a shell runs is checked as well: one
given with -c or to eval, and one it reads from a here-document, a
here-string, or an echo or printf piped to it. One nested too deep to check
is blocked.
"""

import fnmatch
import glob
import json
import os
import re
import shlex
import sys
import tempfile

VAULT = os.path.realpath(os.path.expanduser("~/Documents/armenelos")).lower()
OBSIDIAN = VAULT + "/.obsidian"
# What .obsidian holds, to test a find's -name filters against.
SAMPLES = ("data.json", "workspace.json", "app.json", "manifest.json", "main.js", "styles.css")
# Ways to leave .obsidian out, wherever the search starts. A brace list counts
# only unquoted, when the shell turns it into one --exclude-dir per name.
EXCLUDED = re.compile(
    r"--exclude-dir[= ]['\"]?\.obsidian|-g ['\"]?!\.obsidian|--glob[= ]['\"]?!\.obsidian"
    r"|-not -path ['\"]?\*/?\.obsidian(/\*|\*)['\"]?|! -path ['\"]?\*/?\.obsidian(/\*|\*)['\"]?"
    r"|-path ['\"]?\*/?\.obsidian['\"]? -prune"
    r"|(^|\s)--exclude-dir=\{[^}'\"\s]*\.obsidian[^}'\"\s]*\}(\s|$)"
)
# The same with ./, which leaves it out only for a find that starts at the vault.
EXCLUDED_AT_VAULT = re.compile(
    r"(-not|!) -path ['\"]?\./\.obsidian(/\*|\*)['\"]?|-path ['\"]?\./\.obsidian['\"]? -prune"
)
# Words in front of a command that aren't the command.
KEYWORDS = ("{", "!", "if", "elif", "then", "else", "do", "while", "until")
PREFIXES = ("command", "env", "sudo", "time", "nice", "nohup", "exec") + KEYWORDS
ASSIGNMENT = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
# Commands that set a variable some other way than NAME=value, and the ones of
# them that also take plain NAME=value words.
SETTERS = ("read", "unset", "mapfile", "readarray", "getopts", "let", "printf", "for", "select")
DECLARERS = ("export", "local", "declare", "typeset", "readonly")
SEPARATOR = re.compile(r"&&|\|\||[;|\n]")
SHELLS = ("bash", "sh", "zsh")
# A here-document operator, with the name of the line that ends its body, as
# guard-git.py matches it, and also <<\EOF. <<< is a here-string, not one.
HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*(['\"]?)\\?([A-Za-z_][A-Za-z0-9_]*)\1")
# What the operator becomes once its body is out: a word naming the body.
BODY = re.compile(r"<<heredoc:(\d+)")
# Options of grep and rg that take the next word as their value.
VALUED = ("-e", "-f", "--regexp", "--file", "-g", "--glob", "--iglob", "-t", "--type", "-T", "--type-not",
          "-m", "--max-count", "-A", "-B", "-C", "--context", "--after-context", "--before-context",
          "-d", "--max-depth", "-j", "--threads", "-M", "--max-columns", "--include", "--exclude",
          "--exclude-dir", "--ignore-file", "--pre", "--sort", "--sortr")


def block(reason, instead="Leave .obsidian out, for example grep -r --exclude-dir=.obsidian, "
                          "or rg without --hidden."):
    print(f"BLOCKED by guard-vault.py: {reason} {instead}", file=sys.stderr)
    sys.exit(2)


def real(word, cwd):
    return os.path.realpath(os.path.join(cwd, os.path.expanduser(os.path.expandvars(word))))


def resolve(word, cwd):
    return real(word, cwd).lower()


def braces(word, limit=64):
    """The words the shell makes of the brace lists in this one, such as
    {a,b} or {a,{b,c}}, up to limit of them. One list is opened at a time,
    depth first, so a word with many lists stops early instead of growing."""
    if len(word) > 4096:
        # No path is that long, and a long JSON payload would cost a copy
        # of itself for every part of every list.
        return [word]
    out, todo = [], [word]
    while todo and len(out) < limit:
        word = todo.pop()
        match = re.search(r"\{([^{}]*,[^{}]*)\}", word)
        if not match:
            out.append(word)
            continue
        parts = match.group(1).split(",")
        todo += [word[:match.start()] + part + word[match.end():] for part in reversed(parts)]
    return out


def expand(word, cwd):
    """The paths the shell would hand over for this word, its brace lists first."""
    out = []
    for word in braces(word):
        if not any(c in word for c in "*?["):
            out.append(resolve(word, cwd))
            continue
        pattern = os.path.join(cwd, os.path.expanduser(os.path.expandvars(word)))
        try:
            matches = glob.glob(pattern)
        except re.error:
            # Python 3.9's fnmatch fails on a range such as [:-1]; the shell
            # matches nothing there and hands the word over as it is.
            matches = []
        out += [os.path.realpath(m).lower() for m in matches] or [resolve(word, cwd)]
    return out


def above_or_at_vault(path):
    return path == VAULT or VAULT.startswith(path.rstrip("/") + "/")


def words_of(piece):
    try:
        return shlex.split(piece)
    except ValueError:
        return piece.split()


def ansi_end(command, i):
    """Where the $'...' whose text starts at i closes, or None, as guard-git.py finds it."""
    while i < len(command):
        if command[i] == "\\":
            i += 2
            continue
        if command[i] == "'":
            return i
        i += 1
    return None


def closing(command, i, close=")"):
    """Where the substitution whose text starts at i ends: the index of its ) or
    closing backquote, or None, as guard-git.py finds it. A here-document
    inside it is skipped whole."""
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


def substitution_end(command, i):
    """Where a $(...) or backquote starting at i ends, or None when none starts
    there. Inside double quotes it opens quoting of its own, so a quote in it
    pairs only there. One left open, or nested too deep to follow, runs to the
    end of the command, so the quote around it is left open too."""
    if command.startswith("$(", i) and not command.startswith("$((", i):
        start, close = i + 2, ")"
    elif command[i] == "`":
        start, close = i + 1, "`"
    else:
        return None
    try:
        end = closing(command, start, close)
    except RecursionError:
        end = None
    return len(command) - 1 if end is None else end


def mask_quotes(command):
    """The command with every quoted or escaped character replaced, much as
    guard-git.py masks it, so patterns only see shell syntax, and whether a
    quote is left open. $'...' quoting counts, with its backslash escapes, and
    a $(...) or backquote inside double quotes is masked whole."""
    out, quote, escaped, i = [], None, False, 0
    while i < len(command):
        ch = command[i]
        end = substitution_end(command, i) if quote == '"' and ch in "$`" and not escaped else None
        if escaped:
            out.append("x")
            escaped = False
        elif ch == "\\" and quote != "'":
            out.append("x")
            escaped = True
        elif end is not None:
            out.append("x" * (end + 1 - i))
            i = end
        elif quote:
            out.append(ch if ch == quote[-1] else "x")
            if ch == quote[-1]:
                quote = None
        elif ch == "$" and command[i + 1:i + 2] == "'":
            out.append("$'")
            quote = "$'"
            i += 1
        elif ch in "'\"":
            out.append(ch)
            quote = ch
        else:
            out.append(ch)
        i += 1
    return "".join(out), quote is not None


def unfold(command):
    """The command as the shell reads it: comments dropped and continued lines
    joined, as guard-git.py unfolds it.

    One pass over the whole text, so a quote opened on one line is still open
    on the next. A comment is an unquoted # that starts a word. A backslash
    and newline outside single quotes join two lines into one, unless the
    backslash is itself escaped. In $'...' a backslash escapes the quote. A
    $(...) or backquote inside double quotes is kept whole, since a quote in
    it pairs only there."""
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
        end = substitution_end(command, i) if quote == '"' and ch in "$`" else None
        if end is not None:
            out.append(command[i:end + 1])
            i = end + 1
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


def heredocs(command):
    """The command with each here-document body taken out, as guard-git.py takes
    them out, and the bodies. Each operator becomes <<heredoc:N, which names
    its body, so the body is checked from the folder its command runs in."""
    lines, out, bodies, i = command.split("\n"), [], [], 0
    while i < len(lines):
        line, masked = lines[i], mask_quotes(lines[i])[0]
        # Matched on the line itself, so a quoted terminator keeps its name,
        # but only where the << is outside quotes and before any comment.
        comment = re.search(r"(^|[\s;&|()])#", masked)
        cut = comment.end() - 1 if comment else len(line)
        operators = [m for m in HEREDOC.finditer(line)
                     if m.start() < cut and masked[m.start():m.start() + 2] == "<<"]
        j, found = i + 1, []
        for match in operators:
            body = []
            while j < len(lines) and lines[j].strip() != match.group(2):
                body.append(lines[j])
                j += 1
            if j >= len(lines):
                # No terminator: not a here-document after all, so take nothing out.
                found = None
                break
            j += 1
            found.append((match, "\n".join(body)))
        if not operators or found is None:
            out.append(line)
            i += 1
            continue
        kept, last = [], 0
        for match, body in found:
            kept.append(f"{line[last:match.start()]} <<heredoc:{len(bodies)} ")
            bodies.append(body)
            last = match.end()
        out.append("".join(kept) + line[last:])
        i = j
    return "\n".join(out), bodies


def split(command):
    """The command cut at &&, ||, ;, | and newlines outside quotes, with each
    separator kept between the pieces it separates. With a quote left open, so
    that it doesn't parse, it is cut at every separator."""
    masked, left_open = mask_quotes(command)
    if left_open:
        return re.split(f"({SEPARATOR.pattern})", command)
    out, last = [], 0
    for match in SEPARATOR.finditer(masked):
        out += [command[last:match.start()], match.group()]
        last = match.end()
    return out + [command[last:]]


def plain_values(pieces, inherited=None):
    """The variables a command sets only as plain NAME=value pieces, all to the same
    value, with ~ and the environment's variables expanded, as guard-git.py works
    them out. export, local, declare, typeset or readonly in front counts as
    plain. A name set from a substitution or any other way is left out. A
    here-document body starts from the ones its command knows."""
    values, spoiled = {}, set()
    for piece in pieces:
        words = words_of(piece.strip().lstrip("(").rstrip(")"))
        while words and words[0] in KEYWORDS:
            words = words[1:]
        if words and words[0] in DECLARERS:
            words = [w for w in words[1:] if not re.match(r"^-[xrg]+$", w)]
        if words and all(ASSIGNMENT.match(w) for w in words):
            for word in words:
                name, value = ASSIGNMENT.match(word).groups()
                value = os.path.expanduser(os.path.expandvars(value))
                if "$" in value or "`" in value or values.get(name, value) != value:
                    spoiled.add(name)
                values.setdefault(name, value)
            continue
        spoiled.update(ASSIGNMENT.match(w).group(1) for w in words if ASSIGNMENT.match(w))
        if words and words[0] in SETTERS:
            spoiled.update(w.split("=", 1)[0] for w in words[1:])
    values = dict(inherited or {}, **values)
    return {name: value for name, value in values.items() if name not in spoiled}


def substitute(word, known):
    return re.sub(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))",
                  lambda m: known.get(m.group(1) or m.group(2), m.group(0)), word)


def command_words(piece, known):
    """The piece's words, from the command's name on, with known variables filled
    in. A here-document's <<heredoc:N is its input, not a path to search: grep -r
    with only that searches the folder it runs in."""
    words = [w for w in words_of(piece) if not BODY.fullmatch(w)]
    while words and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]) or words[0] in PREFIXES):
        words = words[1:]
    return [substitute(word, known) for word in words]


def operands(words, name):
    """The words that aren't options, after the command name. For grep and rg
    the first of them is the pattern, unless -e or -f gave it."""
    valued = VALUED + (("-r", "--replace") if name == "rg" else ())
    out, skip = [], False
    for word in words[1:]:
        if skip:
            skip = False
        elif word in valued:
            skip = True
        elif not word.startswith("-"):
            out.append(word)
    if name in ("grep", "egrep", "fgrep", "rg") and "--files" not in words and not any(
            re.match(r"-[A-Za-z]*[ef]|--(regexp|file)(=|$)", w) for w in words[1:]):
        out = out[1:]
    return out


def find_roots(words):
    """Where a find starts: the words before its first test or action."""
    roots = []
    for word in words[1:]:
        if word in ("-H", "-L", "-P") and not roots:
            continue
        if word.startswith(("-", "!", "(")):
            break
        roots.append(word)
    return roots or ["."]


def check_piece(piece, rest, cwd, known):
    if EXCLUDED.search(piece):
        return
    words = command_words(piece, known)
    if not words:
        return
    name = os.path.basename(words[0])
    if name == "find" and EXCLUDED_AT_VAULT.search(piece) \
            and all(resolve(root, cwd) == VAULT for root in find_roots(words)):
        return
    for word in words:
        if any(path.startswith(OBSIDIAN) for path in expand(word, cwd)):
            block("this reads the vault's .obsidian folder.")
    paths = [path for word in operands(words, name) for path in expand(word, cwd)] or [resolve(".", cwd)]
    reaches = any(above_or_at_vault(p) for p in paths)
    if not reaches:
        return
    flags = " ".join(w for w in words[1:] if w.startswith("-"))
    if name in ("grep", "egrep", "fgrep") and re.search(
            r"(^|\s)-[A-Za-z]*[rR]|--recursive|--dereference-recursive|-d\s*recurse|--directories=recurse", flags + " " + piece):
        block("a recursive grep over the vault, or a folder above it, reads its .obsidian folder too.")
    # rg skips hidden folders unless told otherwise: --hidden, -., or -u twice.
    # One -u, or --no-ignore, still skips them.
    unrestricted = sum(w.count("u") for w in words[1:] if re.match(r"^-[A-Za-z]+$", w)) \
        + words[1:].count("--unrestricted")
    if name == "rg" and (unrestricted >= 2 or re.search(r"--hidden|(^|\s)-[A-Za-z]*\.", flags)):
        block("rg with hidden files over the vault, or a folder above it, reads its .obsidian folder too.")
    if name == "find" and (re.search(r"\s-(exec|execdir|ok|okdir)\b", piece) or re.match(r"\s*xargs\b", rest)):
        # A -name filter keeps .obsidian's files out only when every file has
        # to pass it: !, -not, -o or a comma lets the others through.
        filters = [words[n + 1] for n, w in enumerate(words[:-1]) if w in ("-name", "-iname")]
        if any(w in ("!", "-not", "-o", "-or", ",") for w in words):
            filters = []
        if filters and not any(fnmatch.fnmatch(s, f.lower()) for f in filters for s in SAMPLES):
            return
        block("a find that runs a command on the vault's files reaches its .obsidian folder too.")


def git_top(cwd):
    """The top of the Git work tree cwd is in, the folder holding its .git, or cwd outside one."""
    folder = cwd
    while not os.path.exists(os.path.join(folder, ".git")):
        if folder == os.path.dirname(folder):
            return cwd
        folder = os.path.dirname(folder)
    return folder


def moved(words, cwd, pushed):
    """Where the next piece runs, after a cd, pushd or popd in this one.

    A place worked out only when the command runs is the Git top for
    $(git rev-parse --show-toplevel), a new folder in the temp folder for
    $(mktemp -d), and otherwise the folder the cd ran in, which is as close to
    the vault as it can be told to be."""
    if not words or words[0] not in ("cd", "pushd", "popd"):
        return cwd
    if words[0] == "popd":
        return pushed.pop() if pushed else cwd
    if words[0] == "pushd":
        pushed.append(cwd)
    places = [w for w in words[1:] if not w.startswith("-")]
    place = (places or ["~"])[0]
    if place.startswith(("$(", "`")):
        # Unquoted, the substitution is split into several words.
        place = " ".join(words[words.index(place):])
    if re.match(r"^(\$\(|`)\s*git\b[^)`]*\brev-parse\b[^)`]*--show-toplevel\b", place):
        return git_top(cwd)
    if re.match(r"^(\$\(|`)\s*mktemp\b", place):
        return os.path.join(os.path.realpath(tempfile.gettempdir()), "mktemp.XXXXXX")
    if "$(" in place or "`" in place:
        return cwd
    return real(place, cwd)


def script_of(words):
    """The script a shell's -c or an eval runs, or None."""
    if words and os.path.basename(words[0]) in SHELLS:
        index = next((n for n, w in enumerate(words[1:], 1) if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", w)), 0)
        return words[index + 1] if index and index + 1 < len(words) else None
    if words and words[0] == "eval":
        return " ".join(words[1:])
    return None


def reads_script(words):
    """Whether these words run a shell that reads its script from its input: one with no -c."""
    return bool(words) and os.path.basename(words[0]) in SHELLS and not any(
        re.match(r"^-[A-Za-z]*c[A-Za-z]*$", w) for w in words[1:])


def feeds_shell(pieces, n, known):
    """Whether what piece n prints goes down its pipeline to a shell that reads
    its script from its input, as in echo ... | bash or ... | tee x | sh."""
    while n + 2 < len(pieces) and pieces[n + 1] == "|":
        n += 2
        if reads_script(command_words(pieces[n], known)):
            return True
    return False


def here_strings(words):
    """The text of each here-string in these words, as in <<< 'text'."""
    out = []
    for n, word in enumerate(words):
        if word == "<<<" and n + 1 < len(words):
            out.append(words[n + 1])
        elif word.startswith("<<<") and len(word) > 3:
            out.append(word[3:])
    return out


def printed(words):
    """What an echo or printf prints, as the scripts a shell reading it may see:
    its words joined by spaces or by newlines, each also with \\n read as a
    newline, as zsh's echo and printf read it."""
    words = words[1:]
    while words and (re.match(r"^-[neE]+$", words[0]) or words[0] == "--"):
        words = words[1:]
    texts = (" ".join(words), "\n".join(words))
    return set(texts) | {text.replace("\\n", "\n") for text in texts}


def check_body(body, words, rest, cwd, depth, known):
    """Check a here-document body from the folder its command runs in.

    It is checked first as a shell reads it, quotes and all, since a shell
    may run it: the command's own, one it pipes on to, or one that runs a
    script it writes. When the command is a shell reading it, or pipes it
    straight to one, that is all. Any other body is also checked twice more,
    since its quotes may mean nothing there: the shell still runs its $(...)
    and backticks unless the delimiter is quoted, and a program such as
    python3 may open a path the body names. With the quotes blanked, a path a
    program quotes stays a word of its own. With them removed, a word the
    shell builds from quoted parts, as "$HOME"/Documents is, stays whole. In
    those two each # becomes a letter, so a comment line is no command while a
    path or $(...) after it still counts."""
    check(body, cwd, depth + 1, known)
    if reads_script(words) or reads_script(command_words(rest, known)):
        return
    for text in (re.sub(r"['\"]", " ", body), re.sub(r"['\"]", "", body)):
        check(text.replace("#", "x"), cwd, depth + 1, known)


def check(command, cwd, depth=0, known=None):
    """Check each piece of the command in turn, from the folder it runs in."""
    if depth > 3:
        block("this runs a shell inside a shell, or an eval inside an eval, too many levels deep to check.",
              "Run the innermost command on its own.")
    # Here-document bodies come out first, so their text never counts as
    # comments, quotes or continued lines.
    command, bodies = heredocs(command)
    pieces = split(unfold(command))
    known = plain_values(pieces[0::2], known)
    subshells, pushed = [], []
    for n in range(0, len(pieces), 2):
        rest = pieces[n + 2] if n + 1 < len(pieces) and pieces[n + 1] == "|" and n + 2 < len(pieces) else ""
        # A cd inside ( ) lasts until the ) that closes it.
        piece = pieces[n].strip()
        while piece.startswith("("):
            subshells.append(cwd)
            piece = piece[1:].lstrip()
        trailing = re.search(r"(?<!\\)\)+$", piece)
        closes = len(trailing.group()) if trailing else 0
        piece = piece[:len(piece) - closes]
        check_piece(piece, rest, cwd, known)
        words = command_words(piece, known)
        # A quoted script is one word here, so it gets a check of its own.
        script = script_of(words)
        if script is not None:
            check(script, cwd, depth + 1)
        # A shell that reads its script from its input runs a here-string given
        # to it or to a command that pipes on to it, and what an echo or
        # printf pipes on to it.
        to_shell = feeds_shell(pieces, n, known)
        if reads_script(words) or to_shell:
            for text in here_strings(words):
                check(text, cwd, depth + 1, known)
        if to_shell and words and words[0] in ("echo", "printf"):
            for text in printed(words):
                check(text, cwd, depth + 1, known)
        for index in BODY.findall(piece):
            if int(index) < len(bodies):
                check_body(bodies[int(index)], words, rest, cwd, depth, known)
        cwd = moved(words, cwd, pushed)
        for _ in range(closes):
            if subshells:
                cwd = subshells.pop()


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    try:
        command = (payload.get("tool_input") or {}).get("command") or ""
        check(command, os.path.realpath(payload.get("cwd") or os.getcwd()))
    except RecursionError:
        block("this command nests too deeply to check.", "Split it into separate commands.")
    except Exception as error:
        # A crash would let the command through, so it blocks instead.
        block(f"couldn't check this command ({type(error).__name__}: {error}).",
              "Split it into simpler commands.")


if __name__ == "__main__":
    main()
