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
    if 거래날짜 <= &cutoff_date then output work.trans_feature;
    else if &cutoff_date < 거래날짜 <= &label_end then output work.trans_label;
run;


/* -------------------------------------------------------------
   2. 거래(주문) 단위 중복 압축 - 배송료/평균금액은 거래ID당 1개값이므로
   line-item 단위로 바로 평균내면 다품목 주문이 중복 반영됨 (기존 프로젝트에서
   확인된 버그 패턴과 동일한 원리로 방지)
------------------------------------------------------------- */
proc sql;
    create table work.trans_dedup as
    select 고객ID, 거래ID, 거래날짜,
           sum(평균금액 * 수량) as order_total,
           mean(배송료) as order_shipping
    from work.trans_feature
    group by 고객ID, 거래ID, 거래날짜;
quit;


/* -------------------------------------------------------------
   3. 고객단위 RFM류 피처 생성 (전부 cutoff 이전 데이터만 사용)
------------------------------------------------------------- */
proc sql;
    create table work.customer_rfm as
    select 고객ID,
           &cutoff_date - max(거래날짜) as Recency,
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
           e.가입기간, e.성별, e.고객지역
    from work.customer_churn as a
    inner join work.customer_rfm as b on a.고객ID = b.고객ID
    left join work.customer_coupon as c on a.고객ID = c.고객ID
    inner join (select distinct 고객ID, 가입기간, 성별, 고객지역 from proj.customer_segments) as e
      on a.고객ID = e.고객ID;
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
          CouponUseRate CouponClickRate 가입기간 / level=interval;
    input 성별 고객지역 / level=nominal;
    output out=mycas.churn_scored_v2 copyvars=(고객ID 이탈여부);
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

proc assess data=mycas.churn_scored_v2;
    target 이탈여부 / event="1" level=nominal;
    input &v2_pvar;
    ods output ROCInfo=proj.churn_roc_v2;
run;

proc sql;
    title "7-1. 시점분리 재구성 후 AUC - 기존 0.9107과 비교";
    select max(C) as AUC_v2 format=6.4
    from proj.churn_roc_v2;
quit;
title;


/* -------------------------------------------------------------
   8. 마무리
------------------------------------------------------------- */
cas mysession terminate;
