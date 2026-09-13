const HOST = "freenitial_yt_dlp_host";
const INSTALL_URL = "https://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download/setup.bat";
const MODULE_ERR =
  "Failed to communicate with the module (it may also come from yt-dlp).\n" +
  "Install or update the module:\n" + INSTALL_URL;

const MAX_CONCURRENT = 3;
const HISTORY_MAX = 200;
const PROGRESS_BROADCAST_MS = 250;       // at most 4 progress broadcasts per job per second
const TERMINAL_KEEP_MS = 10 * 60000;     // finished jobs stay listed for late-opening tabs
const SERVE_IDLE_MS = 10 * 60000;        // a drag server is closed 10 min after its last use

// ---------------------------------------------------------------------------
// Downloads are owned here, not by the page: they keep running when the tab
// that started them closes, and every tab (and the toolbar popup) shows the same
// list through a "vdrpb-ui" port.
//
// UI -> background: hello · start {request, ref} · cancel {id} · dismiss {id} ·
//                   clearFinished · retry {id} · serve {id | path}
// background -> UI: list {jobs} · job {job} · removed {id} · accepted {ref, id} ·
//                   dup {ref, id} · serve {id, path, url | error} · counts {active}
// ---------------------------------------------------------------------------
const jobs = new Map();          // id -> job (plain object, see jobView)
const natives = new Map();       // id -> native port of a running job
const queue = [];                // ids waiting for a slot
const uiPorts = new Set();
const progressTimers = new Map();
let nextSeq = 1;

const isTerminal = s => s === 'done' || s === 'error' || s === 'cancelled';
const activeCount = () => [...jobs.values()].filter(j => !isTerminal(j.status)).length;
const runningCount = () => natives.size;

const jobView = j => ({ ...j });

const post = (port, msg) => { try { port.postMessage(msg); } catch {} };
const broadcast = msg => { for (const p of uiPorts) post(p, msg); };

const updateBadge = () => {
  const n = activeCount();
  try {
    if (chrome.action) {
      chrome.action.setBadgeText({ text: n ? String(n) : '' });
      chrome.action.setBadgeBackgroundColor({ color: '#3b82f6' });
    }
  } catch {}
};
// Tabs that are not connected follow this key and reconnect when a download starts.
let publishedCount = -1;
const broadcastCounts = () => {
  const n = activeCount();
  broadcast({ type: 'counts', active: n });
  updateBadge();
  if (n !== publishedCount) {
    publishedCount = n;
    try { chrome.storage.local.set({ downloadsActive: { count: n, at: Date.now() } }); } catch {}
  }
};

// Job list survives a service-worker restart within the browser session.
let persistTimer = 0;
const persistJobs = () => {
  if (persistTimer) return;
  persistTimer = setTimeout(() => {
    persistTimer = 0;
    try { chrome.storage.session.set({ jobs: [...jobs.values()], queue: [...queue] }); } catch {}
  }, 500);
};

const broadcastJob = (job, immediate) => {
  persistJobs();
  if (immediate) {
    const t = progressTimers.get(job.id);
    if (t) { clearTimeout(t.timer); progressTimers.delete(job.id); }
    broadcast({ type: 'job', job: jobView(job) });
    return;
  }
  const now = Date.now();
  const t = progressTimers.get(job.id) || { last: 0, timer: 0 };
  if (now - t.last >= PROGRESS_BROADCAST_MS) {
    t.last = now;
    progressTimers.set(job.id, t);
    broadcast({ type: 'job', job: jobView(job) });
  } else if (!t.timer) {
    t.timer = setTimeout(() => {
      t.timer = 0;
      t.last = Date.now();
      if (jobs.has(job.id)) broadcast({ type: 'job', job: jobView(jobs.get(job.id)) });
    }, PROGRESS_BROADCAST_MS - (now - t.last));
    progressTimers.set(job.id, t);
  }
};

