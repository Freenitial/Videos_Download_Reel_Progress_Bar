(() => {

const knownWebsite = window.location.href.match(/^https:\/\/(?:\w+\.)?(facebook\.com|x\.com|youtube\.com|instagram\.com|tiktok\.com)/);
let current_website = knownWebsite ? (
  knownWebsite[1] === "facebook.com"   ? "facebook"  :
  knownWebsite[1] === "x.com"          ? "twitter"   :
  knownWebsite[1] === "youtube.com"    ? "youtube"   :
  knownWebsite[1] === "tiktok.com"     ? "tiktok"    :
  knownWebsite[1] === "instagram.com"  ? "instagram" : "unknown"
) : "unknown";

// At most ONE control bar exists at a time — keep a direct reference instead of
// re-querying the DOM on every tick.
let activeBar = null;

// One live instance per page. background.js injects this script into tabs that
// were already open when the extension was installed or updated; the copy left
// by a previous version is detached from the extension and stops when the new
// one announces itself (or when it notices on its own).
const lifetime = new AbortController();
const LIVE = { signal: lifetime.signal };
let alive = true;
document.dispatchEvent(new CustomEvent('vdrpb-content-takeover'));

// ---------------------------------------------------------------------------
// Extension storage. Settings, the update verdict and the update-launch claim
// live in chrome.storage.local: shared by the five sites and out of reach of
// sites that prune localStorage. Reads are asynchronous, so the in-memory copies
// start at their defaults, are filled once storage answers, and follow
// chrome.storage.onChanged afterwards.
// ---------------------------------------------------------------------------
const DEFAULT_SETTINGS = {
  convertMP4: false, bipAtEnd: true, copyAtEnd: false, keepConsoleOpen: false,
  preciseCut: true, preset: 'best', downloadDir: '', siteSubfolders: false,
  sameVolume: true, collapsedCards: false, stackPos: null
};
const PRESETS = ['best', '1080', '720', 'size25'];
let settings = { ...DEFAULT_SETTINGS };
const EXT_VER = (() => { try { return chrome.runtime.getManifest().version; } catch { return ''; } })();

const extStorage = () => { try { return (chrome.storage && chrome.storage.local) || null; } catch { return null; } };
const storageGet = keys => new Promise(resolve => {
  const area = extStorage();
  if (!area) { resolve({}); return; }
  try { area.get(keys, r => resolve((!chrome.runtime.lastError && r) || {})); } catch { resolve({}); }
});
const storageSet = items => {
  const area = extStorage();
  if (!area) return;
  try { area.set(items, () => void chrome.runtime.lastError); } catch {}
};
const storageRemove = keys => {
  const area = extStorage();
  if (!area) return;
  try { area.remove(keys, () => void chrome.runtime.lastError); } catch {}
};

const normalizeSettings = obj => {
  const s = { ...DEFAULT_SETTINGS, ...(obj && typeof obj === 'object' ? obj : {}) };
  if (!PRESETS.includes(s.preset)) s.preset = 'best';
  if (typeof s.downloadDir !== 'string') s.downloadDir = '';
  return s;
};
const settingsListeners = [];
const applySettings = obj => {
  settings = normalizeSettings(obj);
  settingsListeners.forEach(fn => { try { fn(settings); } catch {} });
};
const saveSetting = (key, value) => {
  settings = { ...settings, [key]: value };
  storageSet({ settings });
  settingsListeners.forEach(fn => { try { fn(settings); } catch {} });
};

// Options stored per origin in localStorage by older versions: copied once into
// the shared settings, only for keys still at their default so a second origin
// never overrides what the first one migrated.
const LEGACY_MIGRATED_KEY = 'vdrpb_migrated';
const migrateLegacySettings = stored => {
  const read = k => { try { return localStorage.getItem(k); } catch { return null; } };
  if (read(LEGACY_MIGRATED_KEY) === '1') return null;
  const next = normalizeSettings(stored);
  const bools = { convertMP4: 'extension_convertMP4', bipAtEnd: 'extension_bipAtEnd', copyAtEnd: 'extension_copyAtEnd', keepConsoleOpen: 'extension_keepConsoleOpen' };
  for (const [key, legacy] of Object.entries(bools)) {
    const v = read(legacy);
    if (v !== null && next[key] === DEFAULT_SETTINGS[key]) next[key] = v === 'true';
  }
  if (read('vdrpb_collapsed') === '1' && !next.collapsedCards) next.collapsedCards = true;
  if (!next.stackPos) {
    try {
      const p = JSON.parse(read('vdrpb_stack_pos') || 'null');
      if (p && Number.isFinite(p.right) && Number.isFinite(p.bottom)) next.stackPos = { right: p.right, bottom: p.bottom };
    } catch {}
  }
  try {
    ['extension_convertMP4', 'extension_bipAtEnd', 'extension_copyAtEnd', 'extension_keepConsoleOpen', 'extension_useChromeCookies',
     'vdrpb_collapsed', 'vdrpb_stack_pos', 'vdrpb_update', 'vdrpb_update_launch'].forEach(k => localStorage.removeItem(k));
    localStorage.setItem(LEGACY_MIGRATED_KEY, '1');
  } catch {}
  return next;
};

// "2.2" == "2.2.0", "2.10" > "2.9".
const numericVersionGreater = (a, b) => {
  const pa = String(a || '').split('.').map(x => parseInt(x, 10) || 0);
  const pb = String(b || '').split('.').map(x => parseInt(x, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i] || 0, y = pb[i] || 0;
    if (x !== y) return x > y;
  }
  return false;
};

// Update verdict written by an older extension version is ignored: it may name
// the version that is now installed.
const EMPTY_UPDATE = { available: false, latest: null, at: 0 };
let vdrpbUpdate = { ...EMPTY_UPDATE };
let updateLaunch = { at: 0 };
let updateStateLoaded = false;
const setUpdateCache = c => { vdrpbUpdate = (c && typeof c === 'object' && c.ver === EXT_VER) ? c : { ...EMPTY_UPDATE }; };
const updateAvailable = () => !!(vdrpbUpdate.available && vdrpbUpdate.latest && numericVersionGreater(vdrpbUpdate.latest, EXT_VER));

storageGet(['settings', 'updateCache', 'updateLaunch']).then(r => {
  const migrated = migrateLegacySettings(r.settings);
  applySettings(migrated || r.settings);
  if (migrated) storageSet({ settings });
  if (r.updateCache && r.updateCache.ver !== EXT_VER) {
    storageRemove(['updateCache', 'updateLaunch']);
    setUpdateCache(null);
  } else {
    setUpdateCache(r.updateCache);
    updateLaunch = (r.updateLaunch && typeof r.updateLaunch === 'object') ? r.updateLaunch : { at: 0 };
  }
  updateStateLoaded = true;
  refreshUpdateButtons();
  if (vdrpbStack) placeStack(vdrpbStack);
});
try {
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== 'local') return;
    if (changes.settings) applySettings(changes.settings.newValue);
    if (changes.updateCache) setUpdateCache(changes.updateCache.newValue);
    if (changes.updateLaunch) updateLaunch = changes.updateLaunch.newValue || { at: 0 };
    if (changes.updateCache || changes.updateLaunch) refreshUpdateButtons();
  });
} catch {}

