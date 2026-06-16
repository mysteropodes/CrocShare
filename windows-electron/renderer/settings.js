// Vue Réglages — équivalent SettingsContent côté Mac.
// Toutes les sections : profil, dossiers, langue, rétention, relai kDrive,
// debug, identité P2P.

import { L } from './i18n.js';

const { config, pat, dialog, relaunch, kdrive, openExternal, version } = window.crocshare;

const RETENTION_OPTIONS = [
  { value: 0,   labelKey: 'retention.never' },
  { value: 90,  labelKey: 'retention.3m' },
  { value: 180, labelKey: 'retention.6m' },
  { value: 365, labelKey: 'retention.12m' },
];

const LANGUAGE_OPTIONS = [
  { value: '',   labelKey: 'lang.system' },
  { value: 'fr', labelKey: 'lang.fr' },
  { value: 'en', labelKey: 'lang.en' },
];

export async function renderSettings(container, ctx) {
  const cfg = await config.get();
  const currentPAT = await pat.get();
  const appVersion = await version();

  container.innerHTML = `
    <div class="settings-scroll">
      <div class="settings-wrap">
        <h1 class="settings-title">${L('settings.title')}</h1>

        <!-- ── Profil ─────────────────────────────── -->
        <section class="settings-section">
          <div class="profile-row">
            <button class="big-profile-avatar" id="set-pick-avatar" title="${L('settings.change_photo')}">
              ${avatarInner(cfg.myName, cfg.avatarPath)}
              <span class="camera-mini">📷</span>
            </button>
            <div class="profile-fields">
              <div class="field-label">${L('settings.my_profile')}</div>
              <input type="text" id="set-name" class="text-input" value="${esc(cfg.myName || '')}" placeholder="${L('settings.my_name')}" />
              ${cfg.avatarPath ? `<button class="link-danger" id="set-remove-avatar">${L('settings.remove_photo')}</button>` : ''}
            </div>
          </div>
        </section>

        <!-- ── Dossier partagé ──────────────────── -->
        <section class="settings-section">
          <div class="row-labeled">
            <div class="row-label">${L('settings.shared_folder')}</div>
            <div class="row-value">
              <span class="path-text" title="${esc(cfg.sharedFolder || '')}">${esc(truncatePath(cfg.sharedFolder, 36) || L('settings.none'))}</span>
              <button class="btn-sm" data-pick="sharedFolder">${L('settings.choose')}</button>
            </div>
          </div>
        </section>

        <section class="settings-section">
          <div class="row-labeled">
            <div class="row-label">${L('settings.download_folder')}</div>
            <div class="row-value">
              <span class="path-text" title="${esc(cfg.downloadFolder || '')}">${esc(truncatePath(cfg.downloadFolder, 36) || '~/CrocShare')}</span>
              <button class="btn-sm" data-pick="downloadFolder">${L('settings.choose')}</button>
            </div>
          </div>
        </section>

        <div class="settings-divider"></div>

        <!-- ── Langue ───────────────────────────── -->
        <section class="settings-section">
          <div class="row-labeled">
            <div class="row-label">${L('settings.language')}</div>
            <div class="row-value">
              <select id="set-language" class="select-input">
                ${LANGUAGE_OPTIONS.map(o => `
                  <option value="${o.value}" ${(cfg.language || '') === o.value ? 'selected' : ''}>${L(o.labelKey)}</option>
                `).join('')}
              </select>
              <button class="btn-sm btn-primary-sm" id="set-relaunch">${L('settings.relaunch_now')}</button>
            </div>
          </div>
          <p class="caption">${L('settings.language_restart_required')}</p>
        </section>

        <!-- ── Rétention chat ───────────────────── -->
        <section class="settings-section">
          <div class="row-labeled">
            <div class="row-label">${L('settings.chat_retention')}</div>
            <div class="row-value">
              <select id="set-retention" class="select-input">
                ${RETENTION_OPTIONS.map(o => `
                  <option value="${o.value}" ${(cfg.chatRetentionDays || 0) === o.value ? 'selected' : ''}>${L(o.labelKey)}</option>
                `).join('')}
              </select>
            </div>
          </div>
          <p class="caption">${L('settings.chat_retention_help')}</p>
        </section>

        <div class="settings-divider"></div>

        <!-- ── Relai kDrive ─────────────────────── -->
        <section class="settings-section">
          <div class="kdrive-header">
            <h2 class="section-h2">${L('settings.kdrive_relay')}</h2>
            <label class="toggle">
              <input type="checkbox" id="set-kdrive-enabled" ${cfg.kdriveRelay?.enabled ? 'checked' : ''} />
              <span class="slider"></span>
            </label>
          </div>
          <p class="caption">${L('settings.kdrive_relay_desc')}</p>
          <div id="kdrive-fields" class="${cfg.kdriveRelay?.enabled ? '' : 'hidden'}">
            <div class="row-labeled compact">
              <div class="row-label">Drive ID</div>
              <div class="row-value">
                <input type="text" id="set-kdrive-driveid" class="text-input" placeholder="ex. 123456" value="${esc(cfg.kdriveRelay?.driveID || '')}" />
              </div>
            </div>
            <div class="row-labeled compact">
              <div class="row-label">Folder ID</div>
              <div class="row-value">
                <input type="text" id="set-kdrive-folderid" class="text-input" placeholder="ex. 789012" value="${esc(cfg.kdriveRelay?.folderID || '')}" />
              </div>
            </div>
            <div class="row-labeled compact">
              <div class="row-label">Personal Access Token</div>
              <div class="row-value">
                <input type="password" id="set-kdrive-pat" class="text-input" placeholder="${L('settings.kdrive_pat_placeholder')}" value="${esc(currentPAT || '')}" />
                ${currentPAT ? `<button class="btn-sm link-danger" id="set-kdrive-clear">${L('common.clear')}</button>` : ''}
              </div>
            </div>
            <div class="kdrive-actions">
              <button class="btn-sm" id="set-kdrive-test">${L('settings.kdrive_test')}</button>
              <span id="kdrive-test-result" class="test-result"></span>
              <button class="btn-sm" id="set-kdrive-help">${L('common.help')}…</button>
            </div>
          </div>
        </section>

        <div class="settings-divider"></div>

        <!-- ── Debug ────────────────────────────── -->
        <section class="settings-section">
          <div class="row-labeled">
            <div class="row-label">${L('settings.debug')}</div>
            <div class="row-value">
              <button class="btn-sm" id="set-sync-log">${L('settings.sync_log')}</button>
              <button class="btn-sm" id="set-add-bot">${L('settings.add_bot')}</button>
            </div>
          </div>
        </section>

        <div class="settings-divider"></div>

        <!-- ── Moteur P2P ───────────────────────── -->
        <section class="settings-section">
          <div class="row-labeled">
            <div class="row-label">${L('settings.p2p_engine')}</div>
            <div class="row-value">
              <span class="status-pill status-ok"><span class="dot"></span>${L('settings.p2p_connected')}</span>
            </div>
          </div>
          <p class="caption mono small" id="my-identity">${L('settings.starting')}</p>
          <p class="caption">${L('settings.p2p_description')}</p>
        </section>

        <!-- ── À propos ─────────────────────────── -->
        <section class="settings-section">
          <div class="row-labeled">
            <div class="row-label">Version</div>
            <div class="row-value"><span class="mono">${esc(appVersion)} (Windows / Electron)</span></div>
          </div>
        </section>
      </div>
    </div>
  `;

  wireSettingsEvents(ctx);
}

