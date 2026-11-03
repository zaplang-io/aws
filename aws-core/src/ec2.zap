# aws.ec2 — boto3-style EC2 resource layer + filter collections.
#
# A hand-written ERGONOMICS module (epic #432, D-0001): the boto3
# `ec2 = boto3.resource('ec2')` conveniences over the generated low-level EC2
# client. It gives LAZY, FILTERABLE collections — `ec2.instances`,
# `ec2.security_groups`, `ec2.volumes` — that walk the paginated `Describe*`
# operations with no manual NextToken threading, a chainable `.filter(name,
# values)` that builds EC2's `Filter.N.Name` / `Filter.N.Value.M` request
# parameters, and thin typed resource objects that wrap the parsed response
# shapes. Resource actions (start / stop / terminate) call through to the
# generated client. Nothing here re-implements signing, pagination, or the wire
# codec — it is a thin, additive surface, like aws.conditions / aws.marshal.
#
# ## Reuses the paginator engine (#436, D-0011)
# A collection is a `paginators.Paginator`: the engine threads
# `NextToken` -> `NextToken` across `Describe*` calls and yields each page's
# result items lazily. The collection supplies the fetch closure — it applies the
# accumulated `.filter(...)` params and calls the DESCRIBE SEAM — and the engine
# does the walking. `.filter(...)` returns a NEW collection (immutable, chainable,
# as in boto3), so a base collection can be refined without disturbing it.
#
# ## The client SEAM (mirrors aws.batch_writer / aws.waiters / aws.paginators)
# The generated EC2 client is injected as two closures so this module stays
# independent of any one request builder and is driven by a mock client in tests
# (no live AWS):
#   * `describe(op, filter_params, token) -> core.Response` — call a `Describe*`
#     operation with the given filters and continuation token, returning the page
#     response. Its body is the parsed-DOM JSON the paginator reads (`result_key`
#     items + a `NextToken`). EC2 is XML on the wire (the `ec2` query protocol,
#     aws.query), so the live adapter projects each describe result into this flat
#     item shape — `{"Instances":[{"InstanceId":..,"State":..}, ...],
#     "NextToken":".."}` — exactly the parsed DOM the waiter matchers already run
#     over (tests/waiters.main.zap). Nested shapes (DescribeInstances groups
#     instances under Reservations) are flattened by that adapter, not modeled as
#     nested generic collections (zaplang-io/zap#625 — list[list[T]] is not
#     lowered; every value shape here is flat).
#   * `act(action, instance_id) -> core.Response` — a resource action
#     (StartInstances / StopInstances / TerminateInstances) on one instance.
#
# Depends on aws.core (bundled ahead of this file) and aws.paginators.

import core
import paginators

# ---------------------------------------------------------------------------
# Filters: boto3's Filters=[{"Name":.., "Values":[..]}] -> EC2 request params
# ---------------------------------------------------------------------------

# One EC2 filter: a name and its accepted values (a plain list[str] field — not a
# nested generic collection, so it lowers cleanly, zap#625).
struct Ec2Filter:
    str name
    list[str] values

# Construct a filter.
def ec2_filter(str name, list[str] values) -> Ec2Filter:
    return Ec2Filter(name=name, values=values)

# Serialize a filter list into EC2's query parameters: `Filter.<i>.Name` and
# `Filter.<i>.Value.<j>` (1-based), the flat ec2-protocol encoding aws.query
# serializes on the wire (the decoded dict is handed to the describe seam, which
# the generated client percent-encodes — the same decoded-params contract s3.zap
# uses for listings).
def ec2_filter_params(list[Ec2Filter] filters) -> dict[str, str]:
    dict[str, str] params = {}
    auto fi = 1
    for f in filters:
        params["Filter." + str(fi) + ".Name"] = f.name
        auto vi = 1
        for v in f.values:
            params["Filter." + str(fi) + ".Value." + str(vi)] = v
            vi = vi + 1
        fi = fi + 1
    return params

# Return a copy of `filters` with `f` appended (list has no `.copy()`; a fresh
# list keeps `.filter()` immutable/chainable).
def append_filter(list[Ec2Filter] filters, Ec2Filter f) -> list[Ec2Filter]:
    list[Ec2Filter] out = []
    for x in filters:
        out.append(x)
    out.append(f)
    return out

# ---------------------------------------------------------------------------
# Typed resource objects (thin wrappers over the parsed response shape)
# ---------------------------------------------------------------------------
#
# Plain-data wrappers: the identifying scalars read out for ergonomic access,
# plus the full parsed `raw` item for anything else. They carry no closures, so
# they are cheap to pass around and to yield from the lazy walk (the value shape
# the paginator already yields). Actions live on `Ec2Resource` (the client
# handle), so boto3's `instance.stop()` is `ec2.stop_instance(instance.id)` here.

# Read a string field out of a parsed JSON object item ("" if absent / non-string).
# Reuses the paginator engine's `field_of` DOM accessor (#436).
def item_str(JsonValue v, str name) -> str:
    Optional[JsonValue] f = paginators.field_of(v, name)
    if not f.is_some():
        return ""
    match f.unwrap():
        case JsonValue.Str(s):
            return s
        case _:
            return ""

struct Ec2Instance:
    str instance_id
    str state
    JsonValue raw

struct Ec2SecurityGroup:
    str group_id
    str group_name
    JsonValue raw

struct Ec2Volume:
    str volume_id
    str state
    JsonValue raw

