import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { resolve, join } from 'node:path'
import { spawnSync } from 'node:child_process'
import { pathToFileURL } from 'node:url'

const sourceManifest = JSON.parse(await readFile(new URL('../packages/agent/package.json', import.meta.url), 'utf8'))
const target = process.argv[2] || '.generated'
const archive = resolve(target.endsWith('.tgz') ? target : join(target, `${sourceManifest.name}-${sourceManifest.version}.tgz`))
const directory = await mkdtemp(join(tmpdir(), 'dsh-solo-package-'))
try {
  const extraction = spawnSync('tar', ['-xzf', archive, '-C', directory], { encoding: 'utf8' })
  assert.equal(extraction.status, 0, extraction.stderr || extraction.error?.message)
  const root = join(directory, 'package')
  const manifest = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'))
  assert.equal(manifest.name, 'dsh-solo-agent')
  assert.ok((await stat(join(root, manifest.dsh.bundle.patch))).isFile())
  for (const file of ['locale/en.json', 'locale/zh.json', 'icon.svg', 'README.md', 'LICENSE', 'dist/client.js']) {
    assert.ok((await stat(join(root, file))).isFile(), `Missing packaged resource: ${file}`)
  }
  for (const locale of ['en', 'zh']) {
    const metadata = JSON.parse(await readFile(join(root, 'locale', `${locale}.json`), 'utf8'))
    assert.ok(metadata.meta.title && metadata.meta.description)
  }
  assert.equal(manifest.exports['.'].import, `./${manifest.main}`)
  assert.equal(manifest.exports['./client'], './dist/client.js')
  assert.equal(manifest.dsh.client.platform, 'web')
  const browserSyntax = spawnSync(process.execPath, ['--check', join(root, 'dist/client.js')], { encoding: 'utf8' })
  assert.equal(browserSyntax.status, 0, browserSyntax.stderr)
  // A fresh process imports the packed entry outside the checkout, with no workspace dependencies.
  const run = spawnSync(process.execPath, ['--input-type=module', '-e', `
    const plugin = await import(process.argv[1]);
    if (typeof plugin.apply !== 'function' || !Array.isArray(plugin.inject)) throw new Error('Invalid host exports');
  `, pathToFileURL(join(root, manifest.main)).href], { cwd: directory, encoding: 'utf8' })
  assert.equal(run.status, 0, run.stderr || run.error?.message)
  console.log('Packed plugin: standalone runtime, bundle patch and display resources verified.')
} finally {
  await rm(directory, { recursive: true, force: true })
}
