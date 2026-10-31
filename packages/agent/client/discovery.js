/** Discover only the reserved loopback ports; returned URLs are never trusted as destinations. */
export async function discoverPairingPages({ fetcher = fetch, signal, timeoutMs = 1500 } = {}) {
  const pages = await Promise.all(Array.from({ length: 10 }, async (_, offset) => {
    const url = `http://127.0.0.1:${8790 + offset}`
    const controller = new AbortController()
    const abort = () => controller.abort()
    signal?.addEventListener('abort', abort, { once: true })
    const timeout = setTimeout(abort, timeoutMs)
    try {
      if (signal?.aborted) return null
      const response = await fetcher(`${url}/api/status`, { signal: controller.signal, cache: 'no-store' })
      if (!response.ok) return null
      const body = await response.json()
      // Pin the destination to the probed loopback origin, even if an unrelated server replies.
      return body.service === 'dsh-solo-pairing' && body.url === url ? url : null
    } catch {
      return null
    } finally {
      clearTimeout(timeout)
      signal?.removeEventListener('abort', abort)
    }
  }))
  return pages.filter(Boolean)
}
