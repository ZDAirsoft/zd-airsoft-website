'use strict';
(() => {
  const API = '/.netlify/functions/arcade-admin-api';
  const $ = (id) => document.getElementById(id);
  const state = { feed: null, sha: '', dirty: false, busy: false, session: false };
  let noticeTimeout;
  const maxMessages = 20;
  function notice(text, type = '') {
    const box = $('notice');
    box.textContent = text;
    box.className = `notice${type ? ' ' + type : ''}`;
    clearTimeout(noticeTimeout);
    if (!type) noticeTimeout = setTimeout(() => box.classList.add('hidden'), 9000);
  }
  function setBusy(on) {
    state.busy = on;
    for (const id of ['publish', 'reload', 'add-message', 'login-submit']) {
      const el = $(id); if (el) el.disabled = on || (id === 'publish' && !state.dirty) || (id === 'add-message' && state.feed?.messages.length >= maxMessages);
    }
  }
  async function api(action, { method = 'GET', body } = {}) {
    const options = { method, credentials: 'same-origin', headers: { 'accept': 'application/json' }, cache: 'no-store' };
    if (body !== undefined) { options.headers['content-type'] = 'application/json'; options.body = JSON.stringify(body); }
    let response;
    try { response = await fetch(`${API}?action=${encodeURIComponent(action)}`, options); }
    catch { throw new Error('Cannot reach the website admin service. Check that Netlify Functions are deployed.'); }
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) {
      if (response.status === 401 && action !== 'login') showLogin();
      throw new Error(payload.error || `Request failed (HTTP ${response.status})`);
    }
    return payload;
  }
  function showLogin() {
    state.session = false;
    $('login-view').classList.remove('hidden');
    $('editor-view').classList.add('hidden');
    $('logout').classList.add('hidden');
    $('password').value = '';
  }
  function showEditor() {
    state.session = true;
    $('login-view').classList.add('hidden');
    $('editor-view').classList.remove('hidden');
    $('logout').classList.remove('hidden');
  }
  function setDirty(value) {
    state.dirty = value;
    $('save-status').textContent = value ? 'Unpublished changes' : 'All changes published';
    $('status-label').textContent = value ? 'Editing — not published' : 'Loaded from repository';
    $('publish').disabled = state.busy || !value;
  }
  function newId() {
    const bytes = new Uint8Array(6);
    if (window.crypto?.getRandomValues) window.crypto.getRandomValues(bytes);
    else for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256);
    return `msg_${Date.now().toString(36)}_${[...bytes].map(b => b.toString(16).padStart(2, '0')).join('')}`;
  }
  function sanitize(text) { return String(text || '').replace(/[\r\n\t]/g, ' ').trim(); }
  function localInputValue(iso) {
    if (!iso) return '';
    const d = new Date(iso);
    if (!Number.isFinite(d.getTime())) return '';
    const pad = n => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }
  function utcFromLocal(value) {
    if (!value) return '';
    const date = new Date(value);
    if (!Number.isFinite(date.getTime()) || localInputValue(date.toISOString()) !== value)
      throw new Error('That local time does not exist in your time zone (daylight saving change).');
    return date.toISOString();
  }
  function browserTimeZone() {
    try { return Intl.DateTimeFormat().resolvedOptions().timeZone || 'your device'; }
    catch { return 'your device'; }
  }
  function previewTime() {
    const selected = $('preview-at').value;
    return selected ? new Date(selected) : new Date();
  }
  function isEligible(item, when) {
    if (!item.enabled) return false;
    if (item.startsAtUtc && when.getTime() < Date.parse(item.startsAtUtc)) return false;
    if (item.expiresAtUtc && when.getTime() >= Date.parse(item.expiresAtUtc)) return false;
    return true;
  }
  function activeMessages(when = previewTime()) {
    const seen = new Set(), result = [];
    for (const item of state.feed?.messages || []) {
      const text = sanitize(item.text);
      if (!isEligible(item, when) || text.length === 0 || text.length > 140 || seen.has(text)) continue;
      seen.add(text); result.push(text);
      if (result.length >= 5) break;
    }
    return result;
  }
  function statusFor(item, active, when) {
    if (!item.enabled) return 'Disabled';
    if (item.startsAtUtc && when.getTime() < Date.parse(item.startsAtUtc)) return 'Waiting for start';
    if (item.expiresAtUtc && when.getTime() >= Date.parse(item.expiresAtUtc)) return 'Expired';
    if (active.includes(sanitize(item.text))) return 'Showing in preview';
    return 'Eligible, but outside top five';
  }
  function renderPreview() {
    if (!state.feed) return;
    const when = previewTime();
    const active = activeMessages(when);
    $('active-count').textContent = `${active.length} / 5 displayed`;
    $('preview-counter').textContent = `${active.length} active of 5 maximum · ${state.feed.displaySeconds || 12}s each · ${$('preview-at').value ? 'selected time' : 'now'}`;
    $('preview-text').textContent = active[0] || 'No active messages — launcher will use built-in fallback';
    const list = $('preview-list'); list.replaceChildren();
    active.forEach((value, i) => {
      const el = document.createElement('div'); el.className = 'preview-item';
      const num = document.createElement('strong'); num.textContent = `${i + 1}. `;
      el.append(num, document.createTextNode(value)); list.append(el);
    });
    $('message-list').querySelectorAll('[data-message-status]').forEach((el) => {
      const item = state.feed.messages.find(m => m.id === el.dataset.messageStatus);
      if (item) el.textContent = statusFor(item, active, when);
    });
  }
  function button(label, title, click, { danger = false, disabled = false } = {}) {
    const el = document.createElement('button'); el.type = 'button'; el.className = 'mini-btn' + (danger ? ' delete' : '');
    el.textContent = label; el.title = title; el.setAttribute('aria-label', title); el.disabled = disabled;
    el.addEventListener('click', click); return el;
  }
  function renderCards() {
    const list = $('message-list'); list.replaceChildren();
    state.feed.messages.forEach((item, i) => {
      const card = document.createElement('article'); card.className = 'message-card' + (item.enabled ? '' : ' is-disabled');
      const heading = document.createElement('div'); heading.className = 'heading';
      const number = document.createElement('span'); number.className = 'message-index'; number.textContent = `ANNOUNCEMENT ${i + 1}`;
      const actions = document.createElement('div'); actions.className = 'card-actions';
      actions.append(
        button('↑', 'Move announcement up', () => move(i, -1), { disabled: i === 0 }),
        button('↓', 'Move announcement down', () => move(i, 1), { disabled: i >= state.feed.messages.length - 1 }),
        button('×', 'Delete announcement', () => remove(i), { danger: true })
      );
      heading.append(number, actions);
      const input = document.createElement('textarea'); input.className = 'message-text';
      input.setAttribute('aria-label', `Announcement ${i + 1} text`); input.rows = 2; input.maxLength = 140;
      input.value = item.text;
      const footer = document.createElement('div'); footer.className = 'message-footer';
      const label = document.createElement('label'); label.className = 'toggle';
      const check = document.createElement('input'); check.type = 'checkbox'; check.checked = item.enabled;
      const checkText = document.createElement('span'); checkText.textContent = 'Enabled'; label.append(check, checkText);
      const count = document.createElement('span'); count.className = 'char-counter';
      count.textContent = `${item.text.length}/140 characters`;
      input.addEventListener('input', () => { item.text = input.value; count.textContent = `${item.text.length}/140 characters`; setDirty(true); renderPreview(); });
      check.addEventListener('change', () => { item.enabled = check.checked; card.classList.toggle('is-disabled', !item.enabled); setDirty(true); renderPreview(); });
      const schedule = document.createElement('div'); schedule.className = 'schedule-row';
      function scheduleInput(field, title) {
        const wrap = document.createElement('div'); wrap.className = 'schedule-field';
        const fieldLabel = document.createElement('label'); fieldLabel.textContent = title;
        const dateInput = document.createElement('input'); dateInput.type = 'datetime-local';
        dateInput.step = '60'; dateInput.value = localInputValue(item[field]);
        dateInput.setAttribute('aria-label', `${title} for announcement ${i + 1}`);
        dateInput.addEventListener('change', () => {
          try {
            const date = utcFromLocal(dateInput.value);
            item[field] = date;
            setDirty(true); renderPreview();
            notice(date ? `${title} saved in ${browserTimeZone()} time. Publish to activate.` : `${title} removed. Publish to activate.`);
          } catch (e) { dateInput.value = localInputValue(item[field]); notice(e.message, 'error'); }
        });
        wrap.append(fieldLabel, dateInput); return wrap;
      }
      schedule.append(scheduleInput('startsAtUtc', 'Starts (optional)'), scheduleInput('expiresAtUtc', 'Ends (optional)'));
      const status = document.createElement('div'); status.className = 'schedule-status';
      status.dataset.messageStatus = item.id;
      footer.append(label, count);
      card.append(heading, input, schedule, status, footer); list.append(card);
    });
    $('add-message').disabled = state.busy || state.feed.messages.length >= maxMessages;
    renderPreview();
  }
  function move(i, offset) {
    const j = i + offset; if (j < 0 || j >= state.feed.messages.length) return;
    [state.feed.messages[i], state.feed.messages[j]] = [state.feed.messages[j], state.feed.messages[i]];
    setDirty(true); renderCards();
  }
  function remove(i) {
    if (!confirm('Delete this announcement from the next published feed?')) return;
    state.feed.messages.splice(i, 1); setDirty(true); renderCards();
  }
  function loadPayload(value) {
    if (!value?.feed || !Array.isArray(value.feed.messages) || typeof value.sha !== 'string')
      throw new Error('The repository returned an invalid announcement file.');
    state.feed = { schemaVersion: 1, displaySeconds: value.feed.displaySeconds || 12,
      messages: value.feed.messages.map((item) => ({
        id: String(item.id), text: String(item.text), enabled: Boolean(item.enabled),
        startsAtUtc: typeof item.startsAtUtc === 'string' ? item.startsAtUtc : '',
        expiresAtUtc: typeof item.expiresAtUtc === 'string' ? item.expiresAtUtc : ''
      })) };
    state.sha = value.sha;
    $('duration').value = String(state.feed.displaySeconds);
    setDirty(false); renderCards();
  }
  async function reload(ask = true) {
    if (ask && state.dirty && !confirm('Discard your unpublished edits and reload from GitHub?')) return;
    setBusy(true);
    try { loadPayload(await api('load')); notice('Loaded the latest announcements from your website repository.'); }
    catch (e) { notice(e.message, 'error'); }
    finally { setBusy(false); }
  }
  $('login-form').addEventListener('submit', async (ev) => {
    ev.preventDefault(); setBusy(true);
    try {
      await api('login', { method: 'POST', body: { password: $('password').value } });
      showEditor(); await reload(false);
    } catch (e) { notice(e.message, 'error'); }
    finally { setBusy(false); }
  });
  $('logout').addEventListener('click', async () => {
    if (state.dirty && !confirm('Sign out and discard unpublished edits?')) return;
    try { await api('logout', { method: 'POST' }); } catch (e) { notice(e.message, 'error'); }
    showLogin();
  });
  $('reload').addEventListener('click', () => reload(true));
  $('duration').addEventListener('change', () => {
    if (!state.feed) return;
    const value = Number($('duration').value);
    if (!Number.isInteger(value) || value < 5 || value > 30) {
      notice('Seconds per announcement must be an integer from 5 to 30.', 'error'); $('duration').value = String(state.feed.displaySeconds); return;
    }
    state.feed.displaySeconds = value; setDirty(true); renderPreview();
  });
  $('add-message').addEventListener('click', () => {
    if (state.feed.messages.length >= maxMessages) return notice('Maximum 20 stored messages.', 'warning');
    state.feed.messages.unshift({ id: newId(), text: '', enabled: true, startsAtUtc: '', expiresAtUtc: '' });
    setDirty(true); renderCards(); $('message-list').querySelector('textarea')?.focus();
  });
  $('publish').addEventListener('click', async () => {
    if (!state.dirty || state.busy || !state.feed) return;
    if (state.feed.messages.some(m => !sanitize(m.text) || sanitize(m.text).length > 140)) return notice('Every announcement needs 1–140 characters. Remove or fill empty announcements.', 'error');
    for (let i = 0; i < state.feed.messages.length; i++) {
      const m = state.feed.messages[i];
      if (m.startsAtUtc && m.expiresAtUtc && Date.parse(m.expiresAtUtc) <= Date.parse(m.startsAtUtc))
        return notice(`Announcement ${i + 1}: End must be later than Start.`, 'error');
    }
    const active = activeMessages(new Date());
    if (!active.length && !confirm('No website messages are active right now. The launcher will use built-in messages until a schedule starts. Continue?')) return;
    setBusy(true);
    try {
      const response = await api('publish', { method: 'POST', body: { expectedSha: state.sha, feed: state.feed } });
      state.sha = response.sha || state.sha;
      setDirty(false);
      notice('Saved to GitHub. Netlify must deploy this change before it appears on the public website; online SMT24 monitors check approximately every five minutes.');
    } catch (e) { notice(e.message, 'error'); }
    finally { setBusy(false); }
  });
  $('timezone-note').textContent = `Dates use this device's time zone (${browserTimeZone()}). Leave either field blank for no limit. The SMT24 must have the correct clock.`;
  $('preview-at').addEventListener('change', renderPreview);
  $('preview-now').addEventListener('click', () => { $('preview-at').value = ''; renderPreview(); });
  // A long-open editor should show schedule changes without a page refresh.
  window.setInterval(() => { if (state.session && state.feed && !$('preview-at').value) renderPreview(); }, 30000);
  window.addEventListener('beforeunload', (event) => { if (state.dirty) { event.preventDefault(); event.returnValue = ''; } });
  (async function start() {
    try {
      const session = await api('status');
      if (session.authenticated) { showEditor(); await reload(false); }
      else showLogin();
    } catch (e) { showLogin(); notice(e.message, 'error'); }
  })();
})();
