#!/bin/bash
# The encoder must stay fast at the iMac's full size. The low-latency rate control mode took 41 ms per frame here,
# plain real-time hardware encoding takes 11 ms, and the whole budget from capture to glass is about 50 ms.
cd "$(dirname "$0")/.." || exit 2
out=$(mktemp -d)
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -o "$out/probe" \
    Sources/Shared/Shared.swift Sources/Server/Encoder.swift Tests/encoder_probe/main.swift 2>"$out/err" || { cat "$out/err"; exit 2; }
"$out/probe"; code=$?
rm -rf "$out"
[ $code -eq 0 ] && echo "ok encoder is fast enough" || echo "FAIL encoder too slow"
exit $code
