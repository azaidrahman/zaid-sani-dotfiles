// List the Pinboard bookmarks of all spaces as Alfred script filter JSON.
// Usage: osascript -l JavaScript bookmarks.js <cache> <space> <tags>
//   cache  the bookmark cache of the Pin Plus Alfred workflow (a JSON list,
//          or an object with "items"). The tags of a bookmark are the
//          subtitle of its "alt" modifier, separated by spaces.
//   space  the current space, or "" if the driver cannot tell
//   tags   lines of "<space>|<Pinboard tag>", in the order of the spaces
// The list has each bookmark with the tag of a space, labelled with that
// space. The bookmarks of the current space come first, then the other
// spaces in order. The arg of each item is the URL of the bookmark, and the
// item variable "space" is its space: Alfred gives it to the next action.
ObjC.import('Foundation');

function item(title, subtitle) {
  return JSON.stringify({ items: [{ title, subtitle, valid: false }] });
}

function run(argv) {
  const [cache, current, tagLines] = argv;
  const spaces = [];
  const spaceOfTag = {};
  for (const line of (tagLines || '').split('\n')) {
    const [name, tag] = line.trim().split('|');
    if (name && tag) {
      spaceOfTag[tag] = name;
      spaces.push(name);
    }
  }
  const text = $.NSString.stringWithContentsOfFileEncodingError(cache, $.NSUTF8StringEncoding, null);
  if (text.isNil()) return item('No bookmark cache', 'Open Pin Plus (Hyper \\) one time, so it saves your bookmarks.');
  let list = JSON.parse(text.js);
  if (!Array.isArray(list)) list = list.items || [];

  // The current space sorts first, then the spaces in their order.
  const rank = (space) => (space === current ? -1 : spaces.indexOf(space));
  const items = [];
  for (const b of list) {
    const tagText = ((b.mods || {}).alt || {}).subtitle || '';
    const tags = tagText.startsWith('[') ? [] : tagText.split(/\s+/).filter(Boolean);
    const tag = tags.find((t) => spaceOfTag[t]);
    if (!tag) continue;
    const space = spaceOfTag[tag];
    items.push({
      rank: rank(space),
      sortTitle: (b.title || b.arg || '').toLowerCase(),
      json: {
        uid: b.arg,
        title: b.title || b.arg,
        subtitle: `${space} · ${b.arg}`,
        arg: b.arg,
        variables: { space },
        match: `${b.title} ${b.arg} ${space} ${tags.join(' ')}`,
      },
    });
  }
  if (!items.length) {
    return item('No workspace bookmarks', 'Tag bookmarks on Pinboard with the tags in BROWSER_BOOKMARK_TAGS.');
  }
  items.sort((a, b) => a.rank - b.rank || a.sortTitle.localeCompare(b.sortTitle));
  return JSON.stringify({ items: items.map((i) => i.json) });
}
