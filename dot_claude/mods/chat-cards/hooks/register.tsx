import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Appearance } from '../types'

// Each reply of Claude is a tinted card with a round edge. Each prompt you
// send gets a square box in the color of the lines of the input field. The
// input field itself is the engine's own, and a mod cannot draw around it.
//
// Each card has a "copy" label on its top edge. A click copies the text as
// Claude wrote it: no card edge, no gutter, and no line breaks from the
// width of the terminal. A selection with the mouse would take all three.

const appearance = atom({ plugin: 'chat-cards', key: 'appearance' } as const, 'light' as Appearance)

// One shade off the backgrounds of the Rex themes: sunlit-parchment
// (#f7f2e3) in light mode and merino-dark (#0e1117) in dark mode.
const CARD: Record<Appearance, { fill: string; edge: string }> = {
  light: { fill: '#ede6d1', edge: '#d9cfb4' },
  dark: { fill: '#181c24', edge: '#2a303b' },
}

// macOS writes AppleInterfaceStyle only in dark mode, so a failed read is
// light mode.
async function readAppearance($: EngineInterface): Promise<Appearance> {
  try {
    const { exitCode, stdout } = await $.process.run(
      ['defaults', 'read', '-g', 'AppleInterfaceStyle'],
      { timeoutMs: 2000 },
    )
    return exitCode === 0 && stdout.trim() === 'Dark' ? 'dark' : 'light'
  } catch {
    return 'light'
  }
}

async function refresh($: EngineInterface): Promise<void> {
  const value = await readAppearance($)
  await update($, appearance, () => value)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await refresh($)
    return started
  })

  // Read the appearance again at each prompt, so the cards follow a switch
  // to dark mode at sunset. The prompt does not wait for it.
  on('prompt.submit', ($, e, next) => {
    void refresh($)
    return next(e)
  })

  // The mod draws the rows itself, not around the engine's own rows: an
  // engine row brings its top margin, which would be an empty line inside
  // the frame. Markdown draws the text as the engine draws a reply.
  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    if (e.surface !== 'terminal') return next(e)
    const { fill, edge } = CARD[await read($, appearance)]
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
      <Box marginTop={1} borderStyle="round" borderColor={edge} backgroundColor={fill} paddingX={1}>
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
