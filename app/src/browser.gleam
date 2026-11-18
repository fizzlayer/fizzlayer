//// Browser FFI. JavaScript returns plain tuples so this module does not depend
//// on the Gleam prelude from inside `.mjs` files.

@external(javascript, "./http_ffi.mjs", "send")
pub fn send(
  _method: String,
  _path: String,
  _body: String,
  done: fn(#(Int, String)) -> Nil,
) -> Nil {
  done(#(0, "HTTP is only available in the browser"))
}

@external(javascript, "./http_ffi.mjs", "probe_tools")
pub fn probe_tools(
  _url: String,
  _auth_kind: String,
  _api_key: String,
  done: fn(#(Bool, String)) -> Nil,
) -> Nil {
  done(#(False, "Tool listing is only available in the browser"))
}

@external(javascript, "./http_ffi.mjs", "hosted_probe")
pub fn hosted_probe(done: fn(#(Int, String)) -> Nil) -> Nil {
  done(#(404, ""))
}

@external(javascript, "./http_ffi.mjs", "copy_text")
pub fn copy_text(_value: String, done: fn(#(Bool, String)) -> Nil) -> Nil {
  done(#(False, ""))
}

@external(javascript, "./http_ffi.mjs", "assign")
pub fn assign(_path: String) -> Nil {
  Nil
}

@external(javascript, "./http_ffi.mjs", "continue_checkout")
pub fn continue_checkout(_plan: String) -> Nil {
  Nil
}

@external(javascript, "./supabase_ffi.mjs", "load_config_text")
pub fn load_config_text(done: fn(#(Bool, String)) -> Nil) -> Nil {
  done(#(False, "Config is only available in the browser"))
}

@external(javascript, "./supabase_ffi.mjs", "create_client")
pub fn create_client(_url: String, _key: String) -> Nil {
  Nil
}

@external(javascript, "./supabase_ffi.mjs", "page_origin")
pub fn page_origin() -> String {
  ""
}

@external(javascript, "./supabase_ffi.mjs", "strip_auth_params")
pub fn strip_auth_params() -> Nil {
  Nil
}

@external(javascript, "./supabase_ffi.mjs", "get_session")
pub fn get_session(done: fn(#(Bool, String, String)) -> Nil) -> Nil {
  done(#(False, "Sessions are only available in the browser", ""))
}

@external(javascript, "./supabase_ffi.mjs", "sign_in_with_otp")
pub fn sign_in_with_otp(
  _email: String,
  _redirect_to: String,
  done: fn(#(Bool, String)) -> Nil,
) -> Nil {
  done(#(False, "Magic links are only available in the browser"))
}

@external(javascript, "./supabase_ffi.mjs", "sign_in_with_github")
pub fn sign_in_with_github(
  _redirect_to: String,
  done: fn(#(Bool, String)) -> Nil,
) -> Nil {
  done(#(False, "GitHub sign-in is only available in the browser"))
}

@external(javascript, "./supabase_ffi.mjs", "sign_out_local")
pub fn sign_out_local(done: fn(#(Bool, String)) -> Nil) -> Nil {
  done(#(False, "Sign-out is only available in the browser"))
}
