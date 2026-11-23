#!/bin/sh
# Turns the user-only secret files into env vars for this process only, then starts LiteLLM.
# Keys never go into compose.yaml, the image or `docker inspect`.
set -e
s=/run/secrets
[ -r $s/cloudflare-api-key ] && CLOUDFLARE_API_KEY=$(cat $s/cloudflare-api-key) && export CLOUDFLARE_API_KEY
[ -n "$CF_ACCOUNT_ID" ] && export CLOUDFLARE_ACCOUNT_ID=$CF_ACCOUNT_ID
exec litellm --config /app/config.yaml --host 0.0.0.0 --port 4000 "$@"
