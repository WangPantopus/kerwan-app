/**
 * content-gmail.js — Kerwan Gmail content script
 *
 * Captures the open email thread when the user navigates to a conversation in
 * Gmail and sends a structured summary to the background service worker.
 *
 * Extracted fields:
 *   subject      — thread subject line
 *   participants — [{ name: string, email: string }] from From/To/Cc headers
 *   snippet      — first ~300 chars of the last visible message body
 *   url          — canonical thread URL
 */

(function () {
  "use strict";

  // Only run on mail.google.com.
  if (!location.hostname.includes("mail.google.com")) return;

  let lastSentUrl = null;
  let sendTimer = null;

  function scheduleExtract() {
    if (sendTimer) clearTimeout(sendTimer);
    sendTimer = setTimeout(extractAndSend, 1800);
  }

  function extractAndSend() {
    // Gmail thread URL contains #inbox/<threadId> or #label/.../<threadId>
    const url = location.href;
    if (url === lastSentUrl) return;
    if (!url.includes("#")) return; // not in a thread

    const data = extractThread();
    if (!data.subject && data.participants.length === 0) return;

    lastSentUrl = url;
    chrome.runtime.sendMessage(
      {
        type: "gmail_thread",
        url,
        data,
        timestamp: Date.now() / 1000,
      },
      () => {
        if (chrome.runtime.lastError) {
          // Ignore.
        }
      }
    );
  }

  function extractThread() {
    // Subject
    const subject = text(
      "h2.hP, [data-legacy-thread-id] .hP, .nH .ha h2"
    );

    // Participants — from/to/cc spans in the expanded message header.
    const participants = extractParticipants();

    // Snippet from the last visible message body.
    const snippet = extractSnippet();

    return { subject, participants, snippet };
  }

  function extractParticipants() {
    const seen = new Set();
    const result = [];

    // Gmail renders each sender as a <span email="..."> with the display name
    // as text content.
    const spans = document.querySelectorAll(
      ".gD[email], span[email], [data-hovercard-id]"
    );
    spans.forEach((el) => {
      const email =
        el.getAttribute("email") ||
        el.getAttribute("data-hovercard-id") ||
        "";
      const name = el.getAttribute("name") || el.textContent.trim();
      if (!email || seen.has(email)) return;
      seen.add(email);
      result.push({ name, email });
    });

    return result;
  }

  function extractSnippet() {
    // Last expanded message body.
    const bodies = document.querySelectorAll(".a3s.aiL, .ii.gt .a3s");
    if (bodies.length === 0) return "";
    const last = bodies[bodies.length - 1];
    return last.innerText.slice(0, 300).replace(/\s+/g, " ").trim();
  }

  function text(selector, root = document) {
    const el = root.querySelector(selector);
    return el ? el.textContent.trim() : "";
  }

  // ─── SPA / hash navigation detection ────────────────────────────────────
  let lastHash = location.hash;
  const observer = new MutationObserver(() => {
    if (location.hash !== lastHash) {
      lastHash = location.hash;
      lastSentUrl = null;
      scheduleExtract();
    }
  });

  observer.observe(document.body, {
    childList: true,
    subtree: true,
    attributes: false,
  });

  // Initial extract if page loads with thread already open.
  scheduleExtract();
})();
