// Raw channel wire v2 fixture for the ChannelSwift tests: plain Bun.serve, no channel library.
// Implements the routes of PROTOCOL.md §7 (plus `hello`, `echo`, `auth` and `auth/name` from the TS fixture).
//
//   bun Tests/Fixture/server.ts          # listens on CHANNEL_FIXTURE_PORT, default 2051
//
// The tests start it on their own when nothing listens on the port. With FIXTURE_PARENT_PID set, it exits when that
// process is gone.
import type { ServerWebSocket } from 'bun'

interface State {
  headers: Record<string, string>
  name?: string
  rate: number[]
}
type Socket = ServerWebSocket<State>
type Context = { body: any; state: State; ws: Socket }

const port = Number(process.env.CHANNEL_FIXTURE_PORT ?? 2051)
let drops = 0

class Failure {
  constructor(
    public message: string,
    public code?: string | number,
    public info?: any,
  ) {}
}

const posts: Record<string, (ctx: Context) => any> = {
  hello: () => 'world',
  echo: ({ body }) => body,
  auth: ({ body, state }) => (state.name = body?.name),
  'auth/name': ({ state }) => {
    if (!state.name) throw 'unauthorized'
    return state.name
  },
  'v2/error': () => {
    throw new Failure('banned', 403, { remaining: 5 })
  },
  'v2/error/code': () => {
    throw new Failure('slow down', 'rate_limited', { retryAfter: 1 })
  },
  'v2/never': () => new Promise(() => {}),
  'v2/drop': ({ ws }) => {
    drops += 1
    ws.close()
    return new Promise(() => {})
  },
  'v2/drops': () => drops,
  'v2/drops/reset': () => {
    drops = 0
    return null
  },
  'v2/headers': ({ state }) => state.headers,
  'v2/rate': ({ state }) => {
    const now = Date.now()
    state.rate = state.rate.filter(time => now - time < 1000)
    if (state.rate.length >= 2) {
      throw new Failure('rate limited', 'rate_limited', {
        retryAfter: Math.max(1, Math.ceil((state.rate[0] + 1000 - now) / 1000)),
      })
    }
    state.rate.push(now)
    return null
  },
  'v2/publish': ({ body }) => {
    const message: any = { topic: 'room/' + body.room }
    if (body.body !== undefined) message.body = body.body
    server.publish(message.topic, JSON.stringify(message))
    return null
  },
}

const subs: Record<string, (ctx: Context) => { topic?: string; body?: any }> = {
  'v2/room': ({ body }) => ({ topic: 'room/' + body.room, body: 'joined' }),
  'v2/once': () => ({ body: 'once' }),
  'v2/private': ({ state }) => {
    if (!state.name) throw new Failure('unauthorized', 401)
    return { topic: 'private/' + state.name, body: state.name }
  },
}

function errorReply(id: number, e: any) {
  const reply: any = { id }
  if (typeof e === 'string') {
    reply.error = e
  } else if (e && typeof e.message === 'string') {
    reply.error = e.message
    if (e.code !== undefined) reply.code = e.code
    if (e.info !== undefined) reply.info = e.info
  } else {
    reply.error = String(e)
  }
  if (!reply.error) reply.error = 'error'
  return reply
}

function send(ws: Socket, message: any) {
  if (ws.readyState === 1) ws.send(JSON.stringify(message))
}

async function receive(ws: Socket, message: any) {
  const ctx: Context = { body: message.body, state: ws.data, ws }
  if (typeof message.path === 'string') {
    const handler = posts[message.path]
    if (!handler) return send(ws, { id: message.id, error: 'api not found', code: 'not_found' })
    try {
      const body = await handler(ctx)
      send(ws, body === undefined ? { id: message.id } : { id: message.id, body })
    } catch (e) {
      send(ws, errorReply(message.id, e))
    }
  } else if (typeof message.sub === 'string') {
    const handler = subs[message.sub]
    if (!handler) return send(ws, { id: message.id, error: 'subscription not found', code: 'not_found' })
    try {
      const { topic, body } = handler(ctx)
      if (topic) ws.subscribe(topic)
      const reply: any = { id: message.id }
      if (topic) reply.topic = topic
      if (body !== undefined) reply.body = body
      send(ws, reply)
    } catch (e) {
      send(ws, errorReply(message.id, e))
    }
  } else if (typeof message.unsub === 'string') {
    ws.unsubscribe(message.unsub)
  }
  // `{ cancel }`, stream requests and responses are ignored
}

const server = Bun.serve<State, {}>({
  hostname: '127.0.0.1',
  port,
  fetch(request, server) {
    const headers: Record<string, string> = {}
    request.headers.forEach((value, key) => (headers[key] = value))
    if (server.upgrade(request, { data: { headers, rate: [] } })) return
    return new Response('websocket only', { status: 400 })
  },
  websocket: {
    message(ws, data) {
      if (typeof data !== 'string') return
      let value: any
      try {
        value = JSON.parse(data)
      } catch {
        return ws.close()
      }
      for (const message of Array.isArray(value) ? value : [value]) {
        if (message && typeof message === 'object') receive(ws, message)
      }
    },
  },
})
console.log(`listening ${server.port}`)

const parent = Number(process.env.FIXTURE_PARENT_PID)
if (parent) {
  setInterval(() => {
    try {
      process.kill(parent, 0)
    } catch {
      process.exit(0)
    }
  }, 500)
}
