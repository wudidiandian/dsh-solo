import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = fileURLToPath(new URL('../', import.meta.url))
export const DEFAULT_RELEASE_REPOSITORY = 'wudidiandian/dsh-solo'
export function releaseVersion({ rootVersion, pluginVersion, appVersion, requestedVersion = '' }) {
  if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(rootVersion)) throw new Error('Release version must be a stable x.y.z version')
  const mobile = /^(\S+)\+([1-9]\d*)$/.exec(appVersion)
  if (pluginVersion !== rootVersion || !mobile || mobile[1] !== rootVersion) throw new Error('Root, plugin and App versions must match; App also needs a positive build number')
  if (requestedVersion && requestedVersion !== rootVersion) throw new Error('Requested version does not match the committed manifests; update and commit versions first')
  return { version: rootVersion, tag: `v${rootVersion}`, appBuildNumber: mobile[2] }
}
export function validateRepository(repository) {
  if (repository.trim() !== repository || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository) || repository.split('/').some(part => part === '.' || part === '..')) throw new Error('Invalid GitHub release repository')
  return repository
}
export function assertTagCommit(refs, tag, sourceCommit) {
  const entries = new Map(refs.trim().split(/\r?\n/).filter(Boolean).map(line => {
    const [sha, ref] = line.split(/\s+/)
    return [ref, sha]
  }))
  const commit = entries.get(`refs/tags/${tag}^{}`) ?? entries.get(`refs/tags/${tag}`)
  if (commit && commit !== sourceCommit) throw new Error('The release tag already points to a different commit; use a new version')
  return Boolean(commit)
}
export async function prepareRelease(env = process.env, cwd = root) {
  const manifest = JSON.parse(await readFile(resolve(cwd, 'package.json'), 'utf8'))
  const plugin = JSON.parse(await readFile(resolve(cwd, 'packages/agent/package.json'), 'utf8'))
  const pubspec = await readFile(resolve(cwd, 'app/pubspec.yaml'), 'utf8')
  const appVersion = /^version:\s*(\S+)\s*$/m.exec(pubspec)?.[1] ?? ''
  const version = releaseVersion({ rootVersion: manifest.version, pluginVersion: plugin.version, appVersion, requestedVersion: env.REQUESTED_VERSION || '' })
  const sourceRepository = validateRepository(env.GITHUB_REPOSITORY || DEFAULT_RELEASE_REPOSITORY)
  const repository = sourceRepository
  if (env.RELEASE_REPOSITORY && env.RELEASE_REPOSITORY !== repository) throw new Error('Releases must target the current source repository')
  if (!/^[0-9a-f]{40}$/.test(env.GITHUB_SHA || '')) throw new Error('A full checked-out source commit is required')
  const required = ['DISTRIBUTION_CONFIG', 'ANDROID_KEYSTORE_BASE64', 'ANDROID_KEYSTORE_PASSWORD', 'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD']
  const missing = required.filter(key => !env[key])
  if (missing.length) throw new Error(`Missing release configuration: ${missing.join(', ')}`)
  JSON.parse(env.DISTRIBUTION_CONFIG)
  const metadata = { ...version, repository, sourceRepository, sourceCommit: env.GITHUB_SHA }
  await mkdir(resolve(cwd, '.generated'), { recursive: true })
  await writeFile(resolve(cwd, '.generated/release-metadata.json'), JSON.stringify(metadata, null, 2) + '\n')
  if (env.GITHUB_OUTPUT) await writeFile(env.GITHUB_OUTPUT, `version=${version.version}\ntag=${version.tag}\nrepository=${repository}\n`, { flag: 'a' })
  console.log(`Release configuration checked: ${version.tag} -> ${repository}`)
  return metadata
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await prepareRelease().catch(error => { console.error(error.message); process.exitCode = 1 })
}
