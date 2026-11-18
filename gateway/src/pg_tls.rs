//! Postgres TLS for `fizz-guard`, `fizz-agent`, and `fizz-config`.
//!
//! `sslmode` on `DATABASE_URL` selects the connector:
//!
//! - `disable` is plain TCP (`NoTls`), for a Postgres that does not speak TLS.
//! - omitted or `prefer` tries TLS and falls back to plain TCP when the server
//!   refuses it. Local compose has no `sslmode`, so it takes this path.
//! - `require` encrypts and does not verify the certificate. Supabase's pooler
//!   certificate is signed by Supabase's CA.
//! - `verify-ca` checks the CA and not the hostname. `verify-full` checks both.
//!   `DATABASE_CA_CERT` (PEM text or a file path) or `PGSSLROOTCERT` (a file
//!   path, or `system`) supplies the CA. With neither, verification uses the
//!   bundled public roots.

use std::env;
use std::fs::File;
use std::io::Read;
use std::ops::Range;
use std::sync::Arc;
use std::time::Duration;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::CryptoProvider;
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, RootCertStore, SignatureScheme};
use tokio_postgres::Client;
use tokio_postgres::tls::MakeTlsConnect;
use tokio_postgres_rustls::MakeRustlsConnect;

use crate::error::{GatewayError, GatewayResult};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SslChoice {
    Disable,
    Prefer,
    Require,
    VerifyCa,
    VerifyFull,
}

#[derive(Debug)]
struct Prepared {
    config: tokio_postgres::Config,
    mode: SslChoice,
}

pub(crate) async fn connect(url: &str) -> GatewayResult<Client> {
    let prepared = prepare(url)?;
    let mut config = prepared.config;
    config.connect_timeout(Duration::from_secs(5));
    match prepared.mode {
        SslChoice::Disable => open(&config, tokio_postgres::NoTls).await,
        mode => {
            let tls = MakeRustlsConnect::new(client_config(mode)?);
            open(&config, tls).await
        }
    }
}

async fn open<T>(config: &tokio_postgres::Config, tls: T) -> GatewayResult<Client>
where
    T: MakeTlsConnect<tokio_postgres::Socket> + Clone,
    T::Stream: Send + 'static,
{
    let mut last = connect_error();
    for attempt in 0..30 {
        match config.connect(tls.clone()).await {
            Ok((client, connection)) => {
                tokio::spawn(async move {
                    let _ = connection.await;
                });
                return Ok(client);
            }
            Err(err) => {
                last = GatewayError::database(err);
                if attempt < 29 {
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
            }
        }
    }
    Err(last)
}

fn prepare(url: &str) -> GatewayResult<Prepared> {
    let (mode, normalized) = normalize(url)?;
    let config = normalized
        .parse::<tokio_postgres::Config>()
        .map_err(|_| connect_error())?;
    Ok(Prepared { config, mode })
}

fn normalize(url: &str) -> GatewayResult<(SslChoice, String)> {
    let params = sslmode_params(url)?;
    let mode = params
        .last()
        .map(|(mode, _)| *mode)
        .unwrap_or(SslChoice::Prefer);
    let mut rewritten = url.to_string();
    for (mode, span) in params.into_iter().rev() {
        if matches!(mode, SslChoice::VerifyCa | SslChoice::VerifyFull) {
            rewritten.replace_range(span, "require");
        }
    }
    Ok((mode, rewritten))
}

fn sslmode_params(url: &str) -> GatewayResult<Vec<(SslChoice, Range<usize>)>> {
    if is_pg_url(url) {
        url_sslmodes(url)
    } else {
        keyword_sslmodes(url)
    }
}

fn is_pg_url(url: &str) -> bool {
    url.starts_with("postgres://") || url.starts_with("postgresql://")
}

fn url_sslmodes(url: &str) -> GatewayResult<Vec<(SslChoice, Range<usize>)>> {
    let Some(query_at) = query_offset(url) else {
        return Ok(Vec::new());
    };
    let query = &url[query_at..];
    let mut found = Vec::new();
    let mut offset = query_at;
    for pair in query.split('&') {
        let pair_start = offset;
        offset += pair.len() + 1;
        if pair.is_empty() {
            continue;
        }
        let Some((key, value)) = pair.split_once('=') else {
            return Err(connect_error());
        };
        if percent_decode(key) != "sslmode" {
            continue;
        }
        let value_start = pair_start + key.len() + 1;
        found.push((
            parse_mode(&percent_decode(value))?,
            value_start..value_start + value.len(),
        ));
    }
    Ok(found)
}

fn query_offset(url: &str) -> Option<usize> {
    let rest = url
        .strip_prefix("postgres://")
        .or_else(|| url.strip_prefix("postgresql://"))?;
    let base = url.len() - rest.len();
    let after_userinfo = match rest.find(['/', '?', '@']) {
        Some(index) if rest.as_bytes()[index] == b'@' => index + 1,
        _ => 0,
    };
    let tail = &rest[after_userinfo..];
    let query = tail.find('?')?;
    Some(base + after_userinfo + query + 1)
}

fn keyword_sslmodes(url: &str) -> GatewayResult<Vec<(SslChoice, Range<usize>)>> {
    let mut scan = Scan { s: url, i: 0 };
    let mut found = Vec::new();
    loop {
        scan.skip_ws();
        if scan.done() {
            break;
        }
        let key = scan.keyword();
        if key.is_empty() {
            break;
        }
        scan.skip_ws();
        scan.eat('=')?;
        scan.skip_ws();
        let (value, span) = scan.value()?;
        if key == "sslmode" {
            found.push((parse_mode(&value)?, span));
        }
    }
    Ok(found)
}

struct Scan<'a> {
    s: &'a str,
    i: usize,
}

