#!/usr/bin/env python3
"""Regenerate tests/expected/marshal.expected from boto3 — the #434 oracle.

The native<->AttributeValue marshaller (aws-core/src/marshal.zap) must
byte-match ``boto3.dynamodb.types.TypeSerializer`` / ``TypeDeserializer``: the
same AttributeValue structure, numbers as decimal STRINGS under ``N``, the same
set/map handling. boto3's ``TypeSerializer`` leaves ``B``/``BS`` as RAW bytes
(botocore base64-encodes them on the awsJson wire); we emit the wire form, so
this oracle base64-encodes blobs to match what marshal.zap produces.

This script is the authoritative oracle. For each vector it:

  1. runs the real boto3 ``TypeSerializer`` on the native value and renders the
     result to the canonical AttributeValue wire JSON (``SER``) — the ground
     truth;
  2. round-trips it through boto3's ``TypeDeserializer`` and back through
     ``TypeSerializer`` (``RT``), proving the inverse — ``RT`` must equal
     ``SER``;
  3. independently runs a pure-Python MIRROR of the algorithm marshal.zap
     implements and asserts it byte-matches boto3; and
  4. emits the shared ``### / SER / RT`` text block.

So regenerating also re-proves the Zap algorithm against boto3.
``tests/marshal.main.zap`` prints the identical format through the actual Zap
module, and tools/run-tests.sh diffs it against the file this writes.

Run:  python3 tools/gen_marshal_vectors.py          # writes the expected file
      python3 tools/gen_marshal_vectors.py --check   # just verify mirror==boto3

Canonicalization (shared by both sides, documented in marshal.zap):
  * map members keep caller/insertion order on SERIALIZE (boto3 iterates the
    dict in order); the vectors below use sorted keys so the pinned bytes are
    stable and the DESERIALIZE path (which sorts keys) round-trips;
  * set types (SS/NS/BS) are unordered in boto3 — it iterates a Python ``set`` —
    so both sides SORT the rendered element tokens;
  * no JSON string escaping on this hand path (matches dynamodb.zap /
    conditions.zap): the vectors avoid characters that need escaping.
"""
import base64
import os
import sys
from decimal import Decimal

from boto3.dynamodb.types import Binary, TypeDeserializer, TypeSerializer

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(HERE, "tests", "expected", "marshal.expected")


def _b64(blob):
    return base64.b64encode(blob).decode("ascii")


def _jstr(s):
    # No escaping on the hand path (matches marshal.zap).
    return '"' + s + '"'


# --- canonical wire JSON from a boto3 TypeSerializer AttributeValue ---------
# `av` is the dict boto3 produces, e.g. {"S": "x"} / {"B": b"..."} / {"M": {...}}.
def canon(av):
    (tk, payload) = next(iter(av.items()))
    if tk == "S":
        return "{" + _jstr("S") + ":" + _jstr(payload) + "}"
    if tk == "N":
        return "{" + _jstr("N") + ":" + _jstr(payload) + "}"
    if tk == "BOOL":
        return "{" + _jstr("BOOL") + ":" + ("true" if payload else "false") + "}"
    if tk == "NULL":
        return '{"NULL":true}'
    if tk == "B":
        raw = payload.value if isinstance(payload, Binary) else payload
        return "{" + _jstr("B") + ":" + _jstr(_b64(raw)) + "}"
    if tk == "L":
        return "{" + _jstr("L") + ":[" + ",".join(canon(x) for x in payload) + "]}"
    if tk == "M":
        body = ",".join(_jstr(k) + ":" + canon(v) for k, v in payload.items())
        return "{" + _jstr("M") + ":{" + body + "}}"
    if tk == "SS":
        return "{" + _jstr("SS") + ":[" \
            + ",".join(_jstr(x) for x in sorted(payload)) + "]}"
    if tk == "NS":
        return "{" + _jstr("NS") + ":[" \
            + ",".join(_jstr(x) for x in sorted(payload)) + "]}"
    if tk == "BS":
        raws = [(p.value if isinstance(p, Binary) else p) for p in payload]
        return "{" + _jstr("BS") + ":[" \
            + ",".join(_jstr(x) for x in sorted(_b64(r) for r in raws)) + "]}"
    raise AssertionError("bad AttributeValue type key " + repr(tk))


# --- pure-Python mirror of marshal.zap's serialize over a tagged node -------
# Node tags mirror marshal.Value: ("S",s) ("N",n) ("BOOL",b) ("NULL",)
# ("B",bytes) ("L",[node]) ("M",[keys],[node]) ("SS",[str]) ("NS",[str])
# ("BS",[bytes]).
def mirror(node):
    t = node[0]
    if t == "S":
        return "{" + _jstr("S") + ":" + _jstr(node[1]) + "}"
    if t == "N":
        return "{" + _jstr("N") + ":" + _jstr(node[1]) + "}"
    if t == "BOOL":
        return "{" + _jstr("BOOL") + ":" + ("true" if node[1] else "false") + "}"
    if t == "NULL":
        return '{"NULL":true}'
    if t == "B":
        return "{" + _jstr("B") + ":" + _jstr(_b64(node[1])) + "}"
    if t == "L":
        return "{" + _jstr("L") + ":[" + ",".join(mirror(x) for x in node[1]) + "]}"
    if t == "M":
        keys, vals = node[1], node[2]
        body = ",".join(_jstr(keys[i]) + ":" + mirror(vals[i])
                        for i in range(len(keys)))
        return "{" + _jstr("M") + ":{" + body + "}}"
    if t == "SS":
        return "{" + _jstr("SS") + ":[" \
            + ",".join(_jstr(x) for x in sorted(node[1])) + "]}"
    if t == "NS":
        return "{" + _jstr("NS") + ":[" \
            + ",".join(_jstr(x) for x in sorted(node[1])) + "]}"
    if t == "BS":
        return "{" + _jstr("BS") + ":[" \
            + ",".join(_jstr(x) for x in sorted(_b64(r) for r in node[1])) + "]}"
    raise AssertionError("bad mirror node " + repr(t))


