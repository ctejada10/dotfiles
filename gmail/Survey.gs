/**
 * Gmail redesign — step 1: backup + sender inventory. READ-ONLY on mail.
 * Requires: Services → Gmail API (advanced service, identifier "Gmail").
 * Writes JSON files to Drive folder "Gmail Redesign".
 *
 * Run backup() once, then run inventory() repeatedly until the log says DONE.
 */
const FOLDER_NAME = 'Gmail Redesign';
const INV_QUERY = 'newer_than:365d -in:chats';
const TIME_BUDGET_MS = 4.5 * 60 * 1000;

function folder_() {
  const it = DriveApp.getFoldersByName(FOLDER_NAME);
  return it.hasNext() ? it.next() : DriveApp.createFolder(FOLDER_NAME);
}
function writeJson_(name, obj) {
  const f = folder_();
  const s = JSON.stringify(obj);
  const files = f.getFilesByName(name);
  if (files.hasNext()) { const file = files.next(); file.setContent(s); return file; }
  return f.createFile(name, s, 'application/json');
}
function readJson_(name) {
  const files = folder_().getFilesByName(name);
  return files.hasNext() ? JSON.parse(files.next().getBlob().getDataAsString()) : null;
}
function me_() { return Session.getActiveUser().getEmail().toLowerCase(); }
function addr_(from) {
  const m = String(from).match(/<([^>]+)>/);
  return (m ? m[1] : String(from)).trim().toLowerCase();
}
function name_(from) {
  const m = String(from).match(/^\s*"?([^"<]*)"?\s*</);
  return m ? m[1].trim() : '';
}

function backup() {
  const u = 'me';
  const data = {
    account: me_(),
    takenAt: new Date().toISOString(),
    filters: (Gmail.Users.Settings.Filters.list(u).filter) || [],
    labels: Gmail.Users.Labels.list(u).labels || [],
    forwardingAddresses: (Gmail.Users.Settings.ForwardingAddresses.list(u).forwardingAddresses) || [],
    autoForwarding: Gmail.Users.Settings.getAutoForwarding(u),
    imap: Gmail.Users.Settings.getImap(u),
    sendAs: (Gmail.Users.Settings.SendAs.list(u).sendAs) || [],
  };
  // label counts
  data.labels.forEach(function (l) {
    try { const d = Gmail.Users.Labels.get(u, l.id); l.threadsTotal = d.threadsTotal; } catch (e) {}
  });
  const stamp = Utilities.formatDate(new Date(), 'America/New_York', 'yyyy-MM-dd_HHmm');
  const file = writeJson_('backup-' + data.account + '-' + stamp + '.json', data);
  Logger.log('BACKUP OK: %s filters, %s labels, %s forwarding addresses -> %s',
    data.filters.length, data.labels.length, data.forwardingAddresses.length, file.getId());
}

function inventoryReset() {
  PropertiesService.getUserProperties().deleteProperty('inv_state');
  Logger.log('reset');
}

function inventory() {
  const t0 = Date.now();
  const props = PropertiesService.getUserProperties();
  const me = me_();
  const mine = [me].concat(GmailApp.getAliases().map(function (a) { return a.toLowerCase(); }));
  const isMe = function (f) { return mine.indexOf(addr_(f)) >= 0; };
  const outName = 'inventory-' + me + '.json';

  let state = JSON.parse(props.getProperty('inv_state') || 'null');
  let senders;
  if (!state) { state = { start: 0, done: false, threads: 0 }; senders = {}; }
  else { senders = (readJson_(outName) || {}).senders || {}; }

  while (!state.done && Date.now() - t0 < TIME_BUDGET_MS) {
    const threads = GmailApp.search(INV_QUERY, state.start, 100);
    if (!threads.length) { state.done = true; break; }
    const all = GmailApp.getMessagesForThreads(threads);
    all.forEach(function (msgs, i) {
      const incoming = msgs.filter(function (m) { return !isMe(m.getFrom()); });
      if (!incoming.length) return;
      const m = incoming[0];
      const a = addr_(m.getFrom());
      const s = senders[a] || (senders[a] = { n: 0, msgs: 0, name: '', subjects: [], to: [], replied: 0, first: null, last: null, inbox: 0 });
      s.n++;
      s.msgs += incoming.filter(function (x) { return addr_(x.getFrom()) === a; }).length;
      if (!s.name) s.name = name_(m.getFrom());
      const subj = String(m.getSubject()).slice(0, 110);
      if (s.subjects.length < 8 && s.subjects.indexOf(subj) < 0) s.subjects.push(subj);
      const to = (String(m.getTo()) + ',' + String(m.getCc())).toLowerCase();
      const hit = mine.concat(['icloud.com', 'karejucar.com', '+']).filter(function (x) { return to.indexOf(x) >= 0; });
      const toKey = addr_(String(m.getTo()).split(',')[0]);
      if (s.to.length < 4 && s.to.indexOf(toKey) < 0) s.to.push(toKey);
      if (msgs.some(function (x) { return isMe(x.getFrom()); })) s.replied++;
      const d = m.getDate().toISOString().slice(0, 10);
      if (!s.first || d < s.first) s.first = d;
      if (!s.last || d > s.last) s.last = d;
    });
    state.start += threads.length;
    state.threads += threads.length;
  }

  const sorted = Object.keys(senders).sort(function (x, y) { return senders[y].n - senders[x].n; });
  const ordered = {};
  sorted.forEach(function (k) { ordered[k] = senders[k]; });
  const file = writeJson_(outName, { account: me, query: INV_QUERY, threads: state.threads, done: state.done, senders: ordered });
  props.setProperty('inv_state', JSON.stringify(state));
  Logger.log((state.done ? 'DONE' : 'PARTIAL — run again') + ': %s threads, %s senders -> %s',
    state.threads, sorted.length, file.getId());
}