impl<'a> Scan<'a> {
    fn done(&self) -> bool {
        self.i >= self.s.len()
    }

    fn peek(&self) -> Option<char> {
        self.s[self.i..].chars().next()
    }

    fn bump(&mut self) -> Option<char> {
        let next = self.peek()?;
        self.i += next.len_utf8();
        Some(next)
    }

    fn skip_ws(&mut self) {
        while self.peek().is_some_and(char::is_whitespace) {
            self.bump();
        }
    }

    fn keyword(&mut self) -> &'a str {
        let start = self.i;
        while let Some(next) = self.peek() {
            if next.is_whitespace() || next == '=' {
                break;
            }
            self.bump();
        }
        &self.s[start..self.i]
    }

    fn eat(&mut self, target: char) -> GatewayResult<()> {
        match self.bump() {
            Some(next) if next == target => Ok(()),
            _ => Err(connect_error()),
        }
    }

    fn value(&mut self) -> GatewayResult<(String, Range<usize>)> {
        let start = self.i;
        if self.peek() == Some('\'') {
            self.bump();
            let mut value = String::new();
            loop {
                match self.bump() {
                    Some('\\') => {
                        if let Some(escaped) = self.bump() {
                            value.push(escaped);
                        }
                    }
                    Some('\'') => return Ok((value, start..self.i)),
                    Some(next) => value.push(next),
                    None => return Err(connect_error()),
                }
            }
        }
        let mut value = String::new();
        while let Some(next) = self.peek() {
            if next.is_whitespace() {
                break;
            }
            self.bump();
            if next == '\\' {
                if let Some(escaped) = self.bump() {
                    value.push(escaped);
                }
            } else {
                value.push(next);
            }
        }
        if value.is_empty() {
            return Err(connect_error());
        }
        Ok((value, start..self.i))
    }
}

fn parse_mode(value: &str) -> GatewayResult<SslChoice> {
    match value {
        "disable" => Ok(SslChoice::Disable),
        "prefer" => Ok(SslChoice::Prefer),
        "require" => Ok(SslChoice::Require),
        "verify-ca" => Ok(SslChoice::VerifyCa),
        "verify-full" => Ok(SslChoice::VerifyFull),
        _ => Err(sslmode_error()),
    }
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            if let Some(byte) = hex_byte(bytes[index + 1], bytes[index + 2]) {
                out.push(byte);
                index += 3;
                continue;
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_byte(hi: u8, lo: u8) -> Option<u8> {
    Some((hex_val(hi)? << 4) | hex_val(lo)?)
}

fn hex_val(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn client_config(mode: SslChoice) -> GatewayResult<ClientConfig> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let builder = ClientConfig::builder_with_provider(Arc::clone(&provider))
        .with_safe_default_protocol_versions()
        .map_err(|_| connect_error())?;
    match mode {
        SslChoice::Disable => Err(connect_error()),
        SslChoice::Prefer | SslChoice::Require => Ok(builder
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(AcceptAnyCert { provider }))
            .with_no_client_auth()),
        SslChoice::VerifyCa => {
            let roots = load_roots()?;
            Ok(builder
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(VerifyCa { roots, provider }))
                .with_no_client_auth())
        }
        SslChoice::VerifyFull => {
            let roots = load_roots()?;
            Ok(builder.with_root_certificates(roots).with_no_client_auth())
        }
    }
}

