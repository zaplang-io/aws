#!/usr/bin/env bash
# Bundle Zap AWS SDK modules + a main into one file and run it.
#
# Because the compiler does not yet link multiple Zap files (FRICTION.md #1), a
# runnable program is the library modules + one main() concatenated. This script
# does that and then runs the result with the Zap toolchain.
#
# Usage:
#   tools/zrun.sh <file.zap> [more files...]
# Files are bundled in the order given (library modules first, the main last).
#
# Toolchain selection (first that applies):
#   * $ZAP set           -> run `$ZAP run <bundle>`  (a native zap with codegen)
#   * $ZAP_REPO set      -> run inside the LLVM dev container built from that
#                           Zap checkout, reusing its target volume. Needed on
#                           hosts without a local LLVM 18 (e.g. macOS dev boxes);
#                           see README "Building the toolchain".
#   * otherwise          -> `zap run <bundle>` from PATH
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: tools/zrun.sh <file.zap> [more files...]" >&2
    exit 2
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bundle="$tmp/bundle.zap"
python3 "$here/tools/bundle.py" "$@" > "$bundle"

if [[ -n "${ZAP:-}" ]]; then
    exec "$ZAP" run "$bundle"
elif [[ -n "${ZAP_REPO:-}" ]]; then
    image="${ZAP_IMAGE:-zap-dev}"
    vol="${ZAP_TARGET_VOLUME:-zap-target-awsv1}"
    bin="${ZAP_BIN:-/work/target-docker/debug/zap}"
    exec docker run --rm --init --memory="${ZAP_DOCKER_MEMORY:-4g}" \
        --memory-swap="${ZAP_DOCKER_MEMORY:-4g}" --cpus="${ZAP_DOCKER_CPUS:-4}" \
        -v "$ZAP_REPO":/work \
        -v "$vol":/work/target-docker \
        -v "$tmp":/bundle \
        "$image" "$bin" run /bundle/bundle.zap
else
    exec zap run "$bundle"
fi
