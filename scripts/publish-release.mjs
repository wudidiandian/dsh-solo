import { spawnSync } from 'node:child_process'
import { readFile, writeFile, stat, mkdir } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { resolve, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { assertTagCommit, releaseVersion, validateRepository } from './prepare-release.mjs'

const root = fileURLToPath(new URL('../', import.meta.url))
const metadata = JSON.parse(await readFile(resolve(root, '.generated/release-metadata.json'), 'utf8'))
const { version, tag, repository, sourceRepository, sourceCommit, appBuildNumber } = metadata
releaseVersion({ rootVersion: version, pluginVersion: version, appVersion: `${version}+${appBuildNumber}` })
validateRepository(repository)
validateRepository(sourceRepository)
if (repository !== sourceRepository || (process.env.GITHUB_REPOSITORY && repository !== process.env.GITHUB_REPOSITORY)) throw new Error('Releases must target the current source repository')
if (tag !== `v${version}` || !/^[0-9a-f]{40}$/.test(sourceCommit)) throw new Error('Invalid release metadata')
const token = process.env.GH_TOKEN
if (!token) throw new Error('Release authentication is required')
function run(command, args, { allowMissing = false, env = process.env } = {}) {
  const result = spawnSync(command, args, { cwd: root, env, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 })
  if (result.status !== 0 && !allowMissing) throw new Error(`${command} failed: ${result.stderr || result.error?.message || result.status}`)
  return result
}
function ghJson(args) { return JSON.parse(run('gh', args).stdout) }
const actualCommit = run('git', ['rev-parse', 'HEAD']).stdout.trim()
if (actualCommit !== sourceCommit) throw new Error('The checkout changed after release preparation')
// Check access before creating tags. Never embed credentials in remote URLs or CLI arguments.
ghJson(['api', `repos/${repository}`])
const auth = Buffer.from(`x-access-token:${token}`).toString('base64')
if (process.env.GITHUB_ACTIONS) console.log(`::add-mask::${auth}`)
const gitEnv = { ...process.env, GIT_TERMINAL_PROMPT: '0', GIT_CONFIG_COUNT: '2',
  GIT_CONFIG_KEY_0: 'http.https://github.com/.extraheader', GIT_CONFIG_VALUE_0: `AUTHORIZATION: basic ${auth}`,
  GIT_CONFIG_KEY_1: 'credential.helper', GIT_CONFIG_VALUE_1: '' }
const remote = `https://github.com/${repository}.git`
const refs = run('git', ['ls-remote', remote, `refs/tags/${tag}`, `refs/tags/${tag}^{}`], { env: gitEnv }).stdout
const tagExists = assertTagCommit(refs, tag, sourceCommit)
const found = run('gh', ['release', 'view', tag, '--repo', repository, '--json', 'isDraft,body'], { allowMissing: true })
const marker = `<!-- dsh-solo-source:${sourceRepository}@${sourceCommit} -->`
if (found.status === 0) {
  const existing = JSON.parse(found.stdout)
  if (!existing.isDraft) throw new Error('This release is already published; published assets are not overwritten')
  if (!existing.body.includes(marker)) throw new Error('An unrelated draft already uses this version')
}
const output = resolve(root, 'release')
await mkdir(output, { recursive: true })
const files = [`dsh-solo-agent-${version}.tgz`, 'dsh-solo.apk', 'BUILD.json']
for (const name of files.slice(0, 2)) if (!(await stat(join(output, name))).isFile()) throw new Error(`Missing release asset: ${name}`)
await writeFile(join(output, 'BUILD.json'), JSON.stringify({ ...metadata, builtAt: new Date().toISOString(), androidBuild: 'release' }, null, 2) + '\n')
const sums = []
for (const name of files) sums.push(`${createHash('sha256').update(await readFile(join(output, name))).digest('hex')}  ${name}`)
await writeFile(join(output, 'SHA256SUMS'), sums.join('\n') + '\n')
files.push('SHA256SUMS')
const notes = `${marker}\n# DSH-SOLO ${version}\n\n- DeepSeek Harness 官方桌面版：插件 → 添加插件，输入 \`dsh-solo-agent\`。\n- Android：下载并安装下方 \`dsh-solo.apk\`，从“手机配对”扫码连接。\n- 离线安装插件：解压 \`dsh-solo-agent-${version}.tgz\`，选择包含 package.json 的 package 目录。\n- 校验文件：SHA256SUMS；构建来源：BUILD.json。\n\nSource: ${sourceRepository}@${sourceCommit}\n\n本工作流发布 GitHub 安装包；npm 发布和服务器部署分别执行。\n`
const notesFile = resolve(root, '.generated/release-notes.md')
await writeFile(notesFile, notes)
if (!tagExists) {
  const local = run('git', ['rev-parse', '--verify', `refs/tags/${tag}^{commit}`], { allowMissing: true })
  if (local.status === 0 && local.stdout.trim() !== sourceCommit) throw new Error('The local tag points to another commit')
  if (local.status !== 0) {
    run('git', ['-c', 'user.name=github-actions[bot]', '-c', 'user.email=41898282+github-actions[bot]@users.noreply.github.com', 'tag', '-a', tag, sourceCommit, '-m', `DSH-SOLO ${version}`])
  }
  // The tag references the exact built commit in the current source repository.
  run('git', ['push', remote, `refs/tags/${tag}:refs/tags/${tag}`], { env: gitEnv })
}
if (found.status !== 0) run('gh', ['release', 'create', tag, '--repo', repository, '--verify-tag', '--draft', '--title', `DSH-SOLO ${version}`, '--notes-file', notesFile])
run('gh', ['release', 'upload', tag, ...files.map(name => join(output, name)), '--repo', repository, '--clobber'])
const assets = ghJson(['release', 'view', tag, '--repo', repository, '--json', 'assets']).assets
for (const name of files) {
  const remoteAsset = assets.find(asset => asset.name === name)
  if (!remoteAsset || remoteAsset.size !== (await stat(join(output, name))).size) throw new Error(`Upload verification failed: ${name}`)
}
// Build/upload failures leave a draft; only a complete set of assets becomes visible as latest.
run('gh', ['release', 'edit', tag, '--repo', repository, '--draft=false', '--latest'])
console.log(`Published https://github.com/${repository}/releases/tag/${tag}`)
