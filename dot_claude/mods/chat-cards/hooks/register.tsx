import type { ElementTable, Register } from 'claude-code'

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
//
// The engine's Markdown draws a table to the width of the terminal, not to
// the width of the box that holds it. A table in a card is thus too wide,
// and each of its lines wraps. The card draws each table itself: one
// Markdown for each cell, in columns that fit the card.

type Elements = ElementTable<'terminal'>
type Align = 'left' | 'center' | 'right'
type Table = { header: string[]; align: Align[]; rows: string[][] }
type Part = { text: string } | { table: Table }

// The columns of a card that the text cannot use: the two edges, the
// padding in the edges, the gutter of the bullet, and the margin of the
// label at the right. The label itself is added for each card.
const CARD_COLUMNS = 8
const GAP = 3
const MIN_COLUMN = 3
const MAX_LINES = 4

const FENCE_OPEN = /^ {0,3}(`{3,}|~{3,})/
const FENCE_CLOSE = /^ {0,3}(`{3,}|~{3,})\s*$/
const DELIMITER_ROW = /^ {0,3}\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/
const JUSTIFY = { left: 'flex-start', center: 'center', right: 'flex-end' } as const

// The cells of a table row. A pipe with a backslash before it is text.
function cells(line: string): string[] {
  let body = line.trim()
  if (body.startsWith('|')) body = body.slice(1)
  if (body.endsWith('|') && !body.endsWith('\\|')) body = body.slice(0, -1)
  return body.split(/(?<!\\)\|/).map(cell => cell.trim().replace(/\\\|/g, '|'))
}

// The reply in parts: markdown text, and the tables outside code fences.
function parts(text: string): Part[] {
  const lines = text.split('\n')
  const out: Part[] = []
  let prose: string[] = []
  let fence: string | undefined
  const flush = () => {
    const body = prose.join('\n').replace(/^\s*\n|\n\s*$/g, '')
    if (body.trim() !== '') out.push({ text: body })
    prose = []
  }

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i] ?? ''
    if (fence !== undefined) {
      const close = FENCE_CLOSE.exec(line)?.[1]
      if (close !== undefined && close[0] === fence[0] && close.length >= fence.length) fence = undefined
      prose.push(line)
      continue
    }
    const open = FENCE_OPEN.exec(line)?.[1]
    if (open !== undefined) {
      fence = open
      prose.push(line)
      continue
    }

    const delimiter = lines[i + 1]
    const header = cells(line)
    if (
      /^ {0,3}\S/.test(line) &&
      line.includes('|') &&
      delimiter !== undefined &&
      DELIMITER_ROW.test(delimiter) &&
      cells(delimiter).length === header.length
    ) {
      const align = cells(delimiter).map((cell): Align =>
        cell.endsWith(':') ? (cell.startsWith(':') ? 'center' : 'right') : 'left',
      )
      const rows: string[][] = []
      let next = i + 2
      for (let row = lines[next]; row !== undefined && row.trim() !== '' && row.includes('|'); row = lines[++next]) {
        const found = cells(row)
        rows.push(header.map((_, column) => found[column] ?? ''))
      }
      flush()
      out.push({ table: { header, align, rows } })
      i = next - 1
      continue
    }
    prose.push(line)
  }
  flush()
  return out
}