fn load_roots() -> GatewayResult<RootCertStore> {
    let mut roots = RootCertStore::empty();
    match configured_ca()? {
        CaMaterial::Bundled => {
            roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
        }
        CaMaterial::Pem(pem) => {
            for cert in parse_certs(&pem)? {
                roots.add(cert).map_err(|_| ca_error())?;
            }
        }
    }
    if roots.is_empty() {
        return Err(ca_error());
    }
    Ok(roots)
}

enum CaMaterial {
    Bundled,
    Pem(String),
}

fn configured_ca() -> GatewayResult<CaMaterial> {
    let database = env_nonempty("DATABASE_CA_CERT");
    let pgssl = env_nonempty("PGSSLROOTCERT");
    match ca_source(database.as_deref(), pgssl.as_deref()) {
        CaSource::Bundled => Ok(CaMaterial::Bundled),
        CaSource::Pem(pem) => Ok(CaMaterial::Pem(pem.to_string())),
        CaSource::Path(path) => Ok(CaMaterial::Pem(read_pem_file(path)?)),
    }
}

#[derive(Debug, PartialEq, Eq)]
enum CaSource<'a> {
    Bundled,
    Pem(&'a str),
    Path(&'a str),
}

fn ca_source<'a>(database_ca: Option<&'a str>, pgsslroot: Option<&'a str>) -> CaSource<'a> {
    if let Some(value) = nonempty(database_ca) {
        if value.contains("BEGIN CERTIFICATE") {
            return CaSource::Pem(value);
        }
        return CaSource::Path(value);
    }
    if let Some(value) = nonempty(pgsslroot) {
        if value == "system" {
            return CaSource::Bundled;
        }
        return CaSource::Path(value);
    }
    CaSource::Bundled
}

fn nonempty(value: Option<&str>) -> Option<&str> {
    value.filter(|text| !text.is_empty())
}

fn env_nonempty(key: &str) -> Option<String> {
    env::var(key).ok().filter(|value| !value.is_empty())
}

fn read_pem_file(path: &str) -> GatewayResult<String> {
    let mut file = File::open(path).map_err(|_| ca_error())?;
    let mut buf = Vec::new();
    file.by_ref()
        .take(1024 * 1024 + 1)
        .read_to_end(&mut buf)
        .map_err(|_| ca_error())?;
    if buf.len() > 1024 * 1024 {
        return Err(ca_error());
    }
    String::from_utf8(buf).map_err(|_| ca_error())
}

fn parse_certs(pem: &str) -> GatewayResult<Vec<CertificateDer<'static>>> {
    let mut certs = Vec::new();
    for item in CertificateDer::pem_slice_iter(pem.as_bytes()) {
        certs.push(item.map_err(|_| ca_error())?);
    }
    if certs.is_empty() {
        return Err(ca_error());
    }
    Ok(certs)
}