// ---------------------------------------------------------------------------
// History (chrome.storage.local "history", newest first). Writes are chained so
// two jobs finishing together never overwrite each other.
// ---------------------------------------------------------------------------
let historyChain = Promise.resolve();
const storageGet = keys => new Promise(r => { try { chrome.storage.local.get(keys, v => r(v || {})); } catch { r({}); } });
const storageSet = items => new Promise(r => { try { chrome.storage.local.set(items, () => r()); } catch { r(); } });
const addHistory = job => {
  const entry = {
    id: job.id, key: job.key, url: job.url, site: job.site, title: job.title || '', thumbnail: job.thumbnail || '',
    uploader: job.uploader || '', variant: job.variant, preset: job.request.preset || '', cut: job.request.cut || '',
    status: job.status, message: job.message || '', detail: job.detail || '', logPath: job.logPath || '',
    finalPath: job.finalPath || '', finalPaths: job.finalPaths || [], size: job.size || 0,
    startedAt: job.startedAt, finishedAt: job.finishedAt, request: job.request
  };
  historyChain = historyChain.then(async () => {
    const { history } = await storageGet(['history']);
    const list = Array.isArray(history) ? history.filter(h => h && h.id !== entry.id) : [];
    list.unshift(entry);
    await storageSet({ history: list.slice(0, HISTORY_MAX) });
  }).catch(() => {});
};

