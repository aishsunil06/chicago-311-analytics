-- The hypothesis test, as a table.
--
-- If wards wait longer because they file more requests, then (a) across wards,
-- volume and median wait should move together, and (b) within a single ward,
-- its heavier months should be its slower months. This mart computes both
-- correlations so the answer in the README is a number someone can re-derive,
-- not an assertion.
--
-- Grain: one row per service type, plus one row with service_type = 'ALL
-- SERVICES' for the citywide figure.

with panel as (

    select * from {{ ref('int_ward_monthly_load') }}
    where median_days_to_close is not null

),

-- Across-ward view: collapse each ward to a single volume and a single median.
by_ward as (

    select
        ward,
        sum(requests_opened)        as requests_total,
        median(median_days_to_close) as median_days_to_close
    from panel
    group by ward

),

all_services as (

    select
        'ALL SERVICES'                                   as service_type,
        (select count(*) from by_ward)                   as n_wards,
        (select {{ safe_corr('requests_total', 'median_days_to_close') }} from by_ward)
                                                         as corr_ward_volume_vs_delay,
        count(*)                                         as n_ward_months,
        -- Within-ward view. load_index is already normalised to each ward's own
        -- average month, so a positive correlation here means a ward genuinely
        -- slows down when its own workload spikes.
        {{ safe_corr('load_index', 'median_days_to_close') }} as corr_monthly_load_vs_delay,
        median(median_days_to_close)                     as median_days_to_close
    from panel

),

per_service_panel as (

    select
        service_type,
        ward,
        created_month,
        count(*)                                        as requests_opened,
        median(days_to_close)                            as median_days_to_close
    from {{ ref('int_service_requests') }}
    where ward is not null and days_to_close is not null
    group by service_type, ward, created_month
    having count(*) >= 10  -- a monthly median off 3 requests is not a signal

),

per_service_load as (

    select
        *,
        requests_opened / nullif(
            avg(requests_opened) over (partition by service_type, ward), 0
        ) as load_index
    from per_service_panel

),

per_service_by_ward as (

    select
        service_type,
        ward,
        sum(requests_opened)            as requests_total,
        median(median_days_to_close)     as median_days_to_close
    from per_service_load
    group by service_type, ward

),

per_service as (

    select
        l.service_type,
        (select count(*) from per_service_by_ward b where b.service_type = l.service_type)
                                                         as n_wards,
        (select {{ safe_corr('b.requests_total', 'b.median_days_to_close') }}
           from per_service_by_ward b where b.service_type = l.service_type)
                                                         as corr_ward_volume_vs_delay,
        count(*)                                         as n_ward_months,
        {{ safe_corr('l.load_index', 'l.median_days_to_close') }} as corr_monthly_load_vs_delay,
        median(l.median_days_to_close)                   as median_days_to_close
    from per_service_load l
    group by l.service_type

),

combined as (

    select service_type, n_wards, corr_ward_volume_vs_delay,
           n_ward_months, corr_monthly_load_vs_delay, median_days_to_close
    from all_services
    union all
    select service_type, n_wards, corr_ward_volume_vs_delay,
           n_ward_months, corr_monthly_load_vs_delay, median_days_to_close
    from per_service

)

select
    *,
    -- A plain-language read of the across-ward correlation, so the dashboard
    -- and the CSV export say the same thing and neither has to re-interpret it.
    case
        when corr_ward_volume_vs_delay is null then 'Not enough data'
        when corr_ward_volume_vs_delay >= 0.4  then 'Volume explains a lot'
        when corr_ward_volume_vs_delay >= 0.2  then 'Volume explains some'
        when corr_ward_volume_vs_delay > -0.2  then 'Volume explains nothing'
        else 'Busier wards are faster'
    end as volume_verdict
from combined
