// Local pairing page: a tiny HTTP server on 127.0.0.1 showing the relay URL,
// the device token (masked by default), a QR code for the mobile app and a
// reset button. Loopback-only; the relay itself stays stateless.
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'
import QRCode from 'qrcode'

export interface PairingServerOptions {
  /** Current device token provider */
  getToken: () => string
  /** Current relay URL provider */
  getRelayUrl: () => string
  /** Reset handler: generate + persist + reconnect; resolves with the new token */
  resetToken: () => Promise<string>
  /** First port to try (default 8790; increments up to maxPort on EADDRINUSE) */
  basePort?: number
  maxPort?: number
  host?: string
}

/** URI encoded into the QR code; the mobile app scans it to auto-fill config */
export function pairUri(relayUrl: string, token: string): string {
  return `dshsolo://pair?relay=${encodeURIComponent(relayUrl)}&token=${encodeURIComponent(token)}`
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
  <div class="qr">${qrSvg}</div>
  <div class="tips" id="t-tips">
    手机 App → 设置 → 「扫码配对」扫描上方二维码即可自动填入地址与令牌。<br>
    重置令牌后旧令牌立即失效，手机需重新扫码配对。
  </div>
</div>
<script>
  const masked = ${JSON.stringify(masked)};
  const I18N = {
    zh: {
      title: '设备配对', tokenLabel: '设备令牌', show: '查看', hide: '隐藏',
      reset: '重置令牌', resetConfirm: '重置后手机端需重新扫码配对，确定重置？',
      resetDone: '已重置，页面将刷新', resetFailed: '重置失败',
      tokenFetchFailed: '获取令牌失败',
      tips: '手机 App → 设置 → 「扫码配对」扫描上方二维码即可自动填入地址与令牌。<br>重置令牌后旧令牌立即失效，手机需重新扫码配对。',
      langBtn: 'EN', htmlLang: 'zh-CN',
    },
    en: {
      title: 'Device Pairing', tokenLabel: 'Device token', show: 'Show', hide: 'Hide',
      reset: 'Reset token', resetConfirm: 'The phone must re-scan after reset. Continue?',
      resetDone: 'Reset done — reloading', resetFailed: 'Reset failed',
      tokenFetchFailed: 'Failed to fetch token',
      tips: 'Phone app → Settings → "Scan pairing QR" to auto-fill the address and token.<br>Resetting invalidates the old token immediately; re-pair your phone afterwards.',
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
      full = j.token;
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
  langBtn.addEventListener('click', () => {
    lang = lang === 'zh' ? 'en' : 'zh';
    applyLang();
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
      if (req.method === 'GET' && url === '/api/token') {
        sendJson(res, { token: this.opts.getToken(), relayUrl: this.opts.getRelayUrl() })
        return
      }
      if (req.method === 'POST' && url === '/api/reset') {
        const token = await this.opts.resetToken()
        sendJson(res, { token, relayUrl: this.opts.getRelayUrl() })
        return
      }
      if (req.method === 'GET' && (url === '/' || url === '/index.html')) {
        const relayUrl = this.opts.getRelayUrl()
        const token = this.opts.getToken()
        const qrSvg = await QRCode.toString(pairUri(relayUrl, token), {
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
