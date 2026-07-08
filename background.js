const HOST = "freenitial_yt_dlp_host";
const INSTALL_URL = "https://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download/setup.bat";
const MODULE_ERR =
  "Failed to communicate with the module (it may also come from yt-dlp).\n" +
  "Install or update the module:\n" + INSTALL_URL;

// ---------------------------------------------------------------------------
// DOWNLOAD: long-lived port. connectNative keeps the MV3 service worker alive
// for the whole (possibly multi-minute) download and lets the native host
// stream progress messages back to the page. background.js just relays.
// ---------------------------------------------------------------------------
chrome.runtime.onConnect.addListener(port => {
  if (port.name !== "vdrpb-download") return;

  let nativePort = null;
  let done = false;

  const finish = message => {
    if (done) return;
    done = true;
    try { port.postMessage({ type: "done", success: false, message }); } catch (e) {}
  };

  port.onMessage.addListener(msg => {
    if (!msg || msg.type !== "start" || nativePort) return;

    try {
      nativePort = chrome.runtime.connectNative(HOST);
    } catch (e) {
      finish(MODULE_ERR);
      return;
    }

    nativePort.onMessage.addListener(m => {
      if (m && m.type === "done") done = true;
      try { port.postMessage(m); } catch (e) {}
    });

    nativePort.onDisconnect.addListener(() => {
      const err = chrome.runtime.lastError;
      finish(err ? MODULE_ERR : "The module stopped before the download finished.");
      try { port.disconnect(); } catch (e) {}
    });

    try {
      nativePort.postMessage(msg.payload);
    } catch (e) {
      finish(MODULE_ERR);
    }
  });

  port.onDisconnect.addListener(() => {
    if (nativePort) { try { nativePort.disconnect(); } catch (e) {} }
  });
});

// ---------------------------------------------------------------------------
// SHOW / COPY: quick one-shot request/response (no progress needed).
// ---------------------------------------------------------------------------
chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  const oneShot = (payload, okMsg) => {
    chrome.runtime.sendNativeMessage(HOST, payload, response => {
      if (chrome.runtime.lastError) {
        console.warn("[Background] Native messaging error:", chrome.runtime.lastError.message);
        sendResponse({ success: false, message: MODULE_ERR });
        return;
      }
      if (response && response.success) {
        // Forward the whole native response (finalPath, updateAvailable, latest, current, …),
        // only filling in a default message when the host didn't send one.
        sendResponse({ ...response, message: response.message || okMsg });
      } else {
        sendResponse({ success: false, message: (response && response.message) || "Unknown error" });
      }
    });
  };

  switch (request.type) {
    case "SHOW":
      oneShot({ show: request.finalPath }, "File revealed");
      return true;
    case "COPY":
      oneShot({ copy: request.finalPath }, "File copied");
      return true;
    case "CHECKUPDATE":
      oneShot({ checkUpdate: true }, "");
      return true;
    case "DOUPDATE":
      oneShot({ doUpdate: true }, "Update launched");
      return true;
    default:
      return false;
  }
});
