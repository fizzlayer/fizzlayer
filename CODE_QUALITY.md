# Code quality

Rules for review and for the checks in CI. Formatting is whatever stable `rustfmt` does. Where this document is silent, match the surrounding module.

## Sources

These are the documents this repo follows. They are not copied here.

- [Google's engineering practices](https://google.github.io/eng-practices/): the [standard of code review](https://google.github.io/eng-practices/review/reviewer/standard.html) (a change should improve code health, not chase a perfect rewrite), [what to look for](https://google.github.io/eng-practices/review/reviewer/looking-for.html) (design, behavior, complexity, tests, names, comments, consistency), and [small changes](https://google.github.io/eng-practices/review/developer/small-cls.html). Style nits that are not in this file or in `rustfmt` do not block a review. Do not mix a repo-wide reformat with a behavior change.
- [Rust API Guidelines](https://rust-lang.github.io/api-guidelines/checklist.html), the items named below. The `fizz` crate is an application library with binary entry points, not a crates.io API, so crate-level rustdoc and `missing_docs` are not required yet.
- [The Rust style guide](https://doc.rust-lang.org/style-guide/), as implemented by stable `rustfmt`. `rustfmt.toml` records the stable options CI relies on. Nightly-only rustfmt options are not used.
- [Clippy's lint groups](https://doc.rust-lang.org/clippy/lints.html). `clippy::all` is on (correctness, suspicious, style, complexity, perf). A curated set of pedantic lints is on. `restriction` and `nursery` are not enabled as groups. Clippy says not to enable `restriction` wholesale, and `nursery` lints are unfinished.
- [Gleam's conventions, patterns, and anti-patterns](https://gleam.run/documentation/conventions-patterns-and-anti-patterns/). There is no Gleam in this repository. A future Gleam package follows that guide: `gleam format`, `gleam check` with warnings fixed, `Result` for fallible functions, no panics in library code, qualified imports for functions, and modules split by domain rather than by pattern (`controller` / `service` / `types`).

## Layout

Three Rust packages, each with its own `Cargo.lock`. They are not a Cargo workspace. The API image, the CLI release, and the worker image build separately, and the worker's Docker context is `supabase/compute/fizz-worker`.

| Package | Path | Role |
| --- | --- | --- |
| `fizz` | repository root | Library in `src/`. Vercel function binaries in `api/`. Self-host server `src/bin/fizz-serve.rs`. |
| `fizz-cli` | `cli/` | Device binary `fizz`. Release builds use `panic = "abort"`. That setting is for this binary only. |
| `fizz-worker` | `supabase/compute/fizz-worker/` | WebSocket and MQTT worker. |

`supabase/compute/fizz-worker/src/protocol.rs` is compiled into all three packages (`src/live.rs` and `cli/src/transport.rs` pull it in with `#[path]`). A change to that file has to pass Clippy for every package. Each crate uses a subset of the file, so the CLI and the worker allow `dead_code` on that module only. Dead code in `main.rs` is still reported. Splitting this into a real shared crate is follow-up work, not something to paper over with another copy of the file.

Other code: browser JavaScript in `public/` (checked with `node --check` in the security workflow), the Home Assistant integration in `custom_components/fizzlayer/`, shell under `scripts/`, `deploy/`, and `public/install.sh`, and SQL in `supabase/migrations/`. Applied migrations are checksummed by Supabase. Do not reformat a migration that has already shipped.

## Module boundaries

- `api/*.rs` and `src/bin/fizz-serve.rs` are process entry points. They check the request or the arguments and call into `src/`. Business rules do not go in the entry point.
- Browser-facing handlers call `security::guard_request` before doing work. Bearer-token device routes are the exception that guard already allows.
- `store::Supabase` is the only PostgREST client. The service-role key stays in the server process.
- New modules follow a domain (`billing`, `sensors`, `voice`), not a pattern (`utils`, `helpers`, `types`). Google's complexity rule and Gleam's "don't group by design pattern" rule are the same idea: don't add an abstraction until a second caller needs it.
- Public items exist so the binaries can use the library. Helpers that no binary and no other module needs should be private. A pass to tighten `pub` to `pub(crate)` is follow-up; don't widen visibility in the meantime.

## Errors, panics, and `unsafe`

- Fallible functions return `Result`. Library code does not panic, including via `unwrap`, `expect`, `panic!`, or `todo!`.
- HTTP responses use `customer::error(status, code, message)` (or the MCP JSON-RPC helpers) with a stable machine-readable `code`. Don't invent a second error JSON shape.
- Process boundaries may exit: `fizz-serve` prints the error and exits, the CLI returns `ExitCode`, and the worker may `expect` when it cannot bind its listen socket. That is the edge, not a pattern to copy into `src/`.
- Tests may use `unwrap` on fixtures.
- New error types implement `Debug`, `Display`, and `std::error::Error`, with variants that say what failed in domain terms (API guideline C-GOOD-ERR). `ConnectionError` and `StoreError` predate that and do not implement `Error`. `selfhost::init` and much of the CLI still use `Result<_, String>`. Don't add more stringly errors; fixing the existing ones is follow-up.
- Handlers today return `Result<T, Response<ResponseBody>>`. `Response` is larger than Clippy's `result_large_err` threshold, so that lint is allowed on the `fizz` package only, with the reason in `Cargo.toml`. New code should use a small error and map it to a response at the boundary.
- `unsafe` is for the CLI's `libc` calls and for tests that set environment variables. Every `unsafe` block needs a `SAFETY` comment that states the invariant, not only the purpose of the call. `clippy::undocumented_unsafe_blocks` is not denied yet.

## Names, types, and comments

- Casing follows Rust RFC 430. Conversions use `as_`, `to_`, and `into_` (C-CONV). Getters are not named `get_`.
- Prefer a newtype or an enum over a `bool` or a stringly mode when more than one caller has to remember what the value means (C-NEWTYPE). Validate at the constructor (C-VALIDATE).
- Types that are public to the binaries implement `Debug` (C-DEBUG).
- Comments say why. Don't restate the code. Don't leave a comment that disagrees with the code.
- A behavior change ships with a test in the same pull request. Tests live next to the code in `#[cfg(test)]` modules. A test that cannot fail does not count.

## What CI runs

The lint workflow (`.github/workflows/lint.yml`) fails the pull request. Run the same commands locally:

```sh
cargo fmt --all -- --check
cargo fmt --manifest-path cli/Cargo.toml -- --check
cargo fmt --manifest-path supabase/compute/fizz-worker/Cargo.toml -- --check

cargo clippy --locked --all-targets -- -D warnings
cargo clippy --locked --all-targets --manifest-path cli/Cargo.toml -- -D warnings
cargo clippy --locked --all-targets --manifest-path supabase/compute/fizz-worker/Cargo.toml -- -D warnings

cargo deny --manifest-path Cargo.toml check
cargo deny --manifest-path cli/Cargo.toml check
cargo deny --manifest-path supabase/compute/fizz-worker/Cargo.toml check

shellcheck scripts/*.sh deploy/*.sh public/install.sh
```

Lint levels in the three `Cargo.toml` files are `warn`. CI passes `-D warnings`, so a warning fails the build. Keep the three `[lints]` tables in sync, except `clippy::result_large_err`, which is allowed only on `fizz`.

`cargo test` and `cargo audit` stay in the security workflow. `cargo deny` checks advisories, licenses, bans, and sources on every pull request (`deny.toml`). Duplicate crate versions warn and do not fail the build. Version requirements must not be `*`. Dependencies come from crates.io only.

Rust 1.94.0 is the minimum supported compiler. It matches `deploy/Dockerfile.api`, `supabase/compute/fizz-worker/Dockerfile`, and `rust-toolchain.toml`. Vercel builds with a compiler that rejects standard-library APIs newer than that, such as `Option::map_or_default`. CI installs 1.94.0 for formatting, Clippy, and tests, and each package sets `rust-version` to 1.94. Do not use syntax or library items that 1.94.0 cannot build.

### Pedantic lints that are on

`map_unwrap_or`, `manual_let_else`, `unreadable_literal`, `explicit_iter_loop`, `explicit_into_iter_loop`, `redundant_closure_for_method_calls`, `unnested_or_patterns`, `uninlined_format_args`, `ignored_unit_patterns`, `format_collect`, `cloned_instead_of_copied`, `flat_map_option`, `implicit_clone`, `inefficient_to_string`, `manual_assert`, `manual_string_new`, `semicolon_if_nothing_returned`, `trivially_copy_pass_by_ref`, `match_same_arms`, `single_match_else`.

`clippy::option_if_let_else` is not enabled. The suggested `map_or_else` rewrite is worse than an `if let` / `else` that returns an HTTP response, and Clippy does not apply most of those edits itself. `clippy::from_iter_instead_of_collect` was removed upstream and must not be turned back on.

### Intentionally not failing the build yet

Turn these on in a follow-up once the code matches them. Allowing them globally would hide new mistakes; leaving them off means review has to catch new cases.

- `clippy::unwrap_used` and `clippy::expect_used`. Existing library `expect`s are mostly `Response::builder().body()` on static headers, plus a few `as_str().unwrap()` calls after a type check. Tests use `unwrap` freely.
- `clippy::too_many_lines`, `missing_errors_doc`, `missing_panics_doc`, `doc_markdown`, and `must_use_candidate`. These need a documentation and decomposition pass, not a mechanical edit.
- `clippy::cast_possible_truncation` and `clippy::needless_pass_by_value`. The casts are range-checked or POSIX field widths; the signature changes need a caller review.
- `clippy::unused_async` on `serve::static_file`, which is async only so the server can `.await` it.
- Rustc `missing_docs` and `unreachable_pub`.

## Other languages

- Shell: `shellcheck` on the scripts listed above. `public/install.sh` is POSIX `sh`.
- JavaScript: `node --check` in the security workflow. There is no package manifest and no ESLint yet.
- Python: Home Assistant's hassfest workflow covers the integration. Ruff is not in CI. The M5Stick firmware is MicroPython; don't apply CPython pyupgrade rules to it.
- SQL: no SQL linter. Do not rewrite applied migrations to satisfy one.
