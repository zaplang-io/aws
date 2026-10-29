#!/usr/bin/env python3
"""Bundle Zap AWS SDK modules into a single compilable file.

The Zap compiler does not yet consume Zap-to-Zap package imports — a project
compiles exactly one entry file (`src/main.zap`), and `import` resolves only
stdlib modules and `import python` (see FRICTION.md, gap #1). Until that lands,
a runnable program = the library modules + one `main()` concatenated into a
single file.

This script concatenates its input files in order, hoisting every `import <mod>`
line to the top (de-duplicated, first-seen order) so the stitched file has each
stdlib import exactly once. It is a build step, not part of the shipped library.

The file list is supplied on the command line (library modules first, the
`main()` last); there is no hard-coded manifest. The current modules are
`src/aws/core.zap`, `src/aws/credentials.zap`, `src/aws/endpoints.zap`,
`src/aws/retry.zap`, `src/aws/awsjson.zap` (the awsJson 1.0/1.1 protocol codec,
bundled after core and before the service modules that ride it),
`src/aws/binding.zap` (the protocol-agnostic HTTP binding layer),
`src/aws/restjson.zap` (the rest-json codec), `src/aws/restxml.zap` (the rest-xml
codec, XML document body over the same binding layer), `src/aws/dynamodb.zap` and
`src/aws/s3.zap`; the test/example harnesses in tools/ pass the subset each entry
point needs. `binding.zap` depends on `core.zap`, and `restjson.zap` /
`restxml.zap` on both, so bundle them in that order (core, then binding, then the
rest-* codec).

Usage:
    tools/bundle.py src/aws/core.zap src/aws/credentials.zap tests/foo.main.zap > out.zap
"""
import re
import sys

IMPORT_RE = re.compile(r"^import\s+\S+\s*$")


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    imports = []
    seen = set()
    bodies = []
    for path in argv[1:]:
        with open(path, "r") as fh:
            body_lines = []
            for line in fh.read().splitlines():
                if IMPORT_RE.match(line):
                    key = line.strip()
                    if key not in seen:
                        seen.add(key)
                        imports.append(key)
                    continue
                body_lines.append(line)
            bodies.append((path, "\n".join(body_lines)))

    out = []
    out.extend(imports)
    out.append("")
    for path, body in bodies:
        out.append(f"# ===== bundled from {path} =====")
        out.append(body.strip("\n"))
        out.append("")
    sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
