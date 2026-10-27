#!/bin/sh
# Fails if the index holds private key material, a licensed font, or a template
# that reads 1Password. Runs from the pre-commit hook and in CI, against what is
# staged or tracked, so it catches a file before it is ever committed.

set -eu
cd "$(git rev-parse --show-toplevel)"
status=0

# Assembled from parts so this file never matches itself. Covers PEM and
# OpenSSH private keys of every kind, age keys of both kinds (the post-quantum
# ones carry a PQ marker after KEY), and PuTTY key files.
key_header='BEGIN ([A-Z0-9]+ )*PRIVATE'" KEY"
age_secret='AGE-SECRET'"-KEY-"
putty='PuTTY-User'"-Key-File-"
leaks=$(git grep --cached -lE "$key_header|$age_secret|$putty" -- . || true)
if [ -n "$leaks" ]; then
  echo "private key material in:" >&2
  echo "$leaks" | sed 's/^/  /' >&2
  status=1
fi

fonts=$(git ls-files --cached -- ':(icase)*.ttf' ':(icase)*.otf' ':(icase)*.ttc' \
  ':(icase)*.woff' ':(icase)*.woff2')
if [ -n "$fonts" ]; then
  echo "font files are never committed:" >&2
  echo "$fonts" | sed 's/^/  /' >&2
  status=1
fi

# chezmoi renders templates on every apply, diff and verify, so a template that
# reads 1Password would prompt or fail on a headless machine. Only scripts may
# call op, and only behind a guard.
op_func='onepassword'
# Any onepassword* template function, whatever follows it. No \b: macOS's
# regex library doesn't support it.
# The [onepassword] section of chezmoi's own config, which turns its prompt
# off, is the one line that may name it.
reads=$(git grep --cached -nE "${op_func}[A-Za-z]*([^A-Za-z]|$)" -- home | grep -vE ":\[${op_func}\]$" || true)
# Commands a template runs through output or outputList are an allowlist,
# since op can hide behind a path, a shell or env: only scutil, for the Mac's
# current names. Every call in every action is checked, whatever else shares
# its line and however many lines the action spans. exec runs a command too,
# and has no allowed use here. Comments inside an action are skipped.
runs=$(git ls-files --cached -- home | while IFS= read -r f; do
  git show ":$f" | F="$f" perl -0777 -ne '
    while (/\{\{(.*?)\}\}/sg) {
      my $a = $1;
      $a =~ s{/\*.*?\*/}{}sg;
      while ($a =~ /(?<![A-Za-z])(outputList|output|exec)(?![A-Za-z])/g) {
        my $fn = $1;
        next if $fn ne "exec" && substr($a, pos($a)) =~ /^\s+"scutil"(\s|$)/;
        print "$ENV{F}: $fn\n";
      }
    }'
done)
# A template that switches its delimiters would slip past that scan.
delims=$(git grep --cached -n 'chezmoi:template:.*delimiter' -- home || true)
# Nor may a template look op up or name a 1Password reference; scripts may.
refs=$(git grep --cached -nE "lookPath +\"op\"|op://" -- home ':!home/.chezmoiscripts' ':!home/.chezmoitemplates' || true)
found=$(printf '%s\n%s\n%s\n%s\n' "$reads" "$runs" "$refs" "$delims" | sed '/^$/d')
if [ -n "$found" ]; then
  echo "templates must not read 1Password or run anything but scutil:" >&2
  echo "$found" | sed 's/^/  /' >&2
  status=1
fi

# Everything under home/ is meant to be committed. A file a gitignore hides,
# such as AGENTS.md under the global excludes, would silently never ship.
hidden=$(git ls-files --others --ignored --exclude-standard -- home | grep -v '/\.DS_Store$' || true)
if [ -n "$hidden" ]; then
  echo "files under home/ that a gitignore hides, so they would never be committed:" >&2
  echo "$hidden" | sed 's/^/  /' >&2
  status=1
fi

exit "$status"
