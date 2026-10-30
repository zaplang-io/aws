#!/usr/bin/env bash
# Run the offline conformance suite: compile+run each test entry through the Zap
# toolchain and diff stdout against the pinned expected output. Deterministic;
# makes no live AWS calls.
#
# Each entry is a real Zap program that imports the aws-core package modules via
# #283 module imports (`import aws_core.core`, …) — there is no bundling. The
# dependency is materialized into the project zenv (`zap zenv create`) and this
# script activates it so `zap run` resolves `aws_core` from `$ZAP_ZENV/pkg`.
#
# Toolchain: `zap` from PATH (the CI image), unless $ZAP overrides it. Running
# the programs needs codegen (LLVM), so this is a container/CI step — the host
# front-end gate (zap fmt / zap ir) is separate. Exit non-zero on first mismatch.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

ZAP="${ZAP:-zap}"

# Materialize the aws-core dependency into the project zenv and activate it, so
# `import aws_core.<module>` resolves to $ZAP_ZENV/pkg/aws_core/src/<module>.zap.
if [[ -z "${ZAP_ZENV:-}" ]]; then
    rm -rf zenv
    "$ZAP" zenv create --no-venv >/dev/null
    # shellcheck disable=SC1091
    source zenv/activate
fi

fail=0
run_case() {
    local name="$1"
    local entry="tests/${name}.main.zap"
    local expected="tests/expected/${name}.expected"
    echo "== ${name} =="
    local got
    got="$("$ZAP" run "$entry" 2>/dev/null)"
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

run_case sigv4_vectors
run_case service_signing
run_case streaming_sigv4
run_case presign_url
run_case awsjson_codec
run_case retry
run_case waiters
run_case middleware
run_case endpoints_resolution
run_case credentials_chain
run_case restjson_binding
run_case restxml_codec
run_case query_codec
run_case typed_errors
run_case dynamic_call
run_case cbor_codec
run_case conditions

if [[ $fail -ne 0 ]]; then
    echo "TESTS FAILED" >&2
    exit 1
fi
echo "ALL TESTS PASSED"
