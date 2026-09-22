/*==========================================================
  이탈 예측 평균확률 오차(약 10.5%p) 원인 확인 - v3 수정본

  수정 내용
    1) 라벨 문자열의 "%p"가 SAS 매크로 호출로 해석되던 문제 수정
       (라벨에서 % 기호를 제거하고 "퍼센트포인트"로 표기)
    2) 4-0 조인 확인 쿼리에 FROM 절이 없어 구문 오류가 나던 문제 수정
       (SAS PROC SQL은 FROM 없는 SELECT를 허용하지 않음)

  사용하는 기존 산출물 (재학습·Python 없음, base SAS만 사용)
    CRM.W3_CHURN_SPLIT_V2      : 3.2 TRAIN/VALID 시간분리 데이터
    CRM.W3_CHURN_QA_SUMMARY    : 3.2 역할별 이탈률
    CRM.W4_MODEL_COMPARISON    : 4.1 VALID 성능 비교
    CRM.W4_CHURN_CALIBRATION   : 4.1 확률구간별 보정표
    CRM.W4_CHURN_VALID_SCORED  : 4.1 VALID 고객별 예측확률
    CRM.CLEAN_ONLINE           : 첫 구매일 확인용

  확인하려는 것
    1) 10/02 이후 첫 구매 고객이 VALID에 들어가 있는가
    2) 라벨 구간이 TRAIN/VALID 모두 90일인가
    3) 평균확률 오차가 TRAIN-VALID 이탈률 차이(기저율 변화)로 설명되는가
    4) 오차가 신규 고객/주문 횟수 등 특정 집단에 몰려 있는가
==========================================================*/

options validvarname=any;

%let CRM_PATH=/home/student/crm_db;
libname crm "&CRM_PATH.";


/*==========================================================
  0. 입력 테이블 확인
==========================================================*/

%macro require_table(ds=);

    %if %sysfunc(exist(&ds.))=0 %then %do;
        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %abort cancel;
    %end;

    %else %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;

%mend;

%require_table(ds=crm.w3_churn_split_v2);
%require_table(ds=crm.w3_churn_qa_summary);
%require_table(ds=crm.w4_model_comparison);
%require_table(ds=crm.w4_churn_calibration);
%require_table(ds=crm.w4_churn_valid_scored);
%require_table(ds=crm.clean_online);


/*==========================================================
  1. 기존 산출물 다시 보기
==========================================================*/

title "1-1. 역할별 실제 이탈률 (3.2 결과)";

proc print data=crm.w3_churn_qa_summary noobs label;
run;


/* ConstantBaseline의 평균확률 = TRAIN 이탈률입니다.
   RAW 모형의 평균확률이 이 값과 비슷하면 모형 예측이 TRAIN 기저율에
   가깝게 몰려 있다는 뜻입니다. */

title "1-2. VALID 성능 비교 (ConstantBaseline = TRAIN 이탈률 그대로 예측)";

proc print data=crm.w4_model_comparison noobs;

    var
        model_name
        probability_type
        customer_count
        actual_churn_rate
        mean_predicted_probability
        absolute_mean_gap
        roc_auc
        brier_score;

    format
        actual_churn_rate
        mean_predicted_probability
        absolute_mean_gap percent8.2
        roc_auc
        brier_score 8.4;

run;


title "1-3. 확률구간별 예측 vs 실제 (4.1 보정표)";

proc print data=crm.w4_churn_calibration noobs;

    var
        probability_type
        bin_number
        customer_count
        min_predicted_probability
        max_predicted_probability
        mean_predicted_probability
        observed_churn_rate
        calibration_gap
        is_selected;

    format
        min_predicted_probability
        max_predicted_probability
        mean_predicted_probability
        observed_churn_rate
        calibration_gap percent8.2;

run;


/*==========================================================
  2. pjh 가설 직접 검증: 관찰기간과 신규 고객
==========================================================*/

/* 2-1. 스냅샷별 라벨 구간 길이와 기준일 이후 첫 구매 고객 수
   label_days = 90, first_purchase_after_cutoff = 0 이면
   "90일을 못 채운 신규 고객이 VALID에 섞였다"는 가설은 성립하지 않습니다. */

title "2-1. 스냅샷별 라벨 구간과 기준일 이후 첫 구매 고객";

