# Data quality findings

Every defect below was found in the 690,427 rows pulled from Chicago Open Data
dataset `v6vf-nfxy`, covering nine field-operations service request types
created between 2023-01-01 and 2024-12-31.

Counts are measured against `stg_service_requests`, which is lossless by
design. A dbt singular test, `assert_staging_preserves_raw_rowcount.sql`,
fails the build if staging ever has a different row count from the raw table,
which is what makes the numbers here trustworthy rather than measured against
an already-filtered table.

Every count is also computed by the dbt model `mart_data_quality`, so these
figures and the pipeline cannot drift apart. Reproduce the whole table with:

```sql
select defect_id, defect, affected_rows, affected_share
from main_marts.mart_data_quality
order by cast(defect_id as integer);
```

## Summary

| # | Defect | Rows | Share | Verdict |
|---|--------|-----:|------:|---------|
| 1 | Duplicate requests flagged by the City | 54,545 | 7.90% | Kept and flagged |
| 2 | Closures recorded in under 60 seconds | 75,768 | 10.97% | Kept, flagged, root cause found |
| 3 | Ward missing | 1,398 | 0.20% | Nulled, row kept |
| 4 | Closed before created | 0 | 0.00% | None in this slice, test retained |
| 5 | Closed after last modified | 7,886 | 1.14% | Benign clock artifact, test given a tolerance |
| 6 | Open longer than a year | 404 | 0.06% | Reported separately as backlog |
| 7 | Completed with no closure timestamp | 0 | 0.00% | None in this slice, test retained |
| 8 | No geocode | 728 | 0.11% | Affects map views only |
| 9 | Missing ZIP code | 249,501 | 36.14% | Documented, unused |
| 10 | Dangling parent request id | 2,822 | 0.41% | Artifact of the extract filter |

Two of these change how the analysis should be read: defect 2 and defect 5.
The rest are small or cosmetic.

---

## 1. Duplicate requests, 54,545 rows, 7.90%

The City flags a request as a duplicate when it merges it into an earlier
report of the same problem, and records the surviving request in
`parent_sr_number`.

```sql
select count(*) as duplicate_rows
from main_staging.stg_service_requests
where is_flagged_duplicate;
-- 54545
```

Worth noting what this is **not**: `sr_number` itself is unique across all
690,427 rows, so there is no row-level duplication to clean up.

```sql
select count(*) - count(distinct sr_number) as repeated_ids
from main_staging.stg_service_requests;
-- 0
```

The intermediate model still deduplicates on `sr_number`, keeping the most
recently modified copy. That is defensive rather than corrective: the
incremental model re-pulls months on demand, and an updated copy of an existing
request would otherwise land as a second row.

**Handling.** Flagged duplicates are kept in every mart. A resident reporting
the same pothole twice is still a report, and removing them would understate
how much work a ward generated. `mart_ward_service_performance` carries
`requests_duplicate` so any count can be taken with or without them.

Duplicates close more slowly than non-duplicates, not faster, which is worth
knowing before anyone proposes dropping them:

```sql
select is_flagged_duplicate, count(*), median(days_to_close)
from main_intermediate.int_service_requests
where days_to_close is not null
group by 1;
-- false  634,791   2.158 days
-- true    54,417   4.959 days
```

## 2. Closures recorded in under 60 seconds, 75,768 rows, 10.97%

This is the most consequential defect in the dataset and the one that would
have quietly ruined the analysis.

```sql
select count(*)
from main_intermediate.int_service_requests
where days_to_close < 1.0 / 1440;
-- 75768
```

No crew removes graffiti, fills a pothole or replaces a street light bulb in
under a minute. These are not service outcomes.

Concentrated almost entirely in two service types:

```sql
select service_type, count(*) as instant_closures
from main_intermediate.int_service_requests
where days_to_close < 1.0 / 1440
group by 1 order by 2 desc;
-- Graffiti Removal Request        60,421
-- Pothole in Street Complaint     12,742
-- Street Light Out Complaint       1,985
-- Tree Debris Clean-Up Request       341
-- ... remainder under 100 each
```

**Root cause.** Grouping by intake channel explains most of it in one line:

```sql
select origin, count(*) as instant_closures
from main_intermediate.int_service_requests
where days_to_close < 1.0 / 1440
group by 1 order by 2 desc limit 4;
-- Mass Entry           60,241
-- Phone Call           10,619
-- Generated In House    3,280
-- WOFromTerraGo         1,350
```

