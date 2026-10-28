#!/bin/bash
# SessionStart and PreToolUse (Skill, AskUserQuestion) hook, on the mini only.
# Decides whether Carlos is in the session and keeps superpowers' skills from
# waiting for Carlos when Carlos isn't there.
#
# Who is there:
#   attended    AGENT_ATTENDED=1, set by T3's "Claude (attended)" instance
#   firstmate   FM_TASK_ID is set, or the session runs in a FirstMate checkout
#   unattended  everything else: T3's default instance, a plain claude, and
#               the child threads and scheduled runs started from either
#
# A child thread or scheduled run started from an attended thread runs on the
# same T3 instance, and T3 hands it that instance's environment unchanged, so
# it carries AGENT_ATTENDED=1 and counts as attended here. Nothing in the
# environment or the hook's payload tells it from its parent, so this hook
# leaves that gap open, and ~/.codex/AGENTS.md tells such a session to work
# as unattended instead. The other hooks no longer give an attended session
# any write an unattended one lacks, so what the gap allows is a question or a
# brainstorm that waits for Carlos after Carlos has gone.
#
# What it does:
#   finishing-a-development-branch  refused everywhere: a branch always ends
#                                   pushed, with a draft PR
#   brainstorming                   attended only
#   other superpowers skills        unattended: a reminder not to wait
#   AskUserQuestion                 unattended: refused unless every question
#                                   starts with STOP:
#   SessionStart                    unattended: a note that nobody is watching
#
# Reads the hook's JSON with macOS's own plutil, so it needs nothing from
# Homebrew. The messages are one line of ASCII with no double quotes or
# backslashes, so they go into the JSON as they are.

set -u

PLUTIL=/usr/bin/plutil
input=$(cat)

get() {
  printf '%s' "$input" | "$PLUTIL" -extract "$1" raw -o - - 2>/dev/null
}

event=$(get hook_event_name)
[ -n "$event" ] || exit 0

mode=unattended
if [ "${AGENT_ATTENDED:-0}" = 1 ]; then
  mode=attended
elif [ -n "${FM_TASK_ID:-}" ]; then
  mode=firstmate
else
  cwd=$(get cwd)
  if [ -n "$cwd" ] && [ -f "$cwd/bin/fm-session-start.sh" ]; then
    mode=firstmate
  fi
fi

NOTE="Carlos is not watching this session and reads the result later in the draft PR. Do not wait for answers. When a skill or your own judgment calls for asking Carlos, decide instead: take your recommended answer and keep going. Pushing your own branch and opening a draft PR are pre-approved. Use AskUserQuestion only for the stops in your rules, and start each such question with STOP: so it reaches Carlos."

SKILL_CTX="Carlos is not watching this session. Wherever this skill says to ask your human partner, wait for review, get approval, or discuss before continuing, do not wait: decide and continue. Specs and plans go in ~/agent-drafts/<repo>/<branch>/, never in the repo. Execute plans with superpowers:subagent-driven-development. Work in the worktree and branch you were given and never create another; if you are in a repo's main checkout, make a worktree as your rules say instead of switching branches there. After three failed fixes, question the approach and test its premise, then either continue or stop with the dead end written up in the PR."

FM_SKILL_CTX="You are in a FirstMate crew. Wherever this skill says to ask your human partner or wait for approval, raise it to firstmate the way your brief says to raise ask-user findings instead of waiting in this pane."

DENY_FINISH="Carlos has already chosen how branches finish on this machine, so skip this menu. Run the full test suite. If it passes, push this branch and open a draft PR with gh pr create --draft whose body lists the work as your rules say, or update the body if a draft PR already exists. Never merge locally, never discard work, and leave the worktree in place. If the suite fails, fix it or write the failure up in the PR."

DENY_FINISH_FM="In a FirstMate crew, shipping follows your FirstMate brief, so skip this menu and do the brief's ship step. Never merge or discard work on your own."

DENY_BRAINSTORM="Carlos is not in this session, so superpowers:brainstorming would stall waiting for Carlos. Do not run it. Treat the request, issue, spec or plan you were given as the approved design. If the work is multi-step and has no design doc yet, write one to ~/agent-drafts/<repo>/<branch>/ with your recommended approach and how you settled its open questions, then continue with superpowers:writing-plans and execute the plan with superpowers:subagent-driven-development. Otherwise carry on with the task."

DENY_BRAINSTORM_FM="In a FirstMate crew, the FirstMate launch brief is the approved design, so skip brainstorming and continue with the brief. Raise anything only the captain can decide to firstmate the way your brief says."

DENY_ASK="Carlos is not watching this session, so this question would wait unseen. Decide it yourself: take your recommended answer and continue. Only if it is one of the stops in your rules, ask again with every question text starting STOP: and it will reach Carlos."

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

context() {
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$1" "$2"
  exit 0
}

case "$event" in
  SessionStart)
    [ "$mode" = unattended ] && context SessionStart "$NOTE"
    exit 0
    ;;
  PreToolUse)
    tool=$(get tool_name)
    case "$tool" in
      Skill)
        skill=$(get tool_input.skill)
        case "$skill" in
          superpowers:finishing-a-development-branch|finishing-a-development-branch)
            [ "$mode" = firstmate ] && deny "$DENY_FINISH_FM"
            deny "$DENY_FINISH"
            ;;
          superpowers:brainstorming|brainstorming)
            [ "$mode" = unattended ] && deny "$DENY_BRAINSTORM"
            [ "$mode" = firstmate ] && deny "$DENY_BRAINSTORM_FM"
            exit 0
            ;;
          superpowers:*)
            [ "$mode" = unattended ] && context PreToolUse "$SKILL_CTX"
            [ "$mode" = firstmate ] && context PreToolUse "$FM_SKILL_CTX"
            exit 0
            ;;
        esac
        exit 0
        ;;
      AskUserQuestion)
        [ "$mode" = unattended ] || exit 0
        i=0
        seen=0
        while q=$(get "tool_input.questions.$i.question"); do
          seen=1
          case "$q" in
            STOP:*) ;;
            *) deny "$DENY_ASK" ;;
          esac
          i=$((i + 1))
        done
        [ "$seen" = 1 ] || deny "$DENY_ASK"
        exit 0
        ;;
    esac
    ;;
esac
exit 0
