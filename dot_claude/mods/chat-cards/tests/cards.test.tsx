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
