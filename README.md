# dotfiles

My Macs and servers, set up and kept in shape by [chezmoi](https://www.chezmoi.io).

**Status:** being built. The old tilde is still the live setup on arnor until
the cutover below; its GitHub repo is deleted, and its checkout in Dropbox
stays until then. Nothing here has been applied to arnor yet.

## Machines

Each machine picks a role and a name once, at `chezmoi init`. Templates key off
the role, never off the hostname, which on macOS changes with the network.

| Machine | Role | Notes |
|---|---|---|
| arnor, MacBook Pro | `laptop` | Daily driver. The only machine with 1Password's SSH agent and Ansible. |
| amon-sul ("Amon Sûl"), Mac mini | `agent-mini` | Runs agents unattended. Headless after its first setup. Its Dropbox syncs only the repositories folder. |
| dor-lomin, rivendell, esgaroth | `server` | Set up by the playbook, which runs this repo as its last step. |
| GitHub Actions | `ci` | Renders and applies everything; never touches 1Password, sudo or a real machine's names. |

`gondor` is kept for a future Mac Studio.

Without a terminal, as in CI or from Ansible, pass all three answers, or init
stops at the first question it can't ask:

```sh
chezmoi init --apply --promptChoice role=server \
  --promptString hostname=rivendell,displayName=Rivendell ctejada10
```

## Set up a Mac

Every Mac starts the same way:

1. Install the Xcode command line tools: `xcode-select --install`.
2. Install 1Password, sign in, and turn on Settings → Developer → Integrate
   with 1Password CLI. On the laptop, also turn on the SSH agent there.
3. Sign in to the App Store, so the Mac App Store apps can install.
4. Run:

   ```sh
   sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply ctejada10
   ```

   It asks three questions: the role, the name (lowercase letters, digits and
   hyphens, 15 characters at most) and the display name (what Find My and
   AirDrop show; capitals, spaces and accents are fine). It asks for your
   password to rename the Mac and set the power settings, and Homebrew asks
   again for the casks that install a package, such as Tailscale. The App
   Store apps install last, and only when you run it at the Mac's own screen
   with the App Store signed in (mas may ask for the password too). Telling
   whether it is signed in needs Full Disk Access, which Terminal doesn't
   have, so on a new Mac the apply says they wait, and
   `brew bundle --file=~/.local/share/chezmoi/Brewfile` installs them once
   you've signed in.

A second `chezmoi apply` changes nothing, `chezmoi diff` is empty and
`chezmoi verify` exits 0.

On a wiped Mac, Dropbox is installed during that first apply, so anything that
lives in Dropbox waits for it: sign in to Dropbox, let it finish, then run
`chezmoi apply` once more. That second apply writes 1Password's `agent.toml`
into `config-files` on the laptop and clones any missing tools into `~/src`.
On the laptop it also stops once, because `~/.config` is still the real folder
`init` made; the Repos section says what to do.

On the laptop the time zone follows its location. That needs System Settings →
Privacy & Security → Location Services → System Services → Setting time zone
turned on, which no script can do.

On the laptop, open Tailscale, allow its system extension and VPN
configuration, and sign in (the mini's steps are below). The first time you
open Ghostty, or any other app the Brewfile installed, macOS asks whether to
open an app downloaded from the internet: open it.

A new Mac given the name of one still on the network, as a new laptop is while
the old arnor is on, can't have it on the network: macOS calls it `arnor-2`
there (Bonjour, `arnor.local`, and SMB). The apply says so and leaves it; once
the old one is off or renamed, `chezmoi apply` sets the name.

### The mini

Bootstrap in this order, then follow the *Mac mini Setup Guide*, which starts
where this repo finishes:

1. Xcode command line tools.
2. Homebrew, then the lines it prints under *Next steps*, so `brew` is on
   your PATH for step 4. The apply replaces that `~/.zprofile` with its own.
3. 1Password, signed in, with CLI integration on. This is only for the first,
   attended setup: it fetches MonoLisa.
4. `brew install gh && gh auth login` (HTTPS). Git on the mini goes through
   `gh`, never through 1Password. If the browser step asks to grant access to
   the cad-accessibility organisation, grant it, or its repos won't clone.
5. The one-liner above, answering `agent-mini`, `amon-sul` and `Amon Sûl`.

Then check:

- `op whoami`
- `chezmoi verify`
- `gh --version && git lfs version`
- `~/.ssh/mini_signing.pub` exists (the apply makes it if the guide didn't) and
  is on GitHub as a signing key. `gh auth login` doesn't grant the scope that
  takes, so ask for it for this one step and drop it again:
  `gh auth refresh -h github.com -s write:ssh_signing_key && gh ssh-key add ~/.ssh/mini_signing.pub --type signing --title amon-sul; gh auth refresh -h github.com -r write:ssh_signing_key`
- `gh auth status` and `git ls-remote https://github.com/ctejada10/dotfiles`
  (this replaces the guide's `ssh -T git@github.com`: the mini's Git doesn't
  use SSH)
- `git ls-remote https://github.com/cad-accessibility/cad-a11y`
- `ls ~/.claude`
- `ls ~/src`
- `sudo systemsetup -gettimezone` shows America/New_York
- `node --version` is v20 or later

Once they pass, turn off 1Password's CLI integration and its SSH agent on the
mini. 1Password there can open the whole Private vault, and the mini runs
agents nobody is watching.

**By hand, on purpose.** These have no clean command-line route, or shouldn't
have one:

- FileVault off and automatic login on (automatic login needs FileVault off).
- Full Disk Access and the other privacy grants. The apply turns Remote Login
  and Screen Sharing on with sudo, Full Disk Access or not; if it said it
  couldn't, turn them on in General → Sharing.
- Signing in to the App Store and every account: Claude, ChatGPT, `gh`, the
  Anthropic API key, T3 Connect, Telegram, Google, Todoist.
- Tailscale: open it, allow its system extension and VPN configuration, and
  sign in. The laptop reaches the mini over the tailnet. Until then the
  apply leaves the tailnet name alone.
- In Tailscale's admin console, turn off key expiry for amon-sul, or the mini
  drops off the tailnet when its key expires (180 days by default). Then
  replace the default policy, which lets every device reach every port on
  every other, with grants: the laptop to amon-sul on tcp:22, tcp:5900 and
  udp:5900-5902, and nothing with amon-sul as the source. Keep what the
  laptop needs for the servers (esgaroth takes SSH from the tailnet only),
  and check from the laptop that each one still answers before saving.
- Screen Sharing's two options, under General → Sharing → ⓘ next to Screen Sharing:
  "Anyone may request permission to control screen" and "VNC viewers may
  control screen with password" stay off. The apply limits who may connect
  but can't reach these.
- On the router: nothing forwarded to the mini, UPnP off, and unsolicited
  inbound IPv6 blocked. In August 2026 attackers got into Macs whose port
  5900 was open to the internet (CVE-2026-65400) without valid credentials.
- Time Machine.
- If Software Update's "install macOS updates" turns itself back on, set it in
  System Settings: without MDM the key may not stick.

Once Remote Login and Tailscale are on, run `chezmoi apply` once more at the
mini's own terminal: SSH turns key-only only once Remote Login is on, and only
in an apply that can ask for sudo. Then, from the laptop, `ssh -o
PubkeyAuthentication=no amon-sul` is refused with `Permission denied
(publickey)`, and `ssh amon-sul true` works.

**Dropbox on the mini.** Sign in to Dropbox and, before it syncs anything, set
Selective Sync to the `repositories` folder only, and inside it untick
`tilde`: the old checkout holds arnor's old SSH keys. Everything else in
Dropbox stays off the mini. The repos the agents need are cloned once into that folder
if they aren't there already, after Dropbox has finished bringing it down.

**What the mini never holds:** the personal age key on disk (a re-seal reads
it from 1Password and keeps it in memory), the app-settings blob, a
key that can log in to the servers, Ansible (`bash tests/run.sh` in a dotfiles
worktree puts it in that worktree's `ansible/.venv` to check the playbook's
syntax, and never runs it against a host), Docker Desktop, the Claude desktop
app or any Dropbox folder but `repositories`. Its Claude Code loads none of the
account's claude.ai connectors or synced plugins.

**Reaching the mini.** Remote Login and Screen Sharing are on, both for your
account only. SSH takes keys only: `/etc/ssh/sshd_config.d/010-dotfiles-keyonly.conf`
turns off passwords, keyboard-interactive and root, and every apply checks
that the running sshd offers publickey alone. The application firewall is on
with stealth mode, so the mini doesn't answer `ping` (use `tailscale ping`).
Block-all stays off: it would shut out new SSH and Screen Sharing
connections. SSH stays reachable on the LAN as well as the tailnet, so a
Tailscale outage doesn't lock you out: at home, `ssh ctejada@amon-sul.local`
gets there without Tailscale. macOS can't bind sshd to one network anyway,
because launchd owns port 22. With FileVault off and automatic login on, a restarted mini logs
itself in, which the Tailscale app needs before it can reconnect.

**Rules on the mini.** Every agent there, Claude Code and Codex alike, reads
one file: `home/dot_codex/AGENTS.md` in this repo, which becomes
`~/.codex/AGENTS.md`. Codex reads it directly; the mini's `~/.claude/CLAUDE.md`
is the one line `@~/.codex/AGENTS.md`. Edit that file, nothing else: no other
rules file loads on the mini. It keeps runs from waiting on you (decisions go
in the draft PR, under *Decisions for Carlos*, and only a real stop asks), and
its first rule is absolute: a commit is never co-authored by an AI agent.
Claude Code's own attribution is switched off in its settings on every Mac.

**Git on the mini.** Agents commit, push and open draft PRs on their own
branches without asking; never on the default branch, never a force-push, a
merge or a PR opened ready. Claude Code's `hooks/guard-git.py` blocks the
ordinary forms of each, and refuses a commit or PR that credits an AI.

The laptop's repos in `~/src` and this dotfiles source change only for a task
you typed, and never in place: a laptop repo's `.git` is the laptop's, shared
through Dropbox, and `~/.local/share/chezmoi` is the mini's live config. An
agent clones a laptop repo from GitHub into `~/worktrees/<repo>/<branch>`, or
makes a worktree of the dotfiles repo in `~/worktrees/dotfiles/<branch>`, and
ends with a draft PR you merge or drop. The hooks block the in-place forms.
Codex has none of those hooks yet. A ruleset on each repo's default branch
that blocks direct pushes and force-pushes is the only lock that holds for
every agent.

The hooks catch an agent's mistakes, not a determined script. They follow
`cd`, `-C`, `--git-dir`, `--work-tree`, the `GIT_DIR` family of variables,
`env`, `sh -c`, `eval`, `xargs`, `find -exec`, subshells and substitutions,
and they block when a command crashes them or nests more than three levels
deep. They don't read a script file that a command runs, a command whose name
comes from a substitution, a git alias, `git update-ref`, or a folder an
ordinary variable gets from `read` or a `for` loop. The vault guard on the
laptop also misses a vault path that `xargs` takes from its input, and a
shell fed by `cat file |` or `curl ... |`. A commit or PR command that quotes
an AI credit line anywhere in it is blocked, so a search for one goes in its
own command.

**Worktrees on the mini** stay out of Dropbox. T3 keeps its own in
`~/.t3/worktrees`, Claude Code's go to `~/worktrees/<repo>/<name>` through
`hooks/worktree.sh`, and FirstMate's crews use treehouse's `~/.treehouse`.
They are worktrees of the checkouts in Dropbox, so every commit made in one
lands in that repo's `.git` and reaches the laptop. Git's automatic gc and
maintenance are off in every Dropbox repo on both Macs. Nothing edits a
checkout in Dropbox itself: the path guard sends an agent to a worktree.

Finished worktrees stay, so a follow-up thread can pick one up, and clean up
after themselves. A LaunchAgent runs `~/.local/bin/worktree-ttl` daily at
04:17 and removes a worktree in `~/worktrees` once it has gone 14 days unused
(no edits, commits or Claude Code session there; an edit to a file the repo
ignores counts too, apart from caches, environments and build output) and
nothing in it would be lost: never one with an open PR, unpushed commits,
commits only its reflog holds, uncommitted work, a running process or a lock
(`git worktree lock --reason "keep: <why>"` keeps one). A
merged branch goes with its worktree. A laptop repo's clone there is judged
the same way, and goes only when each of its branches is merged, or pushed
with no open PR, and it holds no stash. It goes to the Trash, not deleted, and
`git worktree lock` doesn't apply to a clone: an open draft PR keeps one. The
job never fetches, prunes, gc's or uses `--force`. It logs to
`~/Library/Logs/worktree-ttl/`, and anything it can't decide, such as a moved
or broken worktree, goes in `attention.txt` there. T3's and FirstMate's
worktrees are left to them.

**FirstMate on the mini.** The apply clones it to `~/firstmate` at the commit
in `pins.yaml` and sets `FM_HOME` to `~/.local/share/firstmate`, where its
state lives. Its `projects` folder holds a link to each repo under `agent-mini`
and nothing else, because FirstMate fetches, prunes branches and fast-forwards
every folder there; the registry is written once, every repo `direct-PR`.
Then, by hand: start Claude Code in `~/firstmate` and let its first session
install treehouse and the CLIs it asks for, approving each. Its crews branch
as `fm/<task>`.

**Docker on the mini.** Containers run in Colima, a small Linux VM that the
apply starts as a login service, with Homebrew's docker CLI, Compose and
Buildx. There is no Docker Desktop on either Mac.

**Never managed on the mini:** `~/.claude-api`, `~/.t3`, the Codex auth files,
`~/.hermes/.env` and what's inside `~/agent-drafts` (the folder itself is
created).

## Set up a server

cloud-init does the first boot and the Ansible playbook in `ansible/` does
the rest, from the laptop only, never from GitHub or the mini. Ansible owns
the system; its last step applies this repo as `server`, which owns the home
folder. Nothing here has been run against a real server yet.

From `ansible/`, once:

```sh
uv run ansible-galaxy collection install -r requirements.yml
```

This repo has to be on GitHub, readable without credentials, before any
server's first run: the run's last step clones it there, and fails without it
after all the hardening is done. A full run takes about 48 minutes from the
laptop, most of it the `nmap` scan.

**A new server.**

1. `uv run ansible-playbook cloud-init.yml -e out=<file>` writes its
   user-data with the login key from `keys.yaml`: your admin user, key-only,
   no password, no `ubuntu` account. Check it with `cloud-init schema -c
   <file>` on any Ubuntu machine and paste it into the provider's user-data.
2. Add the server to `home/.chezmoidata/hosts.yaml` and give it
   `ansible/hosts/<name>.yml` and a line in `ansible/packages.yml`. Make its
   DNS record (and any AAAA record) too: the playbook connects by name. Then
   `chezmoi apply` on the laptop, for its SSH config.
3. Open the server's SSH port in the provider's own firewall, if it has one.
   Then `uv run ansible-playbook site.yml -e target=<name> -e first_port=22`.
   The first connection asks you to trust the server's host key on 22; check
   it against the fingerprint the provider's console shows. The run opens the
   new SSH port in UFW, moves sshd to it, trusts the same host key on the new
   port, reconnects there and only then closes 22. At the end it asks for a
   sudo password and removes cloud-init's passwordless sudo. Keep that
   password in 1Password: the provider's console takes it if SSH ever fails
   (see *Adding a phone or tablet*). A run that stops
   at "Wait until the new port answers" is finished by the next run without
   `first_port`. Close 22 in the provider's firewall too.
4. On a server that deploys, the run also sets up `deploy`'s checkout. It
   pins GitHub's host keys, makes a read key for each repo `deploy` fetches
   (one each, since GitHub takes a deploy key on one repository only, so
   Rivendell's `arwen` gets its own) and prints every key GitHub doesn't take
   yet, or says it couldn't ask when GitHub doesn't answer; its last play
   lists where each repo stands. Add each to its
   repo as a read-only deploy key (Settings → Deploy keys), then run again:
   that run clones the checkout at `deploy_repo` and makes the folders its
   containers write in (`deploy_owned_dirs`). A key taken off GitHub later
   sends that repo's fetches back the way they went before, at the next run.
   Add the age key the run printed to the repo's `.sops.yaml` and re-seal its
   secrets.

Until a first run has finished, the admin user has no password, so a
provider console can't log in; after it, the console takes the sudo password.

**After that**, and for the existing servers:
`uv run ansible-playbook site.yml -e target=<name> -K`. A second run changes
nothing. `--check` shows what a run would change, without the checks and Lynis,
which need a real run, and without asking GitHub about `deploy`'s read keys, so
it shows no key, clone or switch to an alias; `--skip-tags lynis,scan` skips the
slow parts. A run cut off during a port move finishes it the next time.

Keep a second SSH session open to the server for the whole of any run. The run
counts on it if the new port or a new sshd turns out not to take logins.

**Before the first run on dor-lomin and Rivendell.** Read-only checks, each for
something a replica couldn't show:

- `ssh -v -o PreferredAuthentications=publickey -p <port> ctejada@<address> true`
  logs in as the playbook does, with keys only: it offers the login key and
  nothing before it, and says `Authenticated to ... using "publickey"`.
  Without that option a key the server turns down falls through to the
  password prompt, which the playbook never answers, so the run would stop at
  its first task. If it fails, add the `login` key from `keys.yaml` to
  `~/.ssh/authorized_keys` there first (on dor-lomin, through the link into
  the old checkout). The run lowers MaxAuthTries to 2, so a client that
  offers two wrong keys first is disconnected once sshd restarts.
- On the laptop, `ssh-keygen -F '[<address>]:<port>'` shows an `ssh-ed25519`
  key, and `ssh-keyscan -t rsa -p <port> <address> | ssh-keygen -lf -` says
  3072. An RSA key of any other size is replaced.
- `sudo ufw show added`: rules stored while UFW was off go live when the run
  turns it on. Find out why it was turned off first. On dor-lomin, fail2ban
  bans through UFW for 30 minutes, every port included, and those bans start
  working once UFW is on.
- `sudo journalctl -u ssh --since -30d | grep -oE 'Accepted [^ ]+ for [^ ]+' | sort | uniq -c`
  counts every login by method and account; if the journal doesn't reach
  back that far, run the same `grep` over `sudo zcat -f /var/log/auth.log*`.
  After the run only your user and `deploy` may log in (`AllowUsers`), root
  not at all, and `ubuntu` loses its passwordless sudo, so any other account
  in that list is cut off. Password login goes too, on Rivendell as on
  dor-lomin, and both `password` and `keyboard-interactive/pam` there are
  passwords: any device that still logs in with one needs its key in
  `keys.yaml` first (see *Adding a phone or tablet*), and the run refuses to
  turn password login off until every device listed there has a key. From the
  phone and the iPad, log in to dor-lomin with Blink before the run.
- `sudo find /root /home -maxdepth 2 -name .netrc`: the run deletes them.
- How `deploy` fetches today, which the run leaves alone until GitHub takes its
  new read key: `sudo ls -la ~deploy/.ssh`, `sudo cat ~deploy/.ssh/config`,
  `ls /etc/ssh/ssh_config.d` and `sudo -u deploy git -C <deploy_repo> config
  --get-regexp '^(remote|submodule|url|core)\.'`, and on Rivendell also
  `sudo -u deploy git -C ~deploy/rivendell/arwen config --show-origin
  --get-regexp '^(remote|url|core)\.'`, since arwen's own settings aren't in
  the list before it. GitHub has one deploy key on rivendell and another on
  arwen today, and a deploy key reaches only its own repo, so something on
  Rivendell sends each repo its key; find out what before the run. If
  `~deploy/.ssh` already holds a `github_hurin`, `github_rivendell` or
  `github_arwen`, rename it, and whatever names it, first: the run makes its
  read keys at those names, leaves a repo alone when the key there isn't one
  it made (its comment isn't `deploy@<server> <repo>`), and fails at its end
  naming it. The
  switch to the new key rewrites only URLs written
  `git@github.com:<owner>/<repo>.git`: dor-lomin's origin must read
  `git@github.com:ctejada10/hurin.git`, and Rivendell's `arwen` URL and
  arwen's own origin `git@github.com:ctejada10/arwen.git`. Set them to that
  form first, or once GitHub takes the key the run fails at its very end,
  after everything else is set up, naming the URL. A `core.sshCommand` there
  or in arwen decides how Git connects whatever the alias says, and the run
  fails the same way while one is set; take it out first. If today's fetch
  depends on that URL or that setting, change it after GitHub has the new
  read keys, right before the run that switches to them, not before the run
  that prints them: until that switch `deploy` still fetches the old way. On
  dor-lomin, `ls -ldn ~deploy/hurin/logs
  ~deploy/hurin/docker/services/caddy/data` should show uid 1001 and 1000
  and `drwxr-xr-x`, which the run sets; other owners, or a wider mode,
  mean something else depends on them.
- On dor-lomin `~/.ssh` and `~/.gnupg`, and on Rivendell `~/.gnupg`, link
  into the old checkout, `~/src/tilde`, and the run replaces only the shell,
  Git and tmux links: `find ~ -maxdepth 3 -lname '*src/tilde*'` lists what
  still points there. Until `~/.ssh` is a real folder, the run writes the
  login key through the link into the old checkout. Before `~/src/tilde` is
  deleted, reset or pulled, with a second session open, make both real
  folders:
  `for d in ~/.ssh ~/.gnupg; do [ -L "$d" ] && cp -aT "$(readlink -f "$d")" "$d.new" && rm "$d" && mv "$d.new" "$d"; done`.
  `cp -a` keeps each folder's owner and modes, which sshd checks. Test a new
  login from another terminal before closing the first.
- On dor-lomin, `sudo grep -r manage_etc_hosts /etc/cloud
  /var/lib/cloud/instance/`: if it's set, cloud-init puts the old name back
  in `/etc/hosts` at every boot.
- On Rivendell, `tailscale debug prefs` and `sudo iptables -t nat -S
  PREROUTING`: the run makes reverse-path filtering strict and turns IPv6
  forwarding off, which matters if it forwards anything into the tailnet.
- On Rivendell, 80, 443 and 32400 will answer over IPv6 too once UFW allows
  them by name; today UFW drops them there.
- On Rivendell, `apt-get -s remove cups cups-browsed cups-daemon` shows what
  goes with CUPS. The run also moves Docker to its own noble repository, so
  the next `apt upgrade` by hand offers Docker 29 and restarts dockerd; hold
  the packages or plan for it.

On Rivendell, also before that first run, move `deploy`'s existing age key
aside, so the run makes the server a fresh one:
`sudo -u deploy mv ~deploy/.config/sops/age/keys.txt ~deploy/.config/sops/age/keys.txt.old`.
It dates from the day `SOPS_AGE_KEY` went into GitHub, and nothing records
where it came from. Today's deploy doesn't read it (it writes GitHub's key to
`/tmp`), so moving it breaks nothing. Delete the `.old` file once the first
deploy through the gate passes. Then look in your own home there:
`ls -la ~/.config/sops/age/`. A `keys.txt` there is a copy of a personal age
key, and that `~/.config` is mode 777, so any account on the server can
replace what's in it. Delete it once the re-seal has dropped the old keys, and
take the write bit off for others: `chmod go-w ~/.config`.

The old tilde's secure-mode timer restarts sshd every minute on dor-lomin until
the run stops it, so a run can stop early as unreachable; run it again. After
any reboot of dor-lomin, Húrin stays down until the next deploy, or until
`docker compose up -d` in `~deploy/hurin/docker` as `deploy`. Once Rivendell
is key-only, Húrin's plex-collection-suggest can't log in to it with its
password, so its Rivendell step fails until the task *Stop Húrin writing into
the old checkout* replaces that login.

What a run does, and checks:

- devsec.hardening's SSH and OS roles, pinned at 11.0.0. Key-only login,
  root login off, `AllowUsers`, no agent forwarding; TCP forwarding stays on
  for VS Code's Remote-SSH and ProxyJump. sshd listens on IPv4 and IPv6, as
  today, keeps Ubuntu's 3072-bit RSA host key, and gives files made over SFTP
  (and so scp) Ubuntu's umask of 022. `sshd -T` and the SSH units' state are
  checked after.
- UFW, one named rule at a time, never reset. Docker and Tailscale come from
  their own apt repositories, each key checked against the fingerprint in
  `pins.yml`; chezmoi and sops are pinned by checksum.
- Unattended upgrades reboot for a new kernel at each server's
  `reboot_time`. CUPS goes, and apport is turned off, since it turns setuid
  core dumps back on at every boot.
- Docker keeps containers running while dockerd restarts (`live-restore`), so
  a reboot leaves them to the end of shutdown, and one whose main process
  ignores SIGTERM, as a shell script running as PID 1 does, holds the reboot
  90 s. `init: true` on that compose service fixes it.
- Side effects of the OS role: `/proc` is mounted `hidepid=2`, so `ps` and
  `htop` as your user show only your own processes, not containers or
  services; where password login is off, five wrong sudo passwords lock sudo
  for ten minutes (SSH isn't affected); every account's `.netrc` and
  `.rhosts` are deleted; auditd keeps five audit logs of 6 MB in
  `/var/log/audit` and deletes the oldest; and from the next boot `/tmp` is
  a tmpfs of up to half the memory, emptied at every boot. Whatever the
  disk's own `/tmp` holds at that first reboot stays on the disk under the
  tmpfs, out of sight and never cleared, so empty it of anything large
  before you reboot.
- A deploy part on the servers that deploy: the `deploy` user, sops, age,
  and an age key made on the server, whose public half the run prints. Its
  deploy gate runs a commit's `scripts/deploy.sh` to the end even when the
  workflow's connection drops, so cancelling a run doesn't stop a deploy
  half-way; the last deploy's output is in
  `~deploy/.local/state/deploy-gate/last-deploy.log`.
- Lynis on the first run and on every run after, with both scores shown.
  The reports stay on the server, in `/var/log`.
- From the laptop, an `nmap` of each public address that fails when what
  answers differs from `public_ports`, which catches Docker publishing past
  UFW.

Not yet, on purpose:

- **Docker's default address** stays `0.0.0.0` until the compose files in
  Húrin and Rivendell publish their public ports with an explicit
  `0.0.0.0:`; then set `docker_loopback_default: true` in the host's file.
  Docker settings apply at its next restart, which the playbook never does.
- **Automatic reboots on dor-lomin** stay off (`automatic_reboot: false` in its
  host file) until Húrin's compose file gives its containers `restart:
  unless-stopped`. Today they have `restart: no`, so a kernel reboot would leave
  Húrin down until the next deploy. Rivendell's containers restart themselves,
  Samba included: it's published on the Tailscale address, which tailscale0
  may not hold yet when Docker starts at boot, so the run lets Docker bind
  that address early (`net.ipv4.ip_nonlocal_bind`).
- **The deploy key** that can only ask the gate for a deploy, in this order.
  Add the age key the run printed to the deploy repo's `.sops.yaml` and
  re-seal, since the gate decrypts with the server's own key. Make the new key
  in 1Password, one per repo:
  `op item create --category "SSH Key" --title "hurin deploy key" --vault Private --ssh-generate-key ed25519`.
  Put its public half (`op read "op://Private/hurin deploy key/public key"`)
  in the host file's `deploy_public_key` and run. In the repo's settings, make
  an environment named `production` whose deployment branches are limited to
  `main` (Settings → Environments → New environment, then Deployment branches
  and tags → Selected branches → `main`): the deploy job runs in it, so no
  other branch's workflow can read the key. If `production` is already listed,
  a Deploy run made it by running first, with no branch rule; set the rule all
  the same. Then set the secret there straight from 1Password, so the private
  half never touches a disk or the screen:
  `op read "op://Private/hurin deploy key/private key?ssh-format=openssh" | gh secret set VPS_SSH_KEY --env production -R ctejada10/hurin`.
  The same line sets it again when a repo is recreated. Add the Actions
  variables the gate's workflow reads: `VPS_HOST`, `VPS_PORT` and `VPS_USER`,
  which today's workflow reads as secrets (Húrin's writes its port in as
  6969), and `VPS_HOST_KEY`, set to what the run printed. Only then merge the
  change that moves the repo's Deploy workflow to the gate, while no Deploy
  run is in progress: the old workflow's runs neither wait in the new one's
  queue nor take the gate's lock. The first deploy through the gate is the
  Deploy run that starts by itself once CI passes on the merge (Húrin's CI
  takes 11 to 14 minutes); a Run workflow before the merge runs the old
  workflow and proves nothing about the gate. If that run stops on a setting,
  fix it and re-run it. Once it passes, on dor-lomin run `docker builder
  prune -af` once as `deploy`: deploys before the gate left the decrypted
  files in Docker's build cache. Then delete the repository-level secrets
  today's workflow used, which the gate's doesn't read: `VPS_SSH_KEY` (today's
  key), `SOPS_AGE_KEY` (the age key it decrypts with), `VPS_HOST`, `VPS_USER`,
  and `HEALTH_API_KEY` on Húrin or `VPS_PORT` on Rivendell. Until they are
  gone, re-running a Deploy run from before the merge runs the old workflow,
  around the gate. Then put today's unrestricted key in `deploy_retired_keys`
  and run again, which takes it out. The keys `deploy` fetched with before
  stay on GitHub until you delete them. A run that couldn't ask GitHub
  still passes, and so does a deploy on the old key, so go by the list the
  run prints at its end ("Say where each repo deploy fetches stands"): each
  repo there must say GitHub takes its read key and Git fetches it through
  its alias. `sudo -u deploy git -C <deploy_repo> remote get-url origin`
  then prints `git@github-hurin:ctejada10/hurin.git` (on Rivendell
  `git@github-rivendell:ctejada10/rivendell.git`, and in
  `~deploy/rivendell/arwen` `git@github-arwen:ctejada10/arwen.git`). Once a
  run has passed with every line saying so and a deploy through the gate has
  passed, delete
  hurin's `hurin-server-repo-access`, rivendell's `github-actions-deploy` and
  arwen's `deploy@rivendell` (Settings → Deploy keys). rivendell's can also
  push, so check its last use there first for a push nothing explains. The
  repo's commits need an executable
  `scripts/deploy.sh`, or the gate refuses them. Rivendell's key is "rivendell
  deploy key".
- **Joining the tailnet**: on a server with `tailscale: true`, Tailscale is
  installed, not logged in.
- **esgaroth**: the run stops at its first check unless it runs Ubuntu or
  Debian, and before UFW goes on unless Tailscale is logged in there, since SSH
  then comes from the tailnet only. Its home-network ports in
  `ansible/hosts/esgaroth.yml` (Home Assistant's 8123 for now) need checking
  before its first run.

## Repos

Both Macs keep their repos in the Dropbox `repositories` folder; `~/src` and
`~/Repositories` link to it, and Dropbox carries the repos between them.

On the laptop `~/.config` links to Dropbox's `config-files` too, so gh, op,
rclone, Raycast and the rest keep syncing their settings as they always have.
chezmoi keeps its own config and state there too, in `config-files/chezmoi`.
The link is made only once Dropbox has brought `config-files` down. Until
then, and on a wiped laptop, `init` writes a real `~/.config/chezmoi`, and the
next apply stops rather than replace that folder. Move `~/.config/chezmoi`
into `config-files`, replacing any `chezmoi` folder an earlier install left
there (its state would stop setup scripts from running again), then make the
link yourself, since chezmoi can't find its config until it exists:
`rmdir ~/.config && ln -s ~/Library/CloudStorage/Dropbox/config-files ~/.config && chezmoi apply`.
On a wiped laptop the first apply's 1Password check also leaves
`~/.config/op` holding only op's socket; remove it first (`rm -r ~/.config/op`),
or `rmdir` refuses. The preflight's message says so. It stops the same way
for a real `~/src` or `~/Repositories` with files in it.
This repo writes nothing inside that link except 1Password's `agent.toml`,
which has to live there. Its own files sit outside it: the shell in `~/.zsh`,
and Ghostty's config in `~/Library/Application Support/com.mitchellh.ghostty`.
The personal age key is on no Mac at all (see *Re-sealing secrets*). The mini
keeps a local
`~/.config`; its Dropbox syncs nothing but `repositories`.

The repos the mini's agents work in are listed under `agent-mini` in
`home/.chezmoidata/repos.yaml`. On the laptop they are read-only, because two
Macs writing one `.git` through Dropbox is how an object store gets destroyed:

- `git`, which on the laptop is a wrapper in `~/.local/bin`, runs only
  commands that read there: status, log, diff, show, blame, grep, listing
  branches and tags, and the like. Everything else, switch, checkout, reset,
  rebase, add, commit, stash, fetch, pull and push included, is refused before
  Git starts, so nothing touches the working tree or the `.git`.
- Behind it, for anything that runs the real git directly, such as VS Code's
  autofetch, Git refuses any change to their refs, refuses a rebase before it
  starts, and may use no transport there (`protocol.allow = never`), so it
  can't fetch, pull or push; Git LFS gets a URL it can't use, and keeps the
  temporary files it makes whenever Git hashes an LFS file in a folder of the
  laptop's own. The wrapper lets `git lfs ls-files` through only in a repo
  whose own config already holds git-lfs's version, which the mini's git-lfs
  writes there; elsewhere git-lfs would write it. The remote URLs
  stay as they are, so `gh pr view`, `list` and `checks` work. A refused switch
  or reset through the real git can still have rewritten the working tree by
  then; clean that up on the mini.
- Nothing that reads writes the index back: `GIT_OPTIONAL_LOCKS=0` covers
  status, the wrapper gives diff and `describe --dirty` a copy of the index,
  and `diff.autoRefreshIndex` is off for the real git. No fsmonitor daemon, no
  untracked cache, no automatic gc.
- Claude Code's Edit and Write tools can't touch files in them (a shell
  command still can), and it doesn't fetch without asking.

Plain edits in an editor are still possible, so leave those to the mini too.
Read on the laptop; change on the mini. To run something anyway, call the real
git by its path, `/opt/homebrew/bin/git`. A repo that sets its own
`core.hooksPath` in `.git/config` skips the hooks; every apply on the laptop
names any that do.

The job-search tools, career-ops and ai-job-search, are cloned once into
`~/src` and keep your CV, salary expectations and applications inside their
checkouts, where Dropbox syncs them. Neither can ever push: their push URL goes
nowhere, and ai-job-search, whose setup writes your profile into files Git
tracks, also has a pre-push hook that refuses. Personal edits stay uncommitted.

## Claude Code

All development happens on the mini. The laptop is for personal work and job
hunting, and has no development plugins or skills. Each role's plugins are
declared in `home/dot_claude/modify_settings.json`; Claude Code installs them
in the background the first time it starts.

- **The laptop:** freehire (read-only job search), humanizer (for cover
  letters) and Obsidian's skills, plus your own skills and rules (email
  replies, Todoist triage, the vault researcher) and `rules/job-search.md`.
- **The mini:**
  - Process: t3-pstack routes, through poteto-mode, and is the only plugin
    whose session hook steers the work. Install it by hand at a tag, never
    from main:
    `npx -y github:chhoumann/t3-pstack#v2.0.0-rc.18 install`, then
    `/t3-pstack:setup-pstack` in an attended T3 thread, answering
    `session hook: on`. The installer turns on auto-update from main every
    time it runs; the next apply turns it off. Its hook also loads in plain
    `claude` runs outside T3; start one with
    `claude --settings '{"enabledPlugins":{"t3-pstack@t3-pstack":false}}'`
    to leave it out.
  - superpowers, as a skill library t3-pstack and the agents call by name: its
    test-first features, its plans, its debugging material. It comes from a
    local marketplace in `~/.local/share/claude-plugins/sp-gated`, unchanged
    from its release (pinned in `pins.yaml`), whose entry replaces its session
    hook with one that does nothing, so it never competes with t3-pstack.
    `hooks/agent-gate.sh` keeps it from waiting on you when you aren't there:
    unattended, brainstorming is refused, a question reaches you only when it
    starts with `STOP:`, and every other ask becomes a Ruling under *Decisions
    for Carlos* at the top of the draft PR. Specs and plans go in
    `~/agent-drafts/<repo>/<branch>/`. Its finishing menu never runs: a branch
    always ends pushed, with a draft PR.
  - **Design conversations, when you want one:** in T3, open a thread on the
    "Claude (attended)" instance and type `/superpowers:brainstorming` with the
    idea or an issue. Its questions arrive as T3's ask-for-input cards and wait
    until you answer; once you approve the plan, the run goes on to a draft PR
    without you.
  - Plugins: Ponytail with its full ruleset always on, the Karpathy
    guidelines, agnix, the ty language server, and Trail of Bits' supply-chain
    auditor, property-based-testing, mutation-testing and
    spec-to-code-compliance. No pstack: t3-pstack is its port for T3. No
    claude.ai connectors or synced plugins.
  - Skills copied in under their licences: a subset of Matt Pocock's
    (grill-me, to-spec and the architecture ones), HumanLayer's research, plan
    and implement set (`rpi-`), GitHub's Actions hardening review and
    i-have-adhd. Four review agents from ECC (`ecc-`). See `LICENSES/`.
  - Downloaded at pinned commits, because there is no licence to copy them
    under: the OpenSCAD skill with BOSL2 (outside `~/Documents`, which can hang
    T3 on a privacy prompt), and two of George Wang's skills (read-only log
    investigation, browser evaluation).
  - The agnix and no-mistakes command-line tools at pinned versions, Herdr,
    and Go. no-mistakes stays inert until you run `no-mistakes init` in a repo
    yourself.
  - `~/.codex/AGENTS.md` picks one tool per job where they overlap, and says
    what none of them may do on their own. It wins over every plugin, skill
    and playbook.
- **Servers:** pstack only.

3D models: the mini writes and renders them; Bambu Studio and the printer stay
with the laptop, so a finished model is a file you open there. The skill reads
which filaments are loaded from Bambu Studio's cache, which only the laptop
has; on the mini, tell it.

**Once, after the cutover:** run the "About Me" pass from the one-weekend setup
roadmap. Ask Claude to interview you, four questions at a time, about how you
work. It proposes each preference it finds as one item for `CLAUDE.md` or a
rules file here; personal answers go to a note you name, never this public
repo.

## Day to day

- Edit this repo on the mini, like every other repo. The laptop only pulls,
  with `chezmoi update`, and has neither gitleaks nor shellcheck for the hook
  and the tests.
- `chezmoi diff` shows what an apply would change. Read it before applying.
- `chezmoi apply` applies it.
- `chezmoi verify` exits 0 when the machine matches the repo.
- `brew bundle --file=~/.local/share/chezmoi/Brewfile` installs anything that
  failed, such as an App Store app before signing in. The shell sets
  `HOMEBREW_TILDE_ROLE`, which picks this Mac's part of the shared Brewfile.
- `DOTFILES_CHECK=1 chezmoi apply` dry-runs the macOS settings and applies
  everything else. To change nothing at all, run the rendered script on its
  own, as cutover step 6 does.

### When an installer changes the shell

Installers like Hermes's and T3's want to append to `~/.zshrc`. Don't let them
keep it there: `chezmoi diff` shows what they added. Move it into a drop-in at
`home/dot_zsh/conf.d/<tool>.zsh` in this repo, and the next apply puts
`~/.zshrc` back. `~/.local/bin` is already first in `PATH`.

### Adding a machine

Choose a role and a name. For a server, add it to
`home/.chezmoidata/hosts.yaml`, which the laptop's SSH config and the Ansible
inventory both come from, and give it `ansible/hosts/<name>.yml` and a line in
`ansible/packages.yml` (`tests/ansible.sh` fails until both exist). No template
changes.

### Adding a phone or tablet

Each phone and tablet logs in to the servers and the mini with a key of its
own, which Blink Shell makes in the device's Secure Enclave, so the private
half never leaves the device.

1. In Blink, type `config`, then Keys, +, Generate SE Key, named after the
   device. Copy the key's public half (it starts `ecdsa-sha2-nistp256`) and get
   it to the laptop with Universal Clipboard or AirDrop.
2. Put it in `home/.chezmoidata/keys.yaml` under `ssh.devices`, on that
   device's line (`iphone`, `ipad`, or a new name), and push it like any other
   change.
3. On the laptop, `chezmoi update`, then from `ansible/`, one server at a
   time, `uv run ansible-playbook site.yml -e target=<name> -K`: `-K` asks
   once and gives every server in the run the same sudo password. On the
   mini, `chezmoi update` writes its `authorized_keys`.
4. From the device, log in to each server and to the mini.

A device whose line is empty has no key yet, and the playbook won't turn
password login off on a server that still takes passwords until every device
has one.

**A new device in place of an old one.** Make the new key as above and put it
on that device's line. Move the old public half to `ssh.retiredLogin`: each
server's next run takes it out of `authorized_keys`, and the mini's next apply
drops it, since chezmoi writes that whole file. Wipe the old device once the
new one logs in everywhere.

**A lost device, away from the laptop.** From the other device, take the lost
key out on each server and on the mini, with the long middle part of the lost
key in place of `<key>` and each machine's address, port and user from
`hosts.yaml`:

```
ssh -p <port> <user>@<address> "sed -i.bak '\|<key>|d' ~/.ssh/authorized_keys"
```

Back at the laptop, move it to `ssh.retiredLogin` as above before anything
applies on the mini, whose next apply would otherwise put it back.

**Everything lost.** The login key lives in 1Password, not on the laptop. On
any Mac, sign in to 1Password and turn on its SSH agent (Settings, Developer),
and to Tailscale for esgaroth and the mini, then log in as from the laptop and
add the new devices' keys. If SSH itself fails, Rivendell's and dor-lómin's
provider consoles take the admin user and its sudo password, also in
1Password.

### Re-sealing secrets

Once each repo's first re-seal is done, every sealed file in Húrin and
Rivendell opens with two keys: the personal age key, which lives only in
1Password as "dotfiles age key" (its public half is in
`home/.chezmoidata/keys.yaml`), and the key of the server it deploys to, which
the playbook makes on that server and whose public half its run prints. No Mac
keeps the personal key on disk. On the mini, 1Password's CLI integration stays
off except during a re-seal or a MonoLisa upgrade, Claude Code denies `op`, and
the rules every agent
there reads (`~/.codex/AGENTS.md`, Codex's and Claude Code's alike) forbid it.
To add a server's key, replace a server or drop an old key:

1. In a worktree of the repo on the mini, put the new public half in
   `.sops.yaml` next to the one it replaces.
2. Turn 1Password's CLI integration back on on the mini for this step, then in
   that worktree run
   `SOPS_AGE_KEY="$(op read 'op://Private/dotfiles age key/password')" make secrets-reseal`
   and turn the integration off again. The first re-seal of each repo is the
   exception: until then the personal key doesn't open its blobs. Tilde's old
   key (`age1qmu9…`), kept in the note of "tilde age key", opens both repos',
   so that run reads `op://Private/tilde age key/notesPlain` instead, and the
   old keys step 3 removes are that one and, in Húrin, `age198t3…`.
3. Commit, push and open the PR. Once a deploy passes with the new key, remove
   the old one from `.sops.yaml` and re-seal the same way.

Neither repo has a `secrets-reseal` target yet; it comes with the work that
moves each repo's deploy to the gate. It runs `sops updatekeys -y` on every
sealed file, which never writes a plaintext to disk, and two things come
first. sops picks a `.sops.yaml` rule by the name it's given, here
the sealed file's, and Rivendell's rule and Húrin's rules for the job list and
the two settings files match only the plaintext names, so `updatekeys` stops
with "no matching creation rules found". And Húrin's whole-file blobs need
`--input-type binary`, or sops writes them back as YAML, which the deploy's
`sops --decrypt --input-type=binary` can't read.

### Renaming a machine

Run `chezmoi init --prompt` on it, give the new name, then `chezmoi apply`. On
a Mac that sets all four macOS names (ComputerName, LocalHostName, HostName,
NetBIOSName) and Tailscale's. Then check by hand:

- the machine's name in T3 Connect;
- Obsidian Sync's device name (it lives in `.obsidian`, which nothing here
  touches);
- Time Machine's backup name;
- the old name's lines in `~/.ssh/known_hosts` on other machines;
- for a server, also DNS, the deploy workflows' host variables, and the names
  Plex and Samba show.

## Cutting arnor over from the old tilde

A preflight script refuses any apply while `~/.ssh` is a link, and refuses to
replace the old tilde's links unless `DOTFILES_CUTOVER=1` is set. `~/src`,
`~/Repositories` and `~/.config` stay as they are: they already link to
Dropbox.

1. Check that the old tilde is gone from GitHub, which it has to be before
   this repo is first pushed: `gh api repos/ctejada10/tilde` says
   `Not Found (HTTP 404)`.
2. Finish the task *Close what's exposed in the old tilde*: `~/.ssh` is a real
   folder.
3. Create the new login and signing keys in 1Password and put their public
   halves in `home/.chezmoidata/keys.yaml`. Register both with GitHub.
4. Commit and push any work still open on the laptop in the repos listed under
   `agent-mini` in `home/.chezmoidata/repos.yaml`. After the apply, Git on the
   laptop refuses to commit or fetch in them. While the laptop is still the
   only Mac writing them, unset cad-a11y's own hooks path, which only points
   at its default `.git/hooks`: `git -C ~/src/cad-a11y config --unset core.hooksPath`.
5. `chezmoi init ctejada10`, answering `laptop`, `arnor`, and the display name.
6. Read what the apply would change. `chezmoi diff` shows the files; it leaves
   out the setup scripts, which run on every apply. For the macOS settings,
   `DOTFILES_CHECK=1 bash <(chezmoi execute-template < ~/.local/share/chezmoi/home/.chezmoiscripts/run_after_30-macos-settings.sh.tmpl)`
   prints each one it would change and writes nothing. For packages,
   `HOMEBREW_TILDE_ROLE=laptop brew bundle check --no-upgrade --verbose --file=~/.local/share/chezmoi/Brewfile`
   lists what it would install.
7. `DOTFILES_CUTOVER=1 chezmoi apply`.
8. Save anything running in tmux, run `tmux kill-server` (it closes every pane),
   quit Ghostty with Cmd-Q and open it again. Every Ghostty window reattaches
   to the running tmux session, so without this the next step checks the old
   shell.
9. In a new Ghostty window: the prompt looks the same, Ctrl-R opens fzf's
   history, `ssh -T git@github.com` works, a new commit shows `G` in
   `git log --format=%G? -1`, and the font is MonoLisa.
10. Remove what the laptop no longer gets.
   `brew bundle cleanup --file=~/.local/share/chezmoi/Brewfile` lists
   everything installed that the Brewfile doesn't name, VS Code extensions
   included. Docker Desktop, docker-compose, git-flow, gitleaks, hidapi, ruff,
   shellcheck, sshpass and the development extensions should be on it.
   Anything else on the list you want to keep goes into the Brewfile first.
   Then run it again with `--force`.
11. Delete `~/.oh-my-zsh` and the old `~/.zcompdump*` files.
12. Take the old login keys off the servers. A run adds the new login key but
   keeps every key already in a server's `authorized_keys` unless
   `ssh.retiredLogin` names it, so arnor's old keys and the old RSA ones keep
   logging in there. The iPhone's and the iPad's keys (`ssh.devices`) may be
   among those RSA lines, as `ctejada@gondolin` and `ctejada@lothlorien`: they
   stay, and a run refuses to retire a key that is also a device's. Once the
   new key logs in to each server, see which keys
   still log in there and from where:
   `sudo journalctl -u ssh --since -30d | grep -oE 'Accepted publickey for [^ ]+ from [^ ]+ .*SHA256:[^ ]+' | awk '{print $4, $6, $NF}' | sort | uniq -c`
   counts each account, address and key fingerprint (run the same `grep`
   over `sudo zcat -f /var/log/auth.log*` if the journal doesn't reach back
   that far), and `ssh-keygen -lf ~/.ssh/authorized_keys` gives each line's
   fingerprint. A key that logs in from an address none of your devices
   uses belongs to a script or another machine; find out which before you
   retire it, or that job stops. Then put each old key's line from that
   server's `authorized_keys` under `ssh.retiredLogin` in
   `home/.chezmoidata/keys.yaml` and run the playbook on each server, with a
   second session open. The mini needs nothing: chezmoi writes its whole
   `authorized_keys`. Then take the old keys off GitHub: under Settings → SSH
   and GPG keys, delete the authentication and signing keys whose
   fingerprints `ssh-keygen -lf ~/.ssh/arnor.pub` and
   `ssh-keygen -lf ~/.ssh/arnor_signing.pub` print, and any other key there
   you no longer use. Keep the new login and signing keys and the mini's
   signing key.
13. Delete the old checkout on each server once nothing there uses it. First,
   with a second session open, make `~/.ssh` (dor-lomin) and `~/.gnupg` (both)
   real folders with the loop under *Before the first run on dor-lomin and
   Rivendell*, and test a new login from another terminal. Never just remove
   those two links: on dor-lomin `~/.ssh` holds the only `authorized_keys`,
   and password login is off. Then `find ~ -maxdepth 3 -lname '*src/tilde*'`
   should list only links such as `~/btop.conf`, which you can remove. On
   Rivendell, also wait until the task *Stop Húrin writing into the old
   checkout* is done. Then `rm -rf ~/src/tilde`.

## Fonts

MonoLisa is licensed and never enters this repo, not even encrypted: the
EULA forbids sharing it in any way, and an encrypted blob in a public repo
still publishes it. Both Macs fetch it from the 1Password document "MonoLisa
fonts". To upgrade, change `version` and `family` in
`home/.chezmoidata/fonts.toml` and replace the document; the next apply
removes the old files, installs the new ones and renames the font in
Ghostty's config. On the mini, turn 1Password's CLI integration on for that
apply, run it from a terminal at the mini's own screen (Screen Sharing works,
SSH doesn't), then turn the integration off again. If the mini ever needs to
refresh fonts with nobody at it,
the licence-friendly route is a private repo pulled as a chezmoi external.

Libron comes from the `font-libron` cask.

## Port after the weekend

Done by hand on the mini first, from the guide, then brought in here:

- T3 Code, Codex, Hermes and t3-pstack's installers, as `run_once_` scripts
  for the mini.
- Whatever t3-pstack's installer wrote into the Claude Code and Codex
  configs: run `chezmoi diff` on the mini and capture it. Don't revert it.
  `~/.claude/settings.json` comes from `modify_settings.json`, so port the
  new keys into that template; `chezmoi add` on it would replace the
  template with a copy of the mini's file.
- `~/.config/t3-pstack/models.md` as a managed file.
- A `modify_` template for `~/.hermes/config.yaml` that merges only the
  `approvals`, `gateway.streaming`, `display` and `platforms.telegram.extra`
  blocks.
- A mini-only script that re-runs `hermes gateway install` when the PATH
  setup changes, since launchd keeps the PATH a service was installed with.
- Confirm that `gh auth setup-git` on the mini wrote
  `/opt/homebrew/bin/gh` in the credential helper lines; if it wrote another
  path, `chezmoi diff` shows it and `home/dot_gitconfig.tmpl` follows.

Checked after the mini's first Claude Code session:

- In Codex's settings (the account's, not a config file), turn off commit
  attribution, or Codex tells itself to add a `Co-authored-by: Codex` line
  that outranks `AGENTS.md`. Check that `~/.codex/AGENTS.override.md` doesn't
  exist: it would replace the rules for Codex.
- Before an agent's first push, its T3 thread shows `rules: mini <date>` on a
  line of its own, which says the rules file loaded.
- In T3, Settings → Storage → Automatic worktree cleanup: turn on cleanup on
  merge, so T3's own worktrees go the way this repo's do.
- `launchctl print gui/$(id -u)/com.carlosetejada.worktree-ttl` shows the
  cleanup job loaded. If `~/Library/Logs/worktree-ttl.stderr.log` or
  `~/Library/Logs/worktree-ttl/attention.txt` says `cannot read
  …/repositories: Operation not permitted`, the job stopped without judging
  anything: give `/bin/bash` access to the Dropbox folder in Privacy &
  Security.
- In T3, Settings → Providers: add a Claude instance named "Claude (attended)"
  with binary `claude`, no config folder of its own (it shares `~/.claude`),
  the environment variable `AGENT_ATTENDED=1`, and the launch arguments
  `--append-system-prompt-file /Users/ctejada/.claude/attended.md`. The
  default instance stays as it is.
- `claude plugin details superpowers@sp-gated` lists its skills and one
  SessionStart hook starting `[ "${SP_BOOTSTRAP:-0}" = 1 ]`; if the official
  superpowers was ever installed, `claude plugin uninstall superpowers@claude-plugins-official`.
- Three smoke tests in T3: on the default instance, ask for a small design
  with superpowers:brainstorming and see it write a spec and carry on without
  asking; on "Claude (attended)", type `/superpowers:brainstorming` and get an
  ask-for-input card; let one default run finish and see a draft PR with
  *Decisions for Carlos* at the top and no menu.

- `claude --version` is 2.1.296 or later, which fixed plugin session hooks
  being skipped in headless sessions.
- The first T3 transcript shows t3-pstack's and Ponytail's session text and
  no superpowers. If Ponytail's rules and poteto-mode pull in different
  directions, switch Ponytail off on the mini too.
- t3-pstack's thread count and spend in the first week of unattended runs:
  its issue #21 reports delegates nesting five levels deep.
- no-mistakes' global config (`~/.no-mistakes/config.yaml`): draft PRs, merge
  rather than rebase, no published intent or uploaded media, and a permission
  mode for Claude instead of skipping permissions. The keys are confirmed
  against the current docs but not yet against v1.84.0, so the file is written
  once the installed version accepts it.

## Tests

```sh
bash tests/run.sh
```

In a new clone or worktree, install the playbook's pinned collections first,
from `ansible/`: `uv run --locked ansible-galaxy collection install -r
requirements.yml`. They aren't committed, and `tests/ansible.sh` fails
without them rather than skip.

Everything runs in throwaway homes; no test reads 1Password, a key or a
server. It checks:

- no private key material, licensed font or 1Password-reading template is in
  the index (also the pre-commit hook, with gitleaks);
- every setup script, rendered for every role, parses and is shellcheck-clean;
- what each role gets and must never get;
- the Claude Code hooks: the Git and vault guards block what they must, even
  when they crash, and the risky-command hook's warnings reach the model;
- the server playbook parses, and ansible-lint finds nothing at its
  production profile (`ansible/.ansible-lint` skips two style rules and makes
  warnings fail too);
- applying twice changes nothing, `chezmoi diff` is empty and `chezmoi
  verify` exits 0;
- the new shell matches a recording of the old one: every key binding,
  option, alias, completion style and function, apart from a short list of
  deliberate changes, and starts without errors with no terminal, as agents
  start it.

On the mini, where this repo is edited, the apply turns the hook on. In any
other clone: `git config core.hooksPath .githooks`.

CI (`.github/workflows/tests.yml`) runs these on `ubuntu-24.04` on every push
and pull request, after a gitleaks scan of the whole history, and weekly on
`macos-26`, which can also be started by hand from the Actions tab. GitHub has
no macOS 27 runner yet, so the Mac job tests one version behind the laptop.
On Ubuntu the Mac-only tests exit early, and the roles are `ci` and `server`.

Two more run only there, because they change the machine they run on:

- `tests/server-playbook.sh`, on every push and pull request, runs the server
  playbook for real on a second Ubuntu runner, as a server called
  `ci-runner` that no list here names. A run the device-key guard must stop
  comes first, and ones a device key or a retired login key cut short must
  stop, then a `--check`, then two runs: the guard must let the first through
  with password login still on, and the first must turn it off and take out a
  retired login key; the second must change nothing. Then it checks sshd, UFW,
  that `/tmp` stays as it was until the next boot even when a service with
  PrivateTmp starts, and `authorized_keys`, logs in with a stand-in device
  key, and checks that a login without a key is turned down.
- `tests/macos-ci.sh`, in the weekly Mac job, checks that every formula and
  cask the Brewfile lists for each Mac still exists in Homebrew (trusting
  first what the Brewfile marks `trusted: true`, as `brew bundle` does),
  installs a few, then applies both Macs' settings for real and expects a dry
  run right after to find nothing to change and a second apply to print
  nothing. A setting the apply skips fails the job. A power setting the
  runner doesn't have, such as a battery one, has nothing to set; the log
  lists it. On the runner it first adds a throwaway SSH key and a stand-in
  iCloud Drive folder, so the mini's key-only SSH and the screenshots folder
  are checked too. Run a second time on
  the same machine, it passes again, but each role's apply changes the two
  settings the laptop and the mini set the other way round: automatic macOS
  updates and the automatic time zone.

Each refuses to run anywhere else unless told it's on a throwaway machine
(`DOTFILES_HARDEN_THIS_MACHINE=yes` or `DOTFILES_CHANGE_THIS_MAC=yes`).
