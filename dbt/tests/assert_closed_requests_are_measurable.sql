-- Business rule: if the City says a request is Completed, there has to be a
-- closure timestamp, otherwise the request cannot be counted in any wait-time
-- number and the closure rate reported on the dashboard is wrong.
--
-- This matters more than it looks. mart_service_type_summary publishes
-- closure_rate as requests_measurable / requests_total. If Completed requests
-- can be unmeasurable, that ratio understates performance by an unknown amount
-- and nobody looking at the dashboard can tell.
--
-- The rule is asserted with a tolerance of zero on purpose: 0 rows in this
-- slice, and if the City ever starts publishing completions without timestamps
-- the closure_rate column needs a caveat before it ships, not after.

select
    sr_number,
    service_type,
    status,
    status_raw,
    closed_at
from {{ ref('int_service_requests') }}
where status = 'Completed'
  and closed_at is null
