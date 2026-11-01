#!/bin/sh
# Checks that every sample in swift-test/CompileFailures/ is rejected by the
# compiler with the diagnostic named on its first line:
#
#     // expected-error: <substring of the diagnostic>
#
# Swift Testing can only run code that compiles, so the guarantees that come
# from ~Copyable, ~Escapable, lifetimes and noasync are checked here instead.
#
# Usage (from the package root):  swift-test/check-compile-failures.sh
set -eu

cd "$(dirname "$0")/.."
swift build --target LMDB >/dev/null
bin=$(swift build --show-bin-path)
triple=$(xcrun swiftc -print-target-info | sed -n 's/.*"unversionedTriple": "\(.*\)".*/\1/p' | head -1)

pass=0
fail=0
for sample in swift-test/CompileFailures/*.swift; do
    expected=$(sed -n '1s|^// expected-error: ||p' "$sample")
    if [ -z "$expected" ]; then
        echo "SKIP  $sample (no '// expected-error:' on line 1)"
        continue
    fi

    # -emit-sil, not -typecheck: lifetime and exclusivity diagnostics are
    # produced on SIL. Swift 6 mode, as in the package, so noasync is an error.
    output=$(xcrun swiftc -swift-version 6 -emit-sil -o /dev/null \
        -target "${triple}27.0" \
        -enable-experimental-feature Lifetimes \
        -I "$bin" \
        -Xcc -fmodule-map-file=swift-include/module.modulemap \
        -Xcc -fmodule-map-file=Sources/CLMDB/include/module.modulemap \
        "$sample" 2>&1) && status=0 || status=$?

    if [ "$status" -ne 0 ] && printf '%s\n' "$output" | grep -F 'error:' | grep -qF -- "$expected"; then
        echo "PASS  $(basename "$sample")"
        pass=$((pass + 1))
    else
        echo "FAIL  $(basename "$sample"): expected an error containing: $expected"
        printf '%s\n' "$output" | grep -E 'error:|warning:' | sed 's/^/      /' | head -5
        fail=$((fail + 1))
    fi
done

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
