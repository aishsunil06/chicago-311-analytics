{#
    Pearson correlation that returns NULL instead of NaN on degenerate input.

    This macro exists because of a bug the clean-clone test found. Running the
    project against the committed 2,400 row sample instead of the full 690k
    pull left some service types with a single ward-month observation. DuckDB's
    corr() over a group with zero variance returns NaN, not NULL, and NaN
    silently passes through a model and then fails an accepted_range test with
    a confusing "value outside -1 to 1" message.

    Two guards:
      - require at least {{ min_rows }} rows in the group, because a
        correlation on four points is noise that looks like a finding
      - isfinite() to turn NaN and infinity into NULL

    A NULL correlation is the honest answer for "not enough data to say", and
    accepted_range ignores NULLs, so the test now reports what it should.
#}
{% macro safe_corr(x, y, min_rows=10) %}
    case
        when count(*) >= {{ min_rows }}
             and isfinite(corr({{ x }}, {{ y }}))
            then corr({{ x }}, {{ y }})
    end
{% endmacro %}
