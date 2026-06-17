// CrocShare Windows — renderer.
// L'objectif visuel : coller à la version macOS (Theme.swift, ContentView.swift).

import { loadLanguage, L } from './i18n.js';
import { renderSettings } from './settings.js';
import { openPairingModal } from './pairing.js';
import {
  buildHoverBar, showEmojiPicker, toggleReaction, sendReaction,
  sendDelete, pickAndSendAttachment, sendAttachmentFromPath,
  AudioRecorder, renderAttachment, openLightbox
} from './chat-features.js';

const { request, onEvent, openExternal, version, platform, storagePath, config } = window.crocshare;
// Expose le state au module Settings.
window.crocshareState = null;

const state = {
  myPublicKey: '',
  myName: 'Moi',
  contacts: [],          // [{ key, name, online }]
  channels: [],
  chats: {},             // contactKey → [{ id, fromMe, fromName, text, date, attachment?, replyTo?, reactions? }]
  selectedRoute: null,
  threadRoot: null,      // message racine ouvert dans le thread panel
  audioRec: null,        // AudioRecorder en cours
};

// Path local pour fichiers reçus (download base)
let DOWNLOAD_BASE = '';

const QUICK_TEST_BOT = {
  key: 'robot-test-bot-0000000000000000000000000000000000000000000000000',
  name: '🤖 Robot',
  online: true,
};

// ── Bootstrap ─────────────────────────────────────────────────
async function init() {
  console.log('CrocShare Windows', await version(), '/', await platform());

  // Charge la langue avant tout rendu.
  await loadLanguage();

  // Lit la config persistée
  const cfg = await window.crocshare.config.get();
  if (cfg.myName) state.myName = cfg.myName;
  window.crocshareState = state;

  // Init du compagnon P2P : équivalent du `start` côté Mac.
  // On passe storagePath et displayName ; la seed est persistée localement
  // pour conserver l'identité entre sessions.
  try {
    const stPath = await storagePath();
    const seed = cfg.identitySeed || undefined;
    const r = await request('init', {
      storagePath: stPath,
      displayName: state.myName,
      seed,
    });
    state.myPublicKey = r?.publicKey || '';
    // Si le core a généré une nouvelle seed (1er lancement), on la stocke.
    if (r?.seed) {
      await window.crocshare.config.set({ identitySeed: r.seed });
    }
  } catch (e) {
    console.warn('init failed:', e);
  }

  // Contact démo pour visualiser le rendu si le core n'est pas joignable.
  state.contacts = [QUICK_TEST_BOT];

  // Tentative de chargement des contacts réels (le core renvoie { contacts: [...] }).
  try {
    const r = await request('contacts.list', {});
    if (r?.contacts?.length) {
      state.contacts = r.contacts.map(c => ({
        key: c.key,
        name: c.name || c.key.slice(0, 8),
        online: false,
      }));
    }
  } catch (e) { /* ignore */ }

  onEvent(handleCoreEvent);

  setupSidebarActions();
  renderSidebar();
}

function handleCoreEvent(evt) {
  switch (evt.event) {
    case 'peer.connected': onPeerConnected(evt.params); break;
    case 'peer.disconnected': setContactOnline(evt.params.contactKey, false); break;
    case 'peer.message': onIncomingMessage(evt.params); break;
    case 'peer.fileReceived': onFileReceived(evt.params); break;
    case 'core.ready': state.myPublicKey = evt.params.publicKey; break;
    case 'core.error':
      console.warn('core.error:', evt.params); break;
  }
}

function onFileReceived({ contactKey, relPath, absPath }) {
  // Trouve le message correspondant et marque l'attachment comme téléchargé.
  const list = state.chats[contactKey] || [];
  const msg = list.find(m => m.attachment?.relPath === relPath);
  if (msg) {
    msg.attachment.localPath = absPath;
    if (state.selectedRoute?.kind === 'contact' && state.selectedRoute?.key === contactKey) {
      renderMessages(contactKey);
    }
  }
}

