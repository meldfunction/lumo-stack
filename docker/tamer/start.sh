#!/bin/sh
# Runs the sign-in helper next to the lumo-tamer server. The helper restarts
# the server after a new sign-in so it picks up the fresh login.
case "$1" in
  auth) shift; exec tamer auth "$@" ;;
  cli)  shift; exec tamer "$@" ;;
esac
node /app/lumo/auth-helper.mjs &
while true; do
  tamer server
  echo "lumo-tamer exited ($?); restarting in 3s"
  sleep 3
done
