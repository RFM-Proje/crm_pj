/*=============================================================
  STAGE 4. 이탈예측 (90일 기준 검증 + 시점분리 재구성 모델링)
  = eda_90day_churn_window_check.sas + week6d_churn_temporal_split.sas
  (week6a는 데이터 누수 문제로 폐기, week6d로 일원화)
  전제조건: STAGE 1, STAGE 2 실행 완료
  산출물: proj.churn_window_compare, proj.churn_split_v2, proj.churn_scored_v2

  [v3 수정] churn_improvement.py 실험(30/60/90일 라벨윈도우 전부에서
  AUC 개선 확인)에서 검증된 확장 피처 6종(이용카테고리수, 주이용카테고리
  집중도, 재구매간격평균/표준편차, 마지막쿠폰_Used, CLV)을 정식
  churn_split_v2 생성 과정(PART B 섹션 4)과 GRADBOOST 입력변수에 반영.
=============================================================*/

/* ============================= PART A. 90일 이탈 기준 적정성 검증 EDA ============================= */
/*=============================================================
  EDA. 이탈 라벨 윈도우(90일) 적정성 검증
  - week6d_churn_temporal_split.sas가 이미 "label_window_days=90
    (여기 숫자만 바꾸면 30/60/90 등 실험 가능)"이라고 준비해둔
    지점을 실제로 검증하는 스크립트
  - week6d와 동일하게 "cutoff 이전 = 피처, cutoff 이후 = 라벨"
    구조(시점분리)를 그대로 따름 (데이터 누수 방지)

  전제조건: week1_data_cleaning_merged.sas, week2_rfm_derived_merged.sas
  실행 후 proj.sales_clean, proj.sales_with_disc 가 존재해야 함

  이 스크립트가 답하는 질문:
  1) 고객들의 실제 재구매 간격은 며칠 정도인가? (90일이 그 분포에서
     어디쯤 위치하는가)
  2) 라벨 윈도우를 30/60/90/120일로 바꾸면 이탈률이 어떻게 달라지는가?
     (너무 짧으면 대부분 "이탈 아님"으로, 너무 길면 대부분 "이탈"로
     쏠려 모델이 변별력을 잃을 수 있음)
=============================================================*/

libname proj "/home/student/open";


/* -------------------------------------------------------------
   0. 관측 기간 확인 - 전체 데이터가 며칠 치인지부터 확인
   (90일이라는 숫자가 전체 기간 대비 얼마나 큰 비중인지 판단 기준)
------------------------------------------------------------- */
proc sql;
    select min(거래날짜_num) format=yymmdd10. as 최초거래일,
           max(거래날짜_num) format=yymmdd10. as 최종거래일,
           max(거래날짜_num) - min(거래날짜_num) + 1 as 전체관측일수
    from proj.sales_clean;
    title "0. 전체 관측 기간 - 90일이 전체 기간의 몇 % 인지 판단용";
quit;
title;


/* -------------------------------------------------------------
   1. 고객별 재구매 간격(inter-purchase interval) 분포
   - 거래ID(주문) 단위로 압축한 뒤, 고객별 거래일을 정렬해서
     연속된 두 주문 사이의 간격(일)을 계산
   - 재구매를 2번 이상 한 고객만 간격이 생기므로, 그 고객들만 대상
------------------------------------------------------------- */
proc sql;
    create table work.order_dates as
    select distinct 고객ID, 거래ID, 거래날짜_num
    from proj.sales_with_disc;
quit;

proc sort data=work.order_dates;
    by 고객ID 거래날짜_num;
run;

data work.purchase_gap;
    set work.order_dates;
    by 고객ID;
    retain 이전거래일;
    if first.고객ID then do;
        이전거래일 = 거래날짜_num;
        재구매간격 = .;
    end;
    else do;
        재구매간격 = 거래날짜_num - 이전거래일;
        이전거래일 = 거래날짜_num;
        output;
    end;
    format 거래날짜_num 이전거래일 yymmdd10.;
    keep 고객ID 거래날짜_num 재구매간격;
run;

/* 재구매 간격 기초통계 + 백분위수 - 90일이 P?? 에 해당하는지 직접 확인 */
proc means data=work.purchase_gap n mean std min p10 p25 p50 p75 p90 p95 max;
    var 재구매간격;
    title "1-1. 재구매 간격(일) 분포 - 90일이 어느 백분위수쯤인지 확인";
run;
title;

