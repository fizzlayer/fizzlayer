FROM rust:1.100.0-bookworm AS build
RUN apt-get update \
  && apt-get install -y --no-install-recommends protobuf-compiler libprotobuf-dev \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Cargo.toml Cargo.lock build.rs ./
COPY proto ./proto
COPY pins ./pins
COPY src ./src
RUN cargo build --release --locked

# Published image: fizz-agent, fizz-guard, and fizz-config. No test helpers.
FROM debian:bookworm-slim AS runtime
RUN apt-get update \
  && apt-get install -y --no-install-recommends adduser util-linux \
  && rm -rf /var/lib/apt/lists/* \
  && adduser --uid 65532 --disabled-password --gecos "" --no-create-home fizz
COPY --from=build /src/target/release/fizz-config /usr/local/bin/fizz-config
COPY --from=build /src/target/release/fizz-guard /usr/local/bin/fizz-guard
COPY --from=build /src/target/release/fizz-agent /usr/local/bin/fizz-agent
COPY docker/entrypoint.sh /usr/local/bin/entrypoint
RUN chmod 755 /usr/local/bin/entrypoint /usr/local/bin/fizz-config \
  /usr/local/bin/fizz-guard /usr/local/bin/fizz-agent
USER root
ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["fizz-agent", "pull"]

# Local compose also needs the sample server and the probes.
FROM runtime AS dev
COPY --from=build /src/target/release/sample-mcp /usr/local/bin/sample-mcp
COPY --from=build /src/target/release/fizz-mcp-probe /usr/local/bin/fizz-mcp-probe
COPY --from=build /src/target/release/fizz-control-mock /usr/local/bin/fizz-control-mock
COPY --from=build /src/target/release/fizz-linked-probe /usr/local/bin/fizz-linked-probe
RUN chmod 755 /usr/local/bin/sample-mcp /usr/local/bin/fizz-mcp-probe \
  /usr/local/bin/fizz-control-mock /usr/local/bin/fizz-linked-probe
CMD ["fizz-guard", "serve"]
