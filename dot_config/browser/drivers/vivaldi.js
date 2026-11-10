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
//   activate <tab id>          make the tab the active tab of its window
//   tabs                       print the open tabs as Alfred script filter JSON
//   current                    print the name of the workspace of the active
//                              tab of the front window, or nothing
//   windows                    print one line for each window, from front to
//                              back: "<mode><TAB><position><TAB><title>".
//                              The position is of the workspace of the active
//                              tab, and the title is the title of that tab.
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
    default:
      throw new Error(`unknown command: ${command}`);
  }
}