// ---------------------------------------------------------------------------
// One-time injected styles (switch toggles, notification fade, progress panel).
// Namespaced with vdrpb- so we never collide with the host page's CSS, and
// injected ONCE instead of per-menu.
// ---------------------------------------------------------------------------
const injectStyles = () => {
  // Reused when present: a newer version injected into an open tab replaces the rules.
  const style = document.getElementById('vdrpb-styles') || document.createElement('style');
  style.id = 'vdrpb-styles';
  style.textContent = `
    @keyframes vdrpb-fadeout { to { opacity: 0; } }
    @keyframes vdrpb-indeterminate {
      0%   { transform: translateX(-100%); }
      100% { transform: translateX(400%); }
    }
    /* Control bar and download menu. Buttons and text fields are reset with
       all:unset so the host page's own button/input styles never leak in. */
    .extension-control-bar, .extension-control-bar * { box-sizing: border-box; }
    .extension-control-bar {
      position: absolute; z-index: 2147483647; display: flex; flex-direction: column; align-items: stretch; gap: 6px;
      padding: 4px 6px; border-radius: 10px; background: rgba(14,18,23,.84); border: 1px solid rgba(255,255,255,.08);
      box-shadow: 0 6px 20px rgba(0,0,0,.35); -webkit-backdrop-filter: blur(10px); backdrop-filter: blur(10px);
      color: #e8eef3; font: 500 12px/1.2 'Roboto','Segoe UI',system-ui,sans-serif; letter-spacing: normal; text-transform: none;
      text-align: left; pointer-events: auto; user-select: none; transition: opacity .3s;
    }
    .vdrpb-row { display: flex; align-items: center; gap: 4px; }
    .vdrpb-ibtn {
      all: unset; box-sizing: border-box; display: inline-flex; align-items: center; justify-content: center; flex: none;
      width: 28px; height: 28px; border-radius: 7px; color: #e8eef3; cursor: pointer; transition: background .15s, color .15s;
    }
    .vdrpb-ibtn:hover { background: rgba(255,255,255,.12); color: #fff; }
    .vdrpb-ibtn.open { background: rgba(59,130,246,.24); color: #93c5fd; }
    .vdrpb-ibtn svg { width: 16px; height: 16px; pointer-events: none; }
    .vdrpb-time { flex: none; min-width: 34px; text-align: center; white-space: nowrap; font-size: 12px; color: #cfd9e3; font-variant-numeric: tabular-nums; }
    .vdrpb-range { -webkit-appearance: auto; appearance: auto; accent-color: #3b82f6; margin: 0; padding: 0; height: 16px; cursor: pointer; background: transparent; }
    .vdrpb-progress { position: relative; flex: 1; display: flex; align-items: center; min-width: 130px; margin: 0 2px; }
    .vdrpb-progress .vdrpb-range { width: 100%; }
    .vdrpb-cutrange { position: absolute; top: 50%; height: 6px; transform: translateY(-50%); display: none; background: rgba(250,204,21,.55); border-radius: 3px; pointer-events: none; }
    .vdrpb-volume { display: flex; align-items: center; gap: 1px; flex: none; }
    .vdrpb-volume .vdrpb-range { width: 72px; }
    .vdrpb-sep { flex: none; width: 1px; height: 18px; margin: 0 3px; background: rgba(255,255,255,.14); }

    .vdrpb-download-menu {
      position: absolute; top: calc(100% + 6px); z-index: 2147483647; width: 236px; flex-direction: column; gap: 6px; padding: 8px;
      border-radius: 12px; background: rgba(14,18,23,.97); border: 1px solid rgba(255,255,255,.1); box-shadow: 0 14px 36px rgba(0,0,0,.55);
      color: #e8eef3; font: 500 12px/1.25 'Roboto','Segoe UI',system-ui,sans-serif; cursor: default;
    }
    .vdrpb-download-menu::before { content: ''; position: absolute; left: 0; right: 0; top: -8px; height: 8px; }
    .vdrpb-download-menu.vdrpb-menu-up { top: auto; bottom: calc(100% + 6px); }
    .vdrpb-download-menu.vdrpb-menu-up::before { top: auto; bottom: -8px; }
    .vdrpb-menu-right { right: 0; }
    .vdrpb-menu-left { left: 0; }
    .vdrpb-mbtn {
      all: unset; box-sizing: border-box; display: flex; align-items: center; gap: 9px; width: 100%; height: 34px; padding: 0 11px;
      border-radius: 8px; cursor: pointer; color: #e8eef3; background: rgba(255,255,255,.07);
      font: 600 13px/1 'Roboto','Segoe UI',system-ui,sans-serif; transition: background .15s;
    }
    .vdrpb-mbtn:hover { background: rgba(255,255,255,.14); }
    .vdrpb-mbtn.primary { background: #2563eb; color: #fff; }
    .vdrpb-mbtn.primary:hover { background: #3b82f6; }
    .vdrpb-mbtn svg { width: 16px; height: 16px; flex: none; pointer-events: none; }
    .vdrpb-mdiv { height: 1px; margin: 2px 0; background: rgba(255,255,255,.08); }
    .vdrpb-mhead, .vdrpb-mdisclosure {
      all: unset; box-sizing: border-box; display: flex; align-items: center; gap: 8px; width: 100%; min-height: 26px; padding: 0 2px;
      cursor: pointer; color: #e8eef3; font: 600 12px/1.2 'Roboto','Segoe UI',system-ui,sans-serif;
    }
    .vdrpb-mhead svg, .vdrpb-mdisclosure svg { width: 14px; height: 14px; flex: none; color: #9fb3c8; }
    .vdrpb-mdisclosure:hover { color: #fff; }
    .vdrpb-mlabel { flex: 1; }
    .vdrpb-chev { transition: transform .2s; }
    .vdrpb-mdisclosure[aria-expanded="true"] .vdrpb-chev { transform: rotate(180deg); }
    .vdrpb-switch { position: relative; display: inline-block; flex: none; width: 30px; height: 17px; }
    .vdrpb-switch input { position: absolute; opacity: 0; width: 0; height: 0; margin: 0; }
    .vdrpb-slider { position: absolute; inset: 0; cursor: pointer; border-radius: 17px; background: rgba(255,255,255,.22); transition: background .2s; }
    .vdrpb-slider::before {
      content: ''; position: absolute; left: 2px; top: 2px; width: 13px; height: 13px; border-radius: 50%;
      background: #fff; box-shadow: 0 1px 2px rgba(0,0,0,.4); transition: transform .2s;
    }
    .vdrpb-switch input:checked + .vdrpb-slider { background: #3b82f6; }
    .vdrpb-switch input:checked + .vdrpb-slider::before { transform: translateX(13px); }
    .vdrpb-cutfields { display: flex; flex-direction: column; gap: 5px; transition: opacity .15s; }
    .vdrpb-cutfields.off { opacity: .45; }
    .vdrpb-timerow { display: flex; align-items: center; gap: 6px; }
    .vdrpb-timelabel { flex: none; width: 32px; font-size: 11px; color: #9fb3c8; }
    .vdrpb-input {
      all: unset; box-sizing: border-box; flex: 1; min-width: 0; height: 26px; padding: 0 7px; border-radius: 6px; cursor: text;
      background: rgba(255,255,255,.06); border: 1px solid rgba(255,255,255,.14); color: #e8eef3;
      font: 500 12px/24px 'Roboto','Segoe UI',system-ui,sans-serif; font-variant-numeric: tabular-nums; user-select: text;
    }
    .vdrpb-input:focus { border-color: #3b82f6; background: rgba(59,130,246,.1); }
    .vdrpb-chip {
      all: unset; box-sizing: border-box; flex: none; height: 26px; padding: 0 9px; border-radius: 6px; cursor: pointer; white-space: nowrap;
      background: rgba(255,255,255,.08); color: #cfd9e3; font: 600 11px/26px 'Roboto','Segoe UI',system-ui,sans-serif;
    }
    .vdrpb-chip:hover { background: rgba(255,255,255,.16); color: #fff; }
    .vdrpb-options-menu { flex-direction: column; gap: 7px; padding: 2px; }
    .vdrpb-opt { display: flex; align-items: center; justify-content: space-between; gap: 8px; min-height: 22px; cursor: pointer; color: #cfd9e3; }
    .vdrpb-optlabel { font-size: 11px; color: #9fb3c8; margin-bottom: -3px; }
    .vdrpb-seg { display: flex; gap: 2px; padding: 2px; border-radius: 8px; background: rgba(255,255,255,.06); }
    .vdrpb-seg-btn {
      all: unset; box-sizing: border-box; flex: 1; height: 24px; border-radius: 6px; text-align: center; white-space: nowrap; cursor: pointer;
      color: #9fb3c8; font: 600 11px/24px 'Roboto','Segoe UI',system-ui,sans-serif;
    }
    .vdrpb-seg-btn:hover { color: #fff; }
    .vdrpb-seg-btn[aria-checked="true"] { background: #2563eb; color: #fff; }
    .vdrpb-folder { display: flex; align-items: center; gap: 6px; min-width: 0; font-size: 11px; color: #7f95a5; }
    .vdrpb-folder span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .vdrpb-folder svg { width: 13px; height: 13px; flex: none; }
    .vdrpb-ibtn:focus-visible, .vdrpb-mbtn:focus-visible, .vdrpb-mdisclosure:focus-visible, .vdrpb-chip:focus-visible,
    .vdrpb-seg-btn:focus-visible, .vdrpb-switch input:focus-visible + .vdrpb-slider { outline: 2px solid #60a5fa; outline-offset: 1px; }

    .vdrpb-notification {
      position: fixed; top: 20px; left: 50%; transform: translateX(-50%); z-index: 2147483647; max-width: min(90vw, 520px);
      display: flex; align-items: flex-start; gap: 10px; padding: 11px 16px 11px 13px; border-radius: 10px;
      background: rgba(14,18,23,.97); border: 1px solid rgba(255,255,255,.1); border-left: 3px solid #22c55e;
      box-shadow: 0 10px 30px rgba(0,0,0,.45); color: #e8eef3; font: 500 13px/1.4 'Roboto','Segoe UI',system-ui,sans-serif;
      white-space: pre-wrap; text-align: left;
    }
    .vdrpb-notification.err { border-left-color: #ef4444; }
    .vdrpb-notification .vdrpb-notif-icon { flex: none; font-weight: 700; color: #22c55e; }
    .vdrpb-notification.err .vdrpb-notif-icon { color: #f87171; }
    @keyframes vdrpb-shimmer { 0%{opacity:.5} 50%{opacity:1} 100%{opacity:.5} }
    .vdrpb-stack { position: fixed; z-index: 2147483647; display: flex; flex-direction: column; gap: 6px; width: 340px; max-width: 92vw; }
    .vdrpb-grip { font: 600 11px 'Roboto',sans-serif; letter-spacing:.04em; color:#9fb3c8; background: rgba(0,10,15,.85); padding:5px 10px; border-radius:8px; cursor: move; user-select:none; align-self:flex-end; }
    .vdrpb-cards { display:flex; flex-direction:column; gap:8px; max-height:78vh; overflow-y:auto; }
    .vdrpb-card { background: rgba(10,16,22,.97); color:#e8eef3; border:1px solid rgba(255,255,255,.08); border-radius:10px; padding:11px 12px; box-shadow:0 8px 24px rgba(0,0,0,.5); font-family:'Roboto',sans-serif; font-size:13px; display:flex; flex-direction:column; gap:8px; }
    .vdrpb-card.ok { border-color: rgba(34,197,94,.5); }
    .vdrpb-card.err { border-color: rgba(239,68,68,.55); }
    .vdrpb-card.cxl { border-color: rgba(148,163,184,.5); }
    .vdrpb-card.cxl .vdrpb-fill { background:#94a3b8; }
    .vdrpb-card.ok .vdrpb-ring { background:conic-gradient(#22c55e calc(var(--pct,0)*1%), rgba(255,255,255,.15) 0); }
    .vdrpb-card.err .vdrpb-ring { background:conic-gradient(#ef4444 100%, transparent 0); }
    .vdrpb-card.cxl .vdrpb-ring { background:conic-gradient(#94a3b8 100%, transparent 0); }
    .vdrpb-card.flash { outline:2px solid #3b82f6; outline-offset:2px; }
    .vdrpb-card.queued { opacity:.85; }
    .vdrpb-toprow { display:flex; gap:6px; align-self:flex-end; align-items:center; }
    .vdrpb-clear { display:none; font:600 11px 'Roboto',sans-serif; color:#9fb3c8; background:rgba(0,10,15,.85); border:none; padding:5px 8px; border-radius:8px; cursor:pointer; }
    .vdrpb-clear:hover { color:#fff; background:rgba(20,30,40,.95); }
    .vdrpb-card-head { display:flex; align-items:center; gap:9px; }
    .vdrpb-thumb { width:46px; height:46px; flex:none; border-radius:6px; background:rgba(255,255,255,.08); overflow:hidden; display:flex; align-items:center; justify-content:center; }
    .vdrpb-thumb img { width:100%; height:100%; object-fit:cover; }
    .vdrpb-titlewrap { flex:1; min-width:0; }
    .vdrpb-title { font-weight:600; font-size:13px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    .vdrpb-sub { font-size:11px; color:#9fb3c8; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    .vdrpb-icon { background:none; border:none; color:#9fb3c8; cursor:pointer; font-size:13px; padding:2px 5px; border-radius:4px; line-height:1; }
    .vdrpb-icon:hover { background:rgba(255,255,255,.1); color:#fff; }
    .vdrpb-cancel:hover { color:#ff6b6b; background:rgba(255,80,80,.12); }
    .vdrpb-ring { display:none; width:30px; height:30px; flex:none; border-radius:50%; background:conic-gradient(#3b82f6 calc(var(--pct,0)*1%), rgba(255,255,255,.15) 0); }
    .vdrpb-stepper { display:flex; gap:4px; }
    .vdrpb-step { flex:1; display:flex; flex-direction:column; align-items:center; gap:3px; position:relative; }
    .vdrpb-step:not(:last-child)::after { content:''; position:absolute; top:4px; left:calc(50% + 7px); right:calc(-50% + 7px); height:2px; background:rgba(255,255,255,.14); }
    .vdrpb-step.done::after { background:#22c55e; }
    .vdrpb-dot { width:9px; height:9px; border-radius:50%; background:rgba(255,255,255,.2); z-index:1; }
    .vdrpb-step.current .vdrpb-dot { background:#3b82f6; box-shadow:0 0 0 3px rgba(59,130,246,.3); }
    .vdrpb-step.done .vdrpb-dot { background:#22c55e; }
    .vdrpb-steplabel { font-size:9px; color:#8ea3af; }
    .vdrpb-step.current .vdrpb-steplabel { color:#dbeafe; }
    .vdrpb-status { font-size:12.5px; color:#dbeafe; white-space:pre-wrap; overflow-wrap:anywhere; }
    .vdrpb-barrow { display:flex; align-items:center; gap:8px; }
    .vdrpb-track { position:relative; flex:1; height:7px; background:rgba(255,255,255,.14); border-radius:5px; overflow:hidden; }
    .vdrpb-fill { position:absolute; left:0; top:0; bottom:0; width:0%; background:linear-gradient(90deg,#2563eb,#3b82f6); border-radius:5px; transition:width .25s ease; }
    .vdrpb-fill.indet { width:35% !important; animation:vdrpb-indeterminate 1.1s infinite linear; }
    .vdrpb-fill.busy { animation:vdrpb-shimmer 1.2s infinite; }
    .vdrpb-card.ok .vdrpb-fill { background:#22c55e; }
    .vdrpb-card.err .vdrpb-fill { background:#ef4444; }
    .vdrpb-pct { font-size:11px; font-variant-numeric:tabular-nums; color:#cfe0ee; min-width:34px; text-align:right; }
    .vdrpb-stats { display:flex; gap:8px; }
    .vdrpb-stat { flex:1; }
    .vdrpb-statlab { font-size:9px; text-transform:uppercase; letter-spacing:.05em; color:#7f95a5; }
    .vdrpb-statval { font-size:12px; font-variant-numeric:tabular-nums; color:#e8eef3; }
    .vdrpb-sizeline { font-size:11px; color:#9fb3c8; font-variant-numeric:tabular-nums; }
    .vdrpb-actions { display:flex; gap:8px; }
    .vdrpb-actions:empty { display:none; }
    .vdrpb-btn { flex:1; padding:6px 8px; border:1px solid rgba(255,255,255,.15); background:rgba(255,255,255,.06); color:#e8eef3; border-radius:5px; cursor:pointer; font-size:12px; }
    .vdrpb-btn:hover { background:rgba(255,255,255,.13); }
    .vdrpb-btn-primary { background:#2563eb; border-color:#2563eb; color:#fff; }
    .vdrpb-btn-primary:hover { background:#3b82f6; }
    .vdrpb-card.collapsed { flex-direction:row; align-items:center; gap:10px; }
    .vdrpb-card.collapsed > *:not(.vdrpb-card-head):not(.vdrpb-ring) { display:none; }
    .vdrpb-card.collapsed .vdrpb-card-head { flex:1; }
    .vdrpb-card.collapsed .vdrpb-sub { display:none; }
    .vdrpb-card.collapsed .vdrpb-ring { display:block; }
    @media (prefers-reduced-motion: reduce) { .vdrpb-fill, .vdrpb-fill.indet, .vdrpb-fill.busy { animation:none; transition:none; } }
    .vdrpb-update-strip { display:block; width:100%; box-sizing:border-box; border:none; cursor:pointer;
      font:600 12px 'Roboto',sans-serif; color:#fff; background:#2563eb; border-radius:6px;
      padding:5px 10px; text-align:center; white-space:nowrap; line-height:1.2; transition:background .2s; }
    .vdrpb-update-strip:hover { background:#1d4ed8; }
    .vdrpb-update-strip.busy { background:#475569; cursor:default; }
  `;
  if (!style.isConnected) (document.head || document.documentElement).appendChild(style);
};
injectStyles();

// Where floating UI must live to stay painted: inside the fullscreen element
// during ELEMENT fullscreen. When the root itself is fullscreen (YouTube's
// fullscreen button fullscreens documentElement so the page keeps scrolling),
// the whole document renders — use body as usual.
const uiHost = () => {
  const fs = document.fullscreenElement;
  return (fs && fs !== document.documentElement) ? fs : document.body;
};

const formatTime = time => {
  const minutes = Math.floor(time / 60);
  const seconds = Math.floor(time % 60);
  return `${minutes < 10 ? '0' + minutes : minutes}:${seconds < 10 ? '0' + seconds : seconds}`;
};
const formatTimeHMS = time => {
  const hours = Math.floor(time / 3600);
  const minutes = Math.floor((time % 3600) / 60);
  const seconds = Math.floor(time % 60);
  return `${hours < 10 ? '0' + hours : hours}:${minutes < 10 ? '0' + minutes : minutes}:${seconds < 10 ? '0' + seconds : seconds}`;
};

// Safely render a message that may contain "<br>" / "\n" and http(s) links,
// WITHOUT using innerHTML (the message can originate from the native host).
const renderMessageInto = (el, text) => {
  el.textContent = '';
  const normalized = String(text == null ? '' : text).replace(/<br\s*\/?>/gi, '\n');
  normalized.split('\n').forEach((line, i) => {
    if (i > 0) el.appendChild(document.createElement('br'));
    const urlRe = /(https?:\/\/[^\s]+)/g;
    let last = 0, m;
    while ((m = urlRe.exec(line)) !== null) {
      if (m.index > last) el.appendChild(document.createTextNode(line.slice(last, m.index)));
      const a = document.createElement('a');
      a.href = m[0]; a.textContent = m[0];
      a.target = '_blank'; a.rel = 'noopener noreferrer';
      a.style.color = '#93c5fd';
      el.appendChild(a);
      last = m.index + m[0].length;
    }
    if (last < line.length) el.appendChild(document.createTextNode(line.slice(last)));
  });
};

// Simple centered toast for short-lived messages.
const showNotification = (message, isSuccess = true, duration = 2500) => {
  document.querySelectorAll('.vdrpb-notification').forEach(n => n.remove());
  const notification = document.createElement('div');
  notification.className = 'vdrpb-notification' + (isSuccess ? '' : ' err');
  notification.setAttribute('role', isSuccess ? 'status' : 'alert');
  const iconEl = document.createElement('span');
  iconEl.className = 'vdrpb-notif-icon';
  iconEl.textContent = isSuccess ? '✓' : '!';
  const msgEl = document.createElement('div');
  renderMessageInto(msgEl, message);
  notification.append(iconEl, msgEl);
  if (duration > 0) {
    notification.style.animation = `vdrpb-fadeout 0.3s ${duration}ms forwards`;
    setTimeout(() => notification.remove(), duration + 350);
  }
  uiHost().appendChild(notification);   // body children are unpaintable in element fullscreen
  return notification;
};

// ---------------------------------------------------------------------------
// Live download UI — a bottom-right STACK of cards (one per download), each with
// video metadata + thumbnail, a monotone global bar, a stage stepper, elapsed/
// speed/ETA, a real Cancel, and Retry/Copy-error on failure. Draggable + a
// collapse-to-% pill. Fed by streamed {meta|progress|done} messages.
// ---------------------------------------------------------------------------
let vdrpbStack = null;

// Clamp the saved position to the CURRENT viewport (a smaller window/monitor
// could otherwise leave the stack — and its drag grip — fully off-screen).
const placeStack = stack => {
  const pos = settings.stackPos;
  const clampR = v => Math.max(4, Math.min(Math.max(4, window.innerWidth - 120), v));
  const clampB = v => Math.max(4, Math.min(Math.max(4, window.innerHeight - 40), v));
  stack.style.right = (pos && Number.isFinite(pos.right) ? clampR(pos.right) : 18) + 'px';
  stack.style.bottom = (pos && Number.isFinite(pos.bottom) ? clampB(pos.bottom) : 18) + 'px';
};

