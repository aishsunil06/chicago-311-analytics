-- Business rule about the pipeline itself: staging renames and types, it does
-- not filter. If stg_service_requests has fewer rows than raw.service_requests
-- then a cast or a trim is dropping records, and every data-quality count in
-- docs/DATA_QUALITY.md is being measured against an already-thinned table.
--
-- This is the test that makes the data-quality documentation trustworthy. The
-- counts in that file are taken from staging, and they are only honest if
-- staging is lossless.

with staged as (
    select count(*) as n from {{ ref('stg_service_requests') }}
),
raw_rows as (
    select count(*) as n from {{ source('raw', 'service_requests') }}
)
select
    staged.n as staging_rows,
    raw_rows.n as raw_rows,
    staged.n - raw_rows.n as difference
from staged
cross join raw_rows
where staged.n != raw_rows.n
