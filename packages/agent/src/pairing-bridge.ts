import QRCode from 'qrcode'
import { pairUri } from './pairing.js'

export const PAIRING_ENDPOINT = 'dsh-solo-pairing'
interface Route {
  path: string
  methods: readonly ['POST']
  requestBody: 'buffered'
  fetch(request: Request): Promise<Response>
}
export interface PairingConnection {
  /** Connection exact routes run only after Host authentication and an owner-Peer check. */
  fetch: { register(route: Route): () => unknown }
}
interface Options {
  getToken(): string
  getRelayUrl(): string
  getBrowserUrl(): string | null
  isConnected(): boolean
  isActive(): boolean
  resetToken(): Promise<string>
}

/** Use owner-only shared /api routes: these also work through the desktop carrier. */
export function registerPairingBridge(connection: PairingConnection, options: Options): () => void {
  const disposers: Array<() => unknown> = []
  const fail = (code: string, message: string) => ({ ok: false, error: { code, message, details: {} } })
  try {
    for (const operation of ['read', 'reveal', 'reset']) {
      const endpoint = `${PAIRING_ENDPOINT}/${operation}`
      disposers.push(connection.fetch.register({
        path: `/api/${endpoint}`, methods: ['POST'], requestBody: 'buffered',
        async fetch(request) {
          const headers = { 'cache-control': 'no-store' }
          let body
          try { body = await request.json() } catch { return new Response('Invalid request', { status: 400, headers }) }
          if (body?.type !== 'client-request' || typeof body.rpcId !== 'string' || !body.rpcId || body.rpcId.length > 200 || body.method !== endpoint ||
              !body.payload || typeof body.payload !== 'object' || Array.isArray(body.payload) || Object.keys(body.payload).length) {
            return new Response('Invalid request', { status: 400, headers })
          }
          const respond = (result: unknown) => Response.json({ type: 'server-response', rpcId: body.rpcId, result }, { headers })
          const active = () => !request.signal.aborted && options.isActive()
          if (!active()) return respond(fail('unavailable', 'Pairing is unavailable'))
          try {
            if (operation === 'reveal') return respond({ ok: true, value: { token: options.getToken() } })
            if (operation === 'reset') await options.resetToken()
            if (!active()) return respond(fail('unavailable', 'Pairing is unavailable'))
            const token = options.getToken()
            const qrSvg = await QRCode.toString(pairUri(options.getRelayUrl(), token), { type: 'svg', margin: 1 })
            if (!active()) return respond(fail('unavailable', 'Pairing is unavailable'))
            return respond({ ok: true, value: {
              qrSvg,
              maskedToken: (token.startsWith('dsh-solo-') ? 'dsh-solo-' : '') + '•'.repeat(12),
              browserUrl: options.getBrowserUrl(),
              relayConnected: options.isConnected(),
            } })
          } catch {
            return respond(fail('pairing-failed', 'Pairing operation failed'))
          }
        },
      }))
    }
  } catch (error) {
    for (const dispose of disposers) void dispose()
    throw error
  }
  return () => { for (const dispose of disposers.splice(0)) void dispose() }
}