# --- vector table: label, native python value, mirror node ------------------
# The native value is what boto3's TypeSerializer consumes; the mirror node is
# what marshal.zap's constructors build. The two share one source of truth per
# value, and `main()` asserts canon(boto3(native)) == mirror(node).
B1 = bytes([1])
B2 = bytes([2])
B123 = bytes([1, 2, 3])

VECTORS = [
    ("s_basic", "alice", ("S", "alice")),
    ("s_empty", "", ("S", "")),
    ("n_int", 30, ("N", "30")),
    ("n_neg", -7, ("N", "-7")),
    ("n_zero", 0, ("N", "0")),
    ("n_decimal", Decimal("3.14"), ("N", "3.14")),
    ("n_decimal_neg", Decimal("-0.5"), ("N", "-0.5")),
    ("bool_true", True, ("BOOL", True)),
    ("bool_false", False, ("BOOL", False)),
    ("null", None, ("NULL",)),
    ("bytes", B123, ("B", B123)),
    (
        "list_mixed",
        ["a", 1, True, None],
        ("L", [("S", "a"), ("N", "1"), ("BOOL", True), ("NULL",)]),
    ),
    ("list_empty", [], ("L", [])),
    (
        "map_basic",
        {"age": 30, "name": "Alice"},
        ("M", ["age", "name"], [("N", "30"), ("S", "Alice")]),
    ),
    ("map_empty", {}, ("M", [], [])),
    (
        "map_nested",
        {"profile": {"city": "NYC"}},
        ("M", ["profile"], [("M", ["city"], [("S", "NYC")])]),
    ),
    ("ss", {"c", "a", "b"}, ("SS", ["c", "a", "b"])),
    (
        "ns",
        {Decimal("3"), Decimal("1"), Decimal("2")},
        ("NS", ["3", "1", "2"]),
    ),
    ("bs", {B2, B1}, ("BS", [B2, B1])),
    (
        "deeply_nested",
        [{"k": {"x", "y"}}],
        ("L", [("M", ["k"], [("SS", ["x", "y"])])]),
    ),
]

# N accessor reads: text, is_integral, int-when-integral (the "int when
# integral, else float" deserialize read). Matched against boto3's Decimal.
N_ACCESSORS = ["30", "-7", "0", "3.14", "-0.5"]

# Scalar bridge from the #433 condition builder (conditions.AttrValue kinds
# 0=S 1=N 2=Bool 3=Null) through from_scalar -> serialize.
FROM_SCALAR = [
    ("S", ("S", "alice")),
    ("N", ("N", "30")),
    ("BOOL", ("BOOL", True)),
    ("NULL", ("NULL",)),
]


def main():
    check_only = "--check" in sys.argv
    ser = TypeSerializer()
    de = TypeDeserializer()
    out = []
    for label, native, node in VECTORS:
        av = ser.serialize(native)
        ser_json = canon(av)
        rt_json = canon(ser.serialize(de.deserialize(av)))
        mir = mirror(node)
        if mir != ser_json:
            print("MISMATCH vs boto3 (serialize):", label, file=sys.stderr)
            print("  boto3 :", ser_json, file=sys.stderr)
            print("  mirror:", mir, file=sys.stderr)
            sys.exit(1)
        if rt_json != ser_json:
            print("MISMATCH round-trip:", label, file=sys.stderr)
            print("  SER:", ser_json, "  RT:", rt_json, file=sys.stderr)
            sys.exit(1)
        out.append("### " + label + " ###")
        out.append("SER " + ser_json)
        out.append("RT " + rt_json)

    out.append("### num_accessors ###")
    for text in N_ACCESSORS:
        d = de.deserialize({"N": text})
        integral = ("." not in text and "e" not in text and "E" not in text)
        # boto3 cross-check: an integral decimal string IS an integral Decimal.
        assert integral == (d == d.to_integral_value()), text
        if integral:
            out.append("NINT " + text + " true " + str(int(d)))
        else:
            out.append("NINT " + text + " false")

    out.append("### from_scalar ###")
    for kindlabel, node in FROM_SCALAR:
        out.append("FS " + kindlabel + " " + mirror(node))

    text = "\n".join(out) + "\n"
    if check_only:
        print("OK: mirror byte-matches boto3 for", len(VECTORS), "vectors")
        return
    with open(OUT, "w") as f:
        f.write(text)
    print("wrote", OUT, "(" + str(len(VECTORS)), "vectors)")


if __name__ == "__main__":
    main()