/* 90일 기준 초과/이하 비율 - "재구매 간격이 90일보다 긴 경우"가
   전체 재구매 간격 중 얼마나 되는지 직접 카운트 */
proc sql;
    select count(*) as 전체_재구매간격수,
           sum(case when 재구매간격 > 90 then 1 else 0 end) as 초과90일_건수,
           calculated 초과90일_건수 / calculated 전체_재구매간격수 * 100 as 초과90일_비율
    from work.purchase_gap;
    title "1-2. 재구매 간격이 90일을 넘는 비중 (너무 크면 90일 기준이 느슨할 수 있음)";
quit;
title;

proc sgplot data=work.purchase_gap;
    histogram 재구매간격 / binwidth=7;
    refline 90 / axis=x lineattrs=(color=red thickness=2 pattern=dash)
                 label="90일 기준" labelattrs=(color=red);
    xaxis label="재구매 간격(일)";
    yaxis label="건수";
    title "1-3. 재구매 간격 분포와 90일 기준선";
run;
title;


/* -------------------------------------------------------------
   2. Recency 분포와 90일 기준선 (전체 고객 기준, 관측 마지막 시점)
------------------------------------------------------------- */
proc sql noprint;
    select max(거래날짜_num) + 1 into :ref_date
    from proj.sales_with_disc;
quit;

proc sql;
    create table work.recency_check as
    select 고객ID, &ref_date - max(거래날짜_num) as Recency
    from proj.sales_with_disc
    group by 고객ID;
quit;

proc sgplot data=work.recency_check;
    histogram Recency / binwidth=7;
    refline 90 / axis=x lineattrs=(color=red thickness=2 pattern=dash)
                 label="90일 기준" labelattrs=(color=red);
    xaxis label="Recency(일)";
    yaxis label="고객수";
    title "2-1. 전체 고객 Recency 분포와 90일 기준선";
run;
title;


/* -------------------------------------------------------------
   3. 라벨 윈도우 후보(30/60/90/120일)별 이탈률 비교
   - week6d와 동일한 시점분리(cutoff) 구조를 그대로 사용
   - cutoff는 최장 후보(120일)까지도 관측기간 안에 들어오도록
     여유 있게 중간 지점으로 고정 (윈도우 간 공정 비교를 위해
     후보마다 cutoff를 다르게 잡지 않음)
------------------------------------------------------------- */
%let cutoff_date = '30JUN2019'd;  /* 데이터가 2019-01-01~12-31이라는
                                      week4 확인 결과 기준 - 본인 데이터의
                                      실제 최초/최종 거래일에 맞게 수정 */

%macro check_window(window=);

    %let label_end = %sysfunc(intnx(day, &cutoff_date, &window), date9.);
    %let label_end = "&label_end"d;

    /* cutoff 이전 = 피처 기간, cutoff~label_end = 라벨 기간 */
    data work.trans_feature_&window work.trans_label_&window;
        set proj.sales_clean;
        if 거래날짜_num <= &cutoff_date then output work.trans_feature_&window;
        else if &cutoff_date < 거래날짜_num <= &label_end then output work.trans_label_&window;
    run;

    /* cutoff 이전에 거래가 있던 고객(분석 대상 모집단) */
    proc sql;
        create table work.base_&window as
        select distinct 고객ID from work.trans_feature_&window;
    quit;

    /* 라벨 기간에 거래가 있으면 이탈 아님(0), 없으면 이탈(1) */
    proc sql;
        create table work.active_&window as
        select distinct 고객ID from work.trans_label_&window;
    quit;

    data work.churn_&window;
        merge work.base_&window(in=a) work.active_&window(in=b);
        by 고객ID;
        if a;
        이탈여부 = (not b);
        윈도우 = &window;
    run;

    proc sql;
        create table work.churn_summary_&window as
        select 윈도우,
               count(*) as 전체고객수,
               sum(이탈여부) as 이탈고객수,
               calculated 이탈고객수 / calculated 전체고객수 * 100 as 이탈률_pct
        from work.churn_&window;
    quit;

%mend check_window;

%check_window(window=30);
%check_window(window=60);
%check_window(window=90);
%check_window(window=120);

data proj.churn_window_compare;
    set work.churn_summary_30 work.churn_summary_60
        work.churn_summary_90 work.churn_summary_120;
run;