Every single request with `origin = 'Mass Entry'` behaves this way, and every
single one is a graffiti request:

```sql
select count(*) as total,
       count(*) filter (where days_to_close < 1.0/1440) as instant,
       max(days_to_close) * 86400 as slowest_seconds,
       count(distinct service_type) as service_types
from main_intermediate.int_service_requests
where origin = 'Mass Entry';
-- 60241  |  60241  |  47.0  |  1
```

60,241 of 60,241, with the slowest taking 47 seconds. This is a batch import of
graffiti work orders that were already complete when they were loaded, not
residents being served instantly. It accounts for 33% of all graffiti requests
in the window.

**Effect on the numbers.** Excluding sub-minute closures moves the medians:

| Measure | As published | Excluding sub-minute closures |
|---|---:|---:|
| Citywide median days to close | 2.49 | 3.05 |
| Graffiti median days to close | 0.75 | 0.98 |
| Pothole median days to close | 6.01 | 8.06 |

**Handling.** The rows are kept, not deleted, and the share is published as
`share_closed_under_1min` in both `mart_ward_service_performance` and
`mart_service_type_summary`. Two reasons for keeping them. First, they are real
work that really happened, just not on the timeline the timestamps claim, so
deleting them would make the city look slower than it is. Second, a reader who
sees a 0.75 day graffiti median with a 32.9% instant-closure flag next to it
can judge the number; a reader given a silently cleaned 0.98 cannot.

The README states the pothole figure both ways for this reason.

## 3. Ward missing, 1,398 rows, 0.20%

```sql
select ward_raw, count(*)
from main_staging.stg_service_requests
where ward is null
group by 1;
-- NULL  |  1398
```

All 1,398 are genuinely blank in the source. There are no out-of-range wards in
this slice: no zeros, no 51, no 999.

```sql
select count(*)
from main_staging.stg_service_requests
where ward_raw is not null
  and try_cast(ward_raw as integer) not between 1 and 50;
-- 0
```

**Handling.** The `clean_ward` macro nulls anything outside 1 to 50 rather than
dropping the row, so citywide totals stay correct while ward-level marts
exclude the unknowns. The `assert_ward_within_chicago_range` singular test
guards the macro: if someone widens the range, the build fails.

## 4. Closed before created, 0 rows

```sql
select count(*)
from main_staging.stg_service_requests
where closed_at < created_at;
-- 0
```

None in this slice. The test `assert_no_closure_before_creation.sql` is kept
anyway, and `days_to_close` refuses to populate when the condition holds, so a
wider extract window cannot pull a negative duration into a median.

## 5. Closed after last modified, 7,886 rows, 1.14%

**This is the test that failed on the raw data.** A record cannot be closed
after the last time it was touched, because closing it is a modification.

```sql
select count(*)
from main_staging.stg_service_requests
where closed_at > last_modified_at;
-- 7886
```

Before weakening the test, the magnitude of the violation was measured:

```sql
select min(d) as min_seconds, median(d) as median_seconds, max(d) as max_seconds
from (
  select epoch(closed_at) - epoch(last_modified_at) as d
  from main_staging.stg_service_requests
  where closed_at > last_modified_at
);
-- 1.0  |  1.0  |  1.0
```

Every one of the 7,886 violations is exactly one second, across all nine
service types. That is a write-ordering artifact in the City's own system,
where the closure timestamp and the modified timestamp are stamped by separate
statements, not a corrupted record.

**Handling.** The rule is kept but given a two-second tolerance in
`tests/assert_closed_not_after_last_modified.sql`, which still catches a
genuine ordering break while not firing on a one-second clock skew. The
decision and the evidence for it are written into the test file itself, so
anyone reading the test sees why the tolerance is there. The defect is recorded
here with its row count rather than being silently absorbed.

The smallest unit any mart reports is a minute, so a one-second skew changes
nothing downstream. If the magnitude had been hours, the right answer would
have been to exclude the affected requests from closure-duration measures
instead.

## 6. Open longer than a year, 404 rows, 0.06%

Measured as of the window end, 2025-01-01, not as of today, so the figure does
not drift when the project is re-run.

```sql
select service_type, count(*)
from main_intermediate.int_service_requests
where is_stale_open
group by 1 order by 2 desc;
-- Street Light Out Complaint     193
-- Abandoned Vehicle Complaint    149
-- Graffiti Removal Request        28
-- Sanitation Code Violation       15
-- ... remainder under 10 each
```

