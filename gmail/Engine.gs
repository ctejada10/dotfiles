/**
 * Gmail redesign — engine. Rules live in Rules.gs (CONFIG), rendered from Rules.<account>.gs.op.
 *
 * Entry points (run from the editor):
 *   dryRun()            report only: per-rule match counts, samples, overlaps, unmatched inbox senders
 *   applyLabels()       create every label in CONFIG.labels (idempotent)
 *   applyFilters()      delete ALL existing filters (backup taken first), create CONFIG filters
 *   backfill()          label existing mail per rule (adds labels only; never archives/deletes). Resumable.
 *   removeOldLabels()   delete labels listed in CONFIG.oldLabels that are not in CONFIG.labels
 *   installTriggers()   router every 10 min, housekeeping daily
 *   router()            forwards anything carrying a CONFIG.forwards label, then removes that label
 *   housekeeping()      trashes expired mail per rule.expireDays
 *   reviewDigest()      mails CONFIG.reviewTo a week of evidence for the Sunday review (if set)
 */
const RD_FOLDER = 'Gmail Redesign';

function rdFolder_() {
  const it = DriveApp.getFoldersByName(RD_FOLDER);
  return it.hasNext() ? it.next() : DriveApp.createFolder(RD_FOLDER);
}
function rdWrite_(name, obj) {
  const f = rdFolder_(), s = JSON.stringify(obj, null, 1), files = f.getFilesByName(name);
  if (files.hasNext()) { const file = files.next(); file.setContent(s); return file; }
  return f.createFile(name, s, 'application/json');
}
function rdMe_() { return Session.getActiveUser().getEmail().toLowerCase(); }

/** Expand CONFIG.rules into concrete Gmail filters (one per label, so parent labels work). */
function rdFilters_() {
  const out = [];
  CONFIG.rules.forEach(function (r) {
    const labels = (r.labels || []).slice();
    labels.forEach(function (lab, i) {
      const action = { addLabelIds: [lab] };
      if (i === 0) {
        const rem = [];
        if (r.archive) rem.push('INBOX');
        if (r.read) rem.push('UNREAD');
        if (r.notImportant) rem.push('IMPORTANT');
        if (rem.length) action.removeLabelIds = rem;
        if (r.star) action.addLabelIds.push('STARRED');
        if (r.trash) action.addLabelIds.push('TRASH');
      }
      out.push({ id: r.id, query: r.query, action: action });
    });
    if (!labels.length) {
      const action = { addLabelIds: [], removeLabelIds: [] };
      if (r.trash) action.addLabelIds.push('TRASH');
      if (r.archive) action.removeLabelIds.push('INBOX');
      if (r.read) action.removeLabelIds.push('UNREAD');
      out.push({ id: r.id, query: r.query, action: action });
    }
  });
  return out;
}

/* ---------------- dry run ---------------- */
function dryRun() {
  const window = CONFIG.dryRunWindow || 'newer_than:365d';
  const report = { account: rdMe_(), at: new Date().toISOString(), window: window, rules: [], overlaps: [], unmatched: {} };
  const seen = {};   // threadId -> [ruleIds]
  CONFIG.rules.forEach(function (r) {
    if (r.query.length > 1500) report.rules.push({ id: r.id, error: 'query > 1500 chars (' + r.query.length + ')' });
    let threads = [], start = 0;
    while (true) {
      const page = GmailApp.search('(' + r.query + ') ' + window, start, 500);
      threads = threads.concat(page);
      if (page.length < 500 || threads.length >= 3000) break;
      start += 500;
    }
    const samples = threads.slice(0, 12).map(function (t) {
      const m = t.getMessages()[0];
      return m.getFrom().slice(0, 60) + ' | ' + t.getFirstMessageSubject().slice(0, 80);
    });
    threads.forEach(function (t) { (seen[t.getId()] = seen[t.getId()] || []).push(r.id); });
    report.rules.push({ id: r.id, labels: r.labels, archive: !!r.archive, trash: !!r.trash, count: threads.length, capped: threads.length >= 3000, samples: samples });
  });
  const pairs = {};
  Object.keys(seen).forEach(function (tid) {
    const ids = seen[tid].filter(function (x, i, a) { return a.indexOf(x) === i; });
    if (ids.length > 1) { const k = ids.sort().join(' + '); pairs[k] = (pairs[k] || 0) + 1; }
  });
  report.overlaps = Object.keys(pairs).map(function (k) { return { rules: k, threads: pairs[k] }; })
    .sort(function (a, b) { return b.threads - a.threads; });
  // what would stay in the inbox with no rule at all (last 90 days)
  const recent = GmailApp.search('newer_than:90d -in:sent -in:chats', 0, 500);
  recent.forEach(function (t) {
    if (seen[t.getId()]) return;
    const m = t.getMessages()[0];
    const from = m.getFrom();
    const k = (from.match(/<([^>]+)>/) || [null, from])[1].toLowerCase();
    const u = report.unmatched[k] || (report.unmatched[k] = { n: 0, subjects: [] });
    u.n++;
    if (u.subjects.length < 4) u.subjects.push(t.getFirstMessageSubject().slice(0, 80));
  });
  const file = rdWrite_('dryrun-' + report.account + '.json', report);
  Logger.log('DRYRUN OK: %s rules, %s overlap pairs, %s unmatched senders -> %s',
    report.rules.length, report.overlaps.length, Object.keys(report.unmatched).length, file.getId());
}

