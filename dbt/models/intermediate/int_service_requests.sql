{{
    config(
        materialized = 'incremental',
        unique_key = 'sr_number',
        incremental_strategy = 'delete+insert'
    )
}}

{#
    Why incremental is the right choice here and not anywhere else in this project
    --------------------------------------------------------------------------------
    This is the only model in the project that is both large and append-mostly.
    It carries roughly 690k rows of per-request enrichment over a two-year
    window, and 311 records behave the same way in production as they do here:
    a request is created once, gets touched a few times while it is open, and
    then never changes again. Over 95% of the rows in this table are closed
    requests whose last_modified_date is months in the past. Recomputing them on
    every run is work with a known-zero result.

    The incremental filter is on last_modified_at, not created_at. Filtering on
    created_at would be wrong: a pothole opened in March and closed in
    September would be frozen at its March state forever, and the whole point
    of the project is closure duration. last_modified_at moves whenever the
    City touches the record, so it catches late closures of old requests.

    delete+insert rather than append, because a re-pulled month legitimately
    contains updated copies of rows already in the table, and append would turn
    every one of those into a duplicate. unique_key is sr_number, so an updated
    request replaces its old row.

    The marts downstream are deliberately NOT incremental. They are aggregates
    in the low thousands of rows and rebuild in under a second, so incremental
    logic there would add failure modes and save nothing.
#}

with base as (

    select * from {{ ref('stg_service_requests') }}

    {% if is_incremental() %}
        -- Only rows the City has touched since the last build, with a one-day
        -- overlap because last_modified_date is published at day granularity
        -- for some records and a strict > would skip same-timestamp updates.
        where last_modified_at >= (
            select coalesce(max(last_modified_at), '1900-01-01'::timestamp) - interval 1 day
            from {{ this }}
        )
    {% endif %}

),

deduplicated as (

    -- Defect 1 in docs/DATA_QUALITY.md: sr_number is not unique in the raw
    -- feed. Keep the most recently modified copy of each request, because that
    -- is the City's current view of it. Ties broken by closed_at so the result
    -- is deterministic rather than dependent on scan order.
    select *
    from base
    qualify row_number() over (
        partition by sr_number
        order by last_modified_at desc nulls last,
                 closed_at desc nulls last
    ) = 1

),

normalised as (

    select
        sr_number,
        sr_type                                     as service_type,
        sr_short_code                               as service_code,
        {{ normalize_label('sr_type') }}            as service_type_key,

        -- Department names in the raw feed are a mix of "Streets and
        -- Sanitation" and "DWM - Department of Water Management". Strip the
        -- acronym prefix so a dashboard legend reads consistently.
        case
            when owner_department like '% - %'
                then trim(split_part(owner_department, ' - ', 2))
            else owner_department
        end                                         as department,

        -- Defect 5: "Completed" (the overwhelming majority) and "Closed" (a
        -- single row) are the same state. Collapse them.
        case
            when {{ normalize_label('status_raw') }} in ('COMPLETED', 'CLOSED') then 'Completed'
            when {{ normalize_label('status_raw') }} = 'CANCELED' then 'Canceled'
            when {{ normalize_label('status_raw') }} = 'OPEN' then 'Open'
            else 'Unknown'
        end                                         as status,
        status_raw,

        origin,
        ward,
        ward_raw,
        community_area,
        police_district,
        zip_code,
        latitude,
        longitude,

        created_at,
        last_modified_at,
        closed_at,
        is_flagged_duplicate,
        is_legacy_record,
        parent_sr_number,
        source_file

    from deduplicated

),

enriched as (

    select
        *,

        cast(created_at as date)                            as created_date,
        date_trunc('month', created_at)                     as created_month,
        extract(year from created_at)                       as created_year,
        extract(dow from created_at)                        as created_day_of_week,

        status = 'Completed'                                as is_closed,
        status = 'Open'                                     as is_open,
        status = 'Canceled'                                 as is_canceled,

        -- Raw duration, signed. Negative values are kept here so that the
        -- defect stays visible and the singular tests can see it.
        case
            when closed_at is not null
                then {{ duration_days('created_at', 'closed_at') }}
        end                                                 as days_to_close_raw,

        -- Analysis-ready duration. NULL unless the request is genuinely closed
        -- with a closed_at that is not before its created_at. Every mart uses
        -- this column, which is why the negative rows cannot leak into a median.
        case
            when status = 'Completed'
                 and closed_at is not null
                 and closed_at >= created_at
                then {{ duration_days('created_at', 'closed_at') }}
        end                                                 as days_to_close,

        -- Age of a still-open request as of the end of the analysis window.
        -- A fixed reference date rather than current_date, so the numbers in
        -- the README do not drift every time someone re-runs the project.
        case
            when status = 'Open'
                then {{ duration_days('created_at', "'" ~ var('window_end') ~ "'::timestamp") }}
        end                                                 as days_open,

        -- Defect 6: requests sitting open for more than a year are backlog, not
        -- live work, and a department head would want them separated out.
        case
            when status = 'Open'
                 and {{ duration_days('created_at', "'" ~ var('window_end') ~ "'::timestamp") }} > {{ var('stale_open_days') }}
                then true
            when status = 'Open' then false
        end                                                 as is_stale_open,

        -- Defect 4: closure recorded before creation. Impossible, flagged.
        coalesce(closed_at < created_at, false)             as has_backwards_timestamps,

        -- Defect 7: the City calls it completed but gave no closure timestamp.
        (status = 'Completed' and closed_at is null)        as is_closed_without_timestamp,

        ward is null                                        as has_unknown_ward,
        (latitude is null or longitude is null)             as has_no_geocode

    from normalised

)

select * from enriched
where created_at >= '{{ var("window_start") }}'::timestamp
  and created_at <  '{{ var("window_end") }}'::timestamp
