# Fizzlayer CLI

Connect a Raspberry Pi or Linux device to Fizzlayer, stream system health, and publish custom sensor readings. The executable is named `fizz`.

## Install

On a supported Linux device:

```sh
curl -fsSL https://fizzlayer.com/install.sh -o /tmp/fizz-install.sh
sh /tmp/fizz-install.sh
fizz --version
```

The installer supports x86_64, ARM64, ARMv7, and ARMv6 Linux. It downloads a binary from [GitHub Releases](https://github.com/nisargap/Fizz/releases), verifies it against the release's `SHA256SUMS`, and installs to `/usr/local/bin` when writable or `~/.local/bin` otherwise. It requires `curl` and either `sha256sum` or `shasum`. If necessary, add the install directory to your shell's `PATH`.

To pin a published release or choose the destination:

```sh
FIZZ_VERSION=cli-v0.1.1 FIZZ_INSTALL_DIR="$HOME/.local/bin" sh /tmp/fizz-install.sh
```

Rerun the installer to update the binary. Stop and restart any running Fizz service when updating; your pairing configuration is retained.

## Pair a device

Create or sign in to your Fizzlayer account, then run:

```sh
fizz pair --name "Workshop Pi"
```

1. Enter the displayed code on the **Agents** page, or ask a connected agent to claim it with the `pair_device` MCP tool.
2. Return to the device terminal and check the account and requesting agent.
3. Approve the request to create a Custom sensor and save its device key.
4. Send a sample and view it on the dashboard:

```sh
fizz run --once
fizz status
```

Codes expire after 15 minutes and can be claimed once. Pairing requires approval in the device terminal. `fizz status` displays the local pairing details without contacting the server or printing the key.

## Commands

| Command | Behavior |
| --- | --- |
| `fizz pair [--name NAME]` | Start an interactive pairing; defaults to the device hostname. |
| `fizz run` | Publish available system metrics every 60 seconds until interrupted. |
| `fizz run --every 30` | Change the interval; the minimum is 15 seconds. |
| `fizz run --once` | Attempt one sample, then exit. |
| `fizz send METRIC VALUE […]` | Publish up to 16 custom metrics in one reading. |
| `fizz status` | Show device name, account, sensor ID, API origin, and config path. |
| `fizz unpair` | Revoke the device key and remove the local configuration. |
| `fizz service` | Print a systemd unit; does not install or start it. |
| `fizz help` / `fizz --version` | Show usage or version. |

`fizz run` publishes `cpu_temperature_c`, `load_1m`, `memory_used_pct`, and `disk_used_pct` when the corresponding Linux sources exist. Missing metrics are skipped. Disk usage covers the root filesystem. Failed samples are logged and the next interval sends a new sample; there is no offline queue. Inspect the output for `sent`: `--once` can exit successfully after logging a network or server failure.

Send your own readings:

```sh
fizz send temperature_c 22.4 humidity_pct 48
fizz send door_open true location "Workshop"
```

Metric names must start with a lowercase letter, contain only lowercase letters, digits, and underscores, and be at most 40 characters long. Values accept numbers, lowercase `true` or `false`, or text up to 512 characters. Readings use `/api/ingest` and appear in the same dashboard, alerts, chat, and MCP tools as other sensor data.

To move a device to another account, run `fizz unpair` first, then pair again. `fizz pair --force` replaces the saved pairing after approval but does **not** revoke the previous device key; revoke the previous device separately if you use it.

## Use your own Fizzlayer deployment

Set `FIZZ_API` to your deployment's origin when pairing:

```sh
FIZZ_API=https://fizz.example.com fizz pair --name "Workshop Pi"
fizz run --once
```

The origin is saved with the pairing, so later commands use it automatically. An explicit `FIZZ_API` overrides the saved origin for that command. Pair separately with each deployment; a device key belongs to the deployment that issued it.

Use an HTTPS origin without a path, query, fragment, or user credentials. Plain HTTP is accepted only for loopback development, for example `FIZZ_API=http://localhost:3000`. The CLI does not follow redirects, so use the deployment's final canonical origin.

The installer download source is independent of `FIZZ_API`: it still fetches official GitHub release binaries. Operators distributing their own builds must update `REPO` in `public/install.sh` to their release repository.

## Configuration

| Variable | Purpose |
| --- | --- |
| `FIZZ_API` | Override the API origin; unpaired devices default to `https://fizzlayer.com`. |
| `FIZZ_CONFIG` | Use a specific configuration file. |
| `XDG_CONFIG_HOME` | Base config directory when `FIZZ_CONFIG` is unset. |
| `FIZZ_VERSION` | Installer only: published release tag, or `latest` (default). |
| `FIZZ_INSTALL_DIR` | Installer only: binary destination directory. |

The default configuration is `$XDG_CONFIG_HOME/fizz/device.json`, or `~/.config/fizz/device.json` when `XDG_CONFIG_HOME` is unset. It contains the sensor ID, device key, API origin, and pairing metadata. The CLI writes it with mode `600` and rejects symlinks or files owned by another user or accessible to other users. Keep it private and run commands as the same user who paired the device.

## Run after reboot with systemd

After pairing, generate the service as the device user so it captures the correct binary, user, and config paths:

```sh
fizz service > /tmp/fizz.service
cat /tmp/fizz.service
sudo install -m 644 /tmp/fizz.service /etc/systemd/system/fizz.service
sudo systemctl daemon-reload
sudo systemctl enable --now fizz
systemctl status fizz
journalctl -u fizz -f
```

The generated unit runs `fizz run --every 60` as the current `$USER`, uses the saved configuration, and restarts after failures. Check the generated paths before installing, especially when a path contains spaces. If you need a different interval, edit `ExecStart` before installing. The unit uses the origin stored at pairing; it does not copy a shell's `FIZZ_API` override.

To stop publishing and disconnect the device:

```sh
sudo systemctl disable --now fizz
fizz unpair
```

## Build from source

Install a current stable Rust toolchain and a native C linker, then run from the repository root:

```sh
cargo test --locked --manifest-path cli/Cargo.toml
cargo build --release --locked --manifest-path cli/Cargo.toml
./cli/target/release/fizz --version
cargo install --locked --path cli
```

The CLI is a separate Cargo package from the API. `cargo install` places `fizz` in Cargo's binary directory, normally `~/.cargo/bin`.

Maintainers publish releases with a `cli-v<VERSION>` tag matching `cli/Cargo.toml`. The [CLI release workflow](../.github/workflows/cli-release.yml) tests the CLI, cross-compiles four Linux musl targets, and publishes binaries plus `SHA256SUMS`. Release assets must be publicly downloadable for the installer to work.

ESP32 and other microcontrollers cannot run this Linux CLI. Create an API sensor in Fizzlayer and send readings directly to `/api/ingest` instead.
