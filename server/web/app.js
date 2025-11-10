const API = "http://127.0.0.1:8080";
function authHeaders(token){ return { "Authorization": "Bearer " + token }; }

// ------- Ingest ----------
let ingestBusy = false;
document.getElementById("ingestBtn").onclick = async (e) => {
  e.preventDefault(); e.stopPropagation();
  if (ingestBusy) return;

  const btn    = document.getElementById("ingestBtn");
  const token  = document.getElementById("token").value.trim();
  const ns     = document.getElementById("ns").value.trim() || "default";
  const filesEl= document.getElementById("files");
  const files  = filesEl.files;

  if (!token) return alert("Paste your token first.");
  if (!files.length) return alert("Choose files to ingest.");

  const fd = new FormData();
  for (const f of files) fd.append("files", f);

  ingestBusy = true;
  const oldText = btn.textContent;
  btn.textContent = "Ingesting...";
  btn.disabled = true;

  try {
    const res = await fetch(`${API}/ingest?namespace=${encodeURIComponent(ns)}`, {
      method: "POST",
      headers: authHeaders(token),
      body: fd
    });
    if (!res.ok) throw new Error(await res.text());
    const data = await res.json();
    alert(`Ingested chunks: ${data.inserted_chunks} into namespace: ${data.namespace}`);
    filesEl.value = "";
  } catch (err) {
    console.error(err);
    alert("Ingest failed: " + (err?.message || "see console"));
  } finally {
    btn.textContent = oldText;
    btn.disabled = false;
    ingestBusy = false;
  }
};

// ------- Chat ----------
document.getElementById("askBtn").onclick = async (e) => {
  e.preventDefault(); e.stopPropagation();

  const token   = document.getElementById("token").value.trim();
  const ns      = document.getElementById("ns").value.trim() || "default";
  const message = document.getElementById("msg").value.trim();

  if (!token)   return alert("Paste your token first.");
  if (!message) return alert("Type a message.");

  const ansEl = document.getElementById("answer");
  const srcEl = document.getElementById("sources");
  ansEl.textContent = "Thinking...";
  srcEl.textContent = "";

  try {
    const res = await fetch(`${API}/chat`, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...authHeaders(token) },
      body: JSON.stringify({ message, namespace: ns, k: 3 })
    });
    if (!res.ok) { ansEl.textContent = "Error: " + (await res.text()); return; }
    const data = await res.json();
    ansEl.textContent = data.answer || "(no answer)";
    const pills = (data.sources || []).map(
      s => `<span class="pill">${s.source || "?"} #${s.index ?? "?"}</span>`
    ).join(" ");
    srcEl.innerHTML = pills ? ("Sources: " + pills) : "";
  } catch (err) {
    console.error(err);
    ansEl.textContent = "Request failed. See console.";
  }
};
