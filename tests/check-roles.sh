#!/usr/bin/env bash
# What each role gets, and what it must never get. Checks the target state
# chezmoi computes, not the source files, so a template mistake shows up here.

set -uo pipefail
. "$(dirname "$0")/lib.sh"

# managed <role>: the target paths that role would get.
managed() {
  sandbox "$1" >/dev/null 2>&1
  cz managed --include=all --path-style=relative 2>/dev/null | sort
  cleanup_sandbox
}

# Paths no role may ever manage: written by tools, or holding secrets.
never='^((\.claude\.json|\.claude/(\.credentials\.json|backups|cache|file-history|history\.jsonl|ide|MAINTENANCE\.md|paste-cache|plans|plugins|projects|scheduled-tasks|session-env|sessions|settings\.local\.json|setup-intake\.md|shell-snapshots|skills/synced|spares|state|statsig|telemetry|todos|uploads)|\.claude/\.ponytail-[^/]*|\.claude/ponytail-statusline\.sh|\.claude/skills/no-mistakes|\.agents|\.no-mistakes|\.colima|\.docker/config\.json|firstmate|\.local/share/firstmate|\.treehouse|worktrees|Library/Application Support/email-workflow|\.claude-api|\.t3|\.codex/auth\.json|\.hermes/\.env|\.config/(gh|op|rclone|sops)|Library/Application Support/sops|\.ssh/known_hosts|\.ssh/[^/]*_signing|\.ssh/id_[^/]*|\.ssh/arnor(_claude)?)(/.*)?|agent-drafts/.+)$'

has()   { grep -qxF "$2" <<< "$1"; }
lacks() { ! grep -qxF "$2" <<< "$1"; }

roles=(ci laptop agent-mini)
[ "$(uname)" = Linux ] && roles=(ci server)

for role in "${roles[@]}"; do
  section "role $role"
  list=$(managed "$role")
  bad=$(grep -E "$never" <<< "$list" || true)
  if [ -z "$bad" ]; then pass "manages nothing on the never list"; else fail "manages nothing on the never list" "$bad"; fi

  case "$role" in
    laptop)
      lacks "$list" ".claude/pstack-models.md" && pass "has no pstack model sheet" || fail "has no pstack model sheet"
      has "$list" ".claude/rules/job-search.md" && pass "has the job-search rules" || fail "has the job-search rules"
      bad=$(grep -E '^\.codex|^\.claude/(skills/(rpi-|grill|to-spec|i-have-adhd|github-actions|openscad|read-only-log|frontend-e2e|codebase-design|domain-modeling|improve-codebase|writing-for-agents)|agents/(rpi-|ecc-))|^\.local/share/(openscad|georgeskills|dotfiles/git/read)' <<< "$list" | grep -v '^\.local/share/dotfiles/git/read-only-hooks' || true)
      [ -z "$bad" ] && pass "has no development rules, skills, agents or tools" || fail "has no development rules, skills, agents or tools" "$bad"
      has "$list" "Library/CloudStorage/Dropbox/config-files/1Password/ssh/agent.toml" \
        && pass "writes 1Password's agent.toml into Dropbox's config-files" || fail "writes 1Password's agent.toml into Dropbox's config-files"
      has "$list" ".config" && pass "manages the ~/.config link" || fail "manages the ~/.config link"
      grep -q '^\.config/' <<< "$list" && fail "manages nothing inside ~/.config" "$(grep '^\.config/' <<< "$list")" || pass "manages nothing inside ~/.config"
      lacks "$list" ".ssh/authorized_keys" && pass "has no authorized_keys" || fail "has no authorized_keys"
      lacks "$list" "agent-drafts" && pass "has no agent-drafts" || fail "has no agent-drafts"
      ;;
    agent-mini)
      lacks "$list" ".claude/pstack-models.md" && pass "has no pstack model sheet" || fail "has no pstack model sheet"
      grep -q 'Dropbox/config-files' <<< "$list" && fail "writes nothing into Dropbox's config-files" || pass "writes nothing into Dropbox's config-files"
      grep -q '^\.config' <<< "$list" && fail "keeps a local ~/.config, untouched" || pass "keeps a local ~/.config, untouched"
      has "$list" "agent-drafts" && pass "has agent-drafts" || fail "has agent-drafts"
      # The laptop logs in to the mini with its 1Password login key, and the
      # phone and the iPad each with their own key once keys.yaml holds it.
      login_pub=$(sed -n '/^  login:/,/^  signing:/s/^    public: "\(.*\)"$/\1/p' "$REPO/home/.chezmoidata/keys.yaml")
      sandbox agent-mini >/dev/null 2>&1
      ak=$(cz --override-data '{"ssh":{"devices":{"iphone":"","ipad":""}}}' cat "$SANDBOX/home/.ssh/authorized_keys" 2>/dev/null)
      ak_device=$(cz --override-data '{"ssh":{"devices":{"iphone":"ecdsa-sha2-nistp256 AAAAtest iphone","ipad":""}}}' \
        cat "$SANDBOX/home/.ssh/authorized_keys" 2>/dev/null)
      cleanup_sandbox
      [ -n "$login_pub" ] && [ "$ak" = "$login_pub" ] \
        && pass "authorizes only the laptop's login key while no device has one" \
        || fail "authorizes only the laptop's login key while no device has one" "$ak"
      [ "$ak_device" = "$login_pub"$'\n'"ecdsa-sha2-nistp256 AAAAtest iphone" ] \
        && pass "authorizes a device's key once keys.yaml holds it" \
        || fail "authorizes a device's key once keys.yaml holds it" "$ak_device"
      grep -q '^src/' <<< "$list" && fail "has no ~/src externals" || pass "has no ~/src externals"
      lacks "$list" ".claude/skills/draft-email-reply/SKILL.md" && pass "has no personal skills" || fail "has no personal skills"
      lacks "$list" ".claude/rules/job-search.md" && pass "has no job-search rules" || fail "has no job-search rules"
      for path in .codex/AGENTS.md .claude/skills/rpi-create-plan/SKILL.md \
                  .claude/skills/grill-me/SKILL.md .claude/agents/ecc-python-reviewer.md \
                  .claude/skills/github-actions-hardening/SKILL.md .claude/skills/openscad-bosl2 \
                  .local/share/openscad/libraries/BOSL2 .local/share/georgeskills; do
        has "$list" "$path" && pass "has $path" || fail "has $path"
      done
      ;;
    server)
      has "$list" ".claude/pstack-models.md" && pass "has the pstack model sheet" || fail "has the pstack model sheet"
      grep -q '^\.ssh' <<< "$list" && fail "has nothing under ~/.ssh" || pass "has nothing under ~/.ssh"
      grep -q '^src/' <<< "$list" && fail "has no ~/src repos" || pass "has no ~/src repos"
      ;;
  esac
