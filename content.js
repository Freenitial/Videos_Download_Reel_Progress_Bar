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

// ---------------------------------------------------------------------------
// One-time injected styles (switch toggles, notification fade, progress panel).
// Namespaced with vdrpb- so we never collide with the host page's CSS, and
// injected ONCE instead of per-menu.
// ---------------------------------------------------------------------------
const injectStyles = () => {
  if (document.getElementById('vdrpb-styles')) return;
  const style = document.createElement('style');
  style.id = 'vdrpb-styles';
  style.textContent = `
    @keyframes vdrpb-fadeout { to { opacity: 0; } }
    @keyframes vdrpb-indeterminate {
      0%   { transform: translateX(-100%); }
      100% { transform: translateX(400%); }
    }
    .vdrpb-switch { position: relative; display: inline-block; width: 40px; height: 20px; }
    .vdrpb-switch input { opacity: 0; width: 0; height: 0; }
    .vdrpb-slider {
      position: absolute; cursor: pointer; inset: 0;
      background-color: #ccc; transition: 0.4s; border-radius: 20px;
    }
    .vdrpb-switch input:checked + .vdrpb-slider { background-color: #3b82f6; }
    .vdrpb-slider:before {
      position: absolute; content: ""; height: 16px; width: 16px; left: 2px; bottom: 2px;
      background-color: white; transition: 0.4s; border-radius: 50%;
    }
    .vdrpb-switch input:checked + .vdrpb-slider:before { transform: translateX(20px); }
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
  (document.head || document.documentElement).appendChild(style);
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
  notification.className = 'vdrpb-notification';
  Object.assign(notification.style, {
    position: 'fixed', top: '20px', left: '50%', transform: 'translateX(-50%)',
    backgroundColor: isSuccess ? 'rgba(0, 128, 0, 0.9)' : 'rgba(200, 0, 0, 0.92)',
    color: 'white', padding: '12px 16px', borderRadius: '8px', zIndex: '2147483647',
    textAlign: 'center', maxWidth: '90%', boxShadow: '0 4px 12px rgba(0,0,0,0.35)',
    fontSize: '15px', fontFamily: "'Roboto', sans-serif", whiteSpace: 'pre-wrap'
  });
  const msgEl = document.createElement('div');
  renderMessageInto(msgEl, message);
  notification.appendChild(msgEl);
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
const STACK_POS_KEY = "vdrpb_stack_pos";
let vdrpbStack = null;

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
  let pos = null;
  try { pos = JSON.parse(localStorage.getItem(STACK_POS_KEY) || 'null'); } catch {}
  // Clamp the restored position to the CURRENT viewport (a smaller window/monitor
  // could otherwise leave the stack — and its drag grip — fully off-screen).
  const clampR = v => Math.max(4, Math.min(Math.max(4, window.innerWidth - 120), v));
  const clampB = v => Math.max(4, Math.min(Math.max(4, window.innerHeight - 40), v));
  stack.style.right = (pos && Number.isFinite(pos.right) ? clampR(pos.right) : 18) + 'px';
  stack.style.bottom = (pos && Number.isFinite(pos.bottom) ? clampB(pos.bottom) : 18) + 'px';

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
    cards.querySelectorAll('.vdrpb-card.ok, .vdrpb-card.err, .vdrpb-card.cxl').forEach(c => c.remove());
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
    try { localStorage.setItem(STACK_POS_KEY, JSON.stringify({ right: parseInt(stack.style.right), bottom: parseInt(stack.style.bottom) })); } catch {}
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

const COLLAPSE_KEY = 'vdrpb_collapsed';
const createDownloadCard = (sourceUrl, variant) => {
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
  // The stack scrolls past 78vh: make sure the user SEES that the click worked.
  card.scrollIntoView({ block: 'nearest' });
  if (stack._refreshGrip) stack._refreshGrip();

  let finished = false, curPct = 0, hadPct = false;
  let collapsed = localStorage.getItem(COLLAPSE_KEY) === '1';
  if (collapsed) { card.classList.add('collapsed'); collapseBtn.textContent = '▢'; collapseBtn.title = 'Expand'; }
  const startTime = Date.now();
  let elapsedTimer = setInterval(() => { if (!finished) sEl.v.textContent = fmtDuration((Date.now() - startTime) / 1000); }, 1000);

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
    clearInterval(elapsedTimer);
    if (dismissTimer) { clearTimeout(dismissTimer); dismissTimer = null; }
    card.remove();
    if (stack._refreshGrip) stack._refreshGrip();
    // Guard with vdrpbStack === stack: a stale timeout on an already-detached card
    // must NOT null out the global that now points at a newer, live stack.
    if (stack._cards.children.length === 0 && vdrpbStack === stack) { stack.remove(); vdrpbStack = null; }
  };
  // Hovering pauses auto-dismiss; leaving re-arms it (capped at 8s) so a
  // grazing cursor pass never eats a long error-reading window.
  const dismissAfter = ms => {
    const rearmMs = Math.min(ms, 8000);
    const arm = t => { if (dismissTimer) clearTimeout(dismissTimer); dismissTimer = setTimeout(remove, t); };
    arm(ms);
    card.addEventListener('mouseenter', () => { if (dismissTimer) { clearTimeout(dismissTimer); dismissTimer = null; } });
    card.addEventListener('mouseleave', () => arm(rearmMs));
  };

  collapseBtn.addEventListener('click', e => {
    e.stopPropagation(); collapsed = !collapsed;
    card.classList.toggle('collapsed', collapsed);
    collapseBtn.textContent = collapsed ? '▢' : '▁';
    collapseBtn.title = collapsed ? 'Expand' : 'Collapse';
    collapseBtn.setAttribute('aria-label', collapseBtn.title);
    try { localStorage.setItem(COLLAPSE_KEY, collapsed ? '1' : '0'); } catch {}
  });
  // Terminal states must never stay hidden in the collapsed pill (error text,
  // Open/Retry would be invisible) — auto-expand, and turn the cancel
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

  const controller = {
    card, get finished() { return finished; }, onCancel: null, onRetry: null,
    setQueued(q) {
      if (finished) return;
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
      if (m.title) {
        title.textContent = m.title;
        title.title = sourceUrl ? m.title + '\n' + sourceUrl : m.title;
      }
      const bits = [];
      if (m.uploader) bits.push(m.uploader);
      if (m.duration) bits.push(fmtDuration(m.duration));
      if (variant) bits.push(variant);   // two variants of the same video must stay tellable apart
      sub.textContent = bits.join(' · ');
      if (m.thumbnail) {
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
    success(msg) {
      if (finished) return; finished = true; clearInterval(elapsedTimer);
      expandIfCollapsed();
      card.classList.add('ok'); makeCloseButton();
      setStep(4); setPct(100);
      status.textContent = msg.message || 'Done.';
      stats.style.display = 'none'; sizeLine.textContent = '';
      if (msg.finalPath) {
        const mk = (label, type, primary) => {
          const b = document.createElement('button'); b.textContent = label; b.className = 'vdrpb-btn' + (primary ? ' vdrpb-btn-primary' : '');
          b.addEventListener('click', e => {
            e.stopPropagation();
            try {
              chrome.runtime.sendMessage({ type, finalPath: msg.finalPath }, r => {
                const ok = !chrome.runtime.lastError && r && r.success;
                if (type === 'COPY') { b.textContent = ok ? 'Copied' : 'Failed'; if (ok) b.disabled = true; setTimeout(() => { if (b.isConnected && !ok) b.textContent = label; }, 2000); }
                else if (ok) remove();
                else { b.textContent = 'Failed'; setTimeout(() => { if (b.isConnected) b.textContent = label; }, 2000); }
              });
            } catch {
              // Extension reloaded under a still-open card: the context is invalidated
              // and sendMessage throws synchronously.
              b.textContent = 'Failed';
              setTimeout(() => { if (b.isConnected) b.textContent = label; }, 2000);
            }
          });
          return b;
        };
        actions.append(mk('Open', 'SHOW', true), mk('Copy', 'COPY', false));
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
        const rb = document.createElement('button'); rb.textContent = 'Retry'; rb.className = 'vdrpb-btn vdrpb-btn-primary';
        rb.addEventListener('click', e => { e.stopPropagation(); const retry = controller.onRetry; remove(); retry(); });
        actions.appendChild(rb);
      }
      if (!o.cancelled) {
        const cb = document.createElement('button'); cb.textContent = "Copy error"; cb.className = 'vdrpb-btn';
        cb.addEventListener('click', e => {
          e.stopPropagation();
          const txt = message || '';
          const fallbackCopy = () => {
            const ta = document.createElement('textarea'); ta.value = txt;
            document.body.appendChild(ta); ta.select();
            let ok = false; try { ok = document.execCommand('copy'); } catch {}
            ta.remove(); return ok;
          };
          (navigator.clipboard && navigator.clipboard.writeText
            ? navigator.clipboard.writeText(txt).then(() => true, fallbackCopy)
            : Promise.resolve(fallbackCopy())
          ).then(ok => { cb.textContent = ok ? 'Copied' : 'Failed'; });
        });
        actions.appendChild(cb);
      }
      if (stack._refreshGrip) stack._refreshGrip();
      dismissAfter(o.cancelled ? 6000 : 30000);
    }
  };
  cancelBtn.addEventListener('click', e => {
    e.stopPropagation();
    if (finished) remove();                       // repurposed as "close" on terminal cards
    else if (controller.onCancel) controller.onCancel();
  });
  return controller;
};

// ---------------------------------------------------------------------------
// HARD VOLUME LOCK — enforce the user's chosen volume against the site.
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
  }, true));
sweepVolumes();
document.addEventListener('visibilitychange', () => { if (!document.hidden) sweepVolumes(); });

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
  const barW = controlBar._w || controlBar.offsetWidth;
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
  let newTop, newLeft;
  if (isFullBarFor(video)) {
    newTop = `${offY + rect.top - barH + 90}px`;
    newLeft = `${offX + rect.left + (rect.width / 2) - (barW / 2)}px`;
  } else {
    newTop = `${offY + rect.top + 60}px`;
    newLeft = `${offX + rect.left + 20}px`;
  }
  if (controlBar.style.top !== newTop || controlBar.style.left !== newLeft) {
    controlBar.style.top = newTop;
    controlBar.style.left = newLeft;
  }
};

// ---------------------------------------------------------------------------
// Start a download over a long-lived port and show live progress.
// - Dedup: the same url+options can only run once (double-click = focus the
//   existing card instead of two yt-dlp processes writing the same file).
// - Concurrency cap: at most 3 native host trees at once; extra downloads get
//   a visible "Queued…" card and start as slots free up.
// ---------------------------------------------------------------------------
const activeDownloads = new Map();     // dedup key -> card controller
const downloadQueue = [];              // starter closures waiting for a slot
let runningDownloads = 0;
const MAX_CONCURRENT_DL = 3;
const pumpDownloadQueue = () => {
  while (runningDownloads < MAX_CONCURRENT_DL && downloadQueue.length > 0) downloadQueue.shift()();
};

const startDownload = opts => {
  const targetUrl = opts.targetUrl || window.location.href;
  opts = { ...opts, targetUrl };

  // Mirror the host's Test-SafeUrl so a bad link fails HERE, not after a full
  // host spin-up; the domain boundary is anchored (facebook.com.evil.example
  // must not pass).
  const supported =
    /^https:\/\/(?:\w+\.)*(?:instagram\.com|facebook\.com|x\.com|tiktok\.com|youtube\.com)(?:[\/?#]|$)/.test(targetUrl);
  if (!supported || targetUrl.length >= 2048 || /[\s"'<>|^`\\]/.test(targetUrl)) {
    showNotification("Link not supported for download", false, 2500);
    return;
  }

  const key = `${targetUrl}|${!!opts.mp3}|${!!opts.isGIF}|${opts.cut || ''}|${!!opts.convertMP4}`;
  const existing = activeDownloads.get(key);
  if (existing && !existing.finished) {
    existing.card.scrollIntoView({ block: 'nearest' });
    existing.card.classList.add('flash');
    setTimeout(() => existing.card.classList.remove('flash'), 1200);
    return;
  }

  const variant = opts.mp3 ? 'MP3' : opts.isGIF ? 'GIF' : opts.cut ? 'Clip' : (opts.convertMP4 ? 'MP4' : null);
  const card = createDownloadCard(targetUrl, variant);
  activeDownloads.set(key, card);
  card.onRetry = () => startDownload(opts);

  let port = null, started = false, released = false, cancelledByUser = false;
  const finishCleanup = () => {
    if (released) return; released = true;
    if (activeDownloads.get(key) === card) activeDownloads.delete(key);
    if (started) { runningDownloads--; pumpDownloadQueue(); }
  };

  const begin = () => {
    started = true; runningDownloads++;
    if (card.finished) { finishCleanup(); return; }   // cancelled while queued (safety net)
    card.setQueued(false);

    try {
      port = chrome.runtime.connect({ name: "vdrpb-download" });
    } catch (e) {
      card.fail("Extension unavailable. Reload the page.", true);
      finishCleanup();
      return;
    }

    port.onMessage.addListener(msg => {
      if (!msg) return;
      if (msg.type === "meta") card.setMeta(msg);
      else if (msg.type === "progress") card.update(msg);
      else if (msg.type === "done") {
        if (msg.success) card.success(msg);
        else card.fail(msg.message || "Download failed.", true);
        try { port.disconnect(); } catch {}
        finishCleanup();
      }
    });
    // Unconditional: if the SW died / pipe broke mid-download and no terminal message
    // arrived, the card must not hang forever (do NOT depend on chrome.runtime.lastError).
    port.onDisconnect.addListener(() => {
      if (!card.finished && !cancelledByUser) {
        card.fail("Communication interrupted (the extension may have been reloaded). Try again.", true);
      }
      finishCleanup();
    });

    port.postMessage({
      type: "start",
      payload: {
        url: targetUrl,
        mp3: opts.mp3,
        isGIF: opts.isGIF,
        cut: opts.cut,
        convertMP4: opts.convertMP4,
        bipAtEnd: opts.bipAtEnd,
        copyAtEnd: opts.copyAtEnd,
        useChromeCookies: opts.useChromeCookies,
        keepConsoleOpen: opts.keepConsoleOpen
      }
    });
  };

  // Real cancel: disconnecting the port closes the native host's stdin, which the
  // host detects (EOF) and kills the yt-dlp/ffmpeg tree. A queued download just
  // leaves the queue.
  card.onCancel = () => {
    cancelledByUser = true;
    card.fail("Download cancelled.", true, { cancelled: true });
    if (port) { try { port.disconnect(); } catch {} }
    const qi = downloadQueue.indexOf(begin);
    if (qi >= 0) downloadQueue.splice(qi, 1);
    finishCleanup();
  };

  if (runningDownloads >= MAX_CONCURRENT_DL) {
    card.setQueued(true);
    downloadQueue.push(begin);
  } else {
    begin();
  }
};

