-- This staging model contains key creation and window functions. Keeping window functions outside of the base incremental model ensures that the incremental updates don't artificially limit the window partition sizes (ex: if a session spans 2 days, but only 1 day is in the incremental update)

WITH base_events AS (

    SELECT
        *
    FROM
        {{ ref('base_ga4__events')}}
    {%- if var('include_intraday_events', false) -%}
    UNION ALL
    SELECT
        *
    FROM
        {{ref('base_ga4__events_intraday')}}
    {%- endif %}

),

-- Add unique keys for sessions.
add_session_key AS (

    SELECT
        *,
        MD5(
            CONCAT(
                stream_id,
                client_id,
                CAST(ga_session_id AS STRING)
            )
        ) AS session_key -- Surrogate key to determine unique session across streams and users. Sessions do NOT reset after midnight in GA4.
    FROM
        base_events

),

-- Add event numbers for each event.
add_event_number AS (

    SELECT
        *,
        ROW_NUMBER() OVER(PARTITION BY session_key) AS session_event_number -- Number each event within a session to help generate a unique event key.
    FROM
        add_session_key

),

-- Add unique keys for events.
add_event_key AS (

    SELECT
        *,
        MD5(
            CONCAT(
                CAST(TO_BASE64(session_key) AS STRING), -- MAY NEED ADD 'TO_BASE64' BEFORE THIS --
                CAST(session_event_number AS STRING)
            )
        ) AS event_key -- Surrogate key for unique events.
    FROM
        add_event_number

),

-- Remove specific query strings from page_location field.
remove_query_params AS (

    SELECT
        * EXCEPT (page_location),
        page_location AS original_page_location,
    
        -- If there are query parameters to exclude, exclude them using RegEx.
        {% if var('query_parameter_exclusions', none) is not none -%}

        {{ remove_query_parameters('page_location', var('query_parameter_exclusions')) }} AS page_location

        {% else -%}

        page_location

        {%- endif %}
    FROM
        add_event_key

),

-- Enrich params by extracting 'page_hostname' and 'page_query_string' from the 'page_location' URL.
enrich_params AS (

    SELECT
        *,
        {{ extract_hostname_from_url('page_location') }} AS page_hostname,
        {{ extract_query_string_from_url('page_location') }} AS page_query_string,
    FROM
        remove_query_params

)

SELECT * FROM enrich_params