proc print data=proj.churn_window_compare noobs;
    title "3-1. 라벨 윈도우별 이탈률 비교 (30/60/90/120일) - cutoff 2019-06-30 기준";
    var 윈도우 전체고객수 이탈고객수 이탈률_pct;
run;
title;

proc sgplot data=proj.churn_window_compare;
    vbar 윈도우 / response=이탈률_pct datalabel;
    xaxis label="라벨 윈도우(일)" type=discrete;
    yaxis label="이탈률(%)" grid;
    title "3-2. 라벨 윈도우 길이에 따른 이탈률 변화 - 너무 평평하거나(변별력 없음) 극단(0%/100%)이면 그 윈도우는 부적절";
run;
title;

/* -------------------------------------------------------------
   4. 해석 가이드 (주석)
   - 1번 결과에서 90일이 재구매간격 분포의 P90 근처보다 훨씬
     왼쪽(예: P50~P60)에 있다면, 정상적으로 재구매할 고객까지
     "이탈"로 잘못 분류할 위험이 있음 -> 윈도우를 늘리는 것을 고려
   - 3번 결과에서 이탈률이 30/60/90/120 사이에 큰 차이 없이
     평평하다면, 실제로는 재구매 리듬이 뚜렷하지 않다는 뜻일 수
     있어 "이탈"이라는 이분법 자체를 재검토할 필요가 있음
   - 이탈률이 특정 구간(예: 60→90일)에서 급격히 꺾인다면, 그
     지점이 실제 고객 행동상의 자연스러운 분기점일 가능성이 높음
------------------------------------------------------------- */

/* ============================= PART B. 시점분리(Temporal Split) 이탈예측 모델링 ============================= */
/*=============================================================
  WEEK 6d. 이탈예측 - 시점 분리(Temporal Split) 재구성

  문제의식: 기존(week6a) 방식은 Frequency/Monetary/AvgOrderValue 등을
  "전체 관측기간(1년치)" 거래로 계산하고, 이탈여부도 같은 전체기간의
  Recency로 정의했음. 이러면 "일찍 이탈한 고객은 그 뒤로 거래가 없어서
  Frequency/Monetary가 낮게 멈춘 것"과 "Frequency가 낮아서 이탈한 것"이
  뒤섞임 (인과관계 역전 / 정보 누수). AUC 0.9107이 비현실적으로 높았던
  이유일 가능성이 큼.

  해결: 기준일(cutoff)을 하나 잡아서
    - 피처(설명변수): cutoff 이전 거래만 사용
    - 라벨(이탈여부): cutoff 이후 90일간 거래가 있었는지로 결정
  이러면 "과거 행동 → 미래 이탈" 구조가 되어 데이터 누수가 없어짐.

  기준일: 2019-10-02 (그 뒤 정확히 90일 = 10/3~12/31 남음,
          기존 "Recency>90" 정의와 기간 길이를 맞추기 위한 선택)

  [주의 - 확인 필요한 가정들]
  1) proj.sales_clean이 원본 Onlinesales_info와 동일 컬럼 구조라고 가정
     (고객ID 거래ID 거래날짜 제품ID 제품카테고리 수량 평균금액 배송료 쿠폰상태)
     다르면 아래 "0. 원본 확인" 단계에서 proc contents 결과 보고 조정 필요
  2) 쿠폰상태 값이 'Used'/'Clicked'/'Not Used' 3단계라고 가정
     - 실제 값이 다르면 CouponUseRate/CouponClickRate 계산 부분 수정 필요
  3) 데이터가 2019-01-01~2019-12-31 전체 365일 존재한다는 전제
     (4주차 변화점 스크리닝에서 확인된 사실)
=============================================================*/

libname proj "/home/student/open";

%if %sysfunc(sessfound(mysession)) = 0 %then %do;
    cas mysession;
%end;
libname mycas cas caslib="casuser";

%let cutoff_date = '02OCT2019'd;
%let label_window_days = 90;  /* 여기 숫자만 바꾸면 30/60/90 등 실험 가능 */
%let label_end = %sysfunc(intnx(day, &cutoff_date, &label_window_days), date9.);
%let label_end = "&label_end"d;


/* -------------------------------------------------------------
   0. 원본 확인 - proj.sales_clean 컬럼 구조가 가정과 맞는지 체크
------------------------------------------------------------- */
proc contents data=proj.sales_clean varnum;
    title "0. [확인용] proj.sales_clean 컬럼 구조 - 고객ID/거래ID/거래날짜/평균금액/배송료/쿠폰상태 있는지 확인";
