# aws.marshal — native <-> DynamoDB AttributeValue marshalling (ergonomics epic
# #432, ticket #434).
#
# The Zap counterpart of `boto3.dynamodb.types.TypeSerializer` /
# `TypeDeserializer`: it turns a native Zap value into the DynamoDB
# `AttributeValue` wire shape and back, so callers of the generated DynamoDB
# client pass and read native data instead of hand-building `{"S": ...}` maps.
#
#   serialize(s("alice"))                 -> {"S":"alice"}
#   serialize(m(["age"], [n_int(30)]))    -> {"M":{"age":{"N":"30"}}}
#   deserialize("{\"N\":\"30\"}")          -> Value.N("30")
#
# WHY HAND-WRITTEN (D-0001, generated-is-product): the generated per-service
# clients are the shipping SDK, but boto3's resource-layer conveniences are not
# derivable from botocore models. This is the second hand-written ergonomics
# module, after `conditions` (#433); it owns the native<->AttributeValue seam
# that #433 left open (its `AttrValue` scalar bridges in via `from_scalar`), so
# the `ExpressionAttributeValues` a condition produces flow through this
# marshaller into the wire form.
#
# ORACLE: the output byte-matches `boto3.dynamodb.types.TypeSerializer` for the
# types it supports (plus the awsJson wire base64 for blobs — boto3's
# TypeSerializer leaves `B`/`BS` as raw bytes, which botocore then base64-encodes
# on the wire; we emit the wire form directly). `tests/marshal.main.zap` +
# `tests/expected/marshal.expected` pin vectors generated straight from boto3;
# `tools/gen_marshal_vectors.py` regenerates the expected file from the installed
# boto3 and cross-checks a pure-Python mirror. Matching facts worth stating:
#   * Map members keep caller / insertion order (boto3 iterates the dict in
#     order); we preserve the parallel key/value list order. On DESERIALIZE a map
#     has no inherent order, so we canonicalize its keys to sorted order.
#   * Set types (SS/NS/BS) are unordered in boto3 — it iterates a Python `set`,
#     whose order is arbitrary. We canonicalize by SORTING the rendered element
#     tokens, and the oracle sorts identically, so the pinned bytes are stable.
#   * Numbers ride as decimal STRINGS under `N` (DynamoDB's wire form). The
#     byte-matched constructors are `n_int` (exact) and `n_str` (an exact decimal
#     string, the path `conditions.N` feeds). See DECISIONS.md D-0010 on the
#     `n_float` divergence (boto3 REJECTS raw float; Zap has native float, so we
#     accept it and format via the native `str(float)`).
#   * No JSON string escaping on this hand path (matches `dynamodb.zap` /
#     `conditions.zap`): keep values free of characters that need JSON escaping
#     until a shared escaping pass lands. The oracle vectors honour this.

import base64
import conditions
import json

# --- Value: the native marshallable value model -----------------------------

# One DynamoDB-marshallable native value. Scalars carry their payload; `L` is a
# list of values; `M` carries parallel key/value lists (insertion order = wire
# order, like `cbor.CborValue.Map`); the set variants carry their elements.
# Numbers ride as decimal strings (`N`/`NS`), blobs as raw `bytes` (`B`/`BS`),
# base64-encoded only at the wire.
enum Value:
    S(str s)
    N(str n)
    Bool(bool b)
    Null
    B(bytes b)
    L(list[Value] items)
    M(list[str] keys, list[Value] vals)
    SS(list[str] items)
    NS(list[str] items)
    BS(list[bytes] items)

# --- native constructors (the ergonomic surface) ----------------------------

# String: `s("alice")` -> `{"S":"alice"}`.
def s(str v) -> Value:
    return Value.S(v)

# Number from a native int: `n_int(30)` -> `{"N":"30"}`. Exact — `str(int64)` is
# the same decimal digits boto3's `str(Decimal(int))` produces.
def n_int(int64 v) -> Value:
    return Value.N(str(v))

# Number from an exact decimal string: `n_str("3.14")` -> `{"N":"3.14"}`. The
# byte-exact numeric path (no float rounding), and the one `conditions.N` feeds.
def n_str(str digits) -> Value:
    return Value.N(digits)

# Number from a native float: `n_float(3.14)` -> `{"N":"3.14"}`. DIVERGENCE:
# boto3's TypeSerializer REJECTS raw float (requires Decimal); Zap has native
# float, so we accept it and format via the native `str(float)`. Prefer `n_str`
# when you need exact control over the digits. See DECISIONS.md D-0010.
def n_float(float64 v) -> Value:
    return Value.N(str(v))

