#!/bin/sh
# Runs the app's networking/protocol layer (JarvisNet + JarvisCore, the same code the iOS app uses) against a
# real Jarvis gateway started on a spare local port with a throwaway data directory and the project's fakes.
#
#   Harness/run_harness.sh [path-to-project-jarvis] [path-to-python-with-jarvis-installed]
#
# Needs a Swift toolchain on PATH. Never touches ~/.jarvis or the live server (port 8000).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PROJECT=${1:-$HOME/Documents/Projects/project-jarvis}
PY=${2:-$HOME/miniconda3/envs/jarvis/bin/python}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/jarvis-harness.XXXXXX")
trap 'exec 3>&- 2>/dev/null; rm -rf "$WORK"' EXIT

cd "$HERE/../Packages/JarvisCore"
swift build --product jarvis-harness >&2

mkfifo "$WORK/stdin"
# scrubbed environment: no API keys, no real home, no inherited JARVIS_* settings
env -i HOME="$WORK/home" PATH=/usr/bin:/bin SHELL=/bin/bash LANG=C.UTF-8 \
  "$PY" -I "$HERE/fake_server.py" "$PROJECT" "$WORK/data" <"$WORK/stdin" >"$WORK/out.log" 2>"$WORK/server.log" &
SERVER=$!
exec 3>"$WORK/stdin"        # holding this open keeps the server alive; closing it stops the server
i=0
until grep -q '^CODE ' "$WORK/out.log" 2>/dev/null; do
  i=$((i + 1))
  if [ $i -gt 300 ] || ! kill -0 $SERVER 2>/dev/null; then echo "fake server did not start:" >&2; cat "$WORK/server.log" >&2; exit 1; fi
  sleep 0.1
done
PORT=$(sed -n 's/^PORT //p' "$WORK/out.log")
CODE=$(sed -n 's/^CODE //p' "$WORK/out.log")
echo "fake Jarvis on 127.0.0.1:$PORT (throwaway data in $WORK)" >&2
set +e
swift run --skip-build jarvis-harness "http://127.0.0.1:$PORT" "$CODE"
STATUS=$?
exec 3>&-                   # close stdin: the server prints its STT summary and exits
wait $SERVER 2>/dev/null
grep '^STT ' "$WORK/out.log" || true
exit $STATUS
