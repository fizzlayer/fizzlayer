import { createClient } from "@supabase/supabase-js";

let client = null;

function failed(error, fallback) {
  const message = error && error.message ? error.message : fallback;
  return [false, String(message)];
}

export function create_client(url, key) {
  client = createClient(url, key, {
    auth: {
      flowType: "pkce",
      detectSessionInUrl: true,
      persistSession: true,
      autoRefreshToken: true,
    },
  });
}

export function page_origin() {
  return globalThis.location?.origin ?? "";
}

// Drop the magic-link or OAuth code from the address bar after supabase-js reads it.
export function strip_auth_params() {
  if (!globalThis.location || !globalThis.history) return;
  const url = new URL(globalThis.location.href);
  const hadCode = url.searchParams.has("code") || url.searchParams.has("state");
  const hadHash = url.hash.length > 1;
  url.hash = "";
  url.searchParams.delete("code");
  url.searchParams.delete("state");
  if (hadCode || hadHash) {
    globalThis.history.replaceState(null, "", url.pathname + url.search);
  }
}

export function get_session(done) {
  if (!client) {
    done([false, "Supabase client is not ready.", ""]);
    return;
  }
  client.auth
    .getSession()
    .then(({ data, error }) => {
      if (error) {
        done([false, error.message || "Could not read the session.", ""]);
        return;
      }
      const token = data?.session?.access_token ?? "";
      const email = data?.session?.user?.email ?? "";
      done([true, token, email]);
    })
    .catch((error) => {
      const [ok, message] = failed(error, "Could not read the session.");
      done([ok, message, ""]);
    });
}

export function sign_in_with_otp(email, redirectTo, done) {
  if (!client) {
    done(failed(null, "Supabase client is not ready."));
    return;
  }
  // Existing accounts only. Creating users here would skip the API's sign-up limits.
  client.auth
    .signInWithOtp({
      email,
      options: { emailRedirectTo: redirectTo, shouldCreateUser: false },
    })
    .then(({ error }) => {
      done(error ? failed(error, "Could not send the sign-in email.") : [true, ""]);
    })
    .catch((error) => done(failed(error, "Could not send the sign-in email.")));
}

export function sign_in_with_github(redirectTo, done) {
  if (!client) {
    done(failed(null, "Supabase client is not ready."));
    return;
  }
  client.auth
    .signInWithOAuth({
      provider: "github",
      options: { redirectTo },
    })
    .then(({ error }) => {
      done(error ? failed(error, "GitHub sign-in could not start.") : [true, ""]);
    })
    .catch((error) => done(failed(error, "GitHub sign-in could not start.")));
}

export function sign_out_local(done) {
  if (!client) {
    done([true, ""]);
    return;
  }
  client.auth
    .signOut({ scope: "local" })
    .then(({ error }) => {
      done(error ? failed(error, "Could not clear the browser session.") : [true, ""]);
    })
    .catch((error) => done(failed(error, "Could not clear the browser session.")));
}

export function load_config_text(done) {
  const paths = ["/app/config.json", "/config.json"];
  const next = (index) => {
    if (index >= paths.length) {
      done([false, "Missing config.json"]);
      return;
    }
    fetch(paths[index], { cache: "no-store", credentials: "same-origin" })
      .then(async (response) => {
        if (!response.ok) {
          next(index + 1);
          return;
        }
        const text = await response.text();
        if (!text || text.trim().startsWith("<")) {
          next(index + 1);
          return;
        }
        done([true, text]);
      })
      .catch(() => next(index + 1));
  };
  next(0);
}
