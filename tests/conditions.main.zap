# Offline test for the DynamoDB Key/Attr condition builder (ticket #433, epic
# #432). Exercises aws.conditions end to end — the Key/Attr DSL, the `&`/`|`/`~`
# operators, size(), nested/indexed document paths, IN grouping, and the value
# seam — with no live AWS calls.
#
# Every vector is printed as a `### label / EXPR / NAME / VAL` block and diffed
# against tests/expected/conditions.expected, which is generated straight from
# boto3's ConditionExpressionBuilder by tools/gen_condition_vectors.py. The two
# must byte-match: same expression string, same #nN / :vN numbering (boto3 does
# not dedup), same raw values. Keep this vector list in lockstep with that
# script's VECTORS table.

import aws_core.conditions

def show(str label, conditions.Condition c):
    print("### " + label + " ###")
    auto r = conditions.build(c)
    print("EXPR: " + r.expression)
    auto i = 0
    while i < len(r.name_keys):
        print("NAME " + r.name_keys[i] + " " + r.name_parts[i])
        i = i + 1
    auto j = 0
    while j < len(r.val_keys):
        print("VAL " + r.val_keys[j] + " " + r.val_json[j])
        j = j + 1

def main():
    # Single-leaf vectors pass the leaf straight in. Vectors that combine leaves
    # with `&` / `|` / `~` bind each leaf to a `Condition` value first: the
    # toolchain types a struct method-call result as `Unknown` today, and
    # `Unknown & Unknown` falls back to the built-in bitwise `&` instead of
    # dispatching `__and__`; the declared-type binding makes the operand concrete
    # so the operator dispatches. See DECISIONS.md D-0009 (toolchain gap).
    show("key_eq", conditions.Key("pk").eq(conditions.S("alice")))

    conditions.Condition k_pk = conditions.Key("pk").eq(conditions.S("alice"))
    conditions.Condition k_sk = conditions.Key("sk").begins_with(conditions.S("2024"))
    show("key_eq_and_begins_with", k_pk & k_sk)

    conditions.Condition k_pk2 = conditions.Key("pk").eq(conditions.S("u1"))
    conditions.Condition k_ts = conditions.Key("ts").between(
        conditions.N("100"),
        conditions.N("200"),
    )
    show("key_eq_and_between", k_pk2 & k_ts)

    show("attr_gt_num", conditions.Attr("age").gt(conditions.N("30")))
    show("attr_lt_num", conditions.Attr("age").lt(conditions.N("30")))
    show("attr_lte_str", conditions.Attr("a").lte(conditions.S("m")))
    show("attr_gte_num", conditions.Attr("n").gte(conditions.N("0")))
    show("attr_ne_num", conditions.Attr("c").ne(conditions.N("3")))
    show(
        "attr_between",
        conditions.Attr("age").between(conditions.N("18"), conditions.N("65")),
    )
    show("attr_exists", conditions.Attr("email").exists())
    show("attr_not_exists", conditions.Attr("email").not_exists())
    show("attr_contains", conditions.Attr("tags").contains(conditions.S("vip")))
    show("attr_begins_with", conditions.Attr("name").begins_with(conditions.S("A")))
    list[conditions.AttrValue] in_vals = [
        conditions.S("A"),
        conditions.S("B"),
        conditions.S("C"),
    ]
    show("attr_is_in", conditions.Attr("status").is_in(in_vals))
    show("attr_size_gt", conditions.Attr("name").size().gt(conditions.N("5")))
    show("attr_type", conditions.Attr("data").attribute_type(conditions.S("S")))
    show("attr_bool", conditions.Attr("active").eq(conditions.Bool(True)))
    show("attr_null", conditions.Attr("x").ne(conditions.Null()))

    conditions.Condition x_eq = conditions.Attr("x").eq(conditions.N("1"))
    show("not_eq", ~x_eq)

    conditions.Condition a_eq = conditions.Attr("a").eq(conditions.N("1"))
    conditions.Condition b_eq = conditions.Attr("b").eq(conditions.N("2"))
    show("or_two", a_eq | b_eq)

    show("nested_path", conditions.Attr("a.b.c").eq(conditions.S("z")))
    show("indexed_path", conditions.Attr("a[0].b").eq(conditions.S("z")))
    show("mixed_path", conditions.Attr("a.b[2].c").eq(conditions.S("z")))

    conditions.Condition m_a = conditions.Attr("a").eq(conditions.N("1"))
    conditions.Condition m_b = conditions.Attr("b").eq(conditions.N("2"))
    conditions.Condition m_c = conditions.Attr("c").ne(conditions.N("3"))
    show("and_or_mix", (m_a | m_b) & m_c)

    conditions.Condition g_age = conditions.Attr("age").gt(conditions.N("21"))
    conditions.Condition g_name = conditions.Attr("name").begins_with(conditions.S("A"))
    show("not_group", ~(g_age & g_name))
