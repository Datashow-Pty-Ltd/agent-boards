import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtemp, readdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import test from 'node:test'
import {
  contentAddressedUploadFilename,
  externaliseInlineAssets,
  managedUploadFilename,
  mediaExtensions,
  parseInlineMedia,
  storeInlineMedia,
} from '../src/inlineMedia.ts'

const serverSource = await readFile(new URL('../src/server.ts', import.meta.url), 'utf8')
const mediaSource = await readFile(new URL('../src/media.ts', import.meta.url), 'utf8')
const migrationSource = await readFile(
  new URL('../../../database/migrations/041-externalise-inline-asset-media.sql', import.meta.url),
  'utf8',
)

const png = Buffer.from('89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489', 'hex')
const pngDataUrl = `data:image/png;base64,${png.toString('base64')}`
const pngUploadUrl = `/uploads/${createHash('sha256').update(png).digest('hex')}.png`
const truncatedDataUrl = `data:image/png;base64,${png.toString('base64').slice(0, 12)}...1050437bytesomitted...AAAA`

async function withDirectory(run) {
  const directory = await mkdtemp(path.join(tmpdir(), 'agent-boards-inline-'))
  try {
    return await run(directory)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
}

/** In-memory stand-in for the PostgREST routes the backfill uses, enforcing migration 041's rules. */
function fakeBoardApi(rows) {
  const table = new Map(rows.map((row) => [row.id, { ...row }]))
  const calls = []
  const rest = async (requestPath, init = {}) => {
    calls.push(requestPath)
    if (requestPath.startsWith('/rpc/externalise_inline_work_item_asset_media')) {
      const body = JSON.parse(init.body)
      const row = table.get(body.target_asset_id)
      for (const [field, expected] of [['source_url', body.expected_source_url], ['thumbnail_url', body.expected_thumbnail_url]]) {
        if (expected === null || row[field] === expected) continue
        if (parseInlineMedia(row[field] ?? '')?.url !== expected) throw new Error('Board API 400: media does not match')
        row[field] = expected
      }
      return [row]
    }
    const url = new URL(requestPath, 'http://board')
    if (url.searchParams.has('or')) {
      return [...table.values()]
        .filter((row) => row.source_url.startsWith('data:') || row.thumbnail_url?.startsWith('data:'))
        .map(({ id }) => ({ id }))
    }
    const id = url.searchParams.get('id')?.replace(/^eq\./, '')
    const row = table.get(id)
    return row ? [{ id: row.id, source_url: row.source_url, thumbnail_url: row.thumbnail_url }] : []
  }
  return { table, calls, rest }
}

test('inline media decodes to a content-addressed upload URL', () => {
  const media = parseInlineMedia(pngDataUrl)
  assert.equal(media.url, pngUploadUrl)
  assert.equal(media.mimeType, 'image/png')
  assert.deepEqual(media.buffer, png)
  assert.equal(parseInlineMedia(pngDataUrl.replace('data:image/png', 'data:IMAGE/PNG'))?.url, pngUploadUrl)
  assert.match(parseInlineMedia(`data:image/gif;base64,${Buffer.from('GIF89a').toString('base64')}`).url, /\.gif$/)
})

test('truncated, unpadded, unsupported and non-data URLs are refused', () => {
  assert.equal(parseInlineMedia(truncatedDataUrl), null)
  assert.equal(parseInlineMedia(pngDataUrl.slice(0, -1)), null)
  assert.equal(parseInlineMedia(`data:image/svg+xml;base64,${Buffer.from('<svg/>').toString('base64')}`), null)
  assert.equal(parseInlineMedia('data:image/png,not-base64'), null)
  assert.equal(parseInlineMedia('data:constructor;base64,AAAA'), null)
  assert.equal(parseInlineMedia('https://example.test/a.png'), null)
})

test('the SQL decoder accepts exactly the media types the MCP service stores', () => {
  const sqlTypes = [...migrationSource.matchAll(/WHEN '([a-z]+\/[a-z0-9.+-]+);base64' THEN '([a-z0-9]+)'/g)]
    .map(([, mimeType, extension]) => [mimeType, extension])
  assert.deepEqual(Object.fromEntries(sqlTypes), mediaExtensions)
  assert.match(migrationSource, /encode\(sha256\(decode\(payload, 'base64'\)\), 'hex'\)/)
  assert.match(migrationSource, /length\(payload\) % 4 <> 0 OR payload !~ '\^\[A-Za-z0-9\+\/\]\*=\{0,2\}\$'/)
})

test('storing inline media is atomic and idempotent', () => withDirectory(async (directory) => {
  const first = await storeInlineMedia(pngDataUrl, directory)
  const second = await storeInlineMedia(pngDataUrl, directory)
  assert.equal(first.url, pngUploadUrl)
  assert.equal(first.created, true)
  assert.equal(second.created, false)
  assert.deepEqual(await readdir(directory), [path.basename(pngUploadUrl)])
  assert.deepEqual(await readFile(path.join(directory, path.basename(pngUploadUrl))), png)
  await assert.rejects(storeInlineMedia(truncatedDataUrl, directory), /complete base64 data: URL/)
}))

test('a damaged file with the same name is replaced', () => withDirectory(async (directory) => {
  await writeFile(path.join(directory, path.basename(pngUploadUrl)), png.subarray(0, 4))
  await storeInlineMedia(pngDataUrl, directory)
  assert.deepEqual(await readFile(path.join(directory, path.basename(pngUploadUrl))), png)
}))

test('content-addressed uploads are served but never deleted by request handlers', () => {
  const name = path.basename(pngUploadUrl)
  assert.match(name, managedUploadFilename)
  assert.match(name, contentAddressedUploadFilename)
  assert.doesNotMatch('3f2b1c4e-0d6a-4f1e-9a51-2a7c1d9e8b10.png', contentAddressedUploadFilename)
  assert.match(serverSource, /if \(!contentAddressedUploadFilename\.test\(request\.params\.filename\)\) await deleteStoredMedia\(url\)/)
  assert.match(mediaSource, /contentAddressedUploadFilename\.test\(filename\)\) return;/)
})

