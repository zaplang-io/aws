# aws.iam — boto3-style IAM resource layer + policy collections.
#
# A hand-written ERGONOMICS module (epic #432, D-0001): the boto3
# `iam = boto3.resource('iam')` conveniences over the generated low-level IAM
# client. It gives LAZY collections — `iam.users()`, `iam.roles()`,
# `iam.policies()` — that walk the paginated `List*` operations with no manual
# `Marker` threading, thin typed resource objects over the parsed response
# shapes, and per-user / per-role policy sub-collections so boto3's
# `user.policies.all()` / `user.attached_policies.all()` read as
# `iam.user("bob").policies().all_names()` /
# `.attached_policies().all_attached()`. Nothing here re-implements signing,
# pagination, or the wire codec — it is a thin additive surface, like aws.ec2.
#
# ## Reuses the paginator engine (#436, D-0011)
# Every collection is a `paginators.Paginator`: the engine threads the IAM
# continuation `Marker` across `List*` calls and yields each page's items lazily.
# IAM signals "more pages" with `IsTruncated` + a `Marker`; the live adapter (and
# the test mock) projects each response so `Marker` is present ONLY when the page
# is truncated, which is exactly the "token absent => stop" contract the engine's
# string-token hook already implements (aws.core `next_page_json`). So IAM's
# Marker pagination needs no new engine mode — the same lazy walk aws.ec2 uses,
# with `Marker` in place of `NextToken`.
#
# ## The client SEAM (mirrors aws.ec2 / aws.batch_writer / aws.waiters)
# The generated IAM client is injected as one closure, `list_op(op, params,
# marker) -> core.Response`, so this module is independent of any one request
# builder and is driven by a mock client in tests (no live AWS). `params` is the
# decoded request-parameter dict the scoped list operations need (`UserName` /
# `RoleName` / `PathPrefix`); `marker` is the continuation token the engine
# threads. The response `body` is the parsed-DOM JSON the live adapter projects
# each IAM response into (`{"Users":[{"UserName":..,"Arn":..}, ...],
# "Marker":".."}`, or `{"PolicyNames":["name", ...]}` for the inline-policy
# lists) — the flat shape the waiter matchers and the paginator already run over;
# no nested generic collections (zaplang-io/zap#625).
#
# Depends on aws.core (bundled ahead of this file) and aws.paginators.

import core
import paginators

# The IAM continuation token member name (request param and response field) —
# `"Marker"`, inlined at the one use site (module-level constants are not v1
# surface: a top-level assignment is ZAP3016, zaplang-io/zap#459).

# ---------------------------------------------------------------------------
# Typed resource objects (thin plain-data wrappers over the parsed shape)
# ---------------------------------------------------------------------------
#
# Plain-data wrappers: the identifying scalars read out for ergonomic access,
# plus the full parsed `raw` item for anything else. They carry no closures, so
# they are cheap to yield from the lazy walk (the value shape the paginator
# yields). Sub-collections live on the `User` / `Role` HANDLES (which carry the
# seam), not on these wrappers — the aws.ec2 convention that keeps yielded rows
# closure-free.

# Read a string field out of a parsed JSON object item ("" if absent). Reuses the
# paginator engine's `field_of` DOM accessor (#436).
def item_str(JsonValue v, str name) -> str:
    Optional[JsonValue] f = paginators.field_of(v, name)
    if not f.is_some():
        return ""
    match f.unwrap():
        case JsonValue.Str(s):
            return s
        case _:
            return ""

# Render a bare string item ("" if it is not a JSON string). The inline-policy
# lists (ListUserPolicies -> PolicyNames) yield JSON strings, not objects.
def as_name(JsonValue v) -> str:
    match v:
        case JsonValue.Str(s):
            return s
        case _:
            return ""

struct IamUser:
    str user_name
    str user_id
    str arn
    JsonValue raw

struct IamRole:
    str role_name
    str role_id
    str arn
    JsonValue raw

struct IamPolicy:
    str policy_name
    str policy_id
    str arn
    JsonValue raw

# An attached (managed) policy reference: ListAttachedUserPolicies /
# ListAttachedRolePolicies return `{PolicyName, PolicyArn}` entries.
struct AttachedPolicy:
    str policy_name
    str policy_arn

def as_user(JsonValue v) -> IamUser:
    return IamUser(
        user_name=item_str(v, "UserName"),
        user_id=item_str(v, "UserId"),
        arn=item_str(v, "Arn"),
        raw=v,
    )

def as_role(JsonValue v) -> IamRole:
    return IamRole(
        role_name=item_str(v, "RoleName"),
        role_id=item_str(v, "RoleId"),
        arn=item_str(v, "Arn"),
        raw=v,
    )

def as_policy(JsonValue v) -> IamPolicy:
    return IamPolicy(
        policy_name=item_str(v, "PolicyName"),
        policy_id=item_str(v, "PolicyId"),
        arn=item_str(v, "Arn"),
        raw=v,
    )

def as_attached(JsonValue v) -> AttachedPolicy:
    return AttachedPolicy(
        policy_name=item_str(v, "PolicyName"),
        policy_arn=item_str(v, "PolicyArn"),
    )

# ---------------------------------------------------------------------------
# The lazy collection (a paginators.Paginator driver, Marker-threaded)
# ---------------------------------------------------------------------------

