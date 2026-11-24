-- =====================================================================
-- validation/reconciliation_checks.sql
-- WHAT : Proves the sessions table is trustworthy before anyone believes
--        the funnel numbers. Run right after 01_sessionization.sql.
-- SCAN : Checks 1, 3, 4, 5 read the RAW table; checks 2, 6, 7, 8 read the
--        small sessions table. 
-- Validation status:
-- Check 1: Completed
-- Check 2: Completed
-- Check 3: Completed
-- Check 4: Completed
-- Check 5: Completed
-- Check 6: Completed
-- Check 7: Completed
-- Check 8: Completed
-- Detailed results: docs/data_notes.md
-- =====================================================================
--   Session definition : user_pseudo_id + ga_session_id. Events without a
--                        ga_session_id are excluded (Check 3 measures this).
--   Funnel             : strict, within one session, event order not enforced.
--   Attribution        : first-touch (traffic_source.* = how the user was
--                        first acquired), not last-click per session.
--   Revenue            : ecommerce.purchase_revenue_in_usd on purchase events.
--   Window             : 2020-11-01 to 2021-01-31 (includes Black Friday and
--                        holidays, so rates may be seasonally high).
--   Obfuscation        : Google replaced some values with '<Other>' or
--                        '(data deleted)' and some transaction_ids with
--                        '(not set)'. These are dataset limits, not my errors.
-- =====================================================================


-- ---------------------------------------------------------------------
-- CHECK 1: Raw purchase totals (the "source of truth")
-- ---------------------------------------------------------------------
SELECT
  COUNT(*)                                                     AS purchase_events,
  COUNT(DISTINCT transaction_id)                               AS distinct_transaction_ids,
  COUNTIF(transaction_id IS NULL OR transaction_id = '(not set)') AS purchases_without_valid_txn_id,
  COUNTIF(purchase_revenue_in_usd IS NULL)                     AS purchases_with_null_revenue,
  COUNTIF(purchase_revenue_in_usd = 0)                         AS purchases_with_zero_revenue,
  ROUND(SUM(purchase_revenue_in_usd), 2)                       AS raw_revenue_usd
FROM (
  SELECT ecommerce.transaction_id AS transaction_id,
         ecommerce.purchase_revenue_in_usd AS purchase_revenue_in_usd
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name = 'purchase'
);

-- ---------------------------------------------------------------------
-- CHECK 2: Same totals from the sessions table. Should match Check 1
-- exactly, MINUS any purchases that had no ga_session_id (Check 3).
-- ---------------------------------------------------------------------
SELECT
  SUM(purchase_events)          AS purchase_events,
  ROUND(SUM(revenue_usd), 2)    AS sessions_table_revenue_usd,
  COUNTIF(has_purchase)         AS purchase_sessions,
  COUNTIF(purchase_events > 1)  AS sessions_with_multiple_purchases
FROM ga4_portfolio.sessions;

-- ---------------------------------------------------------------------
-- CHECK 3: Events with NULL ga_session_id, by event type
-- These are dropped by 01_sessionization.sql. Report the share and any
-- purchase revenue lost this way.
-- ---------------------------------------------------------------------
SELECT
  event_name,
  COUNT(*)                                                      AS events,
  COUNTIF(ga_session_id IS NULL)                                AS null_session_events,
  ROUND(SAFE_DIVIDE(COUNTIF(ga_session_id IS NULL), COUNT(*)), 4) AS share_null,
  ROUND(SUM(IF(ga_session_id IS NULL, purchase_revenue_in_usd, 0)), 2) AS revenue_lost_usd