/* ---------------- labels ---------------- */
function rdLabelMap_() {
  const map = {};
  (Gmail.Users.Labels.list('me').labels || []).forEach(function (l) { map[l.name] = l.id; });
  return map;
}
function applyLabels() {
  const map = rdLabelMap_();
  let made = 0;
  CONFIG.labels.forEach(function (l) {
    const name = typeof l === 'string' ? l : l.name;
    if (map[name]) return;
    const body = { name: name, labelListVisibility: 'labelShow', messageListVisibility: 'show' };
    if (l.color) body.color = l.color;
    if (l.hidden) { body.labelListVisibility = 'labelHide'; body.messageListVisibility = 'hide'; }
    map[name] = Gmail.Users.Labels.create(body, 'me').id;
    made++;
  });
  Logger.log('LABELS OK: %s created, %s total', made, CONFIG.labels.length);
}

/* ---------------- filters ---------------- */
function applyFilters() {
  const map = rdLabelMap_();
  const existing = (Gmail.Users.Settings.Filters.list('me') || {}).filter || [];
  rdWrite_('filters-before-apply-' + rdMe_() + '-' + Date.now() + '.json', existing);
  existing.forEach(function (f) { Gmail.Users.Settings.Filters.remove('me', f.id); });
  let made = 0;
  const errors = [];
  rdFilters_().forEach(function (f) {
    const action = JSON.parse(JSON.stringify(f.action));
    action.addLabelIds = (action.addLabelIds || []).map(function (n) {
      if (['STARRED', 'TRASH', 'IMPORTANT', 'INBOX', 'UNREAD'].indexOf(n) >= 0) return n;
      if (!map[n]) throw new Error('Missing label ' + n + ' for rule ' + f.id);
      return map[n];
    });
    if (!action.addLabelIds.length) delete action.addLabelIds;
    if (action.removeLabelIds && !action.removeLabelIds.length) delete action.removeLabelIds;
    try {
      Gmail.Users.Settings.Filters.create({ criteria: { query: f.query }, action: action }, 'me');
      made++;
    } catch (e) { errors.push(f.id + ': ' + e.message); }
  });
  Logger.log('FILTERS OK: removed %s, created %s, errors %s %s', existing.length, made, errors.length, errors.join(' ; '));
}