const fmtBytes = n => {
  if (!n || n <= 0) return null;
  const u = ['B', 'KB', 'MB', 'GB']; let i = 0, v = n;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return (i >= 2 ? v.toFixed(1) : Math.round(v)) + ' ' + u[i];
};
const fmtDuration = secs => {
  secs = Math.floor(secs || 0);
  const h = Math.floor(secs / 3600), m = Math.floor((secs % 3600) / 60), s = secs % 60;
  const p = x => String(x).padStart(2, '0');
  return h > 0 ? `${h}:${p(m)}:${p(s)}` : `${m}:${p(s)}`;
};

const getStack = () => {
  // Re-attach instead of rebuilding when the site detached our node (Facebook /
  // Instagram remount body children): live cards keep their timers and Cancel.
  if (vdrpbStack) {
    if (!vdrpbStack.isConnected) uiHost().appendChild(vdrpbStack);
    return vdrpbStack;
  }
  const stack = document.createElement('div');
  stack.className = 'vdrpb-stack';
  stack.setAttribute('aria-label', 'Downloads');
  placeStack(stack);

  const grip = document.createElement('div');
  grip.className = 'vdrpb-grip';
  grip.textContent = '⠿ Downloads';
  const clearBtn = document.createElement('button');
  clearBtn.className = 'vdrpb-clear';
  clearBtn.textContent = '✕ finished';
  clearBtn.title = 'Close finished downloads';
  const topRow = document.createElement('div');
  topRow.className = 'vdrpb-toprow';
  topRow.append(clearBtn, grip);
  const cards = document.createElement('div');
  cards.className = 'vdrpb-cards';
  stack.append(topRow, cards);
  stack._cards = cards;

  // Grip shows the live count; the clear button appears once something finished.
  stack._refreshGrip = () => {
    const total = cards.children.length;
    const active = cards.querySelectorAll('.vdrpb-card:not(.ok):not(.err):not(.cxl)').length;
    grip.textContent = '⠿ Downloads' + (total ? ` (${active ? active + ' active' : total + ' finished'})` : '');
    clearBtn.style.display = (total - active) > 0 ? 'block' : 'none';
  };
  clearBtn.addEventListener('click', e => {
    e.stopPropagation();
    cards.querySelectorAll('.vdrpb-card.ok, .vdrpb-card.err, .vdrpb-card.cxl').forEach(c => { if (c._close) c._close(); else c.remove(); });
    stack._refreshGrip();
    if (cards.children.length === 0 && vdrpbStack === stack) { stack.remove(); vdrpbStack = null; }
  });

  let dragging = false, sx = 0, sy = 0, sr = 0, sb = 0;
  grip.addEventListener('pointerdown', e => {
    dragging = true; sx = e.clientX; sy = e.clientY;
    const r = stack.getBoundingClientRect();
    sr = window.innerWidth - r.right; sb = window.innerHeight - r.bottom;
    try { grip.setPointerCapture(e.pointerId); } catch {}
    e.preventDefault(); e.stopPropagation();
  });
  grip.addEventListener('pointermove', e => {
    if (!dragging) return;
    stack.style.right = Math.max(4, Math.min(window.innerWidth - 120, sr - (e.clientX - sx))) + 'px';
    stack.style.bottom = Math.max(4, Math.min(window.innerHeight - 40, sb - (e.clientY - sy))) + 'px';
    e.preventDefault(); e.stopPropagation();
  });
  const endDrag = () => {
    if (!dragging) return; dragging = false;
    saveSetting('stackPos', { right: parseInt(stack.style.right), bottom: parseInt(stack.style.bottom) });
  };
  grip.addEventListener('pointerup', endDrag);
  grip.addEventListener('pointercancel', endDrag);

  uiHost().appendChild(stack);
  vdrpbStack = stack;
  return stack;
};

const STEPS = ['Analysis', 'Download', 'Processing', 'Done'];
const stageToStep = stage =>
  stage === 'download' ? 1 : stage === 'postprocess' ? 2 : stage === 'finalize' ? 3 : 0;

const MIME_BY_EXT = {
  mp4: 'video/mp4', webm: 'video/webm', mkv: 'video/x-matroska', mov: 'video/quicktime', flv: 'video/x-flv', '3gp': 'video/3gpp',
  mp3: 'audio/mpeg', m4a: 'audio/mp4', aac: 'audio/aac', opus: 'audio/ogg', ogg: 'audio/ogg', wav: 'audio/wav',
  gif: 'image/gif', webp: 'image/webp'
};
const fileNameOf = path => String(path || '').split(/[\\/]/).pop();
const mimeOf = path => MIME_BY_EXT[(fileNameOf(path).split('.').pop() || '').toLowerCase()] || 'application/octet-stream';

const copyText = txt => {
  const fallbackCopy = () => {
    const ta = document.createElement('textarea'); ta.value = txt;
    document.body.appendChild(ta); ta.select();
    let ok = false; try { ok = document.execCommand('copy'); } catch {}
    ta.remove(); return ok;
  };
  return navigator.clipboard && navigator.clipboard.writeText
    ? navigator.clipboard.writeText(txt).then(() => true, fallbackCopy)
    : Promise.resolve(fallbackCopy());
};

// Card for one download job. Callbacks set by the owner: onCancel(), onRetry(),
// onDismiss() (closed by the user), onLocalRemove() (auto-dismissed in this tab),
// onServe(cb) (cb receives { url } or { error } for dragging the file out).
const createDownloadCard = (sourceUrl, variant, startedAt) => {
  const stack = getStack();
  const card = document.createElement('div');
  card.className = 'vdrpb-card';

  const header = document.createElement('div'); header.className = 'vdrpb-card-head';
  const thumb = document.createElement('div'); thumb.className = 'vdrpb-thumb';
  // Placeholder shown until (or instead of) the thumbnail — a 403'd CDN image
  // must not leave an anonymous grey box.
  thumb.textContent = '🎞'; thumb.style.color = '#7f95a5'; thumb.style.fontSize = '18px';
  const titleWrap = document.createElement('div'); titleWrap.className = 'vdrpb-titlewrap';
  // The title links back to the source video ("which card is this?").
  const title = document.createElement(sourceUrl ? 'a' : 'div'); title.className = 'vdrpb-title';
  title.textContent = variant ? `Downloading (${variant})…` : 'Downloading…';
  if (sourceUrl) {
    title.href = sourceUrl; title.target = '_blank'; title.rel = 'noopener noreferrer'; title.title = sourceUrl;
    Object.assign(title.style, { color: 'inherit', textDecoration: 'none', display: 'block' });
    title.addEventListener('mouseenter', () => title.style.textDecoration = 'underline');
    title.addEventListener('mouseleave', () => title.style.textDecoration = 'none');
  }
  const sub = document.createElement('div'); sub.className = 'vdrpb-sub';
  if (variant) sub.textContent = variant;
  titleWrap.append(title, sub);
  const collapseBtn = document.createElement('button'); collapseBtn.className = 'vdrpb-icon'; collapseBtn.textContent = '▁'; collapseBtn.title = 'Collapse'; collapseBtn.setAttribute('aria-label', 'Collapse');
  const cancelBtn = document.createElement('button'); cancelBtn.className = 'vdrpb-icon vdrpb-cancel'; cancelBtn.textContent = '✕'; cancelBtn.title = 'Cancel'; cancelBtn.setAttribute('aria-label', 'Cancel download');
  header.append(thumb, titleWrap, collapseBtn, cancelBtn);

  const ring = document.createElement('div'); ring.className = 'vdrpb-ring'; ring.style.setProperty('--pct', '0');

  const stepper = document.createElement('div'); stepper.className = 'vdrpb-stepper';
  const stepEls = STEPS.map(label => {
    const st = document.createElement('div'); st.className = 'vdrpb-step';
    const dot = document.createElement('span'); dot.className = 'vdrpb-dot';
    const lb = document.createElement('span'); lb.className = 'vdrpb-steplabel'; lb.textContent = label;
    st.append(dot, lb); stepper.appendChild(st); return st;
  });

  const status = document.createElement('div'); status.className = 'vdrpb-status'; status.textContent = 'Preparing…';
  status.setAttribute('role', 'status'); status.setAttribute('aria-live', 'polite');
  const barRow = document.createElement('div'); barRow.className = 'vdrpb-barrow';
  const track = document.createElement('div'); track.className = 'vdrpb-track';
  track.setAttribute('role', 'progressbar'); track.setAttribute('aria-valuemin', '0'); track.setAttribute('aria-valuemax', '100');
  const fill = document.createElement('div'); fill.className = 'vdrpb-fill';
  track.appendChild(fill);
  const pctText = document.createElement('div'); pctText.className = 'vdrpb-pct';
  barRow.append(track, pctText);

  const stats = document.createElement('div'); stats.className = 'vdrpb-stats';
  const mkStat = lab => {
    const c = document.createElement('div'); c.className = 'vdrpb-stat';
    const l = document.createElement('div'); l.className = 'vdrpb-statlab'; l.textContent = lab;
    const v = document.createElement('div'); v.className = 'vdrpb-statval'; v.textContent = '—';
    c.append(l, v); return { c, v };
  };
  const sEl = mkStat('Elapsed'), spEl = mkStat('Speed'), etEl = mkStat('ETA');
  stats.append(sEl.c, spEl.c, etEl.c);
  const sizeLine = document.createElement('div'); sizeLine.className = 'vdrpb-sizeline';
  const actions = document.createElement('div'); actions.className = 'vdrpb-actions';

  card.append(header, ring, stepper, status, barRow, stats, sizeLine, actions);
  stack._cards.appendChild(card);
  if (stack._refreshGrip) stack._refreshGrip();

  let finished = false, curPct = 0, hadPct = false, queued = false, metaKey = '', removed = false;
  let collapsed = !!settings.collapsedCards;
  if (collapsed) { card.classList.add('collapsed'); collapseBtn.textContent = '▢'; collapseBtn.title = 'Expand'; }
  const startTime = Number(startedAt) || Date.now();
  const tickElapsed = () => { if (!finished) sEl.v.textContent = fmtDuration((Date.now() - startTime) / 1000); };
  tickElapsed();
  let elapsedTimer = setInterval(tickElapsed, 1000);

  const setStep = idx => stepEls.forEach((st, i) => { st.classList.toggle('done', i < idx); st.classList.toggle('current', i === idx); });
  const setPct = (pct, indeterminate) => {
    if (typeof pct === 'number') {
      hadPct = true; curPct = Math.max(curPct, Math.max(0, Math.min(100, pct)));
      fill.classList.remove('indet', 'busy'); fill.style.width = curPct + '%';
      pctText.textContent = curPct + '%'; ring.style.setProperty('--pct', curPct);
      track.setAttribute('aria-valuenow', curPct);
    } else if (indeterminate && !hadPct) {
      fill.classList.add('indet'); pctText.textContent = '';
      track.removeAttribute('aria-valuenow');
    } else if (hadPct) {
      fill.classList.add('busy');
    }
  };
  setPct(null, true);

  let dismissTimer = null;
  const remove = () => {
    if (removed) return;
    removed = true;
    clearInterval(elapsedTimer);
    if (dismissTimer) { clearTimeout(dismissTimer); dismissTimer = null; }
    card.remove();
    if (stack._refreshGrip) stack._refreshGrip();
    // Guard with vdrpbStack === stack: a stale timeout on an already-detached card
    // must NOT null out the global that now points at a newer, live stack.
    if (stack._cards.children.length === 0 && vdrpbStack === stack) { stack.remove(); vdrpbStack = null; }
  };
  // Closed by the user: gone from every tab.
  const close = () => { remove(); if (controller.onDismiss) controller.onDismiss(); };
  card._close = close;
  // Hovering pauses auto-dismiss; leaving re-arms it (capped at 8s) so a
  // grazing cursor pass never eats a long error-reading window. A card that is
  // already under the cursor when it finishes waits for the pointer to leave.
  // Auto-dismiss only hides the card in this tab.
  const dismissAfter = ms => {
    const rearmMs = Math.min(ms, 8000);
    const arm = t => { if (dismissTimer) clearTimeout(dismissTimer); dismissTimer = setTimeout(() => {
      dismissTimer = null;
      if (card.matches(':hover')) return;
      remove();
      if (controller.onLocalRemove) controller.onLocalRemove();
    }, t); };
    if (!card.matches(':hover')) arm(ms);
    card.addEventListener('mouseenter', () => { if (dismissTimer) { clearTimeout(dismissTimer); dismissTimer = null; } });
    card.addEventListener('mouseleave', () => arm(rearmMs));
  };

  collapseBtn.addEventListener('click', e => {
    e.stopPropagation(); collapsed = !collapsed;
    card.classList.toggle('collapsed', collapsed);
    collapseBtn.textContent = collapsed ? '▢' : '▁';
    collapseBtn.title = collapsed ? 'Expand' : 'Collapse';
    collapseBtn.setAttribute('aria-label', collapseBtn.title);
    saveSetting('collapsedCards', collapsed);
  });
  // Terminal states must never stay hidden in the collapsed pill (error text,
  // Show/Retry would be invisible) — auto-expand, and turn the cancel
  // button into a plain close.
  const expandIfCollapsed = () => {
    if (!collapsed) return;
    collapsed = false; card.classList.remove('collapsed');
    collapseBtn.textContent = '▁'; collapseBtn.title = 'Collapse'; collapseBtn.setAttribute('aria-label', 'Collapse');
  };
  const makeCloseButton = () => {
    cancelBtn.classList.remove('vdrpb-cancel');
    cancelBtn.title = 'Close'; cancelBtn.setAttribute('aria-label', 'Close');
  };
  const flashLabel = (b, text, label) => {
    b.textContent = text;
    setTimeout(() => { if (b.isConnected) b.textContent = label; }, 2000);
  };

  // One-shot request to the native host through background.js.
  const mkHostButton = (label, type, payload, primary, onOk) => {
    const b = document.createElement('button'); b.textContent = label; b.className = 'vdrpb-btn' + (primary ? ' vdrpb-btn-primary' : '');
    b.addEventListener('click', e => {
      e.stopPropagation();
      try {
        chrome.runtime.sendMessage({ type, ...payload }, r => {
          const ok = !chrome.runtime.lastError && r && r.success;
          if (ok && onOk) onOk(b);
          else if (!ok) flashLabel(b, 'Failed', label);
        });
      } catch {
        // Extension reloaded under a still-open card: the context is invalidated
        // and sendMessage throws synchronously.
        flashLabel(b, 'Failed', label);
      }
    });
    return b;
  };

  // Drag the finished file out of the browser (desktop, Explorer, other apps): the
  // file is served on 127.0.0.1 by the native host and handed over as DownloadURL.
  const mkDragButton = path => {
    const label = '⿻ Drag';
    const b = document.createElement('button'); b.textContent = label; b.className = 'vdrpb-btn';
    b.draggable = true;
    b.title = 'Drag the file to a folder, the desktop or another application';
    b.style.cursor = 'grab';
    let url = '', pending = false;
    const prepare = () => {
      if (url || pending || !controller.onServe) return;
      pending = true;
      controller.onServe(r => {
        pending = false;
        if (r && r.url) url = r.url;
        else if (r && r.error) b.title = r.error;
      });
    };
    ['pointerenter', 'pointerdown', 'focus'].forEach(t => b.addEventListener(t, prepare));
    b.addEventListener('dragstart', e => {
      e.stopPropagation();
      if (!url) { e.preventDefault(); prepare(); flashLabel(b, 'Preparing… drag again', label); return; }
      e.dataTransfer.setData('DownloadURL', `${mimeOf(path)}:${fileNameOf(path)}:${url}`);
      e.dataTransfer.setData('text/plain', path);
      e.dataTransfer.effectAllowed = 'copy';
    });
    b.addEventListener('click', e => { e.stopPropagation(); prepare(); flashLabel(b, 'Drag me to a folder', label); });
    return b;
  };

  const controller = {
    card, get finished() { return finished; }, onCancel: null, onRetry: null, onDismiss: null, onLocalRemove: null, onServe: null,
    remove,
    setQueued(q) {
      if (finished || q === queued) return;
      queued = q;
      status.textContent = q ? 'Queued…' : 'Preparing…';
      if (q) {
        // A queued card must not ANIMATE like a working one.
        fill.classList.remove('indet', 'busy'); fill.style.width = '0%';
        pctText.textContent = '⏸';
        card.classList.add('queued');
      } else {
        card.classList.remove('queued');
        pctText.textContent = '';
        setPct(null, true);
      }
    },
    setMeta(m) {
      const key = [m.title, m.uploader, m.duration, m.thumbnail].join('|');
      if (key === metaKey) return;
      const hadThumb = metaKey.split('|')[3] || '';
      metaKey = key;
      if (m.title) {
        title.textContent = m.title;
        title.title = sourceUrl ? m.title + '\n' + sourceUrl : m.title;
      }
      const bits = [];
      if (m.uploader) bits.push(m.uploader);
      if (m.duration) bits.push(fmtDuration(m.duration));
      if (variant) bits.push(variant);   // two variants of the same video must stay tellable apart
      sub.textContent = bits.join(' · ');
      if (m.thumbnail && m.thumbnail !== hadThumb) {
        const img = new Image();
        img.referrerPolicy = 'no-referrer';
        img.onload = () => { thumb.textContent = ''; thumb.appendChild(img); };
        img.onerror = () => {};   // keep the placeholder glyph
        img.src = m.thumbnail;
      }
    },
    update(msg) {
      if (finished) return;
      status.textContent = msg.message || '…';
      setStep(stageToStep(msg.stage));
      if (typeof msg.percent === 'number') setPct(msg.percent);
      else setPct(null, msg.stage === 'prepare' || msg.stage === 'update');
      if (msg.stage && msg.stage !== 'download') {
        // Post-processing sends no speed/eta: showing the last download speed
        // would read as a live transfer.
        spEl.v.textContent = '—'; etEl.v.textContent = '—';
      } else {
        if (msg.speed && !/unknown/i.test(msg.speed)) spEl.v.textContent = msg.speed;
        if (msg.eta && !/^(NA|Unknown|--)/i.test(msg.eta)) etEl.v.textContent = msg.eta;
      }
      const dl = fmtBytes(msg.downloaded), tot = fmtBytes(msg.total);
      sizeLine.textContent = (dl && tot) ? (dl + ' / ' + tot) : '';
    },
    success(job) {
      if (finished) return; finished = true; clearInterval(elapsedTimer);
      expandIfCollapsed();
      card.classList.add('ok'); card.classList.remove('queued'); makeCloseButton();
      setStep(4); setPct(100);
      const paths = Array.isArray(job.finalPaths) && job.finalPaths.length ? job.finalPaths : (job.finalPath ? [job.finalPath] : []);
      const size = fmtBytes(job.size);
      status.textContent = (job.message || 'Done.') + (size ? ' · ' + size : '');
      stats.style.display = 'none'; sizeLine.textContent = '';
      if (paths.length) {
        const file = paths[0];
        if (paths.length > 1) sizeLine.textContent = `${paths.length} files — Show, Copy and Drag use the first one`;
        actions.append(
          mkDragButton(file),
          mkHostButton('🗁 Show', 'SHOW', { finalPath: file }, true, () => close()),
          mkHostButton('⧉ Copy', 'COPY', { finalPath: file }, false, b => { b.textContent = 'Copied'; b.disabled = true; })
        );
      }
      if (stack._refreshGrip) stack._refreshGrip();
      dismissAfter(20000);
    },
    fail(message, canRetry, o = {}) {
      if (finished) return; finished = true; clearInterval(elapsedTimer);
      expandIfCollapsed();
      // A deliberate cancel is not a malfunction: neutral grey, no error-copy
      // button, quick dismiss.
      card.classList.add(o.cancelled ? 'cxl' : 'err'); makeCloseButton();
      card.classList.remove('queued');
      fill.classList.remove('indet', 'busy'); fill.style.width = '100%';
      pctText.textContent = '';   // a stale "47%" next to a full red bar reads wrong
      ring.style.setProperty('--pct', 100);
      setStep(-1);
      renderMessageInto(status, message || 'An error occurred.');
      stats.style.display = 'none'; sizeLine.textContent = ''; actions.textContent = '';
      if (canRetry && controller.onRetry) {
        const rb = document.createElement('button'); rb.textContent = '↻ Retry'; rb.className = 'vdrpb-btn vdrpb-btn-primary';
        rb.addEventListener('click', e => { e.stopPropagation(); const retry = controller.onRetry; remove(); retry(); });
        actions.appendChild(rb);
      }
      if (!o.cancelled) {
        const cb = document.createElement('button'); cb.textContent = "Copy error"; cb.className = 'vdrpb-btn';
        cb.addEventListener('click', e => {
          e.stopPropagation();
          const txt = [message || '', o.detail || '', o.logPath ? 'Log: ' + o.logPath : ''].filter(Boolean).join('\n');
          copyText(txt).then(ok => { cb.textContent = ok ? 'Copied' : 'Failed'; });
        });
        actions.appendChild(cb);
        if (o.logPath) actions.appendChild(mkHostButton('Open log', 'OPENLOG', { path: o.logPath }, false, null));
      }
      if (stack._refreshGrip) stack._refreshGrip();
      dismissAfter(o.cancelled ? 6000 : 30000);
    }
  };
  cancelBtn.addEventListener('click', e => {
    e.stopPropagation();
    if (finished) close();                        // repurposed as "close" on terminal cards
    else if (controller.onCancel) { status.textContent = 'Cancelling…'; controller.onCancel(); }
  });
  return controller;
};

