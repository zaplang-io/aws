# aws.conditions — DynamoDB Key/Attr condition builder (ergonomics epic #432,
# ticket #433).
#
# A hand-written, boto3-equivalent DSL for building DynamoDB condition and filter
# expressions. It is the Zap counterpart of `boto3.dynamodb.conditions.Key` /
# `Attr` and its `ConditionExpressionBuilder`: a chainable builder that turns
#
#     Key("pk").eq(S("alice")) & Attr("age").gt(N("30"))
#
# into the three pieces every generated DynamoDB operation already accepts as
# plain str/dict:
#
#   1. the expression STRING (for KeyConditionExpression / FilterExpression /
#      ConditionExpression), using `#nN` name placeholders and `:vN` value
#      placeholders,
#   2. ExpressionAttributeNames  (`#nN` -> the real attribute-name part),
#   3. ExpressionAttributeValues (`:vN` -> the value).
#
# WHY HAND-WRITTEN (D-0001, generated-is-product): the generated per-service
# clients are the shipping SDK, but the resource-layer conveniences boto3 hand-
# codes on top of them are not derivable from botocore models. This builder is
# that convenience layer. Unlike the parked `s3.zap` / `dynamodb.zap` oracle
# fixtures, it is a real shipping aws-core module: generated clients' users
# compose it and pass the result straight into the typed operation inputs.
#
# ORACLE: the output must byte-match boto3's
# `boto3.dynamodb.conditions.ConditionExpressionBuilder` for the same conditions
# — same placeholder-numbering scheme, same (non-)dedup, same string.
# `tests/conditions.main.zap` + `tests/expected/conditions.expected` pin vectors
# generated straight from boto3; `tools/gen_condition_vectors.py` regenerates the
# expected file from the installed boto3. Matching facts worth stating:
#   * NO dedup. boto3 assigns a fresh `#nN` / `:vN` to every occurrence, even of
#     the same attribute name or value; so do we.
#   * Placeholders are numbered in a left-to-right depth-first walk of the final
#     tree; within a leaf the name placeholder(s) come before the value(s). We
#     build a pure immutable condition tree (so `&`/`|`/`~` stay side-effect
#     free) and number it in one stateful pass, exactly as boto3 does.
#   * Nested document paths split on `.` and bracket indices stay literal:
#     `a.b.c` -> `#n0.#n1.#n2`, `a[0].b` -> `#n0[0].#n1`.
#
# VALUES (#434 seam): boto3's ConditionExpressionBuilder emits the RAW values; a
# separate TypeSerializer in the resource layer turns them into AttributeValues.
# Native<->AttributeValue marshalling is ticket #434, queued separately. For #433
# we mirror the builder exactly: `AttrValue` carries a scalar and renders to the
# raw-value JSON the builder produces (string -> "x", number -> bare digits,
# bool -> true/false, null -> null). `AttrValue` is the clean seam #434 slots
# into — it will add native int/float/Decimal/bytes coercion and the
# AttributeValue wire form; nothing else in this module needs to change.

# --- AttrValue: a condition operand value (the #434 seam) -------------------

# kind tags.
#   0 = string  (S)     -> JSON "..."
#   1 = number  (N)     -> JSON bare decimal digits (DynamoDB carries N as text)
#   2 = boolean (Bool)  -> JSON true / false
#   3 = null    (Null)  -> JSON null
struct AttrValue:
    int64 kind
    str sv
    bool bv

# String value: `S("alice")`.
def S(str v) -> AttrValue:
    return AttrValue(kind=0, sv=v, bv=False)

# Number value, given as its decimal digits: `N("30")`. Numbers are passed as
# text (DynamoDB's N wire form) so no float rounding sneaks in; #434 will add
# native-number constructors on top of this same seam.
def N(str v) -> AttrValue:
    return AttrValue(kind=1, sv=v, bv=False)

# Boolean value: `Bool(True)`.
def Bool(bool v) -> AttrValue:
    return AttrValue(kind=2, sv="", bv=v)

# Null value: `Null()`.
def Null() -> AttrValue:
    return AttrValue(kind=3, sv="", bv=False)

# Render one value to the raw-value JSON boto3's builder stores. No string
# escaping on the hand path (matches dynamodb.zap): keep test/real values free of
# characters that would need JSON escaping until #434's marshaller lands.
def _av_json(AttrValue v) -> str:
    if v.kind == 0:
        return "\"" + v.sv + "\""
    if v.kind == 1:
        return v.sv
    if v.kind == 2:
        if v.bv:
            return "true"
        return "false"
    return "null"

# --- Condition: the immutable expression tree -------------------------------