FROM (
  SELECT
    event_name,
    ecommerce.purchase_revenue_in_usd AS purchase_revenue_in_usd,
    (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS ga_session_id
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name IN ('session_start', 'view_item', 'add_to_cart', 'begin_checkout', 'purchase')
)
GROUP BY event_name
ORDER BY events DESC;

-- ---------------------------------------------------------------------
-- CHECK 4: Duplicate events
-- Same user, same session, same event, same microsecond = likely a
-- double-fired tag. A few are normal; a lot would inflate funnel counts
-- (our funnel uses yes/no flags, so it is protected, but revenue is not).
-- ---------------------------------------------------------------------
SELECT
  event_name,
  COUNT(*)            AS duplicate_groups,
  SUM(n - 1)          AS extra_duplicate_rows
FROM (
  SELECT
    user_pseudo_id, event_timestamp, event_name,
    (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS ga_session_id,
    COUNT(*) AS n
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
  GROUP BY 1, 2, 3, 4
  HAVING COUNT(*) > 1
)
GROUP BY event_name
ORDER BY extra_duplicate_rows DESC;

-- ---------------------------------------------------------------------
-- CHECK 5: Duplicate transaction IDs
-- A real transaction_id should appear on exactly one purchase event.
-- If one appears several times, revenue is double counted.
-- ---------------------------------------------------------------------
SELECT
  COUNT(*)                     AS txn_ids_seen_more_than_once,
  SUM(n - 1)                   AS extra_purchase_events,
  ROUND(SUM(extra_revenue), 2) AS potentially_double_counted_revenue_usd
FROM (
  SELECT
    ecommerce.transaction_id AS transaction_id,
    COUNT(*) AS n,
    SUM(ecommerce.purchase_revenue_in_usd) - MAX(ecommerce.purchase_revenue_in_usd) AS extra_revenue
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND event_name = 'purchase'
    AND ecommerce.transaction_id IS NOT NULL
    AND ecommerce.transaction_id != '(not set)'
  GROUP BY 1
  HAVING COUNT(*) > 1
);

-- ---------------------------------------------------------------------
-- CHECK 6: Session key must be unique
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS rows_, COUNT(DISTINCT session_key) AS distinct_keys
FROM ga4_portfolio.sessions;   -- the two numbers must be equal

-- ---------------------------------------------------------------------
-- CHECK 7: Sessions missing device or source values
-- ---------------------------------------------------------------------
SELECT
  COUNT(*)                                                     AS sessions,
  COUNTIF(device_category IS NULL)                             AS missing_device,
  COUNTIF(source IS NULL OR medium IS NULL)                    AS missing_source_medium,
  COUNTIF(channel_group = 'Unknown (obfuscated)')              AS obfuscated_channel,
  ROUND(SAFE_DIVIDE(COUNTIF(channel_group = 'Unknown (obfuscated)'), COUNT(*)), 4) AS share_obfuscated_channel
FROM ga4_portfolio.sessions;

-- ---------------------------------------------------------------------
-- CHECK 8: Funnel logic sanity
-- Purchases with no begin_checkout, sessions with no session_start event.
-- ---------------------------------------------------------------------
SELECT
  COUNTIF(has_purchase AND NOT has_begin_checkout) AS purchase_without_checkout,
  COUNTIF(has_purchase AND NOT has_add_to_cart)    AS purchase_without_add_to_cart,
  COUNTIF(NOT has_session_start)                   AS sessions_without_session_start_event,
  ROUND(SAFE_DIVIDE(COUNTIF(NOT has_session_start), COUNT(*)), 4) AS share_without_session_start
FROM ga4_portfolio.sessions;

-- =====================================================================
-- VALIDATION PASS CRITERIA
--   Check 1 vs 2 : revenue difference explained entirely by Check 3.
--   Check 4      : duplicate rows < 1% of events.
--   Check 5      : double-counted revenue < 1% of total (else de-duplicate).
--   Check 6      : rows = distinct keys.
--   Check 7      : report the obfuscated share as a limitation.
--   Check 8      : report the share; explain why strict funnel is used.

-- RESULTS:
--   Check 1 : PASS
--   Check 3 : PASS
--   Check 4 : PASS
--   Check 5 : FAIL (6.11% potentially double-counted revenue).
--   Check 6 : PASS
--   Check 7 : Limitation (20.74% obfuscated channels).
--   Check 8 : Limitation (0.02% purchases without begin_checkout).
--
-- Detailed results: docs/data_notes.md
-- =====================================================================
