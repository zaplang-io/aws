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
#   import aws_core.waiters      # generic poll-until-state waiter engine
#   import aws_core.paginators  # generic lazy page iterator (get_paginator)
#   import aws_core.middleware  # composable request/response interceptor chain
#   import aws_core.binding     # protocol-agnostic HTTP binding layer
#   import aws_core.awsjson     # awsJson 1.0/1.1 codec
#   import aws_core.restjson    # rest-json codec
#   import aws_core.restxml     # rest-xml codec
#   import aws_core.dynamic     # opt-in dynamic call() escape hatch (#365)
#   import aws_core.conditions  # DynamoDB Key/Attr condition builder (#432/#433)
#   import aws_core.marshal     # native<->AttributeValue marshalling (#432/#434)
#
# `conditions` and `marshal` are the hand-written ERGONOMICS modules (epic #432):
# boto3 resource-layer conveniences that ride on top of the generated DynamoDB
# client, not derivable from the models (D-0009, D-0010). `marshal` turns native
# Zap values into the DynamoDB AttributeValue wire shape and back (boto3's
# TypeSerializer / TypeDeserializer), and a condition's `ExpressionAttributeValues`
# flow through it. They are shipping surface, unlike the parked s3 / dynamodb
# oracle fixtures below.
#
# Zap v1 has no re-export form (D-0081 §3), so this root module exposes only the
# package version; consumers import the submodule they need. The hand-written
# `s3` / `dynamodb` service clients also live in this package but are byte-diff
# ORACLE fixtures, not part of the shipping surface (D-0001; see ../DECISIONS.md).
def version() -> str:
    return "0.1.0"
