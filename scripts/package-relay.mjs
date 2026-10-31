import { mkdir, copyFile, readFile, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'

const root = fileURLToPath(new URL('../', import.meta.url))
const output = resolve(root, '.generated/monitor-handoff')
const manifest = JSON.parse(await readFile(resolve(root, 'package.json'), 'utf8'))
await mkdir(output, { recursive: true })
function run(command, args, options = {}) {
  const result = spawnSync(command, args, { cwd: root, stdio: 'inherit', ...options })
  if (result.status !== 0) throw new Error(`${command} failed (${result.status ?? result.error?.message})`)
}
const files = []
for (const architecture of ['amd64', 'arm64']) {
  const name = `relay-linux-${architecture}`
  run('go', ['build', '-trimpath', '-ldflags=-s -w', '-o', resolve(output, name), './cmd/relay'], {
    cwd: resolve(root, 'server'), env: { ...process.env, GOOS: 'linux', GOARCH: architecture, CGO_ENABLED: '0' },
  })
  files.push(name)
}
for (const name of ['MONITORING.md', 'monitor.env.example', 'relay-monitor.conf']) {
  await copyFile(resolve(root, 'deploy', name), resolve(output, name))
  files.push(name)
}
const commit = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' })
const status = spawnSync('git', ['status', '--porcelain', '--untracked-files=all', '--', 'server', 'deploy'], { cwd: root, encoding: 'utf8' })
await writeFile(resolve(output, 'BUILD.json'), JSON.stringify({
  version: manifest.version, builtAt: new Date().toISOString(),
  sourceCommit: commit.status === 0 ? commit.stdout.trim() : null,
  sourceWorktreeDirty: status.status === 0 ? Boolean(status.stdout.trim()) : null,
  targets: ['linux/amd64', 'linux/arm64'],
  note: 'Local handoff build. No deployment or npm publication is performed.',
}, null, 2) + '\n')
files.push('BUILD.json')
const sums = []
for (const name of files) sums.push(`${createHash('sha256').update(await readFile(resolve(output, name))).digest('hex')}  ${name}`)
await writeFile(resolve(output, 'SHA256SUMS'), sums.join('\n') + '\n')
files.push('SHA256SUMS')
const archive = resolve(root, `.generated/dsh-solo-relay-monitor-${manifest.version}.tar.gz`)
run('tar', ['-czf', archive, '-C', output, ...files])
console.log(`Relay handoff created: ${archive}`)