done

if [ "$(uname)" = Darwin ]; then
  section "the mini's remote access"
  settings_tmpl="$REPO/home/.chezmoiscripts/run_after_30-macos-settings.sh.tmpl"
  sandbox agent-mini >/dev/null 2>&1
  mini=$(cz execute-template < "$settings_tmpl" 2>/dev/null)
  cleanup_sandbox
  sandbox laptop >/dev/null 2>&1
  laptop=$(cz execute-template < "$settings_tmpl" 2>/dev/null)
  cleanup_sandbox
  for line in "PasswordAuthentication no" "KbdInteractiveAuthentication no" "PermitRootLogin no" \
              "AuthenticationMethods publickey" "AllowUsers \$me\""; do
    grep -qxF "$line" <<< "$mini" && pass "the mini's sshd drop-in sets $line" || fail "the mini's sshd drop-in sets $line"
  done
  # The account the apply runs as, which is the one the laptop's key is in.
  grep -qxF "me=\"$(id -un)\"" <<< "$mini" && pass "the drop-in and both lists name the account the apply runs as" \
    || fail "the drop-in and both lists name the account the apply runs as" "$(grep '^me=' <<< "$mini")"
  grep -qx 'UsePAM.*' <<< "$mini" && fail "the mini leaves UsePAM to Apple" || pass "the mini leaves UsePAM to Apple"
  # sshd reads sshd_config.d in lexical order and keeps the first value.
  dropin=$(sed -n 's|^keyonly=/etc/ssh/sshd_config.d/||p' <<< "$mini")
  [ -n "$dropin" ] && [ "$(printf '%s\n' "$dropin" 100-macos.conf | LC_ALL=C sort | head -1)" = "$dropin" ] \
    && pass "the drop-in sorts before Apple's 100-macos.conf" || fail "the drop-in sorts before Apple's 100-macos.conf" "$dropin"
  for group in ssh screensharing; do
    grep -qx "only_me $group .*" <<< "$mini" && pass "the mini limits com.apple.access_$group to its account" \
      || fail "the mini limits com.apple.access_$group to its account"
  done
  # The calls whole, in order: block-all off, then the firewall and stealth
  # mode on, each with the text socketfilterfw prints when it's right.
  calls=$(grep '^fw_ensure ' <<< "$mini")
  want_calls='fw_ensure --getblockall --setblockall off "set to disabled" "the firewall'"'"'s block-all"
