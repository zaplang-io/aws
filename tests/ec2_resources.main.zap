# Offline EC2 resource-layer test — exercises aws.ec2 (boto3-style resource
# collections + filters over the generated EC2 client) deterministically and pins
# the output in tests/expected/ec2_resources.expected. No live AWS: a mock EC2
# client returns canned multi-page describe bodies and records the filter params
# + tokens it was called with, through the same seams the generated client fills
# (mirrors tests/paginators.main.zap and tests/waiters.main.zap).
#
# The describe bodies are the FLAT parsed-DOM projection the live adapter feeds
# the paginator engine — `{"Instances":[{"InstanceId":..,"State":..}, ...],
# "NextToken":..}` — the same shape the waiter matchers run over; no nested
# generic collections (zap#625). Asserts: lazy multi-page walk with NextToken
# threading, `.filter(...)` building EC2's Filter.N.Name/Value.M params (single
# and chained), typed resource wrappers for instances/security-groups/volumes,
# streaming typed iteration, and actions calling through to the client.
#
# Run: tools/run-tests.sh (via `zap run`) with the aws_core zenv active.

import aws_core.core
import aws_core.ec2

# --- mock EC2 client over a scripted body sequence --------------------------

# Canned describe bodies + a mutable cursor, plus records of the tokens threaded,
# the serialized describe calls (op + filter params), and the actions invoked
# (single-element-list cursor so position persists across calls through the
# captured reference — the shape paginators.main.zap's Fake uses).
struct FakeEc2:
    list[str] bodies
    list[int64] cursor
    list[str] seen
    list[str] calls
    list[str] actions

def new_fake(list[str] bodies) -> FakeEc2:
    return FakeEc2(bodies=bodies, cursor=[0], seen=[], calls=[], actions=[])

# Serialize a filter-param dict in sorted-key order, so the pinned output is
# deterministic regardless of dict iteration order.
def serialize_params(dict[str, str] params) -> str:
    list[str] parts = []
    for k in core.sorted_keys(params):
        Optional[str] v = params.get(k)
        parts.append(k + "=" + v.unwrap_or(""))
    return ";".join(parts)

# The describe seam: record the token + the (op, filter params) it was called
# with, return the next canned body as a 200 (clamp to the last body).
def fake_describe(FakeEc2 f, str op, dict[str, str] params, str tok) -> core.Response:
    f.seen.append(tok)
    f.calls.append(op + " " + serialize_params(params))
    auto i = f.cursor[0]
    f.cursor[0] = i + 1
    auto b = f.bodies[len(f.bodies) - 1]
    if i < len(f.bodies):
        b = f.bodies[i]
    return core.Response(status=200, headers={}, body=b)

# The action seam: record the action + instance id, return an empty 200.
def fake_act(FakeEc2 f, str action, str instance_id) -> core.Response:
    f.actions.append(action + " " + instance_id)
    return core.Response(status=200, headers={}, body="{}")

# Build an Ec2Resource over a fake client. The fake is bound to a local before
# the lambdas capture it (the always-valid closure form).
def over(FakeEc2 f) -> ec2.Ec2Resource:
    auto fake = f
    fn(str, dict[str, str], str) -> core.Response describe = lambda op, params, tok: fake_describe(fake, op, params, tok)
    fn(str, str) -> core.Response act = lambda action, iid: fake_act(fake, action, iid)
    return ec2.ec2_resource(describe, act)

# --- print helpers ----------------------------------------------------------

def show_instances(list[ec2.Ec2Instance] xs) -> str:
    list[str] parts = []
    for x in xs:
        parts.append(x.instance_id + ":" + x.state)
    return " ".join(parts)

def show_sgs(list[ec2.Ec2SecurityGroup] xs) -> str:
    list[str] parts = []
    for x in xs:
        parts.append(x.group_id + ":" + x.group_name)
    return " ".join(parts)

def show_vols(list[ec2.Ec2Volume] xs) -> str:
    list[str] parts = []
    for x in xs:
        parts.append(x.volume_id + ":" + x.state)
    return " ".join(parts)

def show_tokens(FakeEc2 f) -> str:
    list[str] parts = []
    for t in f.seen:
        if len(t) == 0:
            parts.append("-")
        else:
            parts.append(t)
    return ",".join(parts)

# --- canned bodies ----------------------------------------------------------

def instance_pages() -> list[str]:
    return [
        "{\"Instances\": [{\"InstanceId\": \"i-1\", \"State\": \"running\"}, {\"InstanceId\": \"i-2\", \"State\": \"running\"}], \"NextToken\": \"p2\"}",
        "{\"Instances\": [{\"InstanceId\": \"i-3\", \"State\": \"running\"}]}",
    ]

def main():
    # --- instances: filtered, multi-page lazy walk -------------------------
    print("== instances (filtered, paged) ==")
    auto f1 = new_fake(instance_pages())
    auto r1 = over(f1)
    auto insts = r1.instances().filter("instance-state-name", ["running"]).all_instances()
    print("items " + show_instances(insts))
    print("tokens " + show_tokens(f1))
    print("filters " + f1.calls[0])

    # --- chained filters: two .filter(...) calls compose Filter.N params ----
    print("== chained filters ==")
    auto f2 = new_fake(instance_pages())
    auto r2 = over(f2)
    auto c2 = r2.instances().filter("instance-state-name", ["running"])
    auto c2b = c2.filter("instance-type", ["t3.micro", "t3.small"])
    auto drained = c2b.all_instances()
    print("filters " + f2.calls[0])

    # --- security groups ---------------------------------------------------
    print("== security groups ==")
    auto f3 = new_fake(
        [
            "{\"SecurityGroups\": [{\"GroupId\": \"sg-1\", \"GroupName\": \"web\"}, {\"GroupId\": \"sg-2\", \"GroupName\": \"db\"}]}",
        ],
    )
    auto r3 = over(f3)
    print("items " + show_sgs(r3.security_groups().all_security_groups()))

    # --- volumes -----------------------------------------------------------
    print("== volumes ==")
    auto f4 = new_fake(
        ["{\"Volumes\": [{\"VolumeId\": \"vol-1\", \"State\": \"available\"}]}"],
    )
    auto r4 = over(f4)
    print("items " + show_vols(r4.volumes().all_volumes()))

    # --- streaming typed iteration (lazy, at the call site) ----------------
    print("== lazy typed stream ==")
    auto f5 = new_fake(instance_pages())
    auto r5 = over(f5)
    auto stream = r5.instances()
    list[str] ids = []
    for it in stream.build().items():
        auto inst = ec2.as_instance(it)
        ids.append(inst.instance_id)
    print("stream " + " ".join(ids))

    # --- actions call through to the client --------------------------------
    print("== actions ==")
    auto f6 = new_fake(["{}"])
    auto r6 = over(f6)
    auto ign1 = r6.start_instance("i-1")
    auto ign2 = r6.stop_instance("i-2")
    auto ign3 = r6.terminate_instance("i-3")
    for a in f6.actions:
        print(a)
