import 'dotenv/config';
import express from 'express';

// === Config desde .env (usa el .env que ya tienes en la raÃ­z del proyecto) ===
const PORT  = process.env.PORT || 8088;
const OLLAMA = process.env.OLLAMA_URL || 'http://localhost:11434';
const QDRANT = process.env.QDRANT_URL || 'http://localhost:6333';
const COLL   = process.env.QDRANT_COLLECTION || 'rmsg_docs';

// --------------------------------- Utilidades ---------------------------------
const toASCII = (s) => s.normalize('NFD').replace(/[\u0300-\u036f]/g, '');

const getPayloadText = (p = {}) => {
  if (typeof p.text === 'string' && p.text.length > 0) return p.text;
  if (typeof p.text_b64 === 'string' && p.text_b64.length > 0) {
    try { return Buffer.from(p.text_b64, 'base64').toString('utf8'); } catch {}
  }
  return '';
};

function extractFields(s) {
  const take = (re) => {
    const m = s.match(re);
    return m ? m[1].trim() : null;
  };
  const renta     = take(/^\s*Renta\s*objetivo\s*:\s*([^\n]+)$/im);
  const vacancia  = take(/^\s*Vacancia\s*:\s*([^\n]+)$/im);
  const absorcion = take(/^\s*Absor(?:ciÃ³n|cion)\s*neta\s*:\s*([^\n]+)$/im);
  return { renta, vacancia, absorcion };
}

// --------------------------------- Ollama -------------------------------------
async function embed(text) {
  const r = await fetch(`${OLLAMA}/api/embeddings`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
    body: JSON.stringify({ model: 'nomic-embed-text', input: text })
  });
  if (!r.ok) throw new Error(`Ollama ${r.status} ${r.statusText}`);
  const j = await r.json();

  let vec = Array.isArray(j.embedding) ? j.embedding : null;
  if (!vec && Array.isArray(j.embeddings) && Array.isArray(j.embeddings[0])) {
    vec = j.embeddings[0];
  }
  if (!vec || vec.length !== 768) throw new Error('Embedding invÃ¡lido (esperaba 768 dims).');
  return vec;
}

// --------------------------------- Qdrant -------------------------------------
async function qdrantSearch(vector, k, namespace) {
  const body = {
    vector,
    limit: k,
    with_payload: true,
    ...(namespace ? { filter: { must: [{ key: 'namespace', match: { value: namespace } }] } } : {})
  };

  const r = await fetch(`${QDRANT}/collections/${COLL}/points/search`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
    body: JSON.stringify(body)
  });
  if (!r.ok) throw new Error(`Qdrant ${r.status} ${r.statusText}`);
  const j = await r.json();
  return Array.isArray(j.result) ? j.result : [];
}

// --------------------------------- App ----------------------------------------
const app = express();
app.use(express.json({ limit: '2mb' }));

// =============================== POST /chat ===================================
app.post('/chat', async (req, res) => {
  try {
    const {
      message = '',
      namespace = '',
      k = 3,
      return_sources = true,
      return_debug = true,
      ascii_only = false
    } = req.body || {};

    // 1) Embedding de la consulta
    const qvec = await embed(message || 'consulta');

    // 2) BÃºsqueda vectorial en Qdrant
    const hits = await qdrantSearch(qvec, k, namespace);

    // 3) Normalizar payloads y concatenar texto
    const docs = hits.map(h => {
      const payload = h.payload || {};
      const text = getPayloadText(payload);
      return { id: h.id, score: h.score, payload, text };
    }).filter(d => d.text && d.text.length > 0);

    const joined = docs.map(d => d.text).join('\n---\n');

    // 4) Extraer mÃ©tricas
    const { renta, vacancia, absorcion } = extractFields(joined);

    // 5) Formato de salida
    const bullets = [
      `Renta objetivo: ${renta ?? 'ND'}`,
      `Vacancia: ${vacancia ?? 'ND'}`,
      `AbsorciÃ³n neta: ${absorcion ?? 'ND'}`
    ];
    let answer = '- ' + bullets.join('\n- ');
    if (ascii_only === true) answer = toASCII(answer);

    // 6) Fuentes
    const sources = return_sources ? docs.map((d, i) => ({
      tag: `[S${i + 1}]`,
      title: d.payload.title || '(sin tÃ­tulo)',
      source: d.payload.source || '',
      score: d.score || 0,
      namespace: d.payload.namespace || '',
      id: d.id,
      snippet: (d.text || '').slice(0, 220),
      doc_id: d.payload.source || ''
    })) : undefined;

    // 7) Debug
    const debug = return_debug ? {
      qdrant_hits: hits.length,
      concatenated_len: joined.length
    } : undefined;

    res.set('Content-Type', 'application/json; charset=utf-8').json({ answer, sources, debug });
  } catch (err) {
    res.status(500).json({ error: String(err?.message || err) });
  }
});

// --------------------------------- Start --------------------------------------
app.listen(PORT, () => {
  console.log(`API listening on http://localhost:${PORT}/chat`);
});