fw_ensure --getglobalstate --setglobalstate on "State = [12]" "the firewall"
fw_ensure --getstealthmode --setstealthmode on "mode is on" "stealth mode"'
  [ "$calls" = "$want_calls" ] \
    && pass "the mini turns block-all off before the firewall on, then stealth mode" \
    || fail "the mini turns block-all off before the firewall on, then stealth mode" "$calls"
  grep -q -- '--setblockall on' <<< "$mini" && fail "the mini never turns block-all on" || pass "the mini never turns block-all on"
  # Stealth mode set while the firewall's own change is still landing never
  # takes effect, so every change waits before the next.
  sed -n '/^fw_ensure() {$/,/^}$/p' <<< "$mini" | grep -qE '^ +sleep [1-9]' \
    && pass "the mini lets each firewall change land before the next" \
    || fail "the mini lets each firewall change land before the next"
  # Code, not comments: the laptop renders none of it.
  [ -n "$laptop" ] && ! grep -qE '^ *(only_me|fw_ensure) |dseditgroup|socketfilterfw|keyonly=' <<< "$laptop" \
    && pass "the laptop's SSH, sharing lists and firewall are left alone" \
    || fail "the laptop's SSH, sharing lists and firewall are left alone"

  # The playbook connects to each server's address, so the laptop's Host line
  # has to match it too, or the run offers every key the agent holds.
  section "the laptop's SSH config"
  sandbox laptop >/dev/null 2>&1
  config=$(cz execute-template < "$REPO/home/private_dot_ssh/config.tmpl" 2>/dev/null)
  pairs=$(cz execute-template '{{ range $n, $h := .hosts }}{{ $n }} {{ $h.address }}{{ "\n" }}{{ end }}' 2>/dev/null)
  cleanup_sandbox
  while read -r name address; do
    [ -n "$name" ] || continue
    if [ "$name" = "$address" ]; then want="Host $name"; else want="Host $name $address"; fi
    grep -qxF "$want" <<< "$config" && pass "$name's Host line matches what the playbook connects to" \
      || fail "$name's Host line matches what the playbook connects to" "$(grep "^Host $name" <<< "$config")"
  done <<< "$pairs"
fi

# Hand checks pasted from the READMEs expect plain cat on the servers. Each
# role inits only on its own OS, and a template that didn't render would pass
# the server's check unseen, so both count as failures.
section "cat is plain on servers"
for role in "${roles[@]}"; do
  if ! sandbox "$role" >/dev/null 2>&1; then
    fail "init as $role"
    cleanup_sandbox
    continue
  fi
  if ! aliases=$(cz execute-template < "$REPO/home/dot_zsh/aliases.zsh.tmpl" 2>&1); then
    fail "aliases.zsh renders as $role" "$aliases"
    cleanup_sandbox
    continue
  fi
  cleanup_sandbox
  if [ "$role" = server ]; then
    grep -q 'alias cat=' <<< "$aliases" && fail "the server role has no cat alias" || pass "the server role has no cat alias"
  else
    grep -q 'alias cat="bat"' <<< "$aliases" && pass "the $role role keeps cat as bat" || fail "the $role role keeps cat as bat"
  fi
done

