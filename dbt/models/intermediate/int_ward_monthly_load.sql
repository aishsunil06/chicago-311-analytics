-- Workload a ward handed the City in each month, and the median closure time
-- for the requests opened in that month. This is the grain the volume
-- hypothesis gets tested at: if backlog drives delay, then months where a ward
-- files unusually many requests should be the months its closure times get
-- worse. Keeping it monthly rather than annual gives 50 wards x 24 months =
-- 1200 observations instead of 100, which is what makes the correlation in
-- mart_volume_vs_delay worth reporting.

with requests as (

    select *
    from {{ ref('int_service_requests') }}
    where ward is not null

),

by_ward_month as (

    select
        ward,
        created_month,
        count(*)                                            as requests_opened,
        count(days_to_close)                                as requests_closed_cleanly,
        median(days_to_close)                               as median_days_to_close,
        avg(days_to_close)                                   as mean_days_to_close,
        quantile_cont(days_to_close, 0.90)                   as p90_days_to_close,
        sum(case when is_open then 1 else 0 end)             as still_open

    from requests
    group by ward, created_month

)

select
    bwm.*,
    w.ward_name,
    w.city_side,

    -- Each ward's own typical month, so a month can be described as heavy or
    -- light relative to that ward rather than relative to the city. Ward 42
    -- always outvolumes ward 19; that is a size difference, not a load spike.
    avg(bwm.requests_opened) over (partition by bwm.ward)   as ward_avg_monthly_requests,
    bwm.requests_opened
        / nullif(avg(bwm.requests_opened) over (partition by bwm.ward), 0) as load_index

from by_ward_month bwm
join {{ ref('stg_wards') }} w on w.ward = bwm.ward
