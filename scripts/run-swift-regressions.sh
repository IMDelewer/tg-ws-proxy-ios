#!/bin/sh
set -eu
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_SOURCE="$(mktemp "${TMPDIR:-/tmp}/tgws-regressions.XXXXXX")"
trap 'rm -f "$TEST_SOURCE"' EXIT HUP INT TERM
cat "$ROOT_DIR/ios/TgWsProxy/Proxy/ProxyConfiguration.swift" \
    "$ROOT_DIR/ios/TgWsProxy/Proxy/ProxyEngine.swift" \
    "$ROOT_DIR/ios/TgWsProxy/Proxy/TunnelEngine.swift" \
    "$ROOT_DIR/ios/TgWsProxy/Proxy/ProxyViewModel.swift" \
    "$ROOT_DIR/tests/proxy_regressions.swift" > "$TEST_SOURCE"
xcrun swift -swift-version 5 "$TEST_SOURCE"
xcrun swift -swift-version 5 -D TGWS_TUNNEL_AVAILABLE "$TEST_SOURCE"
