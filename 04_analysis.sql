-- =====================================================
-- KKBox Churn Analysis - Analysis Queries
-- Run after 01_setup_and_cleaning.sql.
-- Answers two business questions:
--   Q1: Do churners use the app differently from stayers?
--   Q2: How do churners differ from stayers in how they pay and renew?
-- All queries use the Jan 1 - Mar 31 2017 window (the 3 months before
-- the March 2017 expiry cohort).
-- Two populations are used, depending on what each query needs:
--   Active-day rate queries (1.3, 1.3b) need a member record and a
--   transaction to build the exposure window: 825,367 users, 6.51% churn.
--   All other queries use every train user with the data that query needs
--   (listening logs or a transaction), compared against the overall
--   baseline of 8.99% churn (970,960 users).
-- =====================================================


-- =====================================================
-- QUESTION 1: USAGE PATTERNS
-- =====================================================

-- 1.1 Total listening time — do churners listen less overall?
-- Scope: listeners only (INNER JOIN excludes users with no Q1 logs).
-- Aggregated to one row per user via CTE before averaging, so each user
-- counts equally regardless of how many log rows they have.
with total_listening_time as (
    select
        t.msno,
        is_churn,
        sum(total_secs) / 60.0 as total_listen_min
    from train t
    join user_logs u on t.msno = u.msno
    where u.date between '2017-01-01' and '2017-03-31'
    group by t.msno, is_churn
)
select
    is_churn,
    avg(total_listen_min) as avg_listen_time_min
from total_listening_time
group by is_churn;

-- result: stayers 6,364 mins vs churners 6,026 mins over 3 months (~5.5% gap).
-- Weak signal. Roughly 100 extra songs separating the two groups over 90 days.


-- 1.2 Skip rate — do churners skip more songs?
-- Skip defined as num_25: a song played less than 25% of the way through.
-- Per-user rate (not pooled total) so heavy listeners don't dominate.
-- Scope: listeners with at least one song played (total_songs > 0).
with skipped_songs as (
    select
        t.msno,
        is_churn,
        sum(num_25 + num_50 + num_75 + num_985 + num_100) as total_songs,
        sum(num_25) as no_of_skips
    from train t
    join user_logs u on t.msno = u.msno
    where u.date between '2017-01-01' and '2017-03-31'
    group by t.msno, is_churn
)
select
    is_churn,
    count(msno) as no_users,
    round(avg(no_of_skips * 1.0 / total_songs) * 100, 2) as avg_skip_rate
from skipped_songs
where total_songs > 0
group by is_churn;

-- result: stayers 19.19% vs churners 19.21%. Null result.
-- Within-session behaviour does not distinguish churners from stayers.
-- When they listen, they listen the same way.


-- 1.3 Active day rate — average by churn group
-- Active day: a day with at least one song played past 50%.
-- Rate = active days / possible exposure days, normalising for each user's
-- actual exposure window so someone who joined in February is not penalised
-- against someone present for the full quarter.
-- Active days here are counted across the full Jan-Mar window; 1.3b below
-- counts only days inside each user's membership window. Both lead to the
-- same conclusion: usage separates churners from stayers by only a few points.
with last_txn as (
    select
        msno,
        is_auto_renew,
        transaction_date,
        membership_expire_date,
        row_number() over (partition by msno order by transaction_date desc) as rn
    from transactions
    where transaction_date <= '2017-03-31'
),
exposure as (
    select
        lt.msno,
        lt.is_auto_renew,
        lt.membership_expire_date,
        m.registration_init_time,
        greatest('2017-01-01', m.registration_init_time) as start_date,
        least('2017-03-31', lt.membership_expire_date) as end_date,
        (least('2017-03-31', lt.membership_expire_date)
         - greatest('2017-01-01', m.registration_init_time)) + 1 as possible_exposure_days
    from last_txn lt
    join members m on lt.msno = m.msno
    where lt.rn = 1
),
active_days as (
    select
        t.msno,
        t.is_churn,
        count(distinct case when (u.num_50 + u.num_75 + u.num_985 + u.num_100) > 0
                            then u.date end) as active_days
    from train t
    left join user_logs u on t.msno = u.msno
        and u.date between '2017-01-01' and '2017-03-31'
    group by t.msno, t.is_churn
),
user_rates as (
    select
        a.msno,
        a.is_churn,
        a.active_days,
        e.possible_exposure_days,
        e.is_auto_renew,
        round(a.active_days * 1.0 / e.possible_exposure_days, 4) as active_day_rate
    from active_days a
    join exposure e on a.msno = e.msno
    where e.possible_exposure_days > 0
)
select
    is_churn,
    count(msno) as users,
    avg(active_day_rate) as avg_active_day_rate
