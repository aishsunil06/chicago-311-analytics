"""
Pull Chicago 311 service requests from the Socrata API into data/raw/.

Dataset: v6vf-nfxy (311 Service Requests, data.cityofchicago.org)

Design notes
------------
Why chunk by calendar month instead of one deep-paginated query: Socrata degrades
badly on large $offset values, and a single 690k-row scan that dies at offset
600000 has to start over. One file per (month, page) means a crash costs at most
one page, and re-running skips anything already on disk.

Why a service-type filter: the full dataset is 3.7M rows for 2023-2024, and 54%
of that is "311 INFORMATION ONLY CALL" plus "Aircraft Noise Complaint". Neither
is a ward-serviced work order, so neither can answer a question about how long a
ward waits for work to get done. The nine types kept here are the recurring
field-operations requests that have a real open/close lifecycle.
"""

from __future__ import annotations

import argparse
import csv
import io
import logging
import sys
import time
from datetime import date
from pathlib import Path

import requests

DOMAIN = "data.cityofchicago.org"
DATASET_ID = "v6vf-nfxy"
BASE_URL = "https://" + DOMAIN + "/resource/" + DATASET_ID + ".csv"

REPO_ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = REPO_ROOT / "data" / "raw"
SAMPLE_DIR = REPO_ROOT / "data" / "sample"

START = date(2023, 1, 1)
END = date(2025, 1, 1)  # exclusive

PAGE_SIZE = 50_000
SLEEP_BETWEEN_CALLS = 0.5  # be polite to an unauthenticated public endpoint
MAX_RETRIES = 5

# Nine field-operations request types. See module docstring for why these.
SERVICE_TYPES = [
    "Graffiti Removal Request",
    "Pothole in Street Complaint",
    "Rodent Baiting/Rat Complaint",
    "Abandoned Vehicle Complaint",
    "Street Light Out Complaint",
    "Tree Debris Clean-Up Request",
    "Dead Animal Pick-Up Request",
    "Sanitation Code Violation",
    "Fly Dumping Complaint",
]

# Only the columns the models actually use. Keeping the pull narrow cuts the
# download roughly in half without losing any of the dirt the project is
# meant to document.
COLUMNS = [
    "sr_number",
    "sr_type",
    "sr_short_code",
    "owner_department",
    "status",
    "origin",
    "created_date",
    "last_modified_date",
    "closed_date",
    "duplicate",
    "legacy_record",
    "parent_sr_number",
    "community_area",
    "ward",
    "police_district",
    "zip_code",
    "street_address",
    "latitude",
    "longitude",
]

log = logging.getLogger("extract")


def next_month(d: date) -> date:
    return date(d.year + (d.month == 12), d.month % 12 + 1, 1)


def month_starts(start: date, end: date) -> list:
    out, cur = [], start
    while cur < end:
        out.append(cur)
        cur = next_month(cur)
    return out


def sql_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def build_where(lo: date, hi: date) -> str:
    types = ", ".join(sql_quote(t) for t in SERVICE_TYPES)
    return (
        "created_date >= '" + lo.isoformat() + "T00:00:00' "
        "AND created_date < '" + hi.isoformat() + "T00:00:00' "
        "AND sr_type IN (" + types + ")"
    )


def fetch_page(session, where: str, offset: int) -> str:
    """Return one page of CSV text. Retries with backoff on transient errors."""
    params = {
        "$select": ",".join(COLUMNS),
        "$where": where,
        "$order": "sr_number",  # stable sort, otherwise paging can skip or repeat rows
        "$limit": PAGE_SIZE,
        "$offset": offset,
    }
    delay = 2.0
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            resp = session.get(BASE_URL, params=params, timeout=300)
            if resp.status_code == 404:
                raise SystemExit(
                    "Dataset " + DATASET_ID + " returned 404. Find the current 311 "
                    "dataset on " + DOMAIN + " and update DATASET_ID plus the README."
                )
            if resp.status_code == 429 or resp.status_code >= 500:
                raise requests.HTTPError("HTTP " + str(resp.status_code))
            resp.raise_for_status()
            return resp.text
        except requests.RequestException as exc:
            if attempt == MAX_RETRIES:
                raise
            log.warning("page offset=%s failed (%s), retry %s in %.0fs",
                        offset, exc, attempt, delay)
            time.sleep(delay)
            delay *= 2
    raise RuntimeError("unreachable")


def count_data_rows(text: str) -> int:
    """Count CSV records, not newlines. Chicago addresses contain embedded newlines."""
    reader = csv.reader(io.StringIO(text))
    try:
        next(reader)  # header
    except StopIteration:
        return 0
    return sum(1 for _ in reader)


def extract(force: bool = False) -> int:
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    session = requests.Session()
    session.headers["User-Agent"] = "chicago-311-analytics/1.0 (portfolio project)"

    grand_total = 0
    for lo in month_starts(START, END):
        hi = next_month(lo)
        where = build_where(lo, hi)
        month_total, page = 0, 0
        while True:
            out_path = RAW_DIR / ("sr_" + lo.strftime("%Y_%m") + "_p" + str(page).zfill(2) + ".csv")
            if out_path.exists() and not force:
                n = count_data_rows(out_path.read_text(encoding="utf-8"))
                log.info("cached  %s -> %s rows", out_path.name, format(n, ","))
            else:
                text = fetch_page(session, where, page * PAGE_SIZE)
                n = count_data_rows(text)
                if n == 0 and page > 0:
                    # Nothing left in this month. Do not leave an empty file behind.
                    break
                out_path.write_text(text, encoding="utf-8")
                log.info("fetched %s -> %s rows", out_path.name, format(n, ","))
                time.sleep(SLEEP_BETWEEN_CALLS)
            month_total += n
            if n < PAGE_SIZE:
                break
            page += 1
        log.info("%s total: %s rows", lo.strftime("%Y-%m"), format(month_total, ","))
        grand_total += month_total

    n_files = len(list(RAW_DIR.glob("sr_*.csv")))
    log.info("EXTRACT COMPLETE: %s rows across %s files", format(grand_total, ","), n_files)
    write_sample()
    return grand_total


def write_sample(n: int = 2400) -> None:
    """Commit-safe slice so someone cloning the repo can see the raw shape."""
    SAMPLE_DIR.mkdir(parents=True, exist_ok=True)
    files = sorted(RAW_DIR.glob("sr_*.csv"))
    if not files:
        log.warning("no raw files, skipping sample")
        return
    out = SAMPLE_DIR / "sr_sample.csv"
    per_file = max(1, n // 12)
    step = max(1, len(files) // 12)
    written = 0
    with out.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.writer(fh)
        header_done = False
        # Spread the sample over the whole window so the sample has seasonality too.
        for path in files[::step]:
            with path.open("r", encoding="utf-8", newline="") as src:
                reader = csv.reader(src)
                header = next(reader)
                if not header_done:
                    writer.writerow(header)
                    header_done = True
                for i, row in enumerate(reader):
                    if i >= per_file:
                        break
                    writer.writerow(row)
                    written += 1
    log.info("wrote sample %s (%s rows)", out.name, format(written, ","))


def main() -> int:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-7s %(message)s",
        datefmt="%H:%M:%S",
        stream=sys.stdout,
    )
    ap = argparse.ArgumentParser(description="Extract Chicago 311 requests to data/raw/.")
    ap.add_argument("--force", action="store_true", help="re-download pages already cached")
    ap.add_argument("--sample-only", action="store_true", help="rebuild data/sample from cache only")
    args = ap.parse_args()

    if args.sample_only:
        write_sample()
        return 0
    extract(force=args.force)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
