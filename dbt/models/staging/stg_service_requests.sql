{{
    config(
        materialized = 'view'
    )
}}

-- Staging does renames and typing only. No filtering, no deduplication, no
-- business logic. The row count out of here must equal the row count in
-- raw.service_requests, which the singular test
-- tests/assert_staging_preserves_raw_rowcount.sql enforces. Keeping staging
-- lossless means the data-quality counts in docs/DATA_QUALITY.md can be
-- reproduced against this model rather than against a CSV glob.

with source as (

    select * from {{ source('raw', 'service_requests') }}

),

typed as (

    select
        trim(sr_number)                                     as sr_number,
        trim(sr_type)                                       as sr_type,
        trim(sr_short_code)                                  as sr_short_code,
        trim(owner_department)                               as owner_department,
        trim(status)                                         as status_raw,
        trim(origin)                                         as origin,

        try_cast(created_date as timestamp)                  as created_at,
        try_cast(last_modified_date as timestamp)            as last_modified_at,
        try_cast(closed_date as timestamp)                   as closed_at,

        -- The API returns the literal strings 'true' and 'false', not booleans.
        case lower(trim(duplicate))
            when 'true' then true
            when 'false' then false
        end                                                  as is_flagged_duplicate,
        case lower(trim(legacy_record))
            when 'true' then true
            when 'false' then false
        end                                                  as is_legacy_record,
        nullif(trim(parent_sr_number), '')                   as parent_sr_number,

        -- Ward is kept twice: the raw string so the defect is still countable
        -- downstream, and the cleaned integer for joining and grouping.
        nullif(trim(ward), '')                               as ward_raw,
        {{ clean_ward('ward') }}                             as ward,

        try_cast(trim(community_area) as integer)            as community_area,
        nullif(trim(police_district), '')                    as police_district,
        nullif(trim(zip_code), '')                           as zip_code,
        nullif(trim(street_address), '')                     as street_address,

        try_cast(latitude as double)                         as latitude,
        try_cast(longitude as double)                        as longitude,

        nullif(trim(filename), '')                           as source_file

    from source

)

select * from typed
