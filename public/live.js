// Live readings from the Compute worker. HTTPS polling stays in place when streaming is off.
(() => {
  let socket = null;
  let stopped = true;
  let retry = null;
  let renew = null;
  let onReading = () => {};

  function clearTimers() {
    clearTimeout(retry);
    clearTimeout(renew);
    retry = null;
    renew = null;
  }

  function closeSocket() {
    if (!socket) return;
    socket.onopen = socket.onmessage = socket.onclose = null;
    socket.close();
    socket = null;
  }

  async function mint() {
    const response = await fetch('/api/stream', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'content-type': 'application/json' },
      body: '{}',
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok || !data.token || !data.live_url) return null;
    return data;
  }

  function connect(session) {
    if (stopped) return;
    closeSocket();
    let opened;
    try {
      opened = new WebSocket(session.live_url);
    } catch {
      schedule(1500);
      return;
    }
    socket = opened;
    opened.onopen = () => {
      if (stopped || socket !== opened) return;
      opened.send(JSON.stringify({ op: 'auth', key: session.token }));
      opened.send(JSON.stringify({ op: 'subscribe' }));
    };
    opened.onmessage = (event) => {
      let message;
      try { message = JSON.parse(event.data); } catch { return; }
      if (message.op === 'reading') onReading(message);
    };
    opened.onclose = () => {
      if (socket === opened) socket = null;
      if (!stopped) schedule(1500);
    };
  }

  function schedule(delay) {
    clearTimeout(retry);
    retry = setTimeout(() => { void open(); }, delay);
  }

  async function open() {
    if (stopped) return;
    let session;
    try { session = await mint(); } catch { session = null; }
    if (stopped) return;
    if (!session) return;
    const refreshIn = Math.max(60, (session.expires_in_seconds || 900) - 60) * 1000;
    clearTimeout(renew);
    renew = setTimeout(() => { void open(); }, refreshIn);
    connect(session);
  }

  window.fizzLive = {
    start(handler) {
      onReading = typeof handler === 'function' ? handler : () => {};
      stopped = false;
      clearTimers();
      void open();
    },
    stop() {
      stopped = true;
      clearTimers();
      closeSocket();
    },
  };
})();
