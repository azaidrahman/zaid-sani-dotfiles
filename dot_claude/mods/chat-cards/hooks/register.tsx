import type { Register } from 'claude-code'

// Each reply of Claude is a clear card with a round edge. Each prompt you
// send gets a square box in the color of the lines of the input field. The
// input field itself is the engine's own, and a mod cannot draw around it.
//
// The cards have no fill. The terminal background shows through, so a card
// fits a light theme and a dark theme of the terminal. The edges use colors
// of the Claude Code theme, not fixed values.
//
// Each card has a "copy" label on its top edge. A click copies the text as
// Claude wrote it: no card edge, no gutter, and no line breaks from the
// width of the terminal. A selection with the mouse would take all three.

export const register: Register = on => {
  // The mod draws the rows itself, not around the engine's own rows: an
  // engine row brings its top margin, which would be an empty line inside
  // the frame. Markdown draws the text as the engine draws a reply.
  on('ui.render', { component: 'AssistantMessage' }, ($, e, next) => {
    if (e.surface !== 'terminal') return next(e)
    const { Box, Text, Markdown, Button } = $.ui.resolve(e)
    const text = e.props.text

    // The column at the right of the first line holds the copy label. The
    // terminal does not draw a Box placed over the card's edge, so the label
    // takes a few columns of the text instead.
    //
    // A summary row shows a short summary of what Claude wrote between two
    // tool calls. The column says "summary" there, as the engine marks the
    // row, and has no copy label: a copy would take the summary, not the
    // text that Claude wrote.
    const side = e.props.isSummary ? (
      <Text dimColor>summary</Text>
    ) : (
      <Button
        key="copy"
        plain
        onPress={async press => {
          const done = await $.ui.copy({ text, surface: press.surface })
          $.ui.toast(done.isCopied ? 'Copied the reply' : `Not copied: ${done.reason}`)
        }}
      >
        <Text dimColor>copy</Text>
      </Button>
    )

    return (
      <Box marginTop={1} borderStyle="round" borderColor="inactive" paddingX={1}>
        <Box width={2} flexShrink={0}>
          <Text>{e.props.isFirstOfReply ? '⏺' : ' '}</Text>
        </Box>
        <Box flexDirection="column" flexGrow={1} flexShrink={1}>
          <Markdown text={text} />
        </Box>
        <Box flexShrink={0} marginLeft={2}>
          {side}
        </Box>
      </Box>
    )
  })

  on('ui.render', { component: 'UserMessage', props: { origin: { kind: 'composer' } } }, ($, e, next) => {
    if (e.surface !== 'terminal') return next(e)
    const { Box, Text } = $.ui.resolve(e)
    return (
      <Box marginTop={1} borderStyle="single" borderColor="promptBorder" paddingX={1}>
        <Box width={2} flexShrink={0}>
          <Text dimColor>❯</Text>
        </Box>
        <Box flexDirection="column" flexGrow={1} flexShrink={1}>
          <Text>{e.props.text}</Text>
        </Box>
      </Box>
    )
  })
}
