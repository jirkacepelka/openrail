FROM rust:1-slim-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY crates crates
RUN cargo build --release -p openrail-server

FROM debian:bookworm-slim
RUN useradd --system --create-home --uid 10001 openrail \
    && mkdir /data && chown openrail /data
COPY --from=build /src/target/release/openrail-server /usr/local/bin/openrail-server
COPY server.example.toml /etc/openrail/server.toml
USER openrail
WORKDIR /data
VOLUME /data
EXPOSE 7878/tcp 7878/udp
ENTRYPOINT ["openrail-server", "--config", "/etc/openrail/server.toml"]
