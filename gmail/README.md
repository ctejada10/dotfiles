# Gmail rules

The labels, filters and hand-offs for both Gmail accounts, as Google Apps
Script. Each account has its own project, and these files are their source.
chezmoi doesn't deploy this folder (`.chezmoiroot` is `home`).

| Account | Apps Script project | Files |
| --- | --- | --- |
| carlos@carlosetejada.com | Gmail Redesign (personal) | `Code.gs`, `Engine.gs`, `Rules.gs` |
| carlos@karejucar.com | Gmail Redesign (Karejucar) | `Code.gs` (rules and engine in one file) |

- `Rules.personal.gs.op`, `Rules.work.gs.op`: each account's `CONFIG`, meaning
  its labels, forwards and rules. A rule becomes one filter per label.
- `Engine.gs`: shared by both accounts. Its header lists the entry points:
  `dryRun`, `applyLabels`, `applyFilters`, `backfill`, `router`,
  `housekeeping`, `installTriggers`, `reviewDigest` and `unsubscribe`.
- `Survey.gs`: the read-only backup and sender inventory the redesign started
  from. It is the personal project's `Code.gs`.
- `appsscript.json`: the manifest. It lists every scope explicitly, because
  the editor's automatic scopes failed to authorize.

## How the rules behave

- Mail stays in the inbox by default. A rule archives only mail it recognises
  positively.
- Phrases have two or more words. A sender is matched by address when its
  domain also sends marketing. Each exclusion is its own `-term`, because
  negation doesn't distribute.
- Deletes go to Trash, which keeps mail for 30 days. Deletes are sender lists,
  plus multi-word phrases for legal notices and surveys. Each delete also adds
  the hidden label `_deleted`, so `has:nouserlabels in:trash` finds only mail
  deleted by hand.
- A child label is applied together with its parent.
- `_fwd/*` labels are hidden hand-offs. Every 10 minutes, `router()` forwards
  that mail and removes the label, so no forwarding address needs verifying.
- `expireDays` trashes old mail daily, except mail that is starred or labelled
  Todoist.
- Every client thread stays in the inbox, even when Carlos is only CC'd.

## Notifications

Mimestream notifies for a whole inbox or only its Primary category, never for a
label. So with `categorize: true`, a rule that applies Notify also puts the mail
in Primary, and any other rule that leaves mail in the inbox puts it in Updates.
Mimestream, set to notify for Primary Inbox, then pings for Notify mail. Mail
no rule touches keeps Gmail's own category, so people writing in usually ping
too.

Notify rules: on personal, money problems, travel changes, delivery problems
and health changes; on work, every client and delivery problems.

## Secrets

The templates name people, health and money providers, and clients only by
reference: `op://Private/gmail-rules/<field>`. Each field holds a JSON value,
so a rendered reference is a JavaScript literal.

| Field | Holds |
| --- | --- |
| `todoist-address` | the Todoist hand-off address |
| `family-forward`, `family-mortgage-sender` | who `_fwd/Dad` forwards to, and the sender it forwards |
| `health-senders`, `health-insurers`, `health-invoice-sender`, `health-retail`, `health-noise` | provider, insurer and pharmacy senders; marketing to delete |
| `billers`, `card-issuers`, `lenders`, `payment-services`, `finance-noise`, `finance-loyalty-query` | bank, card, loan and payment senders; marketing to delete |
| `work-clients` | `[{ id, label, domains, paperwork? }]`, one entry per client label |

To add a sender to one of these lists, edit the field in 1Password, not the
template. To add a field, add its reference here and to the item.

## Deploying a change

1. On the laptop: `gmail/render`. This writes `gmail/build/` (ignored).
2. In the account's project, paste each file from `build/<account>/` over its
   namesake, then save.
3. Run `dryRun` and read `dryrun-<account>.json` in the Drive folder Gmail
   Redesign.
4. Run `applyLabels`, then `applyFilters`. `applyFilters` first backs up the
   current filters to `filters-before-apply-*.json`, then replaces them all.
5. Run `backfill` only for a new rule, and repeat it until it reports DONE. It
   only adds labels, and it skips Notify and `_fwd/*`, so old mail is never
   forwarded.

## The weekly review

On Sunday mornings, a scheduled Claude task reviews both accounts. It
looks for mail that no rule caught but that Carlos archived, deleted or left in
the inbox, and for rules that may have misfired. It puts its proposals in one
Todoist task and changes nothing. When a proposed sender belongs to a
1Password list, the task names the field.

The task can only reach the personal account, so at 6 AM the work project's
`reviewDigest()` mails the personal account the same evidence about the work
account, as JSON. That evidence is what no rule caught, plus what rules
archived or deleted. The personal rule `review-data` files it under the hidden
label `_review`, and the mail goes to Trash after 35 days. An account sends a
digest only when its `CONFIG.reviewTo` is set.
