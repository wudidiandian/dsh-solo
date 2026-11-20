/** Own pairing requests for one selected Host generation; stale responses never restore credentials. */
export class PairingController {
  constructor(api, { timeoutMs = 15000 } = {}) {
    this.api = api
    this.timeoutMs = timeoutMs
    this.active = false
    this.sequence = 0
    this.listeners = new Set()
    this.snapshot = { data: null, token: null, loading: true, busy: false, error: null }
  }
  getSnapshot = () => this.snapshot
  subscribe = listener => { this.listeners.add(listener); return () => this.listeners.delete(listener) }
  set(patch) {
    this.snapshot = { ...this.snapshot, ...patch }
    for (const listener of this.listeners) listener()
  }
  start() {
    this.active = true
    void this.refresh()
    // 主密钥会在新设备注册/令牌重置时轮换：静默轮询换图，避免面板挂着扫到失效旧码
    this.poll = setInterval(() => {
      if (this.active && !this.snapshot.busy && !this.snapshot.loading) void this.run('read', true)
    }, 5000)
  }
  stop() {
    this.active = false
    this.sequence++
    clearInterval(this.poll)
    this.request?.abort()
    clearTimeout(this.timeout)
    this.snapshot = { data: null, token: null, loading: true, busy: false, error: null }
  }
  refresh() { return this.run('read') }
  reset() { return this.run('reset') }
  toggleToken() {
    if (this.snapshot.token !== null) { this.set({ token: null }); return Promise.resolve() }
    return this.run('reveal')
  }
  async run(operation, silent = false) {
    if (!this.active) return
    this.request?.abort()
    clearTimeout(this.timeout)
    const request = this.request = new AbortController()
    const sequence = ++this.sequence
    const current = () => this.active && sequence === this.sequence
    const clearData = operation !== 'reveal' && !silent
    if (!silent) {
      this.set({ ...(clearData ? { data: null } : {}), token: null, loading: operation === 'read', busy: true, error: null })
    }
    const timeout = this.timeout = setTimeout(() => {
      if (!current()) return
      request.abort()
      this.sequence++
      if (!silent) this.set({ loading: false, busy: false, error: 'failed' })
    }, this.timeoutMs)
    try {
      const value = await this.api[operation](request.signal)
      if (!current() || request.signal.aborted) return
      if (operation === 'reveal') {
        if (typeof value.token !== 'string' || !value.token) throw new Error('Invalid response')
        this.set({ token: value.token })
      } else {
        if (typeof value.qrSvg !== 'string' || !value.qrSvg.startsWith('<svg') || typeof value.maskedToken !== 'string') throw new Error('Invalid response')
        if (silent) {
          // 仅在二维码变化时换图，并收起已失效的明文配对码；无变化不打扰 UI
          if (value.qrSvg !== this.snapshot.data?.qrSvg) this.set({ data: value, token: null })
        } else {
          this.set({ data: value })
        }
      }
    } catch (error) {
      if (silent) return // 轮询失败保留旧图，下次再试
      if (current() && !request.signal.aborted) this.set({ error: error.code === 'forbidden' ? 'forbidden' : 'failed' })
    } finally {
      clearTimeout(timeout)
      if (current() && !silent) this.set({ loading: false, busy: false })
    }
  }
}