proc sql;

    select
        split_role,
        count(*) as customer_count,
        min(snapshot_cutoff) as snapshot_cutoff format=yymmdd10.,
        max(label_end_date)  as label_end_date  format=yymmdd10.,
        max(label_end_date) - min(snapshot_cutoff) as label_days,
        sum(first_purchase_date > snapshot_cutoff)
            as first_purchase_after_cutoff

    from crm.w3_churn_split_v2

    group by split_role;

quit;


/* 2-2. 원본 거래 기준 전체 고객 수와 10/02 이후 첫 구매 고객 수
   (3.2와 같은 유효 거래 조건 사용) */

proc sql;

    create table work.first_purchase as

    select
        customer_id,
        min(transaction_date) as first_date format=yymmdd10.

    from crm.clean_online

    where flag_missing_core = 0
      and flag_return = 0
      and flag_zero_quantity = 0
      and flag_invalid_price = 0
      and flag_customer_unmatched = 0

    group by customer_id;

quit;


title "2-2. 전체 고객 중 기준일 이후 첫 구매 고객 수";

proc sql;

    select
        count(*) as n_customers,
        sum(first_date > '30JUN2019'd) as n_first_after_0630,
        sum(first_date > '02OCT2019'd) as n_first_after_1002

    from work.first_purchase;

quit;


/*==========================================================
  3. 평균확률 오차 분해

  gap_pp             = VALID 평균 예측확률 - VALID 실제 이탈률
  base_rate_shift_pp = TRAIN 실제 이탈률  - VALID 실제 이탈률
  unexplained_pp     = gap_pp - base_rate_shift_pp
  (단위: 퍼센트포인트)

  gap_pp 가 base_rate_shift_pp 와 비슷하면
  오차의 대부분은 "기간에 따른 이탈률 변화"입니다.
==========================================================*/

proc sql noprint;

    select mean(churn_flag)
      into :train_rate trimmed
    from crm.w3_churn_split_v2
    where split_role = 'TRAIN';

    select
        mean(actual_churn_flag),
        mean(final_churn_probability)
      into
        :valid_rate trimmed,
        :valid_pred trimmed
    from crm.w4_churn_valid_scored;

quit;


data work.gap_decomp;

    train_actual_rate = &train_rate.;
    valid_actual_rate = &valid_rate.;
    valid_mean_pred   = &valid_pred.;

    gap_pp             = (valid_mean_pred - valid_actual_rate) * 100;
    base_rate_shift_pp = (train_actual_rate - valid_actual_rate) * 100;
    unexplained_pp     = gap_pp - base_rate_shift_pp;

    format
        train_actual_rate
        valid_actual_rate
        valid_mean_pred percent8.2

        gap_pp
        base_rate_shift_pp
        unexplained_pp 8.2;

    label
        train_actual_rate  = "TRAIN 실제 이탈률"
        valid_actual_rate  = "VALID 실제 이탈률"
        valid_mean_pred    = "VALID 평균 예측확률"
        gap_pp             = "평균확률 오차(예측-실제, 퍼센트포인트)"
        base_rate_shift_pp = "TRAIN-VALID 이탈률 차이(퍼센트포인트)"
        unexplained_pp     = "이탈률 차이로 설명 안 되는 부분(퍼센트포인트)";

run;


title "3. 평균확률 오차 분해";

proc print data=work.gap_decomp noobs label;
run;


/*==========================================================
  4. 오차가 몰린 집단 찾기 (VALID)
==========================================================*/

proc sql;

    create table work.valid_join as

    select
        s.snapshot_key,
        s.customer_id,
        s.first_purchase_date,
        s.frequency,
        s.churn_flag,
        v.final_churn_probability,

        case
            when s.first_purchase_date > '30JUN2019'd
                then 'NEW_AFTER_0630'
            else 'EXISTING_BY_0630'
        end as cust_group length=16,

        case
            when s.frequency = 1 then '1 order'
            when s.frequency = 2 then '2 orders'
            else '3+ orders'
        end as freq_group length=10

    from crm.w3_churn_split_v2 as s

    inner join crm.w4_churn_valid_scored as v
        on s.snapshot_key = v.snapshot_key

    where s.split_role = 'VALID';

quit;


/* SAS PROC SQL은 FROM 없는 SELECT를 허용하지 않으므로
   SASHELP.CLASS의 1행을 사용해 서브쿼리 결과를 한 줄로 출력합니다. */

title "4-0. 조인 확인: VALID 고객 수";

