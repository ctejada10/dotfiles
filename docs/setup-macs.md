# Setting up a personal Mac

The personal Macs are the laptop, arnor, a MacBook Pro with the `laptop` role,
and later a Mac Studio, for which the name `gondor` is kept. The laptop is for
personal work and job hunting. All development happens on
[the mini](setup-mini.md), so the laptop has no development plugins or skills.
It is the only machine with 1Password's SSH agent and Ansible.

The other guides: [the mini](setup-mini.md) and [servers](setup-servers.md).
Back to the [README](../README.md).

Until the [cutover](#cutting-arnor-over-from-the-old-tilde), the old tilde is
still the live setup on arnor, and nothing here has been applied to it.

## Before the one-liner

1. Install the Xcode command line tools: `xcode-select --install`.
2. Install 1Password and sign in. Under Settings → Developer, turn on
   **Integrate with 1Password CLI** and **Use the SSH agent**. When it asks how
   to show your keys, choose **Use Key Names**: it stores only the items'
   titles, "SSH login key" and "SSH signing key", and its approval prompt then
   names the key it's about to use, so you can tell a login from a commit
   signature. Keep 1Password open and unlocked from here on. Check that the
   agent is running:

   ```sh
   export SSH_AUTH_SOCK=~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock
   ssh-add -l
   ```

   It lists "SSH login key" and "SSH signing key". `Error connecting to agent`
   means **Use the SSH agent** is off or 1Password is closed.
3. Put both keys on GitHub, once per key: the apply clones the private
   `scripts` over SSH, and GitHub refuses a key it doesn't have. Check which
   are there already by comparing `curl -fsS https://github.com/ctejada10.keys | ssh-keygen -lf -`
   with `ssh-add -l`; that list holds login keys only. For each one missing,
   copy it with `ssh-add -L | grep 'SSH login key' | pbcopy` (or
   `'SSH signing key'`), then on GitHub go to Settings → SSH and GPG keys →
   New SSH key, title it `arnor`, and choose **Authentication Key** for the
   login key and **Signing Key** for the signing key. In the same shell,
   `ssh -T git@github.com` then greets you by name.
4. Sign in to the App Store, so the Mac App Store apps can install.

## The one-liner

```sh
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin" init --apply ctejada10
```

It asks three questions: the role (`laptop`), the name (lowercase letters,
digits and hyphens, 15 characters at most) and the display name (what Find My
and AirDrop show; capitals, spaces and accents are fine). It asks for your
password to rename the Mac and set the power settings, and Homebrew asks again
for the casks that install a package, such as Tailscale. The App Store apps
install last, and only when you run it at the Mac's own screen with the App
Store signed in (mas may ask for the password too). Telling whether it is
signed in needs Full Disk Access, which Terminal doesn't have, so on a new Mac
every apply says they wait until
`brew bundle --file=~/.local/share/chezmoi/Brewfile` installs them, once you've
signed in. Any other entry that didn't install, such as a cask whose download
failed, is tried again by the next apply.

A second `chezmoi apply` changes nothing, `chezmoi diff` is empty and
`chezmoi verify` exits 0.

## After the first apply

**Dropbox.** On a wiped Mac, Dropbox is installed during that first apply, so
anything that lives in Dropbox waits for it: sign in to Dropbox, let it finish,
then run `chezmoi apply` once more. That second apply turns `~/.config` into
the link into Dropbox ([`~/.config`](#config) says how) and writes 1Password's
`agent.toml` into `config-files`. The
repos don't wait for Dropbox: the first apply already cloned them into `~/src`
from GitHub.

**Time zone.** The laptop's time zone follows its location. That needs System
Settings → Privacy & Security → Location Services → System Services → Setting
time zone turned on, which no script can do.

**Tailscale.** Open it, allow its system extension and VPN configuration, and
sign in. After a clean install the laptop is a new machine on the tailnet with
a new address, and the old install still holds the name `arnor`, so Tailscale
calls the new one `arnor-1`. In the admin console, under Machines, remove the
old `arnor`, the one shown offline, then run `chezmoi apply`: it renames the
new one to `arnor`, and says so while the old one is still there. Then update
the Tailscale policy as the
[mini's guide](setup-mini.md#the-tailscale-admin-console) says.

**First launches.** The first time you open Ghostty, or any other app the
Brewfile installed, macOS asks whether to open an app downloaded from the
internet: open it.

**1Password in each terminal.** On macOS 27, a terminal can't reach the
1Password app until you allow it, and until then `op` says "No accounts
configured for use with 1Password CLI" even with the CLI integration on. The
first time a terminal runs `op`, macOS asks whether it may use data shared by
1Password: allow it. If that was declined, or never asked, turn it on under
System Settings → Privacy & Security → Files & Folders → Ghostty, in the entry
that starts with "Data shared by 1Password", then quit and reopen Ghostty. Each
terminal needs its own: Terminal for the one-liner, Ghostty after it.

**A name still in use.** A new Mac given the name of one still on the network,
as a new laptop is while the old arnor is on, can't have it on the network:
macOS calls it `arnor-2` there (Bonjour, `arnor.local`, and SMB). The apply says
so and leaves it; once the old one is off or renamed, `chezmoi apply` sets the
name.

**Checks.** `ssh -T git@github.com` and `ssh amon-sul true` work through
1Password's agent, `~/src/scripts` exists, and a new commit shows `G` in
`git log --format=%G? -1`.

## Reaching the mini and the servers

The laptop's SSH config comes from `home/.chezmoidata/hosts.yaml`, so every
machine there answers by name:

- `ssh amon-sul` reaches the mini over the tailnet. At home,
  `ssh ctejada@amon-sul.local` gets there without Tailscale, so a Tailscale
  outage doesn't lock you out.
- `open vnc://amon-sul` opens Screen Sharing. Sign in with the mini's macOS
  account name and password, not a separate VNC password.
- `ssh dor-lomin`, `ssh rivendell` and `ssh esgaroth` reach the servers, on the
  ports `hosts.yaml` lists. esgaroth has no public address and answers over the
  tailnet only.

1Password asks you to approve the login key the first time each app uses it,
and again after it locks.

## T3 Code and Hermes from the laptop

**T3 Code.** The Brewfile installs the desktop app. Open it and sign in to T3
Connect with the account the mini uses: the mini shows up on its own. Then,
under Settings → Environments, turn off **Local environment**, so no agent ever
runs on the laptop; the app then works as a remote only. Once connected, it
also learns the mini's home-network and Tailscale addresses as routes and uses
the fastest one that answers, so at home it skips the relay. When T3 updates,
update the mini and the apps together; a newer server refuses an older app.

**Hermes.** You talk to Hermes, the mini's assistant, through its Telegram
bot, Bree. The Brewfile installs Beeper: under Settings → Accounts, add
Telegram as an **on-device** connection, so the chats stay off Beeper's
servers. Beeper doesn't show Telegram's approval buttons; type `/approve` or
`/deny` instead.

## Repos

Each Mac clones its own repos from GitHub into a real `~/src`, once, when
they're missing; the lists are in `home/.chezmoidata/repos.yaml`. On the laptop
that's ai-job-search, `cv`, and `scripts`, which Raycast and Hazel run;
career-ops is a Claude Code plugin instead.
Work moves between the Macs through GitHub, not Dropbox, and nothing pulls the
clones for you. Dropbox's `repositories` folder is the repos' old home: it
keeps the ones no Mac clones, such as the research code, the thesis and the
talks, as they were.

Of the repos the mini's agents work in, the laptop clones only `scripts`, and
only to run it: develop it on the mini, and `git pull` here to update. Set it
up as its README says (pre-commit, `uv run scripts secrets pull`, then
`uv tool install --editable .`), and point Raycast's script commands at
`~/src/scripts/interfaces/raycast` and Hazel's rules at
`~/src/scripts/interfaces/hazel`. The bare `scripts` command exists only once
`uv tool install` has put it in `~/.local/bin`; until then every Raycast
command fails with `~/.local/bin/scripts: No such file or directory`. The
pull needs [1Password in the terminal](#after-the-first-apply) allowed first.
`scripts doctor` then shows `secrets readable  yes`. Read the other repos on
GitHub, or on the mini through T3.

### `~/.config`

On the laptop `~/.config` links to Dropbox's `config-files` too, so gh, op,
rclone, Raycast and the rest keep syncing their settings as they always have.
chezmoi keeps its own config and state there too, in `config-files/chezmoi`.
The link is made only once Dropbox has brought `config-files` down. Until
then, and on a wiped laptop, `init` writes a real `~/.config/chezmoi`, and the
first apply after Dropbox has synced empties that folder and makes the link
itself, before anything else. `~/.config/chezmoi` moves into `config-files`,
and any `chezmoi` folder an earlier install left there goes to the Trash (its
state would stop setup scripts from running again). A folder `config-files`
already has, such as `gh` after you logged in to gh, keeps the synced copy,
and the one from this install goes to the Trash. `op` holding only the socket
the first apply's 1Password check made is removed, and anything else moves
into `config-files`. If a move fails, the apply stops and says what's left.
The preflight also stops the apply while
`~/src` is still a link into Dropbox from before the repos moved out;
`unlink ~/src` removes just the link, never what it points to.

This repo writes nothing inside that link except 1Password's `agent.toml`,
which has to live there. Its own files sit outside it: the shell in `~/.zsh`,
and Ghostty's config in `~/Library/Application Support/com.mitchellh.ghostty`.
The personal age key is on no Mac at all (see
[Re-sealing secrets](setup-servers.md#re-sealing-secrets)).

### Job-search tools and cv

career-ops is a Claude Code plugin, not a clone: run `/career-ops:career-ops`
from any folder. Its CV, profile, tracker and reports live in
`~/.local/share/career-ops`, which `CAREER_OPS_ROOT` in Claude Code's settings
names, and plugin updates never touch them. ai-job-search and `cv` are cloned
into `~/src`. ai-job-search's setup writes your profile into files Git tracks:
commit them on its own branch, and take its releases by merging them, as its
`SETUP.md` says. It can never push: its push URL goes nowhere and a pre-push
hook refuses. `cv`'s applications live in git-ignored folders of its
checkout.

First use:
- **career-ops:** run `/career-ops:career-ops` in any session; its onboarding
  asks about you and writes everything into its data folder. It scans
  portals and checks postings through Playwright's plugin, which the laptop
  enables too. Its PDFs need Chromium, which the plugin doesn't download:
  after its first session, run `npx playwright install chromium` in its
  plugin folder, `~/.claude/plugins/cache/career-ops/career-ops/<version>`,
  where `node doctor.mjs` lists anything else missing.
- **ai-job-search:** the apply installs its portal tools with Bun, and
  MacTeX, Bun and Poppler come from the Brewfile. Run `claude` in
  `~/src/ai-job-search`, trust the folder, run `/setup` once, and commit what
  it writes.

`home/.chezmoidata/personal.yaml` lists all three. Every Sunday at 03:47
`~/.local/bin/personal-backup` archives their personal files: career-ops'
data folder, and each clone's untracked and ignored files, edits, and
commits on no remote. It encrypts the archive to the personal age key's
public half, writes it to `backups/personal/<date>.tar.age` in Dropbox and
keeps the newest eight; a week with no change writes nothing. Only the
private half, which is only in 1Password, opens them. The mini syncs
`backups` for its own snapshots but not `backups/personal`
([its Dropbox steps](setup-mini.md#3-dropbox-and-the-repos)): a restore takes the newest archive it
finds, so only the laptop may write one. A restore also refuses an archive
that holds anything a backup never writes, or that is dated in the future. Its report is `~/Library/Logs/personal-backup/attention.txt`. Like
the mini's snapshot job it writes into Dropbox from launchd, so `/bin/bash`
needs Full Disk Access: System Settings → Privacy & Security → **Full Disk
Access** → **+**, Cmd-Shift-G, `/bin/bash`.

The first apply on a fresh laptop restores them from the newest archive, into
a clone that apply made and a data folder that isn't there yet. It asks
1Password once for the private half, which never touches the disk. If Dropbox
hasn't synced `backups/personal` yet, or 1Password's CLI isn't set up, the
apply says so; run `personal-backup restore` once it is. A restore never
overwrites: it skips a clone that already has local files and a data folder
that isn't empty.

## Claude Code on the laptop

Each role's plugins are declared in `home/dot_claude/modify_settings.json`;
Claude Code downloads them in the background once a session has started, so
`claude plugin list` shows nothing until then. The laptop gets career-ops
(the job-search pipeline; its session hook installs its Node packages),
Playwright's browser tools (which career-ops scans with), freehire
(read-only job search), humanizer (for cover letters) and Obsidian's
skills,
plus your own skills and rules: email replies, Todoist triage, the vault
researcher and `rules/job-search.md`. Claude Code's own commit attribution is
switched off on every Mac.

**Once, after the cutover:** run the "About Me" pass from the one-weekend setup
roadmap. Ask Claude to interview you, four questions at a time, about how you
work. It proposes each preference it finds as one item for `CLAUDE.md` or a
rules file here; personal answers go to a note you name, never this public
repo.

## Fonts

MonoLisa is licensed and never enters this repo, not even encrypted: the
EULA forbids sharing it in any way, and an encrypted blob in a public repo
still publishes it. Both Macs fetch it from the 1Password document "MonoLisa
fonts". To upgrade, change `version` and `family` in
`home/.chezmoidata/fonts.toml` and replace the document; the next apply
removes the old files, installs the new ones and renames the font in
Ghostty's config. The mini needs 1Password's CLI integration on for that apply
(see [its guide](setup-mini.md#fonts-on-the-mini)).

Libron comes from the `font-libron` cask.

## Renaming a Mac

Run `chezmoi init --prompt` on it, give the new name, then `chezmoi apply`. On
a Mac that sets all four macOS names (ComputerName, LocalHostName, HostName,
NetBIOSName) and Tailscale's. Then check by hand:

- the machine's name in T3 Connect;
- Obsidian Sync's device name (it lives in `.obsidian`, which nothing here
  touches);
- the old name's lines in `~/.ssh/known_hosts` on other machines.

## Cutting arnor over from the old tilde

A preflight script refuses any apply while `~/.ssh` is a link, and refuses to
replace the old tilde's links unless `DOTFILES_CUTOVER=1` is set. `~/.config`
stays as it is: it already links to Dropbox. `~/src` doesn't: the preflight
also refuses while it links into Dropbox, so step 7 replaces it with a real
folder of fresh clones.

1. Check that the old tilde is gone from GitHub: `gh api repos/ctejada10/tilde`
   says `Not Found (HTTP 404)`.
2. Finish the task *Close what's exposed in the old tilde*: `~/.ssh` is a real
   folder.
3. Create the new login and signing keys in 1Password and put their public
   halves in `home/.chezmoidata/keys.yaml`. Register both with GitHub. (Done on
   25 Oct 2026.)
4. Make the first personal backup, from the old checkouts in Dropbox's
   `repositories` folder, which `~/src` still links to. With this repo's clone
   in `~/.local/share/chezmoi` on `main` and pulled:
   `bash ~/.local/share/chezmoi/home/dot_local/bin/executable_personal-backup --root ~/src --repos "career-ops ai-job-search cv" --data "" --recipient age1fkegjycfqp4ktjn5zrzv2mjj04rxexnmsh7rmwvg09hs0cumy5cs0a75pn`.
   It writes `backups/personal/<date>.tar.age`, and its report,
   `~/Library/Logs/personal-backup/attention.txt`, says `0 item(s) need a
   person`. On the mini, untick `backups/personal` in Dropbox's sync
   settings ([step 4 there](setup-mini.md#3-dropbox-and-the-repos)). Commit and push any work still
   open in cv.
5. `chezmoi init ctejada10`, answering `laptop`, `arnor`, and the display name.
6. Read what the apply would change. `chezmoi diff` shows the files; it leaves
   out the setup scripts, which run on every apply. For the macOS settings,
   `DOTFILES_CHECK=1 bash <(chezmoi execute-template < ~/.local/share/chezmoi/home/.chezmoiscripts/run_after_30-macos-settings.sh.tmpl)`
   prints each one it would change and writes nothing. For packages,
   `HOMEBREW_TILDE_ROLE=laptop brew bundle check --no-upgrade --verbose --file=~/.local/share/chezmoi/Brewfile`
   lists what it would install.
7. `unlink ~/src && DOTFILES_CUTOVER=1 chezmoi apply`. `unlink` removes only
   the link, never the Dropbox folder it points to. The apply clones
   ai-job-search, cv and scripts into a new `~/src` and restores step 4's
   archive: ai-job-search's and cv's files into their clones, and career-ops'
   into `~/.local/share/career-ops`, where the plugin reads them. 1Password
   asks once for the personal age key. Then commit ai-job-search's profile on
   its own branch: `git -C ~/src/ai-job-search commit -am "My profile"`.
   `~/Repositories` still links to the old folder; remove it with
   `unlink ~/Repositories` once nothing uses it.
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
    new key logs in to each server, see which keys still log in there and
    from where:
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
    real folders with the loop in
    [Before the first run on dor-lomin and Rivendell](setup-servers.md#before-the-first-run-on-dor-lomin-and-rivendell),
    and test a new login from another terminal. Never just remove those two
    links: on dor-lomin `~/.ssh` holds the only `authorized_keys`, and
    password login is off. Then `find ~ -maxdepth 3 -lname '*src/tilde*'`
    should list only links such as `~/btop.conf`, which you can remove. On
    Rivendell, also wait until the task *Stop Húrin writing into the old
    checkout* is done. Then `rm -rf ~/src/tilde`.

**A clean install instead.** Before wiping, do step 4 and let Dropbox finish
uploading `backups/personal`. The first apply on the wiped laptop restores
the personal files from it, as in step 7, once Dropbox and 1Password are set
up; if either isn't yet, it says so, and `personal-backup restore` does it
later. Then commit ai-job-search's profile as step 7 says. Note the fingerprints step 12 needs (`ssh-keygen -lf ~/.ssh/arnor.pub`
and `ssh-keygen -lf ~/.ssh/arnor_signing.pub`), since the wipe takes those
files. Then set the laptop up from the top of this guide, as a wiped Mac, and
do steps 9, 12 and 13 afterwards. Steps 6 to 8, 10 and 11 clean up an old
install and don't apply.
