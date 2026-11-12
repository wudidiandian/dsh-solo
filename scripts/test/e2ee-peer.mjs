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
  let core
  let interactions
  let hostCtx
  let desktopResolve
  let hostAbort
  if (process.env.DSH_TEST_HOST_CORDIS) {
    const { Context } = await import(process.env.DSH_TEST_HOST_CORDIS)
    const { InteractionBroker } = await import('../../packages/agent/dist/interactions.js')
    hostCtx = new Context()
    for (const event of ['approval/request', 'user-questions/request']) {
      hostCtx.on(event, request => new Promise(resolve => {
        desktopResolve = resolve
        request.signal.addEventListener('abort', () => resolve('cancelled'), { once: true })
      }))
    }
    interactions = new InteractionBroker({ changed: () => { void core?.publishSnapshot() },
      mobileAvailable: () => client.connectedMobileCount > 0 })
    interactions.install(hostCtx)
  }
  core = new AgentCore(client, {
    interactions,
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
    if (_line === 'approval-request' || _line === 'question-request') {
      if (!hostCtx) throw new Error('Real Host SDK fixture was not configured')
      const approval = _line === 'approval-request'
      hostAbort = new AbortController()
      const request = { agent: { sessionId: 'created-session' }, signal: hostAbort.signal,
        ...(approval ? { toolName: 'pwsh', reason: 'E2EE_APPROVAL_SENTINEL' } : {
          questions: [{ id: 'page', question: 'E2EE_QUESTION_SENTINEL', options: [{ label: 'Dashboard' }, { label: 'Game' }] }],
        }),
      }
      void hostCtx.waterfall({}, approval ? 'approval/request' : 'user-questions/request', request,
        () => approval ? 'unavailable' : Promise.reject(new Error('No answerer')))
        .then(outcome => process.stdout.write(JSON.stringify({ interactionSettled: true, outcome }) + '\n'),
          () => process.stdout.write('{"interactionCancelled":true}\n'))
      process.stdout.write('{"interactionRequested":true}\n')
      continue
    }
    if (_line === 'desktop-reject') { desktopResolve?.('rejected'); continue }
    if (_line === 'cancel-interaction') { hostAbort?.abort(); continue }
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
    interactions?.dispose(); core.stop(); client.stop(); await rm(stateDir, { recursive: true, force: true }); process.exit(0)
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
