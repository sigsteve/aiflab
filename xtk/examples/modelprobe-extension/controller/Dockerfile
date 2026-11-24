FROM docker.io/library/golang:1.26.4-alpine AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build \
    -buildvcs=false \
    -trimpath \
    -ldflags="-s -w" \
    -o /modelprobe-controller \
    .

FROM scratch

COPY --from=build /modelprobe-controller /modelprobe-controller

USER 65532:65532
ENTRYPOINT ["/modelprobe-controller"]
