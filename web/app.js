// app.js
// If the static site is on the same host as the Ingress, leave API_BASE empty.
// Otherwise, set it to your Ingress base URL, e.g. "https://short.example.com".
const API_BASE = "";

const form = document.getElementById("shorten-form");
const urlTarget = document.getElementById("url_target");
const urlKey = document.getElementById("url_key");
const resultEl = document.getElementById("result");
const errorEl = document.getElementById("error");
const submitBtn = document.getElementById("submit-btn");

function showResult(shortKey, target) {
  const origin = window.location.origin;
  const shortUrl = `${origin}/${encodeURIComponent(shortKey)}`;
  resultEl.classList.remove("hidden");
  resultEl.innerHTML = `Short link: <a href="${shortUrl}" target="_blank" rel="noopener">${shortUrl}</a><br><small>→ ${escapeHtml(
    target
  )}</small>`;
  errorEl.classList.add("hidden");
}
function showError(msg) {
  errorEl.textContent = msg;
  errorEl.classList.remove("hidden");
  resultEl.classList.add("hidden");
}
function escapeHtml(s) {
  return s.replace(/[&<>"']/g, c => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" }[c]));
}

form.addEventListener("submit", async (e) => {
  e.preventDefault();
  const target = urlTarget.value.trim();
  const key = urlKey.value.trim();
  if (!target) {
    showError("Please provide a valid URL.");
    return;
  }
  submitBtn.disabled = true;
  try {
    const resp = await fetch(`${API_BASE}/write/v1`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(key ? { url_target: target, url_key: key } : { url_target: target }),
    });
    const text = await resp.text();
    if (!resp.ok) {
      let msg = "Failed to create short URL.";
      try {
        const j = JSON.parse(text);
        if (j.error) msg = j.error;
      } catch {}
      showError(`${msg} (HTTP ${resp.status})`);
      return;
    }
    const data = JSON.parse(text);
    showResult(data.url_key, data.url_target);
    form.reset();
  } catch (err) {
    showError(`Network error: ${err}`);
  } finally {
    submitBtn.disabled = false;
  }
});