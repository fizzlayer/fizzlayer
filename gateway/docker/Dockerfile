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

FROM debian:bookworm-slim
RUN apt-get update \
  && apt-get install -y --no-install-recommends adduser util-linux \
  && rm -rf /var/lib/apt/lists/* \
  && adduser --uid 65532 --disabled-password --gecos "" --no-create-home fizz
COPY --from=build /src/target/release/fizz-config /usr/local/bin/fizz-config
COPY --from=build /src/target/release/fizz-guard /usr/local/bin/fizz-guard
COPY --from=build /src/target/release/sample-mcp /usr/local/bin/sample-mcp
COPY --from=build /src/target/release/fizz-mcp-probe /usr/local/bin/fizz-mcp-probe
COPY docker/entrypoint.sh /usr/local/bin/entrypoint
RUN chmod 755 /usr/local/bin/entrypoint /usr/local/bin/fizz-config \
  /usr/local/bin/fizz-guard /usr/local/bin/sample-mcp /usr/local/bin/fizz-mcp-probe
USER root
ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["fizz-guard", "serve"]
