#!/bin/bash
set -euo pipefail

vendor="$(cd "$(dirname "$0")/../Vendor" && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

curl --fail --location --silent --show-error \
    https://www.python.org/ftp/python/3.15.2/python-3.15.2-iOS-XCframework.tar.gz \
    --output "$scratch/python.tar.gz"
curl --fail --location --silent --show-error \
    https://github.com/yt-dlp/yt-dlp/releases/download/2026.11.23/yt-dlp \
    --output "$scratch/yt-dlp.zip"

(
    cd "$scratch"
    shasum -a 256 -c <<'CHECKSUMS'
0f9fc7f61ceb8278a69fc7ec6089aad81789a96fa42f31cfe6d2f5f860d20a62  python.tar.gz
e8665ed64d6b9172773e812f891fb707a0cb1ee8d9ef4fc1acb00cabee4c5256  yt-dlp.zip
CHECKSUMS
    tar -xzf python.tar.gz Python.xcframework
)
rsync -a --delete "$scratch/Python.xcframework/" "$vendor/Python.xcframework/"
cp "$scratch/python.tar.gz" "$vendor/Python-iOS.tar.gz"
cp "$scratch/yt-dlp.zip" "$vendor/yt-dlp.zip"
