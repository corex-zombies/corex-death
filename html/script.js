const deathScreen = document.getElementById('death-screen');
const timerValue = document.getElementById('timer-value');
const timerBar = document.getElementById('timer-bar');
const respawnBtn = document.getElementById('respawn-btn');
const btnText = respawnBtn.querySelector('.btn-text');

let countdownInterval = null;
let remaining = 0;
let totalDuration = 0;
let respawnInFlight = false;
let buttonReady = false;

const DEFAULT_BTN_TEXT = 'RESPAWN';

function resourceName() {
    try {
        return typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'corex-death';
    } catch (e) {
        return 'corex-death';
    }
}

function postToClient(endpoint, body) {
    try {
        fetch(`https://${resourceName()}/${endpoint}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body || {})
        }).catch(() => { /* offline / test browser - ignore */ });
    } catch (e) { /* ignore */ }
}

function debugLog(message) {
    try {
        console.log(`[COREX-DEATH][NUI] ${message}`);
        postToClient('debugLog', { message });
    } catch (e) { /* ignore */ }
}

function setButtonReady(ready) {
    buttonReady = ready;
    if (ready) {
        respawnBtn.classList.remove('hidden');
        respawnBtn.style.pointerEvents = '';
        respawnBtn.style.opacity = '';
        respawnBtn.removeAttribute('disabled');
        btnText.textContent = DEFAULT_BTN_TEXT;
        // Focus so Enter/Space can be handled by the browser too.
        try { respawnBtn.focus({ preventScroll: true }); } catch (e) { /* ignore */ }
    } else {
        respawnBtn.classList.add('hidden');
        respawnBtn.style.pointerEvents = '';
        respawnBtn.style.opacity = '';
    }
}

function setButtonPending() {
    // Do NOT set pointer-events:none permanently. Dim and show a pending
    // label so the player knows the request is in flight. If the server
    // times out, the Lua side will send `respawnFailed` and we re-enable.
    respawnInFlight = true;
    respawnBtn.style.opacity = '0.5';
    btnText.textContent = 'RESPAWNING...';
    respawnBtn.setAttribute('disabled', 'disabled');
}

function clearButtonPending() {
    respawnInFlight = false;
    respawnBtn.style.opacity = '';
    btnText.textContent = DEFAULT_BTN_TEXT;
    respawnBtn.removeAttribute('disabled');
}

function showDeathScreen(duration) {
    totalDuration = duration;
    remaining = Math.ceil(duration / 1000);
    respawnInFlight = false;

    timerValue.textContent = remaining;
    timerBar.style.transform = 'scaleX(1)';
    setButtonReady(false);
    deathScreen.classList.remove('hidden');

    debugLog(`showDeathScreen duration=${duration}`);

    if (countdownInterval) {
        clearInterval(countdownInterval);
    }

    countdownInterval = setInterval(() => {
        remaining--;

        if (remaining <= 0) {
            remaining = 0;
            clearInterval(countdownInterval);
            countdownInterval = null;
            setButtonReady(true);
            debugLog('countdown complete, button enabled');
        }

        timerValue.textContent = remaining;

        const progress = remaining / (totalDuration / 1000);
        timerBar.style.transform = `scaleX(${Math.max(0, progress)})`;
    }, 1000);
}

function hideDeathScreen() {
    deathScreen.classList.add('hidden');

    if (countdownInterval) {
        clearInterval(countdownInterval);
        countdownInterval = null;
    }

    remaining = 0;
    respawnInFlight = false;
    buttonReady = false;
    clearButtonPending();
}

function triggerRespawn(origin) {
    if (!buttonReady) {
        debugLog(`respawn attempt ignored (button not ready) origin=${origin}`);
        return;
    }
    if (respawnInFlight) {
        debugLog(`respawn attempt ignored (in-flight) origin=${origin}`);
        return;
    }

    debugLog(`respawn click origin=${origin}`);
    setButtonPending();
    postToClient('requestRespawn', { origin });
}

respawnBtn.addEventListener('click', () => triggerRespawn('click'));

// Keyboard fallback - NUI focused mode routes keys to the iframe. Enter,
// NumpadEnter, and Space all trigger respawn once the button is ready.
document.addEventListener('keydown', (e) => {
    if (!buttonReady) return;
    if (e.repeat) return;

    const key = e.key;
    if (key === 'Enter' || key === ' ' || key === 'Spacebar' || e.code === 'Space' || e.code === 'NumpadEnter') {
        e.preventDefault();
        triggerRespawn(`key:${e.code || key}`);
    }
});

// Safety: if the user somehow focuses outside the button, clicking anywhere
// on the screen after the countdown also triggers respawn. This prevents
// lockouts caused by z-index / layout bugs obscuring the button.
deathScreen.addEventListener('click', (e) => {
    if (!buttonReady) return;
    if (respawnInFlight) return;
    // Only trigger if click was NOT on an interactive ignored element.
    // (Currently only the button is interactive - but guard anyway.)
    if (e.target === respawnBtn || respawnBtn.contains(e.target)) return;
    debugLog('respawn click via screen fallback');
    triggerRespawn('screen-fallback');
});

window.addEventListener('message', (event) => {
    const data = event.data || {};

    if (data.action === 'showDeathScreen') {
        showDeathScreen(data.duration || 15000);
    } else if (data.action === 'hideDeathScreen') {
        hideDeathScreen();
    } else if (data.action === 'respawnPending') {
        setButtonPending();
    } else if (data.action === 'respawnFailed') {
        debugLog('server timeout - re-enabling button');
        clearButtonPending();
        // Make sure button is visible even if something weird happened.
        if (remaining <= 0) setButtonReady(true);
    }
});
