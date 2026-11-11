import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

// The numbers of the [Image #N] chips in the prompt box, in order.
const chips = atom({ plugin: 'image-peek', key: 'chips' } as const, [], {
  shape: 'chips-1',
})

const CHIP = /\[Image #(\d+)\]/g
// Four rows: 64 px tall on a 16 px cell.
const MAX_ROWS = 4
// A terminal cell is about twice as tall as it is wide.
const CELL_RATIO = 2
// An Image takes at most 2 MiB of bytes; a bigger file goes by its path.
const MAX_INLINE_BYTES = 2 * 1024 * 1024
const GAP = 2
// The width of the label beside a picture ("1639x486").
const LABEL_COLUMNS = 11

type Found = {
  n: number
  path: string
  width: number
  height: number
  png?: string
}

// Caches only: a reload starts them over.
let imagesDir: { sessionId: string; dir: string } | undefined
const loadedFiles = new Map<string, { mtimeMs: number; found: Found }>()

function chipsOf(text: string): number[] {
  const seen = new Set<number>()
  for (const m of text.matchAll(CHIP)) seen.add(Number(m[1]))
  return [...seen]
}

function sameList(a: readonly number[], b: readonly number[]) {
  return a.length === b.length && a.every((v, i) => v === b[i])
}

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

// The first bytes of a base64 string; `chars` is a multiple of 4.
function decodeHead(base64: string, chars: number): number[] {
  const out: number[] = []
  for (let i = 0; i + 3 < chars && i + 3 < base64.length; i += 4) {
    const v =
      (B64.indexOf(base64[i]!) << 18) |
      (B64.indexOf(base64[i + 1]!) << 12) |
      (B64.indexOf(base64[i + 2]!) << 6) |
      B64.indexOf(base64[i + 3]!)
    out.push((v >> 16) & 255, (v >> 8) & 255, v & 255)
  }
  return out
}

// The width and height from a PNG's IHDR chunk (bytes 16 to 23).
function pngSize(base64: string) {
  const b = decodeHead(base64, 32)
  const u32 = (at: number) =>
    ((b[at]! << 24) | (b[at + 1]! << 16) | (b[at + 2]! << 8) | b[at + 3]!) >>> 0
  return { width: u32(16), height: u32(20) }
}

// Claude Code saves pasted images in <tmp>/<project>/<session>/images/<N>.png.
// Search the usual temp roots for the folder of this session.
async function findImagesDir($: EngineInterface): Promise<string | null> {
  const sessionId = await $.session.id()
  if (imagesDir?.sessionId === sessionId) return imagesDir.dir

  const bases = new Set<string>()
  const custom = await $.env.get('CLAUDE_CODE_TMPDIR')
  if (custom) bases.add(custom)
  bases.add('/private/tmp')
  bases.add('/tmp')

  const roots: string[] = []
  for (const base of bases) {
    roots.push(base)
    const entries = await $.fs.list(base).catch(() => [])
    for (const entry of entries) {
      if (entry.name.startsWith('claude')) roots.push(`${base}/${entry.name}`)
    }
  }

  for (const root of roots) {
    const projects = await $.fs.list(root).catch(() => [])
    for (const project of projects) {
      const dir = `${root}/${project.name}/${sessionId}/images`
      if (await $.fs.exists(dir)) {
        imagesDir = { sessionId, dir }
        return dir
      }
    }
  }

  // Not cached: the folder appears with the first paste.
  return null
}

async function loadImage($: EngineInterface, n: number): Promise<Found | null> {
  const dir = await findImagesDir($)
  if (!dir) return null

  const entries = await $.fs.list(dir).catch(() => [])
  const entry = entries.find(one => one.name.split('.')[0] === String(n))
  if (!entry || !entry.name.toLowerCase().endsWith('.png')) return null

  const path = `${dir}/${entry.name}`
  const cached = loadedFiles.get(path)
  if (cached && cached.mtimeMs === entry.mtimeMs) return cached.found

  const { base64 } = await $.fs.read(path, { as: 'bytes' })
  const found: Found = {
    n,
    path,
    ...pngSize(base64),
    png: entry.size <= MAX_INLINE_BYTES ? base64 : undefined,
  }
  loadedFiles.set(path, { mtimeMs: entry.mtimeMs, found })
  return found
}

async function track($: EngineInterface, text: string) {
  const next = chipsOf(text)
  const now = await read($, chips)
  if (!sameList(now, next)) await update($, chips, () => next)
}

// The box of cells for one picture: as tall as allowed, as wide as fits.
function fit(found: Found, budget: number, maxRows: number) {
  const aspect = found.width / found.height
  let rows = maxRows
  let columns = Math.round(rows * CELL_RATIO * aspect)
  if (columns > budget) {
    columns = budget
    rows = Math.round(columns / (CELL_RATIO * aspect))
  }
  return {
    columns: Math.max(1, Math.min(255, columns)),
    rows: Math.max(1, Math.min(255, rows)),
  }
}

export const register: Register = on => {
  on('prompt.edit', async ($, e, next) => {
    const box = await next(e)
    await track($, box.text)
    return box
  })

  on('prompt.change', async ($, e, next) => {
    await track($, e.text)
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const list = await read($, chips)
    if (e.surface !== 'terminal' || e.props.hasSurvey || list.length === 0) {
      return next(e)
    }

    const loaded = await Promise.all(
      list.map(n => loadImage($, n).catch(() => null)),
    )
    const { Box, Text, Image, Button } = $.ui.resolve(e)
    const below = await next(e)

    const budget = Math.max(
      8,
      Math.floor((e.props.bodyColumns - GAP * (list.length - 1)) / list.length) - LABEL_COLUMNS,
    )
    const maxRows = Math.max(1, Math.min(MAX_ROWS, e.props.maxRows - 1))

    const tiles = list.map((n, i) => {
      const found = loaded[i]
      if (!found) {
        return (
          <Box flexDirection="column" marginRight={GAP}>
            <Text dimColor>[Image #{n}] no preview</Text>
          </Box>
        )
      }

      const { columns, rows } = fit(found, budget, maxRows)
      const source = found.png
        ? { png: found.png }
        : { file: found.path, format: 'png' as const }

      return (
        <Box flexDirection="row" marginRight={GAP}>
          <Image
            key={`img-${n}`}
            source={source}
            columns={columns}
            rows={rows}
            alt={`[Image #${n}] ${found.width}x${found.height}`}
          />
          <Box flexDirection="column" marginLeft={1}>
            <Text dimColor>#{n}</Text>
            <Text dimColor>
              {found.width}x{found.height}
            </Text>
            <Button
              key={`open-${n}`}
              label="open"
              plain
              onPress={() => $.process.run(['open', found.path])}
            />
          </Box>
        </Box>
      )
    })

    return (
      <Box flexDirection="column">
        {below}
        <Box flexDirection="row">{tiles}</Box>
      </Box>
    )
  })
}
