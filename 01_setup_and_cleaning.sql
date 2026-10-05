-- =============================================
-- KKBox Churn Analysis - Setup and Cleaning
-- Creates the 4 tables, then cleans each one before analysis.
-- Data: KKBox Churn Prediction Challenge (Kaggle) - train_v2, members_v3,
-- transactions_v2, user_logs + user_logs_v2. CSVs imported via DBeaver.
-- =============================================


-- =============================================
-- CREATE TABLES
-- =============================================

create table train (
    msno VARCHAR(100),
    is_churn INT
);

create table members (
    msno VARCHAR(100),
    city INT,
    bd INT,
    gender VARCHAR(10),
    registered_via INT,
    registration_init_time BIGINT
);

create table transactions (
    msno VARCHAR(100),
    payment_method_id INT,
    payment_plan_days INT,
    plan_list_price INT,
    actual_amount_paid INT,
    is_auto_renew INT,
    transaction_date INT,
    membership_expire_date INT,
    is_cancel INT
);

create table user_logs (
    msno VARCHAR(100),
    date INT,
    num_25 INT,
    num_50 INT,
    num_75 INT,
    num_985 INT,
    num_100 INT,
    num_unq INT,
    total_secs FLOAT
);



-- =============================================
-- TRANSACTIONS TABLE - DATA CLEANING
-- =============================================
-- SUMMARY: date columns converted to DATE; no nulls found; 2,218 rows with
-- payment_plan_days = 0 investigated and kept.
-- =============================================

-- 1. CHECK DATA TYPES
select column_name, data_type 
from information_schema.columns
where table_name = 'transactions';

-- 2. CONVERT DATE COLUMNS FROM INTEGER TO DATE
alter table transactions
alter column transaction_date type date
using to_date(transaction_date::text, 'yyyymmdd');

alter table transactions
alter column membership_expire_date type date
using to_date(membership_expire_date::text, 'yyyymmdd');

-- 3. CHECK FOR NULLS
-- null audit: no missing values in any column, no action needed.
select 
    count(*) - count(msno) as msno_nulls,
    count(*) - count(payment_method_id) as payment_method_nulls,
    count(*) - count(payment_plan_days) as payment_plan_nulls,
    count(*) - count(plan_list_price) as plan_list_nulls,
    count(*) - count(actual_amount_paid) as actual_amount_nulls,
    count(*) - count(is_auto_renew) as auto_renew_nulls,
    count(*) - count(transaction_date) as transaction_date_nulls,
    count(*) - count(membership_expire_date) as expire_date_nulls,
    count(*) - count(is_cancel) as is_cancel_nulls
from transactions;

-- 4. CHECK VALUE RANGES
select min(plan_list_price), max(plan_list_price) from transactions;
select min(actual_amount_paid), max(actual_amount_paid) from transactions;
select min(payment_plan_days), max(payment_plan_days) from transactions;
select min(transaction_date), max(transaction_date) from transactions;
select min(membership_expire_date), max(membership_expire_date) from transactions;

-- result: prices 0-2000 NTD, plan length 0-450 days. 7-day trial plans present.

-- 5. INVESTIGATE 0 VALUE ANOMALIES
-- rows with 0 payment plan days
select msno, plan_list_price, is_cancel, actual_amount_paid, payment_plan_days
from transactions
where payment_plan_days = 0;

-- count of 0 payment plan days, split by cancellation status
select count(*), is_cancel
from transactions
where payment_plan_days = 0
group by is_cancel;

-- found 2,218 rows (0.15%) with payment_plan_days = 0, most with is_cancel = 0
-- and some with actual_amount_paid > 0.
-- possible explanations: early cancellation before the plan period, or a
-- recording issue. Kept as-is; too few rows to affect the analysis.



-- =============================================
-- USER_LOGS TABLE - DATA CLEANING
-- =============================================
-- SUMMARY: converted date to DATE type, verified the date range and monthly
-- distribution look right, confirmed no other fields needed cleaning.
-- Imported user_logs.csv (full history) + user_logs_v2.csv (March 2017) into
-- one table. Verified 27 continuous months (Jan 2015 - Mar 2017), ~410M rows.
-- March 2017 count matched the v2-only figure, so the files combined cleanly.
-- =============================================

-- 1. CHECK DATA TYPES
select column_name, data_type 
from information_schema.columns
where table_name = 'user_logs';

-- 2. CONVERT DATE COLUMN FROM INTEGER TO DATE
alter table user_logs 
alter column date type date
using to_date(date::text, 'yyyymmdd');

-- 3. VERIFY DATE RANGE AND ROW COUNT
select min(date), max(date) from user_logs;
select count(*) from user_logs;

-- 4. VERIFY MONTHLY DISTRIBUTION (no missing months)
select date_trunc('month', date) as months, count(*) 
from user_logs
group by months
order by months;

