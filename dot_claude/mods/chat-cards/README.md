# chat-cards

A Claude Code mod that adds frames to the conversation in the terminal.

- Each reply from Claude is a tinted card with a round edge.
- Each prompt that you send gets a square box. The box has the color of the
  lines of the input field.
- Each reply card has a **copy** label at the right of its first line. Click
  it to copy the reply as Claude wrote it. The copy has no card edge, no
  indent, and no line breaks from the width of the terminal.
- A summary row (the short summary that Claude Code shows between two tool
  calls) also gets a card. The card shows "summary" and has no copy label,
  because a copy would take the summary and not the text that Claude wrote.

The mod reads the macOS appearance when the session starts and at each
prompt. It uses a light tint in light mode and a dark tint in dark mode.

## Limits

- The mod cannot draw around the input field. The box goes on a prompt after
  you send it.
- Tool rows, such as "Ran 3 shell commands", stay as they are.
- The copy label needs a mouse click. Claude Code reports clicks in its
  full-screen mode.
- The tints match the Rex themes sunlit-parchment and merino-dark. To use
  other colors, change `CARD` in `hooks/register.tsx`.