run;
title;


/* -------------------------------------------------------------
   0-1. [선택/진단용] proj 라이브러리 전체 테이블 목록 - discount_info가
   실제로 어떤 이름으로 저장되어 있는지 찾고 싶으면 이 스텝 결과 확인
------------------------------------------------------------- */
proc datasets library=proj memtype=data;
    title "0-1. [진단용] proj 라이브러리 전체 테이블 목록";
quit;
title;


/* -------------------------------------------------------------
   1. 피처 윈도우 / 라벨 윈도우 거래 분리
------------------------------------------------------------- */
data work.trans_feature work.trans_label;
    set proj.sales_clean;
    if 거래날짜_num <= &cutoff_date then output work.trans_feature;
    else if &cutoff_date < 거래날짜_num <= &label_end then output work.trans_label;
run;


/* -------------------------------------------------------------
   2. 거래(주문) 단위 중복 압축 - 배송료/평균금액은 거래ID당 1개값이므로
   line-item 단위로 바로 평균내면 다품목 주문이 중복 반영됨 (기존 프로젝트에서
   확인된 버그 패턴과 동일한 원리로 방지)
------------------------------------------------------------- */
proc sql;
    create table work.trans_dedup as
    select 고객ID, 거래ID, 거래날짜_num,
           sum(평균금액 * 수량) as order_total,
           mean(배송료) as order_shipping
    from work.trans_feature
    group by 고객ID, 거래ID, 거래날짜_num;
quit;


/* -------------------------------------------------------------
   3. 고객단위 RFM류 피처 생성 (전부 cutoff 이전 데이터만 사용)
------------------------------------------------------------- */
proc sql;
    create table work.customer_rfm as
    select 고객ID,
           &cutoff_date - max(거래날짜_num) as Recency,
           count(distinct 거래ID) as Frequency,
           sum(order_total) as Monetary,
           mean(order_total) as AvgOrderValue,
           mean(order_shipping) as AvgShipping
    from work.trans_dedup
    group by 고객ID;
quit;

/* 쿠폰 관련 지표 - line-item 단위 비율 (거래 단위가 아니라 상품 단위 행동이라
   line-item 그대로 사용하는 게 맞음) */
proc sql;
    create table work.customer_coupon as
    select 고객ID,
           mean(쿠폰상태 = "Used") as CouponUseRate,
           mean(쿠폰상태 in ("Used","Clicked")) as CouponClickRate
    from work.trans_feature
    group by 고객ID;
quit;

/* [주의] proj.discount_info 테이블을 못 찾아서 AvgDiscountRate는 일단 제외.
   나중에 실제 테이블명 확인되면 이 블록 복원 예정 */



/* -------------------------------------------------------------
   3-1. [확인용] 새로 만든 피처들 분포 확인 - 계산 버그 조기 발견 목적
   (기존 프로젝트에서 배송료/객단가 계산 버그가 있었던 전례가 있어서
   이번에도 눈으로 한 번 확인하고 넘어가는 게 안전함)
------------------------------------------------------------- */
proc means data=work.customer_rfm n nmiss mean std min p50 max;
    var Recency Frequency Monetary AvgOrderValue AvgShipping;
    title "3-1. 새 피처 기술통계 - 이상치/결측 여부 확인";
run;
title;

proc sgplot data=work.customer_rfm;
    histogram Frequency;
    title "3-2. Frequency 분포 (cutoff 이전 9개월 기준)";
run;
title;

proc sgplot data=work.customer_rfm;
    histogram Recency;
    title "3-3. Recency 분포 (cutoff 시점 기준)";
run;
title;


/* -------------------------------------------------------------
   4. [신규] 확장 피처 생성 - churn_improvement.py 실험(3개 라벨윈도우
   30/60/90일 전부에서 AUC 개선 확인)에서 검증된 변수 6개를 정식
   파이프라인에 반영. DACON 코드공유(고객세분화 대회) 참고.
------------------------------------------------------------- */

/* 4-1. 이용카테고리수 - cutoff 이전 구매해본 제품카테고리 종류 수 */
proc sql;
    create table work.customer_num_cat as
    select 고객ID, count(distinct 제품카테고리) as 이용카테고리수
    from work.trans_feature
    group by 고객ID;
quit;

/* 4-2. 주이용카테고리집중도 - 가장 많이 산 카테고리 구매횟수 / 전체 구매횟수
   (1에 가까울수록 한 카테고리에 몰빵, 낮을수록 여러 카테고리 고루 구매) */
