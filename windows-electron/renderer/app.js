// CrocShare Windows — renderer minimal (vanilla JS).
// Cible un MVP fonctionnel : sidebar des contacts/salons + vue chat basique.
// Une version React/Vue propre viendra dans une PR dédiée.

const { request, onEvent, openExternal, version, platform } = window.crocshare;

const state = {
  myPublicKey: '',
  myName: '',
  contacts: [],          // [{ key, name, online }]
  channels: [],          // [{ id, name, members }]
  chats: {},             // contactKey → [{ id, fromMe, text, date }]
  selectedKey: null
};

// ── Bootstrap ─────────────────────────────────────────────────
async function init() {
  console.log('CrocShare renderer, version', await version(), 'platform', await platform());

  // Démarre le core P2P (Hyperswarm). Idempotent côté main.
  try {
    const result = await request('start', { displayName: 'Moi (Windows)' });
    state.myPublicKey = result?.publicKey || '';
    document.getElementById('me-avatar').textContent = (result?.publicKey || 'M').slice(0, 1).toUpperCase();
    document.getElementById('me-status').textContent = 'P2P chiffré';
  } catch (e) {
    console.error('start failed:', e);
    document.getElementById('me-status').textContent = 'Erreur P2P';
  }

  // Récupère la liste des contacts persistés.
  try {
    const list = await request('contacts.list', {});
    state.contacts = list || [];
    renderContacts();
  } catch (e) {
    console.warn('contacts.list:', e);
  }

  // Abonne aux events.
  onEvent(handleCoreEvent);
}

function handleCoreEvent(evt) {
  console.log('event:', evt.event, evt.params);
  switch (evt.event) {
    case 'peer.connected':
      markContactOnline(evt.params.contactKey, true);
      break;
    case 'peer.disconnected':
      markContactOnline(evt.params.contactKey, false);
      break;
    case 'peer.message':
      receiveMessage(evt.params);
      break;
    case 'core.ready':
      state.myPublicKey = evt.params.publicKey;
      break;
  }
}

// ── UI : sidebar contacts ─────────────────────────────────────
function renderContacts() {
  const ul = document.getElementById('contacts-list');
  ul.innerHTML = '';
  if (state.contacts.length === 0) {
    const li = document.createElement('li');
    li.className = 'empty';
    li.textContent = 'Aucun contact';
    ul.appendChild(li);
    return;
  }
  for (const c of state.contacts) {
    const li = document.createElement('li');
    if (c.online) li.classList.add('online');
    if (state.selectedKey === c.key) li.classList.add('active');
    li.innerHTML = `<span class="presence-dot"></span><span>${escapeHTML(c.name || c.key.slice(0, 8))}</span>`;
    li.onclick = () => selectContact(c.key);
    ul.appendChild(li);
  }
}

function markContactOnline(key, online) {
  const c = state.contacts.find(x => x.key === key);
  if (c) {
    c.online = online;
    renderContacts();
  }
}

function selectContact(key) {
  state.selectedKey = key;
  renderContacts();
  renderChat();
}

// ── UI : vue chat ────────────────────────────────────────────
function renderChat() {
  const content = document.getElementById('content');
  const contact = state.contacts.find(c => c.key === state.selectedKey);
  if (!contact) return;

  content.innerHTML = `
    <div class="chat-header">
      <div class="avatar">${escapeHTML((contact.name || '?').slice(0, 1).toUpperCase())}</div>
      <div>
        <div class="name">${escapeHTML(contact.name || contact.key.slice(0, 8))}</div>
        <div class="status">${contact.online ? 'en ligne · chiffré P2P' : 'hors ligne'}</div>
      </div>
    </div>
    <div class="chat-body" id="chat-body"></div>
    <div class="composer">
      <input type="text" id="composer-input" placeholder="Message…" autofocus />
      <button id="composer-send">Envoyer</button>
    </div>
  `;

  renderMessages();

  const input = document.getElementById('composer-input');
  const send = () => {
    const text = input.value.trim();
    if (!text) return;
    sendMessage(text);
    input.value = '';
  };
  input.addEventListener('keydown', e => { if (e.key === 'Enter') send(); });
  document.getElementById('composer-send').addEventListener('click', send);
}

function renderMessages() {
  const body = document.getElementById('chat-body');
  if (!body) return;
  body.innerHTML = '';
  const msgs = state.chats[state.selectedKey] || [];
  for (const m of msgs) {
    const div = document.createElement('div');
    div.className = 'msg' + (m.fromMe ? ' me' : '');
    div.innerHTML = `<div class="bubble">${escapeHTML(m.text)}<div class="meta">${formatTime(m.date)}</div></div>`;
    body.appendChild(div);
  }
  body.scrollTop = body.scrollHeight;
}

async function sendMessage(text) {
  if (!state.selectedKey) return;
  const id = crypto.randomUUID();
  const msg = { id, fromMe: true, text, date: Date.now() };
  state.chats[state.selectedKey] = (state.chats[state.selectedKey] || []).concat(msg);
  renderMessages();
  try {
    await request('peer.send', {
      contactKey: state.selectedKey,
      payload: { k: 'msg', id, t: text, ts: msg.date }
    });
  } catch (e) {
    console.warn('send failed:', e);
  }
}

function receiveMessage(p) {
  // Format du payload : voir P2PEngine.handlePayload côté macOS.
  if (p.payload?.k !== 'msg') return;
  const key = p.contactKey;
  const m = {
    id: p.payload.id,
    fromMe: false,
    text: p.payload.t || '',
    date: p.payload.ts || Date.now()
  };
  state.chats[key] = (state.chats[key] || []).concat(m);
  if (key === state.selectedKey) renderMessages();
}

// ── Ajouter un contact (placeholder) ─────────────────────────
document.getElementById('add-contact-btn').addEventListener('click', async () => {
  const code = prompt('Saisis le code d\'appairage reçu (cs1-…)\nOu laisse vide pour en générer un :');
  if (code) {
    try { await request('pairing.join', { code }); }
    catch (e) { alert('Échec : ' + e.message); }
  } else {
    try {
      const r = await request('pairing.create', {});
      prompt('Transmets ce code à ton contact :', r?.code || '');
    } catch (e) { alert('Échec : ' + e.message); }
  }
});

// ── Helpers ──────────────────────────────────────────────────
function escapeHTML(s) {
  return String(s).replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[c]));
}

function formatTime(ts) {
  const d = new Date(ts);
  return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

init();
