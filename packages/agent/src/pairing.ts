import { decodeKey } from './e2ee.js'
// Local pairing page: a tiny HTTP server on 127.0.0.1 showing the relay URL,
// the device token (masked by default), a QR code for the mobile app and a
// reset button. Loopback-only; the relay itself stays stateless.
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import QRCode from 'qrcode'
import type { PublicDevice } from './devices.js'

export interface PairingServerOptions {
  /** Current device token provider */
  getEncryptionKey?: () => string
  getToken: () => string
  /** Current relay URL provider */
  getRelayUrl: () => string
  /** Reset handler: generate + persist + reconnect; resolves with the new token */
  resetToken: () => Promise<string>
  /** 设备管理（可选；缺省时页面不显示设备区） */
  getDevices?: () => PublicDevice[]
  revokeDevice?: (deviceId: string) => Promise<boolean>
  renameDevice?: (deviceId: string, name: string) => Promise<boolean>
  /** First port to try (default 8790; increments up to maxPort on EADDRINUSE) */
  basePort?: number
  maxPort?: number
  host?: string
}

/** URI encoded into the QR code; the mobile app scans it to auto-fill config */
export function pairingCode(relayUrl: string, token: string, key: string): string {
  decodeKey(key)
  return 'dshpair1.' + Buffer.from(JSON.stringify({ relay: relayUrl, token, key }), 'utf8').toString('base64url')
}
export function pairUri(relayUrl: string, token: string, key?: string): string {
  if (key) decodeKey(key)
  return `dshsolo://pair?relay=${encodeURIComponent(relayUrl)}&token=${encodeURIComponent(token)}` + (key ? `&e2ee=1&key=${key}` : '')
}

