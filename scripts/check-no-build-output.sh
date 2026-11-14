#!/usr/bin/env bash
# Fail when Git is tracking compiler output or a build tree.
#
# Checks every path from `git ls-files` (the index, including staged files).
# Run from anywhere: bash scripts/check-no-build-output.sh
#
# Path components (the filename itself does not count, so build.rs is source):
#   target/  build/  dist/  _build/  node_modules/  .lustre/  .local-bin/
#   __pycache__/
# Prefixes:
#   public/app/   (the Gleam bundle; public/app.js is a different file)
#   gateway/target/
# Extensions:
#   .wasm .o .so .so.* .a .dylib .dll .exe .beam .pyc .pyo .class .jar .min.js .map
# Magic (first bytes of the blob):
#   ELF 7f 45 4c 46
#   Mach-O fe ed fa ce / fe ed fa cf, both endians, plus fat ca fe ba be / ca fe ba bf
#   PE 4d 5a ("MZ")
# Java class files use the same ca fe ba be header as a Mach-O fat binary. Both are
# compiled, so that header fails the check.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'check-no-build-output: not a git checkout\n' >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf 'check-no-build-output: python3 is required to read binary headers\n' >&2
  exit 1
fi

# ALLOWLIST
# Exact repo-relative paths. One path per line. Blank lines and lines starting
# with # are ignored. Add a path only when it is intentional, and say why on
# the comment line above it. An allowlisted path skips both the name rules and
# the magic-byte check.
ALLOWLIST="$(
  cat <<'EOF'
# Nothing is allowlisted.
# public/fizz-demo.mp4 and public/og.png are media assets. They are not listed
# here: they do not match a build path, a compiled extension, or an ELF,
# Mach-O, or PE header.
EOF
)"

allowed() {
  local path="$1" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      '' | \#*) continue ;;
    esac
    if [[ "$line" == "$path" ]]; then
      return 0
    fi
  done <<< "$ALLOWLIST"
  return 1
}

