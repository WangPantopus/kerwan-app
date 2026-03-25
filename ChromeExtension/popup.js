/**
 * popup.js — Kerwan extension popup controller
 *
 * Queries the background service worker for the current connection status and
 * capture-enabled flag, then renders them. The capture toggle is persisted via
 * chrome.storage.local so it survives service worker restarts.
 */

const statusDot   = document.getElementById("statusDot");
const statusLabel = document.getElementById("statusLabel");
const toggle      = document.getElementById("captureToggle");
const footerMsg   = document.getElementById("footerMsg");

// ─── Initial state ───────────────────────────────────────────────────────────

chrome.runtime.sendMessage({ type: "get_status" }, (response) => {
  if (chrome.runtime.lastError || !response) {
    setStatus("disconnected");
    return;
  }
  setStatus(response.connected ? "connected" : "disconnected");
  toggle.checked = response.captureEnabled !== false;
});

// ─── Listen for live status updates from the background ──────────────────────

chrome.runtime.onMessage.addListener((message) => {
  if (message.type === "status_update") {
    setStatus(message.status);
  }
});

// ─── Toggle ──────────────────────────────────────────────────────────────────

toggle.addEventListener("change", () => {
  chrome.runtime.sendMessage(
    { type: "set_capture_enabled", enabled: toggle.checked },
    () => {
      if (chrome.runtime.lastError) {
        console.warn("[Kerwan popup] set_capture_enabled failed");
      }
    }
  );
});

// ─── Helpers ─────────────────────────────────────────────────────────────────

function setStatus(status) {
  statusDot.className = "dot " + status;
  if (status === "connected") {
    statusLabel.textContent = "Connected";
    footerMsg.textContent   = "Kerwan is capturing browsing context.";
  } else {
    statusLabel.textContent = "Disconnected";
    footerMsg.textContent   = "Open Kerwan on your Mac to connect.";
  }
}