# A lazy collection over one IAM `List*` operation. `op` selects the operation;
# `result_key` is the page member holding the items ("Users" / "Roles" /
# "Policies" / "PolicyNames" / "AttachedPolicies"); `params` are the fixed
# request parameters the scoped lists need (UserName / RoleName / PathPrefix),
# carried into every page. `list_op` is the injected client seam.
struct IamCollection:
    str op
    str result_key
    dict[str, str] params
    fn(str, dict[str, str], str) -> core.Response list_op

    # Build the underlying paginator: a one-arg fetch closure that threads the
    # Marker through the seam with the fixed params. The fn-typed field is bound
    # to a local before the lambda captures it (the always-valid form, #163).
    def build(self) -> paginators.Paginator:
        auto op = self.op
        auto params = self.params
        fn(str, dict[str, str], str) -> core.Response lo = self.list_op
        fn(str) -> core.Response fetch = lambda tok: lo(op, params, tok)
        auto cfg = paginators.paginator_config("Marker", "Marker", self.result_key)
        return paginators.paginator(cfg, fetch)

    # Every result item across all pages as the raw parsed DOM.
    def all_raw(self) -> list[JsonValue]:
        return paginators.all_items(self.build())

    # Typed `.all()` accessors — pick the one matching how the collection was
    # built (iam.users() -> all_users(), user.policies() -> all_names(), …).
    def all_users(self) -> list[IamUser]:
        list[IamUser] out = []
        for it in self.all_raw():
            out.append(as_user(it))
        return out

    def all_roles(self) -> list[IamRole]:
        list[IamRole] out = []
        for it in self.all_raw():
            out.append(as_role(it))
        return out

    def all_policies(self) -> list[IamPolicy]:
        list[IamPolicy] out = []
        for it in self.all_raw():
            out.append(as_policy(it))
        return out

    def all_names(self) -> list[str]:
        list[str] out = []
        for it in self.all_raw():
            out.append(as_name(it))
        return out

    def all_attached(self) -> list[AttachedPolicy]:
        list[AttachedPolicy] out = []
        for it in self.all_raw():
            out.append(as_attached(it))
        return out

# ---------------------------------------------------------------------------
# The user / role handles (boto3's iam.User('bob') / iam.Role('r'))
# ---------------------------------------------------------------------------

# A user handle: the user name plus the client seam, with the inline / attached
# policy sub-collections boto3 exposes as `user.policies` / `user.attached_policies`.
struct User:
    str name
    fn(str, dict[str, str], str) -> core.Response list_op

    # Inline user policies (boto3's `user.policies.all()`): ListUserPolicies ->
    # PolicyNames (a list of names). `.all_names()` on the returned collection.
    def policies(self) -> IamCollection:
        dict[str, str] p = {}
        p["UserName"] = self.name
        return IamCollection(
            op="ListUserPolicies",
            result_key="PolicyNames",
            params=p,
            list_op=self.list_op,
        )

    # Attached managed policies (boto3's `user.attached_policies.all()`):
    # ListAttachedUserPolicies -> AttachedPolicies. `.all_attached()`.
    def attached_policies(self) -> IamCollection:
        dict[str, str] p = {}
        p["UserName"] = self.name
        return IamCollection(
            op="ListAttachedUserPolicies",
            result_key="AttachedPolicies",
            params=p,
            list_op=self.list_op,
        )

# A role handle: the role name plus the client seam, with the same inline /
# attached policy sub-collections.
struct Role:
    str name
    fn(str, dict[str, str], str) -> core.Response list_op

    def policies(self) -> IamCollection:
        dict[str, str] p = {}
        p["RoleName"] = self.name
        return IamCollection(
            op="ListRolePolicies",
            result_key="PolicyNames",
            params=p,
            list_op=self.list_op,
        )

    def attached_policies(self) -> IamCollection:
        dict[str, str] p = {}
        p["RoleName"] = self.name
        return IamCollection(
            op="ListAttachedRolePolicies",
            result_key="AttachedPolicies",
            params=p,
            list_op=self.list_op,
        )

# ---------------------------------------------------------------------------
# The resource handle (boto3's iam = boto3.resource('iam'))
# ---------------------------------------------------------------------------

# The IAM resource handle: the client seam plus the collection + handle
# factories. Built from a generated IAM client by the live adapter, or from a
# mock in tests.
struct IamResource:
    fn(str, dict[str, str], str) -> core.Response list_op

    # A fresh collection over a top-level List* operation (no scoping params).
    def collection(self, str op, str result_key) -> IamCollection:
        dict[str, str] empty = {}
        return IamCollection(
            op=op,
            result_key=result_key,
            params=empty,
            list_op=self.list_op,
        )

    def users(self) -> IamCollection:
        return self.collection("ListUsers", "Users")

    def roles(self) -> IamCollection:
        return self.collection("ListRoles", "Roles")

    def policies(self) -> IamCollection:
        return self.collection("ListPolicies", "Policies")

    # Resource handles for a named user / role (boto3's iam.User(name) /
    # iam.Role(name)) with policy sub-collections.
    def user(self, str name) -> User:
        return User(name=name, list_op=self.list_op)

    def role(self, str name) -> Role:
        return Role(name=name, list_op=self.list_op)

# Construct a resource handle from the list client seam.
def iam_resource(fn(str, dict[str, str], str) -> core.Response list_op) -> IamResource:
    return IamResource(list_op=list_op)