/** Keep the dsh-solo- prefix, mask the rest */
function maskToken(token: string): string {
  const m = token.match(/^(dsh-solo-)/)
  return (m ? m[1] : '') + '•'.repeat(12)
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

function renderPage(relayUrl: string, masked: string, qrSvg: string): string {
  // 双语（2026-10-28）：默认跟随浏览器语言，右上角可手动切换（记入 localStorage）。
  return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DSH-SOLO 设备配对 / Device Pairing</title>
<style>
  body { font-family: system-ui, sans-serif; background: #f5f6fa; margin: 0;
         display: flex; justify-content: center; padding: 24px 12px; }
  .card { background: #fff; border-radius: 12px; padding: 24px; max-width: 420px;
          width: 100%; box-shadow: 0 2px 12px rgba(0,0,0,.08); }
  .top { display: flex; align-items: center; gap: 8px; }
  h1 { font-size: 20px; margin: 0 0 16px; flex: 1; }
  .lang { font-size: 12px; border: 1px solid #ccd; border-radius: 6px;
          background: #fff; cursor: pointer; padding: 4px 8px; }
  .row { margin-bottom: 14px; }
  .label { font-size: 12px; color: #666; margin-bottom: 4px; }
  .value { font-family: ui-monospace, monospace; font-size: 13px; word-break: break-all;
           background: #f0f1f5; padding: 8px 10px; border-radius: 8px; }
  .qr { text-align: center; margin: 16px 0; }
  .qr svg { width: 220px; height: 220px; }
  .actions { display: flex; gap: 8px; margin-top: 8px; }
  button { flex: 1; padding: 8px 10px; border: 1px solid #ccd; border-radius: 8px;
           background: #fff; cursor: pointer; font-size: 13px; }
  button.primary { background: #4d6bfe; border-color: #4d6bfe; color: #fff; }
  button.danger { color: #c0392b; }
  .tips { font-size: 12px; color: #888; line-height: 1.7; margin-top: 16px;
          border-top: 1px solid #eee; padding-top: 12px; }
  .dev { display: flex; align-items: center; gap: 8px; padding: 8px 10px;
         background: #f0f1f5; border-radius: 8px; margin-bottom: 6px; font-size: 13px; }
  .dev .name { flex: 1; word-break: break-all; }
  .dev .seen { font-size: 11px; color: #888; }
  .dev button { flex: 0 0 auto; padding: 4px 10px; font-size: 12px; }
  .dev-empty { font-size: 12px; color: #999; padding: 6px 2px; }
</style>
</head>
<body>
<div class="card">
  <div class="top">
    <h1>📡 <span id="t-title">设备配对</span></h1>
    <button class="lang" id="langBtn">EN</button>
  </div>
  <div class="row">
    <div class="label" id="t-tokenLabel">设备令牌</div>
    <div class="value" id="tokenView">${escapeHtml(masked)}</div>
    <div class="actions">
      <button id="toggleBtn" data-i18n="show">查看</button>
      <button class="danger" id="resetBtn" data-i18n="reset">重置令牌</button>
    </div>
  </div>
  <div class="qr" id="qrBox">${qrSvg}</div>
  <div class="row">
    <div class="label" id="t-devicesLabel">已配对设备</div>
    <div id="deviceList"></div>
  </div>
  <div class="tips" id="t-tips">
    手机 App → 设置 → 「扫码配对」扫描上方二维码即可自动填入地址与令牌。<br>
    重置令牌后旧令牌立即失效，手机需重新扫码配对。
  </div>
</div>
<script>
  const masked = ${JSON.stringify(masked)};
  const I18N = {
    zh: {
      title: '设备配对', tokenLabel: '加密配对码', show: '查看配对码', hide: '隐藏',
      reset: '重置令牌', resetConfirm: '重置后手机端需重新扫码配对，确定重置？',
      resetDone: '已重置，页面将刷新', resetFailed: '重置失败',
      tokenFetchFailed: '获取令牌失败',
      tips: '手机 App → 设置 → 「扫码配对」扫描上方二维码即可自动填入地址与令牌。<br>重置令牌后旧令牌立即失效，手机需重新扫码配对。<br>二维码随密钥轮换自动更新，请始终扫描本页当前显示的二维码。',
      devicesLabel: '已配对设备', noDevices: '暂无已注册设备（新版 App 连接后自动注册；旧版 App 不显示在此列表）',
      revoke: '撤销', revokeConfirm: '撤销后该设备立即断开且无法重连，需重新扫码配对。确定撤销？',
      revokeFailed: '撤销失败', lastSeen: '最近在线',
      langBtn: 'EN', htmlLang: 'zh-CN',
    },
    en: {
      title: 'Device Pairing', tokenLabel: 'Encrypted pairing code', show: 'Show', hide: 'Hide',
      reset: 'Reset token', resetConfirm: 'The phone must re-scan after reset. Continue?',
      resetDone: 'Reset done — reloading', resetFailed: 'Reset failed',
      tokenFetchFailed: 'Failed to fetch token',
      tips: 'Phone app → Settings → "Scan pairing QR" to auto-fill the address and token.<br>Resetting invalidates the old token immediately; re-pair your phone afterwards.<br>The QR refreshes automatically when keys rotate; always scan the one currently shown here.',
      devicesLabel: 'Paired devices', noDevices: 'No registered devices yet (new app versions register automatically; legacy apps are not listed)',
      revoke: 'Revoke', revokeConfirm: 'The device is disconnected immediately and must re-scan the QR to pair again. Continue?',
      revokeFailed: 'Revoke failed', lastSeen: 'Last seen',
      langBtn: '中文', htmlLang: 'en',
    },
  };
  let lang = localStorage.getItem('dsh-lang') ||
    (navigator.language && navigator.language.toLowerCase().startsWith('zh') ? 'zh' : 'en');
  let full = null;
  const view = document.getElementById('tokenView');
  const toggleBtn = document.getElementById('toggleBtn');
  const langBtn = document.getElementById('langBtn');
  function applyLang() {
    const t = I18N[lang];
    document.getElementById('t-title').textContent = t.title;
    document.getElementById('t-tokenLabel').textContent = t.tokenLabel;
    document.getElementById('resetBtn').textContent = t.reset;
    document.getElementById('t-tips').innerHTML = t.tips;
    document.getElementById('t-devicesLabel').textContent = t.devicesLabel;
    document.getElementById('langBtn').textContent = t.langBtn;
    if (full === null) toggleBtn.textContent = t.show;
    document.documentElement.lang = t.htmlLang;
    localStorage.setItem('dsh-lang', lang);
  }
  toggleBtn.addEventListener('click', async () => {
    if (full !== null) {
      view.textContent = masked;
      full = null;
      toggleBtn.textContent = I18N[lang].show;
      return;
    }
    try {
      const r = await fetch('/api/token');
      const j = await r.json();
      full = j.pairingCode ?? j.token;
      view.textContent = full;
      toggleBtn.textContent = I18N[lang].hide;
    } catch (e) { alert(I18N[lang].tokenFetchFailed); }
  });
  document.getElementById('resetBtn').addEventListener('click', async () => {
    if (!confirm(I18N[lang].resetConfirm)) return;
    try {
      await fetch('/api/reset', { method: 'POST' });
      alert(I18N[lang].resetDone);
      location.reload();
    } catch (e) { alert(I18N[lang].resetFailed); }
  });
  const deviceList = document.getElementById('deviceList');
  function fmtTime(ts) { return ts ? new Date(ts).toLocaleString() : '-'; }
  async function loadDevices() {
    try {
      const r = await fetch('/api/devices');
      const j = await r.json();
      const devices = j.devices || [];
      deviceList.innerHTML = '';
      if (!devices.length) {
        const empty = document.createElement('div');
        empty.className = 'dev-empty';
        empty.textContent = I18N[lang].noDevices;
        deviceList.appendChild(empty);
        return;
      }
      for (const d of devices) {
        const row = document.createElement('div');
        row.className = 'dev';
        const name = document.createElement('span');
        name.className = 'name';
        name.textContent = d.name || d.id.slice(0, 8);
        const seen = document.createElement('span');
        seen.className = 'seen';
        seen.textContent = I18N[lang].lastSeen + ': ' + fmtTime(d.lastSeen);
        const btn = document.createElement('button');
        btn.className = 'danger';
        btn.textContent = I18N[lang].revoke;
        btn.addEventListener('click', async () => {
          if (!confirm(I18N[lang].revokeConfirm)) return;
          try {
            await fetch('/api/devices/revoke', {
              method: 'POST', headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ deviceId: d.id }),
            });
            loadDevices();
          } catch (e) { alert(I18N[lang].revokeFailed); }
        });
        row.appendChild(name); row.appendChild(seen); row.appendChild(btn);
        deviceList.appendChild(row);
      }
    } catch (e) { /* 设备区加载失败不影响配对主功能 */ }
  }
  loadDevices();
  // 主密钥会在新设备注册/令牌重置时轮换：轮询换图，保证扫到的始终是当前有效码
  async function refreshQr() {
    try {
      const q = await fetch('/api/qr');
      const svg = await q.text();
      const box = document.getElementById('qrBox');
      if (box.innerHTML.trim() !== svg.trim()) box.innerHTML = svg;
    } catch (e) { /* 轮询失败不影响页面 */ }
  }
  setInterval(refreshQr, 5000);
  window.addEventListener('focus', refreshQr);
  langBtn.addEventListener('click', () => {
    lang = lang === 'zh' ? 'en' : 'zh';
    applyLang();
    loadDevices();
  });
  applyLang();
</script>
</body>
</html>`
}

function sendJson(res: ServerResponse, body: unknown, status = 200): void {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' })
  res.end(JSON.stringify(body))
}

function readJsonBody(req: IncomingMessage): Promise<any> {
  return new Promise((resolve, reject) => {
    let data = ''
    req.on('data', (chunk) => {
      data += chunk
      if (data.length > 4096) { reject(new Error('body too large')); req.destroy() }
    })
    req.on('end', () => { try { resolve(data ? JSON.parse(data) : {}) } catch (err) { reject(err) } })
    req.on('error', reject)
  })
}

export class PairingServer {
  private server: Server | null = null
  private port = 0
  private generation = 0

  constructor(private readonly opts: PairingServerOptions) {}

  /** Actual page address once listening, e.g. http://127.0.0.1:8790 */
  get address(): string | null {
    return this.server?.listening && this.port ? `http://${this.opts.host ?? '127.0.0.1'}:${this.port}` : null
  }

  /** Bind 127.0.0.1, retrying the next port on EADDRINUSE; never throws */
  start(): void {
    if (this.server) return
    const generation = ++this.generation
    const base = this.opts.basePort ?? 8790
    const max = this.opts.maxPort ?? 8799
    const host = this.opts.host ?? '127.0.0.1'
    const tryPort = (port: number): void => {
      if (this.generation !== generation) return
      const server = createServer((req, res) => {
        void this.handle(req, res)
      })
      this.server = server
      server.on('error', (err: NodeJS.ErrnoException) => {
        if (this.generation !== generation) return
        if (this.server === server) this.server = null
        if (err.code === 'EADDRINUSE' && port < max) {
          tryPort(port + 1)
        } else {
          // Non-fatal: the plugin keeps working without the pairing page
          console.warn('[dsh-solo-agent] pairing page unavailable:', err.message)
        }
      })
      server.listen(port, host, () => {
        if (this.generation !== generation) { server.close(); return }
        this.port = port
        console.log(`[dsh-solo-agent] pairing page: http://${host}:${port}`)
      })
    }
    tryPort(base)
  }

  stop(): void {
    this.generation++
    this.port = 0
    this.server?.close()
    this.server = null
  }

  private async handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = (req.url ?? '/').split('?')[0]
    try {
      // Public discovery only: never include the relay address or pairing credentials.
      if (req.method === 'GET' && url === '/api/status') {
        res.setHeader('Access-Control-Allow-Origin', '*')
        res.setHeader('Cache-Control', 'no-store')
        sendJson(res, { service: 'dsh-solo-pairing', url: this.address })
        return
      }
      // Block DNS rebinding, cross-site credential reads and reset requests.
      const allowedHosts = [`127.0.0.1:${this.port}`, `localhost:${this.port}`]
      if (!allowedHosts.includes(req.headers.host ?? '') ||
          (req.headers.origin && !allowedHosts.some(host => req.headers.origin === `http://${host}`)) ||
          req.headers['sec-fetch-site'] === 'cross-site') {
        sendJson(res, { error: 'forbidden' }, 403); return
      }
      res.setHeader('Cache-Control', 'no-store')
      res.setHeader('Referrer-Policy', 'no-referrer')
      res.setHeader('X-Content-Type-Options', 'nosniff')
      res.setHeader('Content-Security-Policy', "default-src 'self'; img-src 'self' data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'")
      if (req.method === 'GET' && url === '/api/token') {
        sendJson(res, { token: this.opts.getToken(), relayUrl: this.opts.getRelayUrl(), ...(this.opts.getEncryptionKey ? { pairingCode: pairingCode(this.opts.getRelayUrl(), this.opts.getToken(), this.opts.getEncryptionKey()) } : {}) })
        return
      }
      // 当前有效二维码（主密钥轮换后页面轮询换图，避免扫到失效旧码）
      if (req.method === 'GET' && url === '/api/qr') {
        const svg = await QRCode.toString(pairUri(this.opts.getRelayUrl(), this.opts.getToken(), this.opts.getEncryptionKey?.()), {
          type: 'svg',
          margin: 1,
        })
        res.writeHead(200, { 'Content-Type': 'image/svg+xml; charset=utf-8' })
        res.end(svg)
        return
      }
      if (req.method === 'POST' && url === '/api/reset') {
        const token = await this.opts.resetToken()
        sendJson(res, { token, relayUrl: this.opts.getRelayUrl() })
        return
      }
      if (req.method === 'GET' && url === '/api/devices') {
        sendJson(res, { devices: this.opts.getDevices?.() ?? [] })
        return
      }
      if (req.method === 'POST' && (url === '/api/devices/revoke' || url === '/api/devices/rename')) {
        const body = await readJsonBody(req)
        const id = typeof body?.deviceId === 'string' ? body.deviceId : ''
        if (url === '/api/devices/revoke') {
          if (!this.opts.revokeDevice) { sendJson(res, { error: 'unsupported' }, 400); return }
          sendJson(res, { revoked: await this.opts.revokeDevice(id) })
        } else {
          if (!this.opts.renameDevice) { sendJson(res, { error: 'unsupported' }, 400); return }
          sendJson(res, { renamed: await this.opts.renameDevice(id, typeof body?.name === 'string' ? body.name : '') })
        }
        return
      }
      if (req.method === 'GET' && (url === '/' || url === '/index.html')) {
        const relayUrl = this.opts.getRelayUrl()
        const token = this.opts.getToken()
        const qrSvg = await QRCode.toString(pairUri(relayUrl, token, this.opts.getEncryptionKey?.()), {
          type: 'svg',
          margin: 1,
        })
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
        res.end(renderPage(relayUrl, maskToken(token), qrSvg))
        return
      }
      sendJson(res, { error: 'not found' }, 404)
    } catch (err) {
      sendJson(res, { error: err instanceof Error ? err.message : String(err) }, 500)
    }
  }
}