section "Claude Code plugins per role"
for role in "${roles[@]}"; do
  sandbox "$role" >/dev/null 2>&1
  settings=$(cz cat "$SANDBOX/home/.claude/settings.json" 2>/dev/null)
  list=$(cz managed --include=all --path-style=relative 2>/dev/null)
  cleanup_sandbox
  plugins=$(jq -r '(.enabledPlugins // {}) | to_entries | map(select(.value == true) .key) | join(" ")' <<< "$settings")
  [ "$(jq -c '.attribution' <<< "$settings")" = '{"commit":"","pr":"","sessionUrl":false}' ] \
    && pass "$role: Claude Code adds no AI attribution" || fail "$role: Claude Code adds no AI attribution" "$(jq -c '.attribution' <<< "$settings")"
  case "$role" in
    laptop)
      # Personal work and job hunting only; development happens on the mini.
      lacks "$list" ".claude/hooks/guard-git.py" && pass "laptop has no git guard" || fail "laptop has no git guard"
      grep -q 'claude-plugins\|agent-gate\|attended.md' <<< "$list" && fail "laptop has no superpowers" || pass "laptop has no superpowers"
      grep -qE '^\.local/bin/worktree-ttl$|LaunchAgents/com\.carlosetejada\.worktree-ttl' <<< "$list" \
        && fail "laptop has no worktree cleanup job" || pass "laptop has no worktree cleanup job"
      grep -qE '^\.local/bin/repo-snapshots$|LaunchAgents/com\.carlosetejada\.repo-snapshots' <<< "$list" \
        && fail "laptop has no snapshot job" || pass "laptop has no snapshot job"
      grep -qE '^\.local/bin/git$|read-only-hooks|agent-owned' <<< "$list" \
        && fail "laptop has no read-only guard left" || pass "laptop has no read-only guard left"
      [ "$plugins" = "freehire@freehire humanizer@humanizer obsidian@obsidian-skills" ] \
        && pass "laptop enables only job-hunting and personal plugins" || fail "laptop enables only job-hunting and personal plugins" "$plugins"
      ;;
    agent-mini)
      on=$(jq -r '(.enabledPlugins // {}) | to_entries | map(select(.value == true) .key) | join(" ")' <<< "$settings")
      for p in ponytail@ponytail andrej-karpathy-skills@karpathy-skills \
               agnix@agentsys property-based-testing@trailofbits supply-chain-risk-auditor@trailofbits \
               ty-python-lsp@claude-community; do
        grep -qw "$p" <<< "$on" && pass "the mini enables $p" || fail "the mini enables $p" "$on"
      done
      # t3-pstack routes; superpowers is a skill library from the local marketplace.
      [ "$(jq -r '.enabledPlugins["superpowers@sp-gated"]' <<< "$settings")" = true ] \
        && pass "the mini enables superpowers from its local marketplace" || fail "the mini enables superpowers from its local marketplace"
      [ "$(jq -r '.enabledPlugins["superpowers@claude-plugins-official"]' <<< "$settings")" = false ] \
        && pass "the mini keeps the official superpowers off" || fail "the mini keeps the official superpowers off"
      jq -e '.extraKnownMarketplaces["sp-gated"].source | .source == "directory" and (.path | endswith("/.local/share/claude-plugins/sp-gated"))' <<< "$settings" >/dev/null \
        && pass "the local marketplace is declared" || fail "the local marketplace is declared"
      jq -e '.permissions.deny | index("Skill(superpowers:using-superpowers)")' <<< "$settings" >/dev/null \
        && pass "superpowers' bootstrap skill is denied" || fail "superpowers' bootstrap skill is denied"
      jq -e '.hooks.SessionStart[].hooks[] | select(.command | endswith("/agent-gate.sh"))' <<< "$settings" >/dev/null \
        && jq -e '.hooks.PreToolUse[] | select(.matcher == "Skill|AskUserQuestion") | .hooks[] | select(.command | endswith("/agent-gate.sh"))' <<< "$settings" >/dev/null \
        && pass "the gate runs at session start and before Skill and AskUserQuestion" || fail "the gate runs at session start and before Skill and AskUserQuestion"
      has "$list" ".local/share/claude-plugins/sp-gated/.claude-plugin/marketplace.json" \
        && pass "the mini has the local marketplace" || fail "the mini has the local marketplace"
      mkt="$REPO/home/dot_local/share/claude-plugins/sp-gated/dot_claude-plugin/marketplace.json"
      jq -e '.plugins[0].hooks.SessionStart[0].hooks[0].command | startswith("[ \"${SP_BOOTSTRAP:-0}\" = 1 ] || exit 0;")' "$mkt" >/dev/null \
        && pass "the marketplace entry silences superpowers' session hook" || fail "the marketplace entry silences superpowers' session hook"
      jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | endswith("/guard-git.py"))' <<< "$settings" >/dev/null \
        && pass "the mini runs the git guard" || fail "the mini runs the git guard"
      has "$list" ".claude/hooks/guard-git.py" && pass "the mini has the git guard" || fail "the mini has the git guard"
      # Every deployed agent or shell file is behind an Edit deny.
      uncovered=$(grep -E '^(\.codex/|\.claude/(settings\.json|CLAUDE\.md|attended\.md|hooks/|skills/|agents/)|\.local/share/claude-plugins/|\.gitconfig$|\.zshrc$|\.zshenv$|\.zprofile$|\.zsh/)' <<< "$list" | while read -r path; do
        jq -e --arg p "$path" --arg h "$HOME" '[.permissions.deny[] | select(startswith("Edit(/"))
          | ltrimstr("Edit(/") | rtrimstr(")") | ltrimstr($h + "/")] as $rules
          | any($rules[]; . == $p or (endswith("/**") and ($p | startswith(rtrimstr("/**")))))' <<< "$settings" >/dev/null || echo "$path"
      done)
      [ -z "$uncovered" ] && pass "agents can't edit the deployed config" || fail "agents can't edit the deployed config" "$uncovered"
      jq -e '[.permissions.deny[] | select(startswith("Write("))] | length == 0' <<< "$settings" >/dev/null \
        && pass "no Write deny rules, which match nothing" || fail "no Write deny rules, which match nothing"
      jq -e '.permissions.deny | index("Bash(gh repo view:*)") | not' <<< "$settings" >/dev/null \
        && pass "gh can still read" || fail "gh can still read"
      jq -e '.permissions.deny | index("Bash(op:*)")' <<< "$settings" >/dev/null \
        && pass "agents can't read 1Password, so never the personal age key" || fail "agents can't read 1Password, so never the personal age key"
      sandbox agent-mini >/dev/null 2>&1
      sshcfg=$(cz cat "$SANDBOX/home/.ssh/config" 2>/dev/null)
      cz cat "$SANDBOX/home/.claude/hooks/guard-paths.sh" > "$SANDBOX/guard-paths.sh" 2>/dev/null
      # Rendered from a dotfiles worktree, as `chezmoi --source <worktree> diff`
      # does, the hook must come out the same, or every such diff shows it.
      elsewhere=$(mktemp -d)
      tmpl="$REPO/home/dot_claude/hooks/executable_guard-paths.sh.tmpl"
      [ "$(cz execute-template < "$tmpl")" = "$(cz --working-tree "$elsewhere" execute-template < "$tmpl")" ] \
        && pass "the path guard renders the same from a worktree" || fail "the path guard renders the same from a worktree"
      rmdir "$elsewhere"
      # With a final "." kept, so a trailing blank line shows: it is one line.
      mini_claude=$(cz cat "$SANDBOX/home/.claude/CLAUDE.md" 2>/dev/null; echo .)
      gp() { printf '{"tool_input":{"file_path":"%s"}}' "$1" | AGENT_ATTENDED="$2" bash "$SANDBOX/guard-paths.sh" >/dev/null 2>&1; }
      gp "$HOME/.local/share/chezmoi/home/dot_zshrc" 0 && fail "the mini never edits the dotfiles checkout" || pass "the mini never edits the dotfiles checkout"
      gp "$HOME/worktrees/dotfiles/fix/home/dot_zshrc" 0 && pass "it edits a dotfiles worktree" || fail "it edits a dotfiles worktree"
      gp "$HOME/src/hurin/x.py" 0 && fail "the mini never edits its own repos' main checkouts" || pass "the mini never edits its own repos' main checkouts"
      gp "$HOME/src/hurin/x.py" 1 && fail "not even when Carlos is there" || pass "not even when Carlos is there"
      gp "$HOME/SRC/Hurin/x.py" 0 && fail "nor through a differently cased path" || pass "nor through a differently cased path"
      gp "$HOME/worktrees/hurin/fix/x.py" 0 && pass "it edits them in a worktree" || fail "it edits them in a worktree"
      has "$list" ".local/bin/worktree-ttl" && has "$list" "Library/LaunchAgents/com.carlosetejada.worktree-ttl.plist" \
        && pass "the mini has the worktree cleanup job" || fail "the mini has the worktree cleanup job"
      has "$list" ".local/bin/repo-snapshots" && has "$list" "Library/LaunchAgents/com.carlosetejada.repo-snapshots.plist" \
        && pass "the mini has the snapshot job" || fail "the mini has the snapshot job"
      dbx="$HOME/Library/CloudStorage/Dropbox/repositories"
      gp "$dbx/career-ops/x.md" 0 && fail "the mini never edits a repo in Dropbox's old repositories folder" || pass "the mini never edits a repo in Dropbox's old repositories folder"
      gp "${dbx/CloudStorage/cloudstorage}/career-ops/x.md" 0 && fail "nor through a differently cased path there" || pass "nor through a differently cased path there"
      gp "$HOME/worktrees/career-ops/fix/x.md" 0 && pass "a clone of another repo in ~/worktrees is fine" || fail "a clone of another repo in ~/worktrees is fine"
      [ "$mini_claude" = "@~/.codex/AGENTS.md"$'\n'"." ] && pass "the mini's CLAUDE.md is the one line that imports the shared rules" \
        || fail "the mini's CLAUDE.md is the one line that imports the shared rules" "${mini_claude%.}"
      cleanup_sandbox
      [ "$(grep -v '^#' <<< "$sshcfg" | grep -v '^$' | head -n 1)" = "Include ~/.colima/ssh_config" ] \
        && pass "the mini's SSH config starts with Colima's Include" || fail "the mini's SSH config starts with Colima's Include" "$sshcfg"
      jq -e '.hooks.WorktreeCreate[0].hooks[0].command | endswith("/.claude/hooks/worktree.sh create")' <<< "$settings" >/dev/null \
        && pass "the mini's Claude Code worktrees go through the worktree hook" || fail "the mini's Claude Code worktrees go through the worktree hook" "$(jq -c .hooks <<< "$settings")"
      ask=$(jq -r '.permissions.ask | join(" ")' <<< "$settings")
      grep -q 'git commit\|git push\|gh pr create' <<< "$ask" \
        && fail "the mini's own-branch git work never waits on a prompt" "$ask" || pass "the mini's own-branch git work never waits on a prompt"
      grep -qw 'pstack@pstack-claude' <<< "$plugins" && fail "the mini leaves pstack to T3's t3-pstack" || pass "the mini leaves pstack to T3's t3-pstack"
      [ "$(jq -r '.env.PONYTAIL_DEFAULT_MODE' <<< "$settings")" = full ] \
        && pass "the mini runs Ponytail's full ruleset" || fail "the mini runs Ponytail's full ruleset"
      ;;
    server)
      [ "$plugins" = "pstack@pstack-claude" ] && pass "servers enable pstack only" || fail "servers enable pstack only" "$plugins"
      ;;
    ci)
      [ -z "$plugins" ] && pass "ci enables no plugins" || fail "ci enables no plugins" "$plugins"
      ;;
  esac
