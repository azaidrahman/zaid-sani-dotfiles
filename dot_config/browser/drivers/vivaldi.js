// Helper of the Vivaldi driver (vivaldi.sh) of the browser command.
// Usage: osascript -l JavaScript vivaldi.js <Preferences file> <command> [...]
//
// Commands:
//   position <workspace>       print the position of the workspace (1 is the
//                              first), or 0 if Vivaldi has no such workspace
//   window-empty <window id>   print "yes" if the window has only one tab,
//                              and that tab is a start page or a blank page
//   find <prefix> [<space>]    print "<tab id><TAB><position>" of the first
//                              tab whose URL starts with the prefix, or
//                              nothing. The position is of the workspace of
//                              the tab (see below), else of the space, else 0.
//   find-in <url> <position>   print the id of the first tab in the workspace
//                              at the position whose URL starts with the URL,
//                              when you ignore the Google account parts of
//                              both (see sameAccountFree), or nothing
//   tab-position <tab id>      print the position of the workspace of the tab
//   window-title <window id>   print the title that AeroSpace shows for the
//                              window, without " - Vivaldi"
//   activate <tab id>          make the tab the active tab of its window
//   tabs                       print the open tabs as Alfred script filter JSON
//   current                    print the name of the workspace of the active
//                              tab of the front window, or nothing
//   windows                    print one line for each window, from front to
//                              back: "<mode><TAB><position><TAB><title>".
//                              The position is of the workspace of the active
//                              tab, and the title is the title of that tab.
//   watch                      run until stopped. If a workspace rule makes
//                              Vivaldi jump to a different workspace, go
//                              back, and show a notification. Also show one
//                              when a new tab opens where the user cannot
//                              see it (see watchStep). A click on the
//                              notification runs "browser focus-tab" for
//                              the tab. The LaunchAgent
//                              com.zaid.vivaldi-watch runs this command.
//
// Vivaldi scripting does not tell the workspace of a tab. This helper reads
// it from the session file of Vivaldi (see sessionWorkspaces). If the session
// file has no record of the tab, the helper uses the first workspace rule
// that matches the URL of the tab, as Vivaldi does for a new tab. A tab that
// is in no workspace gets position 0.
//
// The command "position" reads only the Preferences file. The other commands
// send Apple events to Vivaldi, and start it if it is not running.
ObjC.import('Foundation');
ObjC.import('AppKit');

function readWorkspaces(prefsPath) {
  const text = $.NSString.stringWithContentsOfFileEncodingError(
    prefsPath, $.NSUTF8StringEncoding, null);
  if (text.isNil()) throw new Error(`cannot read ${prefsPath}`);
  const ws = (JSON.parse(text.js).vivaldi || {}).workspaces || {};
  return { list: ws.list || [], rules: ws.link_routes || [] };
}

function positionOfName(ws, name) {
  return ws.list.findIndex((w) => w.name === name) + 1;
}

function positionOfUrl(ws, url) {
  for (const r of ws.rules) {
    const e = r.expression;
    const match =
      (r.type === 'STARTSWITH' && url.startsWith(e)) ||
      (r.type === 'EQUALS' && url === e) ||
      (r.type === 'CONTAINS' && url.includes(e));
    if (match) return ws.list.findIndex((w) => w.id === r.workspaceId) + 1;
  }
  return 0;
}

