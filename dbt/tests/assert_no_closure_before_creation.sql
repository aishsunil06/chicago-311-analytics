-- Business rule: a service request cannot be closed before it was opened.
--
-- Chicago's 311 system records closure when a crew files completion, so a
-- closed_date earlier than created_date means either a backdated entry or a
-- bad merge. If it ever appears, the median wait in every mart is silently
-- pulled down, so this is a hard failure rather than a warning.
--
-- Status at time of writing: 0 rows in the 2023-2024 slice. The test stays
-- because the defect is present in other years of this dataset and would
-- arrive with a wider extract window.

select
    sr_number,
    created_at,
    closed_at,
    days_to_close_raw
from {{ ref('int_service_requests') }}
where closed_at is not null
  and closed_at < created_at