done

section "the laptop's settings keep what other tools wrote"
if [ "$(uname)" = Darwin ]; then
sandbox laptop arnor arnor >/dev/null 2>&1
mkdir -p "$SANDBOX/home/.claude"
printf '%s' '{"enabledPlugins":{"obsidian@obsidian-skills":true,"ty-python-lsp@claude-community":true},"hooks":{"PreToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"/opt/other/hook.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"/opt/other/stop.sh"}]}]}}' \
  > "$SANDBOX/home/.claude/settings.json"
settings=$(cz cat "$SANDBOX/home/.claude/settings.json" 2>/dev/null)
mkdir -p "$SANDBOX/again" && printf '%s' "$settings" > "$SANDBOX/home/.claude/settings.json"
again=$(cz cat "$SANDBOX/home/.claude/settings.json" 2>/dev/null)
cleanup_sandbox
[ "$(jq -r '.enabledPlugins["ty-python-lsp@claude-community"]' <<< "$settings")" = false ] \
  && pass "switches the old setup's development plugin off" || fail "switches the old setup's development plugin off"
jq -e '.hooks.PreToolUse[] | select(.matcher == "Read")' <<< "$settings" >/dev/null \
  && pass "keeps another tool's PreToolUse hook" || fail "keeps another tool's PreToolUse hook"
