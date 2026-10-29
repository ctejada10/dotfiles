# dotfiles

My Macs and servers, set up and kept in shape by [chezmoi](https://www.chezmoi.io).

**Status:** the mini, amon-sul, runs from this repo. The laptop still runs the
old tilde until its cutover, and no server has had the playbook yet.

## Machines

| Machine | Role | Setup guide |
|---|---|---|
| arnor, MacBook Pro | `laptop` | [Personal Macs](docs/setup-macs.md) |
| amon-sul ("Amon Sûl"), Mac mini | `agent-mini` | [The mini](docs/setup-mini.md) |
| dor-lomin, rivendell, esgaroth | `server` | [Servers](docs/setup-servers.md) |
| GitHub Actions | `ci` | [Tests](#tests) |

`gondor` is kept for a future Mac Studio.

- **The laptop** is for personal work and job hunting. Of the development
  repos it clones only scripts, which its Raycast and Hazel run, and it's the
  only machine with 1Password's SSH agent and Ansible.
- **The mini** is where all development happens, run by agents in T3 Code, and
  where Hermes, the everyday assistant, lives. It runs on your Claude and
  ChatGPT subscriptions, headless after its first setup.
- **The servers** run Húrin (dor-lomin) and Rivendell's services, and esgaroth
  sits at home. The Ansible playbook sets them up, and applies this repo as
  its last step.

## Getting started

Each machine picks a role and a name once, at `chezmoi init`. Templates key off
the role, never off the hostname, which on macOS changes with the network.

On a Mac, after the steps its guide lists first:

```sh
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply ctejada10
```

It asks for the role, the name and the display name. Without a terminal, as in
CI or from Ansible, pass all three answers, or init stops at the first question
it can't ask:

```sh
chezmoi init --apply --promptChoice role=server \
  --promptString hostname=rivendell,displayName=Rivendell ctejada10
```

## Day to day

- After a PR merges, `chezmoi update --init` makes it live on a Mac in one
  go: it pulls this repo, rebuilds chezmoi's config from its template and
  applies. The pull is fast-forward only, so a checkout with commits of its
  own stops it instead of being rebased. To look first, run it with
  `--apply=false`, read `chezmoi diff`, then `chezmoi apply`. On the mini, run
  it in a terminal of your own: agents can't.
- Edit this repo on the mini, like every other repo. The laptop only pulls,
  and has neither gitleaks nor shellcheck for the hook and the tests.
- `chezmoi diff` shows what an apply would change. Read it before applying.
- `chezmoi apply` applies it, and `chezmoi verify` exits 0 when the machine
  matches the repo.
- `brew bundle --file=~/.local/share/chezmoi/Brewfile` installs anything that
  failed, such as an App Store app before signing in. The shell sets
  `HOMEBREW_TILDE_ROLE`, which picks this Mac's part of the shared Brewfile.
- `DOTFILES_CHECK=1 chezmoi apply` dry-runs the macOS settings and applies
  everything else. To change nothing at all, run the rendered script on its
  own, as the cutover's step 6 does.

### When an installer changes the shell

Installers like Hermes's want to append to `~/.zshrc` and `~/.zprofile`. Don't
let them keep it there: `chezmoi diff` shows what they added. Move what's
needed into a drop-in at `home/dot_zsh/conf.d/<tool>.zsh` in this repo, and the
next apply puts both files back. `~/.local/bin` is already first in `PATH`, so
a line that only adds it can go.

### Everything else, by guide

- **[Personal Macs](docs/setup-macs.md):** bootstrap, Dropbox and `~/.config`,
  the repos the laptop clones and the weekly backup of its personal files,
  Claude Code there, fonts,
  renaming a Mac, and cutting arnor over from the old tilde.
- **[The mini](docs/setup-mini.md):** bootstrap and macOS, Dropbox, T3 Code and
  T3 Connect, t3-pstack, Hermes, scheduled jobs, the final checks, how the
  mini's rules, Git hooks and worktree cleanup work, and what's still to bring
  into this repo.
- **[Servers](docs/setup-servers.md):** a new server, every run after, the
  checks before the first runs on dor-lomin and Rivendell, moving a deploy to
  the gate, phones and tablets, re-sealing secrets, and adding or renaming a
  server.

## What's where

- `home/`: the chezmoi source (`.chezmoiroot` points here). Its data is in
  `home/.chezmoidata/`: `hosts.yaml` (the servers, and the Macs the laptop logs
  in to), `keys.yaml` (public keys only), `repos.yaml`, `pins.yaml` and
  `fonts.toml`. The setup scripts are in `home/.chezmoiscripts/`.
- `ansible/`: the server playbook.
- `Brewfile`: both Macs' packages, one block per role.
- `tests/`: the suite. `.githooks/`: the pre-commit hook.
- `LICENSES/`: the licences of the skills copied in.
- `docs/`: the setup guides.

## Tests

```sh
bash tests/run.sh
```

In a new clone or worktree, install the playbook's pinned collections first,
from `ansible/`: `uv run --locked ansible-galaxy collection install -r
requirements.yml`. They aren't committed, and `tests/ansible.sh` fails without
them rather than skip.

Everything runs in throwaway homes; no test reads 1Password, a key or a
server. It checks:

- no private key material, licensed font or 1Password-reading template is in
  the index (also the pre-commit hook, with gitleaks);
- every setup script, rendered for every role, parses and is shellcheck-clean;
- what each role gets and must never get;
- the Claude Code hooks: the Git and vault guards block what they must, even
  when they crash, and the risky-command hook's warnings reach the model;
- the server playbook parses, and ansible-lint finds nothing at its production
  profile (`ansible/.ansible-lint` skips two style rules and makes warnings
  fail too);
- applying twice changes nothing, `chezmoi diff` is empty and `chezmoi verify`
  exits 0;
- the new shell matches a recording of the old one, apart from a short list of
  deliberate changes, and starts without errors with no terminal, as agents
  start it.

On the mini, where this repo is edited, the apply turns the hook on. In any
other clone: `git config core.hooksPath .githooks`.

CI (`.github/workflows/tests.yml`) runs these on `ubuntu-24.04` on every push
and pull request, after a gitleaks scan of the whole history, and weekly on
`macos-26`, which can also be started by hand from the Actions tab. GitHub has
no macOS 27 runner yet, so the Mac job tests one version behind the laptop. On
Ubuntu the Mac-only tests exit early, and the roles are `ci` and `server`.

Two more run only in CI, because they change the machine they run on:

- `tests/server-playbook.sh`, on every push and pull request, runs the server
  playbook for real on a second Ubuntu runner, as a server called `ci-runner`
  that no list here names: the device-key guard, a `--check`, then two real
  runs, the second changing nothing, and checks of sshd, UFW, `/tmp` and
  `authorized_keys`, a login with a stand-in device key, and a login without a
  key turned down.
- `tests/macos-ci.sh`, in the weekly Mac job, checks that every formula and
  cask the Brewfile lists for each Mac still exists in Homebrew, installs a
  few, then applies both Macs' settings for real and expects a dry run right
  after to find nothing to change. A setting the apply skips fails the job. It
  first adds a throwaway SSH key and a stand-in iCloud Drive folder, so the
  mini's key-only SSH and the screenshots folder are checked too.

Each refuses to run anywhere else unless told it's on a throwaway machine
(`DOTFILES_HARDEN_THIS_MACHINE=yes` or `DOTFILES_CHANGE_THIS_MAC=yes`).
