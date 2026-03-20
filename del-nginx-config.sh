#!/bin/bash
set -e

PR_NUMBER=$1
OUTPUT="nginx/conf.d/pr-$PR_NUMBER.conf"

rm -rf "$OUTPUT"

docker compose exec nginx nginx -s reload
