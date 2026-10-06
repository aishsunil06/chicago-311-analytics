-- Business rule: Chicago has 50 wards, numbered 1 to 50. A ward of 0, 51 or
-- 999 is not a place, and a ward-level mart built on one would show a bar for
-- a district that does not exist.
--
-- The clean_ward macro is what enforces this, by nulling anything outside the
-- range instead of passing it through. This test is the guard on that macro:
-- if someone edits clean_ward and widens the range, this fails.
--
-- Checked in both directions. First, no out-of-range ward survives into the
-- fact model. Second, every non-null ward in the fact model exists in the
-- ward dimension, which the relationships test also covers but which is
-- cheap to assert here against the literal range.

select
    sr_number,
    ward_raw,
    ward,
    'ward outside 1-50' as failure_reason
from {{ ref('int_service_requests') }}
where ward is not null
  and (ward < 1 or ward > 50)

union all

select
    sr_number,
    ward_raw,
    ward,
    'ward not present in ward dimension' as failure_reason
from {{ ref('int_service_requests') }} r
where r.ward is not null
  and not exists (select 1 from {{ ref('stg_wards') }} w where w.ward = r.ward)