// ---------------------------------------------------------------------------
// Job lifecycle
// ---------------------------------------------------------------------------
const SUPPORTED_URL = /^https:\/\/(?:\w+\.)*(?:instagram\.com|facebook\.com|x\.com|tiktok\.com|youtube\.com)(?:[\/?#]|$)/;
const PRESETS = ['best', '1080', '720', 'size25'];

const sanitizeRequest = r => {
  if (!r || typeof r !== 'object') return null;
  const url = String(r.url || '');
  if (!SUPPORTED_URL.test(url) || url.length >= 2048 || /[\s"'<>|^`\\]/.test(url)) return null;
  const cut = r.cut ? String(r.cut) : '';
  if (cut && !/^\*(\d+(:\d+){0,2}(\.\d{1,3})?)?-(\d+(:\d+){0,2}(\.\d{1,3})?)?$/.test(cut)) return null;
  const item = parseInt(r.playlistItem, 10);
  return {
    url,
    mp3: !!r.mp3,
    isGIF: !!r.isGIF && !r.mp3,
    cut,
    convertMP4: !!r.convertMP4 && !r.mp3 && !r.isGIF,
    preciseCut: r.preciseCut !== false,
    preset: PRESETS.includes(r.preset) ? r.preset : 'best',
    bipAtEnd: !!r.bipAtEnd,
    copyAtEnd: !!r.copyAtEnd,
    keepConsoleOpen: !!r.keepConsoleOpen,
    playlistItem: Number.isFinite(item) && item >= 1 && item <= 50 ? item : null,
    mediaDuration: Number.isFinite(Number(r.mediaDuration)) && r.mediaDuration > 0 && r.mediaDuration < 86400 ? Number(r.mediaDuration) : 0,
    downloadDir: typeof r.downloadDir === 'string' ? r.downloadDir.slice(0, 260) : '',
    subfolder: /^[A-Za-z]{1,20}$/.test(r.subfolder || '') ? r.subfolder : '',
    site: typeof r.site === 'string' ? r.site.slice(0, 20) : ''
  };
};
const requestKey = r => [r.url, r.mp3, r.isGIF, r.cut, r.convertMP4, r.preset, r.playlistItem || '', r.preciseCut].join('|');
const variantOf = r => r.mp3 ? 'MP3' : r.isGIF ? 'GIF' : r.cut ? 'Clip' : r.convertMP4 ? 'MP4' : null;

const createJob = request => {
  const id = Date.now().toString(36) + '-' + (nextSeq++).toString(36);
  const job = {
    id, key: requestKey(request), url: request.url, site: request.site, variant: variantOf(request),
    status: 'queued', stage: '', message: 'Queued…', percent: null, speed: '', eta: '', downloaded: 0, total: 0,
    title: '', uploader: '', duration: 0, thumbnail: '',
    finalPath: '', finalPaths: [], size: 0, detail: '', logPath: '',
    startedAt: Date.now(), finishedAt: 0, request
  };
  jobs.set(id, job);
  queue.push(id);
  return job;
};

const finishJob = (job, fields) => {
  if (isTerminal(job.status)) return;
  Object.assign(job, fields, { finishedAt: Date.now(), speed: '', eta: '' });
  const port = natives.get(job.id);
  natives.delete(job.id);
  if (port) { try { port.disconnect(); } catch {} }
  const qi = queue.indexOf(job.id);
  if (qi >= 0) queue.splice(qi, 1);
  broadcastJob(job, true);
  addHistory(job);
  broadcastCounts();
  pump();
  applyPendingUpdate();
};

const hostPayload = r => ({
  URL: r.url, mp3: r.mp3, isGIF: r.isGIF, cut: r.cut || undefined, convertMP4: r.convertMP4, preciseCut: r.preciseCut,
  preset: r.preset, bipAtEnd: r.bipAtEnd, copyAtEnd: r.copyAtEnd, keepConsoleOpen: r.keepConsoleOpen,
  playlistItem: r.playlistItem || undefined, downloadDir: r.downloadDir || undefined, subfolder: r.subfolder || undefined,
  mediaDuration: r.cut && r.mediaDuration ? r.mediaDuration : undefined
});

const startJob = job => {
  let port;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch {
    finishJob(job, { status: 'error', message: MODULE_ERR });
    return;
  }
  natives.set(job.id, port);
  Object.assign(job, { status: 'running', message: 'Preparing…', stage: 'prepare' });
  broadcastJob(job, true);
  let doneSeen = false;
  port.onMessage.addListener(m => {
    if (!m || !jobs.has(job.id) || isTerminal(job.status)) return;
    if (m.type === 'meta') {
      Object.assign(job, {
        title: m.title || job.title, uploader: m.uploader || job.uploader,
        duration: Number(m.duration) || job.duration, thumbnail: m.thumbnail || job.thumbnail
      });
      broadcastJob(job, true);
    } else if (m.type === 'progress') {
      Object.assign(job, {
        stage: m.stage || job.stage, message: m.message || job.message,
        percent: typeof m.percent === 'number' ? Math.max(job.percent || 0, m.percent) : job.percent,
        speed: m.speed || (m.stage === 'download' ? job.speed : ''), eta: m.eta || (m.stage === 'download' ? job.eta : ''),
        downloaded: m.downloaded || 0, total: m.total || 0
      });
      broadcastJob(job, false);
    } else if (m.type === 'done') {
      doneSeen = true;
      if (m.success) {
        const paths = Array.isArray(m.finalPaths) && m.finalPaths.length ? m.finalPaths : (m.finalPath ? [m.finalPath] : []);
        finishJob(job, {
          status: 'done', stage: 'finalize', percent: 100, message: m.message || 'Done.',
          finalPath: m.finalPath || paths[0] || '', finalPaths: paths, size: m.size || 0, logPath: m.logPath || ''
        });
      } else {
        finishJob(job, { status: 'error', message: m.message || 'Download failed.', detail: m.detail || '', logPath: m.logPath || '' });
      }
    }
  });
  port.onDisconnect.addListener(() => {
    const err = chrome.runtime.lastError;
    if (natives.get(job.id) === port) natives.delete(job.id);
    if (!doneSeen && !isTerminal(job.status)) {
      finishJob(job, { status: 'error', message: err ? MODULE_ERR : 'The module stopped before the download finished.', detail: err ? err.message : '' });
    } else {
      pump();
    }
  });
  try {
    port.postMessage(hostPayload(job.request));
  } catch {
    finishJob(job, { status: 'error', message: MODULE_ERR });
  }
};

const pump = () => {
  while (runningCount() < MAX_CONCURRENT && queue.length) {
    const id = queue.shift();
    const job = jobs.get(id);
    if (job && job.status === 'queued') startJob(job);
  }
  persistJobs();
};

const cancelJob = id => {
  const job = jobs.get(id);
  if (!job || isTerminal(job.status)) return;
  finishJob(job, { status: 'cancelled', message: 'Download cancelled.' });
};

const removeJob = id => {
  const job = jobs.get(id);
  if (!job || !isTerminal(job.status)) return;
  jobs.delete(id);
  broadcast({ type: 'removed', id });
  persistJobs();
};

const pruneTerminal = () => {
  const now = Date.now();
  for (const job of [...jobs.values()]) {
    if (isTerminal(job.status) && now - job.finishedAt > TERMINAL_KEEP_MS) removeJob(job.id);
  }
};
setInterval(pruneTerminal, 60000);

const startRequest = (port, request, ref) => {
  const r = sanitizeRequest(request);
  if (!r) { post(port, { type: 'rejected', ref, message: 'Link not supported for download' }); return; }
  const key = requestKey(r);
  const existing = [...jobs.values()].find(j => j.key === key && !isTerminal(j.status));
  if (existing) { post(port, { type: 'dup', ref, id: existing.id }); return; }
  const job = createJob(r);
  post(port, { type: 'accepted', ref, id: job.id });
  broadcastJob(job, true);
  broadcastCounts();
  pump();
};

// ---------------------------------------------------------------------------
// Drag-out: a finished file is served by the native host on 127.0.0.1 so the
// page can hand Chrome a DownloadURL. One server per file, reused while fresh.
// ---------------------------------------------------------------------------
const serves = new Map();   // path -> { url, port, lastUse, pending: [callbacks] }
const randomToken = () => [...crypto.getRandomValues(new Uint8Array(16))].map(b => b.toString(16).padStart(2, '0')).join('');
const closeServe = path => {
  const s = serves.get(path);
  if (!s) return;
  serves.delete(path);
  if (s.port) { try { s.port.disconnect(); } catch {} }
};
setInterval(() => {
  const now = Date.now();
  for (const [path, s] of serves) if (s.url && now - s.lastUse > SERVE_IDLE_MS) closeServe(path);
}, 60000);

const requestServe = (path, cb) => {
  if (!path) { cb({ error: 'No file' }); return; }
  const existing = serves.get(path);
  if (existing) {
    existing.lastUse = Date.now();
    if (existing.url) cb({ url: existing.url });
    else existing.pending.push(cb);
    return;
  }
  const token = randomToken();
  const s = { url: '', port: null, lastUse: Date.now(), pending: [cb] };
  serves.set(path, s);
  const fail = error => {
    const pending = s.pending; s.pending = [];
    if (serves.get(path) === s) serves.delete(path);
    pending.forEach(f => f({ error }));
  };
  try {
    s.port = chrome.runtime.connectNative(HOST);
  } catch { fail(MODULE_ERR); return; }
  s.port.onMessage.addListener(m => {
    if (!m || m.type !== 'serve') return;
    if (!m.success) { fail(m.message || 'File not available.'); try { s.port.disconnect(); } catch {} return; }
    s.url = `http://127.0.0.1:${m.port}/${token}`;
    const pending = s.pending; s.pending = [];
    pending.forEach(f => f({ url: s.url }));
  });
  s.port.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;
    if (serves.get(path) === s) serves.delete(path);
    if (s.pending.length) fail('The module stopped.');
  });
  try { s.port.postMessage({ SERVE: path, token }); } catch { fail(MODULE_ERR); }
};

// ---------------------------------------------------------------------------
// UI ports
// ---------------------------------------------------------------------------
const restored = (async () => {
  try {
    const { jobs: saved, queue: savedQueue } = await new Promise(r => chrome.storage.session.get(['jobs', 'queue'], v => r(v || {})));
    if (Array.isArray(saved)) {
      for (const j of saved) {
        if (!j || !j.id || jobs.has(j.id)) continue;
        // A job that was running when the worker stopped lost its native process.
        if (j.status === 'running') Object.assign(j, { status: 'error', message: 'Interrupted: the browser stopped the extension. Try again.', finishedAt: Date.now() });
        jobs.set(j.id, j);
      }
      for (const id of Array.isArray(savedQueue) ? savedQueue : []) {
        const j = jobs.get(id);
        if (j && j.status === 'queued' && !queue.includes(id)) queue.push(id);
      }
      for (const j of jobs.values()) if (j.status === 'queued' && !queue.includes(j.id)) queue.push(j.id);
    }
  } catch {}
  broadcastCounts();
  pump();
})();

chrome.runtime.onConnect.addListener(port => {
  if (port.name !== 'vdrpb-ui') return;
  uiPorts.add(port);
  port.onDisconnect.addListener(() => uiPorts.delete(port));
  port.onMessage.addListener(async msg => {
    if (!msg || typeof msg !== 'object') return;
    await restored;
    switch (msg.type) {
      case 'hello':
        post(port, { type: 'list', jobs: [...jobs.values()].map(jobView) });
        post(port, { type: 'counts', active: activeCount() });
        break;
      case 'start':
        startRequest(port, msg.request, msg.ref);
        break;
      case 'retry': {
        const old = jobs.get(msg.id);
        const request = old ? old.request : msg.request;
        if (old && isTerminal(old.status)) removeJob(old.id);
        startRequest(port, request, msg.ref);
        break;
      }
      case 'cancel':
        cancelJob(msg.id);
        break;
      case 'dismiss':
        removeJob(msg.id);
        break;
      case 'clearFinished':
        for (const j of [...jobs.values()]) if (isTerminal(j.status)) removeJob(j.id);
        break;
      case 'serve': {
        const job = msg.id ? jobs.get(msg.id) : null;
        const path = job ? job.finalPath : (typeof msg.path === 'string' ? msg.path : '');
        requestServe(path, r => post(port, { type: 'serve', id: msg.id, path, ...r }));
        break;
      }
    }
  });
});

// ---------------------------------------------------------------------------
// Tabs already open when the extension is installed or updated (for example the
// tabs the browser restores while setup installs the extension) do not get the
// declared content scripts: they are injected here. A copy left by the previous
// version stops by itself (content.js); the page-world volume layer runs once
// per page (volume-lock.js).
// ---------------------------------------------------------------------------
const SITE_PATTERNS = ["https://*.facebook.com/*", "https://*.instagram.com/*", "https://*.x.com/*", "https://*.youtube.com/*", "https://*.tiktok.com/*"];
const injectIntoOpenTabs = async () => {
  let tabs = [];
  try { tabs = await chrome.tabs.query({ url: SITE_PATTERNS }); } catch { return; }
  for (const tab of tabs) {
    if (!Number.isInteger(tab.id) || tab.discarded) continue;
    const allFrames = { tabId: tab.id, allFrames: true };
    try { await chrome.scripting.executeScript({ target: allFrames, files: ["volume-lock.js"], world: "MAIN", injectImmediately: true }); } catch {}
    try { await chrome.scripting.executeScript({ target: allFrames, files: ["volume-bridge.js"], injectImmediately: true }); } catch {}
    try { await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["content.js"] }); } catch {}
  }
};
try {
  chrome.runtime.onInstalled.addListener(details => {
    if (details.reason === "install" || details.reason === "update") injectIntoOpenTabs();
  });
} catch {}

