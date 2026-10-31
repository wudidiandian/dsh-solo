import { createPairingApi, localBrowserUrl } from './pairing-api.js'
import { PairingController } from './pairing-controller.js'

window.__ModuleLoader__.load({
  id: 'dsh-solo-agent',
  factory(require) {
    const React = require('react')
    const h = React.createElement
    const NS = 'dsh-solo-pairing'
    const PANEL = 'dsh-solo-pairing'
    const dictionaries = {
      zh: {
        nav: '手机配对', title: '连接 DSH-SOLO 手机端',
        description: '在手机 App 的“设备连接”中点击“扫码配对”，扫描下方二维码。',
        open: '在浏览器打开（备用）', checking: '正在获取配对信息…',
        ready: '云转发已连接', reconnecting: '云转发连接恢复中，请稍后刷新',
        failed: '无法获取配对信息。请确认插件已启用、宿主连接正常，然后重试。',
        forbidden: '只有此 DeepSeek Harness 的所有者可以查看配对信息。',
        retry: '刷新配对信息', token: '设备令牌', show: '查看令牌', hide: '隐藏令牌',
        reset: '重置令牌', resetting: '正在处理…',
        confirm: '重置后原配对令牌将失效，所有手机都需要重新扫码。确定重置吗？',
        privacy: '二维码包含设备访问凭证，请勿分享或公开。令牌重置后，手机需重新扫码配对。',
      },
      en: {
        nav: 'Phone pairing', title: 'Connect your DSH-SOLO phone app',
        description: 'In the phone app, open Device connection → Scan to pair, then scan this QR code.',
        open: 'Open in browser (backup)', checking: 'Loading pairing information…',
        ready: 'Cloud relay connected', reconnecting: 'Reconnecting to the cloud relay. Refresh shortly.',
        failed: 'Cannot load pairing information. Check the plugin and Host connection, then retry.',
        forbidden: 'Only the owner of this DeepSeek Harness can view pairing information.',
        retry: 'Refresh pairing information', token: 'Device token', show: 'Show token', hide: 'Hide token',
        reset: 'Reset token', resetting: 'Working…',
        confirm: 'The old pairing token will stop working. Every phone must scan again. Reset the token?',
        privacy: 'The QR code contains device credentials. Keep it private. Pair again after resetting the token.',
      },
    }
    function PhoneIcon() {
      return h('svg', { width: 20, height: 20, viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', strokeWidth: 1.6, 'aria-hidden': true },
        h('rect', { x: 6, y: 2, width: 12, height: 20, rx: 3 }), h('path', { d: 'M10 18h4M10 5h4' }))
    }
    const css = `
      .dsh-solo-pairing { color:var(--dsw-alias-label-primary); padding:40px 24px; max-width:680px; margin:0 auto; box-sizing:border-box; }
      .dsh-solo-pairing h1 { font-size:24px; font-weight:600; margin:0 0 12px; }
      .dsh-solo-pairing p { color:var(--dsw-alias-label-secondary); line-height:1.7; margin:10px 0; }
      .dsh-solo-pairing .dsh-solo-card { border:1px solid var(--dsw-alias-border-l2); border-radius:16px; padding:24px; margin:24px 0; background:var(--dsw-alias-bg-layer-1); }
      .dsh-solo-pairing button,.dsh-solo-pairing a { font:inherit; }
      .dsh-solo-pairing button { cursor:pointer; border:1px solid var(--dsw-alias-border-l2); background:transparent; color:inherit; border-radius:8px; padding:9px 14px; }
      .dsh-solo-pairing button:disabled { opacity:.5; cursor:wait; }
      .dsh-solo-pairing :focus-visible { outline:2px solid var(--dsw-alias-brand-primary); outline-offset:3px; }
      .dsh-solo-pairing .dsh-solo-qr { display:block; width:256px; max-width:100%; height:auto; padding:12px; box-sizing:border-box; background:#fff; border-radius:12px; margin:20px auto; }
      .dsh-solo-pairing code { display:block; overflow-wrap:anywhere; user-select:text; padding:12px; border-radius:8px; background:var(--dsw-alias-bg-layer-2); margin:8px 0 14px; }
      .dsh-solo-pairing .dsh-solo-actions { display:flex; gap:10px; flex-wrap:wrap; }
      .dsh-solo-pairing .dsh-solo-note { font-size:13px; }
      .dsh-solo-pairing .dsh-solo-error { color:var(--dsw-alias-label-primary); }
      .dsh-solo-pairing a { display:inline-block; color:inherit; margin-top:18px; }
      @media(max-width:600px) { .dsh-solo-pairing { padding:24px 16px; } }
    `
    return {
      inject: ['slots', 'locale', 'layout', 'connection'],
      apply(ctx) {
        ctx.effect(() => ctx.locale.register(NS, dictionaries))
        const t = ctx.locale.bind(NS)
        const api = createPairingApi(ctx.connection)
        function PairingPage() {
          React.useSyncExternalStore(fn => ctx.locale.subscribe(fn), () => ctx.locale.getSnapshot())
          const generation = React.useSyncExternalStore(fn => ctx.connection.generation.subscribe(fn), () => ctx.connection.generation.getSnapshot())
          const model = React.useMemo(() => new PairingController(api), [generation])
          const state = React.useSyncExternalStore(model.subscribe, model.getSnapshot)
          React.useEffect(() => { model.start(); return () => model.stop() }, [model])
          const data = state.data
          const browserUrl = localBrowserUrl(data?.browserUrl, ctx.connection.isLoopback)
          return h('section', { className: 'dsh-solo-pairing' },
            h('style', null, css), h('h1', null, t('title')), h('p', null, t('description')),
            h('div', { className: 'dsh-solo-card' },
              state.loading && h('p', { role: 'status' }, t('checking')),
              state.error && h('p', { role: 'alert', className: 'dsh-solo-error' }, t(state.error)),
              data && h(React.Fragment, null,
                h('p', { role: 'status' }, t(data.relayConnected ? 'ready' : 'reconnecting')),
                h('img', { className: 'dsh-solo-qr', alt: t('nav'), src: 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(data.qrSvg) }),
                h('label', null, t('token')), h('code', null, state.token ?? data.maskedToken)),
              h('div', { className: 'dsh-solo-actions' },
                data && h('button', { type: 'button', disabled: state.busy, onClick: () => void model.toggleToken() }, t(state.token === null ? 'show' : 'hide')),
                h('button', { type: 'button', disabled: state.busy, onClick: () => void model.refresh() }, t('retry')),
                data && h('button', { type: 'button', disabled: state.busy, onClick: () => { if (window.confirm(t('confirm'))) void model.reset() } }, t('reset'))),
              browserUrl && h('a', { href: browserUrl, target: '_blank', rel: 'noopener noreferrer' }, t('open'))),
            h('p', { className: 'dsh-solo-note' }, t('privacy')))
        }
        ctx.slots.inject('main', () => ctx.slots.register({ name: 'main', key: PANEL, locale: NS }, PairingPage))
        ctx.slots.inject('sidebar.panellist', () => ctx.slots.register({ name: 'sidebar.panellist', id: PANEL, order: 5, label: () => t('nav'), locale: NS }, PhoneIcon))
        ctx.slots.inject('plugins.detail.actions', () => ctx.slots.register({ name: 'plugins.detail.actions', id: PANEL, locale: NS }, ({ subject }) => {
          if (subject?.pkg?.name !== 'dsh-solo-agent' && subject?.row?.name !== 'dsh-solo-agent') return null
          return h('button', { type: 'button', onClick: () => ctx.layout.selectPanel(PANEL), style: { cursor: 'pointer', padding: '8px 14px', borderRadius: 8, border: '1px solid var(--dsw-alias-border-l2)', background: 'transparent', color: 'var(--dsw-alias-label-primary)' } }, t('nav'))
        }))
      },
    }
  },
})
