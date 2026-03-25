/**
 * content-linkedin.js — Kerwan LinkedIn content script
 *
 * Extracts profile data from LinkedIn profile pages and sends it to the
 * background service worker for relay to the Kerwan native app.
 *
 * Supported URLs: linkedin.com/in/<vanity-name>
 *
 * Extracted fields:
 *   name        — full display name (h1)
 *   headline    — tagline below the name
 *   company     — current company (top experience entry)
 *   title       — current job title (top experience entry)
 *   degree      — connection degree ("1st", "2nd", "3rd+")
 *   location    — listed location
 *   url         — canonical profile URL
 */

(function () {
  "use strict";

  // Only run on profile pages.
  if (!/^\/in\/[^/]+\/?$/.test(location.pathname)) return;

  // Debounce to avoid firing multiple times on SPA navigations.
  let lastSentUrl = null;
  let sendTimer = null;

  function scheduleExtract() {
    if (sendTimer) clearTimeout(sendTimer);
    sendTimer = setTimeout(extractAndSend, 1500);
  }

  function extractAndSend() {
    const url = location.href.split("?")[0]; // strip query/tracking params
    if (url === lastSentUrl) return;

    const data = extractProfile();
    if (!data.name) return; // page not ready yet

    lastSentUrl = url;
    chrome.runtime.sendMessage(
      {
        type: "linkedin_profile",
        url,
        data,
        timestamp: Date.now() / 1000,
      },
      (response) => {
        if (chrome.runtime.lastError) {
          // Service worker may have been restarted — ignore.
        }
      }
    );
  }

  function extractProfile() {
    const name = text(
      "h1.text-heading-xlarge, h1[class*='inline'], .pv-text-details__left-panel h1"
    );

    const headline = text(
      ".text-body-medium.break-words, .pv-text-details__left-panel .text-body-medium"
    );

    const location = text(
      ".pv-text-details__left-panel .text-body-small:not(.inline)"
    );

    const degree = text(
      ".dist-value, [class*='distance'] .dist-value"
    );

    // Connection degree from the badge next to the name.
    const degreeBadge = text(".pv-top-card--list-bullet .distance-badge span");

    // Top experience: first list item in #experience section.
    let company = "";
    let title = "";
    const expSection = document.getElementById("experience");
    if (expSection) {
      const firstEntry = expSection.querySelector("li.artdeco-list__item");
      if (firstEntry) {
        title = text(".mr1.t-bold span[aria-hidden='true']", firstEntry);
        company = text(
          ".t-14.t-normal span[aria-hidden='true']",
          firstEntry
        );
      }
    }

    // Fallback: parse headline for company ("Title at Company")
    if (!company && headline) {
      const match = headline.match(/ at (.+)$/i);
      if (match) company = match[1].trim();
    }

    return {
      name,
      headline,
      company,
      title,
      degree: degreeBadge || degree || null,
      location,
    };
  }

  function text(selector, root = document) {
    const el = root.querySelector(selector);
    return el ? el.textContent.trim() : "";
  }

  // ─── SPA navigation detection ────────────────────────────────────────────
  // LinkedIn is a SPA; URL changes without full page loads.
  let lastPath = location.pathname;
  const observer = new MutationObserver(() => {
    if (location.pathname !== lastPath) {
      lastPath = location.pathname;
      lastSentUrl = null;
    }
    if (/^\/in\/[^/]+\/?$/.test(location.pathname)) {
      scheduleExtract();
    }
  });

  observer.observe(document.body, {
    childList: true,
    subtree: true,
  });

  // Initial extract.
  scheduleExtract();
})();
