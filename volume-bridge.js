// Shares the volume level between the five sites and their embedded players.
//
// Runs in the extension's isolated world at document_start, in every frame.
// Each origin keeps its level in its own localStorage (read synchronously by
// volume-lock.js in the page world); when "same volume on all sites" is on, the
// level is mirrored to chrome.storage.local ("volume") and written back into the
// localStorage of every other open site or frame.
//
// Local changes come from the extension's slider ('vdrpb-volume-set', dispatched
// after content.js stored the level) and from a site's native slider
// ('vdrpb-volume-adopted', dispatched by volume-lock.js). A shared change is
// applied by writing localStorage, setting the real volume of the frame's videos
// and dispatching 'vdrpb-volume-set' (volume-lock.js moves the site's native
// slider) and 'vdrpb-volume-shared' (content.js moves the extension's slider).
(() => {
  const KEY = 'extension_video_volume';
  const EPS = 0.0005;
  const WRITE_THROTTLE_MS = 150;
  const LOCAL_QUIET_MS = 500;

  let area = null;
  try { area = chrome.storage.local; } catch { return; }
  if (!area) return;

  const clamp01 = n => Math.max(0, Math.min(1, n));
  const readLocal = () => {
    try {
      const n = parseFloat(localStorage.getItem(KEY));
      return Number.isFinite(n) ? clamp01(n) : null;
    } catch { return null; }
  };

  let sameVolume = true;
  let shared = null;            // last value known to be in chrome.storage.local
  let lastLocalChange = -Infinity;
  let writeTimer = 0;
  let applying = false;

  const nativeVolume = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'volume');

  const applyShared = value => {
    if (!sameVolume || typeof value !== 'number' || !Number.isFinite(value)) return;
    const level = clamp01(value);
    shared = level;
    const local = readLocal();
    if (local !== null && Math.abs(local - level) < EPS) return;
    try { localStorage.setItem(KEY, String(level)); } catch { return; }
    applying = true;
    try {
      // Isolated world: this setter is the browser's own, so the value is the real volume.
      for (const v of document.querySelectorAll('video')) {
        try { if (Math.abs(nativeVolume.get.call(v) - level * level) > 0.0001) nativeVolume.set.call(v, level * level); } catch {}
      }
      document.dispatchEvent(new CustomEvent('vdrpb-volume-set'));
      document.dispatchEvent(new CustomEvent('vdrpb-volume-shared', { detail: String(level) }));
    } finally {
      applying = false;
    }
  };

  const flushWrite = () => {
    writeTimer = 0;
    if (!sameVolume) return;
    const level = readLocal();
    if (level === null || (shared !== null && Math.abs(shared - level) < EPS)) return;
    shared = level;
    try { area.set({ volume: level }, () => void chrome.runtime.lastError); } catch {}
  };
  const onLocalChange = () => {
    if (applying) return;
    lastLocalChange = performance.now();
    if (!writeTimer) writeTimer = setTimeout(flushWrite, WRITE_THROTTLE_MS);
  };
  document.addEventListener('vdrpb-volume-set', onLocalChange, true);
  document.addEventListener('vdrpb-volume-adopted', onLocalChange, true);

  try {
    area.get(['settings', 'volume'], r => {
      if (chrome.runtime.lastError || !r) return;
      sameVolume = !(r.settings && r.settings.sameVolume === false);
      if (!sameVolume) return;
      if (typeof r.volume === 'number' && Number.isFinite(r.volume)) {
        applyShared(r.volume);
      } else {
        const local = readLocal();
        if (local !== null) { shared = local; area.set({ volume: local }, () => void chrome.runtime.lastError); }
      }
    });
  } catch {}

  try {
    chrome.storage.onChanged.addListener((changes, name) => {
      if (name !== 'local') return;
      if (changes.settings) {
        const was = sameVolume;
        const s = changes.settings.newValue;
        sameVolume = !(s && s.sameVolume === false);
        if (sameVolume && !was) {
          try {
            area.get(['volume'], r => {
              if (chrome.runtime.lastError || !r) return;
              if (typeof r.volume === 'number') applyShared(r.volume);
              else flushWrite();
            });
          } catch {}
        }
      }
      if (changes.volume && typeof changes.volume.newValue === 'number') {
        // While the user is moving a slider in this frame, its own pending write wins.
        if (performance.now() - lastLocalChange < LOCAL_QUIET_MS) { shared = changes.volume.newValue; return; }
        applyShared(changes.volume.newValue);
      }
    });
  } catch {}
})();
