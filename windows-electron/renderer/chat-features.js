// Fonctionnalités chat avancées Windows :
//  - Réactions emoji (hover bar + picker, payload k:'react' compatible Mac)
//  - Pièces jointes (file picker + drag-drop) via peer.sendFile + payload msg.att
//  - Messages audio via MediaRecorder API
//  - Threading (panel droit avec replyTo)
//
// Tous les payloads matchent exactement ce qu'envoie/reçoit P2PEngine côté Mac.

import { L } from './i18n.js';

const { request, dialog, openExternal } = window.crocshare;

export const QUICK_EMOJIS = ['👍', '❤️', '😂', '🎉', '👀', '✅', '🙏', '🔥'];

export const EMOJI_PALETTE = [
  ['Smileys', ['😀','😁','😂','🤣','😊','😍','😎','🤩','🥰','😘','😜','😇','🤔','🙄','😴','🤤','😭','😱','😡','🤯']],
  ['Gestes', ['👍','👎','👌','🤝','🙌','👏','🙏','🤞','✌️','🤘','👋','🤙','💪','👀','🫶','🤌']],
  ['Cœurs', ['❤️','🧡','💛','💚','💙','💜','🖤','🤍','💖','💕','💔','💯']],
  ['Objets', ['🎉','🔥','✨','⚡️','💡','💎','🎁','🎯','🚀','✅','❌','⚠️','🆗','🆕']],
  ['Nature', ['🐶','🐱','🦊','🦁','🐼','🐧','🐢','🐳','🌸','🌻','🌈','☀️','🌙','⭐️']],
];

// ─── Réactions ─────────────────────────────────────────────────────

/// Crée la barre hover (quick emojis + bouton + + bouton thread + trash)
export function buildHoverBar({ messageId, contactKey, fromMe, onReact, onReply, onDelete, onOpenPicker }) {
  const bar = document.createElement('div');
  bar.className = 'msg-hover-bar';
  for (const e of QUICK_EMOJIS) {
    const b = document.createElement('button');
    b.textContent = e;
    b.title = `Réagir avec ${e}`;
    b.addEventListener('click', (ev) => { ev.stopPropagation(); onReact(e); });
    bar.appendChild(b);
  }
  const sep1 = document.createElement('span'); sep1.style.cssText = 'width:1px;background:#37373C;margin:2px 2px;';
  bar.appendChild(sep1);
  const more = document.createElement('button');
  more.textContent = '😊+';
  more.title = L('reactions.add');
  more.addEventListener('click', (ev) => { ev.stopPropagation(); onOpenPicker(more); });
  bar.appendChild(more);
  const reply = document.createElement('button');
  reply.textContent = '💬';
  reply.title = 'Répondre dans un fil';
  reply.addEventListener('click', (ev) => { ev.stopPropagation(); onReply(); });
  bar.appendChild(reply);
  if (fromMe) {
    const trash = document.createElement('button');
    trash.textContent = '🗑';
    trash.title = 'Supprimer';
    trash.addEventListener('click', (ev) => { ev.stopPropagation(); onDelete(); });
    bar.appendChild(trash);
  }
  return bar;
}

export function showEmojiPicker(anchor, onPick) {
  // Supprime un picker existant
  document.querySelectorAll('.emoji-picker-popup').forEach(p => p.remove());
  const rect = anchor.getBoundingClientRect();
  const pop = document.createElement('div');
  pop.className = 'emoji-picker-popup';
  pop.style.top = (rect.bottom + 4) + 'px';
  pop.style.left = Math.max(8, rect.right - 320) + 'px';
  pop.innerHTML = EMOJI_PALETTE.map(([cat, list]) => `
    <h4>${cat}</h4>
    <div class="emoji-grid">
      ${list.map(e => `<button data-emoji="${e}">${e}</button>`).join('')}
    </div>
  `).join('');
  document.body.appendChild(pop);
  pop.querySelectorAll('button[data-emoji]').forEach(b => {
    b.addEventListener('click', () => { onPick(b.dataset.emoji); pop.remove(); });
  });
  // Click outside → ferme
  setTimeout(() => {
    document.addEventListener('click', function onDoc(e) {
      if (!pop.contains(e.target)) { pop.remove(); document.removeEventListener('click', onDoc); }
    });
  }, 0);
}

/// Toggle d'une réaction (local + envoi P2P). `reactions` est { emoji: [keys] }.
export function toggleReaction(reactions, emoji, myKey, contactKey) {
  reactions[emoji] = reactions[emoji] || [];
  const idx = reactions[emoji].indexOf(myKey);
  let add;
  if (idx >= 0) {
    reactions[emoji].splice(idx, 1);
    if (!reactions[emoji].length) delete reactions[emoji];
    add = false;
  } else {
    reactions[emoji].push(myKey);
    add = true;
  }
  return add;
}

export function sendReaction(contactKey, messageId, emoji, add) {
  return request('peer.send', {
    contactKey,
    payload: { k: 'react', id: messageId, emoji, add }
  }).catch(() => {});
}

// ─── Suppression de message ────────────────────────────────────────

export function sendDelete(contactKey, messageId) {
  return request('peer.send', {
    contactKey,
    payload: { k: 'del', id: messageId }
  }).catch(() => {});
}

// ─── Attachments ───────────────────────────────────────────────────

export async function pickAndSendAttachment({ contactKey, scope, sendMessage }) {
  const file = await dialog.pickFile({});
  if (!file) return;
  return sendAttachmentFromPath(file, { contactKey, scope, sendMessage });
}

