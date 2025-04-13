(() => {

const knownWebsite = window.location.href.match(/^https:\/\/(?:\w+\.)?(facebook\.com|x\.com|youtube\.com|instagram\.com|tiktok\.com)/);
let current_website = knownWebsite ? (
  knownWebsite[1] === "facebook.com"   ? "facebook"  :
  knownWebsite[1] === "x.com"          ? "twitter"   :
  knownWebsite[1] === "youtube.com"    ? "youtube"   :
  knownWebsite[1] === "tiktok.com"     ? "tiktok"   :
  knownWebsite[1] === "instagram.com"  ? "instagram" : "unknown"
) : "unknown";

// Intercept History API to detect URL changes
(() => {
  const pushState = history.pushState;
  const replaceState = history.replaceState;
  history.pushState = function(...args) {
    const result = pushState.apply(history, args);
    window.dispatchEvent(new Event('locationchange'));
    return result;
  };
  history.replaceState = function(...args) {
    const result = replaceState.apply(history, args);
    window.dispatchEvent(new Event('locationchange'));
    return result;
  };
  window.addEventListener('popstate', () => {
    window.dispatchEvent(new Event('locationchange'));
  });
})();

// Display notification on screen
const showNotification = (message, isSuccess = true, duration = 2500, finalPath = null) => {
  // Remove any existing notifications first
  document.querySelectorAll('.extension-notification').forEach(n => n.remove());

  const notification = document.createElement('div');
  notification.className = 'extension-notification';

  // Base styles
  Object.assign(notification.style, {
    position: 'fixed',
    top: '50%',
    left: '50%',
    transform: 'translate(-50%, -50%)',
    backgroundColor: isSuccess ? 'rgba(0, 128, 0, 0.8)' : 'rgba(255, 0, 0, 0.8)',
    color: 'white',
    padding: '15px',
    borderRadius: '8px',
    zIndex: '9999999',
    textAlign: 'center',
    maxWidth: '90%',
    boxShadow: '0 4px 8px rgba(0, 0, 0, 0.3)',
    fontSize: '16px',
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    gap: '10px',
    whiteSpace: 'pre-wrap'
  });

  // Message element
  const messageElement = document.createElement('div');
  messageElement.innerHTML = message.replace(/\n/g, '<br>').replace(/(https?:\/\/[^\s]+)/g, '<a href="$1" target="_blank">$1</a>');
  notification.appendChild(messageElement);

  let effectiveDuration = duration;

  // Add buttons only if download was successful and finalPath is provided
  if (isSuccess && finalPath !== null) {
    effectiveDuration = 10000;

    const buttonContainer = document.createElement('div');
    Object.assign(buttonContainer.style, {
      display: 'flex',
      gap: '10px',
      marginTop: '5px'
    });

    // Common button styles
    const buttonBaseStyle = {
      padding: '5px 10px',
      border: 'none',
      borderRadius: '4px',
      color: 'black',
      backgroundColor: 'rgba(255, 255, 255, 0.85)',
      cursor: 'pointer',
      fontSize: '14px',
      transition: 'background-color 0.2s ease'
    };

    // Show Button
    const showButton = document.createElement('button');
    showButton.textContent = 'Show';
    Object.assign(showButton.style, buttonBaseStyle);
    showButton.addEventListener('mouseover', () => showButton.style.backgroundColor = 'rgba(230, 230, 230, 0.85)');
    showButton.addEventListener('mouseout', () => showButton.style.backgroundColor = 'rgba(255, 255, 255, 0.85)');
    showButton.addEventListener('click', (e) => {
      e.stopPropagation(); // Prevent click from propagating
      chrome.runtime.sendMessage({ type: "SHOW", finalPath: finalPath }, response => {
        if (chrome.runtime.lastError) {
          console.warn("[Extension] Show Error:", chrome.runtime.lastError);
        }
      });
      notification.remove();
    });

    // Copy Button
    const copyButton = document.createElement('button');
    copyButton.textContent = 'Copy File';
    Object.assign(copyButton.style, buttonBaseStyle);
    copyButton.addEventListener('mouseover', () => copyButton.style.backgroundColor = 'rgba(230, 230, 230, 0.85)');
    copyButton.addEventListener('mouseout', () => copyButton.style.backgroundColor = 'rgba(255, 255, 255, 0.85)');
    copyButton.addEventListener('click', (e) => {
      e.stopPropagation(); // Prevent click from propagating
      chrome.runtime.sendMessage({ type: "COPY", finalPath: finalPath }, response => {
        if (chrome.runtime.lastError) {
          console.warn("[Extension] Copy Error:", chrome.runtime.lastError);
          copyButton.textContent = 'Error!';
          copyButton.style.backgroundColor = 'rgba(255, 150, 150, 0.85)';
        } else if (response && response.success) {
          copyButton.textContent = 'Copied!';
          copyButton.disabled = true;
          copyButton.style.backgroundColor = 'rgba(150, 255, 150, 0.85)';
        } else {
          copyButton.textContent = 'Failed!';
            copyButton.style.backgroundColor = 'rgba(255, 150, 150, 0.85)';
        }
        // Reset button state after a short delay
        setTimeout(() => {
          if (copyButton.isConnected) { // Check if button still exists
            copyButton.textContent = 'Copy File';
            copyButton.disabled = false;
              copyButton.style.backgroundColor = 'rgba(255, 255, 255, 0.85)';
          }
        }, 2000);
      });
    });

    buttonContainer.appendChild(showButton);
    buttonContainer.appendChild(copyButton);
    notification.appendChild(buttonContainer);
  }

  // Apply fadeOut animation and removal timeout
  if (effectiveDuration > 0) {
    notification.style.animation = `fadeOut 0.3s ${effectiveDuration}ms forwards`;
    setTimeout(() => notification.remove(), effectiveDuration + 300); 
  }

  document.body.appendChild(notification);
  return notification;
};

const formatTime = time => {
  const minutes = Math.floor(time / 60);
  const seconds = Math.floor(time % 60);
  return `${minutes < 10 ? '0' + minutes : minutes}:${seconds < 10 ? '0' + seconds : seconds}`;
};

// Update control bar position relative to video element
const updateControlBarPosition = (video, controlBar) => {
  const isFullBarRequired = 
  (video._downloadUrl && video._downloadUrl.includes('facebook.com/reel/')) ||
  /^https:\/\/(?:[^\/]+\.)?youtube\.com\/shorts\/[^\/]+/.test(window.location.href) ||
  ["instagram", "tiktok"].includes(current_website);
  const rect = video.getBoundingClientRect();
  let newTop, newLeft;
  if (isFullBarRequired) {
    newTop = `${window.scrollY + rect.top - controlBar.offsetHeight + 90}px`;
    newLeft = `${window.scrollX + rect.left + (rect.width / 2) - (controlBar.offsetWidth / 2)}px`;
  } else {
    newTop = `${window.scrollY + rect.top + 60}px`;
    newLeft = `${window.scrollX + rect.left + 20}px`;
  }
  if (controlBar.style.top !== newTop || controlBar.style.left !== newLeft) {
    controlBar.style.top = newTop;
    controlBar.style.left = newLeft;
  }
};

// Extract video URL and send download message
const extractAndDownloadVideo = (mp3, cut, convertMP4, bipAtEnd, copyAtEnd, useChromeCookies, targetUrl=false, isGIF=false) => {

  if (!targetUrl) {targetUrl = window.location.href}

  switch (true) {
    case /^https:\/\/(?:\w+\.)?instagram\.com/.test(targetUrl):
      showNotification("Analyzing Instagram page...", true, 1500);
      break;
    case /^https:\/\/(?:\w+\.)?facebook\.com/.test(targetUrl) ||
          /^https:\/\/(?:\w+\.)?x\.com/.test(targetUrl) ||
          /^https:\/\/(?:\w+\.)?tiktok\.com/.test(targetUrl):
      console.log(`[Extension] Using stored download URL: ${targetUrl}, is GIF: ${isGIF}`);
      break;
    case /^https:\/\/(?:\w+\.)?youtube\.com/.test(targetUrl):
      break;
    default:
      showNotification("Current website not supported for download", false, 1500);
      return;
  }

  if (!targetUrl) {
    showNotification("Could not determine video URL", false, 1500);
    return;
  }

  showNotification("Preparing video download...", true, 200000);
  console.log("cut =", cut)

  const message = { type: "DOWNLOAD", videoUrl: targetUrl, mp3: mp3, isGIF: isGIF, cut: cut, convertMP4: convertMP4, bipAtEnd: bipAtEnd, copyAtEnd: copyAtEnd, useChromeCookies: useChromeCookies };
  chrome.runtime.sendMessage(message, response => {
    if (chrome.runtime.lastError) {
      showNotification(`Download error: ${chrome.runtime.lastError.message}`, false, 3000);
      console.error("[Extension] Runtime error:", chrome.runtime.lastError);
      return;
    }

    if (response) {
      const finalPath = response.success ? response.finalPath : null;
      const duration = 10000;
      showNotification(response.message, response.success, duration, finalPath);
      console.log("response finalPath = ", finalPath);
    } else {
      showNotification("Received invalid response from background.", false, 3000);
      console.warn("[Extension] Invalid response received from background script.");
    }
  });
};

const createDownloadMenu = video => {
  const formatTimeHMS = time => {
    const hours = Math.floor(time / 3600);
    const minutes = Math.floor((time % 3600) / 60);
    const seconds = Math.floor(time % 60);
    return `${hours < 10 ? '0' + hours : hours}:${minutes < 10 ? '0' + minutes : minutes}:${seconds < 10 ? '0' + seconds : seconds}`;
  };

  const menu = document.createElement('div');
  menu.classList.add('download-menu');
  Object.assign(menu.style, {
    display: 'none',
    flexDirection: 'column',
    gap: '10px',
    position: 'absolute',
    backgroundColor: 'rgba(0, 10, 15, 0.9)',
    borderRadius: '8px',
    padding: '10px',
    zIndex: '2147483647',
    fontFamily: "'Roboto', sans-serif",
    color: 'white'
  });
  menu.style.setProperty('box-sizing', 'border-box', 'important');

  // Switch styles
  const switchStyle = document.createElement('style');
  switchStyle.textContent = `
    .switch {
      position: relative;
      display: inline-block;
      width: 40px;
      height: 20px;
    }
    .switch input {
      opacity: 0;
      width: 0;
      height: 0;
    }
    .slider {
      position: absolute;
      cursor: pointer;
      top: 0;
      left: 0;
      right: 0;
      bottom: 0;
      background-color: #ccc;
      transition: 0.4s;
      border-radius: 20px;
    }
    .switch input:checked + .slider {
      background-color: #3b82f6;
    }
    .slider:before {
      position: absolute;
      content: "";
      height: 16px;
      width: 16px;
      left: 2px;
      bottom: 2px;
      background-color: white;
      transition: 0.4s;
      border-radius: 50%;
    }
    .switch input:checked + .slider:before {
      transform: translateX(20px);
    }
  `;
  menu.appendChild(switchStyle);

  const createTimeInput = placeholder => {
    const input = document.createElement('input');
    input.type = 'text';
    input.placeholder = placeholder;
    Object.assign(input.style, {
      width: '80px',
      padding: '2px 4px',
      fontFamily: "'Roboto', sans-serif",
      color: 'black'
    });
    return input;
  };

  // Download buttons
  const buttonRow = document.createElement('div');
  Object.assign(buttonRow.style, {
    display: 'flex',
    gap: '10px',
    width: '100%'
  });

  const downloadVideoButton = document.createElement('button');
  downloadVideoButton.textContent = "Download Video";
  Object.assign(downloadVideoButton.style, {
    flex: '1',
    cursor: 'pointer',
    border: 'none',
    backgroundColor: '#1E3A8A',
    color: 'white',
    fontWeight: 'bold',
    padding: '4px 5px',
    borderRadius: '4px',
    fontFamily: "'Roboto', sans-serif",
    textAlign: 'center'
  });
  downloadVideoButton.addEventListener('mouseenter', () => {
    downloadVideoButton.style.backgroundColor = '#2563EB';
  });
  downloadVideoButton.addEventListener('mouseleave', () => {
    downloadVideoButton.style.backgroundColor = '#1E3A8A';
  });

  const downloadMp3Button = document.createElement('button');
  downloadMp3Button.textContent = "Download MP3";
  Object.assign(downloadMp3Button.style, {
    flex: '1',
    cursor: 'pointer',
    border: 'none',
    backgroundColor: '#1E3A8A',
    color: 'white',
    fontWeight: 'bold',
    padding: '4px 8px',
    borderRadius: '4px',
    fontFamily: "'Roboto', sans-serif",
    textAlign: 'center'
  });
  downloadMp3Button.addEventListener('mouseenter', () => {
    downloadMp3Button.style.backgroundColor = '#2563EB';
  });
  downloadMp3Button.addEventListener('mouseleave', () => {
    downloadMp3Button.style.backgroundColor = '#1E3A8A';
  });

  buttonRow.appendChild(downloadVideoButton);
  buttonRow.appendChild(downloadMp3Button);

  // CUT row and OPTIONS
  const cutRow = document.createElement('div');
  Object.assign(cutRow.style, {
    display: 'flex',
    alignItems: 'center',
    gap: '8px',
    width: '100%'
  });
  
  const cutLabel = document.createElement('span');
  cutLabel.textContent = "CUT";
  Object.assign(cutLabel.style, {
    fontFamily: "'Roboto', sans-serif",
    fontSize: '14px',
    color: 'white'
  });
  
  const cutSwitch = document.createElement('label');
  cutSwitch.classList.add('switch');
  const cutCheckbox = document.createElement('input');
  cutCheckbox.type = 'checkbox';
  const cutSlider = document.createElement('span');
  cutSlider.classList.add('slider');
  cutSwitch.appendChild(cutCheckbox);
  cutSwitch.appendChild(cutSlider);
  
  const timeContainer = document.createElement('div');
  Object.assign(timeContainer.style, {
    display: 'flex',
    alignItems: 'center',
    gap: '5px',
    opacity: '0.5'
  });
  const startInput = createTimeInput("");
  startInput.value = "00:00:00";
  startInput.readOnly = true; // Use readOnly to allow click events
  const endInput = createTimeInput("");
  if (!isNaN(video.duration) && video.duration > 0) {
    endInput.value = formatTimeHMS(video.duration);
  } else {
    video.addEventListener('loadedmetadata', () => {
      endInput.value = formatTimeHMS(video.duration);
    });
  }
  endInput.readOnly = true;
  const timeSeparator = document.createElement('span');
  timeSeparator.textContent = '-';
  Object.assign(timeSeparator.style, {
    color: 'grey',
    fontWeight: 'bold'
  });
  
  timeContainer.appendChild(startInput);
  timeContainer.appendChild(timeSeparator);
  timeContainer.appendChild(endInput);
  
  // Activate CUT switch when clicking on the readOnly inputs
  startInput.addEventListener('click', () => {
    if (!cutCheckbox.checked) {
      cutCheckbox.checked = true;
      startInput.readOnly = false;
      endInput.readOnly = false;
      timeContainer.style.opacity = "1";
    }
  });
  endInput.addEventListener('click', () => {
    if (!cutCheckbox.checked) {
      cutCheckbox.checked = true;
      startInput.readOnly = false;
      endInput.readOnly = false;
      timeContainer.style.opacity = "1";
    }
  });
  
  cutCheckbox.addEventListener('change', () => {
    if (cutCheckbox.checked) {
      startInput.readOnly = false;
      endInput.readOnly = false;
      timeContainer.style.opacity = "1";
    } else {
      startInput.readOnly = true;
      endInput.readOnly = true;
      timeContainer.style.opacity = "0.5";
    }
  });
  
  cutRow.appendChild(cutLabel);
  cutRow.appendChild(cutSwitch);
  cutRow.appendChild(timeContainer);
  

  // OPTIONS container aligned right
  const optionsContainer = document.createElement('div');
  Object.assign(optionsContainer.style, {
    position: 'relative',
    marginLeft: 'auto'
  });

  const optionsButton = document.createElement('button');
  optionsButton.textContent = "OPTIONS";
  Object.assign(optionsButton.style, {
    cursor: 'pointer',
    border: 'none',
    background: 'none',
    color: 'white',
    fontFamily: "'Roboto', sans-serif"
  });
  optionsContainer.appendChild(optionsButton);

  const optionsMenu = document.createElement('div');
  optionsMenu.classList.add('options-menu');
  Object.assign(optionsMenu.style, {
    display: 'none',
    flexDirection: 'column',
    gap: '10px',
    position: 'absolute',
    top: '100%',
    right: '0',
    width: '265px',
    backgroundColor: 'rgba(0, 10, 15, 0.9)',
    borderRadius: '8px',
    padding: '10px',
    zIndex: '2147483647',
    fontFamily: "'Roboto', sans-serif",
    color: 'white',
    boxSizing: 'border-box'
  });

  // Create an option checkbox with localStorage persistence
  const createOptionCheckbox = (labelText, localStorageKey, defaultValue) => {
    const optionRow = document.createElement('div');
    Object.assign(optionRow.style, {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      width: '100%'
    });

    const optionLabel = document.createElement('span');
    optionLabel.textContent = labelText;
    Object.assign(optionLabel.style, {
      fontFamily: "'Roboto', sans-serif",
      fontSize: '12px'
    });

    const optionSwitch = document.createElement('label');
    optionSwitch.classList.add('switch');
    const optionCheckbox = document.createElement('input');
    optionCheckbox.type = 'checkbox';

    let storedValue = localStorage.getItem(localStorageKey);
    if (storedValue === null) {
      storedValue = defaultValue ? "true" : "false";
      localStorage.setItem(localStorageKey, storedValue);
    }
    optionCheckbox.checked = storedValue === "true";

    optionCheckbox.addEventListener('change', () => {
      localStorage.setItem(localStorageKey, optionCheckbox.checked ? "true" : "false");
    });

    const optionSlider = document.createElement('span');
    optionSlider.classList.add('slider');

    optionSwitch.appendChild(optionCheckbox);
    optionSwitch.appendChild(optionSlider);

    optionRow.appendChild(optionLabel);
    optionRow.appendChild(optionSwitch);

    return { element: optionRow, checkbox: optionCheckbox };
  };

  const { element: convertMP4Option, checkbox: convertMP4Checkbox } = createOptionCheckbox("Convert video as MP4", "extension_convertMP4", true);
  const { element: bipAtEndOption, checkbox: bipAtEndCheckbox } = createOptionCheckbox("Bip at end", "extension_bipAtEnd", true);
  const { element: copyAtEndOption, checkbox: copyAtEndCheckbox } = createOptionCheckbox("Copy at end", "extension_copyAtEnd", false);
  const { element: useChromeCookiesOption, checkbox: useChromeCookiesCheckbox } = createOptionCheckbox("Use my cookies (for private video)", "extension_useChromeCookies", false);

  optionsMenu.appendChild(convertMP4Option);
  optionsMenu.appendChild(bipAtEndOption);
  optionsMenu.appendChild(copyAtEndOption);
  optionsMenu.appendChild(useChromeCookiesOption);
  useChromeCookiesOption.style.display = 'none';

  optionsContainer.appendChild(optionsMenu);
  cutRow.appendChild(optionsContainer);

  let optionsHideTimeout;
  const showOptionsMenu = () => {
    clearTimeout(optionsHideTimeout);
    optionsMenu.style.display = 'flex';
  };
  const hideOptionsMenu = () => {
    optionsHideTimeout = setTimeout(() => {
      if (!optionsMenu.matches(':hover') && !optionsButton.matches(':hover')) {
        optionsMenu.style.display = 'none';
      }
    }, 150);
  };

  // Options button and menu hover events to change color
  optionsButton.addEventListener('mouseenter', () => {
    optionsButton.style.color = '#3b82f6';
    showOptionsMenu();
  });
  optionsButton.addEventListener('mouseleave', () => {
    optionsButton.style.color = 'white';
    hideOptionsMenu();
  });
  optionsMenu.addEventListener('mouseenter', () => {
    optionsButton.style.color = '#3b82f6';
    showOptionsMenu();
  });
  optionsMenu.addEventListener('mouseleave', () => {
    optionsButton.style.color = 'white';
    hideOptionsMenu();
  });

  menu.appendChild(buttonRow);
  menu.appendChild(cutRow);

  const getCutValue = () => {
    if (!cutCheckbox.checked) return null;
    const start = startInput.value.trim();
    const end = endInput.value.trim();
    const empty = val => val === "" || val.toUpperCase() === "HH:MM:SS" || /^[0:]+$/.test(val);
    const valid = val => /^\d+(:\d+){0,2}$/.test(val);
    if (empty(start) && empty(end)) {
      return "*-";
    } else if (empty(start) && !empty(end) && valid(end)) {
      return "*-" + end;
    } else if (!empty(start) && valid(start) && empty(end)) {
      return "*" + start + "-";
    } else if (!empty(start) && !empty(end) && valid(start) && valid(end)) {
      return "*" + start + "-" + end;
    } else {
      showNotification("Invalid CUT input", false, 2000);
      return null;
    }
  };

  storedLink = video._downloadUrl;
  isGIF = video._isGIF;

  downloadVideoButton.addEventListener('click', e => {
    e.stopPropagation();
    const cut = getCutValue();
    if (cutCheckbox.checked && !cut) return;
    extractAndDownloadVideo(false, cut, convertMP4Checkbox.checked, bipAtEndCheckbox.checked, copyAtEndCheckbox.checked, useChromeCookiesCheckbox.checked, storedLink, isGIF);
  });

  downloadMp3Button.addEventListener('click', e => {
    e.stopPropagation();
    const cut = getCutValue();
    if (cutCheckbox.checked && !cut) return;
    extractAndDownloadVideo(true, cut, false, bipAtEndCheckbox.checked, copyAtEndCheckbox.checked, useChromeCookiesCheckbox.checked, false, false);
  });

  return menu;
};


const createControlBar = video => {
  const controlBar = document.createElement('div');
  controlBar.classList.add('extension-control-bar');
  Object.assign(controlBar.style, {
    position: 'absolute',
    backgroundColor: 'rgba(0, 10, 15, 0.8)',
    borderRadius: '8px',
    padding: '7px',
    display: 'flex',
    alignItems: 'center',
    gap: '5px',
    zIndex: '2147483647',
    pointerEvents: 'auto',
    transition: 'opacity 0.3s',
    opacity: '1',
    color: 'white',
    fontFamily: "'Roboto', sans-serif"
  });

  // Determine if full control bar is required
  const isFullBarRequired =
    (video._downloadUrl && video._downloadUrl.includes('facebook.com/reel/')) ||
    /^https:\/\/(?:[^\/]+\.)?youtube\.com\/shorts\/[^\/]+/.test(window.location.href) ||
    ["instagram", "tiktok"].includes(current_website);

  if (isFullBarRequired) {
    const playPauseButton = document.createElement('button');
    playPauseButton.classList.add('play-pause-button');
    playPauseButton.textContent = video.paused ? "▶" : "❚❚";
    Object.assign(playPauseButton.style, {
      cursor: 'pointer',
      border: 'none',
      background: 'none',
      color: 'white',
      transition: 'color 0.3s',
      fontFamily: "'Roboto', sans-serif"
    });
    playPauseButton.addEventListener('mouseenter', () => {
      playPauseButton.style.color = '#3b82f6';
    });
    playPauseButton.addEventListener('mouseleave', () => {
      playPauseButton.style.color = 'white';
    });
    playPauseButton.addEventListener('click', e => {
      e.stopPropagation();
      video.paused ? video.play() : video.pause();
    });
    video.addEventListener('play', () => playPauseButton.textContent = "❚❚");
    video.addEventListener('pause', () => playPauseButton.textContent = "▶");

    const elapsedTime = document.createElement('span');
    elapsedTime.textContent = "00:00";
    Object.assign(elapsedTime.style, {
      fontFamily: "'Roboto', sans-serif",
      color: 'white'
    });

    const progressBar = document.createElement('input');
    progressBar.type = 'range';
    progressBar.min = 0;
    progressBar.max = 100;
    progressBar.value = 0;
    Object.assign(progressBar.style, {
      flex: '1',
      cursor: 'pointer'
    });

    const totalTime = document.createElement('span');
    totalTime.textContent = "00:00";
    Object.assign(totalTime.style, {
      fontFamily: "'Roboto', sans-serif",
      color: 'white'
    });

    const volumeSlider = document.createElement('input');
    volumeSlider.type = 'range';
    volumeSlider.min = 0;
    volumeSlider.max = 1;
    volumeSlider.step = 0.01;
    Object.assign(volumeSlider.style, {
      width: '80px',
      cursor: 'pointer'
    });
    const storedVolume = localStorage.getItem('extension_video_volume');
    let sliderValue = storedVolume !== null ? parseFloat(storedVolume) : Math.sqrt(video.volume);
    volumeSlider.value = sliderValue;
    video.volume = Math.pow(sliderValue, 2);
    volumeSlider.addEventListener('input', e => {
      e.stopPropagation();
      const val = parseFloat(volumeSlider.value);
      video.volume = Math.pow(val, 2);
      localStorage.setItem('extension_video_volume', val);
    });

    // Create download menu and center it relative to the entire control bar
    const downloadMenu = createDownloadMenu(video);
    Object.assign(downloadMenu.style, {
      position: 'absolute',
      top: '100%',
      left: '0',
      width: '100%',
      marginTop: '0px'
    });
    // Append the download menu directly to the control bar so it spans the full width
    controlBar.appendChild(downloadMenu);

    // Define functions with a slight delay to prevent the menu from disappearing
    let hideTimeout;
    const showDownloadMenu = () => {
      clearTimeout(hideTimeout);
      downloadMenu.style.display = 'flex';
    };
    const hideDownloadMenu = () => {
      hideTimeout = setTimeout(() => {
        if (!downloadMenu.matches(':hover') && !downloadMenuButton.matches(':hover')) {
          downloadMenu.style.display = 'none';
          downloadMenuButton.style.color = 'white';
        }
      }, 150);
    };

    // Create download menu button (arrow)
    const downloadMenuButton = document.createElement('button');
    downloadMenuButton.classList.add('download-menu-button');
    downloadMenuButton.textContent = "⇩";
    Object.assign(downloadMenuButton.style, {
      cursor: 'pointer',
      border: 'none',
      background: 'none',
      color: 'white',
      fontFamily: "'Roboto', sans-serif"
    });
    downloadMenuButton.addEventListener('mouseenter', () => {
      downloadMenuButton.style.color = '#3b82f6';
      showDownloadMenu();
    });
    downloadMenuButton.addEventListener('mouseleave', hideDownloadMenu);
    // Also keep the menu visible when hovered directly
    downloadMenu.addEventListener('mouseenter', showDownloadMenu);
    downloadMenu.addEventListener('mouseleave', hideDownloadMenu);

    const createSeparator = (marginPX = '10px') => {
      const sep = document.createElement('div');
      Object.assign(sep.style, {
        width: '1px',
        height: '20px',
        backgroundColor: 'grey',
        marginLeft: marginPX,
        marginRight: marginPX
      });
      return sep;
    };

    // Append all elements to the control bar
    controlBar.append(
      playPauseButton,
      elapsedTime,
      progressBar,
      totalTime,
      createSeparator('5px'),
      volumeSlider,
      createSeparator(),
      downloadMenuButton
    );

    progressBar.addEventListener('input', e => {
      e.stopPropagation();
      video.currentTime = (progressBar.value / 100) * video.duration;
    });
    const updateProgress = () => {
      if (video.duration) {
        const prog = (video.currentTime / video.duration) * 100;
        progressBar.value = prog;
        elapsedTime.textContent = formatTime(video.currentTime);
        totalTime.textContent = formatTime(video.duration);
      }
      requestAnimationFrame(updateProgress);
    };
    updateProgress();
  } else {
    // Mini control bar with only the download arrow menu button
    const downloadContainer = document.createElement('div');
    downloadContainer.style.position = 'relative';
    
    const downloadMenuButton = document.createElement('button');
    downloadMenuButton.classList.add('download-menu-button');
    downloadMenuButton.textContent = "⇩";
    Object.assign(downloadMenuButton.style, {
      cursor: 'pointer',
      border: 'none',
      background: 'none',
      color: 'white',
      fontFamily: "'Roboto', sans-serif"
    });
    downloadMenuButton.addEventListener('mouseenter', () => {
      downloadMenuButton.style.color = '#3b82f6';
    });
    downloadMenuButton.addEventListener('mouseleave', () => {
      downloadMenuButton.style.color = 'white';
    });
    
    const downloadMenu = createDownloadMenu(video);
    
    downloadContainer.appendChild(downloadMenuButton);
    downloadContainer.appendChild(downloadMenu);
    
    let hideTimeout;
    const showDownloadMenu = () => {
      clearTimeout(hideTimeout);
      downloadMenu.style.display = 'flex';
    };
    const hideDownloadMenu = () => {
      hideTimeout = setTimeout(() => {
        if (!downloadMenu.matches(':hover') && !downloadMenuButton.matches(':hover')) {
          downloadMenu.style.display = 'none';
        }
      }, 150);
    };
    downloadContainer.addEventListener('mouseenter', showDownloadMenu);
    downloadContainer.addEventListener('mouseleave', hideDownloadMenu);
    
    controlBar.append(downloadContainer);
  }

  updateControlBarPosition(video, controlBar);
  controlBar._video = video;
  video._controlBar = controlBar;
  video._lastSrc = video.src;
  document.body.appendChild(controlBar);
  requestAnimationFrame(() => updateControlBarPosition(video, controlBar));
  return controlBar;
};




const isCenterInViewport = (element) => {
  const rect = element.getBoundingClientRect();
  if (rect.width === 0 || rect.height === 0) {
    return false;
  }
  const elementTopIsVisible = rect.top < window.innerHeight && rect.bottom > 0;
  const elementLeftIsVisible = rect.left < window.innerWidth && rect.right > 0;
  if (!elementTopIsVisible || !elementLeftIsVisible) {
        return false; 
  }
  const centerX = rect.left + rect.width / 2;
  const centerY = rect.top + rect.height / 2;
  return (
    centerX >= 0 &&
    centerX <= window.innerWidth &&
    centerY >= 0 &&
    centerY <= window.innerHeight
  );
};


/**
 * Identifies the most central video in the viewport, manages its control bar,
 * and removes bars for inactive or orphan videos.
 */
const updateActiveVideoControlBar = () => {

  document.querySelectorAll("video").forEach(video => video._controlBar && !video._controlBar.isConnected && delete video._controlBar);

  function checkWebsiteVideoCompatibility(website, videoElement) {
    if (!videoElement) return { url: null, isGIF: false };
    if (website === "tiktok") {
      const fullUrlMatch = window.location.href.match(/^https:\/\/www\.tiktok\.com\/@([^\/]+)\/video\/(\d+)/);
      if (fullUrlMatch) {
        return { url: window.location.href, isGIF: false };
      }
    }
    // For Facebook, first check for the 'data-video-id' attribute in ancestor elements
    if (website === "facebook") {
      let currentNode = videoElement.parentElement;
      let depth = 0;
      while (currentNode && depth < 10) {
        if (currentNode.hasAttribute('data-video-id')) {
          return { 
            url: `https://www.facebook.com/reel/${currentNode.getAttribute('data-video-id')}`,
            isGIF: false 
          };
        }
        currentNode = currentNode.parentElement;
        depth++;
      }
    }
    // Define selectors for each website
    const websiteSelectors = {
      facebook: {
        ancestorSelector: 'div[data-instancekey]',
        linkSelector: 'a[href*="/watch/?v="], a[href*="/videos/"]'
      },
      twitter: {
        ancestorSelector: 'article[data-testid="tweet"]',
        linkSelector: 'a[href*="/status/"]'
      },
      tiktok: {
        ancestorSelector: 'article',
        linkSelector: 'a[href^="/@"]',
        idSelector: '[id^="xgwrapper-"]'
      }
    };
    const selectors = websiteSelectors[website];
    if (!selectors) return { url: null, isGIF: false };
    // Traverse ancestors to find the common container that holds the video element
    let commonAncestor = null;
    let currentElement = videoElement.parentElement;
    while (currentElement) {
      if (currentElement.contains(videoElement) && currentElement.querySelector(selectors.ancestorSelector)) {
        commonAncestor = currentElement;
        break;
      }
      currentElement = currentElement.parentElement;
    }
    if (!commonAncestor) return { url: null, isGIF: false };
    // Retrieve the link element from the common container
    const linkElement = commonAncestor.querySelector(selectors.linkSelector);
    if (!linkElement) return { url: null, isGIF: false };
    // Get the href attribute from the link element
    const href = linkElement.getAttribute('href');
    if (!href) return { url: null, isGIF: false };
    let url = null;
    if (website === "facebook") {
      // Process Facebook URL
      let match = href.match(/\/watch\/\?v=(\d+)/);
      if (match && match[1]) {
        url = `https://www.facebook.com/watch/?v=${match[1]}`;
      }
      match = href.match(/facebook\.com\/([^\/]+)\/videos\/(\d+)/);
      if (match && match[1] && match[2]) {
        url = `https://www.facebook.com/${match[1]}/videos/${match[2]}`;
      }
      return { url: url, isGIF: false };
    } else if (website === "twitter") {
      // Process Twitter URL
      const match = href.match(/\/([^\/]+)\/status\/(\d+)/);
      if (match && match[1] && match[2]) {
        url = `https://www.x.com/${match[1]}/status/${match[2]}`;
      }
      // Determine isGIF for Twitter: search in the common container for a span whose text ends with "GIF"
      let isGIF = false;
      const spanElements = commonAncestor.querySelectorAll("span");
      spanElements.forEach(span => {
        if (span.textContent.trim().endsWith("GIF")) {
          isGIF = true;
        }
      });
      return { url: url, isGIF: isGIF };
    } else if (website === "tiktok") {
      const idElement = commonAncestor.querySelector(selectors.idSelector);
      const nameMatch = href.match(/^\/@([^/]+)/);
      const idMatch = idElement && idElement.id.match(/xgwrapper-\d+-(\d+)/);
      if (nameMatch && idMatch) {
          url = `https://www.tiktok.com/@${nameMatch[1]}/video/${idMatch[1]}`;
      }
      return { url: url, isGIF: false };
    }
    return { url: null, isGIF: false };
  }

  // Exit if not on a supported website
  if (!/^https:\/\/(?:\w+\.)?(?:facebook\.com|instagram\.com|x\.com|tiktok\.com|youtube\.com\/(?:watch|shorts))/.test(window.location.href)) {
    document.querySelectorAll('.extension-control-bar').forEach(bar => bar.remove());
    return;
  }
  const videos = Array.from(document.querySelectorAll('video'))
      .filter(v => v.isConnected && isCenterInViewport(v));

  // If no candidate videos are found, remove all existing control bars
  if (videos.length === 0) {
      document.querySelectorAll('.extension-control-bar').forEach(bar => {
          // Use removeControlBar if linked to a video to clear the reference
          if (bar._video) removeControlBar(bar._video);
          // Otherwise, just remove the orphan bar element
          else bar.remove();
      });
      return;
  }

  // Identify the video closest to the viewport center among candidates
  const viewportCenterX = window.innerWidth / 2;
  const viewportCenterY = window.innerHeight / 2;
  let activeVideo = null;
  let minDistance = Infinity;

  videos.forEach(video => {
      const rect = video.getBoundingClientRect();
      // Ensure video has valid dimensions before calculating distance
      if (rect.width > 0 && rect.height > 0) {
          const videoCenterX = rect.left + rect.width / 2;
          const videoCenterY = rect.top + rect.height / 2;
          const distance = Math.hypot(videoCenterX - viewportCenterX, videoCenterY - viewportCenterY);
          if (distance < minDistance) {
              minDistance = distance;
              activeVideo = video;
          }
      }
  });

  // Proceed if an active video was identified
  if (activeVideo) {
      // Remove control bars associated with other (now inactive) videos or orphan bars
      document.querySelectorAll('.extension-control-bar').forEach(bar => {
          if (bar._video && bar._video !== activeVideo) {
              removeControlBar(bar._video);
          } else if (!bar._video) {
              bar.remove();
          }
      });
      let canProceed = true;

      // Facebook and Twitter Specific Check ---
      if (["facebook", "twitter", "tiktok"].includes(current_website)) {
        const downloadInfo = checkWebsiteVideoCompatibility(current_website, activeVideo);
        if (downloadInfo && downloadInfo.url) {
          activeVideo._downloadUrl = downloadInfo.url; // Store the compatible URL
          activeVideo._isGIF = downloadInfo.isGIF;     // Store the GIF information
        } else {
          removeControlBar(activeVideo);
          canProceed = false;
        }
      }

      // Create or update the control bar if allowed and video still connected
      if (canProceed && activeVideo.isConnected) {
          if (!activeVideo._controlBar) {
              // Control bar doesn't exist: Create it, but only if video still has valid dimensions
              const currentRect = activeVideo.getBoundingClientRect();
              if (currentRect.width > 0 && currentRect.height > 0) {
                  createControlBar(activeVideo);
              }
              // If dimensions became zero right before creation, do nothing to avoid misplaced bar
          } else {
              // Control bar already exists: Update its position
              updateControlBarPosition(activeVideo, activeVideo._controlBar);
          }
      } else if (!canProceed || !activeVideo.isConnected) {
          // Clean up if FB check failed OR video got disconnected during processing
          removeControlBar(activeVideo);
      }

  } else {
      // Fallback: No specific video selected as active (e.g., distance calculation issue)
      // Remove all bars as a safety measure
      document.querySelectorAll('.extension-control-bar').forEach(bar => {
          if (bar._video) removeControlBar(bar._video);
          else bar.remove();
      });
  }
};

const removeControlBar = video => {
  if (video && video._controlBar) {
    video._controlBar.remove();
    delete video._controlBar;
    delete video._lastSrc;
  }
};

// Throttled update loop for control bars
let lastUpdateTime = 0;
const throttleDelay = 200;
const updateLoop = timestamp => {
  if (timestamp - lastUpdateTime > throttleDelay) {
    updateActiveVideoControlBar();
    lastUpdateTime = timestamp;
  }
  requestAnimationFrame(updateLoop);
};
requestAnimationFrame(updateLoop);

// Hide control bar on cursor inactivity
let lastMouseMoveTime = performance.now();
document.addEventListener('mousemove', () => {
  lastMouseMoveTime = performance.now();
  document.querySelectorAll('.extension-control-bar').forEach(bar => {
    bar.style.opacity = '1';
  });
});
const checkInactivity = () => {
  const isHoveringControlBar = Array.from(document.querySelectorAll('.extension-control-bar')).some(bar => bar.matches(':hover'));
  if (!isHoveringControlBar && performance.now() - lastMouseMoveTime > 1500) {
    document.querySelectorAll('.extension-control-bar').forEach(bar => {
      bar.style.opacity = '0';
    });
  } else {
    document.querySelectorAll('.extension-control-bar').forEach(bar => {
      bar.style.opacity = '1';
    });
  }
  requestAnimationFrame(checkInactivity);
};
requestAnimationFrame(checkInactivity);

// Global events for repositioning and refreshing
window.addEventListener('resize', () => {
  document.querySelectorAll('.extension-control-bar').forEach(bar => {
    if (bar._video) updateControlBarPosition(bar._video, bar);
  });
});
window.addEventListener('locationchange', () => {
  document.querySelectorAll('.extension-control-bar').forEach(bar => bar.remove());
});



})();
