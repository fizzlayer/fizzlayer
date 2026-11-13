FROM docker.io/library/rust:1.94-bookworm AS build
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release --locked --bin fizz-worker

FROM docker.io/library/debian:bookworm-slim
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*
COPY --from=build /build/target/release/fizz-worker /usr/local/bin/fizz-worker
USER 65532:65532
EXPOSE 8080
CMD ["/usr/local/bin/fizz-worker"]
