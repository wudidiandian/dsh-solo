// Test-only Node peer for Dart/Node interoperability and real Go-relay integration.
import { createInterface } from 'node:readline'
import { randomBytes } from 'node:crypto'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { acceptSecureHello } from '../../packages/agent/dist/e2ee.js'
const token = 'secure-test-token'
const key = Buffer.alloc(32, 7).toString('base64url')
const lines = createInterface({ input: process.stdin })
let channel
if (process.argv[2] === '--agent') {
  const { SoloRelayClient } = await import('../../packages/agent/dist/ws-client.js')
  const { AgentCore } = await import('../../packages/agent/dist/core.js')
  const stateDir = await mkdtemp(join(tmpdir(), 'dsh-secure-peer-'))
  const client = new SoloRelayClient({ url: process.argv[3], deviceToken: token, encryptionKey: key, backoffBaseMs: 50 })
  let callback
  let activeKey = key
  const core = new AgentCore(client, {
    rotateDeviceToken: async nextToken => { activeKey = randomBytes(32).toString('base64url'); client.reconnectWithToken(nextToken, activeKey) },
    deviceToken: token, stateDir, historyDir: join(stateDir, 'history'),
    services: {
      listModels: async () => [{ id: 'secret-model' }],
      listSessions: async () => [{ id: 'private-session', title: 'E2EE_CONTENT_SENTINEL' }],
      listProjects: async () => [{ id: 'secret-project', title: 'E2EE_PROJECT_SENTINEL' }],
      createSession: async () => ({ id: 'created-session', setModel: async () => {}, submitPrompt: async (prompt) => {
        callback?.('created-session', { kind: 'text.delta', text: prompt });
        callback?.('created-session', { kind: 'turn.completed' });
      } }),
      getSession: async () => null,
      renameSession: async () => {}, deleteSession: async () => {},
      onSessionEvent: cb => { callback = cb; return () => {} }, registerApprovalHandler: () => {},
    },
  })
  client.on('error', () => {})
  client.once('connected', () => process.stdout.write('{"ready":true}\n'))
  core.start()
  client.start()
  for await (const _line of lines) {
    if (_line === 'burst') {
      callback?.('created-session', { kind: 'turn/start' })
      for (let round = 0; round < 20; round++) {
        for (let i = 0; i < 100; i++) core.sendStreamDelta('created-session', 'text-delta', '字🚀')
        await new Promise(resolve => setTimeout(resolve, 10))
      }
      callback?.('created-session', { kind: 'assistant/message', text: '字🚀'.repeat(2000) })
      callback?.('created-session', { kind: 'turn/end' })
      process.stdout.write('{"burstComplete":true}\n')
      continue
    }
    if (_line === 'offline-completion') {
      callback?.('created-session', { kind: 'assistant/message', text: 'OFFLINE_FINAL_SENTINEL' })
      callback?.('created-session', { kind: 'turn/end' })
      process.stdout.write('{"offlineComplete":true}\n')
      continue
    }
    if (_line === 'rotate') { const token = await core.resetDeviceToken(); process.stdout.write(JSON.stringify({ token, key: activeKey }) + '\n'); continue }
    core.stop(); client.stop(); await rm(stateDir, { recursive: true, force: true }); process.exit(0)
  }
} else {
  for await (const line of lines) {
    try {
      const request = JSON.parse(line)
      if (request.op === 'hello') {
        const accepted = acceptSecureHello(token, key, request.hello)
        channel = accepted.channel
        process.stdout.write(JSON.stringify(accepted.welcome) + '\n')
      } else {
        const plain = channel.open(request.packet)
        process.stdout.write(JSON.stringify({ plain, packet: channel.seal({ v: 1, type: 'rpc.response', reqId: plain.reqId, payload: { ok: true, result: plain.payload } }) }) + '\n')
      }
    } catch { process.stdout.write('{"error":"authentication failed"}\n') }
  }
}
