#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
set -eu
TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PACKAGE_DIR=$(CDPATH= cd -- "$TEST_DIR/../.." && pwd -P)
cd "$PACKAGE_DIR"
# Optional arguments (for example --scratch-path or --build-system) go to both
# invocations so we link the products of the build we just requested.
swift build --configuration debug --target BandejaCore "$@"
PRODUCTS=$(swift build --configuration debug --show-bin-path "$@")
if [ -f "$PRODUCTS/BandejaCore.o" ] && [ -f "$PRODUCTS/BandejaShared.o" ]; then
    # Swift Build/Xcode layout: one relocatable object for each module.
    MODULES="$PRODUCTS"
    set -- "$PRODUCTS/BandejaCore.o" "$PRODUCTS/BandejaShared.o"
else
    # Native SwiftPM layout: modules and per-source objects live separately.
    MODULES="$PRODUCTS/Modules"
    set --
    for TARGET in BandejaCore BandejaShared; do
        FOUND=0
        for OBJECT in "$PRODUCTS/$TARGET.build/"*.swift.o; do
            [ -f "$OBJECT" ] || continue
            set -- "$@" "$OBJECT"
            FOUND=1
        done
        if [ "$FOUND" = 0 ]; then
            printf 'No linkable objects for %s in %s\n' "$TARGET" "$PRODUCTS" >&2
            exit 1
        fi
    done
fi
[ -d "$MODULES" ] || { printf 'Missing Swift modules: %s\n' "$MODULES" >&2; exit 1; }
mkdir -p "$TEST_DIR/.standalone"
swiftc -D BANDEJA_STANDALONE_TESTS -parse-as-library -I "$MODULES" \
    "$TEST_DIR/TrayStoreTests.swift" "$@" \
    -lsqlite3 -o "$TEST_DIR/.standalone/core-tests"
RESULT=0
"$TEST_DIR/.standalone/core-tests" > "$TEST_DIR/.standalone/results.json" || RESULT=$?
cat "$TEST_DIR/.standalone/results.json"
exit "$RESULT"
