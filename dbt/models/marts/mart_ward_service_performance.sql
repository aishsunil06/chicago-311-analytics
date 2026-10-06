-- Core answer table: how long each ward waits for each service type, next to
-- how much of that service the ward asks for. One row per ward x service type.
-- Everything in the dashboard's first two views reads off this.

with requests as (

    select * from {{ ref('int_service_requests') }}
    where ward is not null

),

agg as (

    select
        ward,
        service_type,
        department,

        count(*)                                        as requests_total,
        count(days_to_close)                            as requests_measurable,
        sum(case when is_open then 1 else 0 end)        as requests_open,
        sum(case when is_canceled then 1 else 0 end)    as requests_canceled,
        sum(case when is_flagged_duplicate then 1 else 0 end) as requests_duplicate,

        median(days_to_close)                           as median_days_to_close,
        avg(days_to_close)                              as mean_days_to_close,
        quantile_cont(days_to_close, 0.90)              as p90_days_to_close,

        -- Share closed inside a week. A median hides the tail, and the tail is
        -- what generates the alderman phone call.
        sum(case when days_to_close <= 7 then 1 else 0 end)
            / nullif(count(days_to_close), 0)::double   as share_closed_within_7d,

        -- Share closed in under a minute. Not a performance number, a data
        -- quality number: see docs/DATA_QUALITY.md defect 2. Surfaced in the
        -- mart so nobody reads a 0.7 day graffiti median as a real wait.
        sum(case when days_to_close < 1.0/1440 then 1 else 0 end)
            / nullif(count(days_to_close), 0)::double   as share_closed_under_1min

    from requests
    group by ward, service_type, department

)

select
    a.ward,
    w.ward_name,
    w.city_side,
    a.service_type,
    a.department,
    a.requests_total,
    a.requests_measurable,
    a.requests_open,
    a.requests_canceled,
    a.requests_duplicate,
    a.median_days_to_close,
    a.mean_days_to_close,
    a.p90_days_to_close,
    a.share_closed_within_7d,
    a.share_closed_under_1min,

    -- Rank within the service type, so "ward 36 is slowest for potholes" is a
    -- number in the table rather than something the dashboard has to derive.
    row_number() over (
        partition by a.service_type order by a.median_days_to_close desc nulls last
    )                                                   as slowest_rank_in_service,
    row_number() over (
        partition by a.service_type order by a.requests_total desc
    )                                                   as volume_rank_in_service,

    -- How this ward compares to the city on the same service. Above 1 means
    -- slower than the typical ward for that service.
    a.median_days_to_close / nullif(
        median(a.median_days_to_close) over (partition by a.service_type), 0
    )                                                   as median_vs_city_ratio

from agg a
join {{ ref('stg_wards') }} w on w.ward = a.ward
