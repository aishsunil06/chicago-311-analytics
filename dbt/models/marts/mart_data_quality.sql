-- Every defect from docs/DATA_QUALITY.md as a row, so the counts in that doc
-- and the counts on the dashboard come from the same query and cannot drift
-- apart. Also means a reviewer can check the documented numbers without
-- opening a SQL client.
--
-- affected_rows is measured against stg_service_requests, which is lossless,
-- not against the deduplicated intermediate model. Measuring after the fix
-- would report zero for every defect that staging repairs.

{% set defects = [
    ('1', 'Duplicate requests', 'is_flagged_duplicate', 'Excluded from no mart. Kept, because a resident reporting the same pothole twice is still a report. Flagged so any count can be taken with or without them.'),
    ('2', 'Closed in under one minute', 'days_to_close_raw < 1.0/1440 and days_to_close_raw is not null', 'Not a real closure. Surfaced as share_closed_under_1min in two marts rather than deleted, because deleting it would overstate how fast the remaining work is.'),
    ('3', 'Ward missing or out of range', 'ward is null', 'Nulled by the clean_ward macro. Row kept so citywide totals stay correct, excluded from every ward-level mart.'),
    ('4', 'Closed before created', 'closed_at < created_at', 'Would be impossible. None found in this slice. days_to_close refuses to populate if it ever appears.'),
    ('5', 'Closed after last modified', 'closed_at > last_modified_at', 'Fails a naive ordering test. Every instance is exactly one second, so it is a clock artifact. Test carries a one second tolerance, see tests/assert_closed_not_after_last_modified.sql.'),
    ('6', 'Open longer than a year', 'is_stale_open', 'Backlog rather than live work. Counted separately as requests_stale_open.'),
    ('7', 'Completed with no closed timestamp', 'is_closed_without_timestamp', 'Would make the request unmeasurable. None found in this slice.'),
    ('8', 'No geocode', 'has_no_geocode', 'Blocks map views only. No effect on the ward analysis, which uses the ward field.'),
    ('9', 'Missing ZIP code', 'zip_code is null', 'Known gap. The City populates ZIP inconsistently by intake channel. Not used by any mart.'),
    ('10', 'Dangling parent request id', 'parent_sr_number is not null and not exists (select 1 from staged p where p.sr_number = staged.parent_sr_number)', 'The surviving request this one was merged into is not in the extract, because the extract keeps only nine service types and a parent can be any type. An artifact of the extract filter, not a City defect. No mart joins on parent_sr_number.')
] %}

with staged as (
    select
        s.*,
        {# Recompute the derived flags against staging rather than importing
           them from the intermediate model, so this mart measures the data
           before deduplication. #}
        case
            when s.closed_at is not null
                then {{ duration_days('s.created_at', 's.closed_at') }}
        end as days_to_close_raw,
        (s.status_raw in ('Completed', 'Closed') and s.closed_at is null)
            as is_closed_without_timestamp,
        (s.latitude is null or s.longitude is null) as has_no_geocode,
        (
            s.status_raw = 'Open'
            and {{ duration_days('s.created_at', "'" ~ var('window_end') ~ "'::timestamp") }}
                > {{ var('stale_open_days') }}
        ) as is_stale_open
    from {{ ref('stg_service_requests') }} s
),

total as (
    select count(*) as total_rows from staged
),

counts as (
    {% for id, label, condition, handling in defects %}
    select
        '{{ id }}'                                       as defect_id,
        '{{ label }}'                                    as defect,
        '{{ condition | replace("'", "''") }}'           as detection_rule,
        '{{ handling | replace("'", "''") }}'            as handling,
        count(*)                                         as affected_rows
    from staged
    where {{ condition }}
    {% if not loop.last %}union all{% endif %}
    {% endfor %}
)

select
    c.defect_id,
    c.defect,
    c.detection_rule,
    c.handling,
    c.affected_rows,
    t.total_rows,
    c.affected_rows / nullif(t.total_rows, 0)::double as affected_share
from counts c
cross join total t
order by cast(c.defect_id as integer)
