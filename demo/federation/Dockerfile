# syntax=docker/dockerfile:1.7
FROM golang:1.27-alpine AS build
# Optional extra root CAs for module downloads behind a TLS-inspecting proxy or antivirus (build stage only).
COPY build-ca/ /build-ca/
RUN if ls /build-ca/*.pem >/dev/null 2>&1; then cat /build-ca/*.pem >> /etc/ssl/certs/ca-certificates.crt; fi
WORKDIR /src
COPY go.mod go.sum* ./
COPY *.go ./
RUN --mount=type=cache,target=/go/pkg/mod go mod tidy && CGO_ENABLED=0 go build -trimpath -o /out/federation .

FROM alpine:3.22
RUN apk add --no-cache ca-certificates curl jq
COPY --from=build /out/federation /usr/local/bin/federation
VOLUME /data
EXPOSE 9443 9444
ENTRYPOINT ["federation"]
