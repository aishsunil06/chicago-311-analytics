-- How much of the variation in how long a request takes is about the ward, and
-- how much is about which service was requested?
--
-- This is the number the README's headline rests on, so it lives here as SQL
-- rather than in a notebook. Run it with:
--   dbt compile -s variance_decomposition
-- then execute the compiled file in target/compiled/... against the DuckDB file.
--
-- Method: one-way R-squared. For each grouping, predict every request's wait
-- with that group's mean and measure how much of the total sum of squares that
-- removes. Measured on log1p(days_to_close) because closure times are heavily
-- right-skewed and an untransformed R-squared would be dominated by the
-- handful of requests that took two years.
--
-- This is descriptive, not causal. Ward and service type are correlated with
-- each other (a ward with more alleys files more fly-dumping complaints), so
-- the two R-squared values do not add up to the joint one.

with base as (

    select
        ward,
        service_type,
        ln(1 + days_to_close) as y
    from {{ ref('int_service_requests') }}
    where ward is not null
      and days_to_close is not null

),

grand as (
    select avg(y) as y_bar, count(*) as n from base
),

sst as (
    select sum(power(b.y - g.y_bar, 2)) as sst
    from base b cross join grand g
),

by_service as (
    select sum(power(b.y - m.y_hat, 2)) as sse
    from base b
    join (select service_type, avg(y) as y_hat from base group by service_type) m
      on m.service_type = b.service_type
),

by_ward as (
    select sum(power(b.y - m.y_hat, 2)) as sse
    from base b
    join (select ward, avg(y) as y_hat from base group by ward) m
      on m.ward = b.ward
),

by_both as (
    select sum(power(b.y - m.y_hat, 2)) as sse
    from base b
    join (select service_type, ward, avg(y) as y_hat from base group by service_type, ward) m
      on m.service_type = b.service_type and m.ward = b.ward
)

select 'service type only' as grouping, 1 - by_service.sse / sst.sst as r_squared, grand.n as observations
from by_service cross join sst cross join grand
union all
select 'ward only', 1 - by_ward.sse / sst.sst, grand.n
from by_ward cross join sst cross join grand
union all
select 'service type and ward', 1 - by_both.sse / sst.sst, grand.n
from by_both cross join sst cross join grand
