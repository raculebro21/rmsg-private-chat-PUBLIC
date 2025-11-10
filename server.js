// server.js  (CommonJS)
const express = require('express');
const qp = require('quoted-printable');
const iconv = require('iconv-lite');

const app = express();
app.use(express.json({ limit: '10mb' })); // por si el payload es grande

// ---------- utilidades ----------
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
  // Gmail usa base64 URL-safe
  s = s.replace(/-/g, '+').replace(/_/g, '/');
  // pad
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
  // 1) bytes de base64url
  const raw = part?.body?.data || '';
  const buf = base64UrlToBuffer(raw);
  let text = buf.toString('utf8');

  // 2) ¿Sigue en quoted-printable?
  const cte = (part.headers || []).find(h => /^content-transfer-encoding$/i.test(h.name))?.value || '';
  const looksQP = /=\r?\n|=3D[0-9A-F]{2}/i.test(text);

  if (/quoted-printable/i.test(cte) || looksQP) {
    const decodedBufOrStr = qp.decode(text); // lib puede devolver Buffer
    text = Buffer.isBuffer(decodedBufOrStr) ? iconv.decode(decodedBufOrStr, 'utf-8') : String(decodedBufOrStr);
  }

  return ensureUtf8Meta(text);
}

function tryDecodeHtmlFromMime(mime) {
  if (!mime || !mime.payload) return null;

  // busca text/html en cualquier nivel
  const htmlPart = findPartRecursive(mime.payload, p => (p.mimeType || '').toLowerCase() === 'text/html');
  if (htmlPart) return decodeHtmlFromPart(htmlPart);

  // fallback: text/plain como HTML envuelto
  const txtPart = findPartRecursive(mime.payload, p => (p.mimeType || '').toLowerCase() === 'text/plain');
  if (txtPart) {
    const raw = txtPart?.body?.data || '';
    const buf = base64UrlToBuffer(raw);
    let text = buf.toString('utf8');
    const cte = (txtPart.headers || []).find(h => /^content-transfer-encoding$/i.test(h.name))?.value || '';
    const looksQP = /=\r?\n|=3D[0-9A-F]{2}/i.test(text);
    if (/quoted-printable/i.test(cte) || looksQP) {
      const decodedBufOrStr = qp.decode(text);
      text = Buffer.isBuffer(decodedBufOrStr) ? iconv.decode(decodedBufOrStr, 'utf-8') : String(decodedBufOrStr);
    }
    return wrapTextAsHtml(text);
  }

  return null;
}

// ---------- rutas mínimas ----------
// (Si ya tienes /gmail/list y /gmail/get en otro archivo, déjalos allí tal cual.)

app.post('/gmail/get_body', async (req, res) => {
  // Este endpoint soporta dos modos:
  // 1) Recibe { mime: <payload de Gmail> } y decodifica aquí
  // 2) Recibe { html_doc | html | text } directo
  // (Si solo te mandan {id}, no podemos ir a Gmail aquí sin tu lógica/tokens.)

  const { html_doc, html, text, mime } = req.body || {};

  let out = null;

  if (html_doc) out = ensureUtf8Meta(html_doc);
  else if (html) out = ensureUtf8Meta(html);
  else if (mime) out = tryDecodeHtmlFromMime(mime);
  else if (text) out = wrapTextAsHtml(text);

  if (!out) {
    // Si te envían SOLO {id}, devuelve instructivo claro
    return res
      .status(400)
      .set('Content-Type', 'text/html; charset=utf-8')
      .send(wrapTextAsHtml(
        'Este endpoint necesita: {mime} (payload de Gmail) o {html}/{html_doc}/{text}. ' +
        'Actualiza tu función PowerShell para enviar req.body.mime con el meta de /gmail/get.'
      ));
  }

  res.set('Content-Type', 'text/html; charset=utf-8').send(out);
});

const PORT = process.env.PORT || 8088;
app.listen(PORT, () => {
  console.log(`Server listo en http://localhost:${PORT}`);
});
