// Device token management: resolve (explicit config > persisted file > newly
// generated), persist atomically under the agent state dir (<workspace>/.dsh-solo).
import { randomBytes } from 'node:crypto'
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

export const TOKEN_FILE_NAME = 'device-token'
export const TOKEN_PREFIX = 'dsh-solo-'

/** dsh-solo- + 24 random bytes as hex (48 chars) */
export function generateToken(): string {
  return TOKEN_PREFIX + randomBytes(24).toString('hex')
}

async function readTokenFile(stateDir: string): Promise<string | null> {
  try {
    const raw = await readFile(join(stateDir, TOKEN_FILE_NAME), 'utf8')
    const trimmed = raw.trim()
    return trimmed.length > 0 ? trimmed : null
  } catch (err) {
    if ((err as NodeJS.ErrnoException)?.code !== 'ENOENT') {
      console.error('[dsh-solo-agent] read device token failed:', err)
    }
    return null
  }
}

/** Atomic write: tmp file + rename within the same directory */
export async function writeTokenFile(stateDir: string, token: string): Promise<void> {
  await mkdir(stateDir, { recursive: true })
  const finalPath = join(stateDir, TOKEN_FILE_NAME)
  const tmpPath = `${finalPath}.${process.pid}.${Date.now()}.tmp`
  await writeFile(tmpPath, `${token}\n`, 'utf8')
  await rename(tmpPath, finalPath)
}

/**
 * Resolution order: explicit config.deviceToken (backward compatible) >
 * persisted <stateDir>/device-token file > generate a new token and persist it.
 * On persist failure only warn and fall back to the in-memory value.
 */
export async function resolveDeviceToken(
  explicit: string | undefined,
  stateDir: string,
): Promise<string> {
  const trimmed = explicit?.trim()
  if (trimmed) return trimmed
  const persisted = await readTokenFile(stateDir)
  if (persisted) return persisted
  const token = generateToken()
  try {
    await writeTokenFile(stateDir, token)
  } catch (err) {
    console.error('[dsh-solo-agent] persist device token failed (using in-memory value):', err)
  }
  return token
}
