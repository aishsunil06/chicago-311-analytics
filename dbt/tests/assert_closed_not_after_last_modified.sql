-- Business rule: a record cannot be closed after the last time it was touched,
-- because closing it IS touching it.
--
-- This is the test that failed on the raw data. The naive version, with no
-- tolerance, returns 7,886 rows out of 690,427. Before weakening the test I
-- checked the magnitude of the violation:
--
--   select min(d), median(d), max(d) from (
--     select (epoch(closed_at) - epoch(last_modified_at)) as d
--     from stg_service_requests where closed_at > last_modified_at)
--
--   min = 1.0, median = 1.0, max = 1.0   (seconds)
--
-- Every single violation is exactly one second, across all nine service types.
-- That is a write-ordering artifact in the City's own system, where the closure
-- timestamp and the modified timestamp are stamped by different statements, not
-- a corrupted record. A one-second skew changes no closure duration that this
-- project reports, since the smallest unit any mart uses is a minute.
--
-- So the rule is kept but given a two-second tolerance, which still catches a
-- genuine ordering break while not firing on the clock artifact. The defect is
-- recorded as defect 5 in docs/DATA_QUALITY.md with its row count, rather than
-- being silently dropped.

select
    sr_number,
    closed_at,
    last_modified_at,
    epoch(closed_at) - epoch(last_modified_at) as seconds_after_last_modified
from {{ ref('int_service_requests') }}
where closed_at is not null
  and last_modified_at is not null
  and epoch(closed_at) - epoch(last_modified_at) > 2
