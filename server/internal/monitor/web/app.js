'use strict';
const $ = id => document.getElementById(id);
let history = [], latest = null, page = 0, paused = false, loading = false;
const number = n => new Intl.NumberFormat('zh-CN').format(n || 0);
function bytes(n) { if (n == null)
    return '—'; const units = ['B', 'KB', 'MB', 'GB', 'TB']; let i = 0; while (n >= 1024 && i < units.length - 1) {
    n /= 1024;
    i++;
} return `${n.toFixed(i ? 1 : 0)} ${units[i]}`; }
function duration(seconds) { seconds = Math.max(0, Math.floor(seconds)); if (seconds < 60)
    return `${seconds} 秒`; if (seconds < 3600)
    return `${Math.floor(seconds / 60)} 分`; if (seconds < 86400)
    return `${Math.floor(seconds / 3600)} 时 ${Math.floor(seconds % 3600 / 60)} 分`; return `${Math.floor(seconds / 86400)} 天 ${Math.floor(seconds % 86400 / 3600)} 时`; }
const percent = n => n == null ? '—' : `${n.toFixed(1)}%`;
function rows(id, entries) { $(id).replaceChildren(...entries.flatMap(([label, value]) => { const dt = document.createElement('dt'), dd = document.createElement('dd'); dt.textContent = label; dd.textContent = value; return [dt, dd]; })); }
function showLogin() { $('login-panel').hidden = false; $('dashboard').hidden = true; $('logout').hidden = true; history = []; latest = null; page = 0; }
async function request(path, options = {}) { const response = await fetch(path, { credentials: 'same-origin', cache: 'no-store', signal: AbortSignal.timeout(12000), ...options }); const body = await response.json(); if (!response.ok) {
    const error = new Error(body.error || `请求失败（${response.status}）`);
    error.status = response.status;
    throw error;
} return body; }
$('login-form').addEventListener('submit', async (event) => { event.preventDefault(); $('login-button').disabled = true; $('login-error').textContent = ''; try {
    await request('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username: $('username').value, password: $('password').value }) });
    $('password').value = '';
    await load();
}
catch (error) {
    $('login-error').textContent = error.message;
}
finally {
    $('login-button').disabled = false;
} });
$('logout').addEventListener('click', async () => { try {
    await request('/api/logout', { method: 'POST' });
    showLogin();
}
catch (error) {
    $('dashboard-error').hidden = false;
    $('dashboard-error').textContent = error.message;
} });
async function load() { if (loading)
    return; loading = true; $('refresh').disabled = true; try {
    const since = history.length ? Date.parse(history[history.length - 1].at) : 0;
    const snapshot = await request(`/api/snapshot?since=${since}`);
    if (latest && latest.startedAt !== snapshot.startedAt) {
        history = [];
        latest = null;
        return await reloadFull();
    }
    render(snapshot);
}
catch (error) {
    if (error.status === 401) {
        showLogin();
    }
    else {
        $('dashboard-error').hidden = false;
        $('dashboard-error').textContent = `刷新失败，以下数据可能已过期：${error.message}`;
    }
}
finally {
    loading = false;
    $('refresh').disabled = false;
} }
async function reloadFull() { const snapshot = await request('/api/snapshot'); render(snapshot); }
function render(data) {
    latest = data;
    history.push(...data.history);
    history = history.slice(-720);
    $('login-panel').hidden = true;
    $('dashboard').hidden = false;
    $('logout').hidden = false;
    $('dashboard-error').hidden = true;
    $('node-name').textContent = data.nodeName || '当前节点';
    const s = data.stats, c = s.counters, r = data.resources;
    const now = Date.parse(data.now);
    $('summary').textContent = `运行 ${duration((now - Date.parse(data.startedAt)) / 1000)} · 每 ${data.sampleSeconds} 秒采样 · ${r.platform} / ${r.logicalCpus} 逻辑核`;
    $('updated').textContent = `更新于 ${new Date(data.now).toLocaleTimeString('zh-CN')}`;
    $('apps').textContent = number(s.onlineApps);
    $('agents').textContent = number(s.onlineAgents);
    $('paired').textContent = number(s.pairedRooms);
    $('rooms-note').textContent = `${s.activeRooms} 活跃 / ${s.totalRooms} 保留房间`;
    $('capacity').textContent = `${s.reservedConnections} / ${s.maxConnections > 0 ? s.maxConnections : '不限'}`;
    $('capacity-bar').value = s.maxConnections > 0 ? 100 * s.reservedConnections / s.maxConnections : 0;
    $('peak').textContent = `已握手连接峰值 ${c.peakConnections} · 占用含握手中的连接`;
    let notice = '';
    if (s.maxConnections > 0 && s.reservedConnections / s.maxConnections >= .8)
        notice = '连接占用已达到上限的 80%：请结合持续资源占用、错误和限流情况，评估是否调整容量。';
    $('capacity-notice').hidden = !notice;
    $('capacity-notice').textContent = notice;
    const last = history.at(-1), previous = history.at(-2);
    let incoming = '—', outgoing = '—', messages = '—';
    if (last && previous) {
        const seconds = (Date.parse(last.at) - Date.parse(previous.at)) / 1000;
        if (seconds > 0) {
            incoming = `${bytes(Math.max(0, last.bytesIn - previous.bytesIn) / seconds)}/s`;
            outgoing = `${bytes(Math.max(0, last.bytesOut - previous.bytesOut) / seconds)}/s`;
            messages = `${(Math.max(0, last.messagesIn - previous.messagesIn) / seconds).toFixed(1)} / ${(Math.max(0, last.messagesOut - previous.messagesOut) / seconds).toFixed(1)} 条/s`;
        }
    }
    rows('traffic-stats', [['当前接收 / 发出', `${incoming} / ${outgoing}`], ['消息接收 / 发出速率', messages], ['累计接收消息', number(c.messagesIn)], ['累计发出消息', number(c.messagesOut)], ['累计接收 / 发出正文', `${bytes(c.bytesIn)} / ${bytes(c.bytesOut)}`], ['累计上传分块正文', bytes(c.uploadBytesIn)], ['累计握手连接', number(c.connections)], ['房间上限 / 单 IP 连接上限', `${s.maxRooms > 0 ? s.maxRooms : '不限'} / ${s.maxPerIp > 0 ? s.maxPerIp : '不限'}`]]);
    rows('resources', [['进程 CPU（单核 100%）', percent(r.processCpuPercent)], ['进程常驻内存 RSS', bytes(r.rssBytes)], ['Go 堆 / Go 系统预留', `${bytes(r.heapBytes)} / ${bytes(r.goSystemBytes)}`], ['Goroutines', number(r.goroutines)], ['系统可见 CPU', percent(r.systemCpuPercent)], ['系统内存可用 / 总量', `${bytes(r.systemMemoryAvailable)} / ${bytes(r.systemMemoryTotal)}`], ['系统网卡累计收 / 发', `${bytes(r.systemNetworkIn)} / ${bytes(r.systemNetworkOut)}`], ['容器内存使用 / 上限', `${bytes(r.containerMemoryUsage)} / ${bytes(r.containerMemoryLimit)}`], ['容器 CPU 配额', r.cpuQuotaCores == null ? '—' : `${r.cpuQuotaCores.toFixed(2)} 核`]]);
    rows('errors', [['连接数限制拒绝', number(c.connectionRejected)], ['消息限流断开', number(c.messageLimited)], ['上传限流断开', number(c.uploadLimited)], ['上传大小拒绝', number(c.uploadRejected)], ['慢消费者丢弃', number(c.slowConsumers)], ['握手 / 升级失败', `${number(c.handshakeErrors)} / ${number(c.upgradeErrors)}`], ['无效消息', number(c.invalidMessages)], ['读 / 写异常', `${number(c.readErrors)} / ${number(c.writeErrors)}`], ['推送失败', number(c.pushErrors)]]);
    renderCharts();
    renderConnections();
}
function svgElement(tag, attrs = {}, text) { const element = document.createElementNS('http://www.w3.org/2000/svg', tag); for (const [key, value] of Object.entries(attrs))
    element.setAttribute(key, String(value)); if (text != null)
    element.textContent = text; return element; }
function chart(id, points, first, second, formatter) { const svg = $(id); svg.replaceChildren(); if (points.length < 2) {
    svg.append(svgElement('text', { x: 320, y: 95, 'text-anchor': 'middle' }, '采样中，稍后显示趋势'));
    return;
} const width = 640, left = 58, right = 12, top = 12, bottom = 160; const start = Date.parse(points[0].at), end = Date.parse(points.at(-1).at); const values = points.flatMap(p => second ? [first(p), second(p)] : [first(p)]); const max = Math.max(1, ...values) * 1.1; for (let i = 0; i <= 3; i++) {
    const y = top + (bottom - top) * i / 3;
    svg.append(svgElement('line', { x1: left, x2: width - right, y1: y, y2: y, class: 'grid' }), svgElement('text', { x: left - 7, y: y + 3, 'text-anchor': 'end' }, formatter(max * (1 - i / 3))));
} for (const [getter, cls] of [[first, 'line-a'], [second, 'line-b']].filter(([getter]) => getter)) {
    svg.append(svgElement('polyline', { class: cls, points: points.map(p => `${left + (Date.parse(p.at) - start) / (end - start) * (width - left - right)},${bottom - getter(p) / max * (bottom - top)}`).join(' ') }));
} svg.append(svgElement('text', { x: left, y: 184 }, new Date(start).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' })), svgElement('text', { x: width - right, y: 184, 'text-anchor': 'end' }, new Date(end).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' }))); }
function renderCharts() { if (!latest)
    return; const cutoff = Date.parse(latest.now) - Number($('range').value) * 60000; const points = history.filter(p => Date.parse(p.at) >= cutoff); chart('connections-chart', points, p => p.apps, p => p.agents, n => n.toFixed(0)); const rates = points.slice(1).map((p, i) => { const before = points[i], dt = (Date.parse(p.at) - Date.parse(before.at)) / 1000; return { ...p, rx: Math.max(0, p.bytesIn - before.bytesIn) / Math.max(dt, .001), tx: Math.max(0, p.bytesOut - before.bytesOut) / Math.max(dt, .001) }; }); chart('traffic-chart', rates, p => p.rx, p => p.tx, n => `${bytes(n)}/s`); const cpu = points.filter(p => p.processCpu != null); chart('cpu-chart', cpu, p => p.processCpu, null, n => `${n.toFixed(0)}%`); if (!cpu.length) {
    $('cpu-chart').replaceChildren(svgElement('text', { x: 320, y: 95, 'text-anchor': 'middle' }, '当前平台未提供 CPU 采样'));
} chart('memory-chart', points, p => p.heapBytes, points.every(p => p.rssBytes != null) ? p => p.rssBytes : null, bytes); }
function renderConnections() { if (!latest)
    return; const query = $('search').value.trim().toLowerCase(), role = $('role').value; const connections = (latest.stats.connections || []).filter(c => (role === 'all' || c.role === role) && `${c.id} ${c.roomId} ${c.peer}`.toLowerCase().includes(query)); const pages = Math.max(1, Math.ceil(connections.length / 50)); page = Math.min(page, pages - 1); const body = $('connections'); body.replaceChildren(); for (const c of connections.slice(page * 50, (page + 1) * 50)) {
    const tr = document.createElement('tr');
    const now = Date.parse(latest.now);
    const cells = [c.id, c.role === 'agent' ? '电脑插件' : '手机 App', c.roomId, c.peer, duration((now - Date.parse(c.connectedAt)) / 1000), `${duration((now - Date.parse(c.lastActivity)) / 1000)}前`, number(c.queueDepth)];
    cells.forEach((value, i) => { const td = document.createElement('td'); td.textContent = value; if (i === 0 || i === 2 || i === 3)
        td.className = 'mono'; tr.append(td); });
    body.append(tr);
} if (!connections.length) {
    const tr = document.createElement('tr'), td = document.createElement('td');
    td.colSpan = 7;
    td.className = 'empty';
    td.textContent = '暂无符合条件的在线终端';
    tr.append(td);
    body.append(tr);
} $('table-summary').textContent = `符合条件 ${connections.length} 条 · 全部 ${latest.stats.onlineApps + latest.stats.onlineAgents} 条`; $('page-number').textContent = `${page + 1} / ${pages}`; $('prev').disabled = page === 0; $('next').disabled = page >= pages - 1; }
$('refresh').addEventListener('click', load);
$('pause').addEventListener('click', () => { paused = !paused; $('pause').textContent = paused ? '恢复刷新' : '暂停刷新'; if (!paused)
    load(); });
$('range').addEventListener('change', renderCharts);
for (const id of ['role', 'search'])
    $(id).addEventListener(id === 'search' ? 'input' : 'change', () => { page = 0; renderConnections(); });
$('prev').addEventListener('click', () => { page--; renderConnections(); });
$('next').addEventListener('click', () => { page++; renderConnections(); });
setInterval(() => { if (!paused && !document.hidden && !$('dashboard').hidden)
    load(); }, 5000);
load();
