chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {

    const sendNativeMessage = (payload, messageSucces, extraData = {}) => {
        chrome.runtime.sendNativeMessage("freenitial_yt_dlp_host", payload, response => {
            if (chrome.runtime.lastError) {
                console.warn("[Background] Native messaging error:", chrome.runtime.lastError.message);
                sendResponse({ success: false, message: "Fail to communicate with module. Can be caused by ytdlp itself. Please install or update module :\nhttps://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download/setup.bat" });
                return;
            }
            if (response && response.success) {
                sendResponse({ success: true, message: messageSucces, ...extraData, ...(response.finalPath ? { finalPath: response.finalPath } : {}) });
            } else {
                sendResponse({ success: false, message: response?.message || "Unknown error" });
            }
        });
    };

    switch (request.type) {
        case "DOWNLOAD":
            sendNativeMessage(
                { url: request.videoUrl, mp3: request.mp3, isGIF: request.isGIF, cut: request.cut, convertMP4: request.convertMP4, bipAtEnd: request.bipAtEnd, copyAtEnd: request.copyAtEnd, useChromeCookies: request.useChromeCookies },
                "Download success"
            );
            return true;

        case "SHOW":
            sendNativeMessage(
                { show: request.finalPath },
                "Show success"
            );
            return true;

        case "COPY":
            sendNativeMessage(
                { copy: request.finalPath },
                "Copy success"
            );
            return true;

        default:
            return false;
    }
});
