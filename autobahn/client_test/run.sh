#!/usr/bin/env bash

cd $(dirname $BASH_SOURCE)

docker compose up -d --wait
trap "docker compose stop" EXIT

zig build autobahn-client-test -freference-trace

cd reports

if grep FAILED ./index.json*; then
  echo 'FAILURE'
else
  echo 'NO FAILURES FOUND :)'
fi

python3 -m 'http.server' 8080
