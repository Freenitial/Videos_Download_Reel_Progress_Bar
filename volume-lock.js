// Page-world volume layer, injected at document_start before any site script.
//
// Scale: the page reads and writes video.volume in the extension's slider scale.
// A value s written by the site plays at s^2 (the extension's loudness curve) and
// reads back as s, so every native volume slider shares the extension's curve and
// its position always equals the extension slider's position.
//
// Lock: once a level is stored, site writes are replaced by it synchronously, so
// the audio output never carries the site's own volume.
//
// Sync: the site's native volume control is set to the locked level, and a manual
// change made on that native control becomes the new locked level.
//
// The level is stored in localStorage by content.js (slider scale). content.js
// dispatches 'vdrpb-volume-set' on the video after a change on its own slider, and
// listens for 'vdrpb-volume-adopted' (detail = new level) when a native change is
// adopted here.
(() => {
  // Once per page: the extension also injects this file into tabs that were open
  // before it was installed or updated.
  const INSTALLED = Symbol.for('vdrpb.volumeLock');
  if (window[INSTALLED]) return;
  try { Object.defineProperty(window, INSTALLED, { value: true }); } catch {}

  const KEY = 'extension_video_volume';
  const EPS = 0.001;
  const REAL_EPS = 0.0001;
  const INPUT_WINDOW_MS = 500;
  const OWN_UI = '.extension-control-bar, .vdrpb-stack, .vdrpb-download-menu, .vdrpb-notification';
  const VOLUME_CONTROL = '[role="slider"], input[type="range"], [class*="volume" i], [aria-label*="volume" i]';

  const mediaProto = HTMLMediaElement.prototype;
  const desc = Object.getOwnPropertyDescriptor(mediaProto, 'volume');
  const nativePlay = mediaProto.play;
  if (!desc || !desc.get || !desc.set || typeof nativePlay !== 'function') return;
  const getVolume = desc.get;
  const setVolume = desc.set;
  const EventCtor = Event;
  const CustomEventCtor = CustomEvent;
  const clamp01 = n => Math.max(0, Math.min(1, n));

  const host = location.hostname;
  const site = /(^|\.)youtube\.com$/.test(host) ? 'youtube'
    : /(^|\.)tiktok\.com$/.test(host) ? 'tiktok'
    : /(^|\.)(facebook|instagram)\.com$/.test(host) ? 'meta'
    : 'generic';

  // Some sites prune localStorage keys they do not own: a level known to this
  // page is written back when it disappears.
  let lastLevel = null;
  const lockedLevel = () => {
    let stored = null;
    try { stored = localStorage.getItem(KEY); } catch { return lastLevel; }
    if (stored === null) {
      if (lastLevel !== null) { try { localStorage.setItem(KEY, String(lastLevel)); } catch {} }
      return lastLevel;
    }
    const n = parseFloat(stored);
    if (!Number.isFinite(n)) return lastLevel;
    lastLevel = clamp01(n);
    return lastLevel;
  };
  lockedLevel();

  // Last slider-scale value applied per element, so the getter returns exactly
  // what was written instead of a rounded square root.
  const scaled = new WeakMap();
  const setLevel = (video, level) => {
    setVolume.call(video, level * level);
    scaled.set(video, level);
  };
  const levelOf = video => {
    const real = getVolume.call(video);
    const s = scaled.get(video);
    if (s !== undefined && Math.abs(s * s - real) < 1e-9) return s;
    return Math.round(Math.sqrt(real) * 1e9) / 1e9;
  };

  const enforce = video => {
    const level = lockedLevel();
    if (level !== null && Math.abs(getVolume.call(video) - level * level) > REAL_EPS) setLevel(video, level);
  };

  // ---------------------------------------------------------------------------
  // Trusted user input. For presses and drags the target is the element the
  // press started on, so a drag that leaves the slider keeps its origin.
  // ---------------------------------------------------------------------------
  let lastInputAt = -Infinity;
  let lastInputType = '';
  let lastInputKey = '';
  let lastInputTarget = null;
  let pressTarget = null;
  const PRESS = new Set(['pointerdown', 'mousedown', 'touchstart']);
  const FOLLOW = new Set(['pointermove', 'mousemove', 'touchmove', 'pointerup', 'mouseup', 'touchend', 'click']);
  const onUserInput = e => {
    if (!e.isTrusted) return;
    const type = e.type;
    if ((type === 'pointermove' || type === 'mousemove') && !e.buttons) return;
    if (PRESS.has(type)) pressTarget = e.target;
    const target = FOLLOW.has(type) && pressTarget ? pressTarget : e.target;
    if (target instanceof Element && target.closest(OWN_UI)) {
      lastInputAt = -Infinity;
      lastInputTarget = null;
      return;
    }
    lastInputAt = performance.now();
    lastInputType = type;
    lastInputKey = type === 'keydown' ? e.key : '';
    lastInputTarget = target;
  };
  for (const type of ['pointerdown', 'pointermove', 'pointerup', 'mousedown', 'mousemove', 'mouseup', 'click', 'keydown', 'wheel', 'touchstart', 'touchmove', 'touchend']) {
    window.addEventListener(type, onUserInput, { capture: true, passive: true });
  }
  const recentUserInput = () => performance.now() - lastInputAt < INPUT_WINDOW_MS;

  // A site write counts as a manual change when the user is operating a
  // volume-like control that belongs to the same player as the video.
  const nativeVolumeGesture = video => {
    if (!recentUserInput() || lastInputType === 'keydown') return false;
    const t = lastInputTarget;
    if (!(t instanceof Element) || !t.closest(VOLUME_CONTROL)) return false;
    let a = video.parentElement;
    for (let i = 0; a && i < 15 && !a.contains(t); i++) a = a.parentElement;
    if (!a || !a.contains(t)) return false;
    const vr = video.getBoundingClientRect();
    const ar = a.getBoundingClientRect();
    return ar.width * ar.height <= Math.max(1, vr.width * vr.height) * 3;
  };

  const adopt = (level, source) => {
    level = clamp01(level);
    try { localStorage.setItem(KEY, String(level)); } catch { return; }
    lastLevel = level;
    const real = level * level;
    if (source) setLevel(source, level);
    for (const v of document.querySelectorAll('video')) {
      if (Math.abs(getVolume.call(v) - real) > REAL_EPS) setLevel(v, level);
    }
    document.dispatchEvent(new CustomEventCtor('vdrpb-volume-adopted', { detail: String(level) }));
  };

  // When a site write is absorbed without changing the real value, no native
  // volumechange fires and a site whose UI follows the element would keep
  // showing its own value. One event per distinct absorbed value per element
  // (at most every 250 ms) lets it re-read the volume, without looping on a site
  // that re-applies its value on every volumechange.
  const pending = new WeakSet();
  const pendingValue = new WeakMap();
  const lastNotify = new WeakMap();
  const notifiedValue = new WeakMap();
  const notify = (video, requested) => {
    if (pending.has(video)) { pendingValue.set(video, requested); return; }
    if (notifiedValue.get(video) === requested) return;
    pendingValue.set(video, requested);
    pending.add(video);
    const wait = Math.max(0, 250 - (performance.now() - (lastNotify.get(video) ?? -Infinity)));
    setTimeout(() => {
      pending.delete(video);
      notifiedValue.set(video, pendingValue.get(video));
      lastNotify.set(video, performance.now());
      video.dispatchEvent(new EventCtor('volumechange'));
    }, wait);
  };

  // ---------------------------------------------------------------------------
  // React internals (TikTok, Facebook, Instagram)
  // ---------------------------------------------------------------------------
  const SKIP_KEYS = new Set(['_owner', '_store', 'return', 'child', 'sibling', 'alternate', 'stateNode', 'children']);
  const findIn = (obj, match, depth, seen) => {
    if (!obj || typeof obj !== 'object' || seen.has(obj) || obj instanceof Node) return null;
    seen.add(obj);
    try { if (match(obj)) return obj; } catch { return null; }
    if (depth <= 0) return null;
    let keys;
    try { keys = Object.keys(obj); } catch { return null; }
    if (keys.length > 150) return null;
    for (const k of keys) {
      if (SKIP_KEYS.has(k)) continue;
      let val;
      try { val = obj[k]; } catch { continue; }
      if (val && typeof val === 'object') {
        const r = findIn(val, match, depth - 1, seen);
        if (r) return r;
      }
    }
    return null;
  };
  const findUp = (fiber, match, levels) => {
    for (let i = 0; fiber && i < levels; i++, fiber = fiber.return) {
      const seen = new WeakSet();
      let r = findIn(fiber.memoizedProps, match, 3, seen);
      if (r) return r;
      for (let h = fiber.memoizedState, j = 0; h && typeof h === 'object' && j < 50; h = h.next, j++) {
        r = findIn(h.memoizedState, match, 3, seen);
        if (r) return r;
      }
    }
    return null;
  };
  const fiberOf = el => {
    const k = Object.keys(el).find(x => x.startsWith('__reactFiber$'));
    return k ? el[k] : null;
  };

  // ---------------------------------------------------------------------------
  // Site adapters. reflect(level, gestureVideo) pushes the level into the site's
  // own volume state; attach(videos, level) runs when videos start loading or
  // playing. Mute state is only pushed for the video the gesture targeted.
  // ---------------------------------------------------------------------------
  let reflecting = 0;

  // YouTube Music keeps its volume slider in the page's player bar, outside the
  // video player, and uses "-" / "=" as volume keys.
  const ytMusic = host === 'music.youtube.com';
  const YT_MUSIC_VOLUME = '#volume-slider, #expand-volume-slider, ytmusic-player-bar [class*="volume" i], ytmusic-player-bar [aria-label*="volume" i]';

  const youtube = {
    adoptsWrites: false,
    hooked: new WeakSet(),
    isPlayer: p => !!p && typeof p.setVolume === 'function' && typeof p.getVolume === 'function' && typeof p.isMuted === 'function',
    hook(p) {
      if (this.hooked.has(p)) return;
      this.hooked.add(p);
      try {
        p.addEventListener('onVolumeChange', data => {
          // The player also reports its stored volume whenever a video loads, so
          // only the volume shortcuts and the player's own volume control count.
          if (reflecting || !data || !recentUserInput()) return;
          const t = lastInputTarget;
          const byUser = lastInputType === 'keydown'
            ? (lastInputKey === 'ArrowUp' || lastInputKey === 'ArrowDown' || (ytMusic && (lastInputKey === '-' || lastInputKey === '=' || lastInputKey === '+')))
            : (t instanceof Element && (
                (p.contains(t) && !!t.closest(VOLUME_CONTROL)) ||
                (ytMusic && !t.closest(OWN_UI) && !!t.closest(YT_MUSIC_VOLUME))));
          if (!byUser) return;
          const level = clamp01(Number(data.volume) / 100);
          if (!Number.isFinite(level)) return;
          const current = lockedLevel();
          if (current !== null && Math.round(current * 100) === Math.round(level * 100)) return;
          adopt(level, null);
        });
      } catch {}
    },
    push(p, level, gesture) {
      this.hook(p);
      if (level === null) return;
      const target = Math.round(level * 100);
      if (p.getVolume() !== target) p.setVolume(target);
      if (gesture) {
        if (level > 0 && p.isMuted()) p.unMute();
        else if (level <= 0 && !p.isMuted()) p.mute();
      }
    },
    reflect(level, gestureVideo) {
      for (const p of document.querySelectorAll('.html5-video-player')) {
        if (!this.isPlayer(p)) continue;
        try { this.push(p, level, !!gestureVideo && p.contains(gestureVideo)); } catch {}
      }
    },
    attach(videos, level) {
      for (const v of videos) {
        const p = v.closest('.html5-video-player');
        if (!this.isPlayer(p)) continue;
        try { this.push(p, level, false); } catch {}
      }
    }
  };

  const tiktok = {
    adoptsWrites: true,
    store: null,
    lastSearch: -Infinity,
    isStore: o => typeof o.setVolume === 'function' && typeof o.setMute === 'function',
    findStore() {
      if (this.store) return this.store;
      const now = performance.now();
      if (now - this.lastSearch < 1000) return null;
      this.lastSearch = now;
      const candidates = [...document.querySelectorAll('[class*="VolumeControl"]'), ...document.querySelectorAll(VOLUME_CONTROL)];
      for (const el of candidates.slice(0, 40)) {
        const f = fiberOf(el);
        const s = f && findUp(f, this.isStore, 20);
        if (s) return (this.store = s);
      }
      return null;
    },
    reflect(level, gestureVideo) {
      if (level === null) return;
      const s = this.findStore();
      if (!s) return;
      try {
        s.setVolume(level);
        if (gestureVideo) s.setMute(level <= 0);
      } catch { this.store = null; }
    },
    attach(videos, level) { this.reflect(level, null); }
  };

  const meta = {
    adoptsWrites: true,
    apis: new WeakMap(),
    misses: new WeakMap(),
    roots: [],
    lastRootScan: -Infinity,
    lastTraverse: -Infinity,
    retryTimer: 0,
    isApi: o => typeof o.setVolume === 'function' && typeof o.getCurrentState === 'function' && typeof o.setMuted === 'function',
    hasContainerKey: el => Object.keys(el).some(k => k.startsWith('__reactContainer$')),
    containers() {
      this.roots = this.roots.filter(c => c.isConnected);
      if (this.roots.length || !document.body) return this.roots;
      const now = performance.now();
      if (now - this.lastRootScan < 5000) return this.roots;
      this.lastRootScan = now;
      const walk = (el, depth) => {
        for (const c of el.children) {
          if (this.hasContainerKey(c)) this.roots.push(c);
          else if (depth > 0) walk(c, depth - 1);
        }
      };
      walk(document.body, 4);
      return this.roots;
    },
    // Depth-first walk of every React tree on the page; visit() returns true to stop.
    walk(visit) {
      for (const c of this.containers()) {
        const k = Object.keys(c).find(x => x.startsWith('__reactContainer$'));
        const hostRoot = k && c[k];
        const start = (hostRoot && hostRoot.stateNode && hostRoot.stateNode.current) || hostRoot;
        const stack = start ? [start] : [];
        let visited = 0;
        while (stack.length && visited < 300000) {
          const f = stack.pop();
          visited++;
          if (visit(f)) return;
          if (f.sibling) stack.push(f.sibling);
          if (f.child) stack.push(f.child);
        }
      }
    },
    traverse(videos, out) {
      const wanted = new Set(videos);
      this.walk(f => {
        if (f.stateNode && wanted.has(f.stateNode)) { out.set(f.stateNode, f); wanted.delete(f.stateNode); }
        return wanted.size === 0;
      });
    },
    // Facebook keeps a page-wide volume context ({ volume, setVolume }) above the
    // players; its native slider reads it and pushes it into each player.
    contexts: [],
    lastContextScan: -Infinity,
    isVolumeContext: v => {
      try { return !!v && typeof v === 'object' && typeof v.setVolume === 'function' && typeof v.volume === 'number'; } catch { return false; }
    },
    pushContexts(level) {
      const now = performance.now();
      if (now - this.lastContextScan >= 1000) {
        this.lastContextScan = now;
        const found = [];
        this.walk(f => {
          const p = f.memoizedProps;
          if (p && typeof p === 'object' && this.isVolumeContext(p.value)) found.push(f);
          return false;
        });
        this.contexts = found;
      }
      for (const f of this.contexts) {
        const v = f.memoizedProps && f.memoizedProps.value;
        if (this.isVolumeContext(v)) { try { v.setVolume(level); } catch {} }
      }
    },
    resolve(videos) {
      const todo = videos.filter(v => v.isConnected && !this.apis.has(v) && (this.misses.get(v) || 0) < 3);
      if (!todo.length) return;
      const fibers = new Map();
      for (const v of todo) { const f = fiberOf(v); if (f) fibers.set(v, f); }
      const missing = todo.filter(v => !fibers.has(v));
      let searched = todo.filter(v => fibers.has(v));
      if (missing.length) {
        const now = performance.now();
        if (now - this.lastTraverse >= 500) {
          this.lastTraverse = now;
          this.traverse(missing, fibers);
          searched = todo;
        } else {
          this.scheduleRetry();
        }
      }
      for (const v of searched) {
        const f = fibers.get(v);
        const api = f && findUp(f, this.isApi, 30);
        if (api) this.apis.set(v, api);
        else this.misses.set(v, (this.misses.get(v) || 0) + 1);
      }
    },
    scheduleRetry() {
      if (this.retryTimer) return;
      this.retryTimer = setTimeout(() => {
        this.retryTimer = 0;
        reflecting++;
        try { this.reflect(lockedLevel(), null); } catch {} finally { reflecting--; }
      }, 700);
    },
    push(api, level, gesture) {
      const st = api.getCurrentState();
      if (!st) return;
      if (typeof st.volume === 'number' && Math.abs(st.volume - level) > EPS) api.setVolume(level);
      if (gesture) {
        if (level > 0 && st.muted) api.setMuted(false, 'user_initiated');
        else if (level <= 0 && !st.muted) api.setMuted(true, 'user_initiated');
      }
    },
    reflect(level, gestureVideo) {
      if (level === null) return;
      this.pushContexts(level);
      const videos = [...document.querySelectorAll('video')];
      this.resolve(videos);
      for (const v of videos) {
        const api = this.apis.get(v);
        if (api) { try { this.push(api, level, v === gestureVideo); } catch { this.apis.delete(v); } }
      }
    },
    attach(videos, level) {
      if (level === null) return;
      this.pushContexts(level);
      this.resolve(videos);
      let unresolved = false;
      for (const v of videos) {
        const api = this.apis.get(v);
        if (api) { try { this.push(api, level, false); } catch { this.apis.delete(v); } }
        else if ((this.misses.get(v) || 0) < 3) unresolved = true;
      }
      if (unresolved) this.scheduleRetry();
    }
  };

  const generic = { adoptsWrites: true, reflect() {}, attach() {} };

  const adapter = site === 'youtube' ? youtube : site === 'tiktok' ? tiktok : site === 'meta' ? meta : generic;

  let reflectQueued = false;
  let reflectGesture = null;
  const scheduleReflect = gestureVideo => {
    if (gestureVideo) reflectGesture = gestureVideo;
    if (reflectQueued) return;
    reflectQueued = true;
    requestAnimationFrame(() => {
      reflectQueued = false;
      const gv = reflectGesture;
      reflectGesture = null;
      const level = lockedLevel();
      if (level === null) return;
      reflecting++;
      try { adapter.reflect(level, gv); } catch {} finally { reflecting--; }
    });
  };

  const attachQueue = new Set();
  let attachTimer = 0;
  const scheduleAttach = video => {
    attachQueue.add(video);
    if (attachTimer) return;
    attachTimer = setTimeout(() => {
      attachTimer = 0;
      const videos = [...attachQueue];
      attachQueue.clear();
      reflecting++;
      try { adapter.attach(videos, lockedLevel()); } catch {} finally { reflecting--; }
    }, 0);
  };

  // ---------------------------------------------------------------------------
  // Property and method overrides
  // ---------------------------------------------------------------------------
  Object.defineProperty(HTMLVideoElement.prototype, 'volume', {
    configurable: true,
    enumerable: desc.enumerable,
    get() { return levelOf(this); },
    set(value) {
      const requested = Number(value);
      if (!(requested >= 0 && requested <= 1)) return setVolume.call(this, value);
      const level = lockedLevel();
      if (adapter.adoptsWrites && !reflecting
          && (level === null || Math.abs(requested - level) > EPS)
          && nativeVolumeGesture(this)) {
        adopt(requested, this);
        return;
      }
      if (level === null) { setLevel(this, requested); return; }
      if (Math.abs(getVolume.call(this) - level * level) > REAL_EPS) setLevel(this, level);
      else if (Math.abs(requested - level) > EPS) notify(this, requested);
    }
  });

  Object.defineProperty(HTMLVideoElement.prototype, 'play', {
    configurable: true,
    enumerable: false,
    writable: true,
    value: function play() {
      try { enforce(this); } catch {}
      return nativePlay.apply(this, arguments);
    }
  });

  for (const type of ['loadstart', 'play']) {
    window.addEventListener(type, e => {
      const t = e.target;
      if (!(t instanceof HTMLVideoElement)) return;
      try { enforce(t); } catch {}
      scheduleAttach(t);
    }, true);
  }

  document.addEventListener('vdrpb-volume-set', e => {
    const t = e.target;
    scheduleReflect(t instanceof HTMLVideoElement ? t : null);
  }, true);

  // The level changed in another tab of this origin. lastLevel is updated at once
  // (the reflect waits for a frame, and background tabs get none) so a later
  // write-back after a prune restores the new level, not the old one.
  window.addEventListener('storage', e => {
    if (e.key !== KEY || e.newValue === null) return;
    const n = parseFloat(e.newValue);
    if (Number.isFinite(n)) lastLevel = clamp01(n);
    scheduleReflect(null);
  });
})();