# Parsed-item -> typed wrapper. The field names are the EC2 response member names
# the describe adapter projects (InstanceId/State, GroupId/GroupName, VolumeId/
# State).
def as_instance(JsonValue v) -> Ec2Instance:
    return Ec2Instance(
        instance_id=item_str(v, "InstanceId"),
        state=item_str(v, "State"),
        raw=v,
    )

def as_security_group(JsonValue v) -> Ec2SecurityGroup:
    return Ec2SecurityGroup(
        group_id=item_str(v, "GroupId"),
        group_name=item_str(v, "GroupName"),
        raw=v,
    )

def as_volume(JsonValue v) -> Ec2Volume:
    return Ec2Volume(
        volume_id=item_str(v, "VolumeId"),
        state=item_str(v, "State"),
        raw=v,
    )

# ---------------------------------------------------------------------------
# The lazy, filterable collection (a paginators.Paginator driver)
# ---------------------------------------------------------------------------

# A lazy collection over one `Describe*` operation. `op` is passed to the describe
# seam (which operation to call); `result_key` is the page member holding the
# items ("Instances" / "SecurityGroups" / "Volumes"); `token_field` is the
# NextToken member (same name on request and response for EC2). `filters`
# accumulates `.filter(...)` calls; `describe` is the injected client seam.
struct Ec2Collection:
    str op
    str result_key
    str token_field
    list[Ec2Filter] filters
    fn(str, dict[str, str], str) -> core.Response describe

    # Return a new collection with one more filter (boto3's chainable
    # `.filter(Name=.., Values=[..])`). Immutable: the receiver is unchanged.
    def filter(self, str name, list[str] values) -> Ec2Collection:
        auto fs = append_filter(self.filters, ec2_filter(name, values))
        return Ec2Collection(
            op=self.op,
            result_key=self.result_key,
            token_field=self.token_field,
            filters=fs,
            describe=self.describe,
        )

    # Build the underlying paginator: a fetch closure that applies the current
    # filter params and threads the token through the describe seam, plus the
    # engine config. The fn-typed field is bound to a local before the lambda
    # captures it (the always-valid form, #163/D-0067); the one-arg `fetch` the
    # engine wants closes over the op + filter params.
    def build(self) -> paginators.Paginator:
        auto params = ec2_filter_params(self.filters)
        auto op = self.op
        fn(str, dict[str, str], str) -> core.Response d = self.describe
        fn(str) -> core.Response fetch = lambda tok: d(op, params, tok)
        auto cfg = paginators.paginator_config(
            self.token_field,
            self.token_field,
            self.result_key,
        )
        return paginators.paginator(cfg, fetch)

    # Every result item across all pages as the raw parsed DOM (boto3's
    # collection `.all()` at the response-shape level). Lazy page walk under the
    # hood; drained here. For a streaming typed walk, iterate `self.build().items()`
    # and map `as_instance` / `as_security_group` / `as_volume` at the call site.
    def all_raw(self) -> list[JsonValue]:
        return paginators.all_items(self.build())

    # Typed `.all()` — pick the accessor matching how the collection was built
    # (ec2.instances() -> all_instances(), etc.).
    def all_instances(self) -> list[Ec2Instance]:
        list[Ec2Instance] out = []
        for it in self.all_raw():
            out.append(as_instance(it))
        return out

    def all_security_groups(self) -> list[Ec2SecurityGroup]:
        list[Ec2SecurityGroup] out = []
        for it in self.all_raw():
            out.append(as_security_group(it))
        return out

    def all_volumes(self) -> list[Ec2Volume]:
        list[Ec2Volume] out = []
        for it in self.all_raw():
            out.append(as_volume(it))
        return out

# ---------------------------------------------------------------------------
# The resource handle (boto3's ec2 = boto3.resource('ec2'))
# ---------------------------------------------------------------------------

# The EC2 resource handle: the two client seams plus the collection factories and
# the instance actions. Built from a generated EC2 client by the live adapter, or
# from a mock in tests.
struct Ec2Resource:
    fn(str, dict[str, str], str) -> core.Response describe
    fn(str, str) -> core.Response act

    # A fresh, unfiltered collection over a Describe* operation.
    def collection(self, str op, str result_key) -> Ec2Collection:
        list[Ec2Filter] empty = []
        return Ec2Collection(
            op=op,
            result_key=result_key,
            token_field="NextToken",
            filters=empty,
            describe=self.describe,
        )

    def instances(self) -> Ec2Collection:
        return self.collection("DescribeInstances", "Instances")

    def security_groups(self) -> Ec2Collection:
        return self.collection("DescribeSecurityGroups", "SecurityGroups")

    def volumes(self) -> Ec2Collection:
        return self.collection("DescribeVolumes", "Volumes")

    # Resource actions: call through to the generated client's StartInstances /
    # StopInstances / TerminateInstances on one instance id. The fn-typed field is
    # bound to a local before the call.
    def start_instance(self, str instance_id) -> core.Response:
        fn(str, str) -> core.Response a = self.act
        return a("StartInstances", instance_id)

    def stop_instance(self, str instance_id) -> core.Response:
        fn(str, str) -> core.Response a = self.act
        return a("StopInstances", instance_id)

    def terminate_instance(self, str instance_id) -> core.Response:
        fn(str, str) -> core.Response a = self.act
        return a("TerminateInstances", instance_id)

# Construct a resource handle from the describe + act client seams.
def ec2_resource(
    fn(str, dict[str, str], str) -> core.Response describe,
    fn(str, str) -> core.Response act,
) -> Ec2Resource:
    return Ec2Resource(describe=describe, act=act)