proc sql;

    select
        (select count(*)
           from crm.w3_churn_split_v2
          where split_role = 'VALID') as valid_rows_in_split,

        (select count(*)
           from work.valid_join) as joined_rows

    from sashelp.class(obs=1);

quit;


title "4-1. 신규(6/30 이후 첫 구매) vs 기존 고객";

proc sql;

    select
        cust_group,
        count(*) as n,
        mean(churn_flag) as actual_rate format=percent8.2,
        mean(final_churn_probability) as pred_mean format=percent8.2,
        (calculated pred_mean - calculated actual_rate) * 100
            as gap_pp format=8.2

    from work.valid_join

    group by cust_group;

quit;


title "4-2. 기준일 이전 주문 횟수별";

proc sql;

    select
        freq_group,
        count(*) as n,
        mean(churn_flag) as actual_rate format=percent8.2,
        mean(final_churn_probability) as pred_mean format=percent8.2,
        (calculated pred_mean - calculated actual_rate) * 100
            as gap_pp format=8.2

    from work.valid_join

    group by freq_group

    order by freq_group;

quit;


/*==========================================================
  5. 예측확률 분포
  분포가 좁으면 모형이 TRAIN 기저율 근처에서 거의 움직이지 않는다는 뜻입니다.
==========================================================*/

title "5. VALID 예측확률 분포";

proc means data=crm.w4_churn_valid_scored
    n mean std min p25 median p75 max
    maxdec=4;

    var final_churn_probability;

run;

title;


/*==========================================================
  VALID 이탈률 상승 원인 탐색

  질문
    같은 고객인데 7~9월(TRAIN 라벨 구간)보다 10~12월(VALID 라벨 구간)에
    90일 이탈률이 높아진 이유는 무엇인가?

  이 코드가 보여 주는 것
    A) 데이터 기간과 마지막 몇 주의 주문 수
       -> 12월 말 데이터가 끝부분에서 비어 있지는 않은가
    B) 월별 주문 수, 활성 고객 수, 신규 고객 수, 매출, 쿠폰 사용률,
       마케팅 비용, 평균 할인율
       -> 10~12월에 활동이나 마케팅이 줄었는가
    C) 여러 기준일(14일 간격)의 90일 이탈률 추이
       -> 추세적으로 오르는가, 10~12월만 튀는가
       -> 6/30 이전 첫 구매 고객만 따로 봐서 고객 구성 변화의 영향 제거

  사용 테이블 (모두 기존 산출물, base SAS만 사용)
    CRM.CLEAN_ONLINE, CRM.CLEAN_MARKETING, CRM.CLEAN_DISCOUNT
==========================================================*/

options validvarname=any;

%let CRM_PATH=/home/student/crm_db;
libname crm "&CRM_PATH.";

/* 이탈 라벨 윈도우(일)와 기준일 간격(일) */
%let WINDOW=90;
%let STEP=14;


/*==========================================================
  0. 입력 테이블 확인
==========================================================*/

%macro require_table(ds=);

    %if %sysfunc(exist(&ds.))=0 %then %do;
        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %abort cancel;
    %end;

    %else %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;

%mend;

%require_table(ds=crm.clean_online);
%require_table(ds=crm.clean_marketing);
%require_table(ds=crm.clean_discount);


/*==========================================================
  1. 유효 거래 행 준비 (3.2와 같은 조건)
==========================================================*/

data work.w_lines;

    set crm.clean_online;

    where flag_missing_core = 0
      and flag_return = 0
      and flag_zero_quantity = 0
      and flag_invalid_price = 0
      and flag_customer_unmatched = 0;

    txn_month = intnx('month', transaction_date, 0, 'beginning');

    line_amount = quantity * avg_price;

    coupon_used_line = (upcase(strip(coupon_status)) = 'USED');

    keep
        customer_id
        order_key
        transaction_date
        txn_month
        line_amount
        coupon_used_line;

run;


/* 고객별 첫 구매일 */
proc sql;

    create table work.w_first_raw as

    select
        customer_id,
        min(transaction_date) as first_date format=yymmdd10.

    from work.w_lines

    group by customer_id;

quit;

data work.w_first;

    set work.w_first_raw;

    first_month = intnx('month', first_date, 0, 'beginning');

    format first_month yymmn6.;

run;


/* 고객-구매일 단위로 중복을 없앤 테이블 */
proc sql;

    create table work.w_dates as

    select distinct
        customer_id,
        transaction_date

    from work.w_lines;

quit;