// ---------------------------------------------------------------------------
// HARD VOLUME LOCK — enforce the user's chosen volume against the site.
// First layer: volume-lock.js (page world, document_start) rewrites site writes
// to video.volume synchronously and keeps the site's native volume control in
// sync both ways. This layer is the fallback and handles the extension's own
// slider.
// Enforcement is GLOBAL and independent of the control bar's lifetime:
// document-level capture listeners (media events don't bubble but do cross the
// capture phase) clamp .volume on every video the instant the site touches it
// or starts playing one, so the memorized volume applies even while no control
// bar exists (Shorts scrolling, miniplayer, off-center videos).
// The clamp NEVER touches .muted: unmuting is reserved to an explicit gesture
// on the extension's own slider, so site-muted previews stay silent and the
// site's own mute button keeps working.
// ---------------------------------------------------------------------------
const VOL_KEY = "extension_video_volume"; // normalized [0..1], sqrt mapping
const clamp01 = v => {
  const n = typeof v === "number" ? v : parseFloat(v);
  return Number.isFinite(n) ? Math.max(0, Math.min(1, n)) : 1;
};
let volLockNorm = null;
try {
  const stored = localStorage.getItem(VOL_KEY);
  if (stored !== null) { const n = parseFloat(stored); if (Number.isFinite(n)) volLockNorm = clamp01(n); }
} catch {}
const normToActual = n => Math.pow(clamp01(n), 2);
const lockVolume = norm => {
  volLockNorm = clamp01(norm);
  try { localStorage.setItem(VOL_KEY, String(volLockNorm)); } catch {}
};
// Volume-only clamp. Idempotence (the ±0.001 no-op) is what terminates the
// volumechange echo loop: our own write re-fires the event, the second pass
// matches the epsilon and writes nothing. Do NOT add non-idempotent work here.
const applyVolumeClamp = video => {
  if (!video || volLockNorm === null) return;
  const want = normToActual(volLockNorm);
  try { if (Math.abs((video.volume || 0) - want) > 0.001) video.volume = want; } catch {}
};
// Explicit user gesture on the extension slider: the only place allowed to
// change .muted (slider > 0 unmutes THIS video, slider at 0 mutes it).
const applyUserVolume = video => {
  if (!video || volLockNorm === null) return;
  const want = normToActual(volLockNorm);
  try {
    if (want <= 0) { if (!video.muted) video.muted = true; }
    else if (video.muted) video.muted = false;
  } catch {}
  applyVolumeClamp(video);
};
const sweepVolumes = () => { if (volLockNorm !== null) document.querySelectorAll('video').forEach(applyVolumeClamp); };
['volumechange', 'play', 'loadstart'].forEach(type =>
  document.addEventListener(type, e => {
    const el = e.target;
    if (el && el.tagName === 'VIDEO') applyVolumeClamp(el);
  }, { capture: true, signal: lifetime.signal }));
sweepVolumes();
document.addEventListener('visibilitychange', () => { if (!document.hidden) sweepVolumes(); }, LIVE);

// ---------------------------------------------------------------------------
// Control bar positioning
// ---------------------------------------------------------------------------
const isFullBarFor = video =>
  (video._downloadUrl && video._downloadUrl.includes('facebook.com/reel/')) ||
  /^https:\/\/(?:[^\/]+\.)?facebook\.com\/watch\/?\?v=[^\/&]+/.test(window.location.href) ||
  /^https:\/\/(?:[^\/]+\.)?youtube\.com\/shorts\/[^\/]+/.test(window.location.href) ||
  ["instagram", "tiktok"].includes(current_website);

const updateControlBarPosition = (video, controlBar) => {
  const rect = video.getBoundingClientRect();
  if (rect.width === 0 && rect.height === 0) return;   // detached/hidden video: keep the last position
  // Bar size is cached by a ResizeObserver (createControlBar) so the 200ms tick
  // never forces a synchronous layout with an offsetHeight read after a write.
  const barH = controlBar._h || controlBar.offsetHeight;
  let barW = controlBar._w || controlBar.offsetWidth;
  // The full bar follows the video's width (long progress track on wide players).
  if (controlBar._isFullBar) {
    barW = Math.round(Math.min(640, Math.max(340, rect.width - 40)));
    const ws = barW + 'px';
    if (controlBar.style.width !== ws) controlBar.style.width = ws;
  }
  // Inside a fullscreen ELEMENT the containing block is the (position:fixed)
  // fullscreenElement anchored at the viewport origin — do NOT add document
  // scroll offsets there, or the bar lands scrollY px below the screen. The UA
  // fixed-position rule does NOT apply when the root itself is fullscreen
  // (YouTube fullscreens documentElement to keep the page scrollable), so
  // scroll compensation must stay in that case.
  const fsEl = document.fullscreenElement;
  const inFs = fsEl && fsEl !== document.documentElement && fsEl.contains(controlBar);
  const offX = inFs ? 0 : window.scrollX;
  const offY = inFs ? 0 : window.scrollY;
  // TikTok draws its own control row (volume, "…") across the top of the video:
  // the bar sits below it.
  const siteOffset = current_website === 'tiktok' ? 64 : 0;
  let newTop, newLeft;
  if (isFullBarFor(video)) {
    newTop = `${offY + rect.top - barH + 90 + siteOffset}px`;
    newLeft = `${offX + rect.left + (rect.width / 2) - (barW / 2)}px`;
  } else {
    newTop = `${offY + rect.top + 60 + siteOffset}px`;
    newLeft = `${offX + rect.left + 20}px`;
  }
  if (controlBar.style.top !== newTop || controlBar.style.left !== newLeft) {
    controlBar.style.top = newTop;
    controlBar.style.left = newLeft;
  }
};

// ---------------------------------------------------------------------------
// Downloads run in background.js, so they keep going when this tab closes and
// are capped at 3 across the browser. This tab mirrors the job list through a
// "vdrpb-ui" port: one card per job.
// ---------------------------------------------------------------------------
const cardsById = new Map();         // job id -> card controller
const hiddenJobs = new Set();        // job ids whose card this tab closed or auto-dismissed
const serveWaiters = new Map();      // job id -> callbacks waiting for a drag URL
const CARD_RECENT_MS = 20000;        // a job that finished before this tab saw it is shown this long
let uiPort = null;
let uiRetryTimer = 0;

const extensionAlive = () => { try { return !!chrome.runtime.id; } catch { return false; } };
const isTerminalStatus = s => s === 'done' || s === 'error' || s === 'cancelled';

const renderJob = (card, job) => {
  if (job.title || job.thumbnail || job.uploader) card.setMeta(job);
  if (job.status === 'queued') card.setQueued(true);
  else if (job.status === 'running') { card.setQueued(false); if (job.stage) card.update(job); }
  else if (job.status === 'done') card.success(job);
  else if (job.status === 'error') card.fail(job.message || 'Download failed.', true, { detail: job.detail, logPath: job.logPath });
  else if (job.status === 'cancelled') card.fail(job.message || 'Download cancelled.', true, { cancelled: true });
};

