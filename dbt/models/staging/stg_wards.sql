{{
    config(
        materialized = 'view'
    )
}}

-- Thin pass over the ward_reference seed. It exists so the marts have a
-- dimension to join to and so the ward column in the fact model has a real
-- relationships test to point at, rather than only a range check.

select
    cast(ward as integer)   as ward,
    trim(ward_name)         as ward_name,
    trim(city_side)         as city_side
from {{ ref('ward_reference') }}