from user_rates
group by is_churn;

-- result: stayers (0) = 771,590 users, 50.4% avg rate | churners (1) = 53,777 users, 54.3% avg rate
-- Churners are marginally more active by rate, but the gap is only ~4 points.
-- Usage remains a weak signal — the difference is not large enough to act on.


-- 1.3b Active day rate — bucketed into three engagement tiers
-- Active day definition and exposure window same as 1.3.
-- User logs clipped to each user's personal window (start_date to end_date)
-- so active days are only counted on days the user was actually a member.
-- Three tiers: Dormant (paid but no active days), Light (active on less than
-- about half of their membership days), and Regular (about half or more).
-- The half-way cut separates users who treat the app as occasional from those
-- who use it as a habit.
with last_txn as (
    select
        msno,
        is_auto_renew,
        transaction_date,
        membership_expire_date,
        row_number() over (partition by msno order by transaction_date desc) as rn
    from transactions
    where transaction_date <= '2017-03-31'
),
exposure as (
    select
        lt.msno,
        lt.is_auto_renew,
        lt.membership_expire_date,
        m.registration_init_time,
        greatest('2017-01-01', m.registration_init_time) as start_date,
        least('2017-03-31', lt.membership_expire_date) as end_date,
        (least('2017-03-31', lt.membership_expire_date)
         - greatest('2017-01-01', m.registration_init_time)) + 1 as possible_exposure_days
    from last_txn lt
    join members m on lt.msno = m.msno
    where lt.rn = 1
),
active_days as (
    select
        t.msno,
        t.is_churn,
        count(distinct case when (u.num_50 + u.num_75 + u.num_985 + u.num_100) > 0
                            then u.date end) as active_days
    from train t
    join exposure e on t.msno = e.msno
    left join user_logs u on t.msno = u.msno
        and u.date between e.start_date and e.end_date
    group by t.msno, t.is_churn
),
user_rates as (
    select
        a.msno,
        a.is_churn,
        a.active_days,
        e.possible_exposure_days,
        e.is_auto_renew,
        round(a.active_days * 1.0 / e.possible_exposure_days, 4) as active_day_rate
    from active_days a
    join exposure e on a.msno = e.msno
    where e.possible_exposure_days > 0
)
select
    case
        when active_day_rate = 0    then 'Dormant'
        when active_day_rate < 0.49 then 'Light User'
        else 'Regular'
    end as bucket,
    count(*) as users,
    round(avg(is_churn) * 100, 2) as churn_rate
from user_rates
group by bucket
order by bucket;

-- result: Dormant = 66,995 users (6.96%) | Light User = 322,248 (5.58%) | Regular = 436,124 (7.14%)
-- Spread is under 2 percentage points across all three tiers — a weak signal.
-- Usage engagement level does not meaningfully predict churn.


-- 1.4 Listening intensity — how much do they listen on the days they listen?
-- Only counts minutes on active days, not total minutes across the window.
-- Median reported alongside mean because the distribution is right-skewed.
-- Scope: listeners with at least one active day (INNER JOIN).
with listener_intensity as (
    select
        t.msno,
        t.is_churn,
        sum(case when (u.num_50 + u.num_75 + u.num_985 + u.num_100) > 0
                 then u.total_secs else 0 end) / 60.0 as active_day_mins,
        count(distinct case when (u.num_50 + u.num_75 + u.num_985 + u.num_100) > 0
                            then u.date end) as active_days
    from train t
    join user_logs u on t.msno = u.msno
        and u.date between '2017-01-01' and '2017-03-31'
    group by t.msno, t.is_churn
)
select
    is_churn,
    count(*) as users,
    round(avg(active_day_mins / active_days)::numeric, 2) as avg_mins_per_active_day,
    round(percentile_cont(0.5) within group
         (order by active_day_mins / active_days)::numeric, 2) as median_mins_per_active_day
