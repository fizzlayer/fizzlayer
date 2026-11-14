//! Fizzlayer-signed client JWTs. agentgateway checks them with `jwtAuth`.
//! The private key stays on disk at mode 0600 and is never logged.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use jsonwebtoken::jwk::{
    AlgorithmParameters, CommonParameters, EllipticCurve, EllipticCurveKeyParameters,
    EllipticCurveKeyType, Jwk, JwkSet, KeyAlgorithm, PublicKeyUse,
};
use jsonwebtoken::{Algorithm, EncodingKey, Header};
use p256::ecdsa::SigningKey;
use p256::pkcs8::{DecodePrivateKey, EncodePrivateKey, LineEnding};
use rand_core::OsRng;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::error::{GatewayError, GatewayResult};

pub const ISSUER: &str = "fizzlayer";

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GatewayClaims {
    pub iss: String,
    pub sub: String,
    pub aud: String,
    pub ws: String,
    pub jti: String,
    pub exp: u64,
    pub iat: u64,
}

pub struct SigningMaterial {
    encoding: EncodingKey,
    jwk_set: JwkSet,
    kid: String,
}

impl SigningMaterial {
    pub fn kid(&self) -> &str {
        &self.kid
    }

    pub fn jwks_json(&self) -> GatewayResult<Vec<u8>> {
        serde_json::to_vec_pretty(&self.jwk_set)
            .map_err(|_| GatewayError::message("jwks encoding failed"))
    }

    pub fn issue(
        &self,
        sub: &str,
        workspace: Uuid,
        audience: &str,
        jti: Uuid,
        ttl_secs: u64,
    ) -> GatewayResult<String> {
        if sub.is_empty() || sub.len() > 80 || audience.is_empty() {
            return Err(GatewayError::message("token claims were rejected"));
        }
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| GatewayError::message("system clock is unavailable"))?
            .as_secs();
        let claims = GatewayClaims {
            iss: ISSUER.to_string(),
            sub: sub.to_string(),
            aud: audience.to_string(),
            ws: workspace.to_string(),
            jti: jti.to_string(),
            iat: now,
            exp: now.saturating_add(ttl_secs),
        };
        let mut header = Header::new(Algorithm::ES256);
        header.kid = Some(self.kid.clone());
        jsonwebtoken::encode(&header, &claims, &self.encoding)
            .map_err(|_| GatewayError::message("token signing failed"))
    }
}

pub fn load_or_create(path: &Path) -> GatewayResult<SigningMaterial> {
    if path.exists() {
        let pem =
            fs::read(path).map_err(|_| GatewayError::message("signing key could not be read"))?;
        return material_from_pem(&pem);
    }
    let signing = SigningKey::random(&mut OsRng);
    let pem = signing
        .to_pkcs8_pem(LineEnding::LF)
        .map_err(|_| GatewayError::message("signing key could not be encoded"))?;
    write_private(path, pem.as_bytes())?;
    material_from_pem(pem.as_bytes())
}

fn material_from_pem(pem: &[u8]) -> GatewayResult<SigningMaterial> {
    let pem_str = std::str::from_utf8(pem)
        .map_err(|_| GatewayError::message("signing key could not be read"))?;
    let signing = SigningKey::from_pkcs8_pem(pem_str)
        .map_err(|_| GatewayError::message("signing key could not be read"))?;
    let encoding = EncodingKey::from_ec_pem(pem)
        .map_err(|_| GatewayError::message("signing key could not be read"))?;
    let point = signing.verifying_key().to_encoded_point(false);
    let x = point
        .x()
        .ok_or_else(|| GatewayError::message("signing key could not be read"))?;
    let y = point
        .y()
        .ok_or_else(|| GatewayError::message("signing key could not be read"))?;
    let x_bytes: &[u8] = x.as_ref();
    let y_bytes: &[u8] = y.as_ref();
    let kid = format!(
        "fizzlayer-{}",
        &hex::encode(Sha256::digest([x_bytes, y_bytes].concat()))[..8]
    );
    let jwk = Jwk {
        common: CommonParameters {
            public_key_use: Some(PublicKeyUse::Signature),
            key_operations: None,
            key_algorithm: Some(KeyAlgorithm::ES256),
            key_id: Some(kid.clone()),
            x509_url: None,
            x509_chain: None,
            x509_sha1_fingerprint: None,
            x509_sha256_fingerprint: None,
        },
        algorithm: AlgorithmParameters::EllipticCurve(EllipticCurveKeyParameters {
            key_type: EllipticCurveKeyType::EC,
            curve: EllipticCurve::P256,
            x: URL_SAFE_NO_PAD.encode(x),
            y: URL_SAFE_NO_PAD.encode(y),
        }),
    };
    Ok(SigningMaterial {
        encoding,
        jwk_set: JwkSet { keys: vec![jwk] },
        kid,
    })
}

fn write_private(path: &Path, bytes: &[u8]) -> GatewayResult<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|_| GatewayError::message("signing key directory could not be created"))?;
    }
    let tmp = temp_path(path);
    {
        let mut options = OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(&tmp)
            .map_err(|_| GatewayError::message("signing key could not be written"))?;
        file.write_all(bytes)
            .map_err(|_| GatewayError::message("signing key could not be written"))?;
        file.sync_all()
            .map_err(|_| GatewayError::message("signing key could not be written"))?;
    }
    fs::rename(&tmp, path)
        .map_err(|_| GatewayError::message("signing key could not be written"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .map_err(|_| GatewayError::message("signing key could not be written"))?;
    }
    Ok(())
}

fn temp_path(path: &Path) -> PathBuf {
    let mut tmp = path.to_path_buf();
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("key");
    tmp.set_file_name(format!(".{name}.tmp"));
    tmp
}

#[cfg(test)]
mod tests {
    use super::*;
    use jsonwebtoken::{DecodingKey, Validation};
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn round_trip_matches_the_jwks_agentgateway_loads() {
        let dir = std::env::temp_dir().join(format!("fizz-jwt-{}", Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("signing.pem");
        let material = load_or_create(&path).unwrap();
        let again = load_or_create(&path).unwrap();
        assert_eq!(material.kid(), again.kid());
        let workspace = Uuid::new_v4();
        let jti = Uuid::new_v4();
        let audience = "http://agentgateway:3000/mcp";
        let token = material
            .issue(&Uuid::new_v4().to_string(), workspace, audience, jti, 3600)
            .unwrap();
        assert!(!token.contains('\n'));
        let header = jsonwebtoken::decode_header(&token).unwrap();
        assert_eq!(header.kid.as_deref(), Some(material.kid()));
        assert_eq!(header.alg, Algorithm::ES256);
        let jwk = &material.jwk_set.keys[0];
        let decoding = DecodingKey::from_jwk(jwk).unwrap();
        let mut validation = Validation::new(Algorithm::ES256);
        validation.set_issuer(&[ISSUER]);
        validation.set_audience(&[audience]);
        let decoded =
            jsonwebtoken::decode::<GatewayClaims>(&token, &decoding, &validation).unwrap();
        assert_eq!(decoded.claims.ws, workspace.to_string());
        assert_eq!(decoded.claims.jti, jti.to_string());
        assert!(decoded.claims.exp > decoded.claims.iat);
        let mode = fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        let _ = fs::remove_dir_all(&dir);
    }
}
