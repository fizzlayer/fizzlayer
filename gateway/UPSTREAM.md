# Upstream agentgateway pin

Fizzlayer runs [agentgateway](https://github.com/agentgateway/agentgateway) as the gateway data plane. The image is upstream's release build. We do not fork the repository and we do not rebuild their binary into a Fizzlayer-branded image.

The pin lives in [`pins/agentgateway.toml`](pins/agentgateway.toml). `gateway/compose/compose.yaml` must reference `image@digest` from that file. A unit test fails if the two drift.

| | Pinned value |
|---|---|
| Release | v1.7.0 (27 Oct 2026) |
| Git commit | `26f5aebe99a36a037fe54f8080a608aca5547e15` |
| Image | `cr.agentgateway.dev/agentgateway@sha256:60216aafb03d37f94e952ff3d51d2f630a65b10ecaebdc0a864882f92610c45b` |

That digest is the multi-arch OCI index (linux/amd64 and linux/arm64). Do not pin a floating tag such as `:v1.7.0` or `:latest`.

`gateway/proto/ext_mcp.proto` is a byte-for-byte copy of `crates/protos/proto/ext_mcp.proto` at that commit. SHA-256 `4ba750cca44e9ba68de2ad04e6d507b67f44b1728f09840b78d9e32f3f563584`. It is not a Fizzlayer edit. fizz-guard implements that service; it does not vendor the rest of the proxy.

## What we add

agentgateway terminates MCP, checks the Fizzlayer JWT (`jwtAuth`), and calls fizz-guard on `tools/call` (`mcpGuardrails` / ExtMcp). fizz-config writes the YAML file atomically. agentgateway's file watch reloads it. Session IDs are left unencrypted in local compose (`config.session.key: disabled` and `SESSION_KEY=disabled`) so the process does not write a generated key into the config file. Set a real session key outside the file before a shared or hosted deploy.

## Upgrade

1. Read the upstream release notes, especially breaking config changes. v1.7.0 already changed session encryption, prompt-guard scope, and dynamic-backend address checks.
2. Check the new tag's `crates/protos/proto/ext_mcp.proto`. If the bytes differ, replace `gateway/proto/ext_mcp.proto` with the new file. Do not hand-edit it. Update `proto_sha256`.
3. Resolve the **index** digest, not a single-platform manifest:

   ```sh
   docker buildx imagetools inspect cr.agentgateway.dev/agentgateway:vX.Y.Z
   ```

   The `Docker-Content-Digest` of the OCI index is the value to pin.
4. Update `pins/agentgateway.toml` and the `image:` line in `gateway/compose/compose.yaml`.
5. Render a config and validate it with the release binary before merging:

   ```sh
   gateway/scripts/fetch-agentgateway.sh
   AGENTGATEWAY_BIN="$PWD/gateway/.local-bin/agentgateway" \
     REQUIRE_UPSTREAM_VALIDATE=1 \
     cargo test --locked --manifest-path gateway/Cargo.toml
   ```

6. Run `gateway/compose/test.sh`. The probe must call the allowed tool and record a deny audit row.
7. Open a pull request. Do not merge it on a timer. For an upstream security release, land the digest bump within 48 hours.

`fizz-config` writes `pinned_agentgateway` into the generated file header from this pin. `gateway.gateways.ag_version` is the operator's recorded version and can lag the running image until you update the row.

## Branding

Call the product Fizzlayer. "Fizzlayer gateway" is fine when you need to name this data plane. Do not put "agentgateway" in a Fizzlayer product name, domain, or logo. "Built on agentgateway" in docs is the attribution. Do not say official, and do not imply Linux Foundation or Agentic AI Foundation endorsement.

The upstream admin UI, if you turn it on, stays their UI. Local compose binds it to `127.0.0.1:15000` inside the container and does not publish the port.