// ---------------------------------------------------------------------------
// Download menu (buttons + CUT + options)
// ---------------------------------------------------------------------------
const createDownloadMenu = (video, signal) => {
  const menu = document.createElement('div');
  menu.classList.add('vdrpb-download-menu');
  Object.assign(menu.style, {
    display: 'none', flexDirection: 'column', gap: '10px', position: 'absolute',
    backgroundColor: 'rgba(0, 10, 15, 0.9)', borderRadius: '8px', padding: '10px',
    zIndex: '2147483647', fontFamily: "'Roboto', sans-serif", color: 'white'
  });
  menu.style.setProperty('box-sizing', 'border-box', 'important');

  const createTimeInput = () => {
    const input = document.createElement('input');
    input.type = 'text';
    Object.assign(input.style, { width: '80px', padding: '2px 4px', fontFamily: "'Roboto', sans-serif", color: 'black' });
    return input;
  };

  const buttonRow = document.createElement('div');
  Object.assign(buttonRow.style, { display: 'flex', gap: '10px', width: '100%' });

  const mkDownloadBtn = label => {
    const b = document.createElement('button');
    b.textContent = label;
    Object.assign(b.style, {
      flex: '1', cursor: 'pointer', border: 'none', backgroundColor: '#1E3A8A', color: 'white',
      fontWeight: 'bold', padding: '4px 6px', borderRadius: '4px', fontFamily: "'Roboto', sans-serif", textAlign: 'center'
    });
    b.addEventListener('mouseenter', () => b.style.backgroundColor = '#2563EB');
    b.addEventListener('mouseleave', () => b.style.backgroundColor = '#1E3A8A');
    return b;
  };
  const downloadVideoButton = mkDownloadBtn("Download video");
  const downloadMp3Button = mkDownloadBtn("Download as MP3");
  buttonRow.appendChild(downloadVideoButton);
  buttonRow.appendChild(downloadMp3Button);

  // CUT row
  const cutRow = document.createElement('div');
  Object.assign(cutRow.style, { display: 'flex', alignItems: 'center', gap: '8px', width: '100%' });

  const cutLabel = document.createElement('span');
  cutLabel.textContent = "CUT";
  Object.assign(cutLabel.style, { fontFamily: "'Roboto', sans-serif", fontSize: '14px', color: 'white' });

  const cutSwitch = document.createElement('label');
  cutSwitch.classList.add('vdrpb-switch');
  const cutCheckbox = document.createElement('input');
  cutCheckbox.type = 'checkbox';
  const cutSlider = document.createElement('span');
  cutSlider.classList.add('vdrpb-slider');
  cutSwitch.appendChild(cutCheckbox);
  cutSwitch.appendChild(cutSlider);

  const timeContainer = document.createElement('div');
  Object.assign(timeContainer.style, { display: 'flex', alignItems: 'center', gap: '5px', opacity: '0.5' });
  const startInput = createTimeInput();
  startInput.value = "00:00:00";
  startInput.readOnly = true;
  const endInput = createTimeInput();
  if (!isNaN(video.duration) && video.duration > 0) {
    endInput.value = formatTimeHMS(video.duration);
  } else {
    video.addEventListener('loadedmetadata', () => { endInput.value = formatTimeHMS(video.duration); }, { signal });
  }
  endInput.readOnly = true;
  const timeSeparator = document.createElement('span');
  timeSeparator.textContent = '-';
  Object.assign(timeSeparator.style, { color: 'grey', fontWeight: 'bold' });
  timeContainer.appendChild(startInput);
  timeContainer.appendChild(timeSeparator);
  timeContainer.appendChild(endInput);

  const enableCut = () => {
    cutCheckbox.checked = true;
    startInput.readOnly = false;
    endInput.readOnly = false;
    timeContainer.style.opacity = "1";
  };
  startInput.addEventListener('click', () => { if (!cutCheckbox.checked) enableCut(); });
  endInput.addEventListener('click', () => { if (!cutCheckbox.checked) enableCut(); });
  cutCheckbox.addEventListener('change', () => {
    if (cutCheckbox.checked) { enableCut(); }
    else { startInput.readOnly = true; endInput.readOnly = true; timeContainer.style.opacity = "0.5"; }
  });

  cutRow.appendChild(cutLabel);
  cutRow.appendChild(cutSwitch);
  cutRow.appendChild(timeContainer);

  // OPTIONS
  const optionsContainer = document.createElement('div');
  Object.assign(optionsContainer.style, { position: 'relative', marginLeft: 'auto' });
  const optionsButton = document.createElement('button');
  optionsButton.textContent = "OPTIONS";
  Object.assign(optionsButton.style, { cursor: 'pointer', border: 'none', background: 'none', color: 'white', fontFamily: "'Roboto', sans-serif" });
  optionsContainer.appendChild(optionsButton);

  const optionsMenu = document.createElement('div');
  optionsMenu.classList.add('vdrpb-options-menu');
  Object.assign(optionsMenu.style, {
    display: 'none', flexDirection: 'column', gap: '10px', position: 'absolute', top: '100%', right: '0',
    width: '265px', backgroundColor: 'rgba(0, 10, 15, 0.9)', borderRadius: '8px', padding: '10px',
    zIndex: '2147483647', fontFamily: "'Roboto', sans-serif", color: 'white', boxSizing: 'border-box'
  });

  const createOptionCheckbox = (labelText, localStorageKey, defaultValue) => {
    const optionRow = document.createElement('div');
    Object.assign(optionRow.style, { display: 'flex', alignItems: 'center', justifyContent: 'space-between', width: '100%' });
    const optionLabel = document.createElement('span');
    optionLabel.textContent = labelText;
    Object.assign(optionLabel.style, { fontFamily: "'Roboto', sans-serif", fontSize: '12px' });
    const optionSwitch = document.createElement('label');
    optionSwitch.classList.add('vdrpb-switch');
    const optionCheckbox = document.createElement('input');
    optionCheckbox.type = 'checkbox';
    let storedValue = localStorage.getItem(localStorageKey);
    if (storedValue === null) { storedValue = defaultValue ? "true" : "false"; localStorage.setItem(localStorageKey, storedValue); }
    optionCheckbox.checked = storedValue === "true";
    optionCheckbox.addEventListener('change', () => localStorage.setItem(localStorageKey, optionCheckbox.checked ? "true" : "false"));
    const optionSlider = document.createElement('span');
    optionSlider.classList.add('vdrpb-slider');
    optionSwitch.appendChild(optionCheckbox);
    optionSwitch.appendChild(optionSlider);
    optionRow.appendChild(optionLabel);
    optionRow.appendChild(optionSwitch);
    return { element: optionRow, checkbox: optionCheckbox };
  };

  const { element: convertMP4Option, checkbox: convertMP4Checkbox } = createOptionCheckbox("Convert video to MP4", "extension_convertMP4", false);
  const { element: bipAtEndOption, checkbox: bipAtEndCheckbox } = createOptionCheckbox("Beep when done", "extension_bipAtEnd", true);
  const { element: copyAtEndOption, checkbox: copyAtEndCheckbox } = createOptionCheckbox("Copy when done", "extension_copyAtEnd", false);
  const { element: keepConsoleOpenOption, checkbox: keepConsoleOpenCheckbox } = createOptionCheckbox("Debug (verbose logs)", "extension_keepConsoleOpen", false);
  const { element: useChromeCookiesOption, checkbox: useChromeCookiesCheckbox } = createOptionCheckbox("Use my cookies (private videos)", "extension_useChromeCookies", false);

  optionsMenu.appendChild(convertMP4Option);
  optionsMenu.appendChild(bipAtEndOption);
  optionsMenu.appendChild(copyAtEndOption);
  optionsMenu.appendChild(keepConsoleOpenOption);
  optionsMenu.appendChild(useChromeCookiesOption);
  // Hidden on purpose: yt-dlp can no longer read Chrome's app-bound-encrypted
  // cookies on Windows (Chrome >= 127) and Chrome is always open when the host
  // runs. Un-hide this line if/when yt-dlp regains Chrome cookie support.
  useChromeCookiesOption.style.display = 'none';

  optionsContainer.appendChild(optionsMenu);
  cutRow.appendChild(optionsContainer);

  let optionsHideTimeout;
  const showOptionsMenu = () => { clearTimeout(optionsHideTimeout); optionsMenu.style.display = 'flex'; };
  const hideOptionsMenu = () => {
    optionsHideTimeout = setTimeout(() => {
      if (!optionsMenu.matches(':hover') && !optionsButton.matches(':hover')) optionsMenu.style.display = 'none';
    }, 150);
  };
  optionsButton.addEventListener('mouseenter', () => { optionsButton.style.color = '#3b82f6'; showOptionsMenu(); });
  optionsButton.addEventListener('mouseleave', () => { optionsButton.style.color = 'white'; hideOptionsMenu(); });
  optionsMenu.addEventListener('mouseenter', () => { optionsButton.style.color = '#3b82f6'; showOptionsMenu(); });
  optionsMenu.addEventListener('mouseleave', () => { optionsButton.style.color = 'white'; hideOptionsMenu(); });

  menu.appendChild(buttonRow);
  menu.appendChild(cutRow);

  // Parse "H:M:S" / "M:S" / "S" into seconds, validating field ranges.
  const parseClock = val => {
    const parts = val.split(':').map(p => p.trim());
    if (parts.some(p => !/^\d+$/.test(p))) return null;
    const nums = parts.map(Number);
    if (nums.length > 3) return null;
    if (nums.length >= 2 && nums[nums.length - 1] > 59) return null;         // seconds field
    if (nums.length === 3 && nums[1] > 59) return null;                      // minutes field
    let s = 0;
    for (const n of nums) s = s * 60 + n;
    return s;
  };

  const getCutValue = () => {
    if (!cutCheckbox.checked) return null;
    const start = startInput.value.trim();
    const end = endInput.value.trim();
    const isEmpty = v => v === "" || v.toUpperCase() === "HH:MM:SS" || /^[0:]+$/.test(v);
    const sEmpty = isEmpty(start), eEmpty = isEmpty(end);
    const sSec = sEmpty ? 0 : parseClock(start);
    const eSec = eEmpty ? null : parseClock(end);
    if ((!sEmpty && sSec === null) || (!eEmpty && eSec === null)) {
      showNotification("Invalid range format (HH:MM:SS)", false, 2500);
      return null;
    }
    if (eSec !== null && sSec !== null && eSec <= sSec) {
      showNotification("Range end must be after start", false, 2500);
      return null;
    }
    if (sEmpty && eEmpty) return "*-";
    if (sEmpty && !eEmpty) return "*-" + end;
    if (!sEmpty && eEmpty) return "*" + start + "-";
    return "*" + start + "-" + end;
  };

  const launch = mp3 => {
    const cut = getCutValue();
    if (cutCheckbox.checked && !cut) return;
    // Read the download URL at CLICK time (the active video's URL is refreshed
    // continuously) so we never send a stale link from menu-creation time.
    // null (vs undefined) = known-unresolvable target: refuse instead of
    // shipping the feed URL to the host for a guaranteed failure.
    if (video._downloadUrl === null) {
      showNotification("Video link not found — open the post to download it", false, 3000);
      return;
    }
    const targetUrl = video._downloadUrl || window.location.href;
    startDownload({
      mp3,
      cut,
      convertMP4: mp3 ? false : convertMP4Checkbox.checked,
      bipAtEnd: bipAtEndCheckbox.checked,
      copyAtEnd: copyAtEndCheckbox.checked,
      useChromeCookies: useChromeCookiesCheckbox.checked,
      targetUrl,
      isGIF: mp3 ? false : !!video._isGIF,
      keepConsoleOpen: keepConsoleOpenCheckbox.checked
    });
  };

  downloadVideoButton.addEventListener('click', e => { e.stopPropagation(); launch(false); });
  downloadMp3Button.addEventListener('click', e => { e.stopPropagation(); launch(true); });

  return menu;
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
// Cached in localStorage (shared across tabs); the host is asked at most / 30 min.
// ---------------------------------------------------------------------------
let vdrpbUpdate = { available: false, latest: null, at: 0 };
try { const c = JSON.parse(localStorage.getItem('vdrpb_update') || 'null'); if (c) vdrpbUpdate = c; } catch {}
const UPDATE_POLL_MS = 60000;         // touch localStorage / maybe ask the host at most once a minute
let lastUpdatePoll = -UPDATE_POLL_MS; // negative so the FIRST tick polls immediately (not after 60s)
const UPDATE_TTL_MS  = 30 * 60000;    // re-ask the native host at most every 30 min

// Busy state is MODULE-level (bars/strips are destroyed on every navigation) AND
// mirrored in localStorage: the verdict is shared across tabs, so without a
// shared claim two tabs could each launch a concurrent setup.bat.
let updateLaunchedAt = 0;   // timestamp, NOT a boolean: the launching tab honors the same 2-min TTL as the others
const UPDATE_LAUNCH_KEY = 'vdrpb_update_launch';
const updateLaunchClaimed = () => {
  if (Date.now() - updateLaunchedAt < 120000) return true;
  try { return Date.now() - (parseInt(localStorage.getItem(UPDATE_LAUNCH_KEY)) || 0) < 120000; } catch { return false; }
};
const updateStripLabel = () => "⬆ Update extension" + (vdrpbUpdate.latest ? ' v' + vdrpbUpdate.latest : '');
const UPDATE_BUSY_LABEL = 'Updating… the browser will restart';
const makeUpdateStrip = () => {
  const s = document.createElement('button');
  s.className = 'vdrpb-update-strip';
  if (updateLaunchClaimed()) { s.classList.add('busy'); s.textContent = UPDATE_BUSY_LABEL; }
  else s.textContent = updateStripLabel();
  s.title = 'A new version is available';
  s.addEventListener('click', e => {
    e.stopPropagation();
    if (updateLaunchClaimed()) return;
    updateLaunchedAt = Date.now();
    try { localStorage.setItem(UPDATE_LAUNCH_KEY, String(Date.now())); } catch {}
    s.classList.add('busy');
    s.textContent = UPDATE_BUSY_LABEL;
    const resetStrip = () => {
      updateLaunchedAt = 0;
      try { localStorage.removeItem(UPDATE_LAUNCH_KEY); } catch {}
      if (s.isConnected) { s.classList.remove('busy'); s.textContent = updateStripLabel(); }
    };
    try {
      chrome.runtime.sendMessage({ type: 'DOUPDATE' }, r => {
        if (chrome.runtime.lastError || !r || !r.success) {
          resetStrip();
          showNotification((r && r.message) || 'Failed to launch the update.', false, 4000);
        }
      });
    } catch { resetStrip(); }
  });
  return s;
};

const refreshUpdateButtons = () => {
  const bar = activeBar;
  if (!bar) return;
  const avail = !!(vdrpbUpdate && vdrpbUpdate.available);
  const row = bar._controlsRow;
  let strip = bar.querySelector(':scope > .vdrpb-update-strip');
  if (avail && !strip && row) { strip = makeUpdateStrip(); bar.insertBefore(strip, row); }
  else if (!avail && strip)   { strip.remove(); strip = null; }
  if (strip) {
    // Self-heal the busy state (claim expired, or cleared by the launching tab
    // while we weren't looking) — runs on every 60s poll.
    const busy = updateLaunchClaimed();
    strip.classList.toggle('busy', busy);
    strip.textContent = busy ? UPDATE_BUSY_LABEL : updateStripLabel();
  }
  if (bar._video && bar._video.isConnected) updateControlBarPosition(bar._video, bar);   // re-anchor after the height change
};

const maybeCheckUpdate = () => {
  const now = Date.now();
  let cache = null;
  try { cache = JSON.parse(localStorage.getItem('vdrpb_update') || 'null'); } catch {}
  // Refresh strips on live bars even when the verdict came from another tab
  // (refreshUpdateButtons is idempotent).
  if (cache) { vdrpbUpdate = cache; refreshUpdateButtons(); }
  if (cache && (now - (cache.at || 0) < UPDATE_TTL_MS)) return;   // still fresh -> don't nag the host
  // Claim the check for ~2 min so N same-origin tabs don't all spawn a host.
  try { localStorage.setItem('vdrpb_update', JSON.stringify({ ...vdrpbUpdate, at: now - UPDATE_TTL_MS + 120000 })); } catch {}
  try {
    chrome.runtime.sendMessage({ type: 'CHECKUPDATE' }, r => {
      // success === false = host unreachable, NOT an authoritative "no update":
      // keep the 2-min claim so another tab retries soon instead of caching a
      // false negative for 30 min (which would also strip other tabs' banners).
      if (chrome.runtime.lastError || !r || r.success === false) return;
      vdrpbUpdate = { available: !!r.updateAvailable, latest: r.latest || null, at: Date.now() };
      try { localStorage.setItem('vdrpb_update', JSON.stringify(vdrpbUpdate)); } catch {}
      refreshUpdateButtons();
    });
  } catch {}
};

const makeSeparator = (marginPX = '10px') => {
  const sep = document.createElement('div');
  Object.assign(sep.style, { width: '1px', height: '20px', backgroundColor: 'grey', marginLeft: marginPX, marginRight: marginPX });
  return sep;
};

// Volume slider — present on BOTH bar variants: everywhere the lock is enforced
// there must be a visible control to change it (the site's own slider is
// overridden by the clamp).
const makeVolumeSlider = video => {
  const s = document.createElement('input');
  s.type = 'range'; s.min = 0; s.max = 1; s.step = 0.01;
  s.setAttribute('aria-label', 'Volume');
  Object.assign(s.style, { width: '80px', cursor: 'pointer' });
  s.value = clamp01((volLockNorm !== null) ? volLockNorm : (video.muted ? 0 : Math.sqrt(clamp01(video.volume))));
  // A site-muted video + lock > 0: a single CLICK on our slider (even without
  // moving it) is the explicit gesture that unmutes at the locked level — the
  // global clamp itself never unmutes.
  s.addEventListener('pointerdown', () => { if (volLockNorm !== null) applyUserVolume(video); });
  s.addEventListener('input', e => {
    e.stopPropagation();
    lockVolume(parseFloat(s.value));
    applyUserVolume(video);   // explicit gesture: allowed to mute/unmute THIS video
  });
  return s;
};

const createControlBar = video => {
  const ac = new AbortController();
  const signal = ac.signal;
  video._barAC = ac;

  const controlBar = document.createElement('div');
  controlBar.classList.add('extension-control-bar');
  Object.assign(controlBar.style, {
    position: 'absolute', backgroundColor: 'rgba(0, 10, 15, 0.8)', borderRadius: '8px', padding: '7px',
    display: 'flex', flexDirection: 'column', alignItems: 'stretch', gap: '5px', zIndex: '2147483647', pointerEvents: 'auto',
    transition: 'opacity 0.3s', opacity: '1', color: 'white', fontFamily: "'Roboto', sans-serif"
  });

  // Controls live in their own row so an "update available" strip can sit ABOVE them
  // (the bar grows a little to make room) without disturbing the compact layout.
  const controlsRow = document.createElement('div');
  Object.assign(controlsRow.style, { display: 'flex', alignItems: 'center', gap: '5px' });

  controlBar._isFullBar = isFullBarFor(video);   // shape snapshot for the SPA settle-skip
  if (controlBar._isFullBar) {
    const playPauseButton = document.createElement('button');
    playPauseButton.classList.add('play-pause-button');
    playPauseButton.textContent = video.paused ? "▶" : "❚❚";
    Object.assign(playPauseButton.style, { cursor: 'pointer', border: 'none', background: 'none', color: 'white', transition: 'color 0.3s', fontFamily: "'Roboto', sans-serif" });
    playPauseButton.addEventListener('mouseenter', () => playPauseButton.style.color = '#3b82f6');
    playPauseButton.addEventListener('mouseleave', () => playPauseButton.style.color = 'white');
    playPauseButton.addEventListener('click', e => { e.stopPropagation(); video.paused ? video.play() : video.pause(); });
    video.addEventListener('play', () => playPauseButton.textContent = "❚❚", { signal });
    video.addEventListener('pause', () => playPauseButton.textContent = "▶", { signal });

    const elapsedTime = document.createElement('span');
    elapsedTime.textContent = "00:00";
    Object.assign(elapsedTime.style, { fontFamily: "'Roboto', sans-serif", color: 'white' });

    const progressBar = document.createElement('input');
    progressBar.type = 'range'; progressBar.min = 0; progressBar.max = 100; progressBar.value = 0;
    Object.assign(progressBar.style, { flex: '1', cursor: 'pointer' });

    const totalTime = document.createElement('span');
    totalTime.textContent = "00:00";
    Object.assign(totalTime.style, { fontFamily: "'Roboto', sans-serif", color: 'white' });

    // Volume slider (hard-lock on first touch; global clamp enforces it everywhere)
    const volumeSlider = makeVolumeSlider(video);
    controlBar._volSlider = volumeSlider;

    const downloadMenu = createDownloadMenu(video, signal);
    Object.assign(downloadMenu.style, { position: 'absolute', top: '100%', left: '0', width: '100%', marginTop: '0px' });
    controlBar.appendChild(downloadMenu);

    let hideTimeout;
    const showDownloadMenu = () => { clearTimeout(hideTimeout); downloadMenu.style.display = 'flex'; };
    const hideDownloadMenu = () => {
      hideTimeout = setTimeout(() => {
        if (!downloadMenu.matches(':hover') && !downloadMenuButton.matches(':hover')) {
          downloadMenu.style.display = 'none';
          downloadMenuButton.style.color = 'white';
        }
      }, 150);
    };

    const downloadMenuButton = document.createElement('button');
    downloadMenuButton.classList.add('download-menu-button');
    downloadMenuButton.textContent = "⇩";
    Object.assign(downloadMenuButton.style, { cursor: 'pointer', border: 'none', background: 'none', color: 'white', fontFamily: "'Roboto', sans-serif" });
    downloadMenuButton.addEventListener('mouseenter', () => { downloadMenuButton.style.color = '#3b82f6'; showDownloadMenu(); });
    downloadMenuButton.addEventListener('mouseleave', hideDownloadMenu);
    // Keyboard/touch path (hover never fires there). e.detail === 0 = keyboard
    // activation, the only case allowed to CLOSE (a mouse click after hover
    // must not toggle the just-opened menu shut).
    downloadMenuButton.addEventListener('click', e => {
      e.stopPropagation();
      if (downloadMenu.style.display !== 'flex') showDownloadMenu();
      else if (e.detail === 0) downloadMenu.style.display = 'none';
    });
    downloadMenu.addEventListener('mouseenter', showDownloadMenu);
    downloadMenu.addEventListener('mouseleave', hideDownloadMenu);

    controlsRow.append(playPauseButton, elapsedTime, progressBar, totalTime, makeSeparator('5px'), volumeSlider, makeSeparator(), downloadMenuButton);

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
        if (!scrubbing && Math.abs(pct - lastPct) >= 0.1) { lastPct = pct; progressBar.value = pct; }
        const el = formatTime(video.currentTime);
        if (el !== lastElapsed) { lastElapsed = el; elapsedTime.textContent = el; }
        const tt = formatTime(video.duration);
        if (tt !== lastTotal) { lastTotal = tt; totalTime.textContent = tt; }
      }
      requestAnimationFrame(updateProgress);
    };
    updateProgress();
  } else {
    const downloadContainer = document.createElement('div');
    downloadContainer.style.position = 'relative';
    const downloadMenuButton = document.createElement('button');
    downloadMenuButton.classList.add('download-menu-button');
    downloadMenuButton.textContent = "⇩";
    Object.assign(downloadMenuButton.style, { cursor: 'pointer', border: 'none', background: 'none', color: 'white', fontFamily: "'Roboto', sans-serif" });
    downloadMenuButton.addEventListener('mouseenter', () => downloadMenuButton.style.color = '#3b82f6');
    downloadMenuButton.addEventListener('mouseleave', () => downloadMenuButton.style.color = 'white');
    const downloadMenu = createDownloadMenu(video, signal);
    downloadContainer.appendChild(downloadMenuButton);
    downloadContainer.appendChild(downloadMenu);
    let hideTimeout;
    const showDownloadMenu = () => { clearTimeout(hideTimeout); downloadMenu.style.display = 'flex'; };
    const hideDownloadMenu = () => {
      hideTimeout = setTimeout(() => {
        if (!downloadMenu.matches(':hover') && !downloadMenuButton.matches(':hover')) downloadMenu.style.display = 'none';
      }, 150);
    };
    downloadContainer.addEventListener('mouseenter', showDownloadMenu);
    downloadContainer.addEventListener('mouseleave', hideDownloadMenu);
    downloadMenuButton.addEventListener('click', e => {
      e.stopPropagation();
      if (downloadMenu.style.display !== 'flex') showDownloadMenu();
      else if (e.detail === 0) downloadMenu.style.display = 'none';
    });
    // The lock is enforced globally, so even the mini bar needs a visible way
    // to adjust it (the site's own volume UI is overridden by the clamp).
    const volumeSlider = makeVolumeSlider(video);
    controlBar._volSlider = volumeSlider;
    controlsRow.append(volumeSlider, makeSeparator('5px'), downloadContainer);
  }

  controlBar.appendChild(controlsRow);
  controlBar._controlsRow = controlsRow;
  // Surface a pending update immediately on this fresh bar (strip sits above the row).
  if (vdrpbUpdate && vdrpbUpdate.available) controlBar.insertBefore(makeUpdateStrip(), controlsRow);

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