from listener_intensity
where active_days > 0
group by is_churn;

-- result: stayers = 717,254 users | avg 109.72 mins/active day | median 83.27
--         churners =  75,041 users | avg 113.71 mins/active day | median 87.50
-- Null result. Both groups listen for roughly the same amount on the days they
-- open the app. The median is the more reliable figure here given the right skew —
-- 83 vs 88 mins is not a meaningful difference. When churners listen, they
-- listen just as much as stayers.


-- Q1 conclusion: usage is a weak predictor of churn across all four measures.
-- Total time, skip rate, active day rate, and listening intensity all show
-- minimal separation between churners and stayers. The signal is in Q2.


-- =====================================================
-- QUESTION 2: PAYMENT & RENEWAL
-- =====================================================

-- 2.1 Auto-renew vs manual renewal — the headline finding
-- Each user reduced to their most recent transaction on or before 2017-03-31.
-- ROW_NUMBER() used because window function results can't be filtered in WHERE.
with last_txn as (
    select
        msno,
        payment_plan_days,
        plan_list_price,
        is_auto_renew,
        transaction_date,
        row_number() over (partition by msno order by transaction_date desc) as rn
    from transactions
    where transaction_date <= '2017-03-31'
)
select
    lt.is_auto_renew,
    count(lt.msno) as users,
    round(avg(t.is_churn) * 100, 2) as churn_rate
from last_txn lt
join train t on lt.msno = t.msno
where lt.rn = 1
group by lt.is_auto_renew;

-- result: manual renewers 30.57% churn (82,894 users) vs
--         auto-renewers 3.83% churn (850,684 users). An 8x gap.
-- By far the strongest signal in the project. Usage metrics move churn by
-- under 4 points; payment mechanism moves it by 27.
-- Stated as association, not proven causation. Two readings both produce
-- this result:
--   Causal: friction of manually re-paying is where people drop out.
--   Selection: people who intend to stay are the ones who opt into auto-renew.
-- These imply opposite business recommendations, so the gap motivates a test,
-- not a direct policy change.


-- 2.2 Silent users by auto-renew status — passive renewal check
-- Silent user: subscribed but no Q1 log rows (never opened the app Jan-Mar 2017).
-- Date filter in ON not WHERE so the LEFT JOIN keeps non-listeners.
with last_txn as (
    select
        msno,
        is_auto_renew,
        transaction_date,
        row_number() over (partition by msno order by transaction_date desc) as rn
    from transactions
    where transaction_date <= '2017-03-31'
),
never_listened as (
    select t.msno
    from train t
    left join user_logs u on t.msno = u.msno
        and u.date between '2017-01-01' and '2017-03-31'
    where u.msno is null
)
select
    lt.is_auto_renew,
    count(t.msno) as users,
    round(avg(t.is_churn) * 100, 2) as churn_rate
from train t
join never_listened nl on t.msno = nl.msno
join last_txn lt on t.msno = lt.msno
where lt.rn = 1
group by lt.is_auto_renew;

-- result: silent + auto-renew: 172,397 users, 4.92% churn (below the 8.99% baseline).
--         silent + manual:       209 users, 93.78% churn.
-- 99.9% of silent users are on auto-renew. They pay automatically, never open
-- the app, and churn below the overall baseline — textbook passive renewal.
-- The 209 silent-manual users churn at 93.78%: without auto-renew, a user who
-- never opens the app has no reason to stay. Vivid illustration, but n = 209
-- out of ~970K — illustrative only, never a headline segment.


-- 2.3 Active listeners by auto-renew — usage held constant
-- Listener: at least one Q1 log row.
-- This isolates the payment mechanism effect from any usage difference.
with last_txn as (
    select
        msno,
        is_auto_renew,
        transaction_date,
        row_number() over (partition by msno order by transaction_date desc) as rn
    from transactions
    where transaction_date <= '2017-03-31'
),
listened as (
    select distinct msno
    from user_logs
    where date between '2017-01-01' and '2017-03-31'
)
select
    lt.is_auto_renew,
    count(t.msno) as users,
    round(avg(t.is_churn) * 100, 2) as churn_rate
from train t
join listened l on t.msno = l.msno
join last_txn lt on t.msno = lt.msno
where lt.rn = 1
group by lt.is_auto_renew;

