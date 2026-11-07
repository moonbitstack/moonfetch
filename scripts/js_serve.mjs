// A second HTTP implementation for the tests of the browser host: Node's own `http` module,
// which knows nothing of this library. The js host is exercised against it with
// `MOONFETCH_LIVE` set to the base URL it prints, so the peer in the test is somebody else's
// server rather than this repository's.
//
// Usage: node scripts/js_serve.mjs [--port 0]
// It prints two base URLs, one per listener, then serves until killed.

import http from 'node:http'
import zlib from 'node:zlib'

const args = process.argv.slice(2)
const at = args.indexOf('--port')
const wanted = at >= 0 ? Number(args[at + 1]) : 0

const PLAIN = { 'content-type': 'text/plain' }

function pattern(n) {
  const out = Buffer.alloc(n)
  for (let i = 0; i < n; i++) out[i] = i % 251
  return out
}

// The sum the client computes in 32-bit integers, so that the two agree after an overflow.
function digest(body) {
  let sum = 0
  for (const b of body) sum = ((Math.imul(sum, 31) + b) | 0) % 1000000007
  return `${body.length}:${sum}`
}

function echo(req, query, body) {
  const header = name => req.headers[name] ?? ''
  return JSON.stringify({
    method: req.method,
    query,
    body: body.toString('latin1'),
    type: header('content-type'),
    agent: header('user-agent'),
    auth: header('authorization'),
    extra: header('x-extra'),
    version: `HTTP/${req.httpVersion}`,
    length: header('content-length'),
    cookie: header('cookie'),
    origin: header('origin'),
  })
}

function multipart(body, boundary) {
  const parts = []
  const mark = `--${boundary}`
  let at = body.indexOf(mark)
  while (at >= 0) {
    const next = body.indexOf(mark, at + mark.length)
    if (next < 0) break
    const block = body.subarray(at + mark.length + 2, next - 2)
    const split = block.indexOf('\r\n\r\n')
    if (split >= 0) {
      const head = block.subarray(0, split).toString('latin1')
      const content = block.subarray(split + 4)
      const name = /name="([^"]*)"/.exec(head)?.[1] ?? ''
      const filename = /filename="([^"]*)"/.exec(head)?.[1] ?? ''
      parts.push({ name, filename, body: content.toString('latin1') })
    }
    at = next
  }
  return JSON.stringify(parts)
}

async function route(req, body, other) {
  const path = req.url.split('?')[0]
  const query = req.url.includes('?') ? req.url.split('?')[1] : ''

  if (path === '/') return [200, PLAIN, Buffer.from('hello')]
  if (path === '/echo') return [200, { 'content-type': 'application/json' }, Buffer.from(echo(req, query, body))]
  if (path === '/multipart') {
    const kind = req.headers['content-type'] ?? ''
    const boundary = /boundary=([^;]+)/.exec(kind)?.[1] ?? ''
    return [200, { 'content-type': 'application/json' }, Buffer.from(multipart(body, boundary))]
  }
  if (path === '/upload') return [200, PLAIN, Buffer.from(digest(body))]
  if (path === '/big') return [200, { 'content-type': 'application/octet-stream' }, pattern(Number(query.replace('n=', '')) || 0)]
  if (path === '/gzip') {
    return [200, { ...PLAIN, 'content-encoding': 'gzip' }, zlib.gzipSync(Buffer.from('compressed hello'))]
  }
  if (path === '/deflate') {
    return [200, { ...PLAIN, 'content-encoding': 'deflate' }, zlib.deflateSync(Buffer.from('zlib hello'))]
  }
  if (path === '/raw-deflate') {
    return [200, { ...PLAIN, 'content-encoding': 'deflate' }, zlib.deflateRawSync(Buffer.from('bare hello'))]
  }
  if (path === '/chunked') return [200, PLAIN, Buffer.from('in pieces')]
  if (path === '/eof') return [200, PLAIN, Buffer.from('to the close')]
  if (path === '/steps') return [200, PLAIN, Buffer.from('one-two-three')]
  if (path === '/see-other') return [303, { location: '/echo' }, Buffer.alloc(0)]
  if (path === '/found') return [302, { location: '/echo' }, Buffer.alloc(0)]
  if (path === '/keep') return [307, { location: '/echo' }, Buffer.alloc(0)]
  if (path === '/loop') return [302, { location: '/loop' }, Buffer.alloc(0)]
  if (path === '/away') return [302, { location: `http://localhost:${other}/echo` }, Buffer.alloc(0)]
  if (path === '/slow') {
    await new Promise(done => setTimeout(done, 2000))
    return [200, PLAIN, Buffer.from('late')]
  }
  if (path.startsWith('/redirect/')) {
    const n = Number(path.slice(10))
    return n <= 0 ? [200, PLAIN, Buffer.from('landed')] : [302, { location: `/redirect/${n - 1}` }, Buffer.alloc(0)]
  }
  if (path.startsWith('/status/')) return [Number(path.slice(8)) || 500, PLAIN, Buffer.alloc(0)]
  return [404, PLAIN, Buffer.from('no such route')]
}

function listener(elsewhere) {
  return http.createServer((req, res) => {
    const chunks = []
    req.on('data', piece => chunks.push(piece))
    req.on('end', async () => {
      const body = Buffer.concat(chunks)
      const [status, headers, payload] = await route(req, body, elsewhere())
      const path = req.url.split('?')[0]
      if (path === '/eof') {
        // No length and no chunking: the body ends where the connection does.
        res.useChunkedEncodingByDefault = false
        res.writeHead(200, { ...PLAIN, connection: 'close' })
        res.write(payload)
        res.socket.end()
        return
      }
      if (path === '/truncate') {
        res.writeHead(200, { ...PLAIN, 'content-length': '100' })
        res.write(payload)
        res.socket.end()
        return
      }
      if (path === '/steps') {
        res.writeHead(200, PLAIN)
        for (const piece of payload.toString().split(/(?<=-)/)) {
          res.write(piece)
          await new Promise(done => setTimeout(done, 150))
        }
        res.end()
        return
      }
      res.writeHead(status, headers)
      res.end(req.method === 'HEAD' ? undefined : payload)
    })
  })
}

const ports = { one: 0, two: 0 }
// `/away` names the other listener, whose port is only known once both are listening.
const first = listener(() => ports.two)
const second = listener(() => ports.one)
await new Promise(done => first.listen(wanted, '127.0.0.1', done))
ports.one = first.address().port
await new Promise(done => second.listen(0, '127.0.0.1', done))
ports.two = second.address().port
console.log(`MOONFETCH_LIVE=http://127.0.0.1:${ports.one}`)
console.log(`MOONFETCH_LIVE_OTHER=http://localhost:${ports.two}`)