/* 데이터 시작일과 종료일 */
proc sql noprint;

    select
        min(transaction_date),
        max(transaction_date)
      into
        :d_min trimmed,
        :d_max trimmed
    from work.w_lines;

quit;

%put NOTE: 데이터 기간 = %sysfunc(putn(&d_min., yymmdd10.)) ~ %sysfunc(putn(&d_max., yymmdd10.));


/*==========================================================
  A. 데이터 기간과 최근 10주 주문 수
     마지막 주에 주문이 급감하면 데이터가 끝부분에서 덜 들어온
     것일 수 있습니다.
==========================================================*/

title "A-1. 유효 거래 데이터 기간";

proc sql;

    select
        min(transaction_date) as first_date format=yymmdd10.,
        max(transaction_date) as last_date  format=yymmdd10.,
        count(distinct order_key) as orders,
        count(distinct customer_id) as customers

    from work.w_lines;

quit;


title "A-2. 최근 10주 주간 주문 수와 활성 고객 수";

proc sql;

    select
        intnx('week', transaction_date, 0, 'beginning')
            as week_start format=yymmdd10.,
        count(distinct order_key) as orders,
        count(distinct customer_id) as active_customers

    from work.w_lines

    where transaction_date >= &d_max. - 70

    group by calculated week_start

    order by week_start;

quit;


/*==========================================================
  B. 월별 활동, 마케팅, 할인 요약
==========================================================*/

/* 월별 주문과 고객 */
proc sql;

    create table work.m_orders as

    select
        txn_month as ym format=yymmn6.,
        count(distinct order_key) as orders,
        count(distinct customer_id) as active_customers,
        sum(line_amount) as sales format=comma16.,
        mean(coupon_used_line) as coupon_used_line_rate format=percent8.2

    from work.w_lines

    group by txn_month;


    /* 월별 신규 고객(첫 구매 월 기준) */
    create table work.m_new as

    select
        first_month as ym format=yymmn6.,
        count(*) as new_customers

    from work.w_first

    group by first_month;

quit;


/* 월별 마케팅 비용 */
data work.w_mkt;

    set crm.clean_marketing;

    ym = intnx('month', marketing_date, 0, 'beginning');

    format ym yymmn6.;

run;

proc sql;

    create table work.m_mkt as

    select
        ym,
        sum(offline_cost) as offline_cost format=comma14.2,
        sum(online_cost)  as online_cost  format=comma14.2

    from work.w_mkt

    group by ym;

quit;


/* 월별 평균 할인율 (할인 테이블의 월은 Jan, Feb 같은 문자값입니다) */
data work.w_disc;

    set crm.clean_discount;

    month_no = month(input(cats('01', strip(discount_month), '2019'), date9.));

run;

proc sql;

    create table work.m_disc as

    select
        month_no,
        count(*) as discount_rows,
        mean(discount_pct) as avg_discount_pct format=8.2

    from work.w_disc

    group by month_no;

quit;


/* 한 표로 결합 */
proc sql;

    create table work.monthly_summary as

    select
        o.ym format=yymmn6.,
        o.orders,
        o.active_customers,
        n.new_customers,
        o.sales format=comma16.,
        o.coupon_used_line_rate format=percent8.2,
        m.offline_cost format=comma14.2,
        m.online_cost  format=comma14.2,
        (m.offline_cost + m.online_cost) as total_marketing_cost format=comma14.2,
        d.avg_discount_pct format=8.2,
        d.discount_rows

    from work.m_orders as o

    left join work.m_new as n
        on o.ym = n.ym

    left join work.m_mkt as m
        on o.ym = m.ym

    left join work.m_disc as d
        on month(o.ym) = d.month_no

    order by o.ym;

quit;


title "B. 월별 활동, 마케팅, 할인 요약";

proc print data=work.monthly_summary noobs label;

    label
        ym                   = "월"
        orders               = "주문 수"
        active_customers     = "활성 고객 수"
        new_customers        = "신규 고객 수"
        sales                = "매출"
        coupon_used_line_rate= "쿠폰 사용 행 비율"
        offline_cost         = "오프라인 마케팅비"
        online_cost          = "온라인 마케팅비"
        total_marketing_cost = "마케팅비 합계"
        avg_discount_pct     = "평균 할인율"
        discount_rows        = "할인 정보 행 수";

run;