function onPeerConnected({ contactKey, name }) {
  let c = state.contacts.find(x => x.key === contactKey);
  if (!c) {
    // Premier pairing : le contact arrive en live.
    c = { key: contactKey, name: name || contactKey.slice(0, 8), online: true };
    state.contacts.push(c);
  } else {
    c.online = true;
    if (name) c.name = name;
  }
  renderSidebar();
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

  if (r === 'settings') {
    right.classList.add('hidden');
    content.innerHTML = '';
    renderSettings(content, {
      refreshHeader: renderSidebar,
      refreshView: () => renderContent(),
    });
    return;
  }

  if (!r || r === 'myfiles' || r === 'sharedfolders') {
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
        <div class="header-avatar">${escapeHTML(headerAvatarText(c))}</div>
        <span class="presence-dot" style="${c.online ? '' : 'background:#6B6B70'}"></span>
      </div>
      <div>
        <div class="name">${escapeHTML(c.name || c.key.slice(0, 8))}</div>
        <div class="status ${c.online ? '' : 'offline'}">${c.online ? 'en ligne · chiffré P2P' : 'hors ligne'}</div>
      </div>
      <div class="toolbar">
        <button title="Appeler" id="call-btn">📞</button>
        <button title="Infos" id="info-btn">ℹ️</button>
      </div>
    </div>
    <div class="chat-body" id="chat-body"></div>
    <div class="composer" id="composer">
      <div class="formatting">
        <button title="Gras"><b>B</b></button>
        <button title="Italique"><i>I</i></button>
        <button title="Barré"><s>S</s></button>
        <button title="Code">&lt;/&gt;</button>
        <div class="sep"></div>
        <button title="Liste à puces">•</button>
        <button title="Liste numérotée">1.</button>
        <button title="Lien">🔗</button>
        <button title="Emoji" id="composer-emoji">😀</button>
      </div>
      <div class="input-row">
        <button class="icon-btn" title="Joindre un fichier" id="attach-btn">📎</button>
        <button class="icon-btn" title="Message audio" id="mic-btn">🎙</button>
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

  // Emoji picker du composer
  document.getElementById('composer-emoji').addEventListener('click', e => {
    showEmojiPicker(e.currentTarget, (emoji) => {
      input.value += emoji;
      input.focus();
    });
  });

  // Attach
  document.getElementById('attach-btn').addEventListener('click', async () => {
    await pickAndSendAttachment({
      contactKey: key,
      scope: c.name || c.key.slice(0, 8),
      sendMessage: ({ attachment }) => buildAndSendMessage(key, '', attachment),
    });
  });

  // Mic
  document.getElementById('mic-btn').addEventListener('click', () => toggleAudioRecording(key, c));

  document.getElementById('call-btn').addEventListener('click', () => {
    alert('Appels : prévus dans la prochaine version Electron.');
  });

  // Drag-drop : accepte un fichier sur la zone chat-body
  const body = document.getElementById('chat-body');
  body.addEventListener('dragover', e => { e.preventDefault(); });
  body.addEventListener('drop', async (e) => {
    e.preventDefault();
    const f = e.dataTransfer.files[0];
    if (!f) return;
    // En Electron, on récupère f.path (webContents permission).
    const path = f.path;
    if (!path) return;
    await sendAttachmentFromPath(path, {
      contactKey: key,
      scope: c.name || c.key.slice(0, 8),
      sendMessage: ({ attachment }) => buildAndSendMessage(key, '', attachment),
    });
  });

  // Auto-grow textarea
  input.addEventListener('input', () => {
    input.style.height = 'auto';
    input.style.height = Math.min(140, input.scrollHeight) + 'px';
  });

  // Right info panel
  renderProfilePanel(c);
}

function headerAvatarText(c) {
  if (c.name && c.name.includes('🤖')) return '🤖';
  return (c.name || c.key).slice(0, 1).toUpperCase();
}

function renderMessages(key) {
  const body = document.getElementById('chat-body');
  if (!body) return;
  body.innerHTML = '';
  // On n'affiche que les top-level (pas les réponses thread)
  const all = state.chats[key] || [];
  const msgs = all.filter(m => !m.replyTo);
  if (msgs.length === 0) {
    body.innerHTML = `<div class="day-divider"><div class="pill">Aujourd'hui</div></div>`;
  }

  let lastSender = null;
  for (const m of msgs) {
    const showHeader = m.fromName !== lastSender;
    const row = renderMessageRow(m, { showHeader, contactKey: key, threadCount: replyCount(all, m.id) });
    body.appendChild(row);
    lastSender = m.fromName;
  }
  body.scrollTop = body.scrollHeight;
}

function renderMessageRow(m, { showHeader, contactKey, threadCount }) {
  const row = document.createElement('div');
  row.className = 'msg-row' + (showHeader ? ' with-header' : '');
  const initial = (m.fromName || '?').slice(0, 1).toUpperCase();
  const isBot = m.fromName && m.fromName.includes('🤖');
  const avatarTxt = isBot ? '🤖' : initial;

  // Structure
  const avatarSlot = document.createElement('div');
  avatarSlot.className = 'avatar-slot';
  if (showHeader) {
    avatarSlot.innerHTML = `<div class="msg-avatar">${escapeHTML(avatarTxt)}</div>`;
  }
  const content = document.createElement('div');
  content.className = 'msg-content';
  if (showHeader) {
    content.innerHTML = `
      <div class="msg-header">
        <span class="msg-name">${escapeHTML(m.fromName || 'Moi')}</span>
        <span class="msg-time">${formatTime(m.date)}</span>
      </div>
    `;
  }
  if (m.text) {
    const txt = document.createElement('div');
    txt.className = 'msg-text';
    txt.textContent = m.text;
    content.appendChild(txt);
  }
  if (m.attachment) {
    const localUrl = m.attachment.localPath ? 'file://' + m.attachment.localPath.replace(/\\/g, '/') : null;
    content.appendChild(renderAttachment(m.attachment, localUrl));
  }
  // Réactions
  if (m.reactions && Object.keys(m.reactions).length) {
    const wrap = document.createElement('div');
    wrap.className = 'msg-reactions';
    for (const [emoji, reactors] of Object.entries(m.reactions)) {
      const pill = document.createElement('button');
      const mine = reactors.includes(state.myPublicKey);
      pill.className = 'react-pill' + (mine ? ' mine' : '');
      pill.innerHTML = `${emoji}<span class="count">${reactors.length}</span>`;
      pill.addEventListener('click', () => onReact(contactKey, m.id, emoji));
      wrap.appendChild(pill);
    }
    content.appendChild(wrap);
  }
  // Bouton thread si réponses existent
  if (threadCount > 0) {
    const tb = document.createElement('button');
    tb.style.cssText = 'background:transparent;border:1px solid #37373C;border-radius:8px;padding:3px 8px;color:#60A5FA;font-size:12px;margin-top:4px;cursor:pointer;';
    tb.textContent = `💬 ${threadCount} réponse${threadCount > 1 ? 's' : ''}`;
    tb.addEventListener('click', () => openThread(contactKey, m));
    content.appendChild(tb);
  }

  row.appendChild(avatarSlot);
  row.appendChild(content);

  // Hover bar
  row.appendChild(buildHoverBar({
    messageId: m.id,
    contactKey,
    fromMe: m.fromMe,
    onReact: (e) => onReact(contactKey, m.id, e),
    onOpenPicker: (anchor) => showEmojiPicker(anchor, (e) => onReact(contactKey, m.id, e)),
    onReply: () => openThread(contactKey, m),
    onDelete: () => {
      sendDelete(contactKey, m.id);
      const list = state.chats[contactKey] || [];
      const idx = list.findIndex(x => x.id === m.id);
      if (idx >= 0) { list.splice(idx, 1); renderMessages(contactKey); }
    }
  }));

  return row;
}

function replyCount(list, parentId) {
  return list.filter(m => m.replyTo === parentId).length;
}

function onReact(contactKey, messageId, emoji) {
  const m = findMessage(contactKey, messageId);
  if (!m) return;
  m.reactions = m.reactions || {};
  const add = toggleReaction(m.reactions, emoji, state.myPublicKey, contactKey);
  sendReaction(contactKey, messageId, emoji, add);
  if (state.selectedRoute?.key === contactKey) renderMessages(contactKey);
}

async function sendCurrent() {
  const input = document.getElementById('composer-input');
  const text = input.value.trim();
  if (!text) return;
  const key = state.selectedRoute?.key;
  if (!key) return;
  await buildAndSendMessage(key, text, null);
  input.value = '';
  input.style.height = 'auto';
}

async function buildAndSendMessage(key, text, attachment, replyTo = null) {
  const id = crypto.randomUUID();
  const msg = {
    id, fromMe: true, fromName: state.myName,
    text: text || '', date: Date.now(),
    attachment, replyTo, reactions: {},
  };
  state.chats[key] = (state.chats[key] || []).concat(msg);
  if (state.selectedRoute?.key === key) renderMessages(key);

  // Echo "bot" si on parle au robot (UI demo).
  if (key === QUICK_TEST_BOT.key) {
    setTimeout(() => {
      const reply = {
        id: crypto.randomUUID(), fromMe: false, fromName: '🤖 Robot',
        text: "Reçu ! En P2P réel avec un pair distant, ton message a déjà été délivré.",
        date: Date.now(), reactions: {}
      };
      state.chats[key].push(reply);
      if (state.selectedRoute?.key === key) renderMessages(key);
    }, 400);
  }

  const payload = { k: 'msg', id, t: text, ts: msg.date };
  if (attachment) payload.att = { fileName: attachment.fileName, relPath: attachment.relPath, size: attachment.size };
  if (replyTo) payload.rt = replyTo;
  try {
    await request('peer.send', { contactKey: key, payload });
  } catch (e) {
    console.warn('send failed:', e);
  }
}

// ─── Audio recording ───────────────────────────────────────────────

async function toggleAudioRecording(key, contact) {
  const composer = document.getElementById('composer');
  if (state.audioRec) {
    // Stop + send
    try {
      const { buffer, ext } = await state.audioRec.stop();
      state.audioRec = null;
      composer.classList.remove('recording');
      composer.querySelector('.recording-status')?.remove();
      // Sauvegarde temporaire pour passer le path à peer.sendFile
      const blob = new Blob([buffer]);
      const url = URL.createObjectURL(blob);
      // En Electron, on n'a pas écriture directe disque sans IPC. Cas simple :
      // on attache juste la pièce-jointe locale via blob URL (lecture chez moi).
      // Pour l'envoi P2P, on doit écrire sur disque d'abord.
      const tmpName = `voice-${crypto.randomUUID().slice(0, 8)}.${ext}`;
      const tmpPath = await window.crocshare.saveTempBuffer?.(tmpName, buffer)
                      ?? null;
      if (tmpPath) {
        await sendAttachmentFromPath(tmpPath, {
          contactKey: key,
          scope: contact.name || contact.key.slice(0, 8),
          sendMessage: ({ attachment }) => buildAndSendMessage(key, '', attachment),
        });
      } else {
        // Fallback : juste un message texte de fallback
        await buildAndSendMessage(key, `🎙 Message audio (${(buffer.byteLength/1024).toFixed(0)} Ko)`, null);
      }
    } catch (e) {
      console.warn('audio stop failed:', e);
    }
    return;
  }
  try {
    state.audioRec = new AudioRecorder();
    await state.audioRec.start();
    composer.classList.add('recording');
    const status = document.createElement('div');
    status.className = 'recording-status';
    status.innerHTML = `
      <span class="rec-dot"></span>
      <span class="timer">0:00</span>
      <button class="btn-sm" id="rec-cancel">Annuler</button>
      <button class="btn-sm btn-primary-sm" id="rec-send">Envoyer</button>
    `;
    composer.appendChild(status);
    state.audioRec.onTick = (s) => {
      const t = status.querySelector('.timer');
      if (t) { const sec = Math.floor(s); t.textContent = `${Math.floor(sec/60)}:${String(sec%60).padStart(2, '0')}`; }
    };
    status.querySelector('#rec-cancel').addEventListener('click', () => {
      state.audioRec?.cancel();
      state.audioRec = null;
      composer.classList.remove('recording');
      status.remove();
    });
    status.querySelector('#rec-send').addEventListener('click', () => toggleAudioRecording(key, contact));
  } catch (e) {
    alert('Micro indisponible : ' + e.message);
    state.audioRec = null;
  }
}

// ─── Thread panel ──────────────────────────────────────────────────

function openThread(contactKey, rootMsg) {
  state.threadRoot = { contactKey, rootId: rootMsg.id };
  // Crée le panel s'il n'existe pas
  let panel = document.getElementById('thread-panel');
  if (!panel) {
    panel = document.createElement('aside');
    panel.id = 'thread-panel';
    document.getElementById('app').appendChild(panel);
  }
  // Cache le right info panel
  document.getElementById('right-panel').classList.add('hidden');
  panel.classList.remove('hidden');
  renderThread();
}

function renderThread() {
  if (!state.threadRoot) return;
  const { contactKey, rootId } = state.threadRoot;
  const all = state.chats[contactKey] || [];
  const root = all.find(m => m.id === rootId);
  if (!root) return;
  const replies = all.filter(m => m.replyTo === rootId).sort((a, b) => a.date - b.date);
  const panel = document.getElementById('thread-panel');
  panel.innerHTML = `
    <div class="thread-header">
      <h3>${L('thread.title')}</h3>
      <button class="modal-close-x" id="thread-close">✕</button>
    </div>
    <div class="thread-body" id="thread-body"></div>
    <div class="thread-composer">
      <textarea id="thread-input" rows="2" placeholder="${L('thread.reply_placeholder')}"></textarea>
    </div>
  `;
  const body = document.getElementById('thread-body');
  // Message racine + séparateur
  body.appendChild(renderMessageRow(root, { showHeader: true, contactKey, threadCount: 0 }));
  const sep = document.createElement('div');
  sep.style.cssText = 'padding:6px 18px;color:#9A9AA0;font-size:11px;border-top:1px solid #37373C;margin-top:8px;';
  sep.textContent = replies.length ? `${replies.length} réponse${replies.length > 1 ? 's' : ''}` : 'Aucune réponse';
  body.appendChild(sep);
  for (const r of replies) {
    body.appendChild(renderMessageRow(r, { showHeader: true, contactKey, threadCount: 0 }));
  }
  document.getElementById('thread-close').addEventListener('click', () => {
    state.threadRoot = null;
    panel.classList.add('hidden');
  });
  const input = document.getElementById('thread-input');
  input.focus();
  input.addEventListener('keydown', e => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      const t = input.value.trim();
      if (!t) return;
      buildAndSendMessage(contactKey, t, null, rootId).then(() => {
        input.value = '';
        renderThread();
      });
    }
  });
}

