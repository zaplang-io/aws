#!/usr/bin/env python3
"""Regenerate tests/expected/conditions.expected from boto3 — the #433 oracle.

The DynamoDB Key/Attr condition builder (aws-core/src/conditions.zap) must
byte-match boto3's ``boto3.dynamodb.conditions.ConditionExpressionBuilder``: the
same expression string, the same ``#nN`` / ``:vN`` placeholder numbering (boto3
does NOT dedup — every occurrence gets a fresh placeholder), and the same raw
attribute values.

This script is the authoritative oracle. For each vector it:

  1. builds the condition with the real boto3 ``Key`` / ``Attr`` DSL and runs
     ``ConditionExpressionBuilder.build_expression`` — the ground truth;
  2. independently runs a pure-Python MIRROR of the algorithm that
     ``conditions.zap`` implements (split-on-``.`` name expansion, left-to-right
     placeholder numbering), and asserts it byte-matches boto3; and
  3. emits the shared ``### / EXPR / NAME / VAL`` text block.

So regenerating also re-proves the Zap algorithm against boto3. ``tests/
conditions.main.zap`` prints the identical format through the actual Zap module,
and tools/run-tests.sh diffs it against the file this writes.

Run:  python3 tools/gen_condition_vectors.py        # writes the expected file
      python3 tools/gen_condition_vectors.py --check # just verify mirror==boto3

Values are mirrored across both sides by native type so the raw-value JSON
matches: N(str digits) <-> python int, S(str) <-> python str, Bool <-> bool,
Null <-> None.
"""
import json
import os
import sys

from boto3.dynamodb.conditions import Attr, ConditionExpressionBuilder, Key

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(HERE, "tests", "expected", "conditions.expected")


# --- mirror of conditions.zap (what the Zap module computes) ----------------
class _B:
    def __init__(self):
        self.nc = 0
        self.vc = 0
        self.nkeys = []
        self.nparts = []
        self.vkeys = []
        self.vjson = []


def _name_ph(b, part):
    p = "#n" + str(b.nc)
    b.nc += 1
    b.nkeys.append(p)
    b.nparts.append(part)
    return p


def _val_ph(b, vjson):
    p = ":v" + str(b.vc)
    b.vc += 1
    b.vkeys.append(p)
    b.vjson.append(vjson)
    return p


def _build_name(b, name):
    out = ""
    first = True
    for seg in name.split("."):
        if first:
            first = False
        else:
            out += "."
        bpos = seg.find("[")
        if bpos < 0:
            out += _name_ph(b, seg)
        else:
            head, tail = seg[0:bpos], seg[bpos : len(seg)]
            if len(head) > 0:
                out += _name_ph(b, head) + tail
            else:
                out += tail
    return out


def _subject(b, name, sz):
    if sz:
        return "size(" + _build_name(b, name) + ")"
    return _build_name(b, name)


def _render(b, c):
    t = c[0]
    if t == "cmp":  # (cmp, op, subj, size, vjson)
        s = _subject(b, c[2], c[3])
        return s + " " + c[1] + " " + _val_ph(b, c[4])
    if t == "between":  # (between, subj, size, lo, hi)
        s = _subject(b, c[1], c[2])
        return s + " BETWEEN " + _val_ph(b, c[3]) + " AND " + _val_ph(b, c[4])
    if t == "func2":  # (func2, op, subj, vjson)
        return c[1] + "(" + _build_name(b, c[2]) + ", " + _val_ph(b, c[3]) + ")"
    if t == "func1":  # (func1, op, subj)
        return c[1] + "(" + _build_name(b, c[2]) + ")"
    if t == "in":  # (in, subj, [vjson])
        phs = [_val_ph(b, v) for v in c[2]]
        return _build_name(b, c[1]) + " IN (" + ", ".join(phs) + ")"
    if t == "and":
        return "(" + _render(b, c[1]) + " AND " + _render(b, c[2]) + ")"
    if t == "or":
        return "(" + _render(b, c[1]) + " OR " + _render(b, c[2]) + ")"
    if t == "not":
        return "(NOT " + _render(b, c[1]) + ")"
    raise AssertionError("bad node " + repr(t))


def mirror(node):
    b = _B()
    expr = _render(b, node)
    return expr, list(zip(b.nkeys, b.nparts)), list(zip(b.vkeys, b.vjson))


# --- boto3 oracle -----------------------------------------------------------
def oracle(cond, is_key):
    r = ConditionExpressionBuilder().build_expression(
        cond, is_key_condition=is_key
    )
    nm, vm = r.attribute_name_placeholders, r.attribute_value_placeholders
    nk = sorted(nm, key=lambda k: int(k[2:]))
    vk = sorted(vm, key=lambda k: int(k[2:]))
    names = [(k, nm[k]) for k in nk]
    vals = [(k, json.dumps(vm[k])) for k in vk]
    return r.condition_expression, names, vals


