#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INFRA_DIR="${SCRIPT_DIR%/scripts}"
SCHEMA_DIR="${INFRA_DIR}/schemas"
OUT_DIR="${TS_OUT_DIR:-${INFRA_DIR}/generated/ts}"

if [ ! -d "$SCHEMA_DIR" ]; then
  echo "[ERROR] Avro schemas directory not found: $SCHEMA_DIR" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

run_avro_ts() {
  echo "[INFO] Generating TS using @ovotech/avro-ts → $OUT_DIR"
  npx --yes @ovotech/avro-ts --input "$SCHEMA_DIR" --output "$OUT_DIR"
}

run_avro_to_typescript() {
  echo "[INFO] Generating TS using avro-to-typescript → $OUT_DIR"
  # avro-to-typescript CLI expects output dir via -o and list of files
  npx --yes avro-to-typescript -o "$OUT_DIR" "$SCHEMA_DIR"/*.avsc
}

ensure_node() {
  if ! command -v node >/dev/null 2>&1 || ! command -v npx >/dev/null 2>&1; then
    echo "[ERROR] Node.js + npx are required. Install from https://nodejs.org/ or via Homebrew: brew install node" >&2
    exit 1
  fi
}

ensure_node

# Prefer internal generator (no network), fallback to npx tools if explicitly requested
if [ "${TS_GENERATOR:-internal}" = "internal" ]; then
  echo "[INFO] Generating TS using internal generator (no network) → $OUT_DIR"
  SCHEMA_DIR="$SCHEMA_DIR" OUT_DIR="$OUT_DIR" node "$SCRIPT_DIR/gen-avro-ts.js"
  TOOL="internal"
else
  if run_avro_ts; then
    TOOL="avro-ts"
  else
    echo "[WARN] @ovotech/avro-ts failed, trying avro-to-typescript ..." >&2
    run_avro_to_typescript || {
      echo "[ERROR] Type generation failed with both @ovotech/avro-ts and avro-to-typescript" >&2
      exit 1
    }
    TOOL="avro-to-typescript"
  fi
fi

if [ "$TOOL" != "internal" ]; then
  # Create index.ts that re-exports all generated modules (best effort)
  INDEX="$OUT_DIR/index.ts"
  echo "// Auto-generated barrel file" > "$INDEX"
  for f in "$OUT_DIR"/*.ts; do
    bn=$(basename "$f")
    [ "$bn" = "index.ts" ] && continue
    mod=${bn%.ts}
    echo "export * from './$mod';" >> "$INDEX"
  done
fi

echo "[OK] TypeScript types generated to $OUT_DIR using $TOOL"
