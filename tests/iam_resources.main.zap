# Offline IAM resource-layer test — exercises aws.iam (boto3-style resource
# collections + per-user/role policy sub-collections over the generated IAM
# client) deterministically and pins the output in
# tests/expected/iam_resources.expected. No live AWS: a mock IAM client returns
# canned multi-page list bodies and records the (op, params) + marker it was
# called with, through the same `list_op(op, params, marker)` seam the generated
# client fills (mirrors tests/ec2_resources.main.zap).
#
# The list bodies are the FLAT parsed-DOM projection the live adapter feeds the
# paginator engine — `{"Users":[{"UserName":..,"Arn":..}, ...], "Marker":".."}` —
# with `Marker` present only on a truncated page (IAM's IsTruncated contract), so
# the engine's string-token hook threads it exactly as it threads NextToken for
# EC2. Asserts: lazy Marker-paged `users()` walk, `roles()` / `policies()` typed
# wrappers, and `iam.user("bob").policies().all_names()` /
# `.attached_policies().all_attached()` — boto3's `user.policies.all()`-style
# collections carrying the scoping UserName/RoleName param.
#
# Run: tools/run-tests.sh (via `zap run`) with the aws_core zenv active.

import aws_core.core
import aws_core.iam

# --- mock IAM client over a scripted body sequence --------------------------

struct FakeIam:
    list[str] bodies
    list[int64] cursor
    list[str] seen
    list[str] calls

def new_fake(list[str] bodies) -> FakeIam:
    return FakeIam(bodies=bodies, cursor=[0], seen=[], calls=[])

# Serialize a params dict in sorted-key order for a deterministic record.
def serialize_params(dict[str, str] params) -> str:
    list[str] parts = []
    for k in core.sorted_keys(params):
        Optional[str] v = params.get(k)
        parts.append(k + "=" + v.unwrap_or(""))
    return ";".join(parts)

# The list seam: record the marker + the (op, params) it was called with, return
# the next canned body (clamp to the last).
def fake_list(FakeIam f, str op, dict[str, str] params, str marker) -> core.Response:
    f.seen.append(marker)
    f.calls.append(op + " " + serialize_params(params))
    auto i = f.cursor[0]
    f.cursor[0] = i + 1
    auto b = f.bodies[len(f.bodies) - 1]
    if i < len(f.bodies):
        b = f.bodies[i]
    return core.Response(status=200, headers={}, body=b)

def over(FakeIam f) -> iam.IamResource:
    auto fake = f
    fn(str, dict[str, str], str) -> core.Response lo = lambda op, params, marker: fake_list(fake, op, params, marker)
    return iam.iam_resource(lo)

# --- print helpers ----------------------------------------------------------

def show_users(list[iam.IamUser] xs) -> str:
    list[str] parts = []
    for x in xs:
        parts.append(x.user_name + ":" + x.user_id)
    return " ".join(parts)

def show_markers(FakeIam f) -> str:
    list[str] parts = []
    for t in f.seen:
        if len(t) == 0:
            parts.append("-")
        else:
            parts.append(t)
    return ",".join(parts)

def main():
    # --- users: lazy Marker-paged walk -------------------------------------
    print("== users (paged) ==")
    auto f1 = new_fake(
        [
            "{\"Users\": [{\"UserName\": \"alice\", \"UserId\": \"AID1\", \"Arn\": \"arn:aws:iam::123456789012:user/alice\"}, {\"UserName\": \"bob\", \"UserId\": \"AID2\", \"Arn\": \"arn:aws:iam::123456789012:user/bob\"}], \"Marker\": \"m2\"}",
            "{\"Users\": [{\"UserName\": \"carol\", \"UserId\": \"AID3\", \"Arn\": \"arn:aws:iam::123456789012:user/carol\"}]}",
        ],
    )
    auto r1 = over(f1)
    print("items " + show_users(r1.users().all_users()))
    print("markers " + show_markers(f1))

    # --- roles -------------------------------------------------------------
    print("== roles ==")
    auto f2 = new_fake(
        [
            "{\"Roles\": [{\"RoleName\": \"app\", \"RoleId\": \"RID1\", \"Arn\": \"arn:aws:iam::123456789012:role/app\"}]}",
        ],
    )
    auto r2 = over(f2)
    list[str] rparts = []
    for role in r2.roles().all_roles():
        rparts.append(role.role_name + ":" + role.role_id)
    print("items " + " ".join(rparts))

    # --- policies ----------------------------------------------------------
    print("== policies ==")
    auto f3 = new_fake(
        [
            "{\"Policies\": [{\"PolicyName\": \"ReadOnly\", \"PolicyId\": \"PID1\", \"Arn\": \"arn:aws:iam::123456789012:policy/ReadOnly\"}]}",
        ],
    )
    auto r3 = over(f3)
    list[str] pparts = []
    for pol in r3.policies().all_policies():
        pparts.append(pol.policy_name + ":" + pol.policy_id)
    print("items " + " ".join(pparts))

    # --- user inline policies (boto3's user.policies.all()) ----------------
    print("== user inline policies ==")
    auto f4 = new_fake(["{\"PolicyNames\": [\"inline-a\", \"inline-b\"]}"])
    auto r4 = over(f4)
    print("names " + " ".join(r4.user("bob").policies().all_names()))
    print("call " + f4.calls[0])

    # --- user attached (managed) policies ----------------------------------
    print("== user attached policies ==")
    auto f5 = new_fake(
        [
            "{\"AttachedPolicies\": [{\"PolicyName\": \"AmazonS3ReadOnlyAccess\", \"PolicyArn\": \"arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess\"}]}",
        ],
    )
    auto r5 = over(f5)
    list[str] aparts = []
    for ap in r5.user("bob").attached_policies().all_attached():
        aparts.append(ap.policy_name + "=" + ap.policy_arn)
    print("attached " + " ".join(aparts))
    print("call " + f5.calls[0])

    # --- role inline policies ----------------------------------------------
    print("== role inline policies ==")
    auto f6 = new_fake(["{\"PolicyNames\": [\"role-inline\"]}"])
    auto r6 = over(f6)
    print("names " + " ".join(r6.role("app").policies().all_names()))
    print("call " + f6.calls[0])
