-- =====================================================
-- KKBox Churn Analysis - User-Level Table
-- One row per user with all features needed for visualisation.
-- Run after 01_setup_and_cleaning.sql.
-- 825,367 rows (train users with a member record and positive exposure window).
-- Raw values only — buckets and groupings handled in Tableau.
-- =====================================================


WITH last_txn AS (
    -- Reduce transactions to one row per user: their most recent transaction
    -- on or before 2017-03-31. Uses <= not BETWEEN so users whose last
    -- transaction predates January are kept (they were still members in Q1).
    -- ROW_NUMBER() used here because a window function result can't be
    -- filtered in WHERE — the rn = 1 filter happens in the outer query.
    SELECT
        msno,
        is_auto_renew,
        transaction_date,
        membership_expire_date,
        payment_plan_days,
        ROW_NUMBER() OVER (PARTITION BY msno ORDER BY transaction_date DESC) AS rn
    FROM transactions
    WHERE transaction_date <= '2017-03-31'
),

exposure AS (
    -- Build each user's observable window inside Q1 (Jan 1 - Mar 31 2017).
    -- Start: the later of Jan 1 or their registration date (they can't be
    -- active before they registered).
    -- End: the earlier of Mar 31 or their membership expiry (they can't be
    -- active after their subscription ended).
    -- possible_exposure_days is the denominator for active_day_rate.
    -- Users where possible_exposure_days <= 0 (expired before Jan 1) are
    -- excluded in the final SELECT.
    SELECT
        lt.msno,
        lt.is_auto_renew,
        lt.transaction_date,
        lt.membership_expire_date,
        lt.payment_plan_days,
        m.registration_init_time,
        GREATEST('2017-01-01', m.registration_init_time) AS start_date,
        LEAST('2017-03-31', lt.membership_expire_date) AS end_date,
        (LEAST('2017-03-31', lt.membership_expire_date)
         - GREATEST('2017-01-01', m.registration_init_time)) + 1 AS possible_exposure_days
    FROM last_txn lt
    JOIN members m ON lt.msno = m.msno
    WHERE lt.rn = 1
),

active_days AS (
    -- Aggregate user_logs to one row per user.
    -- Active day: a day where at least one song was played past 50%
    -- (num_50 + num_75 + num_985 + num_100 > 0). Days with only skips
    -- (num_25 only) do not count.
    -- Date filter sits in ON not WHERE so the LEFT JOIN keeps users with
    -- no Q1 logs (non-listeners). A WHERE filter would silently convert
    -- the LEFT JOIN to an INNER JOIN and drop them.
    -- num_25 = songs played less than 25% of the way through — the skip column.
    SELECT
        t.msno,
        t.is_churn,
        COUNT(DISTINCT CASE WHEN (u.num_50 + u.num_75 + u.num_985 + u.num_100) > 0
                            THEN u.date END) AS active_days,
        SUM(u.total_secs) / 60.0 AS total_listen_mins,
        SUM(u.num_25 + u.num_50 + u.num_75 + u.num_985 + u.num_100) AS total_songs,
        SUM(u.num_25) AS skipped_songs
    FROM train t
    LEFT JOIN user_logs u ON t.msno = u.msno
        AND u.date BETWEEN '2017-01-01' AND '2017-03-31'
    GROUP BY t.msno, t.is_churn
)

SELECT
    a.msno,
    a.is_churn,
    e.is_auto_renew,
    e.transaction_date,
    e.payment_plan_days,
    e.possible_exposure_days,
    a.active_days,

    -- active_day_rate: proportion of exposure days where the user was active.
    -- Can exceed 1.0 for 891 users (0.1%) who listened after their expiry date
    -- due to cancellation rows carrying an early expiry. Documented in
    -- 02_data_quality_checks.sql. Does not affect any finding.
    ROUND((a.active_days * 1.0 / e.possible_exposure_days)::numeric, 4) AS active_day_rate,

    ROUND(a.total_listen_mins::numeric, 2) AS total_listen_mins,

    -- mins_per_active_day: listening intensity — how much they listen on days
    -- they actually open the app. Separates frequent light listeners from
    -- infrequent heavy ones. Returns 0 (not NULL) for non-listeners so
    -- Tableau calculations don't break on null values.
    CASE WHEN a.active_days > 0
        THEN ROUND((a.total_listen_mins / a.active_days)::numeric, 2)
        ELSE 0 END AS mins_per_active_day,

    a.total_songs,
    a.skipped_songs,

    -- skip_rate: share of songs played less than 25% of the way through.
    -- Per-user rate, not a pooled total, so heavy listeners don't dominate.
    -- Returns 0 (not NULL) for users with no songs played.
    CASE WHEN a.total_songs > 0
        THEN ROUND((a.skipped_songs * 1.0 / a.total_songs * 100)::numeric, 2)
        ELSE 0 END AS skip_rate

FROM active_days a
JOIN exposure e ON a.msno = e.msno
WHERE e.possible_exposure_days > 0;

-- Result: 825,367 rows. Cohort churn rate = 6.51%.
-- Differs from full train (970,960 users, 8.99%) because ~145K users without
-- a complete member or transaction record were excluded. Those users churn at
-- ~23%. See 02_data_quality_checks.sql for the full breakdown.
