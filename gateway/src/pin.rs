//! Compile-time copy of `pins/agentgateway.toml`.

const PIN: &str = include_str!("../pins/agentgateway.toml");

fn quoted(key: &str) -> &'static str {
    for line in PIN.lines() {
        let line = line.trim();
        let Some(rest) = line.strip_prefix(key) else {
            continue;
        };
        let rest = rest.trim();
        let Some(rest) = rest.strip_prefix('=') else {
            continue;
        };
        let rest = rest.trim();
        if let Some(value) = rest.strip_prefix('"').and_then(|v| v.strip_suffix('"')) {
            return value;
        }
    }
    panic!("pin file is missing {key}");
}

pub fn version() -> &'static str {
    quoted("version")
}

pub fn git_commit() -> &'static str {
    quoted("git_commit")
}

pub fn image() -> &'static str {
    quoted("image")
}

pub fn digest() -> &'static str {
    quoted("digest")
}

pub fn proto_sha256() -> &'static str {
    quoted("proto_sha256")
}

pub fn linux_amd64_sha256() -> &'static str {
    quoted("linux_amd64_sha256")
}

/// Image reference pinned by digest. Compose and the generated config header use this.
pub fn image_ref() -> String {
    format!("{}@{}", image(), digest())
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};

    #[test]
    fn proto_copy_matches_the_pinned_release() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("proto/ext_mcp.proto");
        let bytes = std::fs::read(&path).expect("proto");
        let got = hex::encode(Sha256::digest(&bytes));
        assert_eq!(got, proto_sha256());
        assert!(bytes.starts_with(b"syntax = \"proto3\";"));
        assert!(!bytes.windows(12).any(|w| w == b"Modified by"));
    }

    #[test]
    fn compose_uses_the_pinned_digest() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("compose/compose.yaml");
        let text = std::fs::read_to_string(&path).expect("compose");
        let reference = image_ref();
        assert!(
            text.contains(&reference),
            "compose.yaml must pin {reference}"
        );
        assert!(!text.contains("agentgateway:latest"));
        assert!(!text.contains(":v1.7.0"));
    }

    #[test]
    fn pin_identifies_the_v1_7_0_commit() {
        assert_eq!(version(), "1.7.0");
        assert_eq!(git_commit(), "26f5aebe99a36a037fe54f8080a608aca5547e15");
        assert!(digest().starts_with("sha256:"));
        assert_eq!(linux_amd64_sha256().len(), 64);
    }
}
