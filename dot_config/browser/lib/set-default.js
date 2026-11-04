// Make an application the default web browser of macOS.
// Usage: osascript -l JavaScript set-default.js <bundle id>
//
// macOS shows a dialog to confirm the change, if the application is not
// already the default browser.
ObjC.import('CoreServices');

function run(argv) {
  for (const scheme of ['http', 'https']) {
    const status = $.LSSetDefaultHandlerForURLScheme($(scheme), $(argv[0]));
    if (status !== 0) throw new Error(`${scheme}: status ${status}`);
  }
}
