{#
    Collapse a free-text label to a comparison key.

    Needed because the same concept is spelled more than one way in this
    dataset. The clearest case is status: 3.59M rows say "Completed" and one row
    says "Closed". A GROUP BY on the raw column puts those in different buckets
    and produces a chart with a one-row category in it.

    Uppercases, collapses runs of whitespace, strips punctuation that varies
    between entries (ampersand vs "and", hyphens, periods), and trims.
#}
{% macro normalize_label(column_name) %}
    nullif(
        trim(
            regexp_replace(
                regexp_replace(
                    replace(upper(trim({{ column_name }})), '&', 'AND'),
                    '[^A-Z0-9 ]', ' ', 'g'
                ),
                ' +', ' ', 'g'
            )
        ),
        ''
    )
{% endmacro %}


{#
    Duration between two timestamps, in fractional days.

    Why a macro: this appears in the intermediate model, in three marts and in
    two singular tests. Writing the epoch arithmetic six times is how the
    definition of "days to close" drifts between a mart and the test that is
    supposed to guard it.

    Deliberately NOT clamped at zero. Negative values are a real defect in this
    dataset (closed_date earlier than created_date) and the test in
    tests/assert_no_negative_resolution_time.sql relies on seeing them.
#}
{% macro duration_days(start_ts, end_ts) %}
    (epoch({{ end_ts }}) - epoch({{ start_ts }})) / 86400.0
{% endmacro %}