// The text of a cell as the terminal shows it, to measure its width.
function plain(cell: string): string {
  return cell
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/`/g, '')
    .replace(/\*\*|__|~~/g, '')
}

function width(text: string): number {
  return [...text].length
}

function sum(numbers: number[]): number {
  return numbers.reduce((total, n) => total + n, 0)
}

// The number of lines that a text needs in a column, with words kept whole.
function lineCount(text: string, columns: number): number {
  let count = 1
  let used = 0
  for (const word of text.split(/\s+/).filter(Boolean)) {
    const size = width(word)
    if (used > 0 && used + 1 + size > columns) {
      count++
      used = 0
    }
    used += (used > 0 ? 1 : 0) + size
  }
  return count
}

// The widths of the columns, as the engine sets them for a table in a reply.
// Each column gets the width of its longest word, and MIN_COLUMN at least.
// Each column then gets a part of the space that is left, in proportion to
// the width that its full text needs more than its longest word. If a column
// cannot hold its longest word, or a row needs more than MAX_LINES lines, the
// result is undefined, and the table becomes a list.
function columnWidths(table: Table, room: number): number[] | undefined {
  const texts = [table.header, ...table.rows].map(row => row.map(plain))
  const column = (measure: (text: string) => number) =>
    table.header.map((_, index) => Math.max(MIN_COLUMN, ...texts.map(row => measure(row[index] ?? ''))))
  const ideal = column(width)
  const least = column(text => Math.max(0, ...text.split(/\s+/).map(width)))
  const space = room - GAP * (table.header.length - 1)

  if (sum(ideal) <= space) return ideal
  if (sum(least) > space) return undefined
  const share = (space - sum(least)) / (sum(ideal) - sum(least))
  const widths = least.map((w, index) => w + Math.floor(((ideal[index] ?? w) - w) * share))
  const tallest = Math.max(...texts.flatMap(row => row.map((text, index) => lineCount(text, widths[index] ?? 1))))
  return tallest > MAX_LINES ? undefined : widths
}

// A grid has one Box for each cell, at the width that columnWidths gives.
// If the room was too large an estimate, the cells shrink to fit the card.
// Each rule is a long line in a Box of one row, so it is cut to the table
// width. A table that does not fit as a grid becomes one list for each row.
function drawTable({ Box, Text, Markdown }: Elements, table: Table, room: number) {
  const { header, align, rows } = table
  const widths = columnWidths(table, room)

  if (widths === undefined) {
    return (
      <Box flexDirection="column">
        {rows.map((row, index) => (
          <Box marginTop={index === 0 ? 0 : 1}>
            <Markdown
              text={row
                .map((cell, column) => {
                  const name = plain(header[column] ?? '')
                  return name === '' ? `- ${cell}` : `- **${name}:** ${cell}`
                })
                .join('\n')}
            />
          </Box>
        ))}
      </Box>
    )
  }

  const rule = (
    <Box height={1} overflow="hidden">
      <Text dimColor>{'─'.repeat(sum(widths) + GAP * (widths.length - 1))}</Text>
    </Box>
  )
  const row = (texts: string[], isHeader: boolean) => (
    <Box flexDirection="row" columnGap={GAP}>
      {texts.map((text, column) => (
        <Box width={widths[column]} flexShrink={1} justifyContent={JUSTIFY[align[column] ?? 'left']}>
          {isHeader ? <Text bold>{plain(text)}</Text> : text === '' ? null : <Markdown text={text} />}
        </Box>
      ))}
    </Box>
  )

  return (
    <Box flexDirection="column">
      {row(header, true)}
      {rule}
      {rows.map((cellsOfRow, index) => (
        <Box flexDirection="column">
          {index > 0 && rule}
          {row(cellsOfRow, false)}
        </Box>
      ))}
    </Box>
  )
}

export const register: Register = on => {
  // The mod draws the rows itself, not around the engine's own rows: an
  // engine row brings its top margin, which would be an empty line inside
  // the frame. Markdown draws the text as the engine draws a reply.
  on('ui.render', { component: 'AssistantMessage' }, ($, e, next) => {
    if (e.surface !== 'terminal') return next(e)
    const elements = $.ui.resolve(e)
    const { Box, Text, Markdown, Button } = elements
    const text = e.props.text

    // The column at the right of the first line holds the copy label. The
    // terminal does not draw a Box placed over the card's edge, so the label
    // takes a few columns of the text instead.
    //
    // A summary row shows a short summary of what Claude wrote between two
    // tool calls. The column says "summary" there, as the engine marks the
    // row, and has no copy label: a copy would take the summary, not the
    // text that Claude wrote.
    const label = e.props.isSummary ? 'summary' : 'copy'
    const side = e.props.isSummary ? (
      <Text dimColor>{label}</Text>
    ) : (
      <Button
        key="copy"
        plain
        onPress={async press => {
          const done = await $.ui.copy({ text, surface: press.surface })
          $.ui.toast(done.isCopied ? 'Copied the reply' : `Not copied: ${done.reason}`)
        }}
      >
        <Text dimColor>{label}</Text>
      </Button>
    )

    // Without a table, one Markdown draws the whole text, as the engine does.
    // The room of a table is an estimate from the width of the terminal: it
    // only chooses between a grid and a list. The grid takes its real width
    // from the layout of the card.
    const split = parts(text)
    const room = (e.viewport?.columns ?? Infinity) - CARD_COLUMNS - label.length
    const body = split.some(part => 'table' in part) ? (
      split.map((part, index) => (
        <Box flexDirection="column" marginTop={index === 0 ? 0 : 1}>
          {'table' in part ? drawTable(elements, part.table, room) : <Markdown text={part.text} />}
        </Box>
      ))
    ) : (
      <Markdown text={text} />
    )

    return (
      <Box marginTop={1} borderStyle="round" borderColor="inactive" paddingX={1}>
        <Box width={2} flexShrink={0}>
          <Text>{e.props.isFirstOfReply ? '⏺' : ' '}</Text>
        </Box>
        <Box flexDirection="column" flexGrow={1} flexShrink={1}>
          {body}
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
