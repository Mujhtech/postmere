FROM rust:1.96-bookworm AS build
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY crates ./crates
COPY migrations ./migrations
RUN cargo build --release --locked -p postmere-server

FROM debian:bookworm-slim
# Links the GitHub package to the repository and describes it there.
LABEL org.opencontainers.image.source="https://github.com/Mujhtech/postmere" \
      org.opencontainers.image.title="Postmere server" \
      org.opencontainers.image.description="Mail, calendar and assistants on your own server."
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /build/target/release/postmere-server /usr/local/bin/postmere-server
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["postmere-server"]
CMD ["serve"]
