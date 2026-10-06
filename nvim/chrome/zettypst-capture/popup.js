const $ = (id) => document.getElementById(id);
const statusEl = $("status");
const buttons = Array.from(document.querySelectorAll("button"));

const pdfPattern = /\.pdf($|[?#])/i;
function isPdfUrl(url) {
  try {
    const { pathname } = new URL(url);
    return pdfPattern.test(pathname) || pathname.toLowerCase().includes("/pdf/");
  } catch (_) {
    return pdfPattern.test(url || "");
  }
}

// Status is a plain sentence, e.g. "Captured as @key"; an error's detail
// follows on its own line.
function span(className, text) {
  const node = document.createElement("span");
  node.className = className;
  node.textContent = text;
  return node;
}

function setStatus(state, sentence, { key, detail } = {}) {
  statusEl.dataset.state = state;
  const nodes = [document.createTextNode(sentence)];
  if (key) nodes.push(document.createTextNode(" as "), span("key", `@${key}`));
  if (detail) nodes.push(span("detail", detail));
  statusEl.replaceChildren(...nodes);
}

function describe(action, response) {
  if (action === "ping") return ["Native host is reachable"];
  if (response.status === "exists") return ["Already captured", { key: response.key }];
  return ["Captured", { key: response.key }];
}

function send(action) {
  buttons.forEach((b) => (b.disabled = true));
  statusEl.dataset.state = "busy";
  statusEl.textContent = action === "ping" ? "Checking native host…" : "Capturing…";
  chrome.runtime.sendMessage({ action }, (response) => {
    buttons.forEach((b) => (b.disabled = false));
    const err = chrome.runtime.lastError;
    if (err) return setStatus("error", "Capture failed", { detail: err.message });
    if (response?.ok) setStatus("ok", ...describe(action, response));
    else setStatus("error", action === "ping" ? "Native host unreachable" : "Capture failed", { detail: response?.error });
  });
}

chrome.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
  if (!tab) return;
  const url = tab.url || "";
  $("title").textContent = tab.title || url || "Untitled";
  try {
    const parsed = new URL(url);
    $("url").textContent = parsed.host + parsed.pathname.replace(/\/$/, "");
  } catch (_) {
    $("url").textContent = url;
  }
  $("url").title = url;
  if (isPdfUrl(url)) $("kind").textContent = "PDF";
});

$("auto").addEventListener("click", () => send("captureAuto"));
$("page").addEventListener("click", () => send("capturePage"));
$("pdf").addEventListener("click", () => send("capturePdf"));
$("ping").addEventListener("click", () => send("ping"));
