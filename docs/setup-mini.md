# Setting up the mini

The mini is amon-sul ("Amon Sûl"), a Mac mini at home with the `agent-mini`
role. It runs the agents with nobody watching:

- **Coding happens in T3 Code.** Claude Code plans and reviews, Codex writes
  the code, and t3-pstack routes the work between them. The same threads show
  on the iPhone, the iPad and the laptop, and a push notification says when a
  turn finishes.
- **Everything else goes through Hermes**, an assistant you reach through its
  Telegram bot, Bree, read in Beeper. It reads Gmail, adds calendar events,
  keeps Todoist and Monarch, edits the vault and sends scheduled briefs.
- **It all runs on your subscriptions:** Claude Code on your Claude account,
  Codex and Hermes on ChatGPT. There is no Anthropic API key on the mini.

Once set up, it has no screen or keyboard. You reach it from the laptop over
SSH and Screen Sharing, from Blink on the iPhone and iPad over Tailscale, from
every device through T3, and through Telegram.

This guide merges the October 2026 *Mac mini Setup Guide* with what this repo
does, corrected for everything that didn't match when amon-sul was set up on
27 Oct 2026. Fixes still owed in the code are in
[ctejada10/dotfiles#3](https://github.com/ctejada10/dotfiles/issues/3). The
other guides: [servers](setup-servers.md) and [personal Macs](setup-macs.md).
Back to the [README](../README.md).

**Have on hand:** the mini's keyboard, mouse and a screen for the first day;
1Password unlocked on your phone; logins for your Claude account, ChatGPT,
GitHub, Dropbox, Tailscale, Telegram, Google Workspace, Todoist, Monarch and
Obsidian Sync; T3 Code, Telegram, Tailscale and Blink on the iPhone, and T3
Code, Tailscale and Blink on the iPad.
Optional: a dummy HDMI plug for Screen Sharing without a display, and an
Ethernet cable, steadier than Wi-Fi for a machine that's always on.

Claude Code runs on your work Claude account, so confirm with work that you
can use it for personal projects on a home machine.

## 1. Bootstrap

In this order:

1. Xcode command line tools: `xcode-select --install`.
2. Homebrew, then the lines it prints under *Next steps*, so `brew` is on your
   PATH for step 4. The apply replaces that `~/.zprofile` with its own.
3. 1Password, signed in, with CLI integration on. This is only for the first,
   attended setup: it fetches MonoLisa.
4. `brew install gh && gh auth login` (HTTPS). Git on the mini goes through
   `gh`, never through 1Password. If the browser step asks to grant access to
   the cad-accessibility organisation, grant it, or its repos won't clone.
5. The one-liner, answering `agent-mini`, `amon-sul` and `Amon Sûl`:

   ```sh
   sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin" init --apply ctejada10
   ```

   Near the end it clones the mini's repos from GitHub into `~/src`. A clone
   that fails is named, and the next apply tries it again.

Then check:

- `op whoami`
- `chezmoi verify`
- `gh --version && git lfs version`
- `gh auth status` and `git ls-remote https://github.com/ctejada10/dotfiles`.
  The mini's Git doesn't use SSH, so `ssh -T git@github.com` doesn't apply.
- `git ls-remote https://github.com/cad-accessibility/cad-a11y`
- `ls ~/.claude`
- `sudo systemsetup -gettimezone` shows America/New_York
- `node --version` is v20 or later
- `~/.ssh/mini_signing.pub` exists (the apply makes it) and is on GitHub as a
  signing key. `gh auth login` doesn't grant the scope that takes, so this
  asks for it for one step and drops it again. Each `gh auth refresh` shows a
  code to enter at github.com/login/device:

  ```sh
  gh auth refresh -h github.com -s write:ssh_signing_key && gh ssh-key add ~/.ssh/mini_signing.pub --type signing --title amon-sul; gh auth refresh -h github.com -r write:ssh_signing_key
  ```

Once they pass and `ls ~/Library/Fonts/MonoLisa*` shows the font, turn off
1Password's CLI integration and its SSH agent on the mini. 1Password there can
open the whole Private vault, and the mini runs agents nobody is watching.

## 2. macOS for an always-on Mac

The goal is a Mac that comes back on its own, logged in, after a power cut, a
restart or an update.

### FileVault off, automatic login on

T3's service and Hermes's gateway start when your account logs in, and macOS
allows automatic login only with FileVault off. Start this first, since
decryption runs in the background.

1. `fdesetup status`. If it says `FileVault is Off.`, skip to step 4.
2. System Settings → Privacy & Security → FileVault → **Turn Off…**, and enter
   your password.
3. Run `fdesetup status` again until it says exactly `FileVault is Off.`, with
   no mention of deferred enablement.
4. System Settings → Users & Groups → **Automatically log in as** → your
   account, and enter your password. If it's dimmed, FileVault is still
   decrypting, or your account logs in with your Apple Account password and
   needs one of its own.
5. `defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser`
   prints `ctejada`.

The trade-off is a disk that isn't encrypted at rest. Keep the mini somewhere
safe at home; its keys and logins can be revoked from the services if it's
ever stolen.

### Power, lock screen and updates

- **Power:** the apply sets it. `pmset -g` shows `sleep 0` and
  `autorestart 1`: no system or disk sleep, a restart after a power failure,
  and waking for network access.
- **Lock screen:** keep **Require password after screen saver begins or display
  is turned off** on. Background services keep running while the screen is
  locked.
- **Updates:** `defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates`
  should print `0`. If it prints `1`: System Settings → General → Software
  Update → **ⓘ** next to Automatic Updates, turn off **Install macOS
  updates**, and leave **Download new updates when available** and **Install
  Security Responses and system files** on. A surprise restart interrupts
  agents, so install macOS updates yourself once a month, and check this
  again after each one: that's when it tends to come back. Without device
  management the setting may not stick.

### Remote Login and Screen Sharing

The apply turns both on, for your account only. Screen Sharing needs one more
step by hand: the apply starts it from the command line, which opens port
5900, but since macOS 12.1 only System Settings can give it permission to show
the screen, so every connection fails with "Screen Sharing is not permitted"
(#3).

1. System Settings → General → Sharing: turn **Screen Sharing** off, then on.
2. Open its **ⓘ**. **Allow access for** stays only you, as the apply set it,
   and turn off **Anyone may request permission to control screen** and **VNC
   viewers may control screen with password**. The apply can't reach these
   two.
3. To check, this lists the login types the mini offers; a `2` means a VNC
   password still works:

   ```sh
   perl -MIO::Socket::INET -e '$s=IO::Socket::INET->new(PeerAddr=>"127.0.0.1",PeerPort=>5900,Timeout=>3) or die "Screen Sharing does not answer\n"; $s->sysread($v,12); $s->syswrite("RFB 003.008\n"); $s->sysread($n,1); $n=ord $n; $s->sysread($t,$n); print "login types: ", join(" ", unpack("C*",$t)), "\n"'
   ```

Later applies leave Screen Sharing alone: they act only when port 5900 doesn't
answer. If the apply ever said it couldn't turn Remote Login on, turn it on in
the same pane and run the apply again.

### Tailscale

1. Open `/Applications/Tailscale.app`, which the apply installed.
2. Approve its system extension. If macOS sends you to System Settings, the
   switch is under General → Login Items & Extensions → Network Extensions.
3. **Allow** its VPN configuration, then **Log in** from the menu bar icon,
   with the same account as the laptop.
4. `/Applications/Tailscale.app/Contents/MacOS/Tailscale status` lists the
   mini and the laptop.

Tailscale carries SSH and Screen Sharing from the laptop, and SSH from Blink on
the iPhone and iPad ([SSH from the iPhone and iPad](#ssh-from-the-iphone-and-ipad)).
T3 and Hermes don't need it: the devices reach T3 through T3 Connect and Hermes
through Telegram.

### Key-only SSH: the next apply

Once Remote Login and Tailscale are on, run `chezmoi apply` at the mini's own
screen (Screen Sharing counts; SSH doesn't). SSH turns key-only only once
Remote Login is on, and only in an apply that can ask for sudo. It writes
`/etc/ssh/sshd_config.d/010-dotfiles-keyonly.conf` and checks that the running
sshd offers public keys alone. With Tailscale signed in, it also sets the
mini's tailnet name to `amon-sul`.

### Check from the laptop

This runs four tests through 1Password's SSH agent, which approves the login
key:

```sh
A=~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock; echo "1. no key:"; ssh -o PubkeyAuthentication=no -o ConnectTimeout=5 amon-sul true 2>&1 | tail -1; echo "2. key, over Tailscale:"; SSH_AUTH_SOCK="$A" ssh -o ConnectTimeout=5 amon-sul 'echo "$(hostname -s) as $(whoami)"' 2>&1 | tail -1; echo "3. key, over the home network:"; SSH_AUTH_SOCK="$A" ssh -o ConnectTimeout=5 ctejada@amon-sul.local 'echo "$(hostname -s) as $(whoami)"' 2>&1 | tail -1; echo "4. root:"; ssh -o ConnectTimeout=5 -o BatchMode=yes root@amon-sul true 2>&1 | tail -1
```

1 and 4 print `Permission denied (publickey).`; 2 and 3 print `amon-sul as
ctejada`. Test 3 shows SSH still works at home if Tailscale is down. Once the
laptop runs this repo, plain `ssh amon-sul` uses the agent by itself.

Then `open vnc://amon-sul`, and sign in with the mini's macOS account name and
password: it opens onto the mini's desktop.

**Prove it restarts on its own.** Choose Apple menu → Restart on the mini,
close the window, and wait about three minutes. Then run test 2 again and
`open vnc://amon-sul`. Test 2 needs Tailscale, which only starts once the mini
has logged itself in, so if both work, the mini came back with nobody touching
it.

### SSH from the iPhone and iPad

Blink Shell on each device holds a key of its own, and the mini's
`authorized_keys` already has both (see
[Phones and tablets](setup-servers.md#phones-and-tablets)). With Tailscale on
the devices, `ssh amon-sul` works from anywhere.

1. **The mini's name on the tailnet.** On the mini:

   ```sh
   ts=/Applications/Tailscale.app/Contents/MacOS/Tailscale; $ts status --json | plutil -extract Self.DNSName raw -o - - | sed 's/\.$//'; $ts ip -4
   ```

   The first line is its full name, `amon-sul.<tailnet>.ts.net`, and the
   second its tailnet address. The tailnet's name stays out of this public
   repo.
2. **Tailscale on each device.** Install Tailscale from the App Store, sign in
   with the same account as the Macs, and allow its VPN configuration. Turn on
   VPN On Demand in its settings, so it reconnects on its own.
3. **The host in Blink.** Type `config`, then Hosts, then +: **Host**
   `amon-sul`, **HostName** the full name from step 1, **User** `ctejada`,
   **Port** 22, and **Key** the device's own key. Save.
4. With Wi-Fi off, over cellular, `ssh amon-sul` logs straight in.

If Tailscale is ever down at home, a second Blink host with **HostName**
`amon-sul.local` and the same key still gets in over the home network.

### The router

The router is a hand check, kept as a Todoist task. In August 2026 attackers
got into Macs whose port 5900 was open to the internet (CVE-2026-65400)
without valid credentials.

1. Find the connection the mini really uses and its address. On a Thunderbolt
   dock, wired Ethernet isn't `en0`:

   ```sh
   i=$(route -n get default | awk '/interface:/{print $2}'); echo "$i $(ipconfig getifaddr "$i")"; networksetup -listallhardwareports | grep -B1 "Device: $i$"
   ```

2. In the router's admin page, no port forwarding, virtual server or DMZ entry
   points at that address.
3. Turn off **UPnP**, and NAT-PMP if it's listed. From the mini, this asks the
   network for a UPnP router and should print `no UPnP answer`:

   ```sh
   perl -MIO::Socket::INET -MSocket -e '$s=IO::Socket::INET->new(Proto=>"udp",LocalPort=>0) or die; $s->send(join("\r\n","M-SEARCH * HTTP/1.1","HOST: 239.255.255.250:1900","MAN: \"ssdp:discover\"","MX: 2","ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1","",""),0,sockaddr_in(1900,inet_aton("239.255.255.250"))) or die "could not send\n"; $r=""; vec($r,fileno($s),1)=1; if (select($o=$r,undef,undef,3)) { $s->recv($b,1500); print "a router answered UPnP:\n$b" } else { print "no UPnP answer\n" }'
   ```

4. In the router's IPv6 settings, turn on its IPv6 firewall, or "block
   unsolicited inbound" (names vary).
5. From outside your home, for example from dor-lómin: `curl -s
   https://api.ipify.org` on the mini gives your public address, and
   `nc -z -w 5 <address> 22` and `nc -z -w 5 <address> 5900` from the server
   must both fail. For IPv6, use the mini's public `inet6` addresses (the ones
   not starting `fe80`) with `-6`.

### The Tailscale admin console

1. **Key expiry:** Machines → **⋯** next to amon-sul → **Disable key expiry**,
   or the mini drops off the tailnet when its key expires (180 days by
   default).
2. **The policy:** replace the default, which lets every device reach every
   port on every other, with grants by machine. Your account owns both Macs,
   so a grant by user would make the mini a source too. Do it after the
   laptop's clean install, since the laptop then has a new tailnet address.
   Before saving, note and test what the laptop reaches today:

   ```json
   {
     "hosts": {
       "arnor": "100.x.x.x",
       "iphone": "100.x.x.x",
       "ipad": "100.x.x.x",
       "amon-sul": "100.x.x.x",
       "esgaroth": "100.x.x.x",
       "rivendell": "100.x.x.x"
     },
     "grants": [
       {"src": ["arnor"], "dst": ["amon-sul"], "ip": ["tcp:22", "tcp:5900", "udp:5900-5902"]},
       {"src": ["iphone", "ipad"], "dst": ["amon-sul"], "ip": ["tcp:22"]},
       {"src": ["arnor", "iphone", "ipad"], "dst": ["esgaroth"], "ip": ["tcp:22"]},
       {"src": ["arnor"], "dst": ["rivendell"], "ip": ["tcp:445"]}
     ]
   }
   ```

   Take each address from the Machines page. Drop the Rivendell grant if you
   don't mount its Samba share from the laptop, and the devices' esgaroth
   grant if you never log in there from Blink. Nothing lists amon-sul as a
   source. The iPhone and iPad keep their key expiry on: they ask you to sign
   in again now and then. After saving, test each connection from the laptop again; from the
   mini, `nc -z -G 3 esgaroth 22` should now fail.

## 3. Dropbox and the repos

The repos don't live in Dropbox. The apply clones the mini's seven repos from
GitHub into a real `~/src` (the `agent-mini` list in
`home/.chezmoidata/repos.yaml`), and work reaches the laptop through GitHub.
Nothing pulls those clones: agents branch from `origin/HEAD` in worktrees, and
FirstMate fast-forwards a clone once a PR merges.

Dropbox on the mini holds only the repos' weekly snapshots, in `backups`. Sign
in to Dropbox; on the mini it runs in File Provider mode, so files arrive as
online-only placeholders. Then sync that one folder:

1. Dropbox icon in the menu bar → your avatar → **Preferences** → **Sync**.
   Under "Select folders to sync to this Mac", click **Modify**.
2. Tick **backups** and nothing else, and click **Update**. Leave
   **repositories** unticked: it's the repos' old home, synced with the
   laptop, and it holds the old `tilde` checkout with arnor's old SSH private
   keys. Never open `tilde` on the mini.
3. `ls ~/Library/CloudStorage/Dropbox` shows `backups` and no `repositories`.
4. Once the laptop has made its first personal backup, which creates
   `backups/personal`, come back here, open **backups** and untick
   **personal**. Those are the laptop's encrypted archives, and the laptop
   restores the newest one it finds there, so nothing on the mini may be able
   to add one. Dropbox syncs a new subfolder by default, so it takes this
   untick; `ls ~/Library/CloudStorage/Dropbox/backups` then shows no
   `personal`.

### The snapshot job's access

A LaunchAgent runs `~/.local/bin/repo-snapshots` every Sunday at 03:47. For
each repo in `~/src` whose branches changed since its last snapshot, it writes
a `git bundle` of every branch into `backups/repositories/snapshots/<repo>/`
in Dropbox, and keeps the newest four. Only bundles: no `.env` or other
untracked file goes in. macOS refuses a background job into Dropbox's folder
without asking, as it refused the cleanup job when the repos were there (#3),
and the only grant that works is Full Disk Access for `/bin/bash` (Files &
Folders lists no entry for it). The cleanup job itself only reads `~/src` now.

1. System Settings → Privacy & Security → **Full Disk Access** → **+**, press
   Cmd-Shift-G, type `/bin/bash`, **Open**, and make sure its switch is on.
   That lets any bash script the system starts read your files. On the mini,
   that's only this job and the cleanup job: commands agents run in T3 count
   as T3's, and SSH sessions as Remote Login's.
2. Run it now and read its report:

   ```sh
   launchctl kickstart gui/$(id -u)/com.carlosetejada.repo-snapshots && sleep 5 && while [ -d ~/Library/Logs/repo-snapshots/run.lock ]; do sleep 5; done && cat ~/Library/Logs/repo-snapshots/attention.txt
   ```

   A good run prints one line, ending `repo-snapshots: 0 item(s) need a
   person`. Each line after it names a path and what to do about it.

### Other privacy prompts

Don't give Terminal or Ghostty Full Disk Access on the mini: nothing in the
setup needs it, and the agents run commands there. Allow the other prompts as
they appear while you're at the screen: T3, Obsidian, and Hermes, which shows
up as python asking for the Documents folder once it reads the vault. If a T3
agent can't open a folder, the repo is outside `~/src`: move it rather than
giving `t3` Full Disk Access.

## 4. Accounts and command-line tools

### Claude Code

The apply installs it.

- `claude --version` is 2.1.296 or later, which fixed plugin session hooks
  being skipped in headless sessions.
- `claude auth login`, and sign in with your work Claude account.
- `claude doctor` reports a healthy install.

### Codex

- `curl -fsSL https://chatgpt.com/codex/install.sh | sh`. It installs into
  `~/.local/bin`, which is already first on PATH, so it leaves the shell alone.
  If an installer ever adds lines to `~/.zshrc`, see
  [When an installer changes the shell](../README.md#when-an-installer-changes-the-shell).
- `codex --version` is 0.159 or later.
- `codex login` → **Sign in with ChatGPT**.
- On chatgpt.com: Settings → Data Controls → turn off **Improve the model for
  everyone**.
- In Codex's settings (the account's, not a config file), turn off commit
  attribution, or Codex tells itself to add a `Co-authored-by: Codex` line
  that outranks `AGENTS.md`.
- `ls ~/.codex/AGENTS.override.md` finds nothing. That file would replace the
  shared rules for Codex.

### GitHub

The bootstrap and the apply did it all: `gh` is signed in, `~/.gitconfig`
pushes over HTTPS through `gh` and signs with `~/.ssh/mini_signing`, and the
key is registered (the check in [Bootstrap](#1-bootstrap)). Don't run the old
guide's `gh auth setup-git`, `git config --global` or `ssh-keygen` lines: they
would change files the apply manages. To check, without a 1Password prompt:

```sh
t=$(mktemp -d) && git -C "$t" init -q && git -C "$t" commit -q --allow-empty -S -m test && git -C "$t" log -1 --format='%G?'
```

prints `G`, and `git ls-remote https://github.com/ctejada10/hurin HEAD` prints
a commit.

### No API key

Everything runs on your Claude and ChatGPT subscriptions. There's no Anthropic
Console workspace, no API key and no "Claude API" instance in T3, and when
ChatGPT's limit runs out, Codex's work waits for it.

## 5. T3 Code

### Install and run it in the background

1. `curl -fsSL https://t3.codes/install.sh | sh`. It checks the download's
   checksum, links `t3` into `~/.local/bin` and doesn't touch the shell.
2. `t3 service install`, then `t3 service status`, which says running.
3. Don't also run the T3 desktop app on the mini: one server per T3 home.

The service starts when your account logs in, which with automatic login means
after every restart.

### The setup wizard and projects

At the mini's screen, open `http://localhost:3773`. The wizard checks for
Claude Code and Codex and offers to import projects.

- Import the agent repos from `~/src`: hurin, rivendell, scripts, cad-a11y,
  readme, arwen and faramir.
- Leave out the vault and `tilde`.
- The dotfiles repo at `~/.local/share/chezmoi` is the mini's live config.
  Import it only if every thread there starts in a new worktree.

### Providers

Settings → Providers.

1. **Claude**, the default instance, uses your Claude Code login. Its card
   shows your work account; if it warns about the version, **Update now**.
2. **Codex:** turn it on. The card shows your ChatGPT account.
3. **Claude (attended):** Add provider → Claude, then:
   - Name: `Claude (attended)`.
   - Binary path: `claude`.
   - CLAUDE_CONFIG_DIR: empty, so it shares your normal login and threads can
     switch between it and the default instance.
   - Launch arguments, one line:
     `--append-system-prompt-file /Users/ctejada/.claude/attended.md`. Use the
     full path: T3 reads the file itself, resolves the path against the
     project folder and doesn't expand `~`. A wrong path doesn't fail
     quietly; T3 refuses the first message and names the path it tried.
   - Environment → Variables: `AGENT_ATTENDED` = `1`. Marking it sensitive is
     fine: T3 keeps the value in its secret store and fills it back in.

   The variable is the easy one to lose: on 27 Oct the Add provider flow
   saved the launch argument but not the variable (#3). Check what T3 saved:

   ```sh
   plutil -extract providerInstances.claudeAgent_claude_attended json -r -o - ~/.t3/userdata/settings.json
   ```

   It lists an `environment` block with `AGENT_ATTENDED`. A thread keeps the
   environment it started with, so test in a new thread on the instance, sent
   as its first message:

   ```
   Run echo "AGENT_ATTENDED=[${AGENT_ATTENDED:-unset}]" and show me the output.
   ```

   It prints `AGENT_ATTENDED=[1]`. The model picker shows the instance's
   initials, `CA`, on the Claude icon.

The attended instance is for design conversations. On it, agents stop and ask
you; on the default instance they run unattended, and `hooks/agent-gate.sh`
has them decide anything they'd ask and carry on. `~/.claude/attended.md` is
the prompt the repo keeps for it.

### Settings

- Threads → New threads → **Permissions: Auto.** The starting default is Full
  access, meaning no approvals at all. Auto lets routine steps go ahead and
  asks about risky ones, and Codex hands routine approvals to its own
  reviewer, so a child thread doesn't stall waiting for you.
- Maintenance → **Continue threads after restarts:** on.
- **Worktrees:**
  - **Worktree location:** Default. That's `~/.t3/worktrees`, which the
    cleanup job leaves to T3.
  - **Start from remote:** on. New worktrees start from GitHub's copy of the
    branch, as the agents' own rules do.
  - **Worktree branch naming:** Static prefix, `t3`.
  - **Delete merged worktrees:** on. This is "cleanup on merge".
  - **Delete worktrees with deleted threads:** on. Worktrees with local
    changes are kept, and the branch stays.
  - **Delete inactive worktrees:** off.
  - Under Advanced, **Delete settled worktrees** and **Delete unchanged
    worktrees:** off.
  - Under Advanced, **Keep worktrees with local changes: Uncommitted
    changes.** Any local files also counts ignored files, so a `.venv`,
    `.pytest_cache` or `.coverage` would keep every Python worktree forever.

The time-based cleanups were kept off because of how T3 recreates a worktree:
when a follow-up or a rollback reaches a thread whose worktree folder is gone,
T3 runs `git worktree prune` in the project's checkout, and that checkout used
to be in Dropbox (#3). The checkouts are plain clones in `~/src` now (#5), so
the prune is harmless and turning them on is a choice, not a risk.

## 6. T3 Connect

T3 Connect reaches the mini through a relay, with no router changes and no VPN
on the phone: the mini opens a tunnel out to Cloudflare.

1. On the mini, `t3 connect`. Say yes to installing the relay client. It
   prints a link and a short code: open the link on any device, check the
   code matches, and approve.
2. It ends with a check that other devices can reach the mini. Two failures
   are known:
   - **"The server has not set up a T3 Connect tunnel."** The service was
     already running when `t3 connect` linked the mini, and picks the link up
     only when it starts:

     ```sh
     t3 service restart && sleep 20 && t3 connect status
     ```

   - **"The T3 Connect address does not resolve from this machine."** The
     address is new, and macOS cached a lookup made a moment before it
     existed. Clear the cache and check again:

     ```sh
     sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder; sleep 3; t3 connect status
     ```

   It passes with `✓ Other devices can reach this machine`.
3. The tunnel needs outbound TCP and UDP on port 7844. Home networks allow it;
   a Tailscale exit node on the mini would block it, so don't use one there.
4. **The iPhone and the iPad:** install T3 Code from the App Store (2.0 or
   later), sign in to the same T3 Connect account, and choose amon-sul. If it
   doesn't appear, `t3 pair` on the mini prints a QR code to scan under
   Settings → Environments → Add environment. That link points at the home
   network, so it works only at home, and it's a password: keep it out of
   screenshots.
5. **Notifications:** in each app, Settings → Notifications → **Device
   Notifications** on, and on iOS **Live Activity Updates** too. Push
   notifications only work through T3 Connect.
6. **Who has access:** Settings → Sharing & access on the mini lists every
   paired device. Keep the laptop, iPhone and iPad, and revoke anything else.
7. **Versions travel together:** when T3 updates, update the mini (`t3 update`)
   and the apps together. A newer server refuses an older app with "Client not
   supported".

The laptop's app is set up in the [personal Macs guide](setup-macs.md#t3-code-and-hermes-from-the-laptop).

**Routes.** T3's service listens on the mini's home-network and Tailscale
addresses, never a public one, and every device still has to pair or sign in.
Once a device has connected, its app learns those addresses as routes and uses
the fastest that answers: the home network at home, then Tailscale on the
laptop, then T3 Connect. `T3CODE_HOST=127.0.0.1` in `~/.t3/service.env`, then
`t3 service restart`, would send everything through T3 Connect; there's no
reason to.

## 7. Claude Code plugins and t3-pstack

### The repo's plugins

Each role's plugins are declared in `home/dot_claude/modify_settings.json`.
Claude Code downloads them in the background once a session has started, so
`claude plugin list` shows none on a new mini. Start one session before
installing t3-pstack, so its checks and the first T3 thread see the full set:

```sh
(cd "$(mktemp -d)" && claude); claude --version; claude plugin list
```

Say yes to the trust prompt, wait a minute or two without typing, then
`/exit`. The list then shows nine plugins: agnix, andrej-karpathy-skills,
ponytail, ty-python-lsp, Trail of Bits' mutation-testing,
property-based-testing, spec-to-code-compliance and supply-chain-risk-auditor,
and superpowers@sp-gated at the version `pins.yaml` names. pstack must not be
there: t3-pstack is its port for T3. If some are missing, they were still
downloading; run it again.

`claude plugin details superpowers@sp-gated` lists its skills and one
SessionStart hook starting `[ "${SP_BOOTSTRAP:-0}" = 1 ]`. If the official
superpowers was ever installed, `claude plugin uninstall superpowers@claude-plugins-official`.

### Install t3-pstack

```sh
npx -y github:chhoumann/t3-pstack#v2.1.0 install && npx -y github:chhoumann/t3-pstack#v2.1.0 doctor
```

The tag in that line pins only the installer. Its marketplace comes from
`chhoumann/t3-pstack` with no tag, so Claude Code and Codex install whatever
main holds; on 27 Oct that was exactly v2.1.0, so installer and plugin agreed.
Before installing a later version, check that main is still at the tag you
name (#3). The installer adds t3-pstack to both Claude Code (`~/.claude`,
which the attended instance shares) and Codex (`~/.codex`), and trusts its
Codex session hook.

Then, before any T3 thread:

1. `chezmoi diff`. The real change is t3-pstack's `autoUpdate` going from
   `true` to `false` in `~/.claude/settings.json`; the rest is key order,
   since chezmoi writes that file sorted.
2. `chezmoi apply`, so auto-update is off before Claude Code can pull a newer
   main.

From then on doctor reports `FAIL marketplace auto-update: false`. That's the
repo's choice. Don't follow its fix: rerunning the installer turns auto-update
back on.

### Seat the roles

1. Start a new thread on **Claude (attended)**, in any project, on the
   current checkout. The setup only writes `~/.config/t3-pstack/models.md`,
   outside the repo.
2. Send the `AGENT_ATTENDED` test from [Providers](#providers) first. If it
   prints anything but `[1]`, fix the instance; on the default instance the
   hook blocks the setup's questions and Claude picks defaults itself.
3. Send `/t3-pstack:setup-pstack`. Its questions arrive as cards. What was
   chosen on 27 Oct:
   - **Budget:** medium, every role at high reasoning. Large puts every role
     at xhigh and uses up the plans' limits fastest.
   - **Roles that write code at volume** (feature and refactoring, swarm
     workers): `codex/gpt-5.6-terra`.
   - **The hard tier** (bug-fix, perf-issue, hillclimb, the hardest tasks):
     Claude Fable 5.1.
   - **Everything else:** Claude Opus 5.5 on the default instance
     (`claudeAgent/...`), so the threads these roles start run unattended.
   - **Panels** (arena runners, arena cross-judge pool, architect runners,
     interrogate reviewers): Opus 5.5 and `codex/gpt-5.6-terra`. Grok isn't
     set up, so each panel runs two subagents instead of three.
   - **Session hook:** on. It's the only router: `AGENTS.md` sends multi-file
     changes, design choices, bugs with an unknown cause and performance work
     through poteto-mode.
   - **The verification and formal verification skills:** no. They would
     write into a repo mid-setup; ask for one later in its own thread.

   The old guide's `gpt-6.1-sol` isn't offered on this ChatGPT plan. Of the
   models Codex lists, gpt-6-luna is the small, fast tier and gpt-5.6-terra
   the middle one.
4. `npx -y github:chhoumann/t3-pstack#v2.1.0 doctor` now shows the sheet
   valid, and only the auto-update FAIL.

t3-pstack 2.1.0's checker (`t3-sheet.mjs`) reads T3's model list in an older
layout than T3 0.1.3 returns, so every setup run reports a false failure
first; the thread works around it. Re-running `/t3-pstack:setup-pstack`
changes the sheet.

### The first coding loop

1. In the Húrin project, a new thread on **Claude**, Auto. Pick a small, real
   issue: a widget bug or a one-file change with a test.
2. "Plan this change. Then use delegate_task to hand the implementation to
   Codex (gpt-5.6-terra, Auto mode, in a new worktree). When it reports back,
   review the diff against the plan, ask Codex to fix anything you find, and
   tell me when it's ready to merge."
3. The thread's lineage view shows the child on Codex. If it shows Claude,
   the delegation didn't name its target.
4. Review the diff in T3, open the PR with its button, and merge.

Then try poteto-mode on one bigger task and count the threads it creates; one
user's design task spawned 78, five levels deep (t3-pstack's issue #21). If
yours sprawls, keep it for bigger work only.

**Smoke tests:**

- On the default instance, ask for a small design with
  superpowers:brainstorming: it writes a spec and carries on without asking.
- On Claude (attended), type `/superpowers:brainstorming`: you get an
  ask-for-input card.
- Let one default run finish: a draft PR whose body lists the work, and no
  menu.
- Before an agent's first push, its thread shows `rules: mini <date>` on a
  line of its own, which says the rules file loaded.
- The first transcript shows t3-pstack's and Ponytail's session text and no
  superpowers. If Ponytail's rules and poteto-mode pull in different
  directions, switch Ponytail off on the mini too.

## 8. Hermes

Hermes is the everyday assistant. How it's set up, and why:

- **It runs on Codex, through its own ChatGPT login.** Hermes can't use your
  Claude plan: its Claude login works only on Max, and then bills only extra
  usage credits bought on top, never the plan's included usage.
- **It never borrows another program's login.** Codex CLI's and Claude Code's
  logins use refresh tokens that work once, so whichever program refreshes
  first logs the other out, which on the mini would be T3. Hermes gets its
  own login, and `auth.adopt_external_logins` is off.
- **Its tools:** Gmail read-only, Calendar without deleting, Todoist without
  deleting, Monarch without deleting or merging, the vault read and write,
  your three skills, and no screen control, browser clicking or image
  generation.
- **It asks first:** smart approvals for risky commands, deny rules for what
  must never run, and your own rules in its `SOUL.md`.

### Install

```sh
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-setup && rehash && hermes config set auth.adopt_external_logins false && grep -n adopt_external_logins ~/.hermes/config.yaml
```

Without `--skip-setup` the installer runs `hermes setup` and installs the
gateway as soon as it finishes, before login borrowing can be turned off. It
installs into `~/.hermes/hermes-agent` with `hermes` in `~/.local/bin`, and
appends a PATH line to `~/.zshrc` and `~/.zprofile`; let the next
`chezmoi apply` overwrite both.

### Setup

`hermes setup`, then:

- **Import from Claude Code or Codex:** No. Those hold the coding agents'
  rules, skills and MCP servers, not an assistant's.
- **How to set up:** **Full setup**. Quick Setup signs you in to Nous Portal,
  a separate paid service.
- **Provider:** OpenAI ▸ → **ChatGPT or Codex Subscription**. When it offers
  to import the Codex CLI's credentials, answer `n`, then approve the device
  code it shows with your ChatGPT account. The code is a password while it's
  on screen.
- **Model:** gpt-6-luna, the small, fast tier, like the Haiku the old guide
  planned. The `-900k` versions only add context. `hermes model` changes it.
- **Reasoning effort:** medium.
- **Terminal backend:** Local. The safety settings below assume it.
- **Messaging platforms:** none yet.
- **Gateway service:** No, for now.
- **Tools:** untick Computer Use, Browser Automation and Image Generation.
- **Text-to-speech:** Piper, which runs on the mini. Edge TTS would send what
  it reads, briefs included, to Microsoft.
- **Web search:** OpenAI Native Web Search (Codex Responses), which runs on
  OpenAI's side with no key and no new company. DuckDuckGo (ddgs) is the
  fallback. Reading pages then goes through Exa's free tier, which sees the
  addresses Hermes opens; `hermes setup tools` changes that.
- Skip anything that asks for an API key.

Then:

```sh
hermes auth list; hermes config set HERMES_TIMEZONE America/New_York; hermes doctor
```

`hermes auth list` shows OpenAI Codex with Hermes's own device-code login and
says external logins aren't adopted. It may also list your GitHub CLI login
under Copilot; that's used only if you pick Copilot as a model. Doctor's npm
vulnerability warnings are Hermes's own bundled packages and clear with a
later `hermes update`.

### Safety settings

```sh
hermes config set approvals.mode smart && hermes config set approvals.timeout 600 && hermes config set approvals.cron_mode deny && hermes config set approvals.destructive_slash_confirm false && hermes config set approvals.deny '["*gmail send*", "*gmail reply*", "*gmail modify*", "*messages send*", "*drafts send*", "*calendar delete*", "*.obsidian*", "git push --force*"]' && hermes config set HERMES_WRITE_SAFE_ROOT "/Users/ctejada/agent-drafts:/Users/ctejada/.hermes:/Users/ctejada/Documents/armenelos" && hermes config set agent.disabled_toolsets '["computer_use", "browser", "image_gen"]'
```

- **Smart approvals:** a second look by the model lets clearly safe commands
  run and refuses clearly dangerous ones; the rest come to you. No answer in
  10 minutes counts as no.
- **Scheduled jobs** never ask: a flagged command is simply refused.
- **The confirmation** for `/new` and the like is off, because its buttons may
  not show in Beeper.
- **The deny rules** stop sending or replying to email, changing mail,
  sending drafts or messages, deleting calendar events, touching `.obsidian`
  and force pushes, even if you approve or turn on yolo. They match the
  commands of Hermes's Google skill. Hermes's own docs call command rules a
  guard rail, not a sandbox; the limits each connection carries are the
  stronger ones.
- **Hermes's file tools** write only in `~/agent-drafts`, `~/.hermes` and the
  vault. Credential files are protected everywhere.
- **Disabled toolsets** apply to every platform, Telegram included.

### Telegram: Bree

1. In the Telegram app, message **@BotFather**, send `/newbot`, and name the
   bot: display name `Bree`, after the village beside Weathertop where news
   from all over passed through, and a username ending in `bot`. Save the
   token in 1Password; anyone with it controls the bot.
2. Message **@userinfobot** for your numeric user ID.
3. `hermes gateway setup` → Telegram → **Manual**, paste the token, give your
   user ID as the only allowed user, and use it as the home channel, where
   scheduled jobs deliver. That replaces the old guide's `/sethome`.
4. When it offers to start the gateway at login as a launchd service, say yes.
5. The Telegram settings, under the names this Hermes version uses (the old
   guide's `gateway.streaming` and `notifications` keys don't exist):

   ```sh
   hermes config set streaming.enabled true && hermes config set streaming.transport edit && hermes config set platforms.telegram.extra.drop_pending_on_cold_boot false && hermes config set display.platforms.telegram.tool_progress off && hermes gateway restart && hermes gateway status && hermes tools list --platform telegram
   ```

   Streaming edits one message in place, which reaches Beeper; messages you
   send while the mini restarts are kept; and no progress messages, so the
   chat is mostly answers and approvals. The tools list shows browser,
   image_gen and computer_use disabled.
6. Message Bree "hello". The gateway also posts "Gateway online" whenever it
   starts.

### Beeper and approvals

- In Beeper on each device, add Telegram as an **on-device** connection, so the
  chats stay off Beeper's servers.
- Beeper shows approval requests as plain text: type `/approve` or `/deny`.
  The official Telegram app on the iPhone shows buttons, **Allow Once**,
  **Session**, **Always** and **Deny**. Use only Allow Once or Deny: Always
  stops Hermes asking about that kind of command for good, and Session for the
  rest of the conversation.
- **The five-minute test:** `hermes config set approvals.mode manual && mkdir -p ~/tmp/hermes-test && hermes gateway restart`, then in Beeper send
  `Run this command on the mini: rm -rf ~/tmp/hermes-test` and type
  `/approve`; the folder goes. Make it again, ask again, and tap **Deny** in
  the Telegram app; the folder stays. Then
  `hermes config set approvals.mode smart && hermes gateway restart && rm -rf ~/tmp/hermes-test`.

### The vault

The vault reaches the mini through Obsidian Sync, at
`~/Documents/armenelos`, and Hermes reads and edits it there.

1. The Brewfile installs Obsidian. Sign in to Sync and connect the vault to
   `~/Documents/armenelos`.
2. System Settings → General → Login Items: add Obsidian. Sync only runs while
   the app is open.
3. Keep Sync's version history on. It's the undo for anything Hermes changes.
4. Start Hermes's chats in the vault, so it loads the vault's `CLAUDE.md`:

   ```sh
   hermes config set terminal.cwd /Users/ctejada/Documents/armenelos && hermes gateway restart
   ```

5. The first time Hermes opens the vault, macOS asks on the mini's screen
   whether python can access your Documents folder. Allow it. Ask Bree
   "Using the vault-researcher skill, which note lists my device names?" to
   test.

`.obsidian` may sync too, with live plugin tokens. The deny rule keeps
commands out of it; Hermes's file tools are kept out only by the rules in its
`SOUL.md`.

### Your skills

draft-email-reply and todoist-triage, copied as they are, and vault-researcher
made into a skill by dropping its Claude-only `tools:` line. Hermes keeps
skills in category folders and picks up new ones without a restart:

```sh
d="$HOME/.hermes/skills/personal"; s="$HOME/.local/share/chezmoi/home/dot_claude"; mkdir -p "$d/vault-researcher" && cp -R "$s/skills/draft-email-reply" "$s/skills/todoist-triage" "$d/" && sed '/^tools:/d' "$s/agents/vault-researcher.md" > "$d/vault-researcher/SKILL.md" && hermes skills list | grep -i -E 'draft-email-reply|todoist-triage|vault-researcher'
```

### Your rules: `SOUL.md`

Hermes puts `~/.hermes/SOUL.md` at the top of every conversation, in Telegram,
the terminal and scheduled jobs. This section, below its default persona,
carries your rules over:

```sh
cp ~/.hermes/SOUL.md ~/.hermes/SOUL.md.bak && cat >> ~/.hermes/SOUL.md <<'EOF'

## Working with Carlos

Carlos usually reads you on his phone, in Telegram or Beeper. Keep replies short.

### Writing
- Never use em dashes, in replies, notes, tasks or drafts.
- Plain declarative sentences. Professional but not formal. Don't overstate or oversell.
- Say what a thing is, then stop. Don't add detail he didn't ask for.
- No "What we found" or "What we did" headings, and no bullets inside email bodies.

### Before changing anything
- Act only at full certainty. Otherwise say what's uncertain and ask, as a short numbered list.
- Todoist: when you finish the work a task describes and it is clearly done, complete it without asking, then tell him. Propose any other change one at a time and wait for a yes.
- Monarch: propose one change, then stop and wait for a yes. One item at a time, never a batch.
- "Confirm X" means check whether X is already true. It is never a new request.
- You can read Gmail but not send or change it. When he wants a message sent, draft it in chat for him to send.
- Calendar: propose one event at a time and wait for a yes before adding it. Never delete events.
- Ask before creating a new note or file, and ask where it should go. Never pick a location yourself.

### The vault
- The vault at /Users/ctejada/Documents/armenelos has its own CLAUDE.md. Follow it when you edit notes.
- Most of its prose was written by AI agents. Never quote it back to him as his own words, and never use it as a source for a research question.
- Never read or change anything under .obsidian/. It holds live API tokens.
EOF
```

It applies from the next conversation: send `/new` to Bree.

### Todoist

Todoist's own MCP server, signed in with your Todoist account; no key. Run it
in Terminal at the mini's screen, since the sign-in opens a browser there and
Todoist sends you back to the mini:

```sh
hermes mcp install todoist && hermes mcp login todoist && hermes config set mcp_servers.todoist.tools.exclude '["search", "fetch", "export-project-template", "import-project-template", "delete-object", "project-management", "project-move", "manage-assignments"]' && hermes gateway restart
```

The first four removed are Hermes's own defaults (duplicate search, template
import and export); the other four take away deleting, managing and moving
projects, and assignments. Hermes reads, adds, edits and completes tasks, and
can un-complete one it closed by mistake. Its `SOUL.md` lets it complete a task
whose work it has clearly finished without asking, and has it propose every
other change. Test: "What's due today in Todoist?"

### Gmail and Calendar

Through Hermes's Google skill, with Gmail read-only and full Calendar, enforced
by Google. carlosetejada.com runs on Google Workspace, so the app can be
internal.

1. **Google Cloud,** at the mini's screen so the file lands there, signed in
   as carlos@carlosetejada.com at console.cloud.google.com:
   1. A new project, named Hermes, located in your carlosetejada.com
      organization. Internal sign-in exists only for projects inside it.
   2. APIs & Services → Library: enable **Gmail API** and **Google Calendar
      API**, nothing else.
   3. Google Auth Platform → Get started: app name Hermes, your email,
      **Audience: Internal**. Internal skips test users and the weekly
      sign-out External test apps get.
   4. Clients → Create client → **Desktop app** → Create → **Download JSON**.
2. **Narrow what Hermes asks for.** Hermes 0.22.5's setup script always asks
   for eight permissions (Gmail send and modify, Drive, Docs, Sheets and
   contacts among them); its instructions describe a `--services` option the
   script doesn't have, and Google's screen offers no way to untick them.
   This keeps a backup and limits it to Gmail read-only and full Calendar:

   ```sh
   f="$HOME/.hermes/skills/productivity/google-workspace/scripts/setup.py"; [ -f "$f.orig" ] || cp "$f" "$f.orig"; perl -0pi -e 's/SCOPES = \[.*?\]/SCOPES = [\n    "https:\/\/www.googleapis.com\/auth\/gmail.readonly",\n    "https:\/\/www.googleapis.com\/auth\/calendar",\n]/s' "$f" && grep -n -A3 '^SCOPES' "$f"
   ```

   The script that reads your mail uses whatever the saved token holds. A
   Hermes update can put the original file back; that only matters if you
   redo this sign-in, so run the edit again first if you do.
3. **Sign in,** in the terminal chat rather than Telegram, so the code stays
   out of your chat history. Run `hermes` and say: "Set up Google Workspace
   for email and calendar. The client secret file is in my Downloads folder:
   <the file's name>." Keep the path inside a sentence; a bare path at the
   start of a message looks like a command. Answer **No** to Advanced
   Protection unless you've enrolled in it. Open the link it gives you, allow
   both permissions, then copy the whole address of the `localhost:1` page
   that fails to load and paste it to Hermes within about 10 minutes. Ask it
   which scopes the saved token has: exactly `gmail.readonly` and `calendar`.
4. `ls -l ~/.hermes/google_client_secret.json && rm ~/Downloads/client_secret_*.json`.
   Hermes keeps its own copy.
5. Test: "What are my three newest unread emails, and what's on my calendar
   tomorrow?"

If a token ever comes back with more than those two scopes, have Hermes
revoke it at once and start over.

### Monarch

Monarch's [official MCP server](https://help.monarch.com/hc/en-us/articles/50207234679956-Monarch-MCP-Connector),
which Hermes's catalog doesn't carry. At the mini's screen:

```sh
hermes config set mcp_servers.monarch.url https://api.monarch.com/mcp && hermes config set mcp_servers.monarch.auth oauth && hermes config set mcp_servers.monarch.enabled true && hermes mcp login monarch && hermes mcp configure monarch && hermes gateway restart
```

- At Monarch's sign-in, choose **read and write**.
- In the tool checklist, untick DeleteTransaction, DeleteTag, MergeMerchants,
  DeleteRule, DeleteCategory, DeleteGoal and ReportIssue, which sends Monarch
  a report about the session. Everything else stays, the two bulk tools
  included; `SOUL.md` has Hermes propose changes one at a time.
- `grep -n -A14 'monarch:' ~/.hermes/config.yaml` shows what was saved. Monarch
  lists Hermes's access under Settings → MCP Connector, where you can revoke
  it.
- Test: "What did I spend on dining out this month?"

## 9. Scheduled jobs

Turn them on one week at a time.

**Hermes's jobs**, in Terminal on the mini. Each delivers to Bree's chat:

| Week | Job | Command |
|---|---|---|
| 1 | Morning brief | `hermes cron create "daily at 7am" "Morning brief: triage my Gmail inbox, list today's calendar, and list Todoist tasks due today or overdue. Read only; never send email. Suggest Todoist changes as a numbered list for me to approve." --skill email-inbox-triage --skill google-workspace --deliver telegram` |
| 2 | Evening wrap-up | `hermes cron create "daily at 9pm" "Evening wrap-up: what got done in Todoist today, what's left, and tomorrow's calendar. Propose any vault notes as drafts in ~/agent-drafts for me to review." --skill google-workspace --deliver telegram` |
| 2 | Weekly review prep | `hermes cron create "every sunday 6pm" "Prepare my weekly review: the week's completed and overdue Todoist tasks, next week's calendar, and open loops. Write it as a draft in ~/agent-drafts." --skill google-workspace --deliver telegram` |
| 2 | Job-search checkpoint | `hermes cron create "0 18 1,15 * *" "Prepare my job-search checkpoint from my applications tracker: status changes, follow-ups due, and next steps." --deliver telegram` |

- `hermes cron list` shows each; `hermes cron run <job_id>` runs one now.
- `hermes cron edit <job_id> --schedule "…"` or `--prompt "…"` edits one;
  `/cron pause <job_id>` and `/cron resume <job_id>` work from Telegram.
- Scheduled jobs can't ask, so they write drafts to `~/agent-drafts` rather
  than editing the vault.

**T3's nightly coding** (week 3):

- Pick a home for plans you've approved, such as `.plans/ready/` in each repo,
  and add `.plans/` to the repo's `.gitignore`.
- In T3: Settings → Scheduled tasks → new task → the mini, the Húrin project,
  Codex on the coding model from your t3-pstack sheet, daily at 1:00 am.
- Change its permission mode from Full access to **Auto**: new scheduled tasks
  default to Full access and run with nobody watching.
- Prompt: "Implement each plan in `.plans/ready/`, one per worktree branch.
  Run the tests, commit, and stop after three plans. Don't push or open pull
  requests."
- In the morning, open the results in T3 and have Claude review them before
  you merge.

**Later:** Hermes could start T3 threads itself with `t3 thread start`,
`t3 thread send --wait` and `t3 thread show`, which need no sign-in on the
mini. Ask it to remember: "For coding tasks, start a T3 thread in the right
project with `t3 thread start` and send me its ID; don't write the code
yourself."

## 10. Final checks

Run these away from the mini: from the couch with the iPhone, then the iPad,
then the laptop.

1. **Restart.** Apple menu → Restart on the mini, and don't touch it. Within
   about 3 minutes, `t3 service status` over SSH says running, and Bree
   answers "ping".
2. **T3 from the iPhone.** Start a thread on Claude: "List the TODOs in this
   repo." Lock the phone; a push notification arrives when the turn finishes.
3. **The same thread elsewhere.** Open it on the iPad and in the laptop app;
   you can reply from either.
4. **Hermes through Beeper.** "What's on my calendar tomorrow?" gets a short
   answer that matches your calendar.
5. **Approval, typed.** In Beeper, ask Hermes to `rm -rf ~/agent-drafts/test`
   on a test folder and reply `/deny`: it asks first and stops.
6. **Approval, buttons.** The same in the Telegram app, tapping Deny.
7. **A cron job.** `hermes cron list`, then `hermes cron run <the morning
   brief>`: the brief arrives.
8. **The coding loop.** From the iPhone, a Claude thread on a small real
   change that delegates the implementation to Codex ends in a pull request.
9. **The repo.** `chezmoi verify` exits 0, and t3-pstack's doctor shows only
   the auto-update FAIL.
10. **SSH from the devices.** Over cellular, `ssh amon-sul` in Blink logs in
    on the iPhone and on the iPad.

You're ready when they pass, the mini is unplugged from its keyboard and
screen and in its spot, and you've started a real task from the iPhone
without opening the laptop.

## How the mini works

### Rules on the mini

Every agent there, Claude Code and Codex alike, reads one file:
`home/dot_codex/AGENTS.md` in this repo, which becomes `~/.codex/AGENTS.md`.
Codex reads it directly; the mini's `~/.claude/CLAUDE.md` is the one line
`@~/.codex/AGENTS.md`. Edit that file, nothing else: no other rules file loads
on the mini. It keeps runs from waiting on you (agents decide and carry on,
and only a real stop asks), and its first rule is absolute: a commit is never
co-authored by an AI agent. Claude Code's own
attribution is switched off in its settings on every Mac. Hermes has its own
rules, in `~/.hermes/SOUL.md`.

### Git on the mini

Agents commit, push and open draft PRs on their own branches without asking;
never on the default branch, never a force-push, a merge or a PR opened ready.
Claude Code's `hooks/guard-git.py` blocks the ordinary forms of each, and
refuses a commit or PR that credits an AI.

A draft PR's body lists the work, one line per change, plus the `STOP:` text
when a run stopped and a line for each gate that failed or was skipped. In a
repo whose default branch's ruleset has Copilot's review, which is scripts for
now, credits are limited, so each PR gets one Copilot review, as the last check
on a PR already believed clean. Before opening the PR the agent passes every
gate, runs CI's checks locally and gets adversarial reviews on two model
families. After Copilot's review it puts every finding that holds up in one
change, gets that change reviewed by a different model family, pushes once,
then replies in each thread and resolves it. A repo reviews every push until
`review_on_push` is off in its ruleset.

Any other repo and this dotfiles source change only for a task you typed, and
never in place: `~/.local/share/chezmoi` is the mini's live config. An agent
clones another repo from GitHub into `~/worktrees/<repo>/<branch>`, or makes a
worktree of the dotfiles repo in `~/worktrees/dotfiles/<branch>`, and ends
with a draft PR you merge or drop. Once you merge a dotfiles PR,
`chezmoi update --init` in a terminal of your own makes it live; agents can't
run it. The hooks block the in-place forms, and
refuse every git and gh command in Dropbox's `repositories` folder, the repos'
old home, reads included: those repos are read on GitHub.
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

### Worktrees and the cleanup job

Each repo's main checkout is a plain clone in `~/src`, and nothing edits it in
place: the path guard and the Git guard send an agent to a worktree. T3 keeps
its own in `~/.t3/worktrees`, Claude Code's go to `~/worktrees/<repo>/<name>`
through `hooks/worktree.sh`, and FirstMate's crews use treehouse's
`~/.treehouse`. A commit made in any of them lands in the clone's `.git`, and
reaches GitHub, and so the laptop, only when its branch is pushed.

Finished worktrees stay, so a follow-up thread can pick one up, and clean up
after themselves. `~/.local/bin/worktree-ttl` runs daily at 04:17 and removes
a worktree in `~/worktrees` once it has gone 14 days unused (no edits, commits
or Claude Code session there; an edit to a file the repo ignores counts too,
apart from caches, environments and build output) and nothing in it would be
lost: never one with an open PR, unpushed commits, commits only its reflog
holds, uncommitted work, a running process or a lock
(`git worktree lock --reason "keep: <why>"` keeps one). A merged branch goes
with its worktree. A clone of another repo there is judged the same way, and
goes only when each of its branches is merged, or pushed with no open PR, and
it holds no stash. It goes to the Trash, not deleted, and `git worktree lock`
doesn't apply to a clone: an open draft PR keeps one. The job never fetches,
prunes, gc's or uses `--force`. It logs to `~/Library/Logs/worktree-ttl/`, and
anything it can't decide, such as a moved or broken worktree, goes in
`attention.txt` there. T3's and FirstMate's worktrees are left to them.
`launchctl print gui/$(id -u)/com.carlosetejada.worktree-ttl` shows it loaded.

### FirstMate

The apply clones it to `~/firstmate` at the commit in `pins.yaml` and sets
`FM_HOME` to `~/.local/share/firstmate`, where its state lives. Its `projects`
folder holds a link to each `agent-mini` repo's clone in `~/src` and nothing
else, because FirstMate fetches, prunes branches and fast-forwards every
folder there; the
registry is written once, every repo `direct-PR`. Then, by hand: start Claude
Code in `~/firstmate` and let its first session install treehouse and the CLIs
it asks for, approving each. Its crews branch as `fm/<task>`.

### Docker

Containers run in Colima, a small Linux VM that the apply starts as a login
service, with Homebrew's docker CLI, Compose and Buildx. There is no Docker
Desktop on either Mac.

### Claude Code on the mini

- **Process:** t3-pstack routes, through poteto-mode, and is the only plugin
  whose session hook steers the work. Its hook also loads in plain `claude`
  runs outside T3; start one with
  `claude --settings '{"enabledPlugins":{"t3-pstack@t3-pstack":false}}'` to
  leave it out.
- **superpowers**, as a skill library t3-pstack and the agents call by name:
  its test-first features, its plans, its debugging material. It comes from a
  local marketplace in `~/.local/share/claude-plugins/sp-gated`, unchanged
  from its release (pinned in `pins.yaml`), whose entry replaces its session
  hook with one that does nothing, so it never competes with t3-pstack.
  `hooks/agent-gate.sh` keeps it from waiting on you when you aren't there:
  unattended, brainstorming is refused, a question reaches you only when it
  starts with `STOP:`, and the agent decides every other ask and carries on.
  Specs and plans go in `~/agent-drafts/<repo>/<branch>/`. Its finishing menu
  never runs: a branch always ends pushed, with a draft PR.
- **Design conversations, when you want one:** in T3, open a thread on the
  "Claude (attended)" instance and type `/superpowers:brainstorming` with the
  idea or an issue. Its questions arrive as T3's ask-for-input cards and wait
  until you answer; once you approve the plan, the run goes on to a draft PR
  without you. A child thread started from an attended thread inherits
  `AGENT_ATTENDED=1`; `AGENTS.md` tells it to work as unattended anyway.
- **Plugins:** Ponytail with its full ruleset always on, the Karpathy
  guidelines, agnix, the ty language server, and Trail of Bits' supply-chain
  auditor, property-based-testing, mutation-testing and
  spec-to-code-compliance. No pstack. No claude.ai connectors or synced
  plugins.
- **`/go <task>`:** your own command, from `home/dot_claude/skills/go`. It
  sends big tasks to poteto-mode and runs small ones in the thread with no
  subagents, calling superpowers' test-first, debugging and verification
  skills, deslop and a low-level `/code-review`, through to a draft PR. Type
  `/go` alone to see the steps and the table. Claude never starts it on its
  own.
- **Skills copied in under their licences:** a subset of Matt Pocock's
  (grill-me, to-spec and the architecture ones), HumanLayer's research, plan
  and implement set (`rpi-`), GitHub's Actions hardening review and
  i-have-adhd. Four review agents from ECC (`ecc-`). See `LICENSES/`.
- **Downloaded at pinned commits,** because there is no licence to copy them
  under: the OpenSCAD skill with BOSL2 (outside `~/Documents`, which can hang
  T3 on a privacy prompt), and two of George Wang's skills (read-only log
  investigation, browser evaluation).
- **Command-line tools:** agnix and no-mistakes at pinned versions, Herdr, and
  Go. no-mistakes stays inert until you run `no-mistakes init` in a repo
  yourself.
- `~/.codex/AGENTS.md` picks one tool per job where they overlap, and says
  what none of them may do on their own. It wins over every plugin, skill and
  playbook.

**3D models:** the mini writes and renders them; Bambu Studio and the printer
stay with the laptop, so a finished model is a file you open there. The skill
reads which filaments are loaded from Bambu Studio's cache, which only the
laptop has; on the mini, tell it.

### Fonts on the mini

MonoLisa comes from 1Password (see the
[personal Macs guide](setup-macs.md#fonts)). To upgrade it on the mini, turn
1Password's CLI integration on for that apply, run it from a terminal at the
mini's own screen (Screen Sharing works, SSH doesn't), then turn the
integration off again. If the mini ever needs to refresh fonts with nobody at
it, the licence-friendly route is a private repo pulled as a chezmoi external.

### What the mini never holds

The personal age key on disk (a [re-seal](setup-servers.md#re-sealing-secrets)
reads it from 1Password and keeps it in memory), the app-settings blob, a key
that can log in to the servers, Ansible (`bash tests/run.sh` in a dotfiles
worktree puts it in that worktree's `ansible/.venv` to check the playbook's
syntax, and never runs it against a host), Docker Desktop, the Claude desktop
app, any Dropbox folder but `backups`, or an Anthropic API key. Its Claude
Code loads none of the account's claude.ai connectors or synced plugins.

**Never managed by this repo on the mini:** `~/.t3`, the Codex auth files,
`~/.hermes` (its `.env`, auth, skills and `SOUL.md` included), what's inside
`~/agent-drafts` (the folder itself is created) and `~/.config/t3-pstack`.

## Troubleshooting

**T3 Code**

- **A device says "Client not supported":** the app and the server are on
  different versions. `t3 update`, then `t3 service restart`, and update the
  apps.
- **The iPhone or iPad can't reach the mini:** in the app, Settings →
  Connections → Details shows the first failing part; on the mini,
  `t3 connect status`, and see [T3 Connect](#6-t3-connect) for its two known
  failures. No exit node or VPN on the mini; outbound TCP and UDP 7844 open.
- **Nothing answers after a restart:** nobody is logged in. Check automatic
  login and FileVault, then `t3 service status`; `t3 service install` repairs
  it.
- **`t3 service status` says restart-pending:** `t3 service restart`.
- **An agent can't read a folder:** the repo is outside `~/src`.
- **A Codex child thread stalls:** it's waiting for an approval nobody sees.
  Keep new threads on Auto, and name the child's provider and model in the
  delegation.
- **Claude threads fail with an auth error:** `claude auth login`, then
  `t3 service restart`.
- **An agent decides a question that should reach you:** the thread isn't
  attended. Check `AGENT_ATTENDED` (see [Providers](#providers)), and start a
  new thread after fixing it.
- **poteto-mode starts dozens of threads:** stop the parent and keep
  poteto-mode for big tasks.

**Hermes and Telegram**

- **Bree doesn't answer:** `hermes gateway status`, then
  `hermes gateway restart`; check `TELEGRAM_BOT_TOKEN` in `~/.hermes/.env` and
  read `hermes logs --follow`.
- **Bree replies "unauthorized":** check your ID with @userinfobot against
  `TELEGRAM_ALLOWED_USERS`.
- **The gateway doesn't come back after a restart, or a new tool isn't
  found:** `hermes gateway install` again. launchd keeps the PATH a service
  was installed with.
- **An approval timed out:** the command was denied, not run. Ask again.
- **Gmail or Calendar errors** (`NOT_AUTHENTICATED`, `REFRESH_FAILED`): the
  token expired or was revoked. Redo the sign-in, after the scope edit. For
  `Access Not Configured`, the API isn't enabled in the Cloud project.
- **A Claude Code or Codex login on the mini keeps expiring:** something
  borrowed it. `hermes auth list` should say external logins aren't adopted.
- **A cron job didn't arrive:** `hermes cron list`, then
  `hermes cron runs <name>`.
- **Anything else:** `hermes doctor`.

**macOS, Git and the repos**

- **Screen Sharing is "not permitted":** turn it off and on in System
  Settings ([Remote Login and Screen Sharing](#remote-login-and-screen-sharing)).
- **Screen Sharing shows a tiny or black screen:** plug in the dummy HDMI
  plug.
- **The mini restarted itself for an update:** "Install macOS updates" came
  back on.
- **A push from the mini asks for 1Password:** the remote uses SSH. Check
  `git config --global --get-regexp url` for the HTTPS rewrite and
  `gh auth status`.
- **Commits show as Unverified on GitHub:** the signing key isn't registered
  (see [Bootstrap](#1-bootstrap)).
- **The snapshot job says `Operation not permitted`:** `/bin/bash` needs Full
  Disk Access ([The snapshot job's access](#the-snapshot-jobs-access)).
- **An apply stops because `~/src` is still a link:** it points into Dropbox,
  where the repos used to be. Remove just the link with `unlink ~/src`, never
  what it points to, and apply again; the clone step makes the folder.

## Still to bring into this repo

Done by hand on the mini first, then to be brought in here:

- T3 Code's, Codex's, Hermes's and t3-pstack's installers as `run_once_`
  scripts for the mini: Hermes's with `--skip-setup` and
  `auth.adopt_external_logins` off before anything else, and t3-pstack's from a
  checkout of its tag used as a local marketplace (`--source`), the way
  `sp-gated` holds superpowers, so nothing comes from main.
- What t3-pstack's installer wrote: `extraKnownMarketplaces.t3-pstack` and
  `enabledPlugins` in `~/.claude/settings.json`, which come from
  `modify_settings.json`, so port the keys into that template (`chezmoi add`
  on it would replace the template with a copy of the mini's file); and its
  marketplace, plugin and hook-trust entries in `~/.codex/config.toml`, which
  chezmoi doesn't manage, so `chezmoi diff` never shows them.
- `~/.config/t3-pstack/models.md` as a managed file.
- A `modify_` template for `~/.hermes/config.yaml` that merges only the keys
  set here: `approvals`, `auth.adopt_external_logins`,
  `agent.disabled_toolsets`, `streaming`, `display.platforms.telegram`,
  `platforms.telegram.extra`, `terminal.cwd`, and the Todoist and Monarch
  entries under `mcp_servers`.
- The `SOUL.md` section and the three personal skills for Hermes, as managed
  files, and the Google setup script's scope edit, or Hermes fixing its
  `--services` option.
- A mini-only script that re-runs `hermes gateway install` when the PATH setup
  changes, since launchd keeps the PATH a service was installed with.
- Confirm that `gh auth setup-git` on the mini wrote `/opt/homebrew/bin/gh` in
  the credential helper lines; if it wrote another path, `chezmoi diff` shows
  it and `home/dot_gitconfig.tmpl` follows.
- no-mistakes' global config (`~/.no-mistakes/config.yaml`): draft PRs, merge
  rather than rebase, no published intent or uploaded media, and a permission
  mode for Claude instead of skipping permissions. The keys are confirmed
  against the current docs but not yet against v1.84.0, so the file is written
  once the installed version accepts it.
- t3-pstack's thread count and spend in the first week of unattended runs.

Fixes owed in the code, from #3: Screen Sharing turned on in System Settings
rather than by the apply; the apply making `~/worktrees` and the cleanup job's
message naming Settings → Worktrees → Cleanup; and an RSA stand-in for the
device keys in CI.
