import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises'
import { resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import { releaseVersion, validateRepository, assertTagCommit, prepareRelease } from '../prepare-release.mjs'

const versions = { rootVersion: '0.1.5', pluginVersion: '0.1.5', appVersion: '0.1.5+6' }
const sha = 'a'.repeat(40)
test('stable release uses committed versions, including Android build number', () => {
  assert.deepEqual(releaseVersion(versions), { version: '0.1.5', tag: 'v0.1.5', appBuildNumber: '6' })
  assert.equal(releaseVersion({ ...versions, requestedVersion: '0.1.5' }).tag, 'v0.1.5')
})
test('rejects mismatched, prerelease and uncommitted requested versions', () => {
  for (const change of [
    { pluginVersion: '0.1.4' }, { appVersion: '0.1.4+6' }, { appVersion: '0.1.5+0' },
    { appVersion: '0.1.5' }, { rootVersion: '0.1.5-beta.1' }, { rootVersion: '00.1.5' },
    { requestedVersion: '0.1.6' }, { requestedVersion: 'v0.1.5' },
  ]) assert.throws(() => releaseVersion({ ...versions, ...change }))
})
test('repository must be an owner/repository identifier', () => {
  assert.equal(validateRepository('wudidiandian/dsh-solo'), 'wudidiandian/dsh-solo')
  for (const value of ['../repo', 'owner/..', 'owner/repo/other', 'https://github.com/owner/repo', 'owner/repo\n']) {
    assert.throws(() => validateRepository(value))
  }
})
test('existing tags must identify the exact built commit, including peeled annotated tags', () => {
  assert.equal(assertTagCommit('', 'v0.1.5', sha), false)
  assert.equal(assertTagCommit(`${sha}\trefs/tags/v0.1.5`, 'v0.1.5', sha), true)
  assert.equal(assertTagCommit(`${'b'.repeat(40)}\trefs/tags/v0.1.5\n${sha}\trefs/tags/v0.1.5^{}`, 'v0.1.5', sha), true)
  assert.throws(() => assertTagCommit(`${'b'.repeat(40)}\trefs/tags/v0.1.5`, 'v0.1.5', sha), /different commit/)
})

async function fixture(t) {
  const base = fileURLToPath(new URL('../../.generated/release-tests/', import.meta.url))
  await mkdir(base, { recursive: true })
  const cwd = await mkdtemp(resolve(base, 'case-'))
  t.after(async () => {
    if (!resolve(cwd).startsWith(resolve(base) + sep)) throw new Error('Invalid test cleanup path')
    await rm(cwd, { recursive: true, force: true })
  })
  await mkdir(resolve(cwd, 'packages/agent'), { recursive: true })
  await mkdir(resolve(cwd, 'app'))
  await writeFile(resolve(cwd, 'package.json'), JSON.stringify({ version: versions.rootVersion }))
  await writeFile(resolve(cwd, 'packages/agent/package.json'), JSON.stringify({ version: versions.pluginVersion }))
  await writeFile(resolve(cwd, 'app/pubspec.yaml'), `name: app\nversion: ${versions.appVersion}\n`)
  const env = {
    GITHUB_REPOSITORY: 'wudidiandian/dsh-solo', GITHUB_SHA: sha,
    DISTRIBUTION_CONFIG: '{"relayUrl":"wss://private.invalid/ws"}',
    ANDROID_KEYSTORE_BASE64: 'secret-key-data', ANDROID_KEYSTORE_PASSWORD: 'secret-store-password',
    ANDROID_KEY_ALIAS: 'secret-alias', ANDROID_KEY_PASSWORD: 'secret-key-password',
    GITHUB_OUTPUT: resolve(cwd, 'output'),
  }
  return { cwd, env }
}
test('preflight fails early with missing configuration names', async t => {
  const { cwd, env } = await fixture(t)
  await assert.rejects(prepareRelease({ ...env, ANDROID_KEYSTORE_PASSWORD: '' }, cwd), /ANDROID_KEYSTORE_PASSWORD/)
  await assert.rejects(readFile(resolve(cwd, '.generated/release-metadata.json')), { code: 'ENOENT' })
})
test('metadata targets the requested repository and never contains build secrets', async t => {
  const { cwd, env } = await fixture(t)
  const metadata = await prepareRelease(env, cwd)
  assert.equal(metadata.repository, 'wudidiandian/dsh-solo')
  assert.equal(metadata.sourceCommit, sha)
  const saved = await readFile(resolve(cwd, '.generated/release-metadata.json'), 'utf8')
  for (const secret of ['private.invalid', 'secret-key-data', 'secret-store-password', 'secret-alias', 'secret-key-password']) assert.ok(!saved.includes(secret))
  assert.equal(await readFile(env.GITHUB_OUTPUT, 'utf8'), 'version=0.1.5\ntag=v0.1.5\nrepository=wudidiandian/dsh-solo\n')
})
test('publication follows the current repository without an additional token', async t => {
  const { cwd, env } = await fixture(t)
  const metadata = await prepareRelease({ ...env, GITHUB_REPOSITORY: 'example/fork' }, cwd)
  assert.equal(metadata.repository, 'example/fork')
})
test('invalid source commits and malformed distribution JSON fail preflight', async t => {
  const { cwd, env } = await fixture(t)
  await assert.rejects(prepareRelease({ ...env, GITHUB_SHA: 'main' }, cwd), /source commit/)
  await assert.rejects(prepareRelease({ ...env, DISTRIBUTION_CONFIG: 'invalid' }, cwd), SyntaxError)
})

test('rejects a stale publication target outside the current repository', async t => {
  const { cwd, env } = await fixture(t)
  await assert.rejects(prepareRelease({ ...env, RELEASE_REPOSITORY: 'example/other' }, cwd), /current source repository/)
})