function onIncomingMessage(p) {
  const key = p.contactKey;
  const payload = p.payload || {};
  switch (payload.k) {
    case 'msg': {
      const contact = state.contacts.find(c => c.key === key);
      const fromName = contact?.name || key.slice(0, 8);
      const m = {
        id: payload.id,
        fromMe: false,
        fromName,
        text: payload.t || '',
        date: payload.ts || Date.now(),
        attachment: payload.att || null,
        replyTo: payload.rt || null,
        reactions: {},
      };
      state.chats[key] = (state.chats[key] || []).concat(m);
      if (state.selectedRoute?.kind === 'contact' && state.selectedRoute?.key === key) {
        renderMessages(key);
      }
      // Accusé de réception
      request('peer.send', { contactKey: key, payload: { k: 'ack', ids: [m.id] } }).catch(()=>{});
      break;
    }
    case 'react': {
      const msg = findMessage(key, payload.id);
      if (!msg) return;
      msg.reactions = msg.reactions || {};
      const reactors = msg.reactions[payload.emoji] || [];
      if (payload.add) {
        if (!reactors.includes(key)) reactors.push(key);
      } else {
        const idx = reactors.indexOf(key);
        if (idx >= 0) reactors.splice(idx, 1);
      }
      msg.reactions[payload.emoji] = reactors;
      if (!reactors.length) delete msg.reactions[payload.emoji];
      if (state.selectedRoute?.key === key) renderMessages(key);
      break;
    }
    case 'del': {
      const list = state.chats[key] || [];
      const idx = list.findIndex(m => m.id === payload.id);
      if (idx >= 0) {
        list.splice(idx, 1);
        if (state.selectedRoute?.key === key) renderMessages(key);
      }
      break;
    }
    case 'ack':
      // Marquer mes messages comme livrés
      for (const id of (payload.ids || [])) {
        const m = findMessage(key, id);
        if (m) m.delivered = true;
      }
      if (state.selectedRoute?.key === key) renderMessages(key);
      break;
  }
}

function findMessage(contactKey, id) {
  return (state.chats[contactKey] || []).find(m => m.id === id);
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
function addContactFlow() {
  openPairingModal();
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