# node kinds.
#   0 = comparison   subj <op> v0           (= <> < <= > >=)
#   1 = between       subj BETWEEN v0 AND v1
#   2 = func2         op(subj, v0)          (begins_with / contains / attribute_type)
#   3 = func1         op(subj)              (attribute_exists / attribute_not_exists)
#   4 = in            subj IN (v0, v1, ...)
#   5 = and           (kid0 AND kid1)
#   6 = or            (kid0 OR kid1)
#   7 = not           (NOT kid0)
struct Condition:
    int64 kind
    str op
    str subj
    bool subj_size
    bool subj_key
    list[AttrValue] vals
    bool grouped
    list[Condition] kids

    # `&` -> AND, `|` -> OR, `~` -> NOT, with boto3's parenthesization.
    def __and__(self, Condition other) -> Condition:
        return _and(self, other)

    def __or__(self, Condition other) -> Condition:
        return _or(self, other)

    def __invert__(self) -> Condition:
        return _not(self)

# --- AttrRef: the Key / Attr handle -----------------------------------------

# `Key(name)` and `Attr(name)` both produce an `AttrRef`. boto3 splits these into
# two classes so a KeyConditionExpression can reject non-Key operands; Zap v1 has
# no inheritance to share the comparison methods, so they share one struct and
# `is_key` records which constructor was used (carried for a future
# key-condition validation / `build_key_expression`). The produced expression
# string is identical either way. `.size()` returns an AttrRef flagged so a
# following comparison wraps the subject in `size(...)`.
struct AttrRef:
    str name
    bool is_key
    bool is_size

    # Key + Attr subset.
    def eq(self, AttrValue value) -> Condition:
        return _cmp(self, "=", value)

    def lt(self, AttrValue value) -> Condition:
        return _cmp(self, "<", value)

    def lte(self, AttrValue value) -> Condition:
        return _cmp(self, "<=", value)

    def gt(self, AttrValue value) -> Condition:
        return _cmp(self, ">", value)

    def gte(self, AttrValue value) -> Condition:
        return _cmp(self, ">=", value)

    def between(self, AttrValue low, AttrValue high) -> Condition:
        list[AttrValue] vs = [low, high]
        return _leaf(1, "BETWEEN", self, vs, False)

    def begins_with(self, AttrValue value) -> Condition:
        return _func2(self, "begins_with", value)

    # Attr-only additions.
    def ne(self, AttrValue value) -> Condition:
        return _cmp(self, "<>", value)

    def contains(self, AttrValue value) -> Condition:
        return _func2(self, "contains", value)

    def attribute_type(self, AttrValue value) -> Condition:
        return _func2(self, "attribute_type", value)

    def exists(self) -> Condition:
        return _func1(self, "attribute_exists")

    def not_exists(self) -> Condition:
        return _func1(self, "attribute_not_exists")

    def is_in(self, list[AttrValue] values) -> Condition:
        return _leaf(4, "IN", self, values, True)

    # A size operand usable in comparisons: `Attr("x").size().gt(N("5"))`.
    def size(self) -> AttrRef:
        return AttrRef(name=self.name, is_key=self.is_key, is_size=True)

# Partition / sort key attribute.
def Key(str name) -> AttrRef:
    return AttrRef(name=name, is_key=True, is_size=False)

# Non-key item attribute.
def Attr(str name) -> AttrRef:
    return AttrRef(name=name, is_key=False, is_size=False)

# --- leaf / logical node constructors ---------------------------------------

def _leaf(int64 kind, str op, AttrRef r, list[AttrValue] vs, bool grouped) -> Condition:
    list[Condition] nokids = []
    return Condition(
        kind=kind,
        op=op,
        subj=r.name,
        subj_size=r.is_size,
        subj_key=r.is_key,
        vals=vs,
        grouped=grouped,
        kids=nokids,
    )

def _cmp(AttrRef r, str op, AttrValue v) -> Condition:
    list[AttrValue] vs = [v]
    return _leaf(0, op, r, vs, False)

def _func2(AttrRef r, str op, AttrValue v) -> Condition:
    list[AttrValue] vs = [v]
    return _leaf(2, op, r, vs, False)

def _func1(AttrRef r, str op) -> Condition:
    list[AttrValue] vs = []
    return _leaf(3, op, r, vs, False)

def _logical(int64 kind, str op, list[Condition] kids) -> Condition:
    list[AttrValue] nv = []
    return Condition(
        kind=kind,
        op=op,
        subj="",
        subj_size=False,
        subj_key=False,
        vals=nv,
        grouped=False,
        kids=kids,
    )

def _and(Condition a, Condition b) -> Condition:
    list[Condition] k = [a, b]
    return _logical(5, "AND", k)

def _or(Condition a, Condition b) -> Condition:
    list[Condition] k = [a, b]
    return _logical(6, "OR", k)

def _not(Condition a) -> Condition:
    list[Condition] k = [a]
    return _logical(7, "NOT", k)

# --- the builder: one stateful pass over the tree ---------------------------

# Placeholder counters + the ordered name/value maps. A reference struct, so the
# recursive walk threads one instance and its mutations persist.
struct _Builder:
    int64 nc
    int64 vc
    list[str] name_keys
    list[str] name_parts
    list[str] val_keys
    list[str] val_json

