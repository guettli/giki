# giki in one image: the Go server and the PWA it serves, on one origin.
#
# The web bundle is NOT built here. It is built by whoever builds the image --
# CI does it with the same Flutter that runs the tests -- and copied in. Two
# reasons: the bundle in the image is then provably the one the test suite ran
# against, and the image build does not need a 2 GB Flutter SDK (upstream
# publishes no image pinned to our Flutter version, only a moving `stable`).
#
# Build it by hand with:
#
#   tool/fetch-sqlite-wasm.sh
#   (cd client && flutter build web --release)
#   docker build -f docker/Dockerfile -t giki .

FROM golang:1.26 AS build
WORKDIR /src

# Dependencies first, so a code-only change reuses this layer.
COPY go.mod go.sum ./
RUN go mod download

COPY . .
# CGO off: modernc.org/sqlite is pure Go, so this links statically and the
# final image needs nothing but the binary itself.
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /giki-server ./cmd/giki-server

FROM gcr.io/distroless/static-debian12:nonroot
LABEL org.opencontainers.image.source=https://github.com/guettli/giki
LABEL org.opencontainers.image.description="Local-first wiki and spaced repetition"
LABEL org.opencontainers.image.licenses=Apache-2.0

COPY --from=build /giki-server /usr/local/bin/giki-server
COPY client/build/web /srv/giki/web

# The SQLite database lives here; mount a volume over it. The image runs as
# nonroot (uid 65532), so the volume has to be writable by that user -- in
# Kubernetes that is what the pod's fsGroup is for.
VOLUME ["/data"]
EXPOSE 8080
USER nonroot:nonroot

ENTRYPOINT ["/usr/local/bin/giki-server"]
CMD ["-addr", "0.0.0.0:8080", "-db", "/data/giki.sqlite", "-web-root", "/srv/giki/web"]
