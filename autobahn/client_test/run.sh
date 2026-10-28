#!/usr/bin/env bash
set -o errexit
set -o nounset

docker stop fuzzingserver || true

root=$(dirname $(realpath $BASH_SOURCE))
trap "docker stop fuzzingserver || true;" EXIT

docker run --rm \
  -v "${root}/config:/config" \
  -v "${root}/reports:/reports" \
  -p 9001:9001 \
  --name fuzzingserver \
  crossbario/autobahn-testsuite &

zig build autobahn-client-test -freference-trace

if grep FAILED support/autobahn/client/reports/index.json*; then
  exit 1
else
  exit 0
fi