test('backfill moves inline media without touching ids, approvals or revisions, and is idempotent', () => withDirectory(async (directory) => {
  const approved = {
    id: 'a1', source_url: pngDataUrl, thumbnail_url: pngDataUrl, approval_status: 'approved', approved_by: 'You',
    revision: 'abc1234', recording_review_status: 'not_required',
  }
  const damaged = { id: 'a2', source_url: truncatedDataUrl, thumbnail_url: null, approval_status: 'candidate', revision: null }
  const managed = { id: 'a3', source_url: '/uploads/existing.png', thumbnail_url: null, approval_status: 'candidate', revision: null }
  const board = fakeBoardApi([approved, damaged, managed])

  const first = await externaliseInlineAssets({ rest: board.rest, directory })
  assert.deepEqual(
    { candidates: first.candidates, converted: first.converted, unchanged: first.unchanged, undecodable: first.undecodable, failed: first.failed },
    { candidates: 2, converted: 1, unchanged: 1, undecodable: ['a2'], failed: [] },
  )
  assert.deepEqual(board.table.get('a1'), { ...approved, source_url: pngUploadUrl, thumbnail_url: pngUploadUrl })
  assert.deepEqual(board.table.get('a2'), damaged)
  assert.deepEqual(board.table.get('a3'), managed)
  assert.deepEqual(await readdir(directory), [path.basename(pngUploadUrl)])

  const second = await externaliseInlineAssets({ rest: board.rest, directory })
  assert.equal(second.converted, 0)
  assert.equal(second.candidates, 1)
  assert.deepEqual(board.table.get('a1'), { ...approved, source_url: pngUploadUrl, thumbnail_url: pngUploadUrl })
}))

test('database refuses new inline media but leaves existing rows editable', () => {
  assert.match(migrationSource, /BEFORE INSERT OR UPDATE OF source_url, thumbnail_url ON api\.work_item_assets/)
  assert.match(migrationSource, /TG_OP = 'INSERT' OR NEW\.source_url IS DISTINCT FROM OLD\.source_url\) AND substr\(NEW\.source_url, 1, 5\) = 'data:'/)
  assert.match(migrationSource, /TG_OP = 'INSERT' OR NEW\.thumbnail_url IS DISTINCT FROM OLD\.thumbnail_url\) AND substr\(NEW\.thumbnail_url, 1, 5\) = 'data:'/)
  assert.match(migrationSource, /NOTIFY pgrst, 'reload schema';/)
})

test('database only accepts the upload URL derived from the row and preserves review state', () => {
  assert.match(migrationSource, /IF api\.inline_media_upload_url\(asset\.source_url\) IS DISTINCT FROM expected_source_url THEN/)
  assert.match(migrationSource, /SET source_url = next_source, thumbnail_url = next_thumbnail\r?\n/)
  // The recording contract trigger fires only on asset_type or recording_manifest updates.
  assert.doesNotMatch(migrationSource, /recording_manifest|approval_status|recording_review_status\s*=/)
  assert.match(migrationSource, /CREATE OR REPLACE FUNCTION api\.card_image_url\(asset api\.work_item_assets\)/)
})

test('MCP attachments store inline media before the row is written and the backfill runs on start', () => {
  const attach = serverSource.slice(serverSource.indexOf('"attach_work_item_asset",'), serverSource.indexOf('"attach_validation_recording",'))
  assert.ok(attach.indexOf('storeAttachmentMedia(') < attach.indexOf('/rpc/attach_work_item_asset'))
  assert.match(attach, /asset_mime_type: sourceMimeType \?\? mimeType/)
  assert.match(serverSource, /startInlineAssetExternalisation\(\)/)
})
