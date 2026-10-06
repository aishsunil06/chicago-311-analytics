"""
Load data/raw/*.csv into the DuckDB table raw.service_requests.

Why this is a separate step from dbt: this is the EL half of the pipeline. Every
column lands as VARCHAR on purpose. If DuckDB sniffed types here it would
silently coerce or reject the bad rows, and the bad rows are the point. Typing
and coercion happen in the staging models, where they are visible, tested and
documented.

Re-running is safe. The table is replaced from whatever is currently in
data/raw/, so adding a month of raw files and re-running is all it takes.
"""

from __future__ import annotations

import logging
import sys
from pathlib import Path

import duckdb

REPO_ROOT = Path(__file__).resolve().parents[1]
RAW_GLOB = (REPO_ROOT / "data" / "raw" / "sr_*.csv").as_posix()
SAMPLE_GLOB = (REPO_ROOT / "data" / "sample" / "sr_sample.csv").as_posix()
DB_PATH = REPO_ROOT / "data" / "chicago311.duckdb"

log = logging.getLogger("load_raw")


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s",
        datefmt="%H:%M:%S",
        stream=sys.stdout,
    )

    raw_files = sorted((REPO_ROOT / "data" / "raw").glob("sr_*.csv"))
    if raw_files:
        source_glob = RAW_GLOB
        log.info("loading %s raw files", len(raw_files))
    elif Path(SAMPLE_GLOB).exists():
        # A fresh clone has the committed sample but no raw pull yet. Building off
        # the sample lets dbt run and the tests execute before a 90 MB download.
        source_glob = SAMPLE_GLOB
        log.warning("no data/raw/ files found, falling back to the committed sample")
    else:
        log.error("nothing to load: run scripts/extract.py first")
        return 1

    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(str(DB_PATH))
    con.execute("CREATE SCHEMA IF NOT EXISTS raw")
    con.execute(
        """
        CREATE OR REPLACE TABLE raw.service_requests AS
        SELECT * FROM read_csv(
            ?,
            header = true,
            all_varchar = true,
            ignore_errors = false,
            filename = true
        )
        """,
        [source_glob],
    )
    n = con.execute("SELECT count(*) FROM raw.service_requests").fetchone()[0]
    cols = con.execute("SELECT count(*) FROM duckdb_columns() WHERE table_name = 'service_requests'").fetchone()[0]
    log.info("raw.service_requests: %s rows, %s columns", format(n, ","), cols)
    con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