export async function sendAttachmentFromPath(filePath, { contactKey, scope, sendMessage }) {
  const fileName = filePath.split(/[\\/]/).pop();
  // peer.sendFile dans le core attend reqId + relPath + absPath
  const reqId = crypto.randomUUID();
  const relPath = `Chat/${(scope || 'misc').replace(/[\/\\]/g, '-')}/${fileName}`;

  // Récupération de la taille via le main process (pas dispo en renderer Electron sandbox).
  let size = 0;
  try {
    const stat = await window.crocshare.fileStat?.(filePath);
    size = stat?.size || 0;
  } catch {}

  // Envoie d'abord le message metadata
  await sendMessage({
    attachment: { fileName, relPath, size }
  });

  // Puis transfert binaire via le core
  try {
    await request('peer.sendFile', { contactKey, reqId, relPath, absPath: filePath });
  } catch (e) {
    console.warn('peer.sendFile failed:', e);
  }
}

// ─── Audio messages (MediaRecorder) ────────────────────────────────

export class AudioRecorder {
  constructor() {
    this.stream = null;
    this.rec = null;
    this.chunks = [];
    this.startedAt = 0;
    this.onTick = () => {};
    this.tickInterval = null;
  }

  async start() {
    this.stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    // Préfère mp4/aac si dispo, sinon webm/opus (universel sur Chromium).
    const mimes = ['audio/mp4', 'audio/webm;codecs=opus', 'audio/webm'];
    const mime = mimes.find(m => MediaRecorder.isTypeSupported(m)) || '';
    this.rec = new MediaRecorder(this.stream, mime ? { mimeType: mime } : undefined);
    this.chunks = [];
    this.rec.ondataavailable = (e) => { if (e.data.size > 0) this.chunks.push(e.data); };
    this.rec.start();
    this.startedAt = Date.now();
    this.tickInterval = setInterval(() => this.onTick(this.elapsed()), 250);
  }

  elapsed() { return (Date.now() - this.startedAt) / 1000; }

  async stop() {
    return new Promise(resolve => {
      this.rec.onstop = async () => {
        clearInterval(this.tickInterval);
        const ext = this.rec.mimeType.includes('mp4') ? 'm4a' : 'webm';
        const blob = new Blob(this.chunks, { type: this.rec.mimeType });
        const buf = await blob.arrayBuffer();
        this.stream.getTracks().forEach(t => t.stop());
        resolve({ buffer: buf, ext });
      };
      this.rec.stop();
    });
  }

  cancel() {
    try { this.rec?.stop(); } catch {}
    clearInterval(this.tickInterval);
    this.stream?.getTracks().forEach(t => t.stop());
    this.chunks = [];
  }
}

// ─── Rendu attachment dans le chat ─────────────────────────────────

export function renderAttachment(att, downloadedURL) {
  const wrap = document.createElement('div');
  const ext = (att.fileName.split('.').pop() || '').toLowerCase();
  const isImage = ['png','jpg','jpeg','gif','webp','heic','bmp'].includes(ext);
  const isVideo = ['mp4','mov','m4v','mkv','webm'].includes(ext);
  const isAudio = ['m4a','mp3','wav','aac','webm','opus'].includes(ext);

  if (isImage && downloadedURL) {
    wrap.className = 'msg-attachment image';
    const img = document.createElement('img');
    img.src = downloadedURL;
    img.alt = att.fileName;
    img.addEventListener('click', () => openLightbox(downloadedURL, 'image'));
    wrap.appendChild(img);
  } else if (isVideo && downloadedURL) {
    wrap.className = 'msg-attachment video';
    const v = document.createElement('video');
    v.src = downloadedURL;
    v.controls = true;
    wrap.appendChild(v);
  } else if (isAudio && downloadedURL) {
    wrap.className = 'msg-attachment audio';
    const a = document.createElement('audio');
    a.src = downloadedURL;
    a.controls = true;
    wrap.appendChild(a);
  } else {
    wrap.className = 'msg-attachment file';
    wrap.innerHTML = `
      <div class="file-icon">${fileIcon(ext)}</div>
      <div class="file-info">
        <div class="file-name">${escapeHTML(att.fileName)}</div>
        <div class="file-size">${formatBytes(att.size)}</div>
      </div>
    `;
    if (downloadedURL) {
      wrap.addEventListener('click', () => openExternal('file://' + downloadedURL));
    }
  }
  return wrap;
}

function fileIcon(ext) {
  switch (ext) {
    case 'pdf': return '📄';
    case 'zip': case 'rar': case '7z': return '📦';
    case 'doc': case 'docx': case 'rtf': case 'odt': return '📝';
    case 'xls': case 'xlsx': case 'ods': return '📊';
    case 'mp3': case 'wav': case 'm4a': return '🎵';
    case 'mp4': case 'mov': case 'mkv': return '🎬';
    default: return '📎';
  }
}

function formatBytes(n) {
  if (!n) return '';
  const units = ['B', 'Ko', 'Mo', 'Go'];
  let i = 0; let x = n;
  while (x >= 1024 && i < units.length - 1) { x /= 1024; i++; }
  return `${x.toFixed(x >= 10 ? 0 : 1)} ${units[i]}`;
}

// ─── Lightbox ──────────────────────────────────────────────────────

export function openLightbox(src, type = 'image') {
  const overlay = document.createElement('div');
  overlay.className = 'lightbox-overlay';
  const media = type === 'video'
    ? `<video src="${src}" controls autoplay></video>`
    : `<img src="${src}" alt="" />`;
  overlay.innerHTML = `${media}<button class="close-x">✕</button>`;
  overlay.addEventListener('click', e => { if (e.target === overlay) overlay.remove(); });
  overlay.querySelector('.close-x').addEventListener('click', () => overlay.remove());
  document.body.appendChild(overlay);
}

// ─── Helpers ───────────────────────────────────────────────────────

function escapeHTML(s) {
  return String(s).replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[c]));
}