# Prints why the path is build output, or returns 1 when it is clean.
build_path_reason() {
  local path="$1"
  local base="${path##*/}"
  local -a parts=()
  local i n part

  case "$path" in
    public/app/*)
      printf 'path matches public/app/'
      return 0
      ;;
    gateway/target/*)
      printf 'path matches gateway/target/'
      return 0
      ;;
  esac

  IFS=/ read -r -a parts <<< "$path"
  n=${#parts[@]}
  if ((n > 1)); then
    for ((i = 0; i < n - 1; i++)); do
      part="${parts[$i]}"
      case "$part" in
        target | build | dist | _build | node_modules | .lustre | .local-bin | __pycache__)
          printf 'path is inside %s/' "$part"
          return 0
          ;;
      esac
    done
  fi

  case "$base" in
    *.min.js) printf 'extension .min.js' ;;
    *.wasm) printf 'extension .wasm' ;;
    *.so | *.so.*) printf 'extension .so' ;;
    *.o) printf 'extension .o' ;;
    *.a) printf 'extension .a' ;;
    *.dylib) printf 'extension .dylib' ;;
    *.dll) printf 'extension .dll' ;;
    *.exe) printf 'extension .exe' ;;
    *.beam) printf 'extension .beam' ;;
    *.pyc) printf 'extension .pyc' ;;
    *.pyo) printf 'extension .pyo' ;;
    *.class) printf 'extension .class' ;;
    *.jar) printf 'extension .jar' ;;
    *.map) printf 'extension .map' ;;
    *) return 1 ;;
  esac
  return 0
}

index_list="$(mktemp)"
magic_input="$(mktemp)"
trap 'rm -f "$index_list" "$magic_input"' EXIT

# A failing `git ls-files` must not look like an empty, clean tree.
git ls-files -s -z > "$index_list"

failed=0
count=0

while IFS= read -r -d '' record; do
  mode="${record%% *}"
  rest="${record#* }"
  sha="${rest%% *}"
  path="${rest#*$'\t'}"
  count=$((count + 1))

  if [[ ! "$sha" =~ ^[0-9a-f]{40,64}$ ]]; then
    printf 'check-no-build-output: could not parse index record\n' >&2
    failed=1
    continue
  fi

  if allowed "$path"; then
    continue
  fi

  if reason="$(build_path_reason "$path")"; then
    printf 'tracked build output: %s (%s)\n' "$path" "$reason" >&2
    failed=1
    continue
  fi

  # 120000 is a symlink (the blob is the target text). 160000 is a gitlink.
  case "$mode" in
    100644 | 100755)
      printf '%s\t%s\0' "$sha" "$path" >> "$magic_input"
      ;;
  esac
done < "$index_list"

if [[ -s "$magic_input" ]]; then
  if ! python3 - "$magic_input" <<'PY'
import subprocess
import sys

def read_exact(stream, size):
    buf = bytearray()
    while len(buf) < size:
        chunk = stream.read(size - len(buf))
        if not chunk:
            sys.stderr.write("check-no-build-output: short read from git cat-file\n")
            sys.exit(1)
        buf.extend(chunk)
    return bytes(buf)

def discard(stream, size):
    left = size
    while left:
        chunk = stream.read(min(left, 1024 * 1024))
        if not chunk:
            sys.stderr.write("check-no-build-output: short read from git cat-file\n")
            sys.exit(1)
        left -= len(chunk)

def show(path):
    return path.decode("utf-8", "surrogateescape")

raw = open(sys.argv[1], "rb").read().split(b"\0")
records = []
for rec in raw:
    if not rec:
        continue
    if b"\t" not in rec:
        sys.stderr.write("check-no-build-output: bad magic-check record\n")
        sys.exit(1)
    sha, path = rec.split(b"\t", 1)
    records.append((sha, path))

# Longer headers are listed before any header that could be a prefix of them.
MAGICS = (
    (b"\x7fELF", "ELF"),
    (b"\xfe\xed\xfa\xcf", "Mach-O"),
    (b"\xfe\xed\xfa\xce", "Mach-O"),
    (b"\xcf\xfa\xed\xfe", "Mach-O"),
    (b"\xce\xfa\xed\xfe", "Mach-O"),
    (b"\xca\xfe\xba\xbe", "Mach-O fat or Java class"),
    (b"\xbe\xba\xfe\xca", "Mach-O"),
    (b"\xca\xfe\xba\xbf", "Mach-O"),
    (b"\xbf\xba\xfe\xca", "Mach-O"),
    (b"MZ", "PE"),
)

proc = subprocess.Popen(
    ["git", "cat-file", "--batch"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
)
failed = False
assert proc.stdin is not None and proc.stdout is not None
for sha, path in records:
    proc.stdin.write(sha + b"\n")
    proc.stdin.flush()
    header = proc.stdout.readline()
    if not header or header.endswith(b" missing\n"):
        sys.stderr.write("check-no-build-output: missing blob for %s\n" % show(path))
        failed = True
        continue
    try:
        size = int(header.split()[2])
    except (IndexError, ValueError):
        sys.stderr.write("check-no-build-output: bad cat-file header\n")
        sys.exit(1)
    take = 4 if size >= 4 else size
    blob = read_exact(proc.stdout, take) if take else b""
    discard(proc.stdout, size - take)
    if proc.stdout.read(1) != b"\n":
        sys.stderr.write("check-no-build-output: bad cat-file trailer\n")
        sys.exit(1)
    kind = next((name for magic, name in MAGICS if blob.startswith(magic)), None)
    if kind:
        sys.stderr.write("tracked build output: %s (%s binary)\n" % (show(path), kind))
        failed = True
proc.stdin.close()
rc = proc.wait()
if rc != 0:
    sys.stderr.write("check-no-build-output: git cat-file exited %s\n" % rc)
    sys.exit(1)
sys.exit(1 if failed else 0)
PY
  then
    failed=1
  fi
fi

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

printf 'check-no-build-output: ok (%s tracked files)\n' "$count"