#[derive(Debug)]
struct AcceptAnyCert {
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for AcceptAnyCert {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

#[derive(Debug)]
struct VerifyCa {
    roots: RootCertStore,
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for VerifyCa {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let cert = webpki::EndEntityCert::try_from(end_entity).map_err(webpki_to_rustls)?;
        cert.verify_for_usage(
            self.provider.signature_verification_algorithms.all,
            &self.roots.roots,
            intermediates,
            now,
            webpki::KeyUsage::server_auth(),
            None,
            None,
        )
        .map_err(webpki_to_rustls)?;
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

fn webpki_to_rustls(err: webpki::Error) -> rustls::Error {
    rustls::Error::InvalidCertificate(rustls::CertificateError::Other(rustls::OtherError(
        Arc::new(err),
    )))
}

fn connect_error() -> GatewayError {
    GatewayError::message("database connection failed")
}

fn sslmode_error() -> GatewayError {
    GatewayError::message("database sslmode is not usable")
}

fn ca_error() -> GatewayError {
    GatewayError::message("database CA certificate is not usable")
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio_postgres::config::{Host, SslMode};

    fn must_prepare(url: &str) -> Prepared {
        prepare(url).unwrap_or_else(|err| panic!("prepare failed: {err}"))
    }

    #[test]
    fn omitted_sslmode_prefers_tls() {
        let prepared = must_prepare("postgres://gateway_runtime@postgres:5432/fizz");
        assert_eq!(prepared.mode, SslChoice::Prefer);
        assert_eq!(prepared.config.get_ssl_mode(), SslMode::Prefer);
        assert_eq!(prepared.config.get_user(), Some("gateway_runtime"));
    }

    #[test]
    fn disable_require_and_prefer_round_trip() {
        let disable = must_prepare("postgres://gateway_runtime@postgres/fizz?sslmode=disable");
        assert_eq!(disable.mode, SslChoice::Disable);
        assert_eq!(disable.config.get_ssl_mode(), SslMode::Disable);

        let require = must_prepare(
            "postgresql://gateway_runtime.abc:secret@aws-0-us-east-1.pooler.supabase.com:5432/postgres?sslmode=require",
        );
        assert_eq!(require.mode, SslChoice::Require);
        assert_eq!(require.config.get_ssl_mode(), SslMode::Require);
        assert_eq!(require.config.get_user(), Some("gateway_runtime.abc"));
        assert_eq!(require.config.get_password(), Some(b"secret".as_slice()));
        assert_eq!(require.config.get_ports(), &[5432]);
        match &require.config.get_hosts()[0] {
            Host::Tcp(host) => assert_eq!(host, "aws-0-us-east-1.pooler.supabase.com"),
            other => panic!("expected a tcp host, got {other:?}"),
        }

        let prefer = must_prepare("host=postgres user=gateway_runtime dbname=fizz sslmode=prefer");
        assert_eq!(prefer.mode, SslChoice::Prefer);
        assert_eq!(prefer.config.get_ssl_mode(), SslMode::Prefer);
    }

    #[test]
    fn verify_modes_require_tls_and_keep_the_rest_of_the_url() {
        let url = "postgres://gateway_runtime.abc:p%40ss@aws-0-us-east-1.pooler.supabase.com:5432/postgres?application_name=fizz&sslmode=verify-full";
        let prepared = must_prepare(url);
        assert_eq!(prepared.mode, SslChoice::VerifyFull);
        assert_eq!(prepared.config.get_ssl_mode(), SslMode::Require);
        assert_eq!(prepared.config.get_password(), Some(b"p@ss".as_slice()));
        assert_eq!(prepared.config.get_application_name(), Some("fizz"));

        let ca = must_prepare(
            "host=aws-0-us-east-1.pooler.supabase.com port=5432 user=gateway_runtime.abc password=s3cret dbname=postgres sslmode=verify-ca",
        );
        assert_eq!(ca.mode, SslChoice::VerifyCa);
        assert_eq!(ca.config.get_ssl_mode(), SslMode::Require);
        assert_eq!(ca.config.get_password(), Some(b"s3cret".as_slice()));
        assert_eq!(ca.config.get_dbname(), Some("postgres"));
    }

    #[test]
    fn quoted_and_last_sslmode_win() {
        let quoted = must_prepare("sslmode='verify-full' host=localhost user=gateway_runtime");
        assert_eq!(quoted.mode, SslChoice::VerifyFull);
        assert_eq!(quoted.config.get_ssl_mode(), SslMode::Require);
        assert_eq!(quoted.config.get_hosts().len(), 1);

        let last = must_prepare("postgres://u@h/db?sslmode=verify-full&sslmode=disable");
        assert_eq!(last.mode, SslChoice::Disable);
        assert_eq!(last.config.get_ssl_mode(), SslMode::Disable);

        let spaced = must_prepare("host=localhost sslmode = require user=gateway_runtime");
        assert_eq!(spaced.mode, SslChoice::Require);
        assert_eq!(spaced.config.get_ssl_mode(), SslMode::Require);
    }

    #[test]
    fn password_text_is_not_an_sslmode() {
        let prepared = must_prepare(
            "host=localhost user=gateway_runtime password=sslmode=verify-full dbname=fizz sslmode=disable",
        );
        assert_eq!(prepared.mode, SslChoice::Disable);
        assert_eq!(
            prepared.config.get_password(),
            Some(b"sslmode=verify-full".as_slice())
        );
    }

    #[test]
    fn unknown_sslmode_is_rejected_without_the_url() {
        let err = prepare("postgres://user:supersecret@db.example/postgres?sslmode=allow")
            .expect_err("allow is not a mode we implement");
        let text = err.to_string();
        assert!(text.contains("sslmode"));
        assert!(!text.contains("supersecret"));
        assert!(!text.contains("db.example"));

        let broken = prepare("postgres://user:supersecret@db.example/postgres?sslmode=REQUIRE")
            .expect_err("sslmode is case sensitive");
        assert!(!broken.to_string().contains("supersecret"));
    }

    #[test]
    fn ca_source_prefers_database_ca_cert() {
        assert_eq!(ca_source(None, None), CaSource::Bundled);
        assert_eq!(ca_source(Some(""), Some("")), CaSource::Bundled);
        assert_eq!(
            ca_source(
                Some("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"),
                None
            ),
            CaSource::Pem("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n")
        );
        assert_eq!(
            ca_source(Some("/certs/supabase.pem"), Some("/other.pem")),
            CaSource::Path("/certs/supabase.pem")
        );
        assert_eq!(ca_source(None, Some("system")), CaSource::Bundled);
        assert_eq!(
            ca_source(None, Some("/etc/ssl/supabase-ca.pem")),
            CaSource::Path("/etc/ssl/supabase-ca.pem")
        );
    }

    /// Runs when `FIZZ_TEST_PLAIN_DATABASE_URL` is a `postgres://` URL with no
    /// query, aimed at a Postgres that does not speak TLS.
    #[tokio::test]
    async fn prefer_and_disable_reach_plaintext_postgres() {
        let Ok(url) = env::var("FIZZ_TEST_PLAIN_DATABASE_URL") else {
            return;
        };
        if url.contains("sslmode") || url.contains('?') {
            panic!("FIZZ_TEST_PLAIN_DATABASE_URL must be a postgres URL with no query");
        }
        let client = connect(&url).await.expect("prefer falls back to plaintext");
        let row = client.query_one("select 1", &[]).await.expect("select");
        let one: i32 = row.get(0);
        assert_eq!(one, 1);
        let disabled = connect(&format!("{url}?sslmode=disable"))
            .await
            .expect("disable stays on plaintext");
        let row = disabled.query_one("select 1", &[]).await.expect("select");
        let one: i32 = row.get(0);
        assert_eq!(one, 1);
    }

    /// Runs when `FIZZ_TEST_TLS_DATABASE_URL` is a `postgres://` URL with no
    /// query, aimed at a Postgres that presents a certificate.
    #[tokio::test]
    async fn require_reaches_a_tls_postgres() {
        let Ok(url) = env::var("FIZZ_TEST_TLS_DATABASE_URL") else {
            return;
        };
        if url.contains("sslmode") || url.contains('?') {
            panic!("FIZZ_TEST_TLS_DATABASE_URL must be a postgres URL with no query");
        }
        let client = connect(&format!("{url}?sslmode=require"))
            .await
            .expect("require");
        let row = client.query_one("select 1", &[]).await.expect("select");
        let one: i32 = row.get(0);
        assert_eq!(one, 1);
    }

    #[tokio::test]
    async fn verify_modes_honor_database_ca_cert() {
        let Ok(url) = env::var("FIZZ_TEST_VERIFY_DATABASE_URL") else {
            return;
        };
        let client = connect(&url).await.expect("verify");
        let row = client.query_one("select 1", &[]).await.expect("select");
        let one: i32 = row.get(0);
        assert_eq!(one, 1);
    }
}