jq -e '.hooks.Stop' <<< "$settings" >/dev/null && pass "keeps another tool's Stop hook" || fail "keeps another tool's Stop hook"
[ "$(jq -c '.hooks' <<< "$settings")" = "$(jq -c '.hooks' <<< "$again")" ] \
  && pass "a second apply leaves the hooks as they are" || fail "a second apply leaves the hooks as they are"
[ "$(jq '[.hooks.PreToolUse[] | select(.matcher == "Bash")] | length' <<< "$again")" = 1 ] \
  && pass "a second apply adds no duplicate hook" || fail "a second apply adds no duplicate hook"
fi

section "the mini keeps what t3-pstack's installer writes"
if [ "$(uname)" = Darwin ]; then
sandbox agent-mini >/dev/null 2>&1
mkdir -p "$SANDBOX/home/.claude"
printf '%s' '{"enabledPlugins":{"t3-pstack@t3-pstack":true},"extraKnownMarketplaces":{"t3-pstack":{"source":{"source":"github","repo":"chhoumann/t3-pstack"},"autoUpdate":true}}}' \
  > "$SANDBOX/home/.claude/settings.json"
settings=$(cz cat "$SANDBOX/home/.claude/settings.json" 2>/dev/null)
cleanup_sandbox
[ "$(jq -r '.enabledPlugins["t3-pstack@t3-pstack"]' <<< "$settings")" = true ] \
  && pass "t3-pstack stays enabled" || fail "t3-pstack stays enabled"
[ "$(jq -r '.extraKnownMarketplaces["t3-pstack"].source.repo' <<< "$settings")" = chhoumann/t3-pstack ] \
  && pass "its marketplace source stays" || fail "its marketplace source stays"
[ "$(jq -r '.extraKnownMarketplaces["t3-pstack"].autoUpdate' <<< "$settings")" = false ] \
  && pass "its auto-update is off" || fail "its auto-update is off"
fi

section "the pstack model sheet"
sheet="$REPO/home/dot_claude/pstack-models.md"
grep -qx 'session hook: off' "$sheet" && pass "says session hook: off" || fail "says session hook: off"
grep -qi 'fable' "$sheet" && fail "has no fable line" "$(grep -i fable "$sheet")" || pass "has no fable line"

section "chezmoi update pulls fast-forward only"
for role in "${roles[@]}"; do
  sandbox "$role" >/dev/null 2>&1
  update=$(cz dump-config --format json 2>/dev/null | jq -c '.update | [.command, .args]')
  cleanup_sandbox
  [ "$update" = '["git",["pull","--ff-only"]]' ] \
    && pass "$role runs git pull --ff-only" || fail "$role runs git pull --ff-only" "$update"
done

