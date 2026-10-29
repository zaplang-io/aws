# Offline conformance test for aws.credentials — the provider chain (#341).
#
# Exercises every provider's PURE core plus the chain-ordering selector and the
# cache/refresh math with fixtured inputs: INI text (static / session-token /
# config-file `[profile X]` sections / credentials-file precedence /
# source_profile), the metadata-and-process credential JSON, a real
# `credential_process` exec (a helper script written to a temp dir — no network,
# no live AWS), `shell_split`, `first_ok` (chain order), and `cache_is_fresh`.
# The output is pinned byte-for-byte in tests/expected/credentials_chain.expected.
#
# Run:  tools/zrun.sh src/aws/core.zap src/aws/credentials.zap \
#           tests/credentials_chain.main.zap

import os
import fs

def show(str label, CredentialRecord r):
    if r.ok:
        print(
            label + ": ok ak=" + r.access_key + " sk=" + r.secret_key + " tok=" + r.session_token + " sess=" + str(r.has_session) + " exp=" + r.expiration + " via=" + r.provider,
        )
    else:
        print(label + ": none via=" + r.provider)

def main():
    # --- Provider 1: environment variables -----------------------------------
    os.setenv("AWS_ACCESS_KEY_ID", "ENVAK")
    os.setenv("AWS_SECRET_ACCESS_KEY", "ENVSK")
    os.setenv("AWS_SESSION_TOKEN", "ENVTOK")
    show("env", provider_env())

    # --- Provider 2: shared INI + named profiles -----------------------------
    # Static keys in the default profile.
    auto cred_default = parse_ini(
        "[default]\naws_access_key_id = AKDEF\naws_secret_access_key = SKDEF\n",
    )
    show("ini.default.static", resolve_profile("default", cred_default, {}))

    # Session (temporary) keys carry the token through.
    auto cred_session = parse_ini(
        "[default]\naws_access_key_id = AKS\naws_secret_access_key = SKS\naws_session_token = TOKS\n",
    )
    show("ini.default.session", resolve_profile("default", cred_session, {}))

    # A non-default profile lives under [profile NAME] in the CONFIG file but
    # under [NAME] in the CREDENTIALS file.
    auto cfg_dev = parse_ini(
        "[profile dev]\nregion = us-west-2\naws_access_key_id = CFGAK\naws_secret_access_key = CFGSK\n",
    )
    show("ini.dev.config-only", resolve_profile("dev", {}, cfg_dev))

    # The credentials file wins over the config file for the same profile/key.
    auto cred_dev = parse_ini(
        "[dev]\naws_access_key_id = CREDAK\naws_secret_access_key = CREDSK\n",
    )
    show("ini.dev.precedence", resolve_profile("dev", cred_dev, cfg_dev))

    # source_profile basics: the derived profile borrows the SOURCE profile's
    # base credentials (the STS AssumeRole itself is deferred).
    auto cfg_src = parse_ini(
        "[profile base]\naws_access_key_id = BASEAK\naws_secret_access_key = BASESK\n[profile derived]\nrole_arn = arn:aws:iam::123456789012:role/Role\nsource_profile = base\n",
    )
    show("ini.source_profile", resolve_profile("derived", {}, cfg_src))

    # A cyclic source_profile terminates (not-found) instead of looping.
    auto cfg_cycle = parse_ini(
        "[profile a]\nrole_arn = arn:x\nsource_profile = b\n[profile b]\nrole_arn = arn:y\nsource_profile = a\n",
    )
    show("ini.source_cycle", resolve_profile("a", {}, cfg_cycle))

    # An empty / absent profile resolves to not-found.
    show("ini.missing", resolve_profile("nope", {}, {}))

    # --- The shared metadata/process credential JSON parser -------------------
    auto imds_json = "{\"Code\":\"Success\",\"Type\":\"AWS-HMAC\",\"AccessKeyId\":\"IMDSAK\",\"SecretAccessKey\":\"IMDSSK\",\"Token\":\"IMDSTOK\",\"Expiration\":\"2026-02-03T04:05:06Z\"}"
    show("parse.imds", parse_json_credentials(imds_json, "Token", "imds"))

    auto container_json = "{\"AccessKeyId\":\"CTRAK\",\"SecretAccessKey\":\"CTRSK\",\"Token\":\"CTRTOK\",\"Expiration\":\"2026-05-06T07:08:09Z\"}"
    show(
        "parse.container",
        parse_json_credentials(container_json, "Token", "container"),
    )

    auto process_json = "{\"Version\":1,\"AccessKeyId\":\"PRAK\",\"SecretAccessKey\":\"PRSK\",\"SessionToken\":\"PRTOK\",\"Expiration\":\"2030-01-01T00:00:00Z\"}"
    show("parse.process", parse_process_credentials(process_json))

    # Missing required keys → not-found.
    show(
        "parse.incomplete",
        parse_json_credentials("{\"AccessKeyId\":\"only\"}", "Token", "imds"),
    )

    # --- credential_process end-to-end (real exec of a fixtured helper) -------
    auto dir = fs.mkdtemp()
    auto helper = dir + "/cred_helper.sh"
    fs.write_file(helper, "#!/bin/sh\nprintf '%s' '" + process_json + "'\n")
    show("process.exec", run_process_credentials("/bin/sh " + helper))
    show("process.exit-nonzero", run_process_credentials("/bin/sh -c \"exit 3\""))

    # --- shell_split ----------------------------------------------------------
    auto parts = shell_split("aws-vault exec \"my profile\" --json")
    print(
        "shell_split: n=" + str(len(parts)) + " [" + parts[0] + "|" + parts[1] + "|" + parts[2] + "|" + parts[3] + "]",
    )
    auto empty_parts = shell_split("   ")
    print("shell_split.empty: n=" + str(len(empty_parts)))

    # --- container URI resolution --------------------------------------------
    os.setenv("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "/v2/credentials/abc")
    print("container_uri.relative: " + container_uri())
    os.setenv("AWS_CONTAINER_CREDENTIALS_FULL_URI", "http://localhost:8080/creds")
    print("container_uri.full-wins: " + container_uri())

    # --- Chain ordering (first success wins) ---------------------------------
    list[CredentialRecord] chain = [
        not_found("env"),
        not_found("shared-config"),
        found("WINAK", "WINSK", "", "", "container"),
        found("LATEAK", "LATESK", "", "", "imds"),
    ]
    show("first_ok", first_ok(chain))
    show("first_ok.none", first_ok([not_found("env"), not_found("imds")]))

    # --- Cache freshness / refresh math --------------------------------------
    # 2026-01-01T00:00:00Z == epoch 1767225600. Default cache skew is 300s.
    auto temp_rec = found("A", "S", "T", "2026-01-01T00:00:00Z", "imds")
    auto temp_cache = cache_store(default_cache(), temp_rec)
    print(
        "cache.temp.fresh-early: " + str(cache_is_fresh(temp_cache, 1767225600 - 1000)),
    )
    print(
        "cache.temp.stale-within-skew: " + str(cache_is_fresh(temp_cache, 1767225600 - 100)),
    )
    print("cache.temp.stale-past: " + str(cache_is_fresh(temp_cache, 1767225600 + 10)))

    auto static_cache = cache_store(default_cache(), found("A", "S", "", "", "env"))
    print("cache.static.always-fresh: " + str(cache_is_fresh(static_cache, 9999999999)))
    print("cache.empty.never-fresh: " + str(cache_is_fresh(default_cache(), 0)))
    print("expiration_epoch: " + str(expiration_epoch("2026-01-01T00:00:00Z")))
