// CrocShare Windows — renderer.
// L'objectif visuel : coller à la version macOS (Theme.swift, ContentView.swift).

const { request, onEvent, openExternal, version, platform } = window.crocshare;

const state = {
  myPublicKey: '',
  myName: 'Moi',
  contacts: [],          // [{ key, name, online }]
  channels: [],          // [{ id, name, members }]
  chats: {},             // contactKey → [{ id, fromMe, fromName, text, date }]
  selectedRoute: null,   // 'myfiles' | 'sharedfolders' | 'settings' | { kind:'contact', key } | { kind:'channel', id }
};

const QUICK_TEST_BOT = {
  key: 'robot-test-bot-0000000000000000000000000000000000000000000000000',
  name: '🤖 Robot',
  online: true,
};

// ── Bootstrap ─────────────────────────────────────────────────
async function init() {
  console.log('CrocShare Windows', await version(), '/', await platform());

  // P2P companion start
  try {
    const r = await request('start', { displayName: state.myName });
    state.myPublicKey = r?.publicKey || '';
  } catch (e) {
    console.warn('start failed (utiliser preview UI sans core):', e);
  }

  // Contact démo pour visualiser le rendu si le core n'est pas joignable.
  state.contacts = [QUICK_TEST_BOT];

  // Tentative de chargement des contacts réels.
  try {
    const list = await request('contacts.list', {});
    if (Array.isArray(list) && list.length) state.contacts = list;
  } catch (e) { /* ignore */ }

  onEvent(handleCoreEvent);

  setupSidebarActions();
  renderSidebar();
}

function handleCoreEvent(evt) {
  switch (evt.event) {
    case 'peer.connected': setContactOnline(evt.params.contactKey, true); break;
    case 'peer.disconnected': setContactOnline(evt.params.contactKey, false); break;
    case 'peer.message': onIncomingMessage(evt.params); break;
    case 'core.ready': state.myPublicKey = evt.params.publicKey; break;
  }
}

// ── Sidebar render ──────────────────────────────────────────
function setupSidebarActions() {
  document.querySelectorAll('.nav-item[data-route]').forEach(btn => {
    btn.addEventListener('click', () => {
      const route = btn.dataset.route;
      state.selectedRoute = route;
      renderSidebar();
      renderContent();
    });
  });

  document.getElementById('add-contact-btn').addEventListener('click', async (e) => {
    e.stopPropagation();
    addContactFlow();
  });
  document.getElementById('welcome-pair').addEventListener('click', addContactFlow);

  document.querySelectorAll('.section-header').forEach(btn => {
    btn.addEventListener('click', (e) => {
      if (e.target.classList.contains('section-add')) return;
      const list = btn.nextElementSibling;
      const collapsed = list.style.display === 'none';
      list.style.display = collapsed ? 'flex' : 'none';
      btn.querySelector('.chev').textContent = collapsed ? '▼' : '▶';
    });
  });
}

function renderSidebar() {
  // Avatar utilisateur initial
  const initial = (state.myName || 'C').slice(0, 1).toUpperCase();
  document.getElementById('me-initial').textContent = initial;

  // Highlight active route
  document.querySelectorAll('.nav-item[data-route]').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.route === state.selectedRoute);
  });

  // Liste contacts (DM)
  const dmList = document.getElementById('contacts-list');
  dmList.innerHTML = '';
  if (state.contacts.length === 0) {
    dmList.innerHTML = '<li class="empty">Aucun contact</li>';
  } else {
    for (const c of state.contacts) {
      dmList.appendChild(renderContactRow(c, 'chat'));
    }
  }

  // Liste dossiers partagés (mêmes contacts, vue différente)
  const fl = document.getElementById('folders-list');
  fl.innerHTML = '';
  if (state.contacts.length === 0) {
    fl.innerHTML = '<li class="empty">Aucun contact fichier</li>';
  } else {
    for (const c of state.contacts) {
      const li = document.createElement('li');
      li.className = c.online ? 'online' : '';
      const isActive = state.selectedRoute?.kind === 'contact' &&
                       state.selectedRoute?.pane === 'files' &&
                       state.selectedRoute?.key === c.key;
      if (isActive) li.classList.add('active');
      li.innerHTML = `
        <span class="left-accent"></span>
        <span class="dot-only"><span class="dot"></span></span>
        <span class="nav-label">${escapeHTML(c.name || c.key.slice(0, 8))}</span>
      `;
      li.onclick = () => {
        state.selectedRoute = { kind: 'contact', key: c.key, pane: 'files' };
        renderSidebar();
        renderContent();
      };
      fl.appendChild(li);
    }
  }
}

