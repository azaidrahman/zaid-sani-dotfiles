// Helper of the Vivaldi driver (vivaldi.sh) of the browser command.
// Usage: osascript -l JavaScript vivaldi.js <Preferences file> <command> [...]
//
// Commands:
//   position <workspace>       print the position of the workspace (1 is the
//                              first), or 0 if Vivaldi has no such workspace
//   find <prefix> [<space>]    print "<tab id><TAB><position>" of the first
//                              tab whose URL starts with the prefix, or
//                              nothing. The position is of the workspace of
//                              the tab (see below), else of the space, else 0.
//   tab-position <tab id>      print the position of the workspace of the tab
//   activate <tab id>          make the tab the active tab of its window
//   tabs                       print the open tabs as Alfred script filter JSON
//
// Vivaldi scripting does not tell the workspace of a tab. This helper finds it
// as Vivaldi does: the first workspace rule that matches the URL of the tab.
// A tab that no rule matches gets position 0.
//
// The command "position" reads only the Preferences file. The other commands
// send Apple events to Vivaldi, and start it if it is not running.
ObjC.import('Foundation');

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
      const tab = allTabs().find((t) => t.url.startsWith(arg));
      if (!tab) return '';
      const pos = positionOfUrl(ws, tab.url) || (arg2 ? positionOfName(ws, arg2) : 0);
      return `${tab.id}\t${pos}`;
    }
    case 'tab-position':
      return String(positionOfUrl(readWorkspaces(prefsPath), tabById(arg).url));
    case 'activate': {
      const tab = tabById(arg);
      tab.window.activeTabIndex = tab.index;
      return 'ok';
    }
    case 'tabs':
      return JSON.stringify({
        items: allTabs().map((t) => ({
          uid: t.id,
          title: t.title || t.url,
          subtitle: t.url,
          arg: `${t.windowId} ${t.id}`,
          match: `${t.title} ${t.url}`,
        })),
      });
    default:
      throw new Error(`unknown command: ${command}`);
  }
}
