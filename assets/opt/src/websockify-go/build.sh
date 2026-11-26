#!/bin/bash
# 交叉编译成静态二进制（目标机 x86_64，无 CGO 依赖）
set -euo pipefail
cd "$(dirname "$0")"
export PATH=/usr/local/go/bin:$PATH
export GOFLAGS=-mod=mod
VER="${VER:-$(date +%Y%m%d-%H%M%S)}"
mkdir -p dist
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath \
  -ldflags "-s -w -X main.version=${VER}" -o dist/websockify-go .
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath \
  -ldflags "-s -w -X main.version=${VER}" -o dist/websockify-go-arm64 .
ls -l dist/
sha256sum dist/websockify-go