function renderContactRow(c, pane) {
  const li = document.createElement('li');
  if (c.online) li.classList.add('online');
  const isActive = state.selectedRoute?.kind === 'contact' &&
                   (state.selectedRoute?.pane || 'chat') === pane &&
                   state.selectedRoute?.key === c.key;
  if (isActive) li.classList.add('active');

  const initial = (c.name || c.key).slice(0, 1).toUpperCase();
  const isBot = c.name && c.name.includes('🤖');
  const avatarContent = isBot ? '🤖' : initial;

  li.innerHTML = `
    <span class="left-accent"></span>
    <span class="avatar-wrap">
      <span class="avatar">${escapeHTML(avatarContent)}</span>
      <span class="presence-dot"></span>
    </span>
    <span class="nav-label">${escapeHTML(c.name || c.key.slice(0, 8))}</span>
  `;
  li.onclick = () => {
    state.selectedRoute = { kind: 'contact', key: c.key, pane };
    renderSidebar();
    renderContent();
  };
  return li;
}

function setContactOnline(key, online) {
  const c = state.contacts.find(x => x.key === key);
  if (c) { c.online = online; renderSidebar(); }
}

// ── Contenu principal ──────────────────────────────────────
function renderContent() {
  const content = document.getElementById('content');
  const right = document.getElementById('right-panel');
  const r = state.selectedRoute;

  if (!r || r === 'myfiles' || r === 'sharedfolders' || r === 'settings') {
    content.innerHTML = `
      <div id="welcome" class="welcome">
        <div class="welcome-icon">⚡</div>
        <h1>CrocShare</h1>
        <p class="muted">Page « ${escapeHTML(r || 'Accueil')} » — en cours de portage.</p>
      </div>`;
    right.classList.add('hidden');
    return;
  }

  if (r.kind === 'contact' && (r.pane || 'chat') === 'chat') {
    renderChat(r.key);
    return;
  }
  if (r.kind === 'contact' && r.pane === 'files') {
    renderFilesPlaceholder(r.key);
    return;
  }
}

function renderChat(key) {
  const c = state.contacts.find(x => x.key === key);
  if (!c) return;
  const content = document.getElementById('content');
  content.innerHTML = `
    <div class="chat-header">
      <div class="header-avatar-wrap">
        <div class="header-avatar">${escapeHTML((c.name || '?').slice(0, 1).toUpperCase())}</div>
        <span class="presence-dot"></span>
      </div>
      <div>
        <div class="name">${escapeHTML(c.name || c.key.slice(0, 8))}</div>
        <div class="status ${c.online ? '' : 'offline'}">${c.online ? 'en ligne · chiffré P2P' : 'hors ligne'}</div>
      </div>
      <div class="toolbar">
        <button title="Appeler" id="call-btn">📞</button>
      </div>
    </div>
    <div class="chat-body" id="chat-body"></div>
    <div class="composer">
      <div class="formatting">
        <button title="Gras"><b>B</b></button>
        <button title="Italique"><i>I</i></button>
        <button title="Barré"><s>S</s></button>
        <button title="Code">&lt;/&gt;</button>
        <div class="sep"></div>
        <button title="Liste à puces">•</button>
        <button title="Liste numérotée">1.</button>
        <button title="Lien">🔗</button>
        <button title="Emoji">😀</button>
      </div>
      <div class="input-row">
        <button class="icon-btn" title="Joindre un fichier">📎</button>
        <button class="icon-btn" title="Message audio">🎙</button>
        <textarea id="composer-input" rows="1" placeholder="Message P2P à ${escapeHTML(c.name || '')}…"></textarea>
        <button class="send-btn" id="send-btn" title="Envoyer">➤</button>
      </div>
    </div>
  `;

  renderMessages(key);

  const input = document.getElementById('composer-input');
  input.focus();
  input.addEventListener('keydown', e => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendCurrent(); }
  });
  document.getElementById('send-btn').addEventListener('click', sendCurrent);
  document.getElementById('call-btn').addEventListener('click', () => {
    alert('Appels : disponibles dans la prochaine version Electron.');
  });

  // Auto-grow textarea
  input.addEventListener('input', () => {
    input.style.height = 'auto';
    input.style.height = Math.min(140, input.scrollHeight) + 'px';
  });

  // Right info panel
  renderProfilePanel(c);
}