# --- vector table: label, boto3 condition, mirror node, is_key --------------
# The mirror's value payloads are the json.dumps of the boto3 values, so the two
# sides share exactly one source of truth for every value.
VECTORS = [
    ("key_eq", Key("pk").eq("alice"), ("cmp", "=", "pk", False, '"alice"'), True),
    (
        "key_eq_and_begins_with",
        Key("pk").eq("alice") & Key("sk").begins_with("2024"),
        (
            "and",
            ("cmp", "=", "pk", False, '"alice"'),
            ("func2", "begins_with", "sk", '"2024"'),
        ),
        True,
    ),
    (
        "key_eq_and_between",
        Key("pk").eq("u1") & Key("ts").between(100, 200),
        (
            "and",
            ("cmp", "=", "pk", False, '"u1"'),
            ("between", "ts", False, "100", "200"),
        ),
        True,
    ),
    ("attr_gt_num", Attr("age").gt(30), ("cmp", ">", "age", False, "30"), False),
    ("attr_lt_num", Attr("age").lt(30), ("cmp", "<", "age", False, "30"), False),
    ("attr_lte_str", Attr("a").lte("m"), ("cmp", "<=", "a", False, '"m"'), False),
    ("attr_gte_num", Attr("n").gte(0), ("cmp", ">=", "n", False, "0"), False),
    ("attr_ne_num", Attr("c").ne(3), ("cmp", "<>", "c", False, "3"), False),
    (
        "attr_between",
        Attr("age").between(18, 65),
        ("between", "age", False, "18", "65"),
        False,
    ),
    (
        "attr_exists",
        Attr("email").exists(),
        ("func1", "attribute_exists", "email"),
        False,
    ),
    (
        "attr_not_exists",
        Attr("email").not_exists(),
        ("func1", "attribute_not_exists", "email"),
        False,
    ),
    (
        "attr_contains",
        Attr("tags").contains("vip"),
        ("func2", "contains", "tags", '"vip"'),
        False,
    ),
    (
        "attr_begins_with",
        Attr("name").begins_with("A"),
        ("func2", "begins_with", "name", '"A"'),
        False,
    ),
    (
        "attr_is_in",
        Attr("status").is_in(["A", "B", "C"]),
        ("in", "status", ['"A"', '"B"', '"C"']),
        False,
    ),
    (
        "attr_size_gt",
        Attr("name").size().gt(5),
        ("cmp", ">", "name", True, "5"),
        False,
    ),
    (
        "attr_type",
        Attr("data").attribute_type("S"),
        ("func2", "attribute_type", "data", '"S"'),
        False,
    ),
    ("attr_bool", Attr("active").eq(True), ("cmp", "=", "active", False, "true"), False),
    ("attr_null", Attr("x").ne(None), ("cmp", "<>", "x", False, "null"), False),
    ("not_eq", ~Attr("x").eq(1), ("not", ("cmp", "=", "x", False, "1")), False),
    (
        "or_two",
        Attr("a").eq(1) | Attr("b").eq(2),
        ("or", ("cmp", "=", "a", False, "1"), ("cmp", "=", "b", False, "2")),
        False,
    ),
    (
        "nested_path",
        Attr("a.b.c").eq("z"),
        ("cmp", "=", "a.b.c", False, '"z"'),
        False,
    ),
    (
        "indexed_path",
        Attr("a[0].b").eq("z"),
        ("cmp", "=", "a[0].b", False, '"z"'),
        False,
    ),
    (
        "mixed_path",
        Attr("a.b[2].c").eq("z"),
        ("cmp", "=", "a.b[2].c", False, '"z"'),
        False,
    ),
    (
        "and_or_mix",
        (Attr("a").eq(1) | Attr("b").eq(2)) & Attr("c").ne(3),
        (
            "and",
            ("or", ("cmp", "=", "a", False, "1"), ("cmp", "=", "b", False, "2")),
            ("cmp", "<>", "c", False, "3"),
        ),
        False,
    ),
    (
        "not_group",
        ~(Attr("age").gt(21) & Attr("name").begins_with("A")),
        (
            "not",
            (
                "and",
                ("cmp", ">", "age", False, "21"),
                ("func2", "begins_with", "name", '"A"'),
            ),
        ),
        False,
    ),
]


def block(label, expr, names, vals):
    lines = ["### " + label + " ###", "EXPR: " + expr]
    for k, part in names:
        lines.append("NAME " + k + " " + part)
    for k, vj in vals:
        lines.append("VAL " + k + " " + vj)
    return lines


def main():
    check_only = "--check" in sys.argv
    out_lines = []
    for label, cond, node, is_key in VECTORS:
        o_expr, o_names, o_vals = oracle(cond, is_key)
        m_expr, m_names, m_vals = mirror(node)
        if (o_expr, o_names, o_vals) != (m_expr, m_names, m_vals):
            print("MISMATCH vs boto3 for vector:", label, file=sys.stderr)
            print("  boto3 :", (o_expr, o_names, o_vals), file=sys.stderr)
            print("  mirror:", (m_expr, m_names, m_vals), file=sys.stderr)
            sys.exit(1)
        out_lines += block(label, o_expr, o_names, o_vals)
    text = "\n".join(out_lines) + "\n"
    if check_only:
        print("OK: mirror byte-matches boto3 for", len(VECTORS), "vectors")
        return
    with open(OUT, "w") as f:
        f.write(text)
    print("wrote", OUT, "(" + str(len(VECTORS)), "vectors)")


if __name__ == "__main__":
    main()
