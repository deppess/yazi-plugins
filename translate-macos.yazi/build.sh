#!/bin/sh
# SPDX-License-Identifier: PolyForm-Strict-1.0.0
#
# Builds the helper: build.sh <output binary>
#
# The helper uses Speech's spoken-language detector, which the framework exports but
# leaves out of its public interface. A copy of the SDK's Speech interface with
# speech-spi.swiftinterface appended is put first on the import path, so the helper
# compiles against it and links against the real framework. Speech is weak-linked,
# so the helper still runs, without detection, on a macOS that lacks the detector.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out=$1
work=$(mktemp -d "${TMPDIR:-/tmp}/translate-build.XXXXXX")
trap 'rm -rf "$work"' EXIT

sdk=$(xcrun --show-sdk-path)
interfaces="$sdk/System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule"
mkdir -p "$work/include/Speech.swiftmodule"
for interface in "$interfaces"/*-apple-macos.swiftinterface; do
	target="$work/include/Speech.swiftmodule/$(basename "$interface")"
	cat "$interface" "$here/speech-spi.swiftinterface" > "$target"
done

xcrun swiftc -O -parse-as-library -I "$work/include" -module-cache-path "$work/cache" \
	-Xlinker -weak_framework -Xlinker Speech \
	-o "$work/translate" "$here/translate.swift"
mv "$work/translate" "$out"
