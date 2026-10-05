-- =====================================================
-- KKBox Churn Analysis - Data Quality Checks
-- Run after 01_setup_and_cleaning.sql.
-- Before any analysis: which train users can actually be analysed, are the
-- ones who can't be different, and does the exposure window hold up?
-- Baseline churn rate (~9%) is calculated in 01_setup_and_cleaning.sql.
-- =====================================================



-- =====================================================
-- SECTION A: COVERAGE - DO TRAIN USERS HAVE THE DATA WE NEED?
-- =====================================================

-- 1. Do all train users have a member record?
-- Assumption: "missing" = no row in members.
select
	count(*) as in_train,
	count(case when m.msno is null then 1 end) as no_member_detail
from
	train t
left join members m
on
	t.msno = m.msno;

-- result: 109,993 of 970,960 (11%) have no member record.


-- 2. Why are users missing? (no transaction, no member row, or both)
-- Exposure needs a member row (registration date) AND a transaction
-- (membership expiry date), so a user missing either can't be analysed.
with last_txn as (
    select msno,
           row_number() over (partition by msno order by transaction_date desc) as rn
    from transactions
    where transaction_date <= '2017-03-31'
)
select
    case when lt.msno is null and m.msno is null then 'missing both'
         when lt.msno is null then 'missing transaction'
         when m.msno is null  then 'missing member row'
         else 'has both' end as status,
    count(*) as users,
    round(avg(t.is_churn) * 100, 2) as churn_rate_pct
from train t
left join (select msno from last_txn where rn = 1) lt on lt.msno = t.msno
left join members m on m.msno = t.msno
group by 1
order by users desc;

-- result:
--   has both            825,368 users   6.52% churn
--   missing member row  108,210 users   3.81% churn
--   missing transaction  35,599 users  77.73% churn
--   missing both          1,783 users  98.93% churn
-- (total 970,960 - every train user accounted for)
-- The ~23% churn among dropped users is driven almost entirely by users
-- with no transaction record, who churn at very high rates. Users missing
-- only a member row churn BELOW baseline. Cause of the missing records
-- can't be determined from the data, so this is logged as a limitation.


-- 3. Who ends up in the analysis, and are the dropped users different?
with last_txn as (
    select msno, membership_expire_date,
           row_number() over (partition by msno order by transaction_date desc) as rn
    from transactions
    where transaction_date <= '2017-03-31'
),
exposure as (
    select lt.msno,
           (least('2017-03-31', lt.membership_expire_date)
            - greatest('2017-01-01', m.registration_init_time)) + 1 as possible_exposure_days
    from last_txn lt
    join members m on lt.msno = m.msno
    where lt.rn = 1
)
select
    case when e.msno is null then 'dropped: no txn or no member row'
         when e.possible_exposure_days <= 0 then 'dropped: expired before Jan 1'
         else 'kept' end as status,
    count(*) as users,
    round(avg(t.is_churn) * 100, 2) as churn_rate_pct
from train t
left join exposure e on e.msno = t.msno
group by 1;

-- result: kept = 825,367 (6.51% churn)
--         dropped: no txn or no member row = 145,592 (~23% churn)
--         dropped: expired before Jan 1 = 1
-- implication: the analysed users churn well below the 9% baseline because
-- the dropped group churns heavily. Churn rates in this analysis are best read
-- as comparisons BETWEEN segments, not as KKBox's overall churn level.



-- =====================================================
-- SECTION B: LISTENING HISTORY
-- =====================================================

-- 4. Which train users have Jan - Mar 2017 listening history?
-- Assumption: history = at least one log row in the window.
-- Date filter sits in ON, not WHERE, so the LEFT JOIN keeps non-listeners.
select
	count(distinct t.msno) as in_train,
	count(case when u.msno is null then 1 end) as no_user_log,
	count(distinct case when u.msno is not null then t.msno end) as have_user_log
from train t
left join user_logs u on
	t.msno = u.msno
	and u.date between '2017-01-01' and '2017-03-31';


-- 5. Do users with no listening history churn at a different rate?
select
	count(*) as no_history,
	round(avg(is_churn) * 100, 2) as churn_rate_pct
from
	train t
left join user_logs u
  on
	t.msno = u.msno
	and u.date between '2017-01-01' and '2017-03-31'
where
	u.msno is null;

-- result: 176,132 users (18%) with no listening history churn at 6.90%,
-- BELOW the 9% baseline. Unexpected - followed up in the analysis
-- (auto-renew / passive renewal).



-- =====================================================
-- SECTION C: EXPOSURE WINDOW SANITY CHECK
-- =====================================================

-- 6. Does any user have an active day rate above 100%?
-- Active days should never exceed the days a user could have been active.
-- Exposure window = from the later of Jan 1 or registration date,
-- to the earlier of Mar 31 or membership expiry.
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
        round(a.active_days * 1.0 / e.possible_exposure_days, 4) as active_day_rate
    from active_days a
    join exposure e on a.msno = e.msno
    where e.possible_exposure_days > 0
)
select count(*) as total,
       count(*) filter (where active_day_rate > 1) as impossible,
       round(max(active_day_rate), 2) as worst
from user_rates;

-- result: total = 825,367 | impossible = 891 (0.1%) | worst = 28.00
-- Diagnosed: all 891 listened after their membership expiry date, and 864 of
-- them had a cancellation as their latest transaction. Cancellation rows carry
-- an early expiry date, but users kept access (likely until their paid period
-- ended), so the window end is too early for them.
-- Decision: kept as-is. These users already fall in the top activity bucket,
-- where genuinely heavy listeners belong, and at 0.1% they do not change any
-- finding.
-- Flag for the data team: membership_expire_date on a cancellation row does not
-- reflect when access actually ended. Any analysis relying on that date as a
-- true end-of-access point needs to account for this.
