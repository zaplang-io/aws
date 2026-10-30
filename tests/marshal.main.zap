# Offline test for the native <-> AttributeValue marshaller (ticket #434, epic
# #432). Exercises aws.marshal end to end — the native constructors, serialize to
# the AttributeValue wire JSON, the serialize∘deserialize round-trip, the N
# accessors, and the #433 condition-value bridge — with no live AWS calls.
#
# Every vector prints a `### label / SER / RT` block: SER is serialize(value) and
# RT is serialize(deserialize(SER)), so the block proves both the forward
# serialization AND that deserialize is its inverse. The expected file is
# generated straight from boto3's TypeSerializer / TypeDeserializer by
# tools/gen_marshal_vectors.py and diffed by tools/run-tests.sh; the two must
# byte-match. Keep this vector list in lockstep with that script's VECTORS table.

import aws_core.conditions
import aws_core.marshal

def show(str label, marshal.Value v):
    print("### " + label + " ###")
    auto ser = marshal.serialize(v)
    print("SER " + ser)
    print("RT " + marshal.serialize(marshal.deserialize(ser)))

# Deserialize `{"N":text}` and print the "int when integral, else float" read.
def show_n(str text):
    auto v = marshal.deserialize("{\"N\":\"" + text + "\"}")
    if marshal.n_is_integral(v):
        print("NINT " + text + " true " + str(marshal.n_as_int(v)))
    else:
        print("NINT " + text + " false")

def main():
    show("s_basic", marshal.s("alice"))
    show("s_empty", marshal.s(""))
    show("n_int", marshal.n_int(30))
    show("n_neg", marshal.n_int(-7))
    show("n_zero", marshal.n_int(0))
    show("n_decimal", marshal.n_str("3.14"))
    show("n_decimal_neg", marshal.n_str("-0.5"))
    show("bool_true", marshal.boolean(True))
    show("bool_false", marshal.boolean(False))
    show("null", marshal.null())
    show("bytes", marshal.b(bytes([1, 2, 3])))

    list[marshal.Value] lmixed = [
        marshal.s("a"),
        marshal.n_int(1),
        marshal.boolean(True),
        marshal.null(),
    ]
    show("list_mixed", marshal.l(lmixed))

    list[marshal.Value] lempty = []
    show("list_empty", marshal.l(lempty))

    list[str] mkeys = ["age", "name"]
    list[marshal.Value] mvals = [marshal.n_int(30), marshal.s("Alice")]
    show("map_basic", marshal.m(mkeys, mvals))

    list[str] mekeys = []
    list[marshal.Value] mevals = []
    show("map_empty", marshal.m(mekeys, mevals))

    list[str] ikeys = ["city"]
    list[marshal.Value] ivals = [marshal.s("NYC")]
    list[str] pkeys = ["profile"]
    list[marshal.Value] pvals = [marshal.m(ikeys, ivals)]
    show("map_nested", marshal.m(pkeys, pvals))

    list[str] sset = ["c", "a", "b"]
    show("ss", marshal.ss(sset))

    list[str] nset = ["3", "1", "2"]
    show("ns", marshal.ns(nset))

    list[bytes] bset = [bytes([2]), bytes([1])]
    show("bs", marshal.bs(bset))

    list[str] dkeys = ["k"]
    list[str] dset = ["x", "y"]
    list[marshal.Value] dvals = [marshal.ss(dset)]
    list[marshal.Value] dlist = [marshal.m(dkeys, dvals)]
    show("deeply_nested", marshal.l(dlist))

    print("### num_accessors ###")
    show_n("30")
    show_n("-7")
    show_n("0")
    show_n("3.14")
    show_n("-0.5")

    # The #433 condition-builder scalar flows through the marshaller to the wire
    # form (conditions.AttrValue -> marshal.Value -> AttributeValue JSON).
    print("### from_scalar ###")
    conditions.AttrValue av_s = conditions.S("alice")
    print("FS S " + marshal.serialize(marshal.from_scalar(av_s)))
    conditions.AttrValue av_n = conditions.N("30")
    print("FS N " + marshal.serialize(marshal.from_scalar(av_n)))
    conditions.AttrValue av_b = conditions.Bool(True)
    print("FS BOOL " + marshal.serialize(marshal.from_scalar(av_b)))
    conditions.AttrValue av_null = conditions.Null()
    print("FS NULL " + marshal.serialize(marshal.from_scalar(av_null)))