// sessionWorkspaces: return a Map from tab id to workspace id (null for a tab
// that is in no workspace), or null if the session file cannot be read.
//
// The session file (Default/Sessions/Session_*, the newest) is a Chromium
// "SNSS" log: an 8-byte header, then records of <uint16 size><uint8 command>
// <payload>, where the size counts the command byte and the payload. Vivaldi
// writes the extra data of a tab with command 21. Its payload is
// <uint32 size><int32 tab id><uint32 length><JSON>, and the JSON has
// "workspaceId" when the tab is in a workspace. The last record of a tab is
// the current one. Vivaldi writes the file a few seconds after a change.
function sessionWorkspaces(prefsPath) {
  try {
    const dir = prefsPath.replace(/\/Preferences$/, '/Sessions');
    const fm = $.NSFileManager.defaultManager;
    const names = ObjC.deepUnwrap(fm.contentsOfDirectoryAtPathError(dir, null)) || [];
    let newest = null;
    let newestTime = 0;
    for (const name of names.filter((n) => n.startsWith('Session_'))) {
      const attrs = fm.attributesOfItemAtPathError(`${dir}/${name}`, null);
      const time = attrs.fileModificationDate.timeIntervalSince1970;
      if (time > newestTime) { newest = `${dir}/${name}`; newestTime = time; }
    }
    if (!newest) return null;
    const data = $.NSData.dataWithContentsOfFile(newest);
    const s = $.NSString.alloc.initWithDataEncoding(data, $.NSISOLatin1StringEncoding).js;
    if (s.slice(0, 4) !== 'SNSS') return null;
    const u16 = (i) => s.charCodeAt(i) | (s.charCodeAt(i + 1) << 8);
    const u32 = (i) => (u16(i) | (u16(i + 2) << 16)) >>> 0;
    const map = new Map();
    for (let i = 8; i + 3 <= s.length;) {
      const size = u16(i);
      if (size === 0) break;
      if (s.charCodeAt(i + 2) === 21 && size >= 13) {
        const p = i + 3;
        const json = s.substr(p + 12, u32(p + 8));
        try {
          map.set(String(u32(p + 4)), JSON.parse(json).workspaceId ?? null);
        } catch (e) { /* not a tab record: skip it */ }
      }
      i += 2 + size;
    }
    return map;
  } catch (e) {
    return null;
  }
}

// positionOfTab: the position of the workspace of the tab, from the session
// file if it has a record of the tab, else from the workspace rules.
function positionOfTab(ws, session, tab) {
  if (session && session.has(tab.id)) {
    const id = session.get(tab.id);
    return id === null ? 0 : ws.list.findIndex((w) => w.id === id) + 1;
  }
  return positionOfUrl(ws, tab.url);
}

