// Toolbar popup: live downloads, history and settings.
(() => {
  const DEFAULT_SETTINGS = {
    convertMP4: false, bipAtEnd: true, copyAtEnd: false, keepConsoleOpen: false,
    preciseCut: true, preset: 'best', downloadDir: '', siteSubfolders: false,
    sameVolume: true, collapsedCards: false, stackPos: null
  };
  const PRESETS = ['best', '1080', '720', 'size25'];
  const PRESET_LABELS = { best: 'Best', '1080': '1080p', '720': '720p', size25: '≤ 25 MB' };
  const SITE_LABELS = { youtube: 'YouTube', facebook: 'Facebook', instagram: 'Instagram', tiktok: 'TikTok', twitter: 'X' };
  const PAGE_SIZE = 50;
  const MIME_BY_EXT = {
    mp4: 'video/mp4', webm: 'video/webm', mkv: 'video/x-matroska', mov: 'video/quicktime', flv: 'video/x-flv', '3gp': 'video/3gpp',
    mp3: 'audio/mpeg', m4a: 'audio/mp4', aac: 'audio/aac', opus: 'audio/ogg', ogg: 'audio/ogg', wav: 'audio/wav',
    gif: 'image/gif', webp: 'image/webp'
  };

  const $ = id => document.getElementById(id);
  const el = (tag, props = {}, children = []) => {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(props)) {
      if (k === 'class') e.className = v;
      else if (k === 'text') e.textContent = v;
      else if (k === 'style') Object.assign(e.style, v);
      else e[k] = v;
    }
    for (const c of [].concat(children)) if (c) e.append(c);
    return e;
  };
  const fileNameOf = p => String(p || '').split(/[\\/]/).pop();
  const mimeOf = p => MIME_BY_EXT[(fileNameOf(p).split('.').pop() || '').toLowerCase()] || 'application/octet-stream';
  const fmtBytes = n => {
    if (!n || n <= 0) return '';
    const u = ['B', 'KB', 'MB', 'GB']; let i = 0, v = n;
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return (i >= 2 ? v.toFixed(1) : Math.round(v)) + ' ' + u[i];
  };
  const fmtDate = t => {
    if (!t) return '';
    const d = new Date(t);
    const today = new Date();
    const sameDay = d.toDateString() === today.toDateString();
    return sameDay ? d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : d.toLocaleDateString([], { day: '2-digit', month: 'short' }) + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  };
  const flash = (b, text) => {
    const label = b.textContent;
    b.textContent = text;
    setTimeout(() => { b.textContent = label; }, 1800);
  };
  const sendMessage = msg => new Promise(resolve => {
    try { chrome.runtime.sendMessage(msg, r => resolve(chrome.runtime.lastError ? { success: false } : (r || { success: false }))); }
    catch { resolve({ success: false }); }
  });

  // ---------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------
  let settings = { ...DEFAULT_SETTINGS };
  const normalize = s => {
    const n = { ...DEFAULT_SETTINGS, ...(s && typeof s === 'object' ? s : {}) };
    if (!PRESETS.includes(n.preset)) n.preset = 'best';
    if (typeof n.downloadDir !== 'string') n.downloadDir = '';
    return n;
  };
  const saveSetting = (key, value) => {
    settings = { ...settings, [key]: value };
    chrome.storage.local.set({ settings });
  };
  const isValidFolder = v => v === '' || (/^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)/.test(v) && !/(^|[\\/])\.\.([\\/]|$)/.test(v) && !/[<>"|?*]/.test(v.slice(2)));
  const bindCheckbox = (id, key) => $(id).addEventListener('change', () => saveSetting(key, $(id).checked));
  const renderSettings = () => {
    const dir = $('download-dir');
    if (document.activeElement !== dir) { dir.value = settings.downloadDir; dir.classList.remove('invalid'); }
    $('site-subfolders').checked = !!settings.siteSubfolders;
    $('same-volume').checked = settings.sameVolume !== false;
    $('preset').value = settings.preset;
    $('precise-cut').checked = !!settings.preciseCut;
    $('convert-mp4').checked = !!settings.convertMP4;
    $('beep').checked = !!settings.bipAtEnd;
    $('copy-end').checked = !!settings.copyAtEnd;
  };
  bindCheckbox('site-subfolders', 'siteSubfolders');
  bindCheckbox('same-volume', 'sameVolume');
  bindCheckbox('precise-cut', 'preciseCut');
  bindCheckbox('convert-mp4', 'convertMP4');
  bindCheckbox('beep', 'bipAtEnd');
  bindCheckbox('copy-end', 'copyAtEnd');
  $('preset').addEventListener('change', () => saveSetting('preset', $('preset').value));
  const commitFolder = () => {
    const dir = $('download-dir');
    let v = dir.value.trim();
    if (v.length > 3) v = v.replace(/[\\/]+$/, '');   // "D:\Videos\" -> "D:\Videos", "D:\" stays
    if (!isValidFolder(v)) { dir.classList.add('invalid'); dir.title = 'Use an absolute folder path, for example D:\\Videos'; return; }
    dir.classList.remove('invalid'); dir.title = '';
    dir.value = v;
    if (v !== settings.downloadDir) saveSetting('downloadDir', v);
  };
  $('download-dir').addEventListener('change', commitFolder);
  $('download-dir').addEventListener('keydown', e => { if (e.key === 'Enter') { commitFolder(); e.target.blur(); } });
  $('default-folder').addEventListener('click', () => { $('download-dir').value = ''; commitFolder(); });
  // The folder dialog takes the focus, which closes this popup: background.js
  // stores the chosen folder itself.
  $('pick-folder').addEventListener('click', async () => {
    const b = $('pick-folder');
    b.disabled = true;
    const r = await sendMessage({ type: 'PICKFOLDER', initial: settings.downloadDir });
    b.disabled = false;
    if (!r.success && r.message && !r.cancelled) flash(b, 'Failed');
  });
  const settingsBox = $('settings-box');
  try { settingsBox.open = localStorage.getItem('vdrpb_popup_settings_open') === '1'; } catch {}
  settingsBox.addEventListener('toggle', () => { try { localStorage.setItem('vdrpb_popup_settings_open', settingsBox.open ? '1' : '0'); } catch {} });

  // ---------------------------------------------------------------------------
  // Buttons shared by active and history items
  // ---------------------------------------------------------------------------
  const serveWaiters = new Map();   // path -> callbacks
  const mkDrag = path => {
    const b = el('button', { text: '⿻ Drag', title: 'Drag the file to a folder, the desktop or another application' });
    b.draggable = true;
    let url = '', pending = false;
    const prepare = () => {
      if (url || pending) return;
      pending = true;
      const list = serveWaiters.get(path) || [];
      list.push(r => { pending = false; if (r.url) url = r.url; else if (r.error) b.title = r.error; });
      serveWaiters.set(path, list);
      if (list.length === 1) post({ type: 'serve', path });
    };
    ['pointerenter', 'pointerdown', 'focus'].forEach(t => b.addEventListener(t, prepare));
    b.addEventListener('dragstart', e => {
      if (!url) { e.preventDefault(); prepare(); flash(b, 'Preparing… drag again'); return; }
      e.dataTransfer.setData('DownloadURL', `${mimeOf(path)}:${fileNameOf(path)}:${url}`);
      e.dataTransfer.setData('text/plain', path);
      e.dataTransfer.effectAllowed = 'copy';
    });
    b.addEventListener('click', () => { prepare(); flash(b, 'Drag me to a folder'); });
    return b;
  };
  const mkHost = (label, type, payload, done) => {
    const b = el('button', { text: label });
    b.addEventListener('click', async () => {
      const r = await sendMessage({ type, ...payload });
      if (r.success) { if (done) done(b); } else flash(b, 'Failed');
    });
    return b;
  };
  const mkThumb = (src, missingGlyph = '🎞') => {
    const t = el('div', { class: 'thumb', text: missingGlyph });
    if (src) {
      const img = new Image();
      img.referrerPolicy = 'no-referrer';
      img.onload = () => { t.textContent = ''; t.append(img); };
      img.src = src;
    }
    return t;
  };
  const describe = j => [SITE_LABELS[j.site] || '', j.variant || '', j.preset && j.preset !== 'best' ? PRESET_LABELS[j.preset] : '', fmtBytes(j.size)].filter(Boolean).join(' · ');

  // ---------------------------------------------------------------------------
  // Active downloads (live through the vdrpb-ui port)
  // ---------------------------------------------------------------------------
  const jobs = new Map();
  let port = null;
  const post = msg => {
    if (!port) connect();
    try { port.postMessage(msg); } catch {}
  };
  const renderActive = () => {
    const box = $('active');
    box.textContent = '';
    const active = [...jobs.values()].filter(j => j.status === 'queued' || j.status === 'running').sort((a, b) => a.startedAt - b.startedAt);
    $('count').textContent = active.length ? `${active.length} active` : '';
    $('active-section').hidden = active.length === 0;
    for (const j of active) {
      const fill = el('div', { class: 'fill' });
      fill.style.width = (typeof j.percent === 'number' ? j.percent : 0) + '%';
      const status = j.status === 'queued' ? 'Queued…' : [j.message, typeof j.percent === 'number' ? j.percent + '%' : '', j.speed].filter(Boolean).join(' · ');
      const cancel = el('button', { text: '✕ Cancel' });
      cancel.addEventListener('click', () => post({ type: 'cancel', id: j.id }));
      box.append(el('div', { class: 'item' }, [
        mkThumb(j.thumbnail),
        el('div', { class: 'body' }, [
          el('a', { class: 'title', text: j.title || j.url, href: j.url, target: '_blank', title: j.url }),
          el('div', { class: 'sub', text: status }),
          el('div', { class: 'track' }, [fill]),
          el('div', { class: 'row' }, [cancel])
        ])
      ]));
    }
  };
  let activeRenderQueued = false;
  const scheduleActive = () => {
    if (activeRenderQueued) return;
    activeRenderQueued = true;
    setTimeout(() => { activeRenderQueued = false; renderActive(); }, 50);
  };
  const connect = () => {
    port = chrome.runtime.connect({ name: 'vdrpb-ui' });
    port.onMessage.addListener(msg => {
      if (!msg) return;
      if (msg.type === 'list') { jobs.clear(); (msg.jobs || []).forEach(j => jobs.set(j.id, j)); scheduleActive(); }
      else if (msg.type === 'job') { jobs.set(msg.job.id, msg.job); scheduleActive(); }
      else if (msg.type === 'removed') { jobs.delete(msg.id); scheduleActive(); }
      else if (msg.type === 'serve') {
        const list = serveWaiters.get(msg.path) || [];
        serveWaiters.delete(msg.path);
        list.forEach(cb => cb(msg));
      }
    });
    port.onDisconnect.addListener(() => { void chrome.runtime.lastError; port = null; });
    port.postMessage({ type: 'hello' });
  };
  connect();

  // ---------------------------------------------------------------------------
  // History (chrome.storage.local "history", written by background.js)
  // ---------------------------------------------------------------------------
  let history = [];
  let page = 0;
  const existence = new Map();   // path -> bool
  const renderHistory = () => {
    const box = $('history');
    box.textContent = '';
    const done = history.filter(h => h && h.status);
    const pages = Math.max(1, Math.ceil(done.length / PAGE_SIZE));
    page = Math.min(page, pages - 1);
    const visible = done.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);
    if (!visible.length) box.append(el('div', { class: 'empty', text: 'No downloads yet.' }));
    for (const h of visible) {
      const path = h.finalPath || (h.finalPaths && h.finalPaths[0]) || '';
      const exists = path ? existence.get(path) : false;
      const missing = h.status === 'done' && exists === false;
      const row = el('div', { class: 'row' });
      if (h.status === 'done' && path) {
        const drag = mkDrag(path), show = mkHost('🗁 Show', 'SHOW', { finalPath: path }), copy = mkHost('⧉ Copy', 'COPY', { finalPath: path }, b => flash(b, 'Copied'));
        if (missing) [drag, show, copy].forEach(b => { b.disabled = true; b.title = 'File moved or deleted'; });
        row.append(drag, show, copy);
      }
      if (h.status === 'error' && h.logPath) row.append(mkHost('Open log', 'OPENLOG', { path: h.logPath }));
      if (h.request) {
        const retry = el('button', { text: '↻ Retry' });
        retry.addEventListener('click', () => { post({ type: 'start', request: h.request, ref: 'popup' }); flash(retry, 'Started'); });
        row.append(retry);
      }
      const rm = el('button', { text: '✕', title: 'Remove from history' });
      rm.addEventListener('click', async () => {
        const { history: cur } = await chrome.storage.local.get(['history']);
        await chrome.storage.local.set({ history: (Array.isArray(cur) ? cur : []).filter(x => x && x.id !== h.id) });
      });
      row.append(rm);
      const statusText = h.status === 'done'
        ? [describe(h), h.finalPaths && h.finalPaths.length > 1 ? `${h.finalPaths.length} files` : '', fmtDate(h.finishedAt)].filter(Boolean).join(' · ')
        : h.status === 'cancelled' ? ['Cancelled', fmtDate(h.finishedAt)].join(' · ')
        : (h.message || 'Failed') + ' · ' + fmtDate(h.finishedAt);
      box.append(el('div', { class: 'item' + (missing ? ' missing' : '') }, [
        mkThumb(h.thumbnail),
        el('div', { class: 'body' }, [
          el('a', { class: 'title', text: h.title || h.url, href: h.url, target: '_blank', title: (h.title ? h.title + '\n' : '') + h.url + (path ? '\n' + path : '') }),
          el('div', { class: 'sub' + (h.status === 'error' ? ' err' : ''), text: statusText }),
          row
        ])
      ]));
    }
    const pager = $('pager');
    pager.textContent = '';
    if (pages > 1) {
      const prev = el('button', { text: '‹', disabled: page === 0 });
      const next = el('button', { text: '›', disabled: page >= pages - 1 });
      prev.addEventListener('click', () => { page--; renderHistory(); checkFiles(); });
      next.addEventListener('click', () => { page++; renderHistory(); checkFiles(); });
      pager.append(prev, el('span', { class: 'badge', text: `${page + 1} / ${pages}` }), next);
    }
    $('clear-history').hidden = done.length === 0;
  };
  // One STAT round per page view: entries whose file was moved or deleted get
  // their file buttons disabled.
  const checkFiles = async () => {
    const visible = history.slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE);
    const paths = [...new Set(visible.filter(h => h.status === 'done').map(h => h.finalPath || (h.finalPaths && h.finalPaths[0])).filter(p => p && !existence.has(p)))];
    if (!paths.length) return;
    const r = await sendMessage({ type: 'STAT', paths });
    if (!r.success || !Array.isArray(r.exists)) return;
    paths.forEach((p, i) => existence.set(p, !!r.exists[i]));
    renderHistory();
  };
  $('clear-history').addEventListener('click', () => chrome.storage.local.set({ history: [] }));
  $('open-folder').addEventListener('click', async () => {
    const b = $('open-folder');
    const r = await sendMessage({ type: 'SHOW', finalPath: settings.downloadDir || '::downloads' });
    if (!r.success) flash(b, 'Failed');
  });

  chrome.storage.local.get(['settings', 'history']).then(r => {
    settings = normalize(r.settings);
    history = Array.isArray(r.history) ? r.history : [];
    renderSettings();
    renderHistory();
    checkFiles();
  });
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== 'local') return;
    if (changes.settings) { settings = normalize(changes.settings.newValue); renderSettings(); }
    if (changes.history) { history = Array.isArray(changes.history.newValue) ? changes.history.newValue : []; renderHistory(); checkFiles(); }
  });
})();