-- result: active + manual: 82,685 users, 30.41% churn.
--         active + auto:  678,287 users,  3.55% churn. Nearly 9x apart.
-- Hold usage constant: active manual renewers still churn at 30%.
-- Payment mechanism dominates usage. KKBox is losing engaged users who want
-- to stay, purely over a manual payment step.


-- 2.4 Plan commitment vs churn — does a bigger upfront commitment predict retention?
-- Plan lengths grouped into four types based on payment_plan_days.
-- Cross-cut by is_auto_renew to separate the plan-length effect from the
-- auto-renew effect (they turn out to be the same thing — see 2.5).
with last_txn as (
    select
        msno,
        is_auto_renew,
        transaction_date,
        membership_expire_date,
        payment_plan_days,
        row_number() over (partition by msno order by transaction_date desc) as rn
    from transactions
    where transaction_date <= '2017-03-31'
)
select
    case
        when payment_plan_days <= 7   then 'Trial'
        when payment_plan_days <= 30  then 'Monthly'
        when payment_plan_days <= 90  then 'Quarterly'
        else 'Long-term'
    end as plan_type,
    is_auto_renew,
    count(*) as users,
    round(avg(t.is_churn) * 100, 2) as churn_rate_pct
from last_txn lt
join train t on lt.msno = t.msno
where lt.rn = 1
group by plan_type, is_auto_renew;

-- result: Trial manual = 499 users (82.57%) | Monthly auto = 850,659 (3.83%)
--         Monthly manual = 64,713 (11.95%) | Quarterly manual = 4,208 (90.42%)
--         Long-term manual = 13,498 (99.26%)
-- Counter-intuitive: longer commitment = higher churn. Explained by 2.5 below —
-- auto-renew is only available on monthly plans, so quarterly and long-term users
-- are ALL on manual renewal with no way to auto-continue.


-- 2.5 Auto-renew adoption by plan length — structural constraint confirmed
-- Shows that auto-renew is a monthly-plan-only feature in KKBox's 2017
-- payment architecture. Longer plans are paid at convenience stores or via
-- network deals (one-time payments), so auto-renew is never an option.
with last_txn as (
    select
        msno,
        payment_plan_days,
        is_auto_renew,
        actual_amount_paid,
        row_number() over (partition by msno order by transaction_date desc) as rn
    from transactions
    where transaction_date <= '2017-03-31'
)
select
    lt.payment_plan_days,
    count(*) as users,
    round(avg(lt.is_auto_renew) * 100, 2) as pct_auto_renew,
    round(avg(t.is_churn) * 100, 2) as churn_rate_pct
from last_txn lt
join train t on t.msno = lt.msno
where lt.rn = 1
group by lt.payment_plan_days
having count(*) > 500
order by users desc;

-- result: 30-day plan: ~92% auto-renew, low churn.
--         All other plan lengths: ~0% auto-renew, high churn.


-- 2.5b Confirmation: auto-renew count across ALL transactions (not just latest)
-- Verifies the structural constraint holds across the full transaction history,
-- not just each user's most recent plan.
select
    payment_plan_days,
    count(*) as txns,
    sum(is_auto_renew) as auto_renew_txns,
    count(distinct msno) as users
from transactions
where payment_plan_days in (30, 90, 100, 180, 195, 360, 410)
group by payment_plan_days
order by payment_plan_days;

-- result: 30d = 1,217,998 txns, 1,121,601 auto-renew
--         90d = 19,130 txns, 0 auto-renew | 100d = 4,098 txns, 0
--         180d = 23,900 txns, 0 | 195d = 28,568 txns, 0
--         360d = 4,658 txns, 0 | 410d = 82,097 txns, 0
-- Zero auto-renew across 162,451 transactions on non-monthly plans.
-- This is a system constraint, not a user choice. Confirmed by product research:
-- KKBox did not offer auto-renew on non-monthly plans in 2017.
-- Business recommendation: enabling auto-renew on longer plans is the
-- highest-leverage change supported by this data.