/* ---------------- backfill (labels only) ---------------- */
function backfill() {
  const t0 = Date.now();
  const props = PropertiesService.getUserProperties();
  const map = rdLabelMap_();
  let state = JSON.parse(props.getProperty('bf_state') || '{"i":0,"page":null,"done":false,"n":0}');
  const skip = CONFIG.noBackfill || [];
  const rules = CONFIG.rules.filter(function (r) {
    return !r.trash && (r.labels || []).some(function (n) { return skip.indexOf(n) < 0; });
  });
  while (state.i < rules.length && Date.now() - t0 < 4.5 * 60 * 1000) {
    const r = rules[state.i];
    const ids = r.labels.filter(function (n) { return skip.indexOf(n) < 0; }).map(function (n) { return map[n]; });
    const res = Gmail.Users.Messages.list('me', { q: r.query + ' ' + (CONFIG.backfillWindow || ''), maxResults: 500, pageToken: state.page || undefined });
    const msgs = (res.messages || []).map(function (m) { return m.id; });
    if (msgs.length) {
      Gmail.Users.Messages.batchModify({ ids: msgs, addLabelIds: ids }, 'me');
      state.n += msgs.length;
    }
    if (res.nextPageToken) state.page = res.nextPageToken;
    else { state.i++; state.page = null; }
  }
  state.done = state.i >= rules.length;
  props.setProperty('bf_state', JSON.stringify(state));
  Logger.log((state.done ? 'BACKFILL DONE' : 'BACKFILL PARTIAL - run again') + ': rule %s/%s, %s messages labeled', state.i, rules.length, state.n);
}
function backfillReset() { PropertiesService.getUserProperties().deleteProperty('bf_state'); Logger.log('reset'); }

/* ---------------- old labels ---------------- */
function removeOldLabels() {
  const keep = CONFIG.labels.map(function (l) { return typeof l === 'string' ? l : l.name; });
  const map = rdLabelMap_();
  let n = 0;
  (CONFIG.oldLabels || []).forEach(function (name) {
    if (keep.indexOf(name) >= 0 || !map[name]) return;
    Gmail.Users.Labels.remove('me', map[name]);
    n++;
  });
  Logger.log('OLD LABELS REMOVED: %s', n);
}

/* ---------------- router + housekeeping ---------------- */
function router() {
  (CONFIG.forwards || []).forEach(function (f) {
    if (!/@/.test(f.to) || /TBD/.test(f.to)) return;
    const label = GmailApp.getUserLabelByName(f.label);
    if (!label) return;
    const threads = label.getThreads(0, 50);
    threads.forEach(function (t) {
      t.getMessages().forEach(function (m) {
        if (m.isInTrash()) return;
        const key = 'fwd_' + f.label + '_' + m.getId();
        const props = PropertiesService.getUserProperties();
        if (props.getProperty(key)) return;
        m.forward(f.to);
        props.setProperty(key, '1');
      });
      t.removeLabel(label);
      if (f.thenTrash) t.moveToTrash();
    });
  });
}

function housekeeping() {
  CONFIG.rules.filter(function (r) { return r.expireDays; }).forEach(function (x) {
    let threads;
    do {
      threads = GmailApp.search('(' + x.query + ') older_than:' + x.expireDays + 'd -is:starred -label:Todoist', 0, 100);
      if (threads.length) GmailApp.moveThreadsToTrash(threads);
    } while (threads.length === 100);
  });
  const props = PropertiesService.getUserProperties();
  const all = props.getKeys().filter(function (k) { return k.indexOf('fwd_') === 0; });
  if (all.length > 400) all.slice(0, all.length - 400).forEach(function (k) { props.deleteProperty(k); });
}