-- result: no gaps. Monthly row counts trend upward over time (KKBox was
-- growing), so raw counts across years are inflated by growth - rates beat counts.



-- =============================================
-- MEMBERS TABLE - DATA CLEANING
-- =============================================
-- SUMMARY: registration_init_time converted to DATE; bd nulled outside 13-85
-- (67% were missing); gender '' converted to true NULL (65% empty);
-- city and registered_via checked but left as-is.
-- =============================================

-- 1. CHECK DATA TYPES
select
	column_name,
	data_type
from
	information_schema.columns
where
	table_name = 'members';


-- 2. CONVERT DATE COLUMN FROM UNIX TIMESTAMP TO DATE
-- Kaggle docs list this field as %Y%m%d (e.g. 20170331), but the actual data
-- holds millisecond Unix timestamps (e.g. 1315695600000). to_date failed;
-- investigated the raw values and converted via to_timestamp(... / 1000).
alter table members
alter column registration_init_time type date
	using to_timestamp(registration_init_time / 1000)::date;


-- 3. AGE (bd) - CHECK VALUE RANGE
select
	min(bd) as youngest,
	max(bd) as oldest,
	avg(bd) as average_raw_value
from
	members;

-- found: -7168 to 2016 - clearly junk (negative ages, birth years mixed in)


-- 4. AGE (bd) - QUANTIFY HOW BAD IT IS
select 
   count(*) as total,
   count(case when bd between 13 and 85 then 1 end) as plausible,
   count(case when bd = 0 then 1 end) as zeros,
   count(case when bd < 0 then 1 end) as negative,
   count(case when bd > 85 then 1 end) as too_high
from members;

-- result: 33% plausible (2.22M of 6.77M), 67% are 0 (4.54M),
-- negatives and out-of-range both <0.1%.
-- bd = 0 is implausible as a real age - most likely a missing-data placeholder.


-- 5. AGE (bd) - CLEAN
-- Null out implausible ages (outside 13-85). Range chosen to be generous enough
-- to keep genuine older users while removing obvious nonsense.
-- Chose not to convert birth-year-looking values into ages: bd is a static
-- snapshot with no capture date to subtract from, so converting would stack a
-- guess on a guess and fabricate data. Preserved integrity over salvaging values.
update
	members
set
	bd = null
where
	bd not between 13 and 85;
 
select count(case when bd is null then 1 end) as missing_age from members;

-- result: ~4.55M rows now null (~67% of users). Surviving ages average ~29,
-- consistent with a young streaming audience.


-- 6. GENDER - CHECK DISTRIBUTION
select
	count(*),
	gender
from
	members
group by
	gender;


-- 7. GENDER - CHECK NULLS VS EMPTY STRINGS
select
	count(case when gender is null then 1 end) as true_null,
	count(case when gender = '' then 1 end) as empty_string
from members;

-- result: 4.43M empty strings (~65%), 0 true nulls


-- 8. GENDER - CLEAN
-- Convert empty strings to true NULL so IS NULL filters behave correctly
update
	members
set
	gender = null
where
	gender = '';


-- 9. CITY - CHECK DISTRIBUTION
select count(*), city
from members
group by city;

-- result: codes run cleanly 1-22, no negatives or junk. No action needed.
-- City 1 holds ~4.8M users (~71%). Given Taiwan's population is concentrated
-- in a few major cities, this is most likely Taipei rather than a default value.


-- 10. THE MISSING-DEMOGRAPHICS PATTERN
-- Age (~67%), gender (~65%) and city 1 (~71%) are all heavily concentrated.
-- Testing whether missing gender is random or clusters by registration path.
select
	registered_via,
	count(*) as total_users,
	count(case when gender is null then 1 end) as missing_gender
from
	members
group by
	registered_via
order by
	total_users desc;

-- result: missing gender is NOT spread evenly - it clusters by method:
--   method 4: 2.79M users, 2.54M missing (~91%)
--   method 7: 806K users, 691K missing (~86%)
--   method 9: 1.48M users, 732K missing (~49%)
--   method 3: 1.64M users, 432K missing (~26%)



-- =============================================
-- TRAIN TABLE - CHECK
-- =============================================
-- SUMMARY: is_churn contains only 0/1, no nulls. No cleaning needed.
-- =============================================

-- 1. CHECK DATA TYPES
select
	column_name,
	data_type
from
	information_schema.columns
where
	table_name = 'train';

-- 2. CHECK VALUES
select is_churn, count(*)
from train
group by is_churn;

-- 3. BASELINE CHURN RATE
select round(avg(is_churn) * 100, 2) as churn_rate_pct
from train;

-- result: ~9% (87,330 of 970,960). Data is imbalanced (91/9), so all
-- segments are compared by churn RATE against this baseline, not raw counts.