-- =====================================================
-- RETENTION IMPACT ESTIMATE (SCENARIO-BASED)
-- =====================================================
-- Enabling auto-renew on non-monthly plans is the core recommendation from
-- this analysis. To size the opportunity, I modelled two scenarios. This is a
-- scenario-based estimate, not a causal one: monthly and non-monthly users can
-- differ in ways beyond auto-renew (price, tenure, intent, how they pay), so
-- the true effect can only be confirmed by testing the change.
--
-- I used the monthly plan as the benchmark because it is the only plan where
-- auto-renew exists, which makes it the closest available comparison.
--
-- Optimistic: assumes the churn gap is fully recoverable through auto-renew,
-- so non-monthly users churn at the monthly auto-renew rate (3.83%).
--
-- Conservative: assumes only the friction piece is recoverable, so non-monthly
-- users churn at the monthly manual rate (11.95%). This is a deliberately
-- cautious assumption, not a statistical floor.
--
-- The calculation runs in three steps:
--   actual churn rate - scenario churn rate = recoverable churn rate
--   recoverable churn rate x eligible users  = users retained
--   users retained x annual revenue per user = annual revenue opportunity
-- Rates are kept unrounded until the final output to avoid rounding drift.
--
-- Revenue is annualised per user: the amount paid on their latest plan,
-- converted to USD (NTD / 30), scaled to 365 days by their own plan length.
-- Putting every plan on the same annual basis lets the two plan types be
-- summed. The annual figure assumes a retained user stays for a full year.
-- =====================================================

with benchmarks as (
    select
        0.0383 as optimistic_rate,     -- monthly auto-renew churn
        0.1195 as conservative_rate    -- monthly manual churn
),
last_txn as (
    select
        msno,
        payment_plan_days,
        actual_amount_paid,
        row_number() over (partition by msno order by transaction_date desc) as rn
    from transactions
    where transaction_date <= '2017-03-31'
),
eligible_users as (
    -- non-monthly users: the group the recommendation would apply to
    select
        case
            when lt.payment_plan_days <= 90 then 'Quarterly'
            else 'Long-term'
        end as plan_type,
        count(*)                                                         as users,
        avg(t.is_churn)                                                  as actual_churn_rate,
        avg(lt.actual_amount_paid / 30.0 * 365.0 / lt.payment_plan_days) as annual_revenue_usd
    from last_txn lt
    join train t on lt.msno = t.msno
    where lt.rn = 1
      and lt.payment_plan_days > 30
    group by plan_type
),
results as (
    select
        e.plan_type,
        e.users,
        e.annual_revenue_usd,
        e.users * (e.actual_churn_rate - b.optimistic_rate)                          as retained_optimistic,
        e.users * (e.actual_churn_rate - b.optimistic_rate) * e.annual_revenue_usd   as annual_optimistic_usd,
        e.users * (e.actual_churn_rate - b.conservative_rate)                        as retained_conservative,
        e.users * (e.actual_churn_rate - b.conservative_rate) * e.annual_revenue_usd as annual_conservative_usd
    from eligible_users e
    cross join benchmarks b
)
select
    plan_type,
    users,
    round(annual_revenue_usd, 2)   as annual_revenue_per_user_usd,
    round(retained_optimistic)     as users_retained_optimistic,
    round(annual_optimistic_usd)   as annual_revenue_optimistic_usd,
    round(retained_conservative)   as users_retained_conservative,
    round(annual_conservative_usd) as annual_revenue_conservative_usd
from results

union all

select
    'TOTAL',
    sum(users),
    null,
    round(sum(retained_optimistic)),
    round(sum(annual_optimistic_usd)),
    round(sum(retained_conservative)),
    round(sum(annual_conservative_usd))
from results;

-- result:
--   Long-term: 13,498 users | $48.34 annual revenue per user
--     optimistic:   12,881 retained | $622,610 per year
--     conservative: 11,785 retained | $569,633 per year
--
--   Quarterly: 4,208 users | $47.76 annual revenue per user
--     optimistic:    3,644 retained | $174,031 per year
--     conservative:  3,302 retained | $157,712 per year
--
--   Total: 15,087 to 16,525 users retained | $727,344 to $796,641 per year
--
-- Annual revenue per user is almost identical across plan types (~$48), which
-- is a useful sanity check: once annualised, a subscriber is worth about the
-- same whichever plan they are on. Long-term plans carry most of the
-- opportunity because they hold over 3x as many users and churn almost
-- completely. Even the conservative scenario points to an opportunity of over
-- $700K a year, large enough to justify testing auto-renew on non-monthly
-- plans and measuring churn in the test group against these estimates.
