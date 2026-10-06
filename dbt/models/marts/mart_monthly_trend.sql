-- Monthly volume and wait by service type, with the city side split out.
-- This mart exists because of what the pothole numbers turned out to look
-- like: volume peaks in February and the wait is shortest in February, and the
-- wait is worst in May when volume has already halved. That pattern is only
-- visible at a monthly grain, so it needs its own table rather than being
-- derived from the ward mart.

with requests as (

    select * from {{ ref('int_service_requests') }}

),

monthly as (

    select
        created_month,
        created_year,
        extract(month from created_month)                   as month_of_year,
        service_type,
        department,

        count(*)                                            as requests_opened,
        count(days_to_close)                                as requests_measurable,
        sum(case when is_open then 1 else 0 end)            as requests_still_open,

        median(days_to_close)                                as median_days_to_close,
        quantile_cont(days_to_close, 0.90)                   as p90_days_to_close,
        sum(case when days_to_close <= 7 then 1 else 0 end)
            / nullif(count(days_to_close), 0)::double        as share_closed_within_7d

    from requests
    group by created_month, created_year, service_type, department

)

select
    m.*,

    -- Same month a year earlier, so year-over-year change is in the table.
    -- The 2024 pothole off-season was far worse than 2023 and that comparison
    -- is the single most useful number in this mart.
    lag(m.median_days_to_close, 12) over (
        partition by m.service_type order by m.created_month
    )                                                       as median_days_to_close_ly,

    m.median_days_to_close - lag(m.median_days_to_close, 12) over (
        partition by m.service_type order by m.created_month
    )                                                       as median_days_change_yoy,

    m.requests_opened / nullif(
        avg(m.requests_opened) over (partition by m.service_type), 0
    )                                                       as volume_index

from monthly m