proc sql;
    create table work.customer_cat_counts as
    select 고객ID, 제품카테고리, count(*) as cnt
    from work.trans_feature
    group by 고객ID, 제품카테고리;
quit;

proc sql;
    create table work.customer_cat_total as
    select 고객ID, sum(cnt) as total_cnt, max(cnt) as top_cnt
    from work.customer_cat_counts
    group by 고객ID;
quit;

data work.customer_cat_ratio;
    set work.customer_cat_total;
    주이용카테고리집중도 = top_cnt / total_cnt;
    keep 고객ID 주이용카테고리집중도;
run;

/* 4-3. 재구매간격평균/표준편차 - work.trans_dedup(거래 단위, cutoff 이전
   피처 윈도우 내)의 거래일 간 간격 통계. 1번 섹션의 purchase_gap과 동일한
   계산 로직을 cutoff 이전 데이터로 한정해서 재적용 (데이터 누수 방지) */
proc sort data=work.trans_dedup out=work.dedup_sorted;
    by 고객ID 거래날짜_num;
run;

data work.gap_calc;
    set work.dedup_sorted;
    by 고객ID;
    retain 이전거래일;
    if first.고객ID then do;
        이전거래일 = 거래날짜_num;
        gap_days = .;
    end;
    else do;
        gap_days = 거래날짜_num - 이전거래일;
        이전거래일 = 거래날짜_num;
    end;
    if not missing(gap_days) then output;
    keep 고객ID gap_days;
run;

proc means data=work.gap_calc noprint nway;
    class 고객ID;
    var gap_days;
    output out=work.customer_gap_stats(drop=_type_ _freq_)
        mean=재구매간격평균 std=재구매간격표준편차;
run;
/* [주의] 재구매를 1번도 안 한(cutoff 이전 거래일이 하루뿐인) 고객은
   여기서 빠짐 -> churn_split_v2에 LEFT JOIN되면서 결측(.)이 되는데,
   GRADBOOST는 결측값을 서로게이트 분리로 처리하므로 별도 대체 없이
   그대로 둠 (기존 CouponUseRate 등도 동일한 방식) */

/* 4-4. 마지막쿠폰_Used - cutoff 이전 마지막 거래(line-item 기준 최신
   거래일)에서 쿠폰을 실제로 썼는지 여부 */
proc sort data=work.trans_feature out=work.trans_feature_sorted;
    by 고객ID 거래날짜_num;
run;

data work.customer_last_coupon;
    set work.trans_feature_sorted;
    by 고객ID;
    if last.고객ID;
    마지막쿠폰_Used = (쿠폰상태 = "Used");
    keep 고객ID 마지막쿠폰_Used;
run;

/* 4-5. CLV = 가입기간(년) x 평균구매금액 x 평균구매빈도(연 환산)
   (DACON 코드공유 공식 그대로 적용, window_days로 Frequency를 연 단위로 환산) */
proc sql noprint;
    select &cutoff_date - min(거래날짜_num) into :window_days trimmed
    from work.trans_feature;
quit;
%let window_days = %sysfunc(max(&window_days, 1));

proc sql;
    create table work.customer_clv as
    select a.고객ID,
           (e.가입기간/12) * a.AvgOrderValue * (a.Frequency / (&window_days/365)) as CLV
    from work.customer_rfm as a
    inner join (select distinct 고객ID, 가입기간 from proj.customer_segments) as e
      on a.고객ID = e.고객ID;
quit;

/* 4-6. [확인용] 확장 피처 기술통계 - 계산 버그 조기 발견 목적 */
proc means data=work.customer_num_cat n nmiss mean std min p50 max;
    var 이용카테고리수;
    title "4-6a. 이용카테고리수 기술통계";
run;
proc means data=work.customer_cat_ratio n nmiss mean std min p50 max;
    var 주이용카테고리집중도;
    title "4-6b. 주이용카테고리집중도 기술통계";
run;
proc means data=work.customer_gap_stats n nmiss mean std min p50 max;
    var 재구매간격평균 재구매간격표준편차;
    title "4-6c. 재구매간격 기술통계";
run;
proc means data=work.customer_clv n nmiss mean std min p50 max;
    var CLV;
    title "4-6d. CLV 기술통계";
run;
title;


