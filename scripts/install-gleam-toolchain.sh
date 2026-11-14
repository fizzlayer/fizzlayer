#!/usr/bin/env bash
# Gleam 1.19.2, OTP 27.3.4, OpenSSL 1.1 (for that OTP build), and rebar3 3.28.0.
# OTP is the Hex Bob ubuntu-20.04 build so it runs on glibc 2.31+, including
# Ubuntu 24.04 and Amazon Linux 2023. Crypto is linked to OpenSSL 1.1, which
# those images do not ship, so the matching libssl1.1 is unpacked beside it.
# Existing gleam, erl, and rebar3 on PATH are left alone.
set -euo pipefail

prefix="${FIZZ_TOOLCHAIN:-/tmp/fizz-gleam-toolchain}"
mkdir -p "$prefix/bin" "$prefix/lib"
installed_otp=0

sha256() {
  # sha256sum on GNU, shasum on some minimal images.
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

fetch() {
  local url="$1" dest="$2" want="$3"
  curl -fsSL "$url" -o "$dest"
  local got
  got="$(sha256 "$dest")"
  if [[ "$got" != "$want" ]]; then
    printf 'error: checksum mismatch for %s\n' "$url" >&2
    exit 1
  fi
}

if ! command -v gleam >/dev/null 2>&1; then
  case "$(uname -m)" in
    x86_64) ;;
    *) printf 'error: Gleam toolchain install supports x86_64 only (found %s)\n' "$(uname -m)" >&2; exit 1 ;;
  esac
  tmp="$(mktemp)"
  fetch \
    "https://github.com/gleam-lang/gleam/releases/download/v1.19.2/gleam-v1.19.2-x86_64-unknown-linux-musl.tar.gz" \
    "$tmp" \
    "2ba2afb66ca9f6dcc01a4a6e9169b6942963bad6483bec9571ddc078cfe6f41f"
  tar -xzf "$tmp" -C "$prefix/bin"
  rm -f "$tmp"
  chmod +x "$prefix/bin/gleam"
fi

if ! command -v rebar3 >/dev/null 2>&1; then
  fetch \
    "https://github.com/erlang/rebar3/releases/download/3.28.0/rebar3" \
    "$prefix/bin/rebar3" \
    "5a28b1cca082d3b023ec0f5df9d9f9d52557036c6f2a21c1ffa11b93a984dd42"
  chmod +x "$prefix/bin/rebar3"
fi

if ! command -v erl >/dev/null 2>&1; then
  case "$(uname -m)" in
    x86_64) ;;
    *) printf 'error: OTP toolchain install supports x86_64 only (found %s)\n' "$(uname -m)" >&2; exit 1 ;;
  esac
  tmp="$(mktemp)"
  fetch \
    "https://repo.hex.pm/builds/otp/ubuntu-20.04/OTP-27.3.4.tar.gz" \
    "$tmp" \
    "8c00495b2678854a77e62a977082720d66d9f3a1208ab76d5fddf1165ad2774a"
  mkdir -p "$prefix/otp"
  tar -xzf "$tmp" -C "$prefix/otp"
  rm -f "$tmp"
  "$prefix/otp/OTP-27.3.4/Install" -minimal "$prefix/otp/OTP-27.3.4" >/dev/null

  deb="$(mktemp)"
  fetch \
    "https://archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2.24_amd64.deb" \
    "$deb" \
    "7cf39d70a639017d1dd7c8d36daa2258063608688e449fddf40ffdd46f992a78"
  python3 - "$deb" "$prefix/lib" <<'PY'
import sys, tarfile
deb, dest = sys.argv[1], sys.argv[2]
data = open(deb, "rb").read()
if not data.startswith(b"!<arch>\n"):
    sys.stderr.write("error: libssl package is not an ar archive\n")
    sys.exit(1)
i = 8
blob = None
while i + 60 <= len(data):
    header = data[i:i + 60]
    name = header[:16].decode().strip()
    size = int(header[48:58].decode().strip())
    i += 60
    file_bytes = data[i:i + size]
    i += size + (size % 2)
    if name.startswith("data.tar"):
        blob = file_bytes
        break
if blob is None:
    sys.stderr.write("error: libssl package has no data archive\n")
    sys.exit(1)
import io
with tarfile.open(fileobj=io.BytesIO(blob), mode="r:xz") as archive:
    for member in archive.getmembers():
        base = member.name.rsplit("/", 1)[-1]
        if base in ("libcrypto.so.1.1", "libssl.so.1.1"):
            extracted = archive.extractfile(member)
            if extracted is None:
                sys.exit(1)
            with open(f"{dest}/{base}", "wb") as handle:
                handle.write(extracted.read())
PY
  rm -f "$deb"
  installed_otp=1
fi

{
  # ${PATH} is text for the generated env file. It must not expand here.
  # shellcheck disable=SC2016
  printf 'export PATH="%s/bin:${PATH}"\n' "$prefix"
  if [[ "$installed_otp" -eq 1 ]]; then
    # shellcheck disable=SC2016
    printf 'export PATH="%s/otp/OTP-27.3.4/bin:${PATH}"\n' "$prefix"
    # shellcheck disable=SC2016
    printf 'export LD_LIBRARY_PATH="%s/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n' "$prefix"
  fi
} > "$prefix/env.sh"