# Boolean: `boolean(True)` -> `{"BOOL":true}`.
def boolean(bool v) -> Value:
    return Value.Bool(v)

# Null: `null()` -> `{"NULL":true}`.
def null() -> Value:
    return Value.Null

# Binary: `b(data)` -> `{"B":"<base64>"}`.
def b(bytes v) -> Value:
    return Value.B(v)

# List: `l([s("a"), n_int(1)])` -> `{"L":[{"S":"a"},{"N":"1"}]}`.
def l(list[Value] items) -> Value:
    return Value.L(items)

# Map: `m(["age"], [n_int(30)])` -> `{"M":{"age":{"N":"30"}}}`. `keys[i]` ->
# `vals[i]`, emitted in this order (boto3 preserves dict insertion order).
def m(list[str] keys, list[Value] vals) -> Value:
    return Value.M(keys, vals)

# String set: `ss(["a", "b"])` -> `{"SS":["a","b"]}` (elements sorted on output).
def ss(list[str] items) -> Value:
    return Value.SS(items)

# Number set: `ns(["1", "2"])` -> `{"NS":["1","2"]}` (decimal strings, sorted).
def ns(list[str] items) -> Value:
    return Value.NS(items)

# Binary set: `bs([d1, d2])` -> `{"BS":["<b64>","<b64>"]}` (sorted by base64).
def bs(list[bytes] items) -> Value:
    return Value.BS(items)

# Bridge the #433 condition-builder scalar (`conditions.AttrValue`) into a
# marshal `Value`, so a condition's `ExpressionAttributeValues` flow through this
# marshaller to the wire form. AttrValue kinds: 0=string 1=number 2=bool 3=null.
def from_scalar(conditions.AttrValue av) -> Value:
    if av.kind == 0:
        return Value.S(av.sv)
    if av.kind == 1:
        return Value.N(av.sv)
    if av.kind == 2:
        return Value.Bool(av.bv)
    return Value.Null

# --- serialize: native Value -> AttributeValue wire JSON ---------------------

# A JSON string literal. No escaping on this hand path (see the module header);
# values must be free of characters that need JSON escaping.
def _jstr(str v) -> str:
    return "\"" + v + "\""

def _jbool(bool v) -> str:
    if v:
        return "true"
    return "false"

# `[v0,v1,...]` of serialized element Values.
def _jarray(list[Value] items) -> str:
    auto out = "["
    auto first = True
    for it in items:
        if first:
            first = False
        else:
            out = out + ","
        out = out + serialize(it)
    return out + "]"

# `{"k0":v0,"k1":v1}` in caller order (index i pairs key with value).
def _jmap(list[str] keys, list[Value] vals) -> str:
    auto out = "{"
    auto i = 0
    auto n = len(keys)
    while i < n:
        if i > 0:
            out = out + ","
        out = out + _jstr(keys[i]) + ":" + serialize(vals[i])
        i = i + 1
    return out + "}"

# `["a","b"]` of quoted strings, SORTED — the canonical (stable) order for the
# unordered DynamoDB set types.
def _jstrset(list[str] items) -> str:
    auto out = "["
    auto first = True
    for item in sorted(items):
        if first:
            first = False
        else:
            out = out + ","
        out = out + _jstr(item)
    return out + "]"

# A binary set: base64-encode each blob, then render as a sorted string set.
def _jbytesset(list[bytes] items) -> str:
    list[str] encoded = []
    for blob in items:
        encoded.append(base64.encode(blob))
    return _jstrset(encoded)

# Serialize a native `Value` to its DynamoDB AttributeValue wire JSON. The
# counterpart of boto3's `TypeSerializer.serialize`.
def serialize(Value v) -> str:
    match v:
        case Value.S(sv):
            return "{\"S\":" + _jstr(sv) + "}"
        case Value.N(nv):
            return "{\"N\":" + _jstr(nv) + "}"
        case Value.Bool(bv):
            return "{\"BOOL\":" + _jbool(bv) + "}"
        case Value.Null:
            return "{\"NULL\":true}"
        case Value.B(bb):
            return "{\"B\":" + _jstr(base64.encode(bb)) + "}"
        case Value.L(items):
            return "{\"L\":" + _jarray(items) + "}"
        case Value.M(keys, vals):
            return "{\"M\":" + _jmap(keys, vals) + "}"
        case Value.SS(sitems):
            return "{\"SS\":" + _jstrset(sitems) + "}"
        case Value.NS(nitems):
            return "{\"NS\":" + _jstrset(nitems) + "}"
        case Value.BS(bitems):
            return "{\"BS\":" + _jbytesset(bitems) + "}"

