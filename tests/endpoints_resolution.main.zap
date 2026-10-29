# Offline endpoint-resolution test — exercises aws.endpoints (#342) across the
# resolution matrix (partition / region / FIPS / dualstack / S3 virtual-vs-path
# / us-east-1 global) and prints every result verbatim.
# tests/expected/endpoints_resolution.expected pins the exact hosts, so any drift
# in the resolver fails the diff. No live AWS calls, no signing — this is the
# host-template golden that complements the byte-for-byte SigV4 vectors (which
# must stay green: the default-option hosts here match the pinned signed hosts).
#
# Run: tools/zrun.sh src/aws/core.zap src/aws/endpoints.zap \
#          tests/endpoints_resolution.main.zap

# "virtual" or "path" for an S3Endpoint's addressing style.
def style_name(bool path_style) -> str:
    if path_style:
        return "path"
    return "virtual"

# "<label> -> <host> [virtual|path]" for an S3 resolution.
def show_s3(str label, S3Endpoint ep) -> str:
    return label + " -> " + ep.host + " [" + style_name(ep.path_style) + "]"

def main():
    # --- partition for a region -----------------------------------------
    print("## partitions")
    print("us-east-1 -> " + partition_for_region("us-east-1").id)
    print("eu-west-1 -> " + partition_for_region("eu-west-1").id)
    print("cn-north-1 -> " + partition_for_region("cn-north-1").id)
    print("us-gov-west-1 -> " + partition_for_region("us-gov-west-1").id)

    # --- generic service hosts (standard / FIPS / dualstack / partition) -
    print("## service hosts")
    print(
        "dynamodb/us-east-1 -> " + resolve_service_host("dynamodb", "us-east-1", resolve_options()),
    )
    print(
        "dynamodb/us-east-1 fips -> " + resolve_service_host("dynamodb", "us-east-1", resolve_options(use_fips=True)),
    )
    print(
        "dynamodb/us-east-1 dualstack -> " + resolve_service_host("dynamodb", "us-east-1", resolve_options(use_dualstack=True)),
    )
    print(
        "dynamodb/us-east-1 fips+dualstack -> " + resolve_service_host("dynamodb", "us-east-1", resolve_options(use_dualstack=True, use_fips=True)),
    )
    print(
        "ec2/cn-north-1 -> " + resolve_service_host("ec2", "cn-north-1", resolve_options()),
    )
    print(
        "logs/cn-north-1 dualstack -> " + resolve_service_host("logs", "cn-north-1", resolve_options(use_dualstack=True)),
    )
    print(
        "sqs/us-gov-west-1 fips -> " + resolve_service_host("sqs", "us-gov-west-1", resolve_options(use_fips=True)),
    )

    # --- S3 addressing (virtual vs path, dualstack, FIPS, global) --------
    print("## s3 addressing")
    print(
        show_s3(
            "my-bucket/us-east-1",
            resolve_s3("my-bucket", "us-east-1", s3_options()),
        ),
    )
    print(
        show_s3(
            "my-bucket/us-east-1 dualstack",
            resolve_s3("my-bucket", "us-east-1", s3_options(use_dualstack=True)),
        ),
    )
    print(
        show_s3(
            "my-bucket/us-east-1 fips",
            resolve_s3("my-bucket", "us-east-1", s3_options(use_fips=True)),
        ),
    )
    print(
        show_s3(
            "my-bucket/us-east-1 fips+dualstack",
            resolve_s3(
                "my-bucket",
                "us-east-1",
                s3_options(use_dualstack=True, use_fips=True),
            ),
        ),
    )
    print(
        show_s3(
            "my-bucket/us-east-1 global",
            resolve_s3("my-bucket", "us-east-1", s3_options(use_global_endpoint=True)),
        ),
    )
    print(
        show_s3(
            "my-bucket/us-east-1 global+dualstack",
            resolve_s3(
                "my-bucket",
                "us-east-1",
                s3_options(use_global_endpoint=True, use_dualstack=True),
            ),
        ),
    )
    print(
        show_s3(
            "my-bucket/eu-west-1",
            resolve_s3("my-bucket", "eu-west-1", s3_options()),
        ),
    )
    print(
        show_s3(
            "my-bucket/cn-north-1",
            resolve_s3("my-bucket", "cn-north-1", s3_options()),
        ),
    )
    print(
        show_s3(
            "my-bucket/us-gov-west-1 fips",
            resolve_s3("my-bucket", "us-gov-west-1", s3_options(use_fips=True)),
        ),
    )
    print(
        show_s3(
            "my-bucket/us-east-1 force-path",
            resolve_s3("my-bucket", "us-east-1", s3_options(force_path_style=True)),
        ),
    )
    print(
        show_s3(
            "my-bucket/us-east-1 force-path+global",
            resolve_s3(
                "my-bucket",
                "us-east-1",
                s3_options(force_path_style=True, use_global_endpoint=True),
            ),
        ),
    )
    print(
        show_s3(
            "dotted my.bucket/us-east-1",
            resolve_s3("my.bucket", "us-east-1", s3_options()),
        ),
    )
    print(
        show_s3(
            "upper My-Bucket/us-east-1",
            resolve_s3("My-Bucket", "us-east-1", s3_options()),
        ),
    )
    print(show_s3("short ab/us-east-1", resolve_s3("ab", "us-east-1", s3_options())))

    # --- legacy shim surface (host strings the v1 names still return) ----
    print("## legacy shims")
    print("regional_host -> " + regional_host("dynamodb", "us-east-1"))
    print("s3_virtual_host -> " + s3_virtual_host("my-bucket", "us-east-1"))
    print(
        "s3_virtual_host_for -> " + s3_virtual_host_for("my-bucket", "us-east-1", default_s3_options()),
    )
    print("s3_service_host -> " + s3_service_host("us-east-1", default_s3_options()))
