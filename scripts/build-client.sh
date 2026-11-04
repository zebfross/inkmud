#!/usr/bin/env bash
# Build the Lustre client and bundle it into server/priv/static/app.js.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/client"
gleam build
mkdir -p build/bundle
printf 'import { main } from "../dev/javascript/client/client.mjs";\nmain();\n' > build/bundle/entry.mjs
npx --yes esbuild@0.25.10 build/bundle/entry.mjs --bundle --format=esm --minify \
  --log-level=warning --outfile="$ROOT/server/priv/static/app.js"
