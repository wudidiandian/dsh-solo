import { createCipheriv, createDecipheriv, createHash, createHmac, createPublicKey, diffieHellman, generateKeyPairSync, hkdfSync, randomBytes, timingSafeEqual, type KeyObject } from 'node:crypto'
import { mkdir, readFile, writeFile, rename, chmod } from 'node:fs/promises'
import { join } from 'node:path'
import type { Envelope } from '@dsh-solo/protocol'

export const E2EE = 1
const DOMAIN = 'dsh-solo/e2ee/1'
const publicPrefix = Buffer.from('302a300506032b656e032100', 'hex')
const encode = (value: unknown) => Buffer.from(JSON.stringify(value), 'utf8')
export function decodeKey(value: string): Buffer {
  if (!/^[A-Za-z0-9_-]{43}$/.test(value)) throw new Error('Invalid pairing encryption key')
  const key = Buffer.from(value, 'base64url')
  if (key.length !== 32 || key.toString('base64url') !== value) throw new Error('Invalid pairing encryption key')
  return key
}
export async function resolvePairingKey(stateDir: string, token: string): Promise<string> {
  const path = join(stateDir, 'pairing-key.json')
  const binding = createHash('sha256').update(token).digest('hex')
  try {
    const saved = JSON.parse(await readFile(path, 'utf8'))
    if (saved.binding === binding) { decodeKey(saved.key); await chmod(path, 0o600); return saved.key }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw new Error('Cannot read pairing encryption key; do not fall back to plaintext')
  }
  const key = randomBytes(32).toString('base64url')
  await mkdir(stateDir, { recursive: true, mode: 0o700 })
  const temporary = `${path}.${randomBytes(8).toString('hex')}.tmp`
  await writeFile(temporary, JSON.stringify({ binding, key }), { mode: 0o600, flag: 'wx' })
  await rename(temporary, path)
  return key
}
export interface SecureHello { id: string; publicKey: string; proof: string }
export interface SecureWelcome { id: string; publicKey: string; proof: string }
export interface SecurePacket { counter: number; ciphertext: string }
function publicBytes(key: KeyObject) { return (key.export({ type: 'spki', format: 'der' }) as Buffer).subarray(-32).toString('base64url') }
function transcript(token: string, id: string, mobile: string, agent?: string) {
  return encode([DOMAIN, token, id, mobile, ...(agent ? [agent] : [])])
}
function proof(key: Buffer, label: string, data: Buffer) { return createHmac('sha256', key).update(label).update(data).digest('base64url') }
function checkProof(actual: string, expected: string) {
  const a = Buffer.from(actual || '', 'utf8'), b = Buffer.from(expected, 'utf8')
  if (a.length !== b.length || !timingSafeEqual(a, b)) throw new Error('Pairing authentication failed')
}
function shared(privateKey: KeyObject, peer: string) {
  const publicKey = createPublicKey({ key: Buffer.concat([publicPrefix, decodeKey(peer)]), format: 'der', type: 'spki' })
  const secret = diffieHellman({ privateKey, publicKey })
  if (secret.every(byte => byte === 0)) throw new Error('Invalid peer key')
  return secret
}
function derive(secret: Buffer, psk: Buffer, context: Buffer) {
  const keys = Buffer.from(hkdfSync('sha256', secret, psk, context, 64))
  secret.fill(0)
  return [keys.subarray(0, 32), keys.subarray(32, 64)]
}
function validateId(id: string) { if (!/^[0-9a-f]{32}$/.test(id)) throw new Error('Invalid secure connection ID') }

/** Direction-specific keys, fresh per connection; counters are authenticated and never reused. */
export class SecureChannel {
  private sent = 0
  private received = 0
  constructor(readonly id: string, private sendKey: Buffer, private receiveKey: Buffer, private direction: 'm2a' | 'a2m') {}
  seal(value: Envelope): SecurePacket {
    if (this.sent >= 0xffffffff) throw new Error('Secure session exhausted; reconnect required')
    const counter = ++this.sent, nonce = Buffer.alloc(12)
    nonce.writeUInt32BE(counter, 8)
    const cipher = createCipheriv('aes-256-gcm', this.sendKey, nonce)
    cipher.setAAD(encode([DOMAIN, this.id, this.direction, counter]))
    const encrypted = Buffer.concat([cipher.update(encode(value)), cipher.final(), cipher.getAuthTag()])
    return { counter, ciphertext: encrypted.toString('base64') }
  }
  open(packet: SecurePacket): Envelope {
    const { counter, ciphertext } = packet
    if (!Number.isSafeInteger(counter) || counter !== this.received + 1 || counter > 0xffffffff) throw new Error('Replay or out-of-order encrypted message')
    if (typeof ciphertext !== 'string' || ciphertext.length > 6 * 1024 * 1024) throw new Error('Invalid ciphertext')
    const bytes = Buffer.from(ciphertext, 'base64')
    if (bytes.length < 16 || bytes.toString('base64') !== ciphertext) throw new Error('Invalid ciphertext encoding')
    const nonce = Buffer.alloc(12); nonce.writeUInt32BE(counter, 8)
    const cipher = createDecipheriv('aes-256-gcm', this.receiveKey, nonce)
    cipher.setAAD(encode([DOMAIN, this.id, this.direction === 'm2a' ? 'a2m' : 'm2a', counter]))
    cipher.setAuthTag(bytes.subarray(-16))
    const plain = Buffer.concat([cipher.update(bytes.subarray(0, -16)), cipher.final()])
    const value = JSON.parse(plain.toString('utf8'))
    if (value.v !== 1 || typeof value.type !== 'string') throw new Error('Invalid encrypted envelope')
    this.received = counter
    return value
  }
  destroy() { this.sendKey.fill(0); this.receiveKey.fill(0) }
}

export class SecureInitiator {
  readonly id = randomBytes(16).toString('hex')
  private keys = generateKeyPairSync('x25519')
  private psk: Buffer
  constructor(private token: string, key: string) { this.psk = decodeKey(key) }
  hello(): SecureHello {
    const publicKey = publicBytes(this.keys.publicKey)
    return { id: this.id, publicKey, proof: proof(this.psk, 'mobile:', transcript(this.token, this.id, publicKey)) }
  }
  accept(welcome: SecureWelcome): SecureChannel {
    if (welcome.id !== this.id) throw new Error('Secure connection mismatch')
    const context = transcript(this.token, this.id, this.hello().publicKey, welcome.publicKey)
    checkProof(welcome.proof, proof(this.psk, 'agent:', context))
    const [mobile, agent] = derive(shared(this.keys.privateKey, welcome.publicKey), this.psk, context)
    return new SecureChannel(this.id, mobile, agent, 'm2a')
  }
}

export function acceptSecureHello(token: string, key: string, hello: SecureHello): { welcome: SecureWelcome; channel: SecureChannel } {
  validateId(hello.id)
  const psk = decodeKey(key)
  decodeKey(hello.publicKey)
  checkProof(hello.proof, proof(psk, 'mobile:', transcript(token, hello.id, hello.publicKey)))
  const keys = generateKeyPairSync('x25519'), publicKey = publicBytes(keys.publicKey)
  const context = transcript(token, hello.id, hello.publicKey, publicKey)
  const [mobile, agent] = derive(shared(keys.privateKey, hello.publicKey), psk, context)
  return { welcome: { id: hello.id, publicKey, proof: proof(psk, 'agent:', context) }, channel: new SecureChannel(hello.id, agent, mobile, 'a2m') }
}
