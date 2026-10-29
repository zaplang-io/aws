# Project entry point for `zap run` in project mode.
#
# The SDK proper lives in src/aws/{core,s3,dynamodb}.zap and is used by bundling
# those modules with a program's main() (the compiler does not link multiple Zap
# files yet — see FRICTION.md #1). This stub just points you at the tooling.

def main():
    print("Zap AWS SDK (hand-written S3 + DynamoDB + SigV4 core).")
    print("Run the offline tests:   tools/run-tests.sh")
    print("Run an example:          tools/zrun.sh src/aws/core.zap \\")
    print("    src/aws/dynamodb.zap examples/dynamodb_get_item.main.zap")
    print("See README.md and FRICTION.md.")
