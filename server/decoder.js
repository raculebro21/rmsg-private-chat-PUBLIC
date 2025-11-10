// decoder.js  (micro-servidor solo para decodificar HTML de Gmail)
const express = require('express');
const qp = require('quoted-printable');
const iconv = require('iconv-lite');

const app = express();
app.use(express.json({ limit: '10mb' }));

function ensureUtf8Meta(html) {
  if (!html) return '';
  if (/<meta\s+charset=/i.test(html)) return html;
  if (/<head[^>]*>/i.test(html)) {
    return html.replace(/(<head[^>]*>)/i, '$1<meta charset="utf-8">');
  }
  return `<!doctype html><meta charset="utf-8">${html}`;
}

function wrapTextAsHtml(text) {
  const escaped = String(text)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
  return `<!doctype html><meta charset="utf-8"><pre>${escaped}</pre>`;
}

function base64UrlToBuffer(b64url) {
  let s = b64url || '';
  s = s.replace(/-/g, '+').replace(/_/g, '/'); // URL-safe -> estándar
  while (s.length % 4 !== 0) s += '=';
  return Buffer.from(s, 'base64');
}

function findPartRecursive(node, predicate) {
  if (!node) return null;
  if (predicate(node)) return node;
  const parts = node.parts || node.body?.parts || [];
  for (const p of parts) {
    const f = findPartRecursive(p, predicate);
    if (f) return f;
  }
  return null;
}

function decodeHtmlFromPart(part) {
  const raw = part?.body?.data || '';
  const buf = base64UrlToBuffer(raw);
  let text = buf.toString('utf8');

  const cte = (part.headers || []).find(h => /^content-transfer-encoding$/i.test(h.name))?.value || '';
  const looksQP = /=\r?\n|=3D[0-9A-F]{2}/i.test(text);
  if (/quoted-printable/i.test(cte) || looksQP) {
    const decoded = qp.decode(text);
    text = Buffer.isBuffer(decoded) ? iconv.decode(decoded, 'utf-8') : String(decoded);
  }
  return ensureUtf8Meta(text);
}

function tryDecodeHtmlFromMime(mime) {
  if (!mime || !mime.payload) return null;

  const htmlPart = findPartRecursive(mime.payload, p => (p.mimeType || '').toLowerCase() === 'text/html');
  if (htmlPart) return decodeHtmlFromPart(htmlPart);

  const txtPart = findPartRecursive(mime.payload, p => (p.mimeType || '').toLowerCase() === 'text/plain');
  if (txtPart) {
    const raw = txtPart?.body?.data || '';
    const buf = base64UrlToBuffer(raw);
    let text = buf.toString('utf8');

    const cte = (txtPart.headers || []).find(h => /^content-transfer-encoding$/i.test(h.name))?.value || '';
    const looksQP = /=\r?\n|=3D[0-9A-F]{2}/i.test(text);
    if (/quoted-printable/i.test(cte) || looksQP) {
      const decoded = qp.decode(text);
      text = Buffer.isBuffer(decoded) ? iconv.decode(decoded, 'utf-8') : String(decoded);
    }
    return wrapTextAsHtml(text);
  }
  return null;
}

// POST /decode  ->  { mime }  ó  { html_doc | html | text }
app.post('/decode', (req, res) => {
  const { html_doc, html, text, mime } = req.body || {};
  let out = null;

  if (html_doc) out = ensureUtf8Meta(html_doc);
  else if (html) out = ensureUtf8Meta(html);
  else if (mime) out = tryDecodeHtmlFromMime(mime);
  else if (text) out = wrapTextAsHtml(text);

  if (!out) {
    return res
      .status(400)
      .set('Content-Type', 'text/html; charset=utf-8')
      .send(wrapTextAsHtml('Falta body. Envía { mime } o { html/html_doc/text }.'));
  }
  res.set('Content-Type', 'text/html; charset=utf-8').send(out);
});

const PORT = 8099; // <- NO toca tu 8088
app.listen(PORT, () => console.log(`Decoder listo en http://localhost:${PORT}`));
