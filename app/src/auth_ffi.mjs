// Browser pieces of sign-in that Gleam cannot reach directly.

// Removes Supabase email-link and sign-in error fragments from the address bar,
// so a reload or a copied URL does not reuse them, and supabase-js never
// consumes a password-reset token as a sign-in.
export function clear_hash() {
  if (typeof window === 'undefined' || !window.location.hash) return;
  window.history.replaceState(window.history.state, '', window.location.pathname + window.location.search);
}

export function passkeys_supported() {
  return globalThis.window?.fizzPasskey?.supported === true;
}

async function post(body) {
  const response = await fetch('/api/auth', {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  return [response.status, await response.text()];
}

// Signs in with a passkey through /api/auth and public/passkey.js.
// Calls done with [status, body]; status -1 means the person cancelled.
export async function passkey_sign_in(done) {
  try {
    const [status, text] = await post({ action: 'passkey_options' });
    if (status !== 200) return done([status, text]);
    const start = JSON.parse(text);
    const credential = await window.fizzPasskey.credential(start.options, false);
    done(await post({ action: 'passkey_sign_in', challenge_id: start.challenge_id, credential }));
  } catch (error) {
    if (window.fizzPasskey?.cancelled(error)) return done([-1, '']);
    done([0, "That passkey didn't work. Try again."]);
  }
}