def _new_builder() -> _Builder:
    list[str] nk = []
    list[str] np = []
    list[str] vk = []
    list[str] vj = []
    return _Builder(nc=0, vc=0, name_keys=nk, name_parts=np, val_keys=vk, val_json=vj)

# The built expression plus its placeholder maps, in assignment order (index N in
# *_keys pairs with index N in name_parts / val_json). Rendered in this order so
# the output never depends on dict iteration order.
struct Built:
    str expression
    list[str] name_keys
    list[str] name_parts
    list[str] val_keys
    list[str] val_json

def _name_ph(_Builder b, str part) -> str:
    auto ph = "#n" + str(b.nc)
    b.nc = b.nc + 1
    b.name_keys.append(ph)
    b.name_parts.append(part)
    return ph

def _val_ph(_Builder b, AttrValue v) -> str:
    auto ph = ":v" + str(b.vc)
    b.vc = b.vc + 1
    b.val_keys.append(ph)
    b.val_json.append(_av_json(v))
    return ph

# Expand an attribute name into placeholders. Splits the name on `.` into
# document-path segments; within a segment, everything from the first `[` on
# (the list indices) is kept literal and the leading text gets one placeholder.
# Mirrors boto3's ATTR_NAME_REGEX for well-formed names (`a.b.c`, `a[0].b`).
def _build_name(_Builder b, str name) -> str:
    auto out = ""
    auto segs = name.split(".")
    auto first = True
    for seg in segs:
        if first:
            first = False
        else:
            out = out + "."
        auto bpos = seg.find("[")
        if bpos < 0:
            auto ph = _name_ph(b, seg)
            out = out + ph
        else:
            auto head = seg[0:bpos]
            auto tail = seg[bpos:len(seg)]
            if len(head) > 0:
                auto ph2 = _name_ph(b, head)
                out = out + ph2 + tail
            else:
                out = out + tail
    return out

def _subject(_Builder b, str name, bool sz) -> str:
    if sz:
        auto inner = _build_name(b, name)
        return "size(" + inner + ")"
    return _build_name(b, name)

def _render_group(_Builder b, list[AttrValue] vals) -> str:
    auto out = "("
    auto first = True
    for v in vals:
        auto ph = _val_ph(b, v)
        if first:
            out = out + ph
            first = False
        else:
            out = out + ", " + ph
    return out + ")"

# Depth-first render; each operand is bound to a local before the next so name
# placeholders are always numbered before the value(s) in the same leaf, and
# left children before right.
def _render(_Builder b, Condition c) -> str:
    if c.kind == 0:
        auto s = _subject(b, c.subj, c.subj_size)
        auto v = _val_ph(b, c.vals[0])
        return s + " " + c.op + " " + v
    if c.kind == 1:
        auto s1 = _subject(b, c.subj, c.subj_size)
        auto lo = _val_ph(b, c.vals[0])
        auto hi = _val_ph(b, c.vals[1])
        return s1 + " BETWEEN " + lo + " AND " + hi
    if c.kind == 2:
        auto nm = _build_name(b, c.subj)
        auto v2 = _val_ph(b, c.vals[0])
        return c.op + "(" + nm + ", " + v2 + ")"
    if c.kind == 3:
        auto nm3 = _build_name(b, c.subj)
        return c.op + "(" + nm3 + ")"
    if c.kind == 4:
        auto nm4 = _build_name(b, c.subj)
        auto grp = _render_group(b, c.vals)
        return nm4 + " IN " + grp
    if c.kind == 5:
        auto la = _render(b, c.kids[0])
        auto ra = _render(b, c.kids[1])
        return "(" + la + " AND " + ra + ")"
    if c.kind == 6:
        auto lo2 = _render(b, c.kids[0])
        auto ro2 = _render(b, c.kids[1])
        return "(" + lo2 + " OR " + ro2 + ")"
    auto inner = _render(b, c.kids[0])
    return "(NOT " + inner + ")"

# Build a condition into its expression string + ordered placeholder maps. This
# is the Zap counterpart of boto3's
# `ConditionExpressionBuilder.build_expression`.
def build(Condition c) -> Built:
    auto b = _new_builder()
    auto expr = _render(b, c)
    return Built(
        expression=expr,
        name_keys=b.name_keys,
        name_parts=b.name_parts,
        val_keys=b.val_keys,
        val_json=b.val_json,
    )

# --- rendering the maps (deterministic, index order) ------------------------

# `#n0=pk` lines, one per entry, in assignment order. Empty string if none.
def render_names(Built r) -> str:
    auto out = ""
    auto i = 0
    auto n = len(r.name_keys)
    while i < n:
        if i > 0:
            out = out + "\n"
        out = out + r.name_keys[i] + "=" + r.name_parts[i]
        i = i + 1
    return out

# `:v0="alice"` lines, one per entry, in assignment order. Empty string if none.
def render_values(Built r) -> str:
    auto out = ""
    auto i = 0
    auto n = len(r.val_keys)
    while i < n:
        if i > 0:
            out = out + "\n"
        out = out + r.val_keys[i] + "=" + r.val_json[i]
        i = i + 1
    return out
