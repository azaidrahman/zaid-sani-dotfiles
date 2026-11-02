# chat-cards

A Claude Code mod that adds frames to the conversation in the terminal.

- Each reply from Claude is a clear card with a round edge. The card has
  no fill, so the background of the terminal shows through it.
- Each prompt that you send gets a square box. The box has the color of the
  lines of the input field.
- Each reply card has a **copy** label at the right of its first line. Click
  it to copy the reply as Claude wrote it. The copy has no card edge, no
  indent, and no line breaks from the width of the terminal.
- A summary row (the short summary that Claude Code shows between two tool
  calls) also gets a card. The card shows "summary" and has no copy label,
  because a copy would take the summary and not the text that Claude wrote.

The edges use colors of the Claude Code theme. Thus the cards fit a light
theme and a dark theme of the terminal.

## Limits

- The mod cannot draw around the input field. The box goes on a prompt after
  you send it.
- Tool rows, such as "Ran 3 shell commands", stay as they are.
- The copy label needs a mouse click. Claude Code reports clicks in its
  full-screen mode.
- To use other colors for the edges, change `borderColor` in
  `hooks/register.tsx`.
