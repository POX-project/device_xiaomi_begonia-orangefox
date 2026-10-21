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
    refresh().catch((error) => toast(error.message, 'bad'));
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

  refresh().catch((error) => {
    $('#statusText').textContent = 'Unavailable';
    toast(error.message, 'bad');
  });

  setInterval(() => {
    refresh().catch(() => { /* keep the last known state */ });
  }, 7000);
})();
