#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "FAIL  missing required file: $1"
    fail=1
  fi
}

echo "== required files =="
for path in \
  pom.xml \
  mule-artifact.json \
  src/main/mule/global-config.xml \
  src/main/mule/global-error-handler.xml \
  src/main/mule/api-flows.xml \
  src/main/mule/scheduler-flow.xml \
  src/main/mule/migration-orchestrator.xml \
  src/main/mule/reusable-sub-flows.xml \
  src/main/mule/db-implementation.xml \
  src/main/mule/sftp-implementation.xml \
  src/main/mule/export-flow.xml \
  src/main/mule/notification-flow.xml \
  src/main/resources/dwl/inventoryValidator.dwl \
  src/main/resources/api/data-migration-api.raml \
  sql/01-schema.sql
do
  require_file "$path"
done

echo "== XML well-formed =="
python3 - <<'PY'
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

failed = 0
for path in list(Path("src").rglob("*.xml")) + [Path("pom.xml")]:
    try:
        ET.parse(path)
    except ET.ParseError as exc:
        print(f"FAIL  {path}: {exc}")
        failed += 1
if failed:
    sys.exit(1)
print(f"PASS  {len(list(Path('src').rglob('*.xml'))) + 1} XML files")
PY

echo "== YAML parse =="
python3 - <<'PY'
import sys
from pathlib import Path

try:
    import yaml  # type: ignore
except ImportError:
    yaml = None

failed = 0
files = list(Path("src/main/resources").glob("*-config.yaml"))
for path in files:
    text = path.read_text(encoding="utf-8")
    if yaml is not None:
        try:
            yaml.safe_load(text)
        except Exception as exc:  # noqa: BLE001
            print(f"FAIL  {path}: {exc}")
            failed += 1
            continue
    else:
        # Minimal fallback: reject tabs and require at least one key
        if "\t" in text:
            print(f"FAIL  {path}: contains tabs")
            failed += 1
            continue
        if ":" not in text:
            print(f"FAIL  {path}: no YAML keys found")
            failed += 1
            continue
    print(f"PASS  {path}")
if failed:
    sys.exit(1)
PY

echo "== connector guardrails =="
if grep -R --include='*.xml' -n 'xmlns:ftp=' src/main/mule; then
  echo "FAIL  FTP connector namespace found; this project must use SFTP"
  fail=1
else
  echo "PASS  no FTP connector namespace"
fi

if grep -R --include='*.xml' -n 'xmlns:sftp=' src/main/mule/sftp-implementation.xml >/dev/null; then
  echo "PASS  SFTP connector in use"
else
  echo "FAIL  SFTP connector missing from sftp-implementation.xml"
  fail=1
fi

echo "== inventory validation contract =="
python3 scripts/test_inventory_rules.py || fail=1

if [[ "$fail" -ne 0 ]]; then
  echo "Project validation failed"
  exit 1
fi

echo "Project validation passed"