section "the CLAUDE.md include"
for role in "${roles[@]}"; do
  sandbox "$role" >/dev/null 2>&1
  out=$(cz cat "$SANDBOX/home/.claude/CLAUDE.md" 2>/dev/null)
  cleanup_sandbox
  case "$role" in
    server) grep -qx '@~/.claude/pstack-models.md' <<< "$out" && pass "$role includes the sheet" || fail "$role includes the sheet" ;;
    *)             grep -q 'pstack-models' <<< "$out" && fail "$role leaves the sheet out" || pass "$role leaves the sheet out" ;;
  esac
done

section "the mini's Git config"
if [ "$(uname)" = Darwin ]; then
  sandbox agent-mini >/dev/null 2>&1
  gitconfig=$(cz cat "$SANDBOX/home/.gitconfig" 2>/dev/null)
  cleanup_sandbox
  # `gh auth setup-git` writes an empty helper as "helper = " with a trailing
  # space. If the template loses it, every apply after gh runs shows a diff.
  [ "$(grep -c $'^\thelper = $' <<< "$gitconfig")" = 2 ] \
    && pass "keeps gh's empty helper lines exactly" || fail "keeps gh's empty helper lines exactly"
  grep -qx $'\thelper = !/opt/homebrew/bin/gh auth git-credential' <<< "$gitconfig" \
    && pass "uses gh as the credential helper" || fail "uses gh as the credential helper"
  grep -c -F '[includeIf "gitdir/i:' <<< "$gitconfig" | grep -qx 1 \
    && pass "has one includeIf, for Dropbox's old repositories folder" || fail "has one includeIf, for Dropbox's old repositories folder" "$(grep -A1 -F '[includeIf' <<< "$gitconfig")"
  grep -qx $'\tinsteadOf = git@github.com:' <<< "$gitconfig" \
    && pass "rewrites SSH GitHub URLs to HTTPS" || fail "rewrites SSH GitHub URLs to HTTPS"
  grep -qx $'\tprogram = ssh-keygen' <<< "$gitconfig" \
    && pass "signs with ssh-keygen, not 1Password" || fail "signs with ssh-keygen, not 1Password"

  # With real Git: a repo still in a stand-in Dropbox repositories folder, and
  # a clone in ~/src. Physical paths, because Git matches includeIf against
  # the resolved .git path and expands ~ from HOME.
  sandbox agent-mini >/dev/null 2>&1
  cz apply --exclude=scripts,externals >/dev/null 2>&1
  home="$(cd "$SANDBOX/home" && pwd -P)"
  old="$home/Library/CloudStorage/Dropbox/repositories"
  mkdir -p "$old" "$home/src"
  GIT_CONFIG_GLOBAL=/dev/null git -C "$old" init -q oldrepo
  GIT_CONFIG_GLOBAL=/dev/null git -C "$home/src" init -q clone
  gcv() { HOME="$home" GIT_CONFIG_NOSYSTEM=1 git -C "$1" config --get "$2"; }
  [ "$(gcv "$old/oldrepo" gc.auto)" = 0 ] && pass "no automatic gc in a repo still in Dropbox" || fail "no automatic gc in a repo still in Dropbox" "$(gcv "$old/oldrepo" gc.auto)"
  [ "$(gcv "$old/oldrepo" core.fsmonitor)" = false ] && pass "nor an fsmonitor daemon there" || fail "nor an fsmonitor daemon there"
  [ -z "$(gcv "$home/src/clone" gc.auto)" ] && pass "gc runs as usual in a clone in ~/src" || fail "gc runs as usual in a clone in ~/src" "$(gcv "$home/src/clone" gc.auto)"
  list=$(cz managed --include=all --path-style=relative 2>/dev/null)
  cleanup_sandbox
  lacks "$list" "src" && lacks "$list" "Repositories" \
    && pass "the mini's ~/src and ~/Repositories aren't links chezmoi makes" || fail "the mini's ~/src and ~/Repositories aren't links chezmoi makes"
fi

section "the laptop's repos"
if [ "$(uname)" = Darwin ]; then
  sandbox laptop arnor arnor >/dev/null 2>&1
  list=$(cz managed --include=all --path-style=relative 2>/dev/null)
  settings=$(cz cat "$SANDBOX/home/.claude/settings.json" 2>/dev/null)
  clone=$(cz execute-template < "$REPO/home/.chezmoiscripts/run_after_50-clone-repos.sh.tmpl" 2>/dev/null)
  cleanup_sandbox
  lacks "$list" "src" && pass "chezmoi no longer links ~/src into Dropbox" || fail "chezmoi no longer links ~/src into Dropbox"
  grep -q "ctejada10/cv" <<< "$clone" && grep -q "ctejada10/scripts" <<< "$clone" && ! grep -q "ctejada10/hurin" <<< "$clone" \
    && pass "it clones cv and scripts, and none of the mini's other repos" || fail "it clones cv and scripts, and none of the mini's other repos"
  jq -e '.permissions.allow | index("Bash(git fetch:*)")' <<< "$settings" >/dev/null \
    && pass "Claude Code may fetch, with no .git shared through Dropbox" || fail "Claude Code may fetch, with no .git shared through Dropbox"