proc sql;
    create table work.customer_label as
    select distinct 고객ID, 0 as 이탈여부
    from work.trans_label;
quit;

/* trans_feature에 등장한 모든 고객 기준으로, label에 없으면 이탈=1 */
proc sql;
    create table work.customer_base as
    select distinct 고객ID from work.trans_feature;
quit;

data work.customer_churn;
    merge work.customer_base(in=a) work.customer_label(in=b);
    by 고객ID;
    if a;
    if not b then 이탈여부 = 1;
run;


/* -------------------------------------------------------------
   5. 전부 병합 + Customer_info(정적 속성) 조인
------------------------------------------------------------- */
proc sql;
    create table proj.churn_split_v2 as
    select a.고객ID, a.이탈여부,
           b.Recency, b.Frequency, b.Monetary, b.AvgOrderValue, b.AvgShipping,
           c.CouponUseRate, c.CouponClickRate,
           e.가입기간, e.성별, e.고객지역,
           f.이용카테고리수, g.주이용카테고리집중도,
           h.재구매간격평균, h.재구매간격표준편차,
           i.마지막쿠폰_Used, j.CLV
    from work.customer_churn as a
    inner join work.customer_rfm as b on a.고객ID = b.고객ID
    left join work.customer_coupon as c on a.고객ID = c.고객ID
    inner join (select distinct 고객ID, 가입기간, 성별, 고객지역 from proj.customer_segments) as e
      on a.고객ID = e.고객ID
    left join work.customer_num_cat as f on a.고객ID = f.고객ID
    left join work.customer_cat_ratio as g on a.고객ID = g.고객ID
    left join work.customer_gap_stats as h on a.고객ID = h.고객ID
    left join work.customer_last_coupon as i on a.고객ID = i.고객ID
    left join work.customer_clv as j on a.고객ID = j.고객ID;
quit;

/* TRAIN/VALID 분할 (기존과 동일한 방식·seed) */
data proj.churn_split_v2;
    set proj.churn_split_v2;
    call streaminit(2026);
    if rand("uniform") < 0.7 then 구분 = "TRAIN";
    else 구분 = "VALID";
run;

data mycas.churn_split_v2;
    set proj.churn_split_v2;
run;

proc freq data=proj.churn_split_v2;
    tables 이탈여부;
    title "5-1. [새 정의] 이탈여부 분포 - 라벨 윈도우 90일 기준";
run;
title;

proc freq data=proj.churn_split_v2;
    tables 구분 * 이탈여부;
    title "5-2. 학습/검증 분할 확인";
run;
title;


/* -------------------------------------------------------------
   6. GRADBOOST 학습 - 기존(week6a)과 동일 하이퍼파라미터로 비교 목적
   Recency는 이제 cutoff 시점 기준 과거정보라 안전하게 예측변수로 사용 가능
   Cluster_ID는 전체기간 데이터로 만들어져 여전히 제외
------------------------------------------------------------- */
proc gradboost data=mycas.churn_split_v2
                ntrees=100
                seed=2026;
    partition rolevar=구분(TRAIN='TRAIN' VALIDATE='VALID');
    target 이탈여부 / level=nominal;
    input Recency Frequency Monetary AvgOrderValue AvgShipping
          CouponUseRate CouponClickRate 가입기간
          이용카테고리수 주이용카테고리집중도
          재구매간격평균 재구매간격표준편차
          마지막쿠폰_Used CLV / level=interval;
    input 성별 고객지역 / level=nominal;
    output out=mycas.churn_scored_v2 copyvars=(고객ID 이탈여부 구분);
    savestate rstore=mycas.gb_astore_v2;
    ods output VariableImportance=proj.churn_var_importance_v2
               FitStatistics=proj.churn_fit_stats_v2;
run;

proc print data=proj.churn_var_importance_v2;
    title "6-1. [새 모델] 변수 중요도";
run;
title;


/* -------------------------------------------------------------
   7. AUC 확인 - 기존 0.9107(누수 의심)과 비교
------------------------------------------------------------- */
%macro find_prob_var(dsn=, outvar=);
    %global &outvar;
    proc contents data=&dsn out=work._cols_&outvar(keep=name) noprint;
    run;
    proc sql noprint;
        select name into :&outvar trimmed
        from work._cols_&outvar
        where upcase(name) like 'P\_%1' escape '\';
    quit;
    %put NOTE: [find_prob_var] &dsn 에서 찾은 예측확률 컬럼 = %superq(&outvar);
