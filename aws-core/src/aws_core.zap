# aws_core — package root module (zaplang-io/zap#283, D-0081).
#
# A bare `import aws_core` resolves here; the runtime and codecs live in the
# sibling modules, imported directly by consumers:
#
#   import aws_core.core        # SigV4 signer, Request/Response, transport,
#                               # error dispatch, pagination hooks
#   import aws_core.errors      # typed service errors (base carrier + the
#                               # per-service error-enum/classifier contract)
#   import aws_core.endpoints   # partition / region / endpoint resolution,
#                               # Endpoint + S3 addressing
#   import aws_core.credentials # boto3-style credential provider chain
#   import aws_core.retry       # standard retry mode (backoff + quota)
#   import aws_core.waiters      # poll-until-state waiter engine + Waiter handle
#   import aws_core.paginators  # generic lazy page iterator (get_paginator)
#   import aws_core.middleware  # composable request/response interceptor chain
#   import aws_core.binding     # protocol-agnostic HTTP binding layer
#   import aws_core.awsjson     # awsJson 1.0/1.1 codec
#   import aws_core.restjson    # rest-json codec
#   import aws_core.restxml     # rest-xml codec
#   import aws_core.dynamic     # opt-in dynamic call() escape hatch (#365)
#   import aws_core.conditions  # DynamoDB Key/Attr condition builder (#432/#433)
#   import aws_core.marshal     # native<->AttributeValue marshalling (#432/#434)
#   import aws_core.batch_writer # buffered DynamoDB BatchWriteItem writer (#435)
#   import aws_core.transfer    # S3 managed multipart transfer (#432/#438)
#   import aws_core.presign     # S3 presigned URL + presigned POST (#432/#439)
#   import aws_core.cloudfront  # CloudFront signed URLs & cookies (#432/#440)
#   import aws_core.ec2         # EC2 resource layer + filter collections (#432/#441)
#   import aws_core.sqs         # SQS Queue/Message + attribute MD5 (#432/#442)
#   import aws_core.sns         # SNS Topic publish helpers (#432/#442)
#   import aws_core.iam         # IAM resource layer + policy collections (#432/#443)
#   import aws_core.glacier     # Glacier SHA-256 tree-hash upload helper (#432/#444)
#
# `conditions`, `marshal`, `batch_writer`, `transfer`, `presign`, `cloudfront`,
# `ec2`, `sqs`, `sns`, `iam` and `glacier` are the hand-written ERGONOMICS
# modules (epic #432): boto3 resource-layer conveniences that ride on top of the
# generated clients, not derivable from the models (D-0009, D-0010, D-0013,
# D-0014, D-0015, D-0016, D-0017, D-0018, D-0019).
# `marshal` turns native Zap values into the DynamoDB
# AttributeValue wire shape and back (boto3's TypeSerializer / TypeDeserializer),
# and a condition's `ExpressionAttributeValues` flow through it; `transfer`
# orchestrates S3 multipart upload/download/copy over the generated S3 client and
# the aws-core streaming signer (#358); `presign` mints S3 presigned URLs and POST
# policies over the aws-core query-parameter signer (#359). `cloudfront` mints
# CloudFront signed URLs / signed cookies for private content (RSA-SHA1 over a
# policy document — not SigV4); `ec2` is the boto3 resource/collection layer over
# the generated EC2 client, reusing the paginator engine (#436) for lazy, filtered
# `Describe*` walks. `sqs` / `sns` are the messaging conveniences (Queue send /
# receive / delete with the SQS message-attribute MD5 the SDKs validate, and SNS
# Topic publish); `iam` is the boto3 resource layer with `.policies.all()`-style
# policy collections (reusing the paginator engine for IAM's Marker pagination);
# `glacier` computes the SHA-256 tree hash Glacier requires on archive uploads
# (single-shot and multipart). They are shipping surface, unlike the parked
# s3 / dynamodb oracle fixtures below.
#
# Zap v1 has no re-export form (D-0081 §3), so this root module exposes only the
# package version; consumers import the submodule they need. The hand-written
# `s3` / `dynamodb` service clients also live in this package but are byte-diff
# ORACLE fixtures, not part of the shipping surface (D-0001; see ../DECISIONS.md).
def version() -> str:
    return "0.1.0"