const syncJob = job => {
  if (!job || !job.id || hiddenJobs.has(job.id)) return;
  let card = cardsById.get(job.id);
  if (!card) {
    if (isTerminalStatus(job.status) && Date.now() - (job.finishedAt || 0) > CARD_RECENT_MS) return;
    const id = job.id;
    card = createDownloadCard(job.url, job.variant, job.startedAt);
    card.onCancel = () => sendUi({ type: 'cancel', id });
    card.onRetry = () => { forgetCard(id); sendUi({ type: 'retry', id }); };
    card.onDismiss = () => { forgetCard(id); sendUi({ type: 'dismiss', id }); };
    card.onLocalRemove = () => forgetCard(id);
    card.onServe = cb => {
      const list = serveWaiters.get(id) || [];
      list.push(cb);
      serveWaiters.set(id, list);
      if (list.length === 1 && !sendUi({ type: 'serve', id })) { serveWaiters.delete(id); cb({ error: 'Extension unavailable' }); }
    };
    cardsById.set(id, card);
  }
  renderJob(card, job);
};
const forgetCard = id => { hiddenJobs.add(id); cardsById.delete(id); };
const dropCard = id => {
  const card = cardsById.get(id);
  if (card) card.remove();
  cardsById.delete(id);
};
const flashCard = id => {
  const card = cardsById.get(id);
  if (!card) return;
  card.card.scrollIntoView({ block: 'nearest' });
  card.card.classList.add('flash');
  setTimeout(() => card.card.classList.remove('flash'), 1200);
};

const onUiMessage = msg => {
  if (!msg || typeof msg !== 'object') return;
  switch (msg.type) {
    case 'list': {
      const ids = new Set();
      for (const job of msg.jobs || []) { ids.add(job.id); syncJob(job); }
      for (const id of [...cardsById.keys()]) if (!ids.has(id)) dropCard(id);
      break;
    }
    case 'job':
      syncJob(msg.job);
      break;
    case 'removed':
      dropCard(msg.id);
      break;
    case 'counts':
      activeDownloadCount = Number(msg.active) || 0;
      refreshUpdateButtons();
      break;
    case 'accepted': {
      const card = cardsById.get(msg.id);
      if (card) card.card.scrollIntoView({ block: 'nearest' });
      break;
    }
    case 'dup':
      flashCard(msg.id);
      break;
    case 'rejected':
      showNotification(msg.message || 'Link not supported for download', false, 2500);
      break;
    case 'serve': {
      const list = serveWaiters.get(msg.id) || [];
      serveWaiters.delete(msg.id);
      list.forEach(cb => { try { cb(msg); } catch {} });
      break;
    }
  }
};

const connectUi = () => {
  if (uiPort) return uiPort;
  if (!extensionAlive()) return null;
  try {
    uiPort = chrome.runtime.connect({ name: 'vdrpb-ui' });
  } catch {
    uiPort = null;
    return null;
  }
  uiPort.onMessage.addListener(onUiMessage);
  uiPort.onDisconnect.addListener(() => {
    void chrome.runtime.lastError;
    uiPort = null;
    for (const [id, list] of serveWaiters) list.forEach(cb => { try { cb({ id, error: 'Extension restarted' }); } catch {} });
    serveWaiters.clear();
    // The worker stops when no download runs; reconnect right away only when a
    // card here is still in progress (anything else reconnects on demand).
    const live = [...cardsById.values()].some(c => !c.finished);
    if (live && !uiRetryTimer) uiRetryTimer = setTimeout(() => { uiRetryTimer = 0; connectUi(); }, 1000);
  });
  try { uiPort.postMessage({ type: 'hello' }); } catch {}
  return uiPort;
};
const sendUi = msg => {
  const p = connectUi();
  if (!p) return false;
  try { p.postMessage(msg); return true; } catch { uiPort = null; return false; }
};

// background.js publishes the number of running/queued downloads: a tab that is
// not connected reconnects as soon as a download starts elsewhere.
try {
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== 'local' || !changes.downloadsActive) return;
    const v = changes.downloadsActive.newValue;
    const n = v && Number(v.count) || 0;
    activeDownloadCount = n;
    refreshUpdateButtons();
    if (n > 0 && !uiPort) connectUi();
  });
} catch {}
connectUi();

