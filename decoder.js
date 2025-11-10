"use strict";
const express = require("express");
const iconv = require("iconv-lite");
const libqp  = require("libqp");

const app = express();
app.use(express.json({ limit: "10mb" }));

function forceUtf8Meta(html) {
  if (!html) return "";
  let out = String(html);
  // limpia metas previas
  out = out.replace(/<meta\b[^>]*charset[^>]*>/ig, "");
  out = out.replace(/<meta\b[^>]*http-equiv\s*=\s*["']?\s*content-type\s*["']?[^>]*>/ig, "");
  // inserta utf-8
  if (/<head[^>]*>/i.test(out)) out = out.replace(/(<head[^>]*>)/i, '$1<meta charset="utf-8">');
  else out = '<!doctype html><meta charset="utf-8">' + out;
  return out;
}

function wrapTextAsHtml(text) {
  const esc = String(text)
    .replace(/&/g,"&amp;").replace(/</g,"&lt;")
    .replace(/>/g,"&gt;").replace(/"/g,"&quot;").replace(/'/g,"&#39;");
  return `<!doctype html><meta charset="utf-8"><pre>${esc}</pre>`;
}

function base64UrlToBuffer(s) {
  s = String(s || "").replace(/-/g,"+").replace(/_/g,"/");
  while (s.length % 4) s += "=";
  return Buffer.from(s, "base64");
}

function getHeader(node, name) {
  const headers = (node && (node.headers || node.payload?.headers)) || [];
  const h = headers.find(h => h?.name?.toLowerCase() === name.toLowerCase());
  return h?.value || "";
}

function detectCharset(node) {
  const ct = getHeader(node, "Content-Type");
  const m = /charset\s*=\s*"?([^";\s]+)"?/i.exec(ct || "");
  let cs = (m && m[1]) ? m[1].toLowerCase() : "utf-8";
  if (cs === "latin1") cs = "iso-8859-1";
  if (cs === "cp1252") cs = "windows-1252";
  return cs;
}

function partToBuffer(part) {
  const cte = getHeader(part, "Content-Transfer-Encoding").toLowerCase();
  const raw = part?.body?.data || "";
  let buf = base64UrlToBuffer(raw); // bytes de la parte (aún QP/base64 si aplica)

  if (cte.includes("quoted-printable")) {
    buf = libqp.decode(buf); // QP -> bytes reales
  } else if (cte.includes("base64")) {
    // ya tenemos los bytes reales
  } else {
    // sin CTE claro: si huele a QP, intenta una pasada
    const ascii = buf.toString("ascii");
    if (/=([0-9A-F]{2})(?:\r?\n)?/i.test(ascii)) {
      buf = libqp.decode(Buffer.from(ascii, "ascii"));
    }
  }
  return buf;
}

// puntuación de calidad: menos � y menos patrones de mojibake gana
function scoreText(s) {
  const bad = (s.match(/\uFFFD/g) || []).length;
  const moj = (s.match(/[ÃÂ][\u0000-\u00FF]/g) || []).length;
  return -(bad * 10 + moj * 5);
}

// repara caso típico “Ã³/Â ” -> recodifica latin1->utf8
function repairIfMojibake(s) {
  const moj = (s.match(/[ÃÂ][\u0000-\u00FF]/g) || []).length;
  if (moj >= 2) {
    return Buffer.from(s, "latin1").toString("utf8");
  }
  return s;
}

function decodeBest(bytes, declared) {
  const candidates = Array.from(new Set([declared, "utf-8", "windows-1252", "iso-8859-1"]));
  let best = { text: "", score: -Infinity, charset: "" };

  for (const cs of candidates) {
    try {
      const t = iconv.decode(bytes, cs);
      const repaired = repairIfMojibake(t);
      const sc = scoreText(repaired);
      if (sc > best.score) best = { text: repaired, score: sc, charset: cs };
    } catch {}
  }
  // opcional: log de depuración
  // console.log("charset elegido:", best.charset, "score:", best.score);
  return best.text;
}

function decodeHtmlFromPart(part) {
  const bytes = partToBuffer(part);
  const declared = detectCharset(part);
  const html = decodeBest(bytes, declared);
  return forceUtf8Meta(html);
}

function findPartRecursive(node, pred) {
  if (!node) return null;
  if (pred(node)) return node;
  const parts = node.parts || node.body?.parts || [];
  for (const p of parts) {
    const f = findPartRecursive(p, pred);
    if (f) return f;
  }
  return null;
}

function tryDecodeHtmlFromMime(mime) {
  if (!mime || !mime.payload) return null;

  const htmlPart = findPartRecursive(mime.payload, p => (p.mimeType||"").toLowerCase() === "text/html");
  if (htmlPart) return decodeHtmlFromPart(htmlPart);

  const txtPart  = findPartRecursive(mime.payload, p => (p.mimeType||"").toLowerCase() === "text/plain");
  if (txtPart) {
    const bytes = partToBuffer(txtPart);
    const declared = detectCharset(txtPart);
    return forceUtf8Meta(wrapTextAsHtml(decodeBest(bytes, declared)));
  }
  return null;
}

// POST /decode -> { mime } o { html_doc | html | text }
app.post("/decode", (req, res) => {
  const { html_doc, html, text, mime } = req.body || {};
  let out = null;

  if (mime) out = tryDecodeHtmlFromMime(mime); // primero MIME (mejor para charset/CTE)
  if (!out && html_doc) out = forceUtf8Meta(html_doc);
  if (!out && html)     out = forceUtf8Meta(html);
  if (!out && text)     out = wrapTextAsHtml(text);

  if (!out) {
    return res.status(400)
      .set("Content-Type","text/html; charset=utf-8")
      .send(wrapTextAsHtml("Falta body. Envía { mime } o { html/html_doc/text }."));
  }
  res.set("Content-Type","text/html; charset=utf-8").send(out);
});

const PORT = 8099;
app.listen(PORT, () => console.log(`Decoder listo en http://localhost:${PORT}`));
