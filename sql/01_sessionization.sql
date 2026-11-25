
-- =====================================================================
-- 01_sessionization.sql
--
-- WHAT : Transforms raw GA4 events into ONE row per session.
--
-- WHY  : Creates a reusable session-level table for funnel analysis,
--        customer segmentation, retention and RFM analysis.
--
-- SCAN : Reads required columns from 92 daily GA4 event tables.
--        Uses date filters and selected columns to control query costs.
--        Estimated scan: approximately 1.17 GB (verified in BigQuery).
--        BigQuery free tier: 1 TB of query processing per month.
--
-- RUN  : Run once. Re-run only if the session definition changes.
--
-- =====================================================================
--
-- GA4 TABLE STRUCTURE
--   * One table per day: events_20201101 ... events_20210131.
--   * events_* and _TABLE_SUFFIX allow date-range queries.
--   * One row represents one event.
--   * event_params contains nested key-value pairs.
--   * UNNEST() extracts values from event_params.
--   * user_pseudo_id identifies an anonymous browser/device.
--   * ga_session_id identifies a session within a user.
--   * Session key = user_pseudo_id + ga_session_id.
--
-- CONCEPT: UNNEST
--   UNNEST(list) converts array elements into rows.
--   It allows us to extract specific event parameters.
--
-- CONCEPT: CTE (WITH ... AS)
--   A named temporary result that makes complex queries easier
--   to read, organize and maintain.
--
-- =====================================================================

-- STEP 0: Create a dataset in your Google Cloud project.
-- Location must be US because the public GA4 dataset is hosted in the US.

CREATE SCHEMA IF NOT EXISTS ga4_portfolio
OPTIONS (location = 'US');


-- STEP 1: Build and save the session-level table.

CREATE OR REPLACE TABLE ga4_portfolio.sessions AS

WITH events AS (

  -- Extract required fields from raw GA4 events.

  SELECT
    user_pseudo_id,
    event_timestamp,
    event_name,
    PARSE_DATE('%Y%m%d', event_date) AS event_date,

    (SELECT value.int_value
     FROM UNNEST(event_params)
     WHERE key = 'ga_session_id') AS ga_session_id,

    (SELECT value.int_value
     FROM UNNEST(event_params)
     WHERE key = 'ga_session_number') AS ga_session_number,

    device.category AS device_category,
    traffic_source.source AS source,
    traffic_source.medium AS medium,
    geo.country AS country,
    ecommerce.transaction_id,
    ecommerce.purchase_revenue_in_usd

  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`

  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
),

sessions_agg AS (

  -- Aggregate events into one row per user and session.

  SELECT
    CONCAT(user_pseudo_id, '-', CAST(ga_session_id AS STRING))
      AS session_key,

    user_pseudo_id,
    ga_session_id,

    MIN(ga_session_number) AS ga_session_number,

    TIMESTAMP_MICROS(MIN(event_timestamp)) AS session_start_ts,

    MIN(event_date) AS session_date,

    DATE_TRUNC(MIN(event_date), WEEK(MONDAY)) AS session_week,

    -- First available non-null session attributes.

    ARRAY_AGG(device_category IGNORE NULLS
      ORDER BY event_timestamp LIMIT 1)[SAFE_OFFSET(0)]
      AS device_category,

    ARRAY_AGG(source IGNORE NULLS
      ORDER BY event_timestamp LIMIT 1)[SAFE_OFFSET(0)]
      AS source,

    ARRAY_AGG(medium IGNORE NULLS
      ORDER BY event_timestamp LIMIT 1)[SAFE_OFFSET(0)]
      AS medium,

    ARRAY_AGG(country IGNORE NULLS
      ORDER BY event_timestamp LIMIT 1)[SAFE_OFFSET(0)]
      AS country,

    COUNT(*) AS event_count,

    -- Funnel flags: whether each event occurred at least once
    -- during the session. Event order is not enforced.

    LOGICAL_OR(event_name = 'session_start') AS has_session_start,
    LOGICAL_OR(event_name = 'view_item') AS has_view_item,
    LOGICAL_OR(event_name = 'add_to_cart') AS has_add_to_cart,
    LOGICAL_OR(event_name = 'begin_checkout') AS has_begin_checkout,
    LOGICAL_OR(event_name = 'purchase') AS has_purchase,

    -- Purchase and revenue metrics.

    COUNTIF(event_name = 'purchase') AS purchase_events,

    COUNT(DISTINCT IF(
      event_name = 'purchase',
      transaction_id,
      NULL
    )) AS distinct_transaction_ids,

    IFNULL(
      SUM(IF(
        event_name = 'purchase',
        purchase_revenue_in_usd,
        0
      )),
      0
    ) AS revenue_usd

  FROM events

  WHERE ga_session_id IS NOT NULL

  GROUP BY user_pseudo_id, ga_session_id
)

-- STEP 2: Add first-touch channel grouping.

SELECT
  *,

  CASE
    WHEN medium = '(none)' THEN 'Direct'
    WHEN medium = 'organic' THEN 'Organic Search'
    WHEN medium IN ('cpc', 'ppc', 'paid') THEN 'Paid Search'
    WHEN medium = 'referral' THEN 'Referral'
    WHEN medium IN ('<Other>', '(data deleted)')
      OR medium IS NULL THEN 'Unknown (missing/obfuscated)'
    ELSE 'Other'
  END AS channel_group

FROM sessions_agg;


-- =====================================================================
-- OUTPUT VALIDATION
-- =====================================================================

-- A) Check table size, users, unique keys and date range.

SELECT
  COUNT(*) AS sessions,
  COUNT(DISTINCT user_pseudo_id) AS users,
  COUNT(DISTINCT session_key) AS distinct_session_keys,
  MIN(session_date) AS first_day,
  MAX(session_date) AS last_day

FROM ga4_portfolio.sessions;


-- B) Check funnel counts and total purchase revenue.

SELECT
  COUNTIF(has_session_start) AS with_session_start,
  COUNTIF(has_view_item) AS with_view_item,
  COUNTIF(has_add_to_cart) AS with_add_to_cart,
  COUNTIF(has_begin_checkout) AS with_begin_checkout,
  COUNTIF(has_purchase) AS with_purchase,

  ROUND(SUM(revenue_usd), 2) AS total_revenue_usd

FROM ga4_portfolio.sessions;


-- C) Inspect a random sample of 10 session records.

SELECT *
FROM ga4_portfolio.sessions
ORDER BY RAND()
LIMIT 10;