// ---------------------------------------------------------------------------
// Extension updates. Open tabs keep this worker alive, so a downloaded update
// would otherwise wait for a browser restart: it is applied as soon as no
// download runs, and the new version is injected into the open tabs.
// ---------------------------------------------------------------------------
let updatePending = false;
const applyPendingUpdate = () => {
  if (!updatePending || activeCount() > 0) return;
  updatePending = false;
  chrome.runtime.reload();
};
try { chrome.runtime.onUpdateAvailable.addListener(() => { updatePending = true; applyPendingUpdate(); }); } catch {}

// Asks the browser to fetch the version the native host just placed on the loopback
// server; the server may need a moment, and checks can be throttled. Without an
// update after the retries, the installer takes over.
const requestSelfUpdate = attempt => {
  const retry = delay => {
    if (attempt >= 6) { nativeOneShot({ doUpdate: true, method: 'setup' }); return; }
    setTimeout(() => requestSelfUpdate(attempt + 1), delay);
  };
  try {
    chrome.runtime.requestUpdateCheck((res, details) => {
      void chrome.runtime.lastError;
      const status = typeof res === 'string' ? res : res && res.status;
      if (status === 'update_available') return;   // onUpdateAvailable follows
      retry(status === 'throttled' ? 10000 : 3000);
    });
  } catch { retry(3000); }
};

