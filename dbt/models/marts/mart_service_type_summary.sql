-- Citywide picture per service type, plus how unequal that service is across
-- wards. This is the table that answers "is the wait about the ward or about
-- the service", because it puts the service-to-service range and the
-- ward-to-ward range side by side in the same units.

with per_ward as (

    select
        service_type,
        ward,
        requests_total,
        requests_measurable,
        median_days_to_close
    from {{ ref('mart_ward_service_performance') }}
    -- Wards with very few closed requests of a type produce unstable medians,
    -- and two of them were enough to make the ward spread look 95x. Floor at
    -- 200 so the inequity numbers reported in the README are about routing and
    -- not about sample size.
    where requests_measurable >= 200

),

citywide as (

    select
        service_type,
        department,
        count(*)                                            as requests_total,
        count(days_to_close)                                as requests_measurable,
        sum(case when is_open then 1 else 0 end)            as requests_open,
        sum(case when is_stale_open then 1 else 0 end)       as requests_stale_open,
        count(days_to_close) / nullif(count(*), 0)::double   as closure_rate,
        median(days_to_close)                                as median_days_to_close,
        avg(days_to_close)                                   as mean_days_to_close,
        quantile_cont(days_to_close, 0.90)                   as p90_days_to_close,
        sum(case when days_to_close < 1.0/1440 then 1 else 0 end)
            / nullif(count(days_to_close), 0)::double        as share_closed_under_1min
    from {{ ref('int_service_requests') }}
    group by service_type, department

),

spread as (

    select
        service_type,
        count(*)                                        as wards_reported,
        quantile_cont(median_days_to_close, 0.10)        as ward_p10_median_days,
        quantile_cont(median_days_to_close, 0.90)        as ward_p90_median_days,
        min(median_days_to_close)                        as ward_fastest_median_days,
        max(median_days_to_close)                        as ward_slowest_median_days,
        -- p90/p10 rather than max/min, because max/min is one ward away
        -- from being noise.
        quantile_cont(median_days_to_close, 0.90)
            / nullif(quantile_cont(median_days_to_close, 0.10), 0) as ward_inequity_ratio,
        {{ safe_corr('requests_total', 'median_days_to_close') }} as corr_volume_vs_delay
    from per_ward
    group by service_type

),

slowest as (

    select service_type, ward, median_days_to_close
    from per_ward
    qualify row_number() over (partition by service_type order by median_days_to_close desc) = 1

),

fastest as (

    select service_type, ward, median_days_to_close
    from per_ward
    qualify row_number() over (partition by service_type order by median_days_to_close asc) = 1

)

select
    c.service_type,
    c.department,
    c.requests_total,
    c.requests_measurable,
    c.requests_open,
    c.requests_stale_open,
    c.closure_rate,
    c.median_days_to_close,
    c.mean_days_to_close,
    c.p90_days_to_close,
    c.share_closed_under_1min,
    coalesce(s.wards_reported, 0)                       as wards_reported,
    s.ward_p10_median_days,
    s.ward_p90_median_days,
    s.ward_fastest_median_days,
    s.ward_slowest_median_days,
    s.ward_inequity_ratio,

    -- Sign and size of this is the whole volume hypothesis, per service type.
    -- Positive means busier wards wait longer, which is the queueing story.
    -- Negative means busier wards are served faster, which is the opposite.
    s.corr_volume_vs_delay,

    sl.ward                                             as slowest_ward,
    sl.median_days_to_close                             as slowest_ward_median_days,
    fa.ward                                             as fastest_ward,
    fa.median_days_to_close                             as fastest_ward_median_days

from citywide c
left join spread s   on s.service_type = c.service_type
left join slowest sl on sl.service_type = c.service_type
left join fastest fa on fa.service_type = c.service_type
