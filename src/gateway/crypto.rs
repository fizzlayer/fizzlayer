//! AES-256-GCM for upstream MCP credentials, and the registration-token hash.
//! Plaintext and key bytes are not written to errors or logs.

use base64::{
    Engine,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use ring::{
    aead::{AES_256_GCM, Aad, LessSafeKey, NONCE_LEN, Nonce, UnboundKey},
    digest,
    rand::{SecureRandom, SystemRandom},
};

use crate::customer::ApiError;

pub const KEY_ID: &str = "v1";

const REGISTRATION_PREFIX: &str = "fizz_reg_";

pub fn registration_token() -> Result<String, ApiError> {
    let mut bytes = [0u8; 32];
    SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| ApiError::new(503, "unavailable", "A token could not be minted."))?;
    Ok(format!("{REGISTRATION_PREFIX}{}", hex_encode(&bytes)))
}

pub fn registration_token_ok(token: &str) -> bool {
    let Some(rest) = token.strip_prefix(REGISTRATION_PREFIX) else {
        return false;
    };
    rest.len() == 64 && rest.bytes().all(|c| c.is_ascii_hexdigit())
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    hex_encode(digest::digest(&digest::SHA256, bytes).as_ref())
}

pub fn secret_key_from(raw: &str) -> Result<[u8; 32], ApiError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(encryption_missing());
    }
    let decoded = STANDARD
        .decode(trimmed)
        .or_else(|_| URL_SAFE_NO_PAD.decode(trimmed))
        .map_err(|_| encryption_bad())?;
    if decoded.len() != 32 {
        return Err(encryption_bad());
    }
    let mut key = [0u8; 32];
    key.copy_from_slice(&decoded);
    Ok(key)
}

pub fn seal(key: &[u8; 32], plaintext: &[u8]) -> Result<String, ApiError> {
    if plaintext.is_empty() || plaintext.len() > 4096 || plaintext.iter().any(u8::is_ascii_control)
    {
        return Err(ApiError::new(
            400,
            "invalid_request",
            "The MCP credential is empty or too long.",
        ));
    }
    let unbound = UnboundKey::new(&AES_256_GCM, key).map_err(|_| {
        ApiError::new(
            503,
            "encryption_unavailable",
            "The credential could not be stored.",
        )
    })?;
    let sealing = LessSafeKey::new(unbound);
    let mut nonce_bytes = [0u8; NONCE_LEN];
    SystemRandom::new().fill(&mut nonce_bytes).map_err(|_| {
        ApiError::new(
            503,
            "encryption_unavailable",
            "The credential could not be stored.",
        )
    })?;
    let nonce = Nonce::assume_unique_for_key(nonce_bytes);
    let mut body = plaintext.to_vec();
    sealing
        .seal_in_place_append_tag(nonce, Aad::empty(), &mut body)
        .map_err(|_| {
            ApiError::new(
                503,
                "encryption_unavailable",
                "The credential could not be stored.",
            )
        })?;
    let mut out = Vec::with_capacity(1 + NONCE_LEN + body.len());
    out.push(1);
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&body);
    Ok(STANDARD.encode(out))
}

pub fn open(key: &[u8; 32], encoded: &str) -> Result<Vec<u8>, ApiError> {
    let bytes = STANDARD.decode(encoded.trim()).map_err(|_| unreadable())?;
    if bytes.len() < 1 + NONCE_LEN + 16 || bytes[0] != 1 {
        return Err(unreadable());
    }
    let mut nonce_bytes = [0u8; NONCE_LEN];
    nonce_bytes.copy_from_slice(&bytes[1..1 + NONCE_LEN]);
    let unbound = UnboundKey::new(&AES_256_GCM, key).map_err(|_| unreadable())?;
    let opening = LessSafeKey::new(unbound);
    let nonce = Nonce::assume_unique_for_key(nonce_bytes);
    let mut body = bytes[1 + NONCE_LEN..].to_vec();
    let plain = opening
        .open_in_place(nonce, Aad::empty(), &mut body)
        .map_err(|_| unreadable())?;
    Ok(plain.to_vec())
}

pub fn signing_pem(raw: &str) -> Result<Vec<u8>, ApiError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(signing_missing());
    }
    let pem = if trimmed.contains("BEGIN ") {
        if trimmed.contains('\n') {
            trimmed.to_string()
        } else {
            trimmed.replace("\\n", "\n")
        }
    } else {
        let decoded = STANDARD
            .decode(trimmed)
            .or_else(|_| URL_SAFE_NO_PAD.decode(trimmed))
            .map_err(|_| signing_bad())?;
        String::from_utf8(decoded).map_err(|_| signing_bad())?
    };
    fizz_gateway::jwt::from_pem(pem.as_bytes()).map_err(|_| signing_bad())?;
    Ok(pem.into_bytes())
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(HEX[usize::from(byte >> 4)] as char);
        out.push(HEX[usize::from(byte & 0x0f)] as char);
    }
    out
}

fn encryption_missing() -> ApiError {
    ApiError::new(
        503,
        "encryption_unavailable",
        "Storing an MCP credential needs GATEWAY_SECRET_KEY on the server.",
    )
}

fn encryption_bad() -> ApiError {
    ApiError::new(
        503,
        "encryption_unavailable",
        "GATEWAY_SECRET_KEY must be a base64-encoded 32-byte key.",
    )
}

fn signing_missing() -> ApiError {
    ApiError::new(
        503,
        "signing_unavailable",
        "Client tokens need GATEWAY_SIGNING_KEY on the server.",
    )
}

fn signing_bad() -> ApiError {
    ApiError::new(
        503,
        "signing_unavailable",
        "GATEWAY_SIGNING_KEY must be a PKCS#8 PEM for an ES256 key.",
    )
}

fn unreadable() -> ApiError {
    ApiError::new(
        503,
        "missing_secret",
        "A stored MCP credential could not be read.",
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seal_round_trip_hides_the_plaintext_in_the_ciphertext() {
        let key = [7u8; 32];
        let plain = b"ghp_example_token";
        let sealed = seal(&key, plain).unwrap();
        assert!(!sealed.contains("ghp_example"));
        assert_eq!(open(&key, &sealed).unwrap(), plain);
        let mut other = key;
        other[0] ^= 1;
        assert!(open(&other, &sealed).is_err());
    }

    #[test]
    fn registration_token_is_the_expected_shape() {
        let token = registration_token().unwrap();
        assert!(registration_token_ok(&token));
        assert_eq!(sha256_hex(token.as_bytes()).len(), 64);
        assert!(!registration_token_ok("fizz_reg_short"));
    }
}
