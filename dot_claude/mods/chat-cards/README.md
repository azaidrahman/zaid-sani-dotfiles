# chat-cards

A Claude Code mod that adds frames to the conversation in the terminal.

- Each reply from Claude is a card with a fill and no edge. Thus a
  selection with the mouse takes no border characters.
- Each prompt that you send gets a square box. The box has the color of the
  lines of the input field.
- Each reply card has a **copy** label at the right of its first line. Click
  it to copy the reply as Claude wrote it. The copy has no indent and no
  line breaks from the width of the terminal.
- A summary row (the short summary that Claude Code shows between two tool
  calls) also gets a card. The card shows "summary" and has no copy label,
  because a copy would take the summary and not the text that Claude wrote.
- The card draws each markdown table in a reply. Claude Code draws a table
  to the width of the terminal, so in a card each line of the table wraps.
  The card sets the columns as Claude Code does, but to the width of the
  card. If a column cannot hold its longest word, or a row needs more than
  four lines, the table becomes one list for each row. A table in a code
  fence stays code.

The fill is `userMessageBackground`, the color that Claude Code gives to a
prompt. The fill and the edges use colors of the Claude Code theme, not
fixed values. Thus they change when the theme of Claude Code changes.

## Limits

- The mod cannot draw around the input field. The box goes on a prompt after
  you send it.
- Tool rows, such as "Ran 3 shell commands", stay as they are.
- A table in the card has no vertical lines, because a mod cannot draw a
  line to the height of a row. A table in a quote, or a table with an
  indent of four spaces or more, stays with Claude Code. The lines of such
  a table can wrap.
- The copy label needs a mouse click. Claude Code reports clicks in its
  full-screen mode.
- The fill follows the theme of Claude Code, not the theme of the terminal.
  If a dark Claude Code theme is on a light terminal, the fill is dark.
- A selection with the mouse takes the indent at the left of each line.
  Some terminals also take the filled spaces at the right of a line.
- To change the fill of all cards, set `userMessageBackground` in a custom
  Claude Code theme. To use a color for the cards only, change
  `backgroundColor` in `hooks/register.tsx`.