function wireSettingsEvents(ctx) {
  const $ = (id) => document.getElementById(id);

  // Nom
  $('set-name').addEventListener('blur', async () => {
    await config.set({ myName: $('set-name').value });
    if (ctx?.refreshHeader) ctx.refreshHeader();
  });

  // Avatar (placeholder simple : on stocke juste un path pické)
  $('set-pick-avatar').addEventListener('click', async () => {
    const file = await dialog.pickFile({ filters: [{ name: 'Image', extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'] }] });
    if (file) {
      await config.set({ avatarPath: file });
      const c = await config.get();
      // Refresh local de la zone avatar uniquement
      $('set-pick-avatar').innerHTML = avatarInner(c.myName, c.avatarPath) + '<span class="camera-mini">📷</span>';
      if (ctx?.refreshHeader) ctx.refreshHeader();
    }
  });
  if ($('set-remove-avatar')) $('set-remove-avatar').addEventListener('click', async () => {
    await config.set({ avatarPath: null });
    ctx?.refreshView?.();
  });

  // Dossiers
  document.querySelectorAll('button[data-pick]').forEach(b => {
    b.addEventListener('click', async () => {
      const folder = await dialog.pickFolder();
      if (folder) {
        await config.set({ [b.dataset.pick]: folder });
        ctx?.refreshView?.();
      }
    });
  });

  // Langue
  $('set-language').addEventListener('change', async () => {
    await config.set({ language: $('set-language').value });
  });
  $('set-relaunch').addEventListener('click', () => relaunch());

  // Rétention
  $('set-retention').addEventListener('change', async () => {
    await config.set({ chatRetentionDays: parseInt($('set-retention').value, 10) });
  });

  // Relai kDrive
  $('set-kdrive-enabled').addEventListener('change', async () => {
    const enabled = $('set-kdrive-enabled').checked;
    const cur = (await config.get()).kdriveRelay || {};
    await config.set({ kdriveRelay: { ...cur, enabled } });
    document.getElementById('kdrive-fields').classList.toggle('hidden', !enabled);
  });
  ['driveID', 'folderID'].forEach(field => {
    const id = field === 'driveID' ? 'set-kdrive-driveid' : 'set-kdrive-folderid';
    $(id).addEventListener('blur', async () => {
      const cur = (await config.get()).kdriveRelay || {};
      await config.set({ kdriveRelay: { ...cur, [field]: $(id).value.trim() } });
    });
  });
  $('set-kdrive-pat').addEventListener('blur', async () => {
    await pat.set($('set-kdrive-pat').value);
  });
  if ($('set-kdrive-clear')) $('set-kdrive-clear').addEventListener('click', async () => {
    await pat.clear();
    $('set-kdrive-pat').value = '';
    ctx?.refreshView?.();
  });
  $('set-kdrive-test').addEventListener('click', async () => {
    const out = $('kdrive-test-result');
    out.textContent = '… ' + L('settings.kdrive_testing');
    out.className = 'test-result';
    try {
      await pat.set($('set-kdrive-pat').value);
      await kdrive.test({ driveID: $('set-kdrive-driveid').value.trim() });
      out.textContent = '✓ OK';
      out.className = 'test-result ok';
    } catch (e) {
      out.textContent = '✗ ' + (e.message || 'erreur');
      out.className = 'test-result fail';
    }
  });
  $('set-kdrive-help').addEventListener('click', () => showKDriveHelp());

  // Debug
  $('set-sync-log').addEventListener('click', () => {
    alert(L('settings.debug_log_unavailable'));
  });
  $('set-add-bot').addEventListener('click', () => {
    alert(L('settings.bot_already_present'));
  });

  // Identité (récupération depuis le state global)
  if (window.crocshareState?.myPublicKey) {
    $('my-identity').textContent = 'Identité : ' + window.crocshareState.myPublicKey.slice(0, 24) + '…';
  }
}

// ─── Helpers ────────────────────────────────────────────────────────

function avatarInner(name, photoPath) {
  if (photoPath) return `<img src="file://${photoPath}" alt="" />`;
  const initial = (name || 'M').slice(0, 1).toUpperCase();
  return `<span>${esc(initial)}</span>`;
}

function truncatePath(p, max) {
  if (!p) return '';
  if (p.length <= max) return p;
  const half = Math.floor((max - 1) / 2);
  return p.slice(0, half) + '…' + p.slice(-half);
}

function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[c]));
}

function showKDriveHelp() {
  const body = `
    <h3>${L('settings.kdrive_help_title')}</h3>
    <ol>
      <li>${L('settings.kdrive_help_1')}</li>
      <li>${L('settings.kdrive_help_2')}<br/>
        <code>drive:file:read</code> · <code>drive:file:write</code><br/>
        <small>${L('settings.kdrive_help_scope_note')}</small>
      </li>
      <li>${L('settings.kdrive_help_3')}</li>
      <li>${L('settings.kdrive_help_4')}</li>
      <li>${L('settings.kdrive_help_5')}</li>
      <li>${L('settings.kdrive_help_6')}</li>
    </ol>
    <p class="caption">${L('settings.kdrive_help_security')}</p>
  `;
  showModal(body);
}

function showModal(html) {
  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  overlay.innerHTML = `
    <div class="modal-panel">
      <div class="modal-content">${html}</div>
      <div class="modal-actions">
        <button class="btn-primary" id="modal-close">${L('common.close')}</button>
      </div>
    </div>
  `;
  document.body.appendChild(overlay);
  overlay.querySelector('#modal-close').addEventListener('click', () => overlay.remove());
  overlay.addEventListener('click', e => { if (e.target === overlay) overlay.remove(); });
}