%mend find_prob_var;

%find_prob_var(dsn=mycas.churn_scored_v2, outvar=v2_pvar);

/* 7주차(최종 등급 설계)에서 재사용하기 위해 영구 저장 */
data proj.churn_scored_v2;
    set mycas.churn_scored_v2;
run;


/* [수정] 이전 STAGE 5에서 발견됐던 것과 동일한 데이터 누수 패턴 예방:
   churn_scored_v2에는 이제 구분 컬럼이 있으므로, 반드시 VALID만
   걸러서 PROC ASSESS를 돌림. 참고 비교를 위해 "섞인 채로 계산한
   착시 AUC"도 나란히 보여줌 (0.8901처럼 비현실적으로 높게 나오면
   그게 바로 이 착시임을 눈으로 확인하기 위함) */
proc assess data=mycas.churn_scored_v2;
    target 이탈여부 / event="1" level=nominal;
    input &v2_pvar;
    ods output ROCInfo=proj.churn_roc_v2_mixed;
run;

data mycas.churn_scored_v2_valid;
    set mycas.churn_scored_v2(where=(구분="VALID"));
run;

proc assess data=mycas.churn_scored_v2_valid;
    target 이탈여부 / event="1" level=nominal;
    input &v2_pvar;
    ods output ROCInfo=proj.churn_roc_v2;
run;

proc sql;
    title "7-1a. [주의] TRAIN+VALID 섞어서 계산한 착시 AUC - 실제 성능 아님";
    select max(C) as AUC_섞임_착시 format=6.4
    from proj.churn_roc_v2_mixed;
quit;
title;

proc sql;
    title "7-1b. [진짜] VALID(352명)만 걸러서 계산한 실제 검증 AUC";
    select max(C) as AUC_v2_진짜검증 format=6.4
    from proj.churn_roc_v2;
quit;
title;


/* -------------------------------------------------------------
   7-2. [새 모델] 상위 변수 PDP - Recency가 새로 1위로 올라온 것의
   방향성 확인 목적 (week6b와 동일한 방식, VALID셋 352명 전체 사용)
------------------------------------------------------------- */
data mycas.pdp_base_v2;
    set proj.churn_split_v2(where=(구분="VALID"));
run;

%macro make_pdp_v2(vname=, tag=);

    proc means data=proj.churn_split_v2 noprint;
        var &vname;
        output out=work.pctl_v2_&tag
            p10=g1 p20=g2 p30=g3 p40=g4 p50=g5 p60=g6 p70=g7 p80=g8 p90=g9;
    run;

    data _null_;
        set work.pctl_v2_&tag;
        array g g1-g9;
        do i=1 to 9;
            call symputx(cats('grid_v2_', "&tag", '_', i), g(i));
        end;
    run;

    data mycas.pdp_grid_v2_&tag;
        set mycas.pdp_base_v2;
        %do i=1 %to 9;
            &vname = &&grid_v2_&tag._&i;
            grid_id = &i;
            grid_value = &&grid_v2_&tag._&i;
            output;
        %end;
    run;

    proc astore;
        score data=mycas.pdp_grid_v2_&tag
              out=mycas.pdp_scored_v2_&tag
              rstore=mycas.gb_astore_v2
              copyvars=(grid_id grid_value);
    run;

    %find_prob_var(dsn=mycas.pdp_scored_v2_&tag, outvar=pdp_v2_pvar_&tag);

    proc means data=mycas.pdp_scored_v2_&tag noprint nway;
        class grid_value;
        var &&pdp_v2_pvar_&tag;
        output out=proj.pdp_v2_&tag(drop=_type_ _freq_) mean=평균예측확률;
    run;

    proc sgplot data=proj.pdp_v2_&tag;
        series x=grid_value y=평균예측확률 / markers;
        xaxis label="&vname (P10~P90)";
        yaxis label="평균 예측 이탈확률";
        title "7-2. [새 모델] PDP - &vname 값에 따른 이탈확률 변화";
    run; 
    title;

%mend make_pdp_v2;

%make_pdp_v2(vname=Recency, tag=Recency);
%make_pdp_v2(vname=CouponUseRate, tag=CouponUseRate);
%make_pdp_v2(vname=가입기간, tag=tenure);
%make_pdp_v2(vname=Monetary, tag=Monetary);


/* -------------------------------------------------------------
   8. 마무리
------------------------------------------------------------- */
cas mysession terminate;
