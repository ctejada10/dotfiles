# Setting up a server

The servers are dor-lomin (Húrin), Rivendell and esgaroth. cloud-init does a
server's first boot, and the Ansible playbook in [`ansible/`](../ansible) does
the rest, from the laptop only, never from GitHub or the mini. Ansible owns the
system; its last step applies this repo as `server`, which owns the home
folder. Nothing here has been run against a real server yet.

The other guides: [the mini](setup-mini.md) and [personal Macs](setup-macs.md).
Back to the [README](../README.md).

## Before any server

From `ansible/`, once:

```sh
uv run ansible-galaxy collection install -r requirements.yml
```

A run's last step clones this repo onto the server, so the repo has to stay
public on GitHub, readable without credentials; without it a first run fails
at the very end, after all the hardening is done. A full run takes about 48
minutes from the laptop, most of it the `nmap` scan.

## A new server

1. `uv run ansible-playbook cloud-init.yml -e out=<file>` writes its
   user-data with the login key from `keys.yaml`: your admin user, key-only,
   no password, no `ubuntu` account. Check it with `cloud-init schema -c
   <file>` on any Ubuntu machine and paste it into the provider's user-data.
2. Add the server to `home/.chezmoidata/hosts.yaml` and give it
   `ansible/hosts/<name>.yml` and a line in `ansible/packages.yml`
   (`tests/ansible.sh` fails until both exist). Make its DNS record (and any
   AAAA record) too: the playbook connects by name. Then `chezmoi apply` on
   the laptop, for its SSH config.
