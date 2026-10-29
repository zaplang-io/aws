#!/usr/bin/env bash
# Run the offline test suite: bundle each test with the modules it needs, run it
# through the Zap toolchain, and diff stdout against the pinned expected output.
# Deterministic; makes no live AWS calls.
#
# Honors the same toolchain-selection env vars as tools/zrun.sh ($ZAP, or
# $ZAP_REPO for the dev container). Exit non-zero on the first mismatch.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

fail=0
run_case() {
    local name="$1"; shift
    local expected="tests/expected/${name}.expected"
    echo "== ${name} =="
    local got
    got="$(bash tools/zrun.sh "$@" 2>/dev/null)"
    if [[ ! -f "$expected" ]]; then
        echo "  MISSING expected: $expected" >&2
        fail=1
        return
    fi
    if diff <(printf '%s' "$got") "$expected" >/dev/null 2>&1 \
        || diff <(printf '%s\n' "$got") "$expected" >/dev/null 2>&1; then
        echo "  ok"
    else
        echo "  FAIL — output differs from $expected" >&2
        diff <(printf '%s\n' "$got") "$expected" | head -40 >&2
        fail=1
    fi
}

run_case sigv4_vectors \
    src/aws/core.zap tests/sigv4_vectors.main.zap
run_case service_signing \
    src/aws/core.zap src/aws/dynamodb.zap src/aws/s3.zap \
    tests/service_signing.main.zap
run_case retry \
    src/aws/core.zap src/aws/retry.zap tests/retry.main.zap

if [[ $fail -ne 0 ]]; then
    echo "TESTS FAILED" >&2
    exit 1
fi
echo "ALL TESTS PASSED"
