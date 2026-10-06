-- Business rule: the ward mart must not lose or invent requests. Its
-- requests_total summed over all rows has to equal the count of ward-attributed
-- requests in the fact model.
--
-- Worth asserting because the mart has a join to stg_wards. An inner join on a
-- ward that was missing from the seed would quietly drop a whole ward's
-- volume, the chart would still render, and the only symptom would be a
-- citywide total that is slightly too low.
--
-- Allows a difference of exactly zero.

with mart_total as (
    select sum(requests_total) as n from {{ ref('mart_ward_service_performance') }}
),
fact_total as (
    select count(*) as n from {{ ref('int_service_requests') }} where ward is not null
)
select
    mart_total.n as mart_rows,
    fact_total.n as fact_rows,
    mart_total.n - fact_total.n as difference
from mart_total
cross join fact_total
where mart_total.n != fact_total.n
