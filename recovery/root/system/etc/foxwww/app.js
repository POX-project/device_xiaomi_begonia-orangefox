(() => {
  'use strict';

  const $ = (sel) => document.querySelector(sel);
  const token = {
    key: 'foxweb.token',
    get() { return localStorage.getItem(this.key) || ''; },
    set(value) { localStorage.setItem(this.key, value); },
  };

  const state = {
    wifi: { state: 'off', up: false },
    selected: null,
    adb: { enabled: false, running: false, ip: null, port: 5555, command: null },
    adbBusy: false,
    files: { path: '/sdcard', entries: [], requestId: 0, busy: false },
  };

  // A one-click URL can carry the token in the fragment, e.g.
  //   http://192.168.1.5:8080/#token=...
  // The fragment never reaches the server, and we remove it from the address
  // bar after storing it locally.
  try {
    const params = new URLSearchParams(location.hash.replace(/^#/, ''));
    const hashToken = params.get('token');
    if (hashToken) {
      token.set(hashToken);
      history.replaceState(null, '', location.pathname + location.search);
    }
  } catch (_) { /* ignore malformed fragments */ }

  function toast(message, kind = '') {
    const el = $('#toast');
    el.textContent = message;
    el.className = `toast ${kind}`.trim();
    clearTimeout(toast._timer);
    toast._timer = setTimeout(() => el.classList.add('hidden'), 4200);
  }

  function busy(button, isBusy, label) {
    if (!button) return;
    if (isBusy) {
      button.dataset.label = button.textContent;
      button.disabled = true;
      button.innerHTML = '<span class="spinner"></span>' + (label || 'Working');
    } else {
      button.disabled = false;
      button.textContent = button.dataset.label || button.textContent;
    }
  }

  async function api(path, options = {}) {
    const headers = new Headers(options.headers || {});
    if (token.get()) headers.set('X-Fox-Token', token.get());
    const response = await fetch(path, { cache: 'no-store', ...options, headers });
    let data = null;
    try { data = await response.json(); } catch (_) { /* empty body */ }

    if (response.status === 401) {
      showTokenDialog();
      throw new Error('Access token required');
    }
    if (!response.ok || (data && data.ok === false)) {
      throw new Error((data && (data.error || data.message)) || `HTTP ${response.status}`);
    }
    return data;
  }

  async function raw(path) {
    const headers = new Headers();
    if (token.get()) headers.set('X-Fox-Token', token.get());
    const response = await fetch(path, { cache: 'no-store', headers });
    if (response.status === 401) {
      showTokenDialog();
      throw new Error('Access token required');
    }
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return response.text();
  }

  function formatBytes(bytes) {
    const n = Number(bytes);
    if (!Number.isFinite(n) || n < 0) return '—';
    if (n < 1024) return `${n} B`;
    const units = ['KiB', 'MiB', 'GiB', 'TiB'];
    let value = n;
    let unit = -1;
    do {
      value /= 1024;
      unit += 1;
    } while (value >= 1024 && unit < units.length - 1);
    return `${value.toFixed(value >= 10 ? 1 : 2)} ${units[unit]}`;
  }

  function formatTime(seconds) {
    const n = Number(seconds);
    if (!Number.isFinite(n) || n <= 0) return '—';
    try {
      return new Date(n * 1000).toLocaleString();
    } catch (_) {
      return '—';
    }
  }

  function encodePath(path) {
    return encodeURIComponent(path);
  }

  function requireToken() {
    if (token.get()) return true;
    showTokenDialog();
    toast('Enter the access token, then try again.', 'bad');
    return false;
  }

  async function copyText(text) {
    try {
      if (navigator.clipboard && window.isSecureContext) {
        await navigator.clipboard.writeText(text);
        return true;
      }
    } catch (_) { /* fall through to the old copy path */ }

    try {
      const area = document.createElement('textarea');
      area.value = text;
      area.setAttribute('readonly', '');
      area.style.position = 'fixed';
      area.style.left = '-9999px';
      document.body.appendChild(area);
      area.select();
      const ok = document.execCommand('copy');
      area.remove();
      return ok;
    } catch (_) {
      return false;
    }
  }

  function makeQr(element, text, label) {
    if (!element) return;
    if (!text) {
      element.textContent = '';
      const note = document.createElement('p');
      note.className = 'muted small';
      note.textContent = label || 'Not available';
      element.appendChild(note);
      return;
    }
    if (typeof qrcode !== 'function') {
      element.textContent = 'QR library unavailable';
      return;
    }
    try {
      const qr = qrcode(0, 'M');
      qr.addData(text);
      qr.make();
      element.innerHTML = qr.createSvgTag({
        cellSize: 4,
        margin: 4,
        scalable: true,
        alt: label || 'QR code',
        title: label || 'QR code',
      });
    } catch (_) {
      element.textContent = 'Could not render the QR code';
    }
  }

  function foxwebUrl() {
    const ip = state.wifi && state.wifi.ip;
    if (!ip) return '';
    const port = location.port || '8080';
    const base = `http://${ip}:${port}/`;
    return token.get()
      ? `${base}#token=${encodeURIComponent(token.get())}`
      : base;
  }

  function renderWebQr() {
    const url = foxwebUrl();
    const link = $('#webQrLink');
    const qr = $('#webQr');
    const hint = $('#webQrHint');

    if (!url) {
      link.textContent = 'Connect WiFi first';
      link.removeAttribute('href');
      makeQr(qr, '', 'Connect WiFi to generate a one-click QR code.');
      hint.textContent = 'Connect a network in the card above.';
      return;
    }

    link.textContent = url;
    link.href = url;
    makeQr(qr, url, 'FoxWeb dashboard URL');
    hint.textContent = token.get()
      ? 'Scan with a phone on the same network; the token is included in the fragment.'
      : 'Scan, then enter the token shown by foxweb token.';
  }

  function renderAdb(data) {
    const adb = data || {};
    const port = Number(adb.port) || 5555;
    const ip = adb.ip || (state.wifi && state.wifi.ip) || null;
    state.adb = { ...state.adb, ...adb, ip, port };

    const enabled = !!state.adb.enabled;
    const running = !!state.adb.running;
    const pill = $('#adbPill');
    const stateText = $('#adbState');

    if (enabled) {
      pill.className = `pill ${running ? 'on' : 'warn'}`;
      stateText.textContent = running ? 'Enabled' : 'adbd stopped';
    } else {
      pill.className = 'pill off';
      stateText.textContent = 'Off';
    }

    $('#adbAddress').textContent = ip ? `${ip}:${port}` : 'No WiFi IP';
    $('#adbPort').textContent = String(port);
    const command = ip ? `adb connect ${ip}:${port}` : 'Connect WiFi first';
    $('#adbCommand').textContent = command;
    $('#adbCommand').title = command;

    const button = $('#btnAdb');
    button.textContent = enabled ? 'Disable ADB over WiFi' : 'Enable ADB over WiFi';
    button.dataset.action = enabled ? 'off' : 'on';
    button.className = enabled ? 'ghost danger' : 'primary';

    if (!enabled) {
      $('#adbDetail').textContent = 'TCP ADB is off. USB ADB is still available independently.';
      makeQr($('#adbQr'), '', 'Enable ADB over WiFi to show the connect QR code.');
      $('#adbQrHint').textContent = 'The QR code contains the full adb connect command.';
    } else if (!ip) {
      $('#adbDetail').textContent = 'ADB is enabled, but wlan0 has no IPv4 address yet. Connect WiFi first.';
      makeQr($('#adbQr'), '', 'Connect WiFi to show the ADB QR code.');
      $('#adbQrHint').textContent = 'The QR code will appear after WiFi gets an address.';
    } else if (!running) {
      $('#adbDetail').textContent = 'The TCP port is enabled but adbd is not running. Try Refresh.';
      makeQr($('#adbQr'), `adb connect ${ip}:${port}`, 'ADB connect command');
      $('#adbQrHint').textContent = 'Restart adbd with foxadb on if this persists.';
    } else {
      $('#adbDetail').textContent = `ADB is listening on TCP ${port}. Run adb connect from your computer.`;
      makeQr($('#adbQr'), `adb connect ${ip}:${port}`, 'ADB connect command');
      $('#adbQrHint').textContent = 'Scan with a computer or use the command above.';
    }
  }

  async function loadAdb(options = {}) {
    if (!token.get()) {
      $('#adbState').textContent = 'Token needed';
      $('#adbPill').className = 'pill off';
      return;
    }
    try {
      const data = await api('/cgi-bin/adb');
      renderAdb((data && data.adb) || {});
    } catch (error) {
      if (!options.silent) toast(error.message, 'bad');
      $('#adbState').textContent = 'Unavailable';
      $('#adbPill').className = 'pill off';
    }
  }

  async function toggleAdb(button) {
    if (!requireToken()) return;
    const action = button.dataset.action || (state.adb.enabled ? 'off' : 'on');
    state.adbBusy = true;
    busy(button, true, action === 'on' ? 'Enabling' : 'Disabling');
    try {
      const data = await api('/cgi-bin/adb', {
        method: 'POST',
        body: new URLSearchParams({ action }),
      });
      if (data && data.adb) renderAdb(data.adb);
      toast(data.message || (action === 'on' ? 'ADB over WiFi enabled' : 'ADB over WiFi disabled'), 'good');
      await loadAdb({ silent: true });
    } catch (error) {
      toast(error.message, 'bad');
      await loadAdb({ silent: true });
    } finally {
      state.adbBusy = false;
      busy(button, false);
      renderAdb(state.adb);
    }
  }

  function setFilesState(message, loading = false) {
    const element = $('#filesState');
    element.textContent = '';
    if (loading) {
      const spinner = document.createElement('span');
      spinner.className = 'spinner';
      element.appendChild(spinner);
    }
    element.appendChild(document.createTextNode(message));
  }

  function fileSort(a, b) {
    const rank = (entry) => (entry.type === 'dir' ? 0 : 1);
    const byType = rank(a) - rank(b);
    if (byType !== 0) return byType;
    return String(a.name || '').localeCompare(String(b.name || ''), undefined, {
      numeric: true,
      sensitivity: 'base',
    });
  }

  function markActiveRoot(path) {
    let best = '';
    document.querySelectorAll('#fileRoots button').forEach((button) => {
      const candidate = button.dataset.path || '';
      if (candidate === path || path.startsWith(`${candidate}/`)) {
        if (candidate.length > best.length) best = candidate;
      }
    });
    document.querySelectorAll('#fileRoots button').forEach((button) => {
      button.classList.toggle('active', button.dataset.path === best);
    });
  }

  function renderBreadcrumb(path) {
    const nav = $('#breadcrumb');
    nav.textContent = '';
    const crumbs = [];

    if (path === '/sdcard' || path.startsWith('/sdcard/')) {
      crumbs.push({ label: 'Internal', path: '/sdcard' });
      let current = '/sdcard';
      path.slice('/sdcard'.length).split('/').filter(Boolean).forEach((part) => {
        current += `/${part}`;
        crumbs.push({ label: part, path: current });
      });
    } else if (path === '/tmp' || path.startsWith('/tmp/')) {
      crumbs.push({ label: 'Temp', path: '/tmp' });
      let current = '/tmp';
      path.slice('/tmp'.length).split('/').filter(Boolean).forEach((part) => {
        current += `/${part}`;
        crumbs.push({ label: part, path: current });
      });
    } else {
      crumbs.push({ label: path || '/', path: path || '/sdcard' });
    }

    crumbs.forEach((crumb, index) => {
      if (index > 0) {
        const separator = document.createElement('span');
        separator.className = 'crumb-sep';
        separator.textContent = '/';
        nav.appendChild(separator);
      }
      const button = document.createElement('button');
      button.type = 'button';
      button.className = `crumb${index === crumbs.length - 1 ? ' current' : ''}`;
      button.textContent = crumb.label;
      button.title = crumb.path;
      button.addEventListener('click', () => loadFiles(crumb.path));
      nav.appendChild(button);
    });
  }

  function fileButton(label, handler, extra = '') {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = `ghost small ${extra}`.trim();
    button.textContent = label;
    button.addEventListener('click', handler);
    return button;
  }

  async function hashEntry(entry, output, button) {
    if (!requireToken()) return;
    busy(button, true, 'Hashing');
    output.textContent = 'Hashing…';
    output.classList.remove('hidden');
    try {
      const data = await api(`/cgi-bin/hash?path=${encodePath(entry.path)}`);
      output.textContent = `SHA-256 ${data.sha256}`;
      toast('SHA-256 calculated', 'good');
    } catch (error) {
      output.classList.add('hidden');
      toast(error.message, 'bad');
    } finally {
      busy(button, false);
    }
  }

  async function renameEntry(entry, button) {
    if (!requireToken()) return;
    const next = window.prompt(`Rename "${entry.name}" to:`, entry.name);
    if (next === null || next === entry.name) return;
    if (!next) {
      toast('Name cannot be empty', 'bad');
      return;
    }
    busy(button, true, 'Renaming');
    try {
      await api('/cgi-bin/fileop', {
        method: 'POST',
        body: new URLSearchParams({ op: 'rename', path: entry.path, name: next }),
      });
      toast('Renamed', 'good');
      await loadFiles(state.files.path);
    } catch (error) {
      toast(error.message, 'bad');
    } finally {
      busy(button, false);
    }
  }

  async function deleteEntry(entry, button) {
    if (!requireToken()) return;
    const what = entry.type === 'dir' ? 'folder and everything inside it' : 'file';
    if (!window.confirm(`Delete the ${what} "${entry.name}"? This cannot be undone.`)) return;
    busy(button, true, 'Deleting');
    try {
      await api('/cgi-bin/fileop', {
        method: 'POST',
        body: new URLSearchParams({ op: 'delete', path: entry.path }),
      });
      toast('Deleted', 'good');
      await loadFiles(state.files.path);
    } catch (error) {
      toast(error.message, 'bad');
    } finally {
      busy(button, false);
    }
  }

  function downloadLink(entry) {
    const link = document.createElement('a');
    link.className = 'button ghost small';
    link.textContent = 'Download';
    link.download = entry.name || '';
    link.rel = 'noopener';
    if (token.get()) {
      link.href = `/cgi-bin/file?path=${encodePath(entry.path)}&token=${encodeURIComponent(token.get())}`;
    } else {
      link.href = '#';
      link.addEventListener('click', (event) => {
        event.preventDefault();
        showTokenDialog();
        toast('Enter the access token, then try again.', 'bad');
      });
    }
    return link;
  }

  function renderFileRow(entry) {
    const row = document.createElement('li');
    row.className = 'file-row';

    const icon = document.createElement('span');
    const type = ['dir', 'file', 'link'].includes(entry.type) ? entry.type : 'file';
    icon.className = `file-icon ${type}`;
    icon.textContent = type === 'dir' ? 'DIR' : type === 'link' ? 'LNK' : 'FILE';
    row.appendChild(icon);

    const main = document.createElement('div');
    main.className = 'file-main';

    let name;
    if (type === 'dir') {
      name = document.createElement('button');
      name.type = 'button';
      name.className = 'file-name';
      name.title = `Open ${entry.name}`;
      name.addEventListener('click', () => loadFiles(entry.path));
    } else {
      name = document.createElement('span');
      name.className = 'file-name';
    }
    name.textContent = entry.name || '(unnamed)';
    main.appendChild(name);

    const meta = document.createElement('div');
    meta.className = 'file-meta';
    const size = type === 'dir' ? 'Folder' : formatBytes(entry.size);
    meta.textContent = `${size} · ${formatTime(entry.mtime)}`;
    main.appendChild(meta);

    const hash = document.createElement('code');
    hash.className = 'file-hash hidden';
    main.appendChild(hash);
    row.appendChild(main);

    const actions = document.createElement('div');
    actions.className = 'file-buttons';

    if (type === 'dir') {
      actions.appendChild(fileButton('Open', () => loadFiles(entry.path)));
    } else {
      actions.appendChild(downloadLink(entry));
      actions.appendChild(fileButton('SHA-256', (event) => hashEntry(entry, hash, event.currentTarget)));
    }

    if (type !== 'link') {
      actions.appendChild(fileButton('Rename', (event) => renameEntry(entry, event.currentTarget)));
      actions.appendChild(fileButton('Delete', (event) => deleteEntry(entry, event.currentTarget), 'danger'));
    }

    row.appendChild(actions);
    return row;
  }

  function renderFiles(data) {
    const path = (data && data.path) || state.files.path;
    state.files.path = path;
    state.files.entries = Array.isArray(data && data.entries) ? data.entries.slice() : [];
    markActiveRoot(path);
    renderBreadcrumb(path);
    $('#btnUp').disabled = path === '/sdcard' || path === '/tmp';

    const list = $('#fileList');
    list.textContent = '';
    const entries = state.files.entries.sort(fileSort);

    if (entries.length === 0) {
      list.classList.add('hidden');
      setFilesState('This folder is empty.', false);
      return;
    }

    entries.forEach((entry) => list.appendChild(renderFileRow(entry)));
    list.classList.remove('hidden');
    setFilesState(`${entries.length} item${entries.length === 1 ? '' : 's'}`, false);
  }

  async function loadFiles(path = state.files.path) {
    if (!requireToken()) return;
    const requestId = state.files.requestId + 1;
    state.files.requestId = requestId;
    state.files.busy = true;
    $('#fileList').classList.add('hidden');
    setFilesState(`Loading ${path}…`, true);

    try {
      const data = await api(`/cgi-bin/files?path=${encodePath(path)}`);
      if (requestId !== state.files.requestId) return;
      renderFiles(data);
    } catch (error) {
      if (requestId !== state.files.requestId) return;
      setFilesState(error.message, false);
      toast(error.message, 'bad');
    } finally {
      if (requestId === state.files.requestId) state.files.busy = false;
    }
  }

  function parentPath(path) {
    const clean = (path || '/sdcard').replace(/\/+$/, '');
    if (clean === '/sdcard' || clean === '/tmp') return clean;
    const slash = clean.lastIndexOf('/');
    if (slash <= 0) return clean.startsWith('/tmp') ? '/tmp' : '/sdcard';
    return clean.slice(0, slash);
  }

  async function makeFolder(button) {
    if (!requireToken()) return;
    const name = window.prompt('New folder name:');
    if (name === null || name === '') return;
    busy(button, true, 'Creating');
    try {
      await api('/cgi-bin/fileop', {
        method: 'POST',
        body: new URLSearchParams({ op: 'mkdir', path: state.files.path, name }),
      });
      toast('Folder created', 'good');
      await loadFiles(state.files.path);
    } catch (error) {
      toast(error.message, 'bad');
    } finally {
      busy(button, false);
    }
  }

  function stateLabel(wifi) {
    switch (wifi.state) {
      case 'connected': return 'Connected';
      case 'ready': return 'Ready to scan';
      case 'starting': return 'Starting';
      default: return 'WiFi off';
    }
  }

  function signalClass(dbm) {
    if (dbm >= -55) return 's4';
    if (dbm >= -67) return 's3';
    if (dbm >= -78) return 's2';
    return 's1';
  }

  function signalBars(dbm) {
    const wrap = document.createElement('div');
    wrap.className = `signal ${signalClass(dbm)}`;
    for (let i = 0; i < 4; i += 1) wrap.appendChild(document.createElement('i'));
    return wrap;
  }

  async function refresh() {
    const data = await api('/cgi-bin/status');
    const wifi = data.wifi || {};
    state.wifi = wifi;

    const pill = $('#statusPill');
    const text = $('#statusText');
    pill.className = 'pill';
    if (wifi.state === 'connected') {
      pill.classList.add('on');
      text.textContent = 'Connected';
    } else if (wifi.state === 'off') {
      pill.classList.add('off');
      text.textContent = 'WiFi off';
    } else {
      pill.classList.add('warn');
      text.textContent = stateLabel(wifi);
    }

    $('#ssid').textContent = wifi.ssid || (wifi.state === 'off' ? 'WiFi is off' : 'Not connected');
    $('#ip').textContent = wifi.ip || '—';
    $('#mac').textContent = wifi.mac || '—';
    $('#state').textContent = wifi.wpa_state || wifi.state || '—';

    if (wifi.state === 'connected') {
      $('#detail').textContent = 'Recovery is reachable over the local network. Open a terminal for advanced work.';
    } else if (wifi.state === 'off') {
      $('#detail').textContent = 'Start the WiFi stack, then scan for a network.';
    } else {
      $('#detail').textContent = 'WiFi is powered. Pick a network below or join a hidden one.';
    }

    $('#btnWifi').textContent = wifi.state === 'off' ? 'Start WiFi' : 'Stop WiFi';
    $('#btnWifi').dataset.action = wifi.state === 'off' ? 'on' : 'off';
    $('#btnDisconnect').disabled = wifi.state !== 'connected';

    renderWebQr();
    if (token.get() && !state.adbBusy) {
      loadAdb({ silent: true }).catch(() => { /* keep the last known ADB state */ });
    }
  }

  function renderNetworks(networks) {
    const list = $('#networks');
    const scanState = $('#scanState');
    list.textContent = '';

    if (!Array.isArray(networks) || networks.length === 0) {
      scanState.textContent = 'No networks found. Make sure WiFi is on and try again.';
      return;
    }

    networks
      .slice()
      .sort((a, b) => Number(b.signal) - Number(a.signal))
      .forEach((net) => {
        const li = document.createElement('li');
        li.className = 'network';

        li.appendChild(signalBars(Number(net.signal)));

        const name = document.createElement('span');
        name.className = 'name';
        name.textContent = net.ssid;
        li.appendChild(name);

        const sec = document.createElement('span');
        sec.className = 'sec';
        sec.textContent = net.security || 'OPEN';
        li.appendChild(sec);

        const connect = document.createElement('button');
        connect.className = 'ghost small';
        connect.textContent = 'Connect';
        connect.addEventListener('click', () => openConnect(net.ssid, net.security));
        li.appendChild(connect);

        list.appendChild(li);
      });

    scanState.textContent = `${networks.length} network${networks.length === 1 ? '' : 's'} found.`;
  }

  async function scan() {
    const button = $('#btnScan');
    const scanState = $('#scanState');
    busy(button, true, 'Scanning');
    scanState.innerHTML = '<span class="spinner"></span>Scanning for networks…';
    try {
      const networks = await api('/cgi-bin/scan');
      renderNetworks(networks);
    } catch (error) {
      scanState.textContent = error.message;
      toast(error.message, 'bad');
    } finally {
      busy(button, false);
    }
  }

  async function doConnect(ssid, psk, enc, remember) {
    const body = new URLSearchParams({ ssid, psk, enc, remember: remember ? '1' : '0' });
    const data = await api('/cgi-bin/connect', { method: 'POST', body });
    toast(data.message || `Connected to ${ssid}`, 'good');
    await refresh();
  }

  function openConnect(ssid, security) {
    if (security === 'OPEN') {
      doConnect(ssid, '', 'OPEN', false).catch((error) => toast(error.message, 'bad'));
      return;
    }
    state.selected = { ssid, security };
    $('#dialogTitle').textContent = `Connect to ${ssid}`;
    $('#dialogSub').textContent = `${security} network`;
    $('#dialogPsk').value = '';
    $('#dialogRemember').checked = false;
    $('#connectDialog').showModal();
    setTimeout(() => $('#dialogPsk').focus(), 50);
  }

  function showTokenDialog() {
    const dialog = $('#tokenDialog');
    if (dialog.open) return;
    $('#tokenInput').value = token.get();
    dialog.showModal();
    setTimeout(() => $('#tokenInput').focus(), 50);
  }

  $('#btnScan').addEventListener('click', scan);
  $('#btnRescan').addEventListener('click', scan);

  $('#btnWifi').addEventListener('click', async (event) => {
    const button = event.currentTarget;
    const action = button.dataset.action || 'on';
    busy(button, true, action === 'on' ? 'Starting' : 'Stopping');
    try {
      const data = await api('/cgi-bin/wifi', {
        method: 'POST',
        body: new URLSearchParams({ action }),
      });
      toast(data.message || 'WiFi updated', 'good');
      await refresh();
    } catch (error) {
      toast(error.message, 'bad');
    } finally {
      busy(button, false);
      button.textContent = button.dataset.action === 'off' ? 'Stop WiFi' : 'Start WiFi';
    }
  });

  $('#btnDisconnect').addEventListener('click', async (event) => {
    const button = event.currentTarget;
    busy(button, true, 'Disconnecting');
    try {
      const data = await api('/cgi-bin/disconnect', { method: 'POST' });
      toast(data.message || 'Disconnected', 'good');
      await refresh();
    } catch (error) {
      toast(error.message, 'bad');
    } finally {
      busy(button, false);
      button.disabled = state.wifi.state !== 'connected';
    }
  });

  $('#manualForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    const button = event.submitter || $('#manualForm button[type="submit"]');
    const ssid = $('#manualSsid').value.trim();
    const psk = $('#manualPsk').value;
    const remember = $('#manualRemember').checked;
    if (!ssid) return;
    busy(button, true, 'Connecting');
    try {
      await doConnect(ssid, psk, psk ? 'WPA2' : 'OPEN', remember);
    } catch (error) {
      toast(error.message, 'bad');
    } finally {
      busy(button, false);
    }
  });

  $('#connectForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    if (event.submitter && event.submitter.value === 'cancel') {
      $('#connectDialog').close();
      return;
    }
    if (!state.selected) return;
    const button = $('#dialogConnect');
    busy(button, true, 'Connecting');
    try {
      await doConnect(
        state.selected.ssid,
        $('#dialogPsk').value,
        state.selected.security || 'WPA2',
        $('#dialogRemember').checked,
      );
      $('#connectDialog').close();
    } catch (error) {
      toast(error.message, 'bad');
    } finally {
      busy(button, false);
    }
  });

  $('#tokenForm').addEventListener('submit', async (event) => {
    event.preventDefault();
    if (event.submitter && event.submitter.value === 'cancel') {
      $('#tokenDialog').close();
      return;
    }
    token.set($('#tokenInput').value.trim());
    $('#tokenDialog').close();
    toast('Access token saved', 'good');
    renderWebQr();
    refresh().catch((error) => toast(error.message, 'bad'));
    if (token.get()) {
      loadFiles(state.files.path).catch(() => { /* the error is shown in the file card */ });
    }
  });

  $('#btnAdb').addEventListener('click', (event) => toggleAdb(event.currentTarget));

  $('#btnAdbRefresh').addEventListener('click', async (event) => {
    const button = event.currentTarget;
    busy(button, true, 'Refreshing');
    try {
      await loadAdb();
    } finally {
      busy(button, false);
    }
  });

  $('#btnCopyWeb').addEventListener('click', async () => {
    const url = foxwebUrl();
    if (!url) {
      toast('Connect WiFi first', 'bad');
      return;
    }
    const copied = await copyText(url);
    toast(copied ? 'Link copied' : 'Select the link and copy it', copied ? 'good' : '');
  });

  $('#btnUpload').addEventListener('click', () => {
    if (!requireToken()) return;
    $('#fileUpload').click();
  });

  let uploading = false;
  $('#fileUpload').addEventListener('change', async (event) => {
    const files = Array.from(event.target.files || []);
    event.target.value = '';
    if (files.length === 0 || uploading) return;
    if (!requireToken()) return;

    uploading = true;
    $('#btnUpload').disabled = true;
    let uploaded = 0;

    try {
      for (const file of files) {
        const exists = state.files.entries.some((entry) => entry.name === file.name);
        let overwrite = '0';
        if (exists) {
          if (!window.confirm(`"${file.name}" already exists. Replace it?`)) continue;
          overwrite = '1';
        }
        setFilesState(`Uploading ${file.name} (${formatBytes(file.size)})…`, true);
        await api(
          `/cgi-bin/upload?dir=${encodePath(state.files.path)}&name=${encodePath(file.name)}&overwrite=${overwrite}`,
          {
            method: 'POST',
            body: file,
            headers: { 'Content-Type': 'application/octet-stream' },
          },
        );
        uploaded += 1;
      }

      if (uploaded > 0) {
        toast(`Uploaded ${uploaded} file${uploaded === 1 ? '' : 's'}`, 'good');
        await loadFiles(state.files.path);
      } else {
        setFilesState('Upload cancelled.', false);
      }
    } catch (error) {
      toast(error.message, 'bad');
      setFilesState(error.message, false);
    } finally {
      uploading = false;
      $('#btnUpload').disabled = false;
    }
  });

  $('#btnMkdir').addEventListener('click', (event) => makeFolder(event.currentTarget));
  $('#btnFilesRefresh').addEventListener('click', () => loadFiles(state.files.path));
  $('#btnUp').addEventListener('click', () => {
    const parent = parentPath(state.files.path);
    if (parent !== state.files.path) loadFiles(parent);
  });

  document.querySelectorAll('#fileRoots button').forEach((button) => {
    button.addEventListener('click', () => loadFiles(button.dataset.path || '/sdcard'));
  });

  document.querySelectorAll('[data-reboot]').forEach((button) => {
    button.addEventListener('click', async () => {
      const target = button.dataset.reboot;
      const label = target === 'system' ? 'the system' : target === 'recovery' ? 'recovery' : 'the bootloader';
      if (!window.confirm(`Reboot to ${label}?`)) return;
      busy(button, true, 'Rebooting');
      try {
        await api('/cgi-bin/reboot', {
          method: 'POST',
          body: new URLSearchParams({ target }),
        });
      } catch (error) {
        toast(error.message, 'bad');
        busy(button, false);
      }
    });
  });

  $('#btnLog').addEventListener('click', async () => {
    const log = $('#log');
    if (!log.classList.contains('hidden')) {
      log.classList.add('hidden');
      $('#btnLog').textContent = 'Show';
      return;
    }
    $('#btnLog').disabled = true;
    try {
      log.textContent = await raw('/cgi-bin/log');
      log.classList.remove('hidden');
      $('#btnLog').textContent = 'Hide';
      log.scrollTop = log.scrollHeight;
    } catch (error) {
      toast(error.message, 'bad');
    } finally {
      $('#btnLog').disabled = false;
    }
  });

  renderWebQr();
  if (token.get()) {
    loadFiles(state.files.path).catch(() => { /* the file card shows the error */ });
  } else {
    setFilesState('Enter the access token, then open a folder.', false);
    $('#adbState').textContent = 'Token needed';
    $('#adbPill').className = 'pill off';
  }

  refresh().catch((error) => {
    $('#statusText').textContent = 'Unavailable';
    toast(error.message, 'bad');
  });

  setInterval(() => {
    refresh().catch(() => { /* keep the last known state */ });
  }, 7000);
})();