// sameAccountFree: the URL without the fragment and without the parts that
// select a Google account ("/u/1/" in the path, "authuser=" in the query).
// A bookmark that selects the account by email ("authuser=<email>") then
// matches the tab of that account, which Google moved to "/u/<number>/".
function sameAccountFree(url) {
  return url.replace(/#.*$/, '')
    .replace(/\/u\/[^/?#]+(\/|$)/, '/')
    .replace(/([?&])authuser=[^&]*(&|$)/, '$1')
    .replace(/[?&]$/, '');
}

// urlStartsWith: true if the URL starts with the prefix at a URL boundary.
// Then the repository ".../api" does not match a tab of ".../api-gateway",
// and the pull request ".../12" does not match ".../123".
function urlStartsWith(url, prefix) {
  if (!url.startsWith(prefix)) return false;
  if (url.length === prefix.length || /[/?#&=]$/.test(prefix)) return true;
  return '/?#&'.includes(url[prefix.length]);
}

// firstMatch: the first item whose URL is the prefix, else the first item
// whose URL starts with the prefix at a URL boundary. norm changes each URL
// before the compare.
function firstMatch(items, prefix, norm) {
  const want = norm(prefix);
  return items.find((t) => norm(t.url) === want) ||
    items.find((t) => urlStartsWith(norm(t.url), want));
}

// Tabs that the tab list does not show.
function isHidden(url) {
  return url === 'about:blank' || url.startsWith('chrome://vivaldi-webui/startpage') ||
    url.startsWith('chrome://newtab');
}

// All tabs of all windows: [{ window, index, id, title, url }]. Read each
// property of all tabs of a window with one Apple event.
function allTabs() {
  const tabs = [];
  for (const w of Application('Vivaldi').windows()) {
    const ids = w.tabs.id();
    const titles = w.tabs.title();
    const urls = w.tabs.url();
    ids.forEach((id, i) => tabs.push({
      window: w, windowId: w.id(), index: i + 1, id: String(id),
      title: titles[i], url: urls[i],
    }));
  }
  return tabs;
}

function tabById(id) {
  const tab = allTabs().find((t) => t.id === String(id));
  if (!tab) throw new Error(`Vivaldi has no tab ${id}`);
  return tab;
}

// The times of the watch command, in seconds.
const WATCH_POLL = 0.5; // the time between two looks at the tabs
const WATCH_SETTLE = 1; // the time that Vivaldi gets to show a new tab
const WATCH_GIVE_UP = 20; // stop the wait for the URL of a blank new tab
const WATCH_LIFETIME = 3600; // then exit, and launchd starts a new process
// If more new tabs than this appear in one look, Vivaldi restored a
// session or a window. Then the tabs are not new, and get no notification.
const WATCH_BURST = 5;
// The Keyboard Maestro macro "Browser: Run Command". It runs the browser
// command with the arguments that it gets. The browser command sends keys
// to Vivaldi, and only Keyboard Maestro has the Accessibility permission
// for that. Its file is dot_config/keyboardmaestro/exact_macros/
// browser-run-command.kmmacros.
const KM_BROWSER_MACRO = '2EDA9A5E-2F0A-4A30-90BB-E611B00293F1';

// watchStep: compare one look at the tabs with the last look. Find the
// jumps of workspace rules, and the new tabs that the user did not see.
//
// state: the state that the last step returned, or null if there was no
// last step. Tabs of a first step are not new.
// snap: { front, windows }. "front" is true if Vivaldi is the frontmost
// application. "windows" is in order from front to back:
// [{ id, mode, activeId, tabs: [{ id, url }] }].
// load: a function that returns { ws, session } (see readWorkspaces and
// sessionWorkspaces). The step calls it only when it needs them.
//
// A jump: Vivaldi is frontmost, and the active tab of the front window gets
// a new URL, or is a new tab. A workspace rule matches the URL, and sends
// the tab to a different workspace than the one that the window showed.
// Vivaldi then shows that workspace. The note of a jump has "back", the
// position of the workspace that the window showed before the jump, and
// "backTab", the tab that was active then ("-" if it is the tab that
// jumped).
//
// A new tab that is not a jump gets a check when it has had a real URL for
// WATCH_SETTLE. Vivaldi then had time to show the workspace of the tab.
// The user saw the tab if Vivaldi is frontmost, the tab is in the front
// window, and that window shows the tab or the workspace of the tab.
// Private windows have no workspaces, so the step ignores them.
//
// Return { state, notes }. "notes" has one { windowId, id, url, pos } for
// each jump and each new tab that the user did not see. "pos" is the
// position of the workspace of the tab (0 for no workspace).
function watchStep(state, snap, load, now) {
  const tabs = [];
  for (const w of snap.windows) {
    if (w.mode !== 'normal') continue;
    for (const t of w.tabs) tabs.push({ id: t.id, url: t.url, win: w });
  }
  const known = state ? state.tabs : null;
  const fresh = known ? tabs.filter((t) => !known.has(t.id)).length : 0;
  const quiet = !known || fresh > WATCH_BURST;
  let data;
  const get = () => (data = data || load());
  const notes = [];

  // The front window: find a jump, and the workspace that it shows.
  let front = null;
  let jumped = null;
  const fw = snap.windows[0];
  const t = fw && fw.mode === 'normal' ? fw.tabs.find((x) => x.id === fw.activeId) : null;
  if (t) {
    const prev = state && state.front && state.front.winId === fw.id ? state.front : null;
    if (prev && prev.activeId === t.id && prev.url === t.url) {
      front = prev;
    } else {
      const old = known && known.get(t.id);
      const opened = !old || old.url !== t.url;
      const { ws, session } = get();
      const rule = isHidden(t.url) ? 0 : positionOfUrl(ws, t.url);
      let pos;
      if (!quiet && snap.front && prev && opened && rule && rule !== prev.pos) {
        pos = rule;
        jumped = t.id;
        const backTab = prev.activeId !== t.id ? prev.activeId : '-';
        notes.push({ windowId: fw.id, id: t.id, url: t.url, pos, back: prev.pos, backTab });
      } else if (session && session.has(t.id)) {
        pos = positionOfTab(ws, session, t);
      } else if (rule) {
        pos = rule;
      } else {
        // Vivaldi opens a tab with no rule in the workspace that it shows.
        pos = opened && prev ? prev.pos : 0;
      }
      front = { winId: fw.id, activeId: t.id, url: t.url, pos };
    }
  }

  // The new tabs.
  const next = new Map();
  for (const tab of tabs) {
    const old = known && known.get(tab.id);
    const e = old ? { ...old, url: tab.url } :
      { url: tab.url, since: now, realSince: null, done: quiet || tab.id === jumped };
    if (!e.done && isHidden(tab.url)) {
      e.done = now - e.since >= WATCH_GIVE_UP;
    } else if (!e.done) {
      if (e.realSince === null) e.realSince = now;
      if (now - e.realSince >= WATCH_SETTLE) {
        e.done = true;
        const inFront = front && front.winId === tab.win.id ? front : null;
        const pos = newTabPosition(get(), tab, inFront);
        const saw = snap.front && fw === tab.win && inFront &&
          (inFront.activeId === tab.id || inFront.pos === pos);
        if (!saw) notes.push({ windowId: tab.win.id, id: tab.id, url: tab.url, pos });
      }
    }
    next.set(tab.id, e);
  }
  return { state: { tabs: next, front }, notes };
}

// newTabPosition: the position of the workspace of a new tab. If the
// session file has no record of the tab yet, use the workspace rules. If no
// rule matches, Vivaldi opened the tab in the workspace that its window
// shows. "front" is the state of the front window if the tab is in it.
function newTabPosition({ ws, session }, t, front) {
  if (session && session.has(t.id)) return positionOfTab(ws, session, t);
  const rule = positionOfUrl(ws, t.url);
  if (rule) return rule;
  if (front) return front.pos;
  const active = t.win.tabs.find((x) => x.id === t.win.activeId);
  return active ? positionOfTab(ws, session, active) : 0;
}

// watchSnapshot: read the tabs for watchStep with one Apple event for each
// property. Return null if a window opened or closed between two events.
function watchSnapshot(app) {
  const front = app.frontmost();
  const w = app.windows;
  const ids = w.id();
  const parts = [w.mode(), w.activeTab.id(), w.tabs.id(), w.tabs.url()];
  if (parts.some((p) => p.length !== ids.length)) return null;
  const [modes, actives, tabIds, urls] = parts;
  if (tabIds.some((a, i) => a.length !== urls[i].length)) return null;
  return {
    front,
    windows: ids.map((id, i) => ({
      id: String(id),
      mode: modes[i],
      activeId: String(actives[i]),
      tabs: tabIds[i].map((tid, j) => ({ id: String(tid), url: urls[i][j] || '' })),
    })),
  };
}

// watchBrowser: run "browser <args>" through the Keyboard Maestro macro.
function watchBrowser(args) {
  Application('Keyboard Maestro Engine').doScript(KM_BROWSER_MACRO, { withParameter: args });
}

// watchNotify: for a jump, show the workspace of before the jump again.
// Then show a notification. A click on it focuses the tab.
function watchNotify(app, ws, note, notifier) {
  if (!/^\d+$/.test(note.windowId) || !/^\d+$/.test(note.id)) return;
  const name = (pos) => (pos ? ws.list[pos - 1].name : '');
  const jump = note.back !== undefined;
  // Go back in the window that jumped. Do not use "space": it can choose a
  // different window.
  if (jump) watchBrowser(`focus-tab ${note.windowId} ${note.backTab} ${note.back}`);
  let title = '';
  try {
    title = app.windows.byId(Number(note.windowId)).tabs.byId(Number(note.id)).title();
  } catch (e) { /* the tab closed: use the URL */ }
  const w = note.pos ? ws.list[note.pos - 1] : null;
  const place = w ? `Opened in ${w.emoji ? `${w.emoji} ` : ''}${w.name}` : 'Opened in no workspace';
  const host = note.url.replace(/^[a-z-]+:\/\/([^/?#]*).*$/i, '$1');
  // For a jump, give the position to focus-tab: for a tab that got a new
  // URL, the session file can still give the old workspace.
  const target = `focus-tab ${note.windowId} ${note.id}${jump ? ` ${note.pos}` : ''}`;
  const click = `tell application "Keyboard Maestro Engine" to do script "${KM_BROWSER_MACRO}"` +
    ` with parameter "${target}"`;
  const args = [
    '-title', place,
    '-subtitle', host,
    '-message', title || note.url,
    '-group', `vivaldi-watch-${note.id}`,
    '-execute', `/usr/bin/osascript -e '${click}'`,
  ];
  const task = $.NSTask.launchedTaskWithLaunchPathArguments(notifier, $(args));
  task.waitUntilExit;
  const back = jump ? ` (went back to ${name(note.back) || 'no workspace'})` : '';
  console.log(`${new Date().toISOString()} ${place}${back}: ${note.url}`);
}

function watch(prefsPath) {
  const env = ObjC.deepUnwrap($.NSProcessInfo.processInfo.environment);
  const notifier = env.VIVALDI_WATCH_NOTIFIER || '/opt/homebrew/bin/terminal-notifier';
  const app = Application('Vivaldi');
  const end = Date.now() / 1000 + WATCH_LIFETIME;
  let state = null;
  for (let now = Date.now() / 1000; now < end; now = Date.now() / 1000) {
    try {
      if (!app.running()) {
        state = null;
      } else {
        const snap = watchSnapshot(app);
        if (snap) {
          let data;
          const load = () => {
            data = { ws: readWorkspaces(prefsPath), session: sessionWorkspaces(prefsPath) };
            return data;
          };
          const step = watchStep(state, snap, load, now);
          state = step.state;
          for (const note of step.notes) watchNotify(app, data.ws, note, notifier);
        }
      }
    } catch (e) {
      // Vivaldi quit or did not answer. Keep the state of the last step.
      console.log(`${new Date().toISOString()} ${e}`);
    }
    delay(WATCH_POLL);
  }
}

function run(argv) {
  const [prefsPath, command, arg, arg2] = argv;
  switch (command) {
    case 'position':
      return String(positionOfName(readWorkspaces(prefsPath), arg));
    case 'find': {
      const ws = readWorkspaces(prefsPath);
      const tab = firstMatch(allTabs(), arg, (u) => u);
      if (!tab) return '';
      const pos = positionOfTab(ws, sessionWorkspaces(prefsPath), tab) ||
        (arg2 ? positionOfName(ws, arg2) : 0);
      return `${tab.id}\t${pos}`;
    }
    case 'window-empty': {
      const w = Application('Vivaldi').windows().find((x) => String(x.id()) === String(arg));
      if (!w) return 'no';
      const urls = w.tabs.url();
      return urls.length === 1 && isHidden(urls[0]) ? 'yes' : 'no';
    }
    case 'find-in': {
      const ws = readWorkspaces(prefsPath);
      const session = sessionWorkspaces(prefsPath);
      const pos = Number(arg2);
      const inSpace = allTabs().filter((t) => positionOfTab(ws, session, t) === pos);
      const tab = firstMatch(inSpace, arg, sameAccountFree);
      return tab ? tab.id : '';
    }
    case 'tab-position':
      return String(positionOfTab(readWorkspaces(prefsPath), sessionWorkspaces(prefsPath),
        tabById(arg)));
    case 'window-title': {
      // AeroSpace shows "Start Page" for a start page, but scripting gives
      // an empty title (see check 8 in vivaldi.sh).
      const w = Application('Vivaldi').windows().find((x) => String(x.id()) === String(arg));
      if (!w) return '';
      const t = w.activeTab;
      return t.title() || (isHidden(t.url()) ? 'Start Page' : '');
    }
    case 'activate': {
      const tab = tabById(arg);
      tab.window.activeTabIndex = tab.index;
      return 'ok';
    }
    case 'current': {
      const ws = readWorkspaces(prefsPath);
      const front = Application('Vivaldi').windows[0].activeTab;
      const pos = positionOfTab(ws, sessionWorkspaces(prefsPath), { id: String(front.id()), url: front.url() });
      return pos ? ws.list[pos - 1].name : '';
    }
    case 'windows': {
      const ws = readWorkspaces(prefsPath);
      const session = sessionWorkspaces(prefsPath);
      return Application('Vivaldi').windows().map((w) => {
        const t = w.activeTab;
        const pos = positionOfTab(ws, session, { id: String(t.id()), url: t.url() });
        return `${w.mode()}\t${pos}\t${t.title()}`;
      }).join('\n');
    }
    case 'tabs': {
      // The subtitle starts with the workspace, so that the user sees it.
      // The workspace name is also in "match", so typing it filters the tabs.
      const ws = readWorkspaces(prefsPath);
      const session = sessionWorkspaces(prefsPath);
      // Show the icon of the Vivaldi application on each tab. Without the
      // icon, Alfred shows the icon of the workflow.
      let icon;
      try {
        const app = $.NSWorkspace.sharedWorkspace
          .URLForApplicationWithBundleIdentifier('com.vivaldi.Vivaldi');
        if (!app.isNil()) icon = { type: 'fileicon', path: app.path.js };
      } catch (e) { /* no icon */ }
      return JSON.stringify({
        items: allTabs().filter((t) => !isHidden(t.url)).map((t) => {
          const pos = positionOfTab(ws, session, t);
          const w = pos ? ws.list[pos - 1] : null;
          const place = w ? `${w.emoji ? `${w.emoji} ` : ''}${w.name}` : 'No workspace';
          return {
            uid: t.id,
            title: t.title || t.url,
            subtitle: `${place} · ${t.url}`,
            arg: `${t.windowId} ${t.id}`,
            match: `${t.title} ${t.url} ${w ? w.name : ''}`,
            icon,
          };
        }),
      });
    }
    case 'watch':
      watch(prefsPath);
      return '';
    default:
      throw new Error(`unknown command: ${command}`);
  }
}