fi

section "a wiped laptop, before Dropbox has synced"
if [ "$(uname)" = Darwin ]; then
  SANDBOX_DROPBOX=none sandbox laptop arnor arnor >/dev/null 2>&1
  list=$(cz managed --include=all --path-style=relative 2>/dev/null)
  lacks "$list" ".config" && pass "holds the ~/.config link back" || fail "holds the ~/.config link back"
  grep -q '^Library/CloudStorage/Dropbox' <<< "$list" && fail "writes nothing into Dropbox yet" || pass "writes nothing into Dropbox yet"
  cleanup_sandbox

  # Dropbox has synced, but ~/.config is still the real folder init wrote.
  sandbox laptop arnor arnor >/dev/null 2>&1
  mkdir -p "$SANDBOX/home/.config/chezmoi" && touch "$SANDBOX/home/.config/chezmoi/chezmoi.toml"
  cz execute-template < "$REPO/home/.chezmoiscripts/run_before_00-preflight.sh.tmpl" > "$SANDBOX/preflight.sh"
  HOME="$SANDBOX/home" bash "$SANDBOX/preflight.sh" >/dev/null 2>&1 \
    && fail "the preflight stops before a real ~/.config is replaced" || pass "the preflight stops before a real ~/.config is replaced"
  [ -f "$SANDBOX/home/.config/chezmoi/chezmoi.toml" ] && pass "and leaves it as it was" || fail "and leaves it as it was"
  rm -rf "$SANDBOX/home/.config"
  mkdir -p "$SANDBOX/home/src/cv"
  HOME="$SANDBOX/home" bash "$SANDBOX/preflight.sh" >/dev/null 2>&1 \
    && pass "the preflight passes a real ~/src with repos in it" || fail "the preflight passes a real ~/src with repos in it"
  rm -rf "$SANDBOX/home/src"
  ln -s "$SANDBOX/home/Library/CloudStorage/Dropbox" "$SANDBOX/home/src"
  HOME="$SANDBOX/home" bash "$SANDBOX/preflight.sh" >/dev/null 2>&1 \
    && fail "the preflight stops while ~/src is still a link" || pass "the preflight stops while ~/src is still a link"
  [ -L "$SANDBOX/home/src" ] && [ -d "$SANDBOX/home/Library/CloudStorage/Dropbox/config-files" ] \
    && pass "and touches neither the link nor what it points to" || fail "and touches neither the link nor what it points to"
  rm "$SANDBOX/home/src"
  HOME="$SANDBOX/home" bash "$SANDBOX/preflight.sh" >/dev/null 2>&1 \
    && pass "the preflight passes once nothing would be replaced" || fail "the preflight passes once nothing would be replaced"

  # Folders macOS keeps private stay private.
  for d in Library "Library/Application Support" Library/CloudStorage/Dropbox Library/CloudStorage/Dropbox/config-files; do
    mkdir -p "$SANDBOX/home/$d" && chmod 700 "$SANDBOX/home/$d"
  done
  cz apply --exclude=scripts,externals >/dev/null 2>&1
  for d in Library "Library/Application Support" Library/CloudStorage/Dropbox Library/CloudStorage/Dropbox/config-files; do
    [ "$(stat -f %Lp "$SANDBOX/home/$d")" = 700 ] && pass "$d stays 0700" || fail "$d stays 0700" "$(stat -f %Lp "$SANDBOX/home/$d")"
  done
  cleanup_sandbox
fi

section "init refuses bad input"
SANDBOX="$(mktemp -d)"; mkdir -p "$SANDBOX/home"
cz init --promptChoice role=desktop --promptString hostname=x,displayName=x >/dev/null 2>&1 \
  && fail "an unknown role" || pass "an unknown role"
rm -f "$SANDBOX/chezmoi.toml"
cz init --promptChoice role=ci --promptString 'hostname=Dor-Lómin,displayName=x' >/dev/null 2>&1 \
  && fail "a hostname with capitals or accents" || pass "a hostname with capitals or accents"
rm -f "$SANDBOX/chezmoi.toml"
cz init --promptChoice role=ci --promptString 'hostname=a-name-that-is-too-long,displayName=x' >/dev/null 2>&1 \
  && fail "a hostname over 15 characters" || pass "a hostname over 15 characters"
rm -f "$SANDBOX/chezmoi.toml"
cz init --promptChoice role=ci --promptString 'hostname=amon-sul,displayName=Amon Sûl' >/dev/null 2>&1 \
  && pass "an accented display name" || fail "an accented display name"
cleanup_sandbox

summary
