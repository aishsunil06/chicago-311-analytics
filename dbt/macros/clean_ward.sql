{#
    Chicago has exactly 50 wards, numbered 1 through 50.

    The raw ward column is a VARCHAR and arrives three ways: a clean number, an
    empty string, or a number with padding. A handful of rows also carry a 0,
    which is not a ward. Anything that is not 1-50 becomes NULL rather than
    being dropped, because a request with an unknown ward is still a real
    request and still belongs in the citywide totals. Dropping it would quietly
    understate volume; nulling it keeps the row and makes the gap countable.

    Returns an INTEGER or NULL.
#}
{% macro clean_ward(column_name) %}
    case
        when try_cast(trim({{ column_name }}) as integer) between 1 and 50
            then try_cast(trim({{ column_name }}) as integer)
        else null
    end
{% endmacro %}
