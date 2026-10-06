"""
Export every mart to exports/*.csv for Tableau Public.

Why this exists: Tableau Public cannot connect to a local DuckDB file, so the
marts have to land as flat files before they can be published. The columns are
renamed to title case here rather than in the models, because a warehouse
column called "Median Days To Close" is awkward to write SQL against but is
exactly what Tableau should show in a shelf without anyone hand-editing 60
field aliases.

Written with index=False. A stray unnamed index column shows up in Tableau as a
dimension called F1 and it is the first thing that makes a dashboard look
careless.
"""

from __future__ import annotations

import logging
import re
import sys
from pathlib import Path

import duckdb

REPO_ROOT = Path(__file__).resolve().parents[1]
DB_PATH = REPO_ROOT / "data" / "chicago311.duckdb"
EXPORT_DIR = REPO_ROOT / "exports"

# Mart name mapped to the columns it is sorted by on export.
#
# Sorting is not cosmetic. The marts have no ORDER BY, and DuckDB running four
# threads returns aggregate results in whatever order the threads finish, so two
# runs over identical data produce byte-different CSVs. If these files are ever
# committed, that shows up as a diff on every rebuild for no reason. Sorting
# here makes the exports reproducible.
MARTS = {
    "mart_ward_service_performance": ["service_type", "ward"],
    "mart_service_type_summary": ["median_days_to_close"],
    "mart_volume_vs_delay": ["service_type"],
    "mart_monthly_trend": ["service_type", "created_month"],
    "mart_data_quality": ["defect_id"],
}

MART_SCHEMA = "main_marts"

# Acronyms and short forms that title-casing gets wrong.
FIXUPS = {
    "P90": "P90",
    "P10": "P10",
    "Yoy": "YoY",
    "Ly": "Last Year",
    "7d": "7 Days",
    "1min": "1 Minute",
    "Sr": "SR",
    "Corr": "Correlation",
    "Vs": "vs",
    "Id": "ID",
    "Pct": "Percent",
}

log = logging.getLogger("export_marts")


def prettify(column: str) -> str:
    """snake_case to Title Case With Readable Acronyms."""
    parts = column.split("_")
    out = []
    for part in parts:
        token = part.capitalize()
        out.append(FIXUPS.get(token, FIXUPS.get(part.upper(), token)))
    label = " ".join(out)
    # "Days To Close" reads better than "Days to Close" in a Tableau shelf, but
    # small joining words should stay lowercase.
    label = re.sub(r"\b(To|And|Of|Within|Under|Per)\b", lambda m: m.group(1).lower(), label)
    return label[0].upper() + label[1:]


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s",
        datefmt="%H:%M:%S",
        stream=sys.stdout,
    )

    if not DB_PATH.exists():
        log.error("no warehouse at %s: run dbt first", DB_PATH)
        return 1

    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(str(DB_PATH), read_only=True)

    total_rows = 0
    for mart, sort_by in MARTS.items():
        df = con.execute("select * from " + MART_SCHEMA + "." + mart).df()
        df = df.sort_values(sort_by, kind="mergesort").reset_index(drop=True)

        # Round the float measures. A median of 6.012345678901 days in a CSV is
        # false precision and makes the file bigger for no reason.
        for col in df.select_dtypes(include="float").columns:
            df[col] = df[col].round(4)

        df.columns = [prettify(c) for c in df.columns]
        out = EXPORT_DIR / (mart.replace("mart_", "") + ".csv")
        df.to_csv(out, index=False, encoding="utf-8")
        log.info("%-34s -> %-28s %6s rows, %2d cols",
                 mart, out.name, format(len(df), ","), len(df.columns))
        total_rows += len(df)

    con.close()
    log.info("EXPORT COMPLETE: %s files, %s rows total into %s",
             len(MARTS), format(total_rows, ","), EXPORT_DIR.relative_to(REPO_ROOT))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