3. Open the server's SSH port in the provider's own firewall, if it has one.
   Then `uv run ansible-playbook site.yml -e target=<name> -e first_port=22`.
   The first connection asks you to trust the server's host key on 22; check
   it against the fingerprint the provider's console shows. The run opens the
   new SSH port in UFW, moves sshd to it, trusts the same host key on the new
   port, reconnects there and only then closes 22. At the end it asks for a
   sudo password and removes cloud-init's passwordless sudo. Keep that
   password in 1Password: the provider's console takes it if SSH ever fails
   (see [Everything lost](#everything-lost)). A run that stops at "Wait until
   the new port answers" is finished by the next run without `first_port`.
   Close 22 in the provider's firewall too.
4. On a server that deploys, the run also sets up `deploy`'s checkout. It
   pins GitHub's host keys, makes a read key for each repo `deploy` fetches
   (one each, since GitHub takes a deploy key on one repository only, so
   Rivendell's `arwen` gets its own) and prints every key GitHub doesn't take
   yet, or says it couldn't ask when GitHub doesn't answer; its last play
   lists where each repo stands. Add each to its repo as a read-only deploy
   key (Settings → Deploy keys), then run again: that run clones the checkout
   at `deploy_repo` and makes the folders its containers write in
   (`deploy_owned_dirs`). A key taken off GitHub later sends that repo's
   fetches back the way they went before, at the next run. Add the age key
   the run printed to the repo's `.sops.yaml` and [re-seal](#re-sealing-secrets)
   its secrets.

Until a first run has finished, the admin user has no password, so a provider
console can't log in; after it, the console takes the sudo password.

## Every run after

For the existing servers, and a new one after its first run:

```sh
uv run ansible-playbook site.yml -e target=<name> -K
```

A second run changes nothing. `--check` shows what a run would change, without
the checks and Lynis, which need a real run, and without asking GitHub about
`deploy`'s read keys, so it shows no key, clone or switch to an alias;
`--skip-tags lynis,scan` skips the slow parts. A run cut off during a port move
finishes it the next time.

Keep a second SSH session open to the server for the whole of any run. The run
counts on it if the new port or a new sshd turns out not to take logins.

## Before the first run on dor-lomin and Rivendell

Read-only checks, each for something a replica couldn't show:

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
  `keys.yaml` first (see [Phones and tablets](#phones-and-tablets)), and the
  run refuses to turn password login off until every device listed there has
  a key. From the phone and the iPad, log in to dor-lomin with Blink before
  the run.
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
  naming it. The switch to the new key rewrites only URLs written
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

## What a run does

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

The only Claude Code plugin on the servers is pstack.

## Not yet, on purpose

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
- **Joining the tailnet**: on a server with `tailscale: true`, Tailscale is
  installed, not logged in.
- **esgaroth**: the run stops at its first check unless it runs Ubuntu or
  Debian, and before UFW goes on unless Tailscale is logged in there, since SSH
  then comes from the tailnet only. Its home-network ports in
  `ansible/hosts/esgaroth.yml` (Home Assistant's 8123 for now) need checking
  before its first run.
- **The deploy key** that can only ask the gate for a deploy. The steps are in
  [Moving a repo's deploy to the gate](#moving-a-repos-deploy-to-the-gate).

## Moving a repo's deploy to the gate

The deploy key that can only ask the gate for a deploy goes in, in this order.

1. Add the age key the run printed to the deploy repo's `.sops.yaml` and
   [re-seal](#re-sealing-secrets), since the gate decrypts with the server's
   own key.
2. Make the new key in 1Password, one per repo:
   `op item create --category "SSH Key" --title "hurin deploy key" --vault Private --ssh-generate-key ed25519`.
   Rivendell's is "rivendell deploy key". Put its public half
   (`op read "op://Private/hurin deploy key/public key"`) in the host file's
   `deploy_public_key` and run.
3. In the repo's settings, make an environment named `production` whose
   deployment branches are limited to `main` (Settings → Environments → New
   environment, then Deployment branches and tags → Selected branches →
   `main`): the deploy job runs in it, so no other branch's workflow can read
   the key. If `production` is already listed, a Deploy run made it by running
   first, with no branch rule; set the rule all the same.
4. Set the secret there straight from 1Password, so the private half never
   touches a disk or the screen:
   `op read "op://Private/hurin deploy key/private key?ssh-format=openssh" | gh secret set VPS_SSH_KEY --env production -R ctejada10/hurin`.
   The same line sets it again when a repo is recreated.
5. Add the Actions variables the gate's workflow reads: `VPS_HOST`,
   `VPS_PORT` and `VPS_USER`, which today's workflow reads as secrets (Húrin's
   writes its port in as 6969), and `VPS_HOST_KEY`, set to what the run
   printed.
6. Only then merge the change that moves the repo's Deploy workflow to the
   gate, while no Deploy run is in progress: the old workflow's runs neither
   wait in the new one's queue nor take the gate's lock. The first deploy
   through the gate is the Deploy run that starts by itself once CI passes on
   the merge (Húrin's CI takes 11 to 14 minutes); a Run workflow before the
   merge runs the old workflow and proves nothing about the gate. If that run
   stops on a setting, fix it and re-run it. The repo's commits need an
   executable `scripts/deploy.sh`, or the gate refuses them.
7. Once it passes, on dor-lomin run `docker builder prune -af` once as
   `deploy`: deploys before the gate left the decrypted files in Docker's
   build cache.
8. Delete the repository-level secrets today's workflow used, which the
   gate's doesn't read: `VPS_SSH_KEY` (today's key), `SOPS_AGE_KEY` (the age
   key it decrypts with), `VPS_HOST`, `VPS_USER`, and `HEALTH_API_KEY` on
   Húrin or `VPS_PORT` on Rivendell. Until they are gone, re-running a Deploy
   run from before the merge runs the old workflow, around the gate.
9. Put today's unrestricted key in `deploy_retired_keys` and run again, which
   takes it out.
10. The keys `deploy` fetched with before stay on GitHub until you delete
    them. A run that couldn't ask GitHub still passes, and so does a deploy on
    the old key, so go by the list the run prints at its end ("Say where each
    repo deploy fetches stands"): each repo there must say GitHub takes its
    read key and Git fetches it through its alias.
    `sudo -u deploy git -C <deploy_repo> remote get-url origin` then prints
    `git@github-hurin:ctejada10/hurin.git` (on Rivendell
    `git@github-rivendell:ctejada10/rivendell.git`, and in
    `~deploy/rivendell/arwen` `git@github-arwen:ctejada10/arwen.git`). Once a
    run has passed with every line saying so and a deploy through the gate
    has passed, delete hurin's `hurin-server-repo-access`, rivendell's
    `github-actions-deploy` and arwen's `deploy@rivendell` (Settings → Deploy
    keys). rivendell's can also push, so check its last use there first for a
    push nothing explains.

## Phones and tablets

Each phone and tablet logs in to the servers and the mini with a key of its
own, held by Blink Shell. The iPhone's and the iPad's are RSA keys, not Secure
Enclave ones. For a new device, make the key in the Secure Enclave, so its
private half never leaves the device.

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
4. From the device, log in to each server and to the mini. For the mini, and
   for esgaroth, the device needs Tailscale and a host in Blink, as
   [SSH from the iPhone and iPad](setup-mini.md#ssh-from-the-iphone-and-ipad)
   describes.

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

### Everything lost

The login key lives in 1Password, not on the laptop. On any Mac, sign in to
1Password and turn on its SSH agent (Settings, Developer), and to Tailscale for
esgaroth and the mini, then log in as from the laptop and add the new devices'
keys. If SSH itself fails, Rivendell's and dor-lómin's provider consoles take
the admin user and its sudo password, also in 1Password.

## Re-sealing secrets

Once each repo's first re-seal is done, every sealed file in Húrin and
Rivendell opens with two keys: the personal age key, which lives only in
1Password as "dotfiles age key" (its public half is in
`home/.chezmoidata/keys.yaml`), and the key of the server it deploys to, which
the playbook makes on that server and whose public half its run prints. No Mac
keeps the personal key on disk. On the mini, 1Password's CLI integration stays
off except during a re-seal or a MonoLisa upgrade, Claude Code denies `op`, and
the rules every agent there reads (`~/.codex/AGENTS.md`, Codex's and Claude
Code's alike) forbid it. To add a server's key, replace a server or drop an
old key:

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
first. sops picks a `.sops.yaml` rule by the name it's given, here the sealed
file's, and Rivendell's rule and Húrin's rules for the job list and the two
settings files match only the plaintext names, so `updatekeys` stops with "no
matching creation rules found". And Húrin's whole-file blobs need
`--input-type binary`, or sops writes them back as YAML, which the deploy's
`sops --decrypt --input-type=binary` can't read.

## Adding or renaming a server

**Adding one.** Choose its name, then add it to `home/.chezmoidata/hosts.yaml`,
which the laptop's SSH config and the Ansible inventory both come from, and
give it `ansible/hosts/<name>.yml` and a line in `ansible/packages.yml`. No
template changes. Then follow [A new server](#a-new-server).

**Renaming one.** Run `chezmoi init --prompt` on it, give the new name, then
`chezmoi apply`. Then check by hand:

- DNS, and the deploy workflows' host variables;
- the names Plex and Samba show;
- the old name's lines in `~/.ssh/known_hosts` on the laptop and the devices.
