// The TypeScript reference's interop fixture (channel/tests/server.ts) for the QUIC tests: its routes over WebSocket
// on TCP and QUIC on UDP, both on CHANNEL_TEST_PORT. With QUIC_KEY and QUIC_CERT (PEM files) it also serves them over
// QUIC on the next port with that certificate, since Apple platforms only trust certificates of at most 825 days with
// the serverAuth extended key usage, which the reference's test certificate isn't. With FIXTURE_PARENT_PID set, it
// exits when that process is gone.
import { readFileSync } from 'node:fs'

const { channel, quicServer } = await import('../../../channel/tests/server.ts')
const { QUIC_KEY: key, QUIC_CERT: cert } = process.env
if (key && cert) {
  await channel.listenQuic(quicServer.port + 1, {
    key: readFileSync(key),
    cert: readFileSync(cert),
    state: headers => ({ id: 0, headers }),
  })
}
console.log(`listening ${quicServer.port}`)

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
