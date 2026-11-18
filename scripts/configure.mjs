import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { resolve } from 'node:path'
const root = fileURLToPath(new URL('../', import.meta.url))
const explicit = process.env.DSH_CONFIG_FILE
let text
try { text = await readFile(resolve(root, explicit || 'config/distribution.local.json'), 'utf8') }
catch (error) {
  if (explicit || error.code !== 'ENOENT') throw error
  text = await readFile(resolve(root, 'config/distribution.example.json'), 'utf8')
}
const config = JSON.parse(text)
const url = new URL(config.relayUrl)
if (!['ws:', 'wss:'].includes(url.protocol) || url.username || url.password || url.hash) throw new Error('Invalid relayUrl')
if (!/^[a-zA-Z0-9.-]+$/.test(config.relayDomain || '')) throw new Error('Invalid relayDomain')
let intlUrl = ''
if (config.relayUrlIntl) {
  const parsed = new URL(config.relayUrlIntl)
  if (!['ws:', 'wss:'].includes(parsed.protocol) || parsed.username || parsed.password || parsed.hash) throw new Error('Invalid relayUrlIntl')
  intlUrl = config.relayUrlIntl
}
await mkdir(resolve(root, '.generated'), { recursive: true })
await writeFile(resolve(root, 'packages/agent/src/generated-defaults.ts'), 'export const defaultRelayUrl = ' + JSON.stringify(config.relayUrl) + '\n')
// DSH_INTL_RELAY 仅在配置了国际节点时注入，避免空串覆盖 App 侧 defaultValue
const defines = { DSH_DEFAULT_RELAY: config.relayUrl, DSH_LEGACY_RELAY: config.legacyRelayUrl || '' }
if (intlUrl) defines.DSH_INTL_RELAY = intlUrl
await writeFile(resolve(root, '.generated/flutter-defines.json'), JSON.stringify(defines))
await writeFile(resolve(root, '.generated/deploy.env'), 'RELAY_DOMAIN=' + config.relayDomain + '\n')
console.log('Distribution configuration generated (values omitted).')
