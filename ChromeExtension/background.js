/**
 * background.js — Kerwan Chrome Extension Service Worker
 *
 * Maintains a persistent connection to the kerwan-nmh native messaging host.
 * Receives captured profile/thread objects from content scripts and forwards
 * them to the host. Reconnects automatically on disconnect.
 *
 * Message protocol (content script → background):
 *   { type: "linkedin_profile" | "gmail_thread", url: string, data: object, timestamp: number }
 *
 * Message protocol (background → native host):
 *   Same object, JSON-encoded with 4-byte LE length prefix (handled by Chrome).
 */

const NMH_NAME = "com.kerwan.app";

let port = null;
let captureEnabled = true;

// ─── Connection Management ───────────────────────────────────────────────────

function connect() {
  try {
    port = chrome.runtime.connectNative(NMH_NAME);
    port.onMessage.addListener(onNativeMessage);
    port.onDisconnect.addListener(onDisconnected);
    broadcastStatus("connected");
    console.log("[Kerwan] Connected to native messaging host");
  } catch (err) {
    console.error("[Kerwan] Failed to connect to native host:", err);
    broadcastStatus("disconnected");
    scheduleReconnect();
  }
}

function onDisconnected() {
  const err = chrome.runtime.lastError;
  if (err) {
    console.warn("[Kerwan] Native host disconnected:", err.message);
  }
  port = null;
  broadcastStatus("disconnected");
  scheduleReconnect();
}

let reconnectTimer = null;
function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, 5000);
}

// ─── Native Host → Extension ─────────────────────────────────────────────────

function onNativeMessage(msg) {
  // The native host may send acknowledgement or config messages in future.
  console.log("[Kerwan] Message from native host:", msg);
}

// ─── Content Script → Background → Native ────────────────────────────────────

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!captureEnabled) {
    sendResponse({ ok: false, reason: "capture_disabled" });
    return true;
  }

  if (
    message.type === "linkedin_profile" ||
    message.type === "gmail_thread"
  ) {
    forwardToNative(message);
    sendResponse({ ok: true });
  } else if (message.type === "get_status") {
    sendResponse({
      ok: true,
      connected: port !== null,
      captureEnabled,
    });
  } else if (message.type === "set_capture_enabled") {
    captureEnabled = !!message.enabled;
    chrome.storage.local.set({ captureEnabled });
    sendResponse({ ok: true });
  }
  return true;
});

function forwardToNative(message) {
  if (!port) {
    connect();
    // Buffer briefly and retry once connected. Simple single-retry approach.
    setTimeout(() => {
      if (port) port.postMessage(message);
    }, 1000);
    return;
  }
  try {
    port.postMessage(message);
  } catch (err) {
    console.error("[Kerwan] postMessage failed:", err);
    port = null;
    scheduleReconnect();
  }
}

function broadcastStatus(status) {
  chrome.runtime.sendMessage({ type: "status_update", status }).catch(() => {
    // Popup may not be open — ignore.
  });
}

// ─── Popup / Status ───────────────────────────────────────────────────────────

// Restore captureEnabled from storage on service worker start.
chrome.storage.local.get(["captureEnabled"], (result) => {
  if (typeof result.captureEnabled === "boolean") {
    captureEnabled = result.captureEnabled;
  }
  connect();
});