/*==========================================================
  C. 여러 기준일의 90일 이탈률 추이

  정의는 3.2와 같습니다.
    기준일 이전에 한 번이라도 구매한 고객 중
    기준일 다음 날부터 90일 안에 구매가 없으면 이탈

  cohort_churn_rate
    6/30 이전에 첫 구매한 고객만 대상으로 한 이탈률입니다.
    같은 고객 집단이 시간에 따라 이탈이 늘었는지 봅니다.
    (기준일이 6/30 이후인 행부터 의미가 있습니다)

  data_covers_window
    라벨 구간의 마지막 날이 데이터 종료일 이내이면 1입니다.
==========================================================*/

data work.cutoffs;

    length cutoff_tag $12;
    format cutoff yymmdd10.;

    cutoff_tag = '';

    do cutoff = &d_min. + 30 to &d_max. - &WINDOW. by &STEP.;
        output;
    end;

    cutoff_tag = 'TRAIN_CUTOFF';
    cutoff = '30JUN2019'd;
    output;

    cutoff_tag = 'VALID_CUTOFF';
    cutoff = '02OCT2019'd;
    output;

    keep cutoff cutoff_tag;

run;

/* 같은 날짜가 겹치면 태그가 있는 행을 남깁니다. */
proc sort data=work.cutoffs;
    by cutoff descending cutoff_tag;
run;

proc sort data=work.cutoffs nodupkey;
    by cutoff;
run;


proc sql;

    /* 기준일 이전에 구매한 적이 있는 고객 */
    create table work.cb_base as

    select distinct
        c.cutoff,
        c.cutoff_tag,
        d.customer_id

    from work.cutoffs as c

    inner join work.w_dates as d
        on d.transaction_date <= c.cutoff;


    /* 기준일 다음 날부터 WINDOW일 안에 구매한 고객 */
    create table work.cb_active as

    select distinct
        c.cutoff,
        d.customer_id

    from work.cutoffs as c

    inner join work.w_dates as d
        on  d.transaction_date >  c.cutoff
        and d.transaction_date <= c.cutoff + &WINDOW.;


    create table work.churn_trend as

    select
        b.cutoff format=yymmdd10.,
        b.cutoff_tag,
        b.cutoff + &WINDOW. as window_end format=yymmdd10.,
        (calculated window_end <= &d_max.) as data_covers_window,

        count(*) as at_risk_customers,

        sum(case when a.customer_id is null then 1 else 0 end)
            as churned_customers,

        calculated churned_customers / calculated at_risk_customers
            as churn_rate format=percent8.2,

        sum(case when f.first_date <= '30JUN2019'd then 1 else 0 end)
            as cohort_customers,

        sum(case
                when f.first_date <= '30JUN2019'd
                 and a.customer_id is null then 1
                else 0
            end) as cohort_churned,

        calculated cohort_churned / calculated cohort_customers
            as cohort_churn_rate format=percent8.2

    from work.cb_base as b

    left join work.cb_active as a
        on  b.cutoff = a.cutoff
        and b.customer_id = a.customer_id

    left join work.w_first as f
        on b.customer_id = f.customer_id

    group by
        b.cutoff,
        b.cutoff_tag

    order by b.cutoff;

quit;


title "C-1. 기준일별 90일 이탈률 (TRAIN_CUTOFF=6/30, VALID_CUTOFF=10/02)";

proc print data=work.churn_trend noobs label;

    label
        cutoff             = "기준일"
        cutoff_tag         = "구분"
        window_end         = "라벨 구간 종료일"
        data_covers_window = "데이터가 라벨 구간을 덮는지(1=예)"
        at_risk_customers  = "대상 고객 수"
        churned_customers  = "이탈 고객 수"
        churn_rate         = "90일 이탈률(전체)"
        cohort_customers   = "6/30 이전 첫 구매 고객 수"
        cohort_churned     = "그 중 이탈 고객 수"
        cohort_churn_rate  = "90일 이탈률(6/30 이전 첫 구매 고객)";

run;


title "C-2. 기준일별 90일 이탈률 추이";

proc sgplot data=work.churn_trend;

    series x=cutoff y=churn_rate / markers;
    series x=cutoff y=cohort_churn_rate / markers;

    refline '30JUN2019'd '02OCT2019'd / axis=x;

    label
        churn_rate        = "전체 고객"
        cohort_churn_rate = "6/30 이전 첫 구매 고객만";

    format
        churn_rate
        cohort_churn_rate percent8.1;

    xaxis label="기준일";
    yaxis grid label="90일 이탈률";

run;

title;