const checkWebsiteVideoCompatibility = (website, videoElement) => {
  if (!videoElement) return { url: null, isGIF: false };

  if (website === "tiktok") {
    if (/^https:\/\/www\.tiktok\.com\/@([^\/]+)\/video\/(\d+)/.test(window.location.href)) {
      return { url: window.location.href, isGIF: false };
    }
  }

  if (website === "instagram") {
    // Permalink page (reel / post / tv): the page URL is the right target.
    if (/^https:\/\/(?:www\.)?instagram\.com\/(reel|reels|p|tv)\/[^\/]+/.test(window.location.href)) {
      return { url: window.location.href, isGIF: false };
    }
    // Feed: resolve the nearest post permalink from an ancestor link.
    let node = videoElement.parentElement, depth = 0;
    while (node && depth < 12) {
      const link = node.querySelector && node.querySelector('a[href*="/reel/"], a[href*="/reels/"], a[href*="/p/"], a[href*="/tv/"]');
      if (link) {
        const href = link.getAttribute('href') || '';
        const m = href.match(/\/(reel|reels|p|tv)\/([^\/?#]+)/);
        if (m) return { url: `https://www.instagram.com/${m[1]}/${m[2]}/`, isGIF: false };
      }
      node = node.parentElement; depth++;
    }
    return { url: null, isGIF: false };
  }

  if (website === "facebook") {
    let currentNode = videoElement.parentElement, depth = 0;
    while (currentNode && depth < 10) {
      if (currentNode.hasAttribute('data-video-id')) {
        return { url: `https://www.facebook.com/reel/${currentNode.getAttribute('data-video-id')}`, isGIF: false };
      }
      currentNode = currentNode.parentElement; depth++;
    }
  }

  const websiteSelectors = {
    facebook: { hooks: ['div[data-instancekey]', 'div[style*="height: calc"]'], linkSelector: 'a[href*="/watch/?v="], a[href*="/videos/"]' },
    twitter:  { ancestorSelector: 'article[data-testid="tweet"]', linkSelector: 'a[href*="/status/"]' },
    tiktok:   { ancestorSelector: 'article', linkSelector: 'a[href^="/@"]', idSelector: '[id^="xgwrapper-"]' }
  };
  const selectors = websiteSelectors[website];
  if (!selectors) return { url: null, isGIF: false };

  let commonAncestor = null;
  let currentElement = videoElement.parentElement;
  while (currentElement) {
    if (website === "facebook") {
      const hasHook = selectors.hooks.some(sel => currentElement.querySelector(sel));
      if (hasHook && currentElement.querySelector(selectors.linkSelector)) { commonAncestor = currentElement; break; }
    } else {
      if (currentElement.querySelector(selectors.ancestorSelector) && currentElement.querySelector(selectors.linkSelector)) { commonAncestor = currentElement; break; }
    }
    currentElement = currentElement.parentElement;
  }
  if (!commonAncestor) return { url: null, isGIF: false };

  const linkElement = commonAncestor.querySelector(selectors.linkSelector);
  if (!linkElement) return { url: null, isGIF: false };
  const href = linkElement.getAttribute('href');
  if (!href) return { url: null, isGIF: false };

  let url = null;
  if (website === "facebook") {
    let match = href.match(/\/watch\/\?v=(\d+)/);
    if (match) url = `https://www.facebook.com/watch/?v=${match[1]}`;
    match = href.match(/facebook\.com\/([^\/]+)\/videos\/(\d+)/);
    if (match) url = `https://www.facebook.com/${match[1]}/videos/${match[2]}`;
    return { url, isGIF: false };
  } else if (website === "twitter") {
    const match = href.match(/\/([^\/]+)\/status\/(\d+)/);
    if (match) url = `https://www.x.com/${match[1]}/status/${match[2]}`;
    // GIF badge: only an element whose text is EXACTLY "GIF" (not tweet text ending in "GIF").
    let isGIF = false;
    commonAncestor.querySelectorAll("span").forEach(span => {
      if (span.textContent.trim() === "GIF") isGIF = true;
    });
    return { url, isGIF };
  } else if (website === "tiktok") {
    const idElement = commonAncestor.querySelector(selectors.idSelector);
    const nameMatch = href.match(/^\/@([^/]+)/);
    const idMatch = idElement && idElement.id.match(/xgwrapper-\d+-(\d+)/);
    if (nameMatch && idMatch) url = `https://www.tiktok.com/@${nameMatch[1]}/video/${idMatch[1]}`;
    return { url, isGIF: false };
  }
  return { url: null, isGIF: false };
};

// After an SPA navigation the OLD page's video can survive for a few hundred ms
// and win the election while isFullBarFor already evaluates the NEW href —
// suppress bar creation briefly so the bar never attaches in the wrong shape.
// Same-shape navigations (shorts→shorts, tiktok swipe) skip the wait: the race
// is only visible cross-shape, and swipes are the highest-frequency gesture.
let urlSettleUntil = 0;
let lastNavShape = null;
const COMPAT_CACHE_MS = 1000;

const updateActiveVideoControlBar = () => {
  // Drop a bar whose element or video the site detached.
  if (activeBar && (!activeBar.isConnected || !activeBar._video || !activeBar._video.isConnected)) removeActiveBar();

  if (!/^https:\/\/(?:\w+\.)?(?:facebook\.com|instagram\.com|x\.com|tiktok\.com|youtube\.com\/(?:watch|shorts))/.test(window.location.href)) {
    removeActiveBar();
    return;
  }

  // Single pass: one querySelectorAll, one getBoundingClientRect per video,
  // reused for both the center test and the distance election.
  const viewportCenterX = window.innerWidth / 2;
  const viewportCenterY = window.innerHeight / 2;
  let activeVideo = null, minDistance = Infinity;
  document.querySelectorAll('video').forEach(video => {
    if (!video.isConnected) return;
    const rect = video.getBoundingClientRect();
    if (!isCenterInViewport(rect)) return;
    const dx = rect.left + rect.width / 2 - viewportCenterX;
    const dy = rect.top + rect.height / 2 - viewportCenterY;
    const distance = Math.hypot(dx, dy);
    if (distance < minDistance) { minDistance = distance; activeVideo = video; }
  });

  if (!activeVideo) { removeActiveBar(); return; }
  if (activeBar && activeBar._video !== activeVideo) removeActiveBar();

  let canProceed = true;
  if (["facebook", "twitter", "tiktok", "instagram"].includes(current_website)) {
    // The ancestor-walk resolution is pure DOM reading — memoize it per
    // (video, href) for 1s instead of re-walking 5x/sec. launch() re-reads
    // video._downloadUrl at click time, so 1s of staleness is harmless.
    const nowMs = performance.now();
    let cached = activeVideo._dlCache;
    if (!cached || cached.href !== window.location.href || nowMs - cached.at > COMPAT_CACHE_MS) {
      cached = { href: window.location.href, at: nowMs, info: checkWebsiteVideoCompatibility(current_website, activeVideo) };
      activeVideo._dlCache = cached;
    }
    const info = cached.info;
    if (info && info.url) {
      activeVideo._downloadUrl = info.url;
      activeVideo._isGIF = info.isGIF;
    } else if (current_website === "instagram" && /\/(reel|reels|p|tv|stories)\/[^\/?#]+/.test(window.location.pathname)) {
      // Instagram fallback: only on pages whose URL can actually resolve to a
      // video (permalinks incl. /{user}/p/... and stories). The feed root or
      // /explore would just spin up the host for a guaranteed yt-dlp failure.
      activeVideo._downloadUrl = window.location.href;
      activeVideo._isGIF = false;
    } else if (current_website === "instagram") {
      // Feed/explore with an unresolvable permalink: keep the playback/volume
      // bar, only the download target is unavailable (launch() refuses politely).
      activeVideo._downloadUrl = null;
      activeVideo._isGIF = false;
    } else {
      removeControlBar(activeVideo);
      canProceed = false;
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
document.addEventListener('mousemove', () => { lastMouseMoveTime = performance.now(); }, { passive: true });

window.addEventListener('resize', () => {
  if (activeBar && activeBar._video && activeBar._video.isConnected) updateControlBarPosition(activeBar._video, activeBar);
  // Re-clamp the card stack too: a persisted position from a bigger monitor
  // must not leave it (and its Cancel buttons) outside the shrunken viewport.
  if (vdrpbStack) {
    const r = parseInt(vdrpbStack.style.right) || 18, b = parseInt(vdrpbStack.style.bottom) || 18;
    vdrpbStack.style.right = Math.max(4, Math.min(Math.max(4, window.innerWidth - 120), r)) + 'px';
    vdrpbStack.style.bottom = Math.max(4, Math.min(Math.max(4, window.innerHeight - 40), b)) + 'px';
  }
});

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
});

// Cross-tab sync: 'storage' fires in every OTHER same-origin tab (never the
// writer, so no loop) — adopt volume-lock changes and update verdicts live.
window.addEventListener('storage', e => {
  if (!e) return;
  if (e.key === UPDATE_LAUNCH_KEY) {
    // BOTH directions: claim set (another tab launched the updater) -> busy;
    // claim removed (its DOUPDATE failed) -> restore the clickable strip.
    const strip = activeBar && activeBar.querySelector(':scope > .vdrpb-update-strip');
    if (strip) {
      const busy = e.newValue !== null;
      strip.classList.toggle('busy', busy);
      strip.textContent = busy ? UPDATE_BUSY_LABEL : updateStripLabel();
    }
    return;
  }
  if (e.newValue === null) return;
  if (e.key === VOL_KEY) {
    const n = parseFloat(e.newValue);
    if (Number.isFinite(n)) {
      volLockNorm = clamp01(n);
      sweepVolumes();
      if (activeBar && activeBar._volSlider) activeBar._volSlider.value = volLockNorm;
    }
  } else if (e.key === 'vdrpb_update') {
    try { const c = JSON.parse(e.newValue || 'null'); if (c) { vdrpbUpdate = c; refreshUpdateButtons(); } } catch {}
  }
});

let lastHref = window.location.href;
let lastTick = 0;
let lastOrphanSweep = 0;
const TICK_MS = 200;
const tick = ts => {
  if (ts - lastTick >= TICK_MS) {
    lastTick = ts;

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
    }

    if (activeBar) {
      const show = activeBar._hovered || (performance.now() - lastMouseMoveTime <= 1500);
      const target = show ? '1' : '0';
      if (activeBar.style.opacity !== target) activeBar.style.opacity = target;
    }
  }
  requestAnimationFrame(tick);
};
requestAnimationFrame(tick);

})();
