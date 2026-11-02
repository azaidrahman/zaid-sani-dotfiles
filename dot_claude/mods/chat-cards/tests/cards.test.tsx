import { expect, test } from 'claude-code/testing'

test('a reply is a card with its text and a copy label', async $ => {
  const ui = await $.ui.mount({
    plugin: 'chat-cards',
    component: 'AssistantMessage',
    requestId: 'msg-1',
    surface: 'terminal',
    props: { text: 'Hello **there**', isFirstOfReply: true },
  })

  expect((await ui.find({ type: 'Text', text: /⏺/ }))?.text).toBe('⏺')
  expect((await ui.find({ type: 'Text', text: /copy/ }))?.text).toBe('copy')
  await ui.unmount()
})

test('a summary card is marked and has no copy label', async $ => {
  const ui = await $.ui.mount({
    plugin: 'chat-cards',
    component: 'AssistantMessage',
    requestId: 'msg-3',
    surface: 'terminal',
    props: { text: 'Checking the tests', isFirstOfReply: false, isSummary: true },
  })

  expect((await ui.find({ type: 'Text', text: /summary/ }))?.text).toBe('summary')
  expect(await ui.find({ type: 'Text', text: /copy/ })).toBeUndefined()
  await ui.unmount()
})

// The engine draws a markdown table to the width of the terminal, not to the
// width of the card, so the card draws each table itself.
const TABLE = [
  'Here is how much each question matters:',
  '',
  '| Q | What it is | Where it goes |',
  '|:-:|---|---|',
  '| 1 | Narrow the reader to `example-repo` | A small hardening ticket |',
  '| 2 | Bring the SAs into Terraform | A new ticket |',
  '',
  'What I would do next.',
].join('\n')

const FENCED = ['```', '| a | b |', '|---|---|', '| 1 | 2 |', '```'].join('\n')

const tables = [
  {
    name: 'a table is a grid of cells in a wide terminal',
    text: TABLE,
    columns: 120,
    present: [
      { type: 'Markdown', text: 'Here is how much each question matters:' },
      { type: 'Text', text: 'Where it goes' },
      { type: 'Markdown', text: 'Narrow the reader to `example-repo`' },
      { type: 'Markdown', text: 'What I would do next.' },
    ],
    absent: [{ type: 'Markdown', text: '|' }],
  },
  {
    name: 'a table is a list of rows in a narrow terminal',
    text: TABLE,
    columns: 30,
    present: [{ type: 'Markdown', text: '- **Where it goes:** A small hardening ticket' }],
    absent: [{ type: 'Markdown', text: '|' }],
  },
  {
    name: 'a table with a row of more than four lines is a list of rows',
    text: ['| Q | Notes |', '|---|---|', `| 1 | ${'word '.repeat(60).trim()} |`].join('\n'),
    columns: 60,
    present: [{ type: 'Markdown', text: '- **Q:** 1' }],
    absent: [{ type: 'Markdown', text: '|' }],
  },
  {
    name: 'a table in a code fence stays code',
    text: FENCED,
    columns: 120,
    present: [{ type: 'Markdown', text: FENCED }],
    absent: [{ type: 'Text', text: /^a$/ }],
  },
]

for (const c of tables) {
  test(c.name, async $ => {
    const ui = await $.ui.mount({
      plugin: 'chat-cards',
      component: 'AssistantMessage',
      surface: 'terminal',
      viewport: { columns: c.columns, rows: 40 },
      props: { text: c.text, isFirstOfReply: true },
    })

    for (const query of c.present) expect(await ui.find(query)).toBeDefined()
    for (const query of c.absent) expect(await ui.find(query)).toBeUndefined()
    await ui.unmount()
  })
}

test('a prompt you send is in a box', async $ => {
  const ui = await $.ui.mount({
    plugin: 'chat-cards',
    component: 'UserMessage',
    requestId: 'msg-2',
    surface: 'terminal',
    props: { text: 'cards please', origin: { kind: 'composer' }, isExpanded: true },
  })

  expect((await ui.find({ type: 'Text', text: /cards please/ }))?.text).toBe('cards please')
  await ui.unmount()
})