Only 1,219 requests out of 690,427 are open at all, and a third of those have
been open more than a year. Street lights dominate, which is consistent with
requests that need a pole replacement rather than a bulb.

**Handling.** Counted separately as `requests_stale_open` in
`mart_service_type_summary`. Excluded from closure-duration measures by
construction, since `days_to_close` requires a closure.

## 7. Completed with no closure timestamp, 0 rows

```sql
select count(*)
from main_staging.stg_service_requests
where status_raw in ('Completed', 'Closed')
  and closed_at is null;
-- 0
```

None in this slice, which is why `closure_rate` in
`mart_service_type_summary` can be published without a caveat.
`assert_closed_requests_are_measurable.sql` holds the line at zero so the
caveat gets added before the dashboard ships, not after.

## 8. No geocode, 728 rows, 0.11%

```sql
select count(*)
from main_staging.stg_service_requests
where latitude is null or longitude is null;
-- 728
```

**Handling.** No effect on this analysis, which uses the `ward` field rather
than point geometry. It would block a map view, which is one reason the
dashboard does not have one.

## 9. Missing ZIP code, 249,501 rows, 36.14%

```sql
select count(*) from main_staging.stg_service_requests where zip_code is null;
-- 249501
```

The largest gap in the dataset by row count, and the least important. Every ZIP
that is present is a well-formed five-digit Chicago ZIP:

```sql
select count(*)
from main_staging.stg_service_requests
where zip_code is not null
  and not regexp_matches(zip_code, '^[0-9]{5}$');
-- 0
```

The City populates ZIP inconsistently depending on intake channel.

**Handling.** Documented, not repaired. No mart uses ZIP. It is left in staging
because backfilling it from latitude and longitude would be inventing data to
fill a column nothing needs.

## 10. Dangling parent request id, 2,822 rows, 0.41%

```sql
select count(*)
from main_staging.stg_service_requests r
where r.parent_sr_number is not null
  and not exists (
    select 1 from main_staging.stg_service_requests p
    where p.sr_number = r.parent_sr_number
  );
-- 2822
```

**This one is self-inflicted and worth being honest about.** The extract keeps
only nine service types, but a duplicate request can be merged into a parent of
any type. 2,822 of the 54,545 duplicates point at a parent that was filtered
out of the pull. It is an artifact of the extract scope, not a City defect.

**Handling.** No mart joins on `parent_sr_number`, so nothing downstream breaks.
No `relationships` test was written for this column, because it would fail by
construction and a test that is expected to fail is worse than no test.

---

## Things that turned out to be clean

Worth recording, because an absence of a defect is also a finding and it stops
the next person re-checking:

- **`sr_number` is unique.** 690,427 rows, 690,427 distinct ids.
- **No unparseable timestamps.** Every `created_date` cast successfully.
- **No service-type spelling variants.** All nine types map one-to-one to a
  single `sr_short_code`, and the 2023-2024 window is after the City's 2018
  system migration, so the legacy duplicate naming is not present here. An
  earlier window would need it.
  ```sql
  select count(*) from (
    select sr_type from main_staging.stg_service_requests
    group by sr_type having count(distinct sr_short_code) > 1);
  -- 0
  ```
- **`status` has only three values**, all spelled one way: Completed (680,439),
  Canceled (8,769), Open (1,219). The wider dataset does contain a single row
  spelled "Closed" instead of "Completed", which is why the normalisation in
  `int_service_requests` collapses the two, but that row is not in this slice.
- **No community areas outside 1 to 77.**
- **No closure timestamps in the future.**

## Where the normalisation work actually was

The dirt was not where it was expected. Two columns needed real normalisation:

**`owner_department`** mixes two naming conventions, which gives a dashboard
legend two different styles for two departments:

```sql
select owner_department, count(*)
from main_staging.stg_service_requests group by 1;
-- Streets and Sanitation                 513,257
-- CDOT - Department of Transportation    177,170
```

Handled in `int_service_requests` by stripping the acronym prefix.

**`origin`** has 29 distinct values for roughly eight real intake channels,
including "Phone Call" (234,026) and "Phone" (122) as separate entries, plus
one-row categories like "Budget Town Hall Meeting" and "IMMTOWQA". The
`normalize_label` macro exists for exactly this shape of problem. `origin` is
not a grouping dimension in any mart, so it is left raw, but it is the column
that would need the most work if someone wanted to analyse intake channel.
