-- =====================================================================
-- 02_funnel.sql
-- WHAT : Overall purchase funnel with step-to-step conversion and drop-off.
-- WHY  : Shows WHERE in the journey most sessions are lost, which is
--        the first half of the core question ("where is the leak?").
-- SCAN : Reads only ga4_portfolio.sessions. Validator estimate: 1.37 MB.
-- =====================================================================
--
-- FUNNEL DEFINITION
--   * Unit = session.
--   * "Strict" funnel: a session counts at a step only if it ALSO did
--     every earlier step in the same session. This keeps each step a
--     true subset of the previous one.
--   * Order of events inside the session is NOT enforced (a simplification
--     you should mention; GA4 events can arrive slightly out of order).
--   * The top step is ALL sessions, labelled 'all_sessions' rather than
--     'session_start': a few sessions have no session_start event but are
--     still counted (validation Check 8 gives the share).
--
-- CONCEPT: LAG() window function
--   LAG(x) OVER (ORDER BY step_order) returns x from the PREVIOUS row,
--   without collapsing rows like GROUP BY does.
--   Tiny example: rows 100, 40, 10  ->  LAG gives NULL, 100, 40.
--
-- CONCEPT: FIRST_VALUE() window function
--   FIRST_VALUE(x) OVER (ORDER BY step_order) = x from the first row.
--   Used here to divide every step by the number of sessions at the top.
-- =====================================================================

CREATE OR REPLACE TABLE ga4_portfolio.dash_funnel AS
WITH totals AS (
  SELECT
    COUNT(*)                                                                 AS s1_all_sessions,
    COUNTIF(has_view_item)                                                   AS s2_view_item,
    COUNTIF(has_view_item AND has_add_to_cart)                               AS s3_add_to_cart,
    COUNTIF(has_view_item AND has_add_to_cart AND has_begin_checkout)        AS s4_begin_checkout,
    COUNTIF(has_view_item AND has_add_to_cart AND has_begin_checkout
            AND has_purchase)                                                AS s5_purchase
  FROM ga4_portfolio.sessions
),

steps AS (
  -- Reshape 1 wide row into 5 long rows (one per step) so we can use LAG.
            SELECT 1 AS step_order, 'all_sessions'   AS step, s1_all_sessions   AS sessions FROM totals
  UNION ALL SELECT 2,               'view_item',              s2_view_item               FROM totals
  UNION ALL SELECT 3,               'add_to_cart',            s3_add_to_cart             FROM totals
  UNION ALL SELECT 4,               'begin_checkout',         s4_begin_checkout          FROM totals
  UNION ALL SELECT 5,               'purchase',               s5_purchase                FROM totals
)

SELECT
  step_order,
  step,
  sessions,
  LAG(sessions) OVER (ORDER BY step_order)                                   AS prev_step_sessions,
  LAG(sessions) OVER (ORDER BY step_order) - sessions                        AS sessions_lost,
  ROUND(SAFE_DIVIDE(sessions, LAG(sessions) OVER (ORDER BY step_order)), 4)  AS step_conversion,
  ROUND(1 - SAFE_DIVIDE(sessions, LAG(sessions) OVER (ORDER BY step_order)), 4) AS step_drop_off,
  ROUND(SAFE_DIVIDE(sessions, FIRST_VALUE(sessions) OVER (ORDER BY step_order)), 4) AS conversion_from_start
FROM steps
ORDER BY step_order;

-- HOW TO READ IT
--   step_conversion = share of sessions at the previous step that reached this one.
--   step_drop_off   = 1 - step_conversion. The row with the LARGEST drop-off
--                     (and the largest sessions_lost) is your candidate leak.
--   conversion_from_start on the purchase row = overall session conversion rate.

SELECT * FROM ga4_portfolio.dash_funnel ORDER BY step_order;


-- =====================================================================
-- CHECK: strict vs loose funnel
-- "Loose" = sessions that did the event at all, regardless of earlier steps.
-- If loose purchases >> strict purchases, many purchases skip tracked
-- steps (a tracking gap, not customer behaviour).
-- =====================================================================
SELECT
  COUNTIF(has_purchase)                                                     AS loose_purchase_sessions,
  COUNTIF(has_view_item AND has_add_to_cart AND has_begin_checkout
          AND has_purchase)                                                 AS strict_purchase_sessions,
  ROUND(SAFE_DIVIDE(
    COUNTIF(has_view_item AND has_add_to_cart AND has_begin_checkout AND has_purchase),
    COUNTIF(has_purchase)), 4)                                              AS share_of_purchases_in_strict_funnel
FROM ga4_portfolio.sessions;