// URL + options -> a job in background.js.
const startDownload = opts => {
  const targetUrl = opts.targetUrl || window.location.href;
  // Same rule as background.js and the host's Test-SafeUrl: a bad link fails HERE;
  // the domain boundary is anchored (facebook.com.evil.example must not pass).
  const supported =
    /^https:\/\/(?:\w+\.)*(?:instagram\.com|facebook\.com|x\.com|tiktok\.com|youtube\.com)(?:[\/?#]|$)/.test(targetUrl);
  if (!supported || targetUrl.length >= 2048 || /[\s"'<>|^`\\]/.test(targetUrl)) {
    showNotification("Link not supported for download", false, 2500);
    return;
  }
  const request = {
    url: targetUrl,
    mp3: !!opts.mp3,
    isGIF: !!opts.isGIF,
    cut: opts.cut || '',
    convertMP4: !!opts.convertMP4,
    preciseCut: opts.preciseCut !== false,
    preset: opts.preset || 'best',
    bipAtEnd: !!opts.bipAtEnd,
    copyAtEnd: !!opts.copyAtEnd,
    keepConsoleOpen: !!opts.keepConsoleOpen,
    playlistItem: opts.playlistItem || null,
    mediaDuration: Number(opts.mediaDuration) || 0,
    downloadDir: opts.downloadDir || '',
    subfolder: opts.subfolder || '',
    site: opts.site || current_website
  };
  if (!sendUi({ type: 'start', request, ref: Date.now().toString(36) })) {
    showNotification("Extension unavailable. Reload the page.", false, 3000);
  }
};


// ---------------------------------------------------------------------------
// Download menu (buttons + CUT + options)
// ---------------------------------------------------------------------------
// "SS", "MM:SS" or "HH:MM:SS", with an optional fraction on the last field.
const parseClock = val => {
  const t = String(val == null ? '' : val).trim();
  if (!/^\d+(:\d+){0,2}(\.\d+)?$/.test(t)) return null;
  const [whole, frac] = t.split('.');
  const nums = whole.split(':').map(Number);
  if (nums.length >= 2 && nums[nums.length - 1] > 59) return null;   // seconds field
  if (nums.length === 3 && nums[1] > 59) return null;                  // minutes field
  let s = 0;
  for (const n of nums) s = s * 60 + n;
  return frac ? s + parseFloat('0.' + frac) : s;
};
// HH:MM:SS, plus tenths when the value is not a whole second.
const formatClock = sec => {
  const r = Math.round(Math.max(0, Number(sec) || 0) * 10) / 10;
  const whole = Math.floor(r);
  const tenths = Math.round((r - whole) * 10);
  return formatTimeHMS(whole) + (tenths ? '.' + tenths : '');
};
const cutSeconds = s => String(Math.round(s * 1000) / 1000);

const PRESET_LABELS = { best: 'Best', '1080': '1080p', '720': '720p', size25: '≤ 25 MB' };
const SITE_FOLDERS = { youtube: 'YouTube', facebook: 'Facebook', instagram: 'Instagram', tiktok: 'TikTok', twitter: 'X' };

// Line icons (24px grid, drawn with currentColor).
const SVG_NS = 'http://www.w3.org/2000/svg';
const ICONS = {
  play:     [{ d: 'M8 5.14v13.72a1 1 0 0 0 1.52.85l10.6-6.86a1 1 0 0 0 0-1.7L9.52 4.29A1 1 0 0 0 8 5.14z', fill: true }],
  pause:    [{ d: 'M7 5h3.2v14H7zM13.8 5H17v14h-3.8z', fill: true }],
  download: [{ d: 'M12 4v11M7.5 10.5 12 15l4.5-4.5M5 19.5h14' }],
  video:    [{ d: 'M4 6.5h10a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1v-9a1 1 0 0 1 1-1zM15 10.5l5.5-3v9l-5.5-3' }],
  music:    [{ d: 'M9 17.5V6l10-2v11.5' }, { d: 'M9 17.5a2.5 2.5 0 1 1-5 0 2.5 2.5 0 0 1 5 0zM19 15.5a2.5 2.5 0 1 1-5 0 2.5 2.5 0 0 1 5 0z' }],
  cut:      [{ d: 'M6 9a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM6 21a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM20 4 8.1 15.9M14.5 14.5 20 20M8.1 8.1 12 12' }],
  sliders:  [{ d: 'M4 7h9M17 7h3M4 17h3M11 17h9M15 5v4M9 15v4' }],
  chevron:  [{ d: 'm6 9 6 6 6-6' }],
  folder:   [{ d: 'M3.5 7.5a2 2 0 0 1 2-2h3.8l2 2h7.2a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z' }],
  volume:   [{ d: 'M11 5 6.5 9H3.5v6h3L11 19z' }, { d: 'M15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13' }],
  volumeLow:[{ d: 'M11 5 6.5 9H3.5v6h3L11 19z' }, { d: 'M15.5 8.5a5 5 0 0 1 0 7' }],
  mute:     [{ d: 'M11 5 6.5 9H3.5v6h3L11 19z' }, { d: 'm16 9.5 5 5M21 9.5l-5 5' }]
};
const makeIcon = name => {
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('aria-hidden', 'true');
  svg.setAttribute('focusable', 'false');
  for (const part of ICONS[name] || []) {
    const path = document.createElementNS(SVG_NS, 'path');
    path.setAttribute('d', part.d);
    if (part.fill) { path.setAttribute('fill', 'currentColor'); }
    else {
      path.setAttribute('fill', 'none'); path.setAttribute('stroke', 'currentColor'); path.setAttribute('stroke-width', '2');
      path.setAttribute('stroke-linecap', 'round'); path.setAttribute('stroke-linejoin', 'round');
    }
    svg.appendChild(path);
  }
  return svg;
};
const setIcon = (button, name) => {
  if (button._icon === name) return;
  button._icon = name;
  button.replaceChildren(makeIcon(name));
};
const mkEl = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
};
// Switch built from a real checkbox (keyboard and screen readers keep working).
const makeSwitch = checked => {
  const wrap = mkEl('span', 'vdrpb-switch');
  const input = document.createElement('input');
  input.type = 'checkbox';
  input.checked = !!checked;
  wrap.append(input, mkEl('span', 'vdrpb-slider'));
  return { wrap, input };
};

// Options section open state, kept while the page lives (bars are rebuilt often).
let downloadOptionsOpen = false;

const createDownloadMenu = (video, signal, hooks = {}) => {
  const menu = mkEl('div', 'vdrpb-download-menu');
  menu.style.display = 'none';
  menu.setAttribute('aria-label', 'Download');

  // Actions
  const mkAction = (iconName, label, primary, action) => {
    const b = mkEl('button', 'vdrpb-mbtn' + (primary ? ' primary' : ''));
    b.type = 'button';
    b.dataset.action = action;
    b.append(makeIcon(iconName), mkEl('span', '', label));
    return b;
  };
  const downloadVideoButton = mkAction('download', 'Download video', true, 'video');
  const downloadMp3Button = mkAction('music', 'Download MP3', false, 'mp3');

  // Cut
  const cutHead = mkEl('label', 'vdrpb-mhead');
  const { wrap: cutSwitch, input: cutCheckbox } = makeSwitch(false);
  cutCheckbox.setAttribute('aria-label', 'Cut');
  cutHead.append(makeIcon('cut'), mkEl('span', 'vdrpb-mlabel', 'Cut'), cutSwitch);

  const cutFields = mkEl('div', 'vdrpb-cutfields off');
  const mkTimeInput = title => {
    const input = document.createElement('input');
    input.type = 'text';
    input.className = 'vdrpb-input';
    input.spellcheck = false;
    input.readOnly = true;
    input.title = title;
    input.setAttribute('inputmode', 'decimal');
    return input;
  };
  const startInput = mkTimeInput('Start (HH:MM:SS, decimals allowed)');
  const endInput = mkTimeInput('End (HH:MM:SS, decimals allowed, empty = to the end)');
  startInput.value = '00:00:00';
  startInput.setAttribute('aria-label', 'Cut start');
  endInput.setAttribute('aria-label', 'Cut end');
  const mkNow = (action, title) => {
    const b = mkEl('button', 'vdrpb-chip', 'Now');
    b.type = 'button';
    b.dataset.action = action;
    b.title = title;
    return b;
  };
  const inButton = mkNow('cut-start-now', 'Start at the current position');
  const outButton = mkNow('cut-end-now', 'End at the current position');
  const mkTimeRow = (label, input, button) => {
    const row = mkEl('div', 'vdrpb-timerow');
    row.append(mkEl('span', 'vdrpb-timelabel', label), input, button);
    return row;
  };
  cutFields.append(mkTimeRow('Start', startInput, inButton), mkTimeRow('End', endInput, outButton));

  const enableCut = () => {
    cutCheckbox.checked = true;
    startInput.readOnly = false;
    endInput.readOnly = false;
    cutFields.classList.remove('off');
  };

  // Selected range, in seconds (end null = to the end), or null when CUT is off
  // or the fields do not parse.
  const currentRange = () => {
    if (!cutCheckbox.checked) return null;
    const s = startInput.value.trim() === '' ? 0 : parseClock(startInput.value);
    const e = endInput.value.trim() === '' ? null : parseClock(endInput.value);
    if (s === null || (endInput.value.trim() !== '' && e === null)) return null;
    return { start: s, end: e };
  };
  const notifyCut = () => { if (hooks.onCutChange) { try { hooks.onCutChange(currentRange()); } catch {} } };

  // The same <video> element can receive new media (YouTube next video, ads,
  // Shorts/Reels swipes): a new source resets the range to the new duration.
  let cutSrc = video.currentSrc || '';
  const syncCutToMedia = () => {
    const d = video.duration;
    const hasDuration = Number.isFinite(d) && d > 0;
    const src = video.currentSrc || '';
    if (src !== cutSrc) {
      cutSrc = src;
      startInput.value = '00:00:00';
      endInput.value = hasDuration ? formatClock(d) : '';
      notifyCut();
    } else if (!cutCheckbox.checked && hasDuration) {
      endInput.value = formatClock(d);
    }
  };
  if (Number.isFinite(video.duration) && video.duration > 0) endInput.value = formatClock(video.duration);
  ['loadedmetadata', 'durationchange', 'emptied'].forEach(type => video.addEventListener(type, syncCutToMedia, { signal }));

  startInput.addEventListener('click', () => { if (!cutCheckbox.checked) { enableCut(); notifyCut(); } });
  endInput.addEventListener('click', () => { if (!cutCheckbox.checked) { enableCut(); notifyCut(); } });
  startInput.addEventListener('input', notifyCut);
  endInput.addEventListener('input', notifyCut);
  // Keys typed in the fields must not reach the site's shortcuts (space = pause, f = fullscreen…).
  [startInput, endInput].forEach(input => ['keydown', 'keyup', 'keypress'].forEach(type =>
    input.addEventListener(type, e => { if (e.key !== 'Escape') e.stopPropagation(); })));
  inButton.addEventListener('click', e => {
    e.stopPropagation();
    enableCut();
    startInput.value = formatClock(video.currentTime);
    notifyCut();
  });
  outButton.addEventListener('click', e => {
    e.stopPropagation();
    enableCut();
    endInput.value = formatClock(video.currentTime);
    notifyCut();
  });
  cutCheckbox.addEventListener('change', () => {
    if (cutCheckbox.checked) { enableCut(); }
    else { startInput.readOnly = true; endInput.readOnly = true; cutFields.classList.add('off'); }
    notifyCut();
  });

  // Options (inline section)
  const optionsButton = mkEl('button', 'vdrpb-mdisclosure');
  optionsButton.type = 'button';
  optionsButton.dataset.action = 'options';
  const chevron = makeIcon('chevron');
  chevron.classList.add('vdrpb-chev');
  optionsButton.append(makeIcon('sliders'), mkEl('span', 'vdrpb-mlabel', 'Options'), chevron);

  const optionsMenu = mkEl('div', 'vdrpb-options-menu');

  const syncers = [];
  const createOptionCheckbox = (labelText, key) => {
    const row = mkEl('label', 'vdrpb-opt');
    const { wrap, input } = makeSwitch(settings[key]);
    input.addEventListener('change', () => saveSetting(key, input.checked));
    syncers.push(() => { input.checked = !!settings[key]; });
    row.append(mkEl('span', '', labelText), wrap);
    return row;
  };

  const presetButtons = mkEl('div', 'vdrpb-seg');
  presetButtons.setAttribute('role', 'radiogroup');
  presetButtons.setAttribute('aria-label', 'Quality');
  const presetEls = PRESETS.map(p => {
    const b = mkEl('button', 'vdrpb-seg-btn', PRESET_LABELS[p]);
    b.type = 'button';
    b.setAttribute('role', 'radio');
    b.addEventListener('click', e => { e.stopPropagation(); saveSetting('preset', p); });
    return { p, b };
  });
  const syncPresets = () => presetEls.forEach(({ p, b }) => b.setAttribute('aria-checked', settings.preset === p ? 'true' : 'false'));
  syncPresets();
  syncers.push(syncPresets);
  presetButtons.append(...presetEls.map(x => x.b));

  const folderLine = mkEl('div', 'vdrpb-folder');
  const folderText = mkEl('span');
  folderLine.append(makeIcon('folder'), folderText);
  const syncFolder = () => {
    const base = settings.downloadDir || 'Downloads';
    const sub = settings.siteSubfolders && SITE_FOLDERS[current_website] ? '\\' + SITE_FOLDERS[current_website] : '';
    folderText.textContent = base + sub;
    folderLine.title = base + sub + '\nChange it from the extension icon in the toolbar';
  };
  syncFolder();
  syncers.push(syncFolder);

  optionsMenu.append(
    mkEl('div', 'vdrpb-optlabel', 'Quality'),
    presetButtons,
    createOptionCheckbox('Convert video to MP4', 'convertMP4'),
    createOptionCheckbox('Precise cut (re-encode)', 'preciseCut'),
    createOptionCheckbox('Beep when done', 'bipAtEnd'),
    createOptionCheckbox('Copy when done', 'copyAtEnd'),
    createOptionCheckbox('Debug (verbose logs)', 'keepConsoleOpen'),
    folderLine
  );

  menu._syncSettings = () => syncers.forEach(fn => { try { fn(); } catch {} });

  const setOptionsOpen = open => {
    downloadOptionsOpen = open;
    optionsMenu.style.display = open ? 'flex' : 'none';
    optionsButton.setAttribute('aria-expanded', open ? 'true' : 'false');
    if (open) menu._syncSettings();
    if (menu._place && menu.style.display === 'flex') menu._place();
  };
  setOptionsOpen(downloadOptionsOpen);
  optionsButton.addEventListener('click', e => { e.stopPropagation(); setOptionsOpen(optionsMenu.style.display !== 'flex'); });

  menu.append(
    downloadVideoButton, downloadMp3Button,
    mkEl('div', 'vdrpb-mdiv'), cutHead, cutFields,
    mkEl('div', 'vdrpb-mdiv'), optionsButton, optionsMenu
  );
  // Clicks inside the menu stay inside (sites toggle playback on clicks over the player).
  menu.addEventListener('click', e => e.stopPropagation());

  // undefined = CUT off, null = invalid (already reported), '' = whole video,
  // otherwise a yt-dlp section spec built from the parsed seconds.
  const getCutValue = () => {
    if (!cutCheckbox.checked) return undefined;
    const start = startInput.value.trim();
    const end = endInput.value.trim();
    const sSec = start === '' ? 0 : parseClock(start);
    let eSec = end === '' ? null : parseClock(end);
    if (sSec === null || (end !== '' && eSec === null)) {
      showNotification("Invalid range format (HH:MM:SS)", false, 2500);
      return null;
    }
    const d = video.duration;
    if (eSec !== null && Number.isFinite(d) && d > 0 && eSec >= d - 0.05) eSec = null;   // the full length = to the end
    if (eSec !== null && eSec <= sSec) {
      showNotification("Range end must be after start", false, 2500);
      return null;
    }
    const startPart = sSec > 0 ? cutSeconds(sSec) : '';
    const endPart = eSec !== null ? cutSeconds(eSec) : '';
    return (startPart || endPart) ? '*' + startPart + '-' + endPart : '';
  };

  const launch = mp3 => {
    const cut = getCutValue();
    if (cut === null) return;
    // Read the download URL at CLICK time (the active video's URL is refreshed
    // continuously) so we never send a stale link from menu-creation time.
    // null (vs undefined) = known-unresolvable target: refuse instead of
    // shipping the feed URL to the host for a guaranteed failure.
    if (video._downloadUrl === null) {
      showNotification("Video link not found — open the post to download it", false, 3000);
      return;
    }
    const targetUrl = video._downloadUrl || window.location.href;
    const isGIF = mp3 ? false : !!video._isGIF;
    startDownload({
      targetUrl,
      mp3,
      isGIF,
      cut: cut || null,
      convertMP4: (mp3 || isGIF) ? false : settings.convertMP4,
      preciseCut: settings.preciseCut,
      preset: (mp3 || isGIF) ? 'best' : settings.preset,
      bipAtEnd: settings.bipAtEnd,
      copyAtEnd: settings.copyAtEnd,
      keepConsoleOpen: settings.keepConsoleOpen,
      playlistItem: video._playlistItem || null,
      // Lets the native host choose how to cut (whole file then local cut, or section only).
      mediaDuration: cut && Number.isFinite(video.duration) && video.duration > 0 ? Math.round(video.duration * 1000) / 1000 : 0,
      downloadDir: settings.downloadDir || '',
      subfolder: settings.siteSubfolders ? (SITE_FOLDERS[current_website] || '') : '',
      site: current_website
    });
  };

  downloadVideoButton.addEventListener('click', e => { e.stopPropagation(); launch(false); });
  downloadMp3Button.addEventListener('click', e => { e.stopPropagation(); launch(true); });

  return menu;
};

// Hover/click/keyboard behaviour of the download menu, anchored under its button
// and flipped above the bar when it would leave the viewport.
const attachDownloadMenu = (controlBar, button, menu, align) => {
  menu.classList.add(align === 'left' ? 'vdrpb-menu-left' : 'vdrpb-menu-right');
  controlBar.appendChild(menu);
  controlBar._menu = menu;
  button.setAttribute('aria-haspopup', 'true');
  button.setAttribute('aria-expanded', 'false');
  let hideTimeout = 0;
  const place = () => {
    menu.classList.remove('vdrpb-menu-up');
    const r = menu.getBoundingClientRect();
    if (r.bottom > window.innerHeight - 8) {
      const barTop = controlBar.getBoundingClientRect().top;
      if (barTop - r.height - 6 >= 8) menu.classList.add('vdrpb-menu-up');
    }
  };
  menu._place = place;
  const show = () => {
    clearTimeout(hideTimeout);
    if (menu.style.display === 'flex') return;
    menu.style.display = 'flex';
    button.classList.add('open');
    button.setAttribute('aria-expanded', 'true');
    if (menu._syncSettings) menu._syncSettings();
    place();
  };
  const hide = () => {
    clearTimeout(hideTimeout);
    // A button clicked in the menu keeps the focus: drop it so nothing in a hidden menu stays focused.
    if (menu.contains(document.activeElement)) { try { document.activeElement.blur(); } catch {} }
    menu.style.display = 'none';
    button.classList.remove('open');
    button.setAttribute('aria-expanded', 'false');
  };
  // Only a cut field being edited keeps the menu open once the pointer has left
  // (a clicked button or switch keeps the focus too, it must not).
  const typing = () => {
    const a = document.activeElement;
    return !!a && menu.contains(a) && a.classList.contains('vdrpb-input');
  };
  const hovered = () => menu.matches(':hover') || button.matches(':hover');
  const hideSoon = () => {
    clearTimeout(hideTimeout);
    hideTimeout = setTimeout(() => { if (!hovered() && !typing()) hide(); }, 200);
  };
  menu._isOpen = () => menu.style.display === 'flex';
  menu._typing = typing;
  menu._hide = hide;
  menu._hovered = hovered;
  button.addEventListener('mouseenter', show);
  button.addEventListener('mouseleave', hideSoon);
  menu.addEventListener('mouseenter', show);
  menu.addEventListener('mouseleave', hideSoon);
  // Leaving a cut field with the pointer already outside closes the menu.
  menu.addEventListener('focusout', () => setTimeout(() => { if (menu._isOpen() && !hovered() && !typing()) hideSoon(); }, 0));
  // Keyboard/touch path (hover never fires there). e.detail === 0 = keyboard
  // activation, the only case allowed to CLOSE (a mouse click after hover
  // must not toggle the just-opened menu shut).
  button.addEventListener('click', e => {
    e.stopPropagation();
    if (menu.style.display !== 'flex') show();
    else if (e.detail === 0) hide();
  });
  menu.addEventListener('keydown', e => {
    if (e.key === 'Escape') { e.stopPropagation(); hide(); button.focus(); }
  });
};

// ---------------------------------------------------------------------------
// Control bar
// ---------------------------------------------------------------------------
const removeControlBar = video => {
  if (video && video._barAC) { try { video._barAC.abort(); } catch {} delete video._barAC; }
  if (video && video._controlBar) {
    const bar = video._controlBar;
    if (bar._ro) { try { bar._ro.disconnect(); } catch {} }
    bar.remove();
    delete video._controlBar;
    if (activeBar === bar) activeBar = null;
  }
};
const removeActiveBar = () => {
  if (!activeBar) return;
  if (activeBar._video) removeControlBar(activeBar._video);
  else { activeBar.remove(); activeBar = null; }
};

// ---------------------------------------------------------------------------
// Online-update state. The native host compares the installed version to the
// latest GitHub release tag; we surface it as an "update" strip inside the bar.
// The verdict is shared by every tab through extension storage; the host is
// asked at most every 30 min.
// ---------------------------------------------------------------------------
const UPDATE_POLL_MS = 60000;         // maybe ask the host at most once a minute
let lastUpdatePoll = -UPDATE_POLL_MS; // negative so the FIRST tick polls immediately (not after 60s)
const UPDATE_TTL_MS  = 30 * 60000;    // re-ask the native host at most every 30 min

// Busy state is MODULE-level (bars/strips are destroyed on every navigation) AND
// shared through extension storage, so two tabs never launch setup.bat together.
let updateLaunchedAt = 0;   // timestamp, NOT a boolean: the launching tab honors the same 2-min TTL as the others
const updateLaunchClaimed = () => Date.now() - Math.max(updateLaunchedAt, Number(updateLaunch.at) || 0) < 120000;
// Downloads running anywhere in the browser (reported by background.js): the
// update restarts the browser, so it waits until they end.
let activeDownloadCount = 0;
const updateStripLabel = () => "⬆ Update extension" + (vdrpbUpdate.latest ? ' v' + vdrpbUpdate.latest : '');
const UPDATE_BUSY_LABEL = 'Updating…';
const renderUpdateStrip = s => {
  const busy = updateLaunchClaimed();
  const blocked = !busy && activeDownloadCount > 0;
  s.classList.toggle('busy', busy || blocked);
  s.textContent = busy ? UPDATE_BUSY_LABEL : updateStripLabel();
  s.title = blocked ? 'Finish or cancel downloads first' : 'A new version is available';
};
const makeUpdateStrip = () => {
  const s = document.createElement('button');
  s.className = 'vdrpb-update-strip';
  renderUpdateStrip(s);
  s.addEventListener('click', e => {
    e.stopPropagation();
    if (updateLaunchClaimed()) return;
    if (activeDownloadCount > 0) { showNotification('Finish or cancel downloads first, then update.', false, 3000); return; }
    updateLaunchedAt = Date.now();
    storageSet({ updateLaunch: { at: updateLaunchedAt } });
    renderUpdateStrip(s);
    const resetStrip = message => {
      updateLaunchedAt = 0;
      updateLaunch = { at: 0 };
      storageRemove('updateLaunch');
      if (s.isConnected) renderUpdateStrip(s);
      if (message) showNotification(message, false, 4000);
    };
    try {
      chrome.runtime.sendMessage({ type: 'DOUPDATE' }, r => {
        if (chrome.runtime.lastError || !r || !r.success) resetStrip((r && r.message) || 'Failed to launch the update.');
      });
    } catch { resetStrip('Failed to launch the update.'); }
  });
  return s;
};

const refreshUpdateButtons = () => {
  const bar = activeBar;
  if (!bar) return;
  const avail = updateAvailable();
  const row = bar._controlsRow;
  let strip = bar.querySelector(':scope > .vdrpb-update-strip');
  if (avail && !strip && row) { strip = makeUpdateStrip(); bar.insertBefore(strip, row); }
  else if (!avail && strip)   { strip.remove(); strip = null; }
  // Self-heal the busy state (claim expired, or cleared by the launching tab).
  if (strip) renderUpdateStrip(strip);
  if (bar._video && bar._video.isConnected) updateControlBarPosition(bar._video, bar);   // re-anchor after the height change
};

const maybeCheckUpdate = () => {
  refreshUpdateButtons();
  if (!updateStateLoaded) return;
  const now = Date.now();
  if (now - (Number(vdrpbUpdate.at) || 0) < UPDATE_TTL_MS) return;   // still fresh -> don't nag the host
  // Claim the check for ~2 min so other tabs don't all spawn a host.
  vdrpbUpdate = { ...vdrpbUpdate, ver: EXT_VER, at: now - UPDATE_TTL_MS + 120000 };
  storageSet({ updateCache: vdrpbUpdate });
  try {
    chrome.runtime.sendMessage({ type: 'CHECKUPDATE' }, r => {
      // success === false = host unreachable, NOT an authoritative "no update":
      // keep the 2-min claim so a retry happens soon instead of caching a
      // false negative for 30 min.
      if (chrome.runtime.lastError || !r || r.success === false) return;
      vdrpbUpdate = { ver: EXT_VER, available: !!r.updateAvailable, latest: r.latest || null, at: Date.now() };
      storageSet({ updateCache: vdrpbUpdate });
      refreshUpdateButtons();
    });
  } catch {}
};

const makeSeparator = () => mkEl('div', 'vdrpb-sep');

// Tells volume-lock.js (page world) that the lock changed through this slider,
// so it updates the site's native volume control to match.
const signalVolumeSet = video => {
  const target = video && video.isConnected ? video : document;
  try { target.dispatchEvent(new CustomEvent('vdrpb-volume-set', { bubbles: true })); } catch {}
};

// Level restored by the mute button.
let lastAudibleVolume = 0.5;

// Volume control — present on BOTH bar variants: everywhere the lock is enforced
// there must be a visible control to change it (the site's own slider mirrors
// it through volume-lock.js). Returns { group, slider, sync }.
const makeVolumeControl = video => {
  const group = mkEl('div', 'vdrpb-volume');
  const muteButton = mkEl('button', 'vdrpb-ibtn');
  muteButton.type = 'button';
  const s = document.createElement('input');
  s.type = 'range'; s.min = 0; s.max = 1; s.step = 0.01;
  s.className = 'vdrpb-range';
  s.setAttribute('aria-label', 'Volume');
  const sync = () => {
    const v = clamp01(parseFloat(s.value));
    if (v > 0) lastAudibleVolume = v;
    setIcon(muteButton, v <= 0 ? 'mute' : v < 0.5 ? 'volumeLow' : 'volume');
    muteButton.title = v <= 0 ? 'Unmute' : 'Mute';
    muteButton.setAttribute('aria-label', muteButton.title);
    s.title = 'Volume ' + Math.round(v * 100) + '%';
  };
  s.value = clamp01((volLockNorm !== null) ? volLockNorm : (video.muted ? 0 : Math.sqrt(clamp01(video.volume))));
  sync();
  const applyLevel = level => {
    s.value = level;
    lockVolume(level);
    applyUserVolume(video);   // explicit gesture: allowed to mute/unmute THIS video
    signalVolumeSet(video);
    sync();
  };
  // A site-muted video + lock > 0: a single CLICK on our slider (even without
  // moving it) is the explicit gesture that unmutes at the locked level — the
  // global clamp itself never unmutes.
  s.addEventListener('pointerdown', () => { if (volLockNorm !== null) { applyUserVolume(video); signalVolumeSet(video); } });
  s.addEventListener('input', e => {
    e.stopPropagation();
    applyLevel(parseFloat(s.value));
  });
  muteButton.addEventListener('click', e => {
    e.stopPropagation();
    const current = clamp01(parseFloat(s.value));
    applyLevel(current > 0 ? 0 : (lastAudibleVolume > 0 ? lastAudibleVolume : 0.5));
  });
  group.append(muteButton, s);
  return { group, slider: s, sync: () => { s.value = clamp01(volLockNorm !== null ? volLockNorm : parseFloat(s.value)); sync(); } };
};

const createControlBar = video => {
  const ac = new AbortController();
  const signal = ac.signal;
  video._barAC = ac;

  const controlBar = mkEl('div', 'extension-control-bar');
  controlBar.style.opacity = '1';

  // Controls live in their own row so an "update available" strip can sit ABOVE them
  // (the bar grows a little to make room) without disturbing the compact layout.
  const controlsRow = mkEl('div', 'vdrpb-row');

  const volume = makeVolumeControl(video);
  controlBar._volSlider = volume.slider;
  controlBar._syncVolume = volume.sync;

  const downloadMenuButton = mkEl('button', 'vdrpb-ibtn download-menu-button');
  downloadMenuButton.type = 'button';
  downloadMenuButton.title = 'Download';
  downloadMenuButton.setAttribute('aria-label', 'Download');
  downloadMenuButton.appendChild(makeIcon('download'));

  controlBar._isFullBar = isFullBarFor(video);   // shape snapshot for the SPA settle-skip
  if (controlBar._isFullBar) {
    const playPauseButton = mkEl('button', 'vdrpb-ibtn play-pause-button');
    playPauseButton.type = 'button';
    const syncPlay = () => {
      setIcon(playPauseButton, video.paused ? 'play' : 'pause');
      playPauseButton.title = video.paused ? 'Play' : 'Pause';
      playPauseButton.setAttribute('aria-label', playPauseButton.title);
    };
    syncPlay();
    playPauseButton.addEventListener('click', e => { e.stopPropagation(); video.paused ? video.play() : video.pause(); });
    video.addEventListener('play', syncPlay, { signal });
    video.addEventListener('pause', syncPlay, { signal });

    const elapsedTime = mkEl('span', 'vdrpb-time', '00:00');

    const progressBar = document.createElement('input');
    progressBar.type = 'range'; progressBar.min = 0; progressBar.max = 100; progressBar.step = 'any'; progressBar.value = 0;
    progressBar.className = 'vdrpb-range';
    progressBar.setAttribute('aria-label', 'Seek');
    // Wrapper so the selected CUT range can be drawn under the thumb.
    const progressWrap = mkEl('div', 'vdrpb-progress');
    const cutOverlay = mkEl('div', 'vdrpb-cutrange');
    progressWrap.append(progressBar, cutOverlay);
    let cutRange = null;
    const drawCutRange = () => {
      const d = video.duration;
      if (!cutRange || !(Number.isFinite(d) && d > 0)) { cutOverlay.style.display = 'none'; return; }
      const a = Math.max(0, Math.min(1, cutRange.start / d));
      const b = cutRange.end === null ? 1 : Math.max(a, Math.min(1, cutRange.end / d));
      cutOverlay.style.left = (a * 100) + '%';
      cutOverlay.style.width = ((b - a) * 100) + '%';
      cutOverlay.style.display = 'block';
    };
    video.addEventListener('durationchange', drawCutRange, { signal });

    const totalTime = mkEl('span', 'vdrpb-time', '00:00');

    const downloadMenu = createDownloadMenu(video, signal, { onCutChange: range => { cutRange = range; drawCutRange(); } });
    attachDownloadMenu(controlBar, downloadMenuButton, downloadMenu, 'right');

    controlsRow.append(playPauseButton, elapsedTime, progressWrap, totalTime, makeSeparator(), volume.group, makeSeparator(), downloadMenuButton);

    // While the user drags the thumb, the rAF loop must not overwrite .value
    // from video.currentTime (which lags the seek) — that fights the drag.
    let scrubbing = false;
    progressBar.addEventListener('pointerdown', () => { scrubbing = true; });
    progressBar.addEventListener('pointerup', () => { scrubbing = false; });
    progressBar.addEventListener('pointercancel', () => { scrubbing = false; });
    progressBar.addEventListener('input', e => {
      e.stopPropagation();
      if (video.duration && isFinite(video.duration)) {
        video.currentTime = (progressBar.value / 100) * video.duration;
      }
    });
    // rAF for smoothness, but compare-before-write: at 60-144Hz the strings
    // change once a second and the thumb moves sub-pixel — skip the DOM writes.
    let lastPct = -1, lastElapsed = '', lastTotal = '';
    const updateProgress = () => {
      if (signal.aborted) return;                 // stop the loop when the bar is removed
      if (video.duration && isFinite(video.duration)) {
        const pct = (video.currentTime / video.duration) * 100;
        // One write per displayed pixel at most (the slider is a few hundred px wide).
        if (!scrubbing && Math.abs(pct - lastPct) >= 0.05) { lastPct = pct; progressBar.value = pct; }
        const el = formatTime(video.currentTime);
        if (el !== lastElapsed) { lastElapsed = el; elapsedTime.textContent = el; }
        const tt = formatTime(video.duration);
        if (tt !== lastTotal) { lastTotal = tt; totalTime.textContent = tt; }
      }
      requestAnimationFrame(updateProgress);
    };
    updateProgress();
  } else {
    // The lock is enforced globally, so even the mini bar needs a visible way
    // to adjust it (the site's own volume UI is overridden by the clamp).
    const downloadMenu = createDownloadMenu(video, signal);
    attachDownloadMenu(controlBar, downloadMenuButton, downloadMenu, 'left');
    controlsRow.append(volume.group, makeSeparator(), downloadMenuButton);
  }

  controlBar.appendChild(controlsRow);
  controlBar._controlsRow = controlsRow;
  // Surface a pending update immediately on this fresh bar (strip sits above the row).
  if (updateAvailable()) controlBar.insertBefore(makeUpdateStrip(), controlsRow);

  // Hover state as a boolean (pointerenter/leave treat descendants as inside)
  // so the tick reads a flag instead of running a selector match.
  controlBar._hovered = false;
  controlBar.addEventListener('pointerenter', () => { controlBar._hovered = true; });
  controlBar.addEventListener('pointerleave', () => { controlBar._hovered = false; });

  controlBar._video = video;
  video._controlBar = controlBar;
  // Same predicate as the fullscreenchange handler: only host the bar in the
  // fullscreen element if it actually contains this video (root fullscreen
  // renders the whole document, so body is fine there).
  const fsEl = document.fullscreenElement;
  ((fsEl && fsEl !== document.documentElement && fsEl.contains(video)) ? fsEl : document.body).appendChild(controlBar);
  // Cache the bar's size and re-anchor whenever it actually changes (menu/update
  // strip toggles) — fires once right after observe(), which also does the
  // initial positioning with real dimensions.
  controlBar._ro = new ResizeObserver(() => {
    controlBar._h = controlBar.offsetHeight;
    controlBar._w = controlBar.offsetWidth;
    if (controlBar._video && controlBar._video.isConnected) updateControlBarPosition(controlBar._video, controlBar);
  });
  controlBar._ro.observe(controlBar);
  activeBar = controlBar;
  return controlBar;
};

// ---------------------------------------------------------------------------
// Active-video detection + per-site download URL resolution
// ---------------------------------------------------------------------------
const isCenterInViewport = rect => {
  if (rect.width === 0 || rect.height === 0) return false;
  if (!(rect.top < window.innerHeight && rect.bottom > 0)) return false;
  if (!(rect.left < window.innerWidth && rect.right > 0)) return false;
  const centerX = rect.left + rect.width / 2;
  const centerY = rect.top + rect.height / 2;
  return centerX >= 0 && centerX <= window.innerWidth && centerY >= 0 && centerY <= window.innerHeight;
};

const OWN_UI_SELECTOR = '.extension-control-bar, .vdrpb-stack, .vdrpb-notification, .vdrpb-download-menu';

// Largest ancestor still at most 3x the video's area: the player, with its own
// overlays (controls, captions), but not the page around it.
const playerRootOf = (video, rect) => {
  const area = Math.max(1, rect.width * rect.height);
  let root = video;
  for (let a = video.parentElement, i = 0; a && a !== document.body && i < 15; a = a.parentElement, i++) {
    const r = a.getBoundingClientRect();
    const aArea = r.width * r.height;
    if (aArea === 0) continue;   // collapsed wrapper: not a player boundary
    if (aArea > area * 3) break;
    root = a;
  }
  return root;
};

// True when something outside the video's player covers its centre (a dialog
// opened over a feed, a browse-mode overlay).
const isCovered = (video, rect) => {
  const x = Math.max(0, Math.min(window.innerWidth - 1, rect.left + rect.width / 2));
  const y = Math.max(0, Math.min(window.innerHeight - 1, rect.top + rect.height / 2));
  let top = null;
  for (const el of document.elementsFromPoint(x, y)) {
    if (el.closest && el.closest(OWN_UI_SELECTOR)) continue;
    top = el;
    break;
  }
  if (!top || top === video || video.contains(top)) return false;
  return !playerRootOf(video, rect).contains(top);
};

// Smallest ancestor (at most 12 levels up) holding a link that matches, as long
// as it does not also hold another video: a scope with two videos is a feed, not
// this video's item, and its first link may belong to any post.
const findItemScope = (video, linkSelector) => {
  let node = video.parentElement;
  for (let depth = 0; node && node !== document.body && depth < 12; depth++, node = node.parentElement) {
    if (node.querySelectorAll('video').length > 1) return null;
    if (node.querySelector(linkSelector)) return node;
  }
  return null;
};

const checkWebsiteVideoCompatibility = (website, videoElement) => {
  const none = { url: null, isGIF: false };
  if (!videoElement) return none;
  const href = window.location.href;

  if (website === "tiktok") {
    const permalink = href.match(/^https:\/\/www\.tiktok\.com\/@([^\/?#]+)\/video\/(\d+)/);
    const idEl = videoElement.closest('[id^="xgwrapper-"]');
    const item = videoElement.closest('article') || (idEl && idEl.closest('article'));
    const idMatch = ((idEl && idEl.id) || (item && item.querySelector('[id^="xgwrapper-"]') || {}).id || '').match(/xgwrapper-\d+-(\d+)/);
    if (permalink && (!idMatch || idMatch[1] === permalink[2])) return { url: permalink[0], isGIF: false };
    if (!idMatch) return none;
    const scope = item || findItemScope(videoElement, 'a[href^="/@"]');
    const link = scope && scope.querySelector('a[href^="/@"]');
    const nameMatch = link && (link.getAttribute('href') || '').match(/^\/@([^\/?#]+)/);
    // yt-dlp only needs the video id; the author keeps the card's link readable.
    return { url: `https://www.tiktok.com/@${nameMatch ? nameMatch[1] : ''}/video/${idMatch[1]}`, isGIF: false };
  }

  if (website === "instagram") {
    // Permalink page (reel / post / tv): the page URL is the right target.
    if (/^https:\/\/(?:www\.)?instagram\.com\/(?:[^\/]+\/)?(reel|reels|p|tv)\/[^\/]+/.test(href)) {
      return { url: href, isGIF: false };
    }
    // Feed: the permalink of the post (article) that holds the video.
    const linkSel = 'a[href*="/reel/"], a[href*="/reels/"], a[href*="/p/"], a[href*="/tv/"]';
    const article = videoElement.closest('article');
    const scope = article || findItemScope(videoElement, linkSel);
    const link = scope && scope.querySelector(linkSel);
    const m = link && (link.getAttribute('href') || '').match(/\/(reel|reels|p|tv)\/([^\/?#]+)/);
    return m ? { url: `https://www.instagram.com/${m[1] === 'reels' ? 'reel' : m[1]}/${m[2]}/`, isGIF: false } : none;
  }

  if (website === "facebook") {
    const idHolder = videoElement.closest('[data-video-id]');
    if (idHolder && /^\d+$/.test(idHolder.getAttribute('data-video-id') || '')) {
      return { url: `https://www.facebook.com/reel/${idHolder.getAttribute('data-video-id')}`, isGIF: false };
    }
    const fromHref = h => {
      let m = h.match(/facebook\.com\/watch\/?\?(?:[^#]*&)?v=(\d+)/);
      if (m) return `https://www.facebook.com/watch/?v=${m[1]}`;
      m = h.match(/facebook\.com\/([^\/?#]+)\/videos\/(?:[^\/?#]+\/)?(\d+)/);
      if (m) return `https://www.facebook.com/${m[1]}/videos/${m[2]}`;
      m = h.match(/facebook\.com\/reel\/(\d+)/);
      if (m) return `https://www.facebook.com/reel/${m[1]}`;
      return null;
    };
    const scope = findItemScope(videoElement, 'a[href*="/videos/"], a[href*="/watch/?v="], a[href*="/reel/"]');
    if (scope) {
      for (const a of scope.querySelectorAll('a[href*="/videos/"], a[href*="/watch/?v="], a[href*="/reel/"]')) {
        const u = fromHref(a.href);
        if (u) return { url: u, isGIF: false };
      }
    }
    // Video permalink page: the page is the target when this is its main video.
    const pageUrl = fromHref(href);
    if (pageUrl) {
      const rect = videoElement.getBoundingClientRect();
      const area = rect.width * rect.height;
      const larger = [...document.querySelectorAll('video')].some(v => {
        if (v === videoElement) return false;
        const r = v.getBoundingClientRect();
        return r.width * r.height > area;
      });
      if (!larger) return { url: pageUrl, isGIF: false };
    }
    return none;
  }

  if (website === "twitter") {
    const item = videoElement.closest('article[data-testid="tweet"]');
    if (!item) {
      const m = href.match(/^https:\/\/(?:www\.)?x\.com\/([^\/?#]+)\/status\/(\d+)/);
      return m ? { url: `https://www.x.com/${m[1]}/status/${m[2]}`, isGIF: false } : none;
    }
    // The tweet's permalink is the status link that wraps its timestamp.
    const links = [...item.querySelectorAll('a[href*="/status/"]')].filter(a => a.closest('article[data-testid="tweet"]') === item);
    const link = links.find(a => a.querySelector('time')) || links[0];
    const m = link && (link.getAttribute('href') || '').match(/\/([^\/]+)\/status\/(\d+)/);
    // GIF badge: only an element whose text is EXACTLY "GIF" (not tweet text ending in "GIF").
    const scope = videoElement.closest('[data-testid="videoComponent"], [data-testid="videoPlayer"]') || item;
    let isGIF = false;
    scope.querySelectorAll("span").forEach(span => { if (span.textContent.trim() === "GIF") isGIF = true; });
    return m ? { url: `https://www.x.com/${m[1]}/status/${m[2]}`, isGIF } : none;
  }

  return none;
};

// After an SPA navigation the OLD page's video can survive for a few hundred ms
// and win the election while isFullBarFor already evaluates the NEW href —
// suppress bar creation briefly so the bar never attaches in the wrong shape.
// Same-shape navigations (shorts→shorts, tiktok swipe) skip the wait: the race
// is only visible cross-shape, and swipes are the highest-frequency gesture.
let urlSettleUntil = 0;
let lastNavShape = null;
// Resolved links are reused while the page URL and the media source stay the
// same: 30 s for a found link, 5 s for a miss.
const LINK_CACHE_HIT_MS = 30000;
const LINK_CACHE_MISS_MS = 5000;

const resolveVideoLink = video => {
  const nowMs = performance.now();
  const src = video.currentSrc || '';
  let cached = video._dlCache;
  const ttl = cached && cached.info && cached.info.url ? LINK_CACHE_HIT_MS : LINK_CACHE_MISS_MS;
  if (!cached || cached.href !== window.location.href || cached.src !== src || nowMs - cached.at > ttl) {
    cached = { href: window.location.href, src, at: nowMs, info: checkWebsiteVideoCompatibility(current_website, video) };
    video._dlCache = cached;
  }
  return cached.info;
};

const updateActiveVideoControlBar = () => {
  // Drop a bar whose element or video the site detached.
  if (activeBar && (!activeBar.isConnected || !activeBar._video || !activeBar._video.isConnected)) removeActiveBar();

  if (!/^https:\/\/(?:\w+\.)?(?:facebook\.com|instagram\.com|x\.com|tiktok\.com|youtube\.com\/(?:watch|shorts))/.test(window.location.href)) {
    removeActiveBar();
    return;
  }

  // One querySelectorAll, one getBoundingClientRect per video.
  const viewportCenterX = window.innerWidth / 2;
  const viewportCenterY = window.innerHeight / 2;
  const candidates = [];
  document.querySelectorAll('video').forEach(video => {
    if (!video.isConnected) return;
    const rect = video.getBoundingClientRect();
    if (!isCenterInViewport(rect)) return;
    const dx = rect.left + rect.width / 2 - viewportCenterX;
    const dy = rect.top + rect.height / 2 - viewportCenterY;
    candidates.push({ video, rect, distance: Math.hypot(dx, dy), area: rect.width * rect.height });
  });

  let activeVideo = null;
  if (candidates.length === 1) {
    activeVideo = candidates[0].video;
  } else if (candidates.length > 1) {
    // Several centred videos: skip covered ones (unless all are), then prefer a
    // playing video of comparable size, then the one closest to the centre.
    const maxArea = Math.max(...candidates.map(c => c.area));
    candidates.forEach(c => {
      c.covered = isCovered(c.video, c.rect);
      c.playing = !c.video.paused && !c.video.ended && c.area >= maxArea * 0.4;
    });
    const visible = candidates.filter(c => !c.covered);
    const pool = visible.length ? visible : candidates;
    pool.sort((a, b) => (b.playing - a.playing) || (a.distance - b.distance));
    activeVideo = pool[0].video;
  }

  if (!activeVideo) { removeActiveBar(); return; }
  if (activeBar && activeBar._video !== activeVideo) removeActiveBar();

  let canProceed = true;
  if (["facebook", "twitter", "tiktok", "instagram"].includes(current_website)) {
    const info = resolveVideoLink(activeVideo);
    if (info && info.url) {
      activeVideo._downloadUrl = info.url;
      activeVideo._isGIF = info.isGIF;
    } else if (current_website === "instagram" && /\/(reel|reels|p|tv|stories)\/[^\/?#]+/.test(window.location.pathname)) {
      // Instagram fallback: only on pages whose URL can actually resolve to a
      // video (permalinks incl. /{user}/p/... and stories). The feed root or
      // /explore would just spin up the host for a guaranteed yt-dlp failure.
      activeVideo._downloadUrl = window.location.href;
      activeVideo._isGIF = false;
    } else if (current_website === "instagram" || current_website === "facebook" || current_website === "tiktok") {
      // Unresolvable permalink: keep the playback/volume bar, only the download
      // target is unavailable (launch() refuses politely).
      activeVideo._downloadUrl = null;
      activeVideo._isGIF = false;
    } else {
      removeControlBar(activeVideo);
      canProceed = false;
    }
    // Instagram carousel: the slide index of the post (1-based) selects the item.
    if (current_website === "instagram") {
      const idx = parseInt(new URLSearchParams(window.location.search).get('img_index'), 10);
      activeVideo._playlistItem = Number.isFinite(idx) && idx >= 1 && idx <= 50 ? idx : null;
    }
  }

  if (canProceed && activeVideo.isConnected) {
    if (!activeVideo._controlBar) {
      if (performance.now() >= urlSettleUntil || isFullBarFor(activeVideo) === lastNavShape) createControlBar(activeVideo);
    } else {
      updateControlBarPosition(activeVideo, activeVideo._controlBar);
    }
  } else if (!canProceed || !activeVideo.isConnected) {
    removeControlBar(activeVideo);
  }
};

// ---------------------------------------------------------------------------
// Single throttled loop: active-video management, cursor-inactivity opacity,
// and SPA URL-change cleanup (replaces the isolated-world history patch that
// never actually fired on the page's own pushState calls).
// ---------------------------------------------------------------------------
let lastMouseMoveTime = performance.now();
document.addEventListener('mousemove', () => { lastMouseMoveTime = performance.now(); }, { passive: true, signal: lifetime.signal });

window.addEventListener('resize', () => {
  if (activeBar && activeBar._video && activeBar._video.isConnected) updateControlBarPosition(activeBar._video, activeBar);
  // Re-clamp the card stack too: a persisted position from a bigger monitor
  // must not leave it (and its Cancel buttons) outside the shrunken viewport.
  if (vdrpbStack) {
    const r = parseInt(vdrpbStack.style.right) || 18, b = parseInt(vdrpbStack.style.bottom) || 18;
    vdrpbStack.style.right = Math.max(4, Math.min(Math.max(4, window.innerWidth - 120), r)) + 'px';
    vdrpbStack.style.bottom = Math.max(4, Math.min(Math.max(4, window.innerHeight - 40), b)) + 'px';
  }
}, LIVE);

// Element fullscreen only paints the fullscreenElement subtree: reparent our UI
// into it so the bar and in-progress download cards stay visible (a DOM move —
// listeners and timers survive).
document.addEventListener('fullscreenchange', () => {
  const fsRaw = document.fullscreenElement;
  const fs = (fsRaw && fsRaw !== document.documentElement) ? fsRaw : null;   // root fullscreen renders everything
  if (activeBar) {
    const host = (fs && activeBar._video && fs.contains(activeBar._video)) ? fs : document.body;
    if (activeBar.parentElement !== host) {
      host.appendChild(activeBar);
      if (activeBar._video && activeBar._video.isConnected) updateControlBarPosition(activeBar._video, activeBar);
    }
  }
  if (vdrpbStack && vdrpbStack.isConnected) {
    const host = fs || document.body;
    if (vdrpbStack.parentElement !== host) host.appendChild(vdrpbStack);
  }
}, LIVE);

// Settings changed in another tab or in the toolbar popup.
settingsListeners.push(() => {
  if (activeBar && activeBar._menu && activeBar._menu._syncSettings) activeBar._menu._syncSettings();
});

// Level changed outside the extension's slider — on the site's native control
// (volume-lock.js) or on another site (volume-bridge.js): both already stored
// it, this side only follows.
const followStoredLevel = e => {
  const n = parseFloat(e.detail);
  if (!Number.isFinite(n)) return;
  volLockNorm = clamp01(n);
  sweepVolumes();
  if (activeBar && activeBar._syncVolume) activeBar._syncVolume();
};
document.addEventListener('vdrpb-volume-adopted', followStoredLevel, LIVE);
document.addEventListener('vdrpb-volume-shared', followStoredLevel, LIVE);

// Cross-tab sync: 'storage' fires in every OTHER same-origin tab (never the
// writer, so no loop) — follow volume-lock changes live.
window.addEventListener('storage', e => {
  if (!e || e.key !== VOL_KEY || e.newValue === null) return;
  const n = parseFloat(e.newValue);
  if (Number.isFinite(n)) {
    volLockNorm = clamp01(n);
    sweepVolumes();
    if (activeBar && activeBar._syncVolume) activeBar._syncVolume();
  }
}, LIVE);

// Stops this instance: listeners, loop, and the UI it created (a newer instance
// draws its own; downloads keep running in background.js).
const shutdown = () => {
  if (!alive) return;
  alive = false;
  lifetime.abort();
  try { removeActiveBar(); } catch {}
  try { for (const card of cardsById.values()) card.remove(); cardsById.clear(); } catch {}
  try { if (vdrpbStack) { vdrpbStack.remove(); vdrpbStack = null; } } catch {}
  try { if (uiPort) uiPort.disconnect(); } catch {}
  uiPort = null;
};
document.addEventListener('vdrpb-content-takeover', shutdown, { once: true });

let lastHref = window.location.href;
let lastTick = 0;
let lastOrphanSweep = 0;
const TICK_MS = 200;
const tick = ts => {
  if (!alive) return;
  // Detached from the extension (disabled, removed or updated): stop.
  if (!extensionAlive()) { shutdown(); return; }
  requestAnimationFrame(tick);   // re-armed first: an exception below must not stop the loop
  if (ts - lastTick < TICK_MS) return;
  lastTick = ts;
  try {

    if (window.location.href !== lastHref) {
      lastHref = window.location.href;
      lastNavShape = activeBar ? activeBar._isFullBar : null;
      removeActiveBar();
      urlSettleUntil = performance.now() + 400;   // let the new page's DOM mount before re-attaching
    }

    updateActiveVideoControlBar();

    // Self-heal a card stack the site detached (in-flight downloads must stay
    // visible and cancelable even between two card creations).
    if (vdrpbStack && !vdrpbStack.isConnected) uiHost().appendChild(vdrpbStack);

    if (ts - lastUpdatePoll > UPDATE_POLL_MS) { lastUpdatePoll = ts; maybeCheckUpdate(); }

    // Defensive: the single-bar invariant is otherwise enforced by activeBar;
    // sweep rarely in case a path ever leaks a detached-from-tracking bar.
    if (ts - lastOrphanSweep > 5000) {
      lastOrphanSweep = ts;
      document.querySelectorAll('.extension-control-bar').forEach(bar => { if (bar !== activeBar) bar.remove(); });
      // Some sites prune localStorage keys they do not own: keep the level stored.
      if (volLockNorm !== null) {
        try { if (localStorage.getItem(VOL_KEY) === null) localStorage.setItem(VOL_KEY, String(volLockNorm)); } catch {}
      }
    }

    if (activeBar) {
      const menu = activeBar._menu;
      const typing = !!(menu && menu._typing && menu._typing());
      const show = activeBar._hovered || typing || (performance.now() - lastMouseMoveTime <= 1500);
      const target = show ? '1' : '0';
      if (activeBar.style.opacity !== target) activeBar.style.opacity = target;
      // A faded bar never keeps its menu open for the next time it shows.
      if (!show && menu && menu._isOpen && menu._isOpen()) menu._hide();
    }
  } catch (e) {
    console.warn('[vdrpb] tick', e);
  }
};
requestAnimationFrame(tick);

})();
