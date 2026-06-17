// Modale d'appairage type Mac : 2 onglets « Inviter » / « Rejoindre ».
import { L } from './i18n.js';

const { request } = window.crocshare;

export function openPairingModal() {
  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  overlay.innerHTML = `
    <div class="modal-panel pairing-panel">
      <div class="pairing-header">
        <h2>${L('pairing.title')}</h2>
        <button class="modal-close-x" id="pair-close">✕</button>
      </div>
      <div class="pairing-tabs">
        <button class="pairing-tab active" data-tab="invite">${L('pairing.invite')}</button>
        <button class="pairing-tab" data-tab="join">${L('pairing.join')}</button>
      </div>
      <div class="pairing-body">
        <!-- Onglet Invite -->
        <div class="pairing-pane" data-pane="invite">
          <p class="caption">${L('pairing.invite_desc')}</p>
          <div class="invite-code" id="invite-code-zone">
            <button class="btn-primary" id="generate-invite">${L('pairing.generate')}</button>
          </div>
          <div id="invite-waiting" class="hidden">
            <div class="spinner"></div>
            <p class="caption">${L('pairing.waiting')}</p>
          </div>
        </div>

        <!-- Onglet Join -->
        <div class="pairing-pane hidden" data-pane="join">
          <p class="caption">${L('pairing.join_desc')}</p>
          <input type="text" id="join-code-input" class="text-input"
                 placeholder="cs1-…" autocomplete="off" />
          <div class="pairing-actions">
            <button class="btn-primary" id="join-submit" disabled>${L('pairing.join')}</button>
          </div>
          <div id="join-status" class="join-status hidden"></div>
        </div>
      </div>
    </div>
  `;
  document.body.appendChild(overlay);

  // Tab switching
  overlay.querySelectorAll('.pairing-tab').forEach(t => {
    t.addEventListener('click', () => {
      overlay.querySelectorAll('.pairing-tab').forEach(x => x.classList.toggle('active', x === t));
      overlay.querySelectorAll('.pairing-pane').forEach(p => p.classList.toggle('hidden', p.dataset.pane !== t.dataset.tab));
    });
  });

  overlay.querySelector('#pair-close').addEventListener('click', () => overlay.remove());
  overlay.addEventListener('click', e => { if (e.target === overlay) overlay.remove(); });

  // ── Invite tab ───────────────────────────────
  overlay.querySelector('#generate-invite').addEventListener('click', async () => {
    const zone = overlay.querySelector('#invite-code-zone');
    const wait = overlay.querySelector('#invite-waiting');
    zone.innerHTML = '<div class="spinner"></div>';
    try {
      const r = await request('pairing.createInvite', {});
      const code = r?.invite || r?.code;
      if (!code) throw new Error('Pas de code retourné');
      zone.innerHTML = `
        <div class="invite-code-display">
          <code id="invite-text">${esc(code)}</code>
          <button class="btn-sm" id="copy-invite">${L('pairing.copy')}</button>
        </div>
        <p class="caption">${L('pairing.share_hint')}</p>
      `;
      wait.classList.remove('hidden');
      overlay.querySelector('#copy-invite').addEventListener('click', () => {
        navigator.clipboard.writeText(code).then(() => {
          const btn = overlay.querySelector('#copy-invite');
          btn.textContent = '✓ ' + L('pairing.copied');
          setTimeout(() => { if (btn) btn.textContent = L('pairing.copy'); }, 1500);
        });
      });
      // Quand un peer.connected arrive pour un nouveau contact, on ferme.
      const dispose = window.crocshare.onEvent(evt => {
        if (evt.event === 'peer.connected') {
          dispose();
          overlay.querySelector('.pairing-body').innerHTML = `
            <div class="success">
              <div class="check">✓</div>
              <h3>${L('pairing.connected', evt.params.name || '?')}</h3>
              <button class="btn-primary" id="pair-done">${L('common.close')}</button>
            </div>
          `;
          overlay.querySelector('#pair-done').addEventListener('click', () => overlay.remove());
        }
      });
    } catch (e) {
      zone.innerHTML = `<p class="error">${esc(e.message)}</p>
        <button class="btn-sm" id="retry-invite">${L('common.retry')}</button>`;
      overlay.querySelector('#retry-invite').addEventListener('click', () => location.reload());
    }
  });

  // ── Join tab ─────────────────────────────────
  const input = overlay.querySelector('#join-code-input');
  const submit = overlay.querySelector('#join-submit');
  input.addEventListener('input', () => {
    submit.disabled = !input.value.trim().startsWith('cs1-');
  });
  input.focus();
  input.addEventListener('keydown', e => {
    if (e.key === 'Enter' && !submit.disabled) submit.click();
  });
  submit.addEventListener('click', async () => {
    const code = input.value.trim();
    const status = overlay.querySelector('#join-status');
    status.classList.remove('hidden');
    status.className = 'join-status';
    status.innerHTML = `<div class="spinner small"></div> <span>${L('pairing.joining')}</span>`;
    submit.disabled = true;
    try {
      await request('pairing.acceptInvite', { invite: code });
      status.innerHTML = `<span class="ok">✓ ${L('pairing.success')}</span>`;
      setTimeout(() => overlay.remove(), 1200);
    } catch (e) {
      status.innerHTML = `<span class="error">${esc(e.message)}</span>`;
      submit.disabled = false;
    }
  });
}

function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[c]));
}