// ---------------------------------------------------------------------------
// One-shot requests (sendMessage)
// ---------------------------------------------------------------------------
let updateCheck = null;   // { at, promise } — several tabs asking together share one host run

const nativeOneShot = payload => new Promise(resolve => {
  try {
    chrome.runtime.sendNativeMessage(HOST, payload, response => {
      if (chrome.runtime.lastError) {
        console.warn("[Background] Native messaging error:", chrome.runtime.lastError.message);
        resolve({ success: false, message: MODULE_ERR });
        return;
      }
      resolve(response || { success: false, message: "Unknown error" });
    });
  } catch {
    resolve({ success: false, message: MODULE_ERR });
  }
});

chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  const reply = (promise, okMsg) => {
    promise.then(response => {
      if (response && response.success) sendResponse({ ...response, message: response.message || okMsg });
      else sendResponse({ ...(response || {}), success: false, message: (response && response.message) || "Unknown error" });
    });
    return true;
  };
  switch (request && request.type) {
    case "SHOW":
      return reply(nativeOneShot({ show: request.finalPath }), "File revealed");
    case "COPY":
      return reply(nativeOneShot({ copy: request.finalPath }), "File copied");
    case "OPENLOG":
      return reply(nativeOneShot({ OPENLOG: request.path }), "Log opened");
    case "STAT":
      return reply(nativeOneShot({ STAT: Array.isArray(request.paths) ? request.paths.slice(0, 100) : [] }), "");
    case "CHECKUPDATE": {
      const now = Date.now();
      if (!updateCheck || now - updateCheck.at > 30000) updateCheck = { at: now, promise: nativeOneShot({ checkUpdate: true }) };
      return reply(updateCheck.promise, "");
    }
    case "DOUPDATE":
      restored.then(async () => {
        if (activeCount() > 0) { sendResponse({ success: false, message: "Finish or cancel downloads first, then update." }); return; }
        const r = await nativeOneShot({ doUpdate: true, method: 'auto' });
        if (r && r.success && r.mode === 'inplace') {
          requestSelfUpdate(0);
          sendResponse({ ...r, message: 'Updating…' });
        } else if (r && r.success) {
          sendResponse({ ...r, message: r.message || 'Update launched' });
        } else {
          sendResponse({ ...(r || {}), success: false, message: (r && r.message) || 'Failed to launch the update.' });
        }
      });
      return true;
    case "PICKFOLDER":
      // The dialog closes the popup that asked: the choice is stored here.
      nativeOneShot({ PICKFOLDER: true, initial: typeof request.initial === 'string' ? request.initial : '' }).then(async r => {
        if (r && r.success && r.path) {
          const { settings } = await storageGet(['settings']);
          await storageSet({ settings: { ...(settings && typeof settings === 'object' ? settings : {}), downloadDir: r.path } });
        }
        try { sendResponse(r); } catch {}
      });
      return true;
    case "COUNTS":
      restored.then(() => sendResponse({ success: true, active: activeCount() }));
      return true;
    default:
      return false;
  }
});
