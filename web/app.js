// app.js
// If the static site is on the same host as the Ingress, leave API_BASE empty.
// Otherwise, set it to your Ingress base URL, e.g. "https://short.example.com".
const API_BASE = "";

document.addEventListener("DOMContentLoaded", () => {
  const form = document.getElementById("shorten-form");
  const urlInput = document.getElementById("url_target");
  const aliasInput = document.getElementById("url_key");
  const btn = document.getElementById("submit-btn");
  const resultEl = document.getElementById("result");
  const errorEl = document.getElementById("error");

  const hide = (el) => el.classList.add("hidden");
  const show = (el) => el.classList.remove("hidden");

  function showError(msg) {
    resultEl.innerHTML = "";
    hide(resultEl);
    errorEl.textContent = msg;
    show(errorEl);
  }

  function showResult(shortUrl, targetUrl) {
    errorEl.textContent = "";
    hide(errorEl);
    resultEl.innerHTML = `
      <div>Short URL created:</div>
      <div><a href="${shortUrl}" target="_blank" rel="noopener">${shortUrl}</a></div>
      <div style="margin-top:6px; color:#9ca3af">→ ${escapeHtml(targetUrl)}</div>
    `;
    show(resultEl);
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, c => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
    }[c]));
  }

  async function postJson(url, body) {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      // Credentials not needed when same-origin and no cookies
    });
    let text = await res.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { }
    return { res, json, text };
  }

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    hide(resultEl);
    hide(errorEl);

    const urlTarget = urlInput.value.trim();
    const urlKey = aliasInput.value.trim();

    // Basic client-side URL validation
    try { new URL(urlTarget); } catch {
      showError("Please enter a valid URL (including https://).");
      return;
    }

    btn.disabled = true;
    const originalLabel = btn.textContent;
    btn.textContent = "Shortening...";

    try {
      const { res, json, text } = await postJson("/write/v1", {
        url_target: urlTarget,
        url_key: urlKey || undefined
      });

      if (res.ok) {
        // Server returns {URLKey, URLTarget} (Go struct) or may use lower-case keys.
        const returnedKey = json?.URLKey ?? json?.url_key ?? urlKey;
        const returnedTarget = json?.URLTarget ?? json?.url_target ?? urlTarget;
        const shortUrl = `${window.location.origin}/${returnedKey}`;
        showResult(shortUrl, returnedTarget);
        form.reset();
        return;
      }

      // Friendly error messages by status code
      if (res.status === 400) {
        // Path is illegal (e.g., reserved like static/*, invalid chars)
        const msg = json?.error || text || "The alias/path is not allowed. Use letters, numbers, - or _. Avoid reserved paths like static/.";
        showError(msg);
      } else if (res.status === 409) {
        // Alias already in use
        const msg = json?.error || text || "That alias is already in use. Please choose another.";
        showError(msg);
      } else if (res.status >= 500) {
        // Server-side issue
        showError("A server error occurred. Please try again in a moment.");
      } else {
        // Other non-2xx
        showError(`Request failed (${res.status}). ${text || "Please try again."}`);
      }
    } catch (err) {
      showError("Network error. Check your connection and try again.");
    } finally {
      btn.textContent = originalLabel;
      btn.disabled = false;
    }
  });
});