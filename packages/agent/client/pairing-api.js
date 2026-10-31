/** Use the selected Host transport, including native IPC and authenticated browser connections. */
export function createPairingApi(connection) {
  async function call(operation, signal) {
    const result = await connection.rpc.call('/api', `dsh-solo-pairing/${operation}`, {}, signal)
    if (!result.ok) {
      const error = new Error('Pairing operation failed')
      error.code = result.error?.code
      throw error
    }
    if (!result.value || typeof result.value !== 'object') throw new Error('Invalid pairing response')
    return result.value
  }
  return { read: signal => call('read', signal), reveal: signal => call('reveal', signal), reset: signal => call('reset', signal) }
}

/** A browser fallback is meaningful only on the same computer as the selected Host. */
export function localBrowserUrl(value, isLocal) {
  if (!isLocal || typeof value !== 'string') return null
  try {
    const url = new URL(value)
    return url.protocol === 'http:' && url.hostname === '127.0.0.1' &&
      /^879[0-9]$/.test(url.port) && url.pathname === '/' &&
      !url.username && !url.password && !url.search && !url.hash ? url.origin : null
  } catch { return null }
}
