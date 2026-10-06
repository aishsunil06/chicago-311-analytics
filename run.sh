#!/usr/bin/env bash
#
# Build the whole project from nothing: extract, load, transform, test, export.
#
# Usage:
#   ./run.sh              full build, skips pages already in data/raw/
#   ./run.sh --skip-extract   reuse whatever is already in data/raw/
#   ./run.sh --quick          build off the committed 2,400 row sample only
#
set -euo pipefail

# The dbt CLI installs into the Windows Store Python user scripts directory,
# which is not on PATH. Putting it here rather than asking the reader to fix
# their PATH is what makes this script runnable on a fresh clone.
PY_SCRIPTS="/c/Users/HP/AppData/Local/Packages/PythonSoftwareFoundation.Python.3.13_qbz5n2kfra8p0/LocalCache/local-packages/Python313/Scripts"
if [ -d "$PY_SCRIPTS" ]; then
    export PATH="$PY_SCRIPTS:$PATH"
fi
# Fall back to `python -m dbt` if the CLI still is not resolvable, so the script
# does not depend on one specific Python install layout.
if command -v dbt >/dev/null 2>&1; then
    DBT="dbt"
else
    DBT="python -m dbt.cli.main"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

SKIP_EXTRACT=0
QUICK=0
for arg in "$@"; do
    case "$arg" in
        --skip-extract) SKIP_EXTRACT=1 ;;
        --quick)        QUICK=1; SKIP_EXTRACT=1 ;;
        *) echo "unknown option: $arg"; exit 1 ;;
    esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

step "1/6 Extract 311 service requests from the Socrata API"
if [ "$QUICK" = "1" ]; then
    echo "    --quick: skipping extract, will build off data/sample/sr_sample.csv"
    rm -rf data/raw
elif [ "$SKIP_EXTRACT" = "1" ]; then
    echo "    --skip-extract: reusing $(ls data/raw/sr_*.csv 2>/dev/null | wc -l) cached pages"
else
    # Idempotent. Pages already on disk are counted, not re-downloaded.
    python scripts/extract.py
fi

step "2/6 Load raw CSVs into DuckDB"
python scripts/load_raw.py

step "3/6 dbt deps and seed"
cd dbt
$DBT deps
$DBT seed

step "4/6 dbt run"
$DBT run

step "5/6 dbt test"
$DBT test

step "5b/6 dbt docs generate"
$DBT docs generate
cd "$REPO_ROOT"

step "6/6 Export marts to CSV for Tableau"
python scripts/export_marts.py

cat <<'EOF'

Build complete.

  Warehouse        data/chicago311.duckdb
  Tableau CSVs     exports/*.csv
  dbt docs         dbt/target/index.html
  Findings         README.md and docs/DATA_QUALITY.md

Launch the dashboard with:

  streamlit run dashboard/app.py

EOF