function renderMessages(key) {
  const body = document.getElementById('chat-body');
  if (!body) return;
  body.innerHTML = '';
  const msgs = state.chats[key] || [];
  if (msgs.length === 0) {
    body.innerHTML = `<div class="day-divider"><div class="pill">Aujourd'hui</div></div>`;
  }

  let lastSender = null;
  for (const m of msgs) {
    const showHeader = m.fromName !== lastSender;
    const row = document.createElement('div');
    row.className = 'msg-row' + (showHeader ? ' with-header' : '');
    const initial = (m.fromName || '?').slice(0, 1).toUpperCase();
    const isBot = m.fromName && m.fromName.includes('🤖');
    row.innerHTML = `
      <div class="avatar-slot">
        ${showHeader ? `<div class="msg-avatar">${escapeHTML(isBot ? '🤖' : initial)}</div>` : ''}
      </div>
      <div class="msg-content">
        ${showHeader ? `<div class="msg-header">
          <span class="msg-name">${escapeHTML(m.fromName || 'Moi')}</span>
          <span class="msg-time">${formatTime(m.date)}</span>
        </div>` : ''}
        <div class="msg-text">${escapeHTML(m.text)}</div>
      </div>
    `;
    body.appendChild(row);
    lastSender = m.fromName;
  }
  body.scrollTop = body.scrollHeight;
}

async function sendCurrent() {
  const input = document.getElementById('composer-input');
  const text = input.value.trim();
  if (!text) return;
  const key = state.selectedRoute?.key;
  if (!key) return;

  const id = crypto.randomUUID();
  const msg = { id, fromMe: true, fromName: state.myName, text, date: Date.now() };
  state.chats[key] = (state.chats[key] || []).concat(msg);
  renderMessages(key);
  input.value = '';
  input.style.height = 'auto';

  // Echo "bot" si on parle au robot (UI demo).
  if (key === QUICK_TEST_BOT.key) {
    setTimeout(() => {
      const reply = {
        id: crypto.randomUUID(), fromMe: false, fromName: '🤖 Robot',
        text: 'Reçu ! Le compagnon Node n\'est pas encore branché côté Electron, mais l\'UI fonctionne.',
        date: Date.now()
      };
      state.chats[key].push(reply);
      renderMessages(key);
    }, 400);
  }

  try {
    await request('peer.send', {
      contactKey: key,
      payload: { k: 'msg', id, t: text, ts: msg.date }
    });
  } catch (e) { /* offline / core not running */ }
}

function onIncomingMessage(p) {
  if (p.payload?.k !== 'msg') return;
  const key = p.contactKey;
  const m = {
    id: p.payload.id,
    fromMe: false,
    fromName: p.fromName || 'Pair',
    text: p.payload.t || '',
    date: p.payload.ts || Date.now()
  };
  state.chats[key] = (state.chats[key] || []).concat(m);
  if (state.selectedRoute?.kind === 'contact' && state.selectedRoute?.key === key) {
    renderMessages(key);
  }
}

function renderFilesPlaceholder(key) {
  const c = state.contacts.find(x => x.key === key);
  const content = document.getElementById('content');
  content.innerHTML = `
    <div class="welcome">
      <div class="welcome-icon">📁</div>
      <h1>Fichiers de ${escapeHTML(c?.name || '?')}</h1>
      <p class="muted">Cette vue (browser de fichiers) est à porter sur Electron.<br/>Côté Mac, c'est FilesBrowser.swift.</p>
    </div>`;
  document.getElementById('right-panel').classList.add('hidden');
}

function renderProfilePanel(c) {
  const right = document.getElementById('right-panel');
  right.classList.remove('hidden');
  const initial = (c.name || '?').slice(0, 1).toUpperCase();
  const isBot = c.name && c.name.includes('🤖');
  right.querySelector('.right-content').innerHTML = `
    <div class="profile-panel">
      <div class="big-avatar">
        ${escapeHTML(isBot ? '🤖' : initial)}
        <span class="presence-dot"></span>
      </div>
      <div class="profile-name">${escapeHTML(c.name || c.key.slice(0, 8))}</div>
      <div class="profile-status">${c.online ? 'en ligne · P2P chiffré' : 'hors ligne'}</div>
      <button class="files-btn">📁 Voir ses fichiers</button>
    </div>
    <div class="about-section">
      <div class="section-label">À PROPOS</div>
      <div class="about-row">
        <span class="label">Identité</span>
        <span class="value" title="${escapeHTML(c.key)}">${escapeHTML(c.key.slice(0, 20))}…</span>
      </div>
      <div class="about-row">
        <span class="label">Fichiers partagés</span>
        <span class="value">0</span>
      </div>
    </div>
  `;
}

// ── Ajouter un contact ──────────────────────────────────────
async function addContactFlow() {
  const code = prompt("Saisis le code d'appairage reçu (cs1-…)\nLaisse vide pour en générer un :");
  if (code === null) return;
  if (code.trim()) {
    try { await request('pairing.join', { code: code.trim() }); }
    catch (e) { alert('Échec : ' + e.message); }
  } else {
    try {
      const r = await request('pairing.create', {});
      prompt('Transmets ce code à ton contact :', r?.code || '');
    } catch (e) { alert('Échec : ' + e.message); }
  }
}

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
