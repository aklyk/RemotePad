#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output=$1
shift
mkdir -p "$(dirname -- "$output")"
xcrun --sdk macosx clang -O2 -Wall -Wextra -mmacosx-version-min=13.0 "$@" \
    "$project_dir/Sources/USBRelay/main.c" -o "$output"