/* ---------------- weekly review digest (CONFIG.reviewTo) ---------------- */
// The Sunday Claude review reads only the personal account, so an account with CONFIG.reviewTo mails it the
// same evidence about itself: what no rule caught and Carlos handled by hand, and what rules archived or
// deleted (possible misfires). Read-only on mail; the digest is the only thing sent.
function reviewDigest() {
  if (!CONFIG.reviewTo) { Logger.log('no CONFIG.reviewTo'); return; }
  const since = Date.now() - 7 * 864e5, me = rdMe_();
  const addr = function (f) { const m = String(f).match(/<([^>]+)>/); return (m ? m[1] : String(f)).trim().toLowerCase(); };
  const brief = function (m) {
    return { date: Utilities.formatDate(m.getDate(), 'America/New_York', 'yyyy/MM/dd'), subject: m.getSubject().slice(0, 120),
      text: m.getPlainBody().replace(/\s+/g, ' ').trim().slice(0, 160) };
  };
  const unruled = {};
  [['archived', 'newer_than:7d has:nouserlabels -in:inbox -in:sent -in:trash -in:spam -in:chats -from:me'],
   ['inbox', 'newer_than:7d has:nouserlabels in:inbox -from:me'],
   ['trashed', 'newer_than:7d has:nouserlabels in:trash -from:me']].forEach(function (s) {
    GmailApp.search(s[1], 0, 150).forEach(function (t) {
      t.getMessages().forEach(function (m) {
        const from = addr(m.getFrom());
        if (m.getDate().getTime() < since || from === me) return;
        const u = unruled[from] || (unruled[from] = { sender: from, archived: 0, inbox: 0, trashed: 0, samples: [] });
        u[s[0]]++;
        if (u.samples.length < 3) u.samples.push(brief(m));
      });
    });
  });
  const ruled = [];
  CONFIG.rules.filter(function (r) { return r.archive || r.trash; }).forEach(function (r) {
    GmailApp.search('in:anywhere newer_than:7d (' + r.query + ')', 0, 15).forEach(function (t) {
      const m = t.getMessages().pop();
      if (m.getDate().getTime() >= since && addr(m.getFrom()) !== me) {
        ruled.push(Object.assign({ rule: r.id, action: r.trash ? 'deleted' : 'archived', sender: addr(m.getFrom()) }, brief(m)));
      }
    });
  });
  const digest = { account: me, generated: new Date().toISOString(),
    unruled: Object.keys(unruled).map(function (k) { return unruled[k]; })
      .sort(function (a, b) { return (b.archived + b.inbox + b.trashed) - (a.archived + a.inbox + a.trashed); }).slice(0, 150),
    ruled: ruled.slice(0, 200) };
  GmailApp.sendEmail(CONFIG.reviewTo, 'Gmail review data: ' + me + ' ' + Utilities.formatDate(new Date(), 'America/New_York', 'yyyy/MM/dd'),
    JSON.stringify(digest, null, 1));
  Logger.log('DIGEST SENT: %s unruled senders, %s ruled messages', digest.unruled.length, digest.ruled.length);
}

function installTriggers() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (['router', 'housekeeping', 'reviewDigest'].indexOf(t.getHandlerFunction()) >= 0) ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('router').timeBased().everyMinutes(10).create();
  ScriptApp.newTrigger('housekeeping').timeBased().atHour(4).everyDays(1).inTimezone('America/New_York').create();
  // Sunday 6 AM, ahead of the 7:47 review.
  if (CONFIG.reviewTo) ScriptApp.newTrigger('reviewDigest').timeBased().onWeekDay(ScriptApp.WeekDay.SUNDAY).atHour(6)
    .inTimezone('America/New_York').create();
  Logger.log('TRIGGERS OK');
}

/* ---------------- unsubscribe (CONFIG.unsubscribe senders) ---------------- */
// mailto: unsubscribes are sent from here; https: links are written to the report for a browser click.
function unsubscribe() {
  const out = [];
  (CONFIG.unsubscribe || []).forEach(function (sender) {
    const t = GmailApp.search('from:' + sender, 0, 1)[0];
    if (!t) { out.push({ sender: sender, status: 'no mail found' }); return; }
    const msgs = t.getMessages(), m = msgs[msgs.length - 1];
    const header = m.getHeader('List-Unsubscribe') || '';
    const post = m.getHeader('List-Unsubscribe-Post') || '';
    const links = (header.match(/<([^>]+)>/g) || []).map(function (x) { return x.slice(1, -1); });
    const mailto = links.filter(function (l) { return l.indexOf('mailto:') === 0; })[0];
    const https = links.filter(function (l) { return l.indexOf('http') === 0; })[0];
    if (mailto) {
      const addr = mailto.slice(7).split('?')[0];
      const subj = (mailto.match(/[?&]subject=([^&]+)/i) || [null, 'unsubscribe'])[1];
      GmailApp.sendEmail(addr, decodeURIComponent(subj), 'unsubscribe');
      out.push({ sender: sender, status: 'mailto sent', to: addr, https: https || null });
    } else if (https) {
      out.push({ sender: sender, status: 'needs browser', https: https, oneClick: /One-Click/i.test(post) });
    } else {
      out.push({ sender: sender, status: 'no List-Unsubscribe header', subject: t.getFirstMessageSubject() });
    }
  });
  const file = rdWrite_('unsubscribe-' + rdMe_() + '.json', out);
  Logger.log('UNSUBSCRIBE: %s', JSON.stringify(out.map(function (o) { return o.sender + '=' + o.status; })));
}
