const HOST = "top.homeward_sky.zettypst_capture";

function isPdfUrl(url) {
  try {
    const parsed = new URL(url);
    return /\.pdf($|[?#])/i.test(parsed.pathname) || parsed.pathname.toLowerCase().includes("/pdf/");
  } catch (_) {
    return /\.pdf($|[?#])/i.test(url || "");
  }
}

function notify(title, message) {
  chrome.notifications.create({
    type: "basic",
    iconUrl: "icon.png",
    title,
    message: message || "",
  });
}

function sendNative(payload) {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendNativeMessage(HOST, payload, (response) => {
      const err = chrome.runtime.lastError;
      if (err) {
        reject(new Error(err.message));
        return;
      }
      resolve(response || { ok: false, error: "empty native host response" });
    });
  });
}

async function getPageData(tabId) {
  try {
    const [result] = await chrome.scripting.executeScript({
      target: { tabId },
      func: () => {
        const meta = (selector) => document.querySelector(selector)?.getAttribute("content") || "";
        const absoluteUrl = (value) => {
          if (!value) return "";
          try {
            const resolved = new URL(value, location.href);
            return resolved.protocol === "http:" || resolved.protocol === "https:" ? resolved.href : "";
          } catch (_) {
            return "";
          }
        };
        const looksLikePdf = (value) => {
          try {
            const parsed = new URL(value, location.href);
            return /\.pdf$/i.test(parsed.pathname) || parsed.pathname.toLowerCase().includes("/pdf/");
          } catch (_) {
            return false;
          }
        };
        const attributeUrl = (selector, attribute) =>
          absoluteUrl(document.querySelector(selector)?.getAttribute(attribute) || "");
        const citationPdf = absoluteUrl(meta("meta[name='citation_pdf_url']"));
        const embeddedPdf =
          attributeUrl("embed[type='application/pdf'][src]", "src") ||
          attributeUrl("object[type='application/pdf'][data]", "data");
        const framedPdf = Array.from(document.querySelectorAll("iframe[src]"))
          .map((node) => absoluteUrl(node.getAttribute("src") || ""))
          .find(looksLikePdf);
        const allMeta = {};
        for (const node of document.querySelectorAll("meta[name], meta[property], meta[itemprop]")) {
          const key = node.getAttribute("name") || node.getAttribute("property") || node.getAttribute("itemprop");
          const value = node.getAttribute("content") || "";
          if (!key || !value) continue;
          const normalized = key.toLowerCase();
          if (allMeta[normalized] === undefined) {
            allMeta[normalized] = value;
          } else if (Array.isArray(allMeta[normalized])) {
            allMeta[normalized].push(value);
          } else {
            allMeta[normalized] = [allMeta[normalized], value];
          }
        }
        const canonical = document.querySelector("link[rel='canonical']")?.href || "";
        const jsonLd = Array.from(document.querySelectorAll("script[type='application/ld+json']"))
          .map((node) => node.textContent || "")
          .filter(Boolean)
          .slice(0, 5);
        return {
          title: document.title || "",
          selection: window.getSelection()?.toString() || "",
          description: meta("meta[name='description']"),
          keywords: meta("meta[name='keywords']"),
          ogTitle: meta("meta[property='og:title']"),
          ogDescription: meta("meta[property='og:description']"),
          twitterTitle: meta("meta[name='twitter:title']"),
          twitterDescription: meta("meta[name='twitter:description']"),
          canonicalUrl: canonical,
          pdfUrl: citationPdf || embeddedPdf || framedPdf || "",
          meta: allMeta,
          jsonLd,
          url: location.href,
        };
      },
    });
    return result?.result || {};
  } catch (_) {
    return {};
  }
}

function report(response, successTitle) {
  if (response?.ok) {
    if (response.status === "exists") {
      notify("Already captured", response.key ? `@${response.key}` : "Existing note found");
    } else {
      notify(successTitle, response.title || response.note_path || "Done");
    }
  } else {
    notify("ZetTypst Capture failed", response?.error || "Unknown error");
  }
}

async function capturePage(tab, pageData = null) {
  const page = pageData || (tab.id ? await getPageData(tab.id) : {});
  const response = await sendNative({
    action: "capturePage",
    url: tab.url || page.url,
    title: tab.title || page.title || "",
    selection: page.selection || "",
    metadata: page,
  });
  report(response, "Page captured");
  return response;
}

function downloadPdf(url, title = "") {
  const filename = `zettypst-capture/${crypto.randomUUID()}.pdf`;
  return new Promise((resolve, reject) => {
    chrome.downloads.download(
      {
        url,
        filename,
        conflictAction: "uniquify",
        saveAs: false,
      },
      (downloadId) => {
        const err = chrome.runtime.lastError;
        if (err) {
          reject(new Error(err.message));
          return;
        }
        let settled = false;
        const finish = (error, item) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          chrome.downloads.onChanged.removeListener(listener);
          if (error) reject(error);
          else resolve({
            path: item.filename,
            finalUrl: item.finalUrl || item.url || url,
            mimeType: item.mime || "",
            title,
          });
        };
        const inspect = () => chrome.downloads.search({ id: downloadId }, (items) => {
          const error = chrome.runtime.lastError;
          if (error) return finish(new Error(error.message));
          const item = items?.[0];
          if (!item) return finish(new Error("Chrome did not return the download"));
          if (item.state === "interrupted") return finish(new Error("PDF download was interrupted"));
          if (item.state === "complete") {
            if (!item.filename) return finish(new Error("Chrome did not return a downloaded file path"));
            finish(null, item);
          }
        });
        const listener = (delta) => {
          if (delta.id === downloadId && delta.state) inspect();
        };
        const timer = setTimeout(() => finish(new Error("PDF download timed out")), 5 * 60 * 1000);
        chrome.downloads.onChanged.addListener(listener);
        // A cached download can finish before the listener is registered.
        inspect();
      },
    );
  });
}

async function capturePdfUrl(url, title = "", tab = null, pageData = null) {
  const page = pageData || (tab?.id ? await getPageData(tab.id) : {});
  const downloaded = await downloadPdf(url, title);
  const response = await sendNative({
    action: "capturePdfFile",
    path: downloaded.path,
    sourceUrl: downloaded.finalUrl,
    mimeType: downloaded.mimeType,
    title,
    metadata: page,
  });
  report(response, "PDF captured");
  return response;
}

async function captureActivePdf(tab) {
  const page = tab.id ? await getPageData(tab.id) : {};
  const pdfUrl = isPdfUrl(tab.url || "") ? tab.url : page.pdfUrl;
  if (!pdfUrl) {
    throw new Error("Current tab is not a PDF and contains no detectable PDF URL");
  }
  return capturePdfUrl(pdfUrl, tab.title || page.title || "", tab, page);
}

async function captureAuto(tab) {
  const page = tab.id ? await getPageData(tab.id) : {};
  const pdfUrl = isPdfUrl(tab.url || "") ? tab.url : page.pdfUrl;
  if (pdfUrl) {
    return capturePdfUrl(pdfUrl, tab.title || page.title || "", tab, page);
  }
  return capturePage(tab, page);
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: "zettypst-capture-page",
    title: "Capture page to ZetTypst",
    contexts: ["page"],
  });
  chrome.contextMenus.create({
    id: "zettypst-capture-link-pdf",
    title: "Capture linked PDF to ZetTypst",
    contexts: ["link"],
  });
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  try {
    if (info.menuItemId === "zettypst-capture-page" && tab) {
      await capturePage(tab);
    } else if (info.menuItemId === "zettypst-capture-link-pdf" && info.linkUrl) {
      await capturePdfUrl(info.linkUrl, info.selectionText || tab?.title || "", tab);
    }
  } catch (error) {
    notify("ZetTypst Capture failed", error.message);
  }
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  (async () => {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!tab) throw new Error("No active tab");
    if (message.action === "capturePage") return capturePage(tab);
    if (message.action === "capturePdf") return captureActivePdf(tab);
    if (message.action === "captureAuto") return captureAuto(tab);
    if (message.action === "ping") return sendNative({ action: "ping" });
    throw new Error(`Unknown action: ${message.action}`);
  })()
    .then((response) => sendResponse(response))
    .catch((error) => sendResponse({ ok: false, error: error.message }));
  return true;
});
