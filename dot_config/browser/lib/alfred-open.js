// Wait while the Alfred window is open, then exit.
// Usage: osascript -l JavaScript alfred-open.js
//
// The browser command runs this script when the tab grid opens. When the
// script exits, the command sets the Karabiner variable browser_tabs_open to 0
// again. Karabiner cannot see the Alfred window: Alfred shows it as a panel,
// and Alfred never becomes the frontmost application.
//
// The window list of macOS shows the Alfred window at a window layer above 0.
// The owner name and the layer need no Screen Recording permission.
ObjC.import('CoreGraphics');

const POLL = 0.25; // the time between two looks, in seconds
const START = 3; // the time that Alfred gets to show the window
const GONE = 2; // the number of looks in a row with no window
const LIFETIME = 600; // stop after this time, in seconds

function alfredOpen() {
  const list = ObjC.deepUnwrap(ObjC.castRefToObject(
    $.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0))) || [];
  return list.some((w) => w.kCGWindowOwnerName === 'Alfred' && w.kCGWindowLayer > 0);
}

function run() {
  const start = Date.now() / 1000;
  let seen = false;
  let gone = 0;
  for (let now = start; now - start < LIFETIME; now = Date.now() / 1000) {
    if (alfredOpen()) {
      seen = true;
      gone = 0;
    } else if (seen || now - start > START) {
      gone += 1;
      if (gone >= GONE) return '';
    }
    delay(POLL);
  }
  return '';
}