# --- deserialize: AttributeValue wire JSON -> native Value -------------------

# The string carried by a JSON scalar (empty if not a JSON string).
def _as_str(JsonValue v) -> str:
    match v:
        case JsonValue.Str(sv):
            return sv
        case _:
            return ""

# The bool carried by a JSON scalar (False if not a JSON bool).
def _as_bool(JsonValue v) -> bool:
    match v:
        case JsonValue.Bool(bv):
            return bv
        case _:
            return False

# The elements of a JSON array mapped through `_from_json` (empty if not array).
def _arr_to_values(JsonValue v) -> list[Value]:
    list[Value] out = []
    match v:
        case JsonValue.Array(items):
            for it in items:
                out.append(_from_json(it))
        case _:
            out = out
    return out

# The elements of a JSON array as strings (SS / NS: arrays of JSON strings).
def _arr_to_strs(JsonValue v) -> list[str]:
    list[str] out = []
    match v:
        case JsonValue.Array(items):
            for it in items:
                out.append(_as_str(it))
        case _:
            out = out
    return out

# The elements of a JSON array base64-decoded to bytes (BS).
def _arr_to_bytes(JsonValue v) -> list[bytes]:
    list[bytes] out = []
    match v:
        case JsonValue.Array(items):
            for it in items:
                out.append(base64.decode(_as_str(it)))
        case _:
            out = out
    return out

# A JSON object (the inner `M` body) -> `Value.M`, keys canonicalized to SORTED
# order (a deserialized map has no inherent order to preserve).
def _obj_to_map(JsonValue v) -> Value:
    list[str] keys = []
    list[Value] vals = []
    match v:
        case JsonValue.Object(fields):
            for k in sorted(fields.keys()):
                Optional[JsonValue] fv = fields.get(k)
                keys.append(k)
                vals.append(_from_json(fv.unwrap()))
        case _:
            keys = keys
    return Value.M(keys, vals)

# One parsed AttributeValue (a single-key JSON object) -> native `Value`. The key
# selects the type; a malformed / empty object falls back to `Null`.
def _from_json(JsonValue v) -> Value:
    match v:
        case JsonValue.Object(fields):
            Optional[JsonValue] sj = fields.get("S")
            if sj.is_some():
                return Value.S(_as_str(sj.unwrap()))
            Optional[JsonValue] nj = fields.get("N")
            if nj.is_some():
                return Value.N(_as_str(nj.unwrap()))
            Optional[JsonValue] boj = fields.get("BOOL")
            if boj.is_some():
                return Value.Bool(_as_bool(boj.unwrap()))
            Optional[JsonValue] nuj = fields.get("NULL")
            if nuj.is_some():
                return Value.Null
            Optional[JsonValue] bj = fields.get("B")
            if bj.is_some():
                return Value.B(base64.decode(_as_str(bj.unwrap())))
            Optional[JsonValue] lj = fields.get("L")
            if lj.is_some():
                return Value.L(_arr_to_values(lj.unwrap()))
            Optional[JsonValue] mj = fields.get("M")
            if mj.is_some():
                return _obj_to_map(mj.unwrap())
            Optional[JsonValue] ssj = fields.get("SS")
            if ssj.is_some():
                return Value.SS(_arr_to_strs(ssj.unwrap()))
            Optional[JsonValue] nsj = fields.get("NS")
            if nsj.is_some():
                return Value.NS(_arr_to_strs(nsj.unwrap()))
            Optional[JsonValue] bsj = fields.get("BS")
            if bsj.is_some():
                return Value.BS(_arr_to_bytes(bsj.unwrap()))
            return Value.Null
        case _:
            return Value.Null

# Deserialize an AttributeValue wire JSON string to a native `Value`. The
# counterpart of boto3's `TypeDeserializer.deserialize`.
def deserialize(str json_text) -> Value:
    return _from_json(json.loads(json_text))

# --- number accessors (the "int when integral, else float" read) ------------

# True if this N value is integral (no fraction / exponent), so `n_as_int` reads
# it losslessly. A non-integral N is read with `n_as_float` (float rounding). The
# stored form stays the exact decimal string, consistent with `dynamodb.zap`.
def n_is_integral(Value v) -> bool:
    match v:
        case Value.N(nv):
            return nv.find(".") < 0 and nv.find("e") < 0 and nv.find("E") < 0
        case _:
            return False

# The native int of an integral N value (0 for a non-N value).
def n_as_int(Value v) -> int64:
    match v:
        case Value.N(nv):
            return int(nv)
        case _:
            return 0
