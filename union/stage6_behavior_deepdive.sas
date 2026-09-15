/*=============================================================
  STAGE 6. 행동 심층분석
  = DACON 코드공유(고객세분화 대회) 벤치마킹 - STAGE 1~5 파이프라인에서
    다루지 않았던 5가지를 순서대로 채움:
    B) ARPPU (카테고리별/세그먼트별)
    C) 마케팅비용 - ARPPU 상관관계 (+ 온/오프라인 효과 비교)
    D) 성별 구매패턴
    E) 요일별 구매패턴
    F) 세그먼트별 쿠폰 재사용 전이패턴

  세그먼트 기준: DACON은 자체 RFM-P로 VIP~Bronze 6등급을 새로 만들었지만,
  본 프로젝트는 이미 stage2 K-means 군집(6개) + stage5 이탈위험등급으로
  만든 proj.customer_final_tier.군집라벨(배송이슈/이탈위험군/저관여/
  쿠폰의존/핵심고객/일반고객)이 있으므로 그걸 그대로 세그먼트 단위로 재사용함
  (새로 만들지 않음 - 이미 있는 세분화 결과와 이번 분석을 연결하는 것이 목적).

  전제조건: STAGE 1~5 실행 완료
  (proj.sales_with_disc, proj.customer_segments, proj.customer_final_tier,
   proj.mkt_raw 존재해야 함)

  [주의] mkt_raw의 날짜 컬럼명은 확인된 적이 없어서 "날짜"로 가정함.
  아래 A0 진단 결과 다르면 이후 코드의 "날짜" 부분을 실제 컬럼명으로 수정할 것.

  산출물: proj.arppu_by_category, proj.arppu_by_segment,
          proj.marketing_arppu_corr, proj.gender_purchase_pattern,
          proj.gender_category_arppu, proj.weekday_pattern,
          proj.coupon_transition_summary
=============================================================*/

libname proj "/home/student/open";

/* ============================= PART A. 원천 테이블 구조 확인 ============================= */

proc contents data=proj.mkt_raw varnum;
    title "A0-1. [확인용] mkt_raw 컬럼 구조 - 날짜/오프라인비용/온라인비용 컬럼명·타입 확인";
run;
title;

proc contents data=proj.customer_final_tier varnum;
    title "A0-2. [확인용] customer_final_tier 컬럼 구조 - 군집라벨 있는지 확인";
run;
title;

proc contents data=proj.sales_with_disc varnum;
    title "A0-3. [확인용] sales_with_disc 컬럼 구조 - 거래금액/제품카테고리/쿠폰상태 있는지 확인";
run;
title;


/* ============================= PART B. ARPPU (카테고리별 / 세그먼트별) ============================= */
/*=============================================================
  ARPPU = 특정 기간·집단 내 총매출 / 순고객수
  DACON은 월별/주별로 나눴지만, 여기서는 전체 관측기간(1년) 기준
  카테고리별·세그먼트별 ARPPU로 단순화함 (필요시 월별로 확장 가능)
=============================================================*/

proc sql;
    create table proj.arppu_by_category as
    select 제품카테고리,
           sum(거래금액) as 총매출,
           count(distinct 고객ID) as 순고객수,
           calculated 총매출 / calculated 순고객수 as ARPPU format=10.2
    from proj.sales_with_disc
    group by 제품카테고리
    order by calculated ARPPU desc;
quit;

proc print data=proj.arppu_by_category noobs;
    title "B-1. 카테고리별 ARPPU";
run;
title;

proc sgplot data=proj.arppu_by_category;
    hbar 제품카테고리 / response=ARPPU categoryorder=respdesc;
    xaxis label="ARPPU";
    title "B-2. 카테고리별 ARPPU 순위";
run;
title;

/* 세그먼트(군집라벨)별 ARPPU - 거래 데이터에 세그먼트 붙여서 계산 */
proc sql;
    create table work.sales_with_segment as
    select a.*, b.군집라벨, b.최종등급, b.이탈위험등급
    from proj.sales_with_disc as a
    inner join proj.customer_final_tier as b
      on a.고객ID = b.고객ID;
quit;

proc sql;
    create table proj.arppu_by_segment as
    select 군집라벨,
           sum(거래금액) as 총매출,
           count(distinct 고객ID) as 순고객수,
           calculated 총매출 / calculated 순고객수 as ARPPU format=10.2
    from work.sales_with_segment
    group by 군집라벨
    order by calculated ARPPU desc;
quit;

proc print data=proj.arppu_by_segment noobs;
    title "B-3. 세그먼트(군집라벨)별 ARPPU";
run;
title;


/* ============================= PART C. 마케팅비용 - ARPPU 상관관계 ============================= */
/*=============================================================
  [단순화] DACON은 광고일로부터 2주 윈도우로 매출을 귀속시켰지만,
  여기서는 일자 단위 동시성(같은 날 매출 vs 같은 날 마케팅비용)
  상관관계로 단순화함. 2주 윈도우 버전이 필요하면 이 구조를 그대로
  두고 날짜 조인 조건만 between으로 바꾸면 됨.
=============================================================*/

proc sql;
    create table work.daily_sales as
    select 거래날짜_num as 날짜,
           sum(거래금액) as 매출합,
           count(distinct 고객ID) as 고객수,
           calculated 매출합 / calculated 고객수 as ARPPU format=10.2
    from proj.sales_with_disc
    group by 거래날짜_num;
quit;

/* [주의] 날짜 컬럼명이 mkt_raw에서 다르게 나오면 아래 on절의 "날짜"를 수정 */
proc sql;
    create table proj.marketing_arppu_corr as
    select a.날짜, a.매출합, a.고객수, a.ARPPU,
           b.오프라인비용, b.온라인비용,
           b.오프라인비용 + b.온라인비용 as 총마케팅비용
    from work.daily_sales as a
    left join proj.mkt_raw as b
      on a.날짜 = b.날짜;
quit;

proc corr data=proj.marketing_arppu_corr;
    var ARPPU;
    with 총마케팅비용 오프라인비용 온라인비용;
    title "C-1. ARPPU와 마케팅비용(총/온라인/오프라인)의 피어슨 상관계수";
run;
title;

proc sgplot data=proj.marketing_arppu_corr;
    scatter x=총마케팅비용 y=ARPPU;
    reg x=총마케팅비용 y=ARPPU;
    title "C-2. 총마케팅비용 vs ARPPU (회귀선 포함)";
run;
title;

proc sgplot data=proj.marketing_arppu_corr;
    scatter x=오프라인비용 y=ARPPU / legendlabel="오프라인";
    reg x=오프라인비용 y=ARPPU / legendlabel="오프라인 회귀선";
    scatter x=온라인비용 y=ARPPU / legendlabel="온라인";
    reg x=온라인비용 y=ARPPU / legendlabel="온라인 회귀선";
    title "C-3. 온라인 vs 오프라인 마케팅비용 - 기울기 비교 (어느 쪽이 ARPPU를 더 올리나)";
run;
title;

/* 세그먼트별 평균 마케팅비용 노출 정도 - DACON 4-5-1과 동일한 취지 */
proc sql;
    create table work.sales_segment_daily as
    select 군집라벨, 거래날짜_num as 날짜
    from work.sales_with_segment;
quit;

proc sql;
    create table proj.segment_marketing_exposure as
    select a.군집라벨, mean(b.오프라인비용 + b.온라인비용) as 평균노출_마케팅비용 format=10.2
    from work.sales_segment_daily as a
    left join proj.mkt_raw as b on a.날짜 = b.날짜
    group by a.군집라벨
    order by calculated 평균노출_마케팅비용 desc;
quit;

proc print data=proj.segment_marketing_exposure noobs;
    title "C-4. 세그먼트별 평균 마케팅비용 노출 (구매가 마케팅 고비용일에 몰린 세그먼트 확인)";
run;
title;


/* ============================= PART D. 성별 구매패턴 ============================= */

proc sql;
    create table work.sales_gender as
    select a.*, b.성별
    from proj.sales_with_disc as a
    left join (select distinct 고객ID, 성별 from proj.customer_segments) as b
      on a.고객ID = b.고객ID;
quit;

proc sql;
    create table proj.gender_purchase_pattern as
    select 성별,
           count(distinct 거래ID) as 구매건수,
           sum(거래금액) as 총매출,
           mean(거래금액) as 평균거래금액 format=10.2,
           count(distinct 고객ID) as 순고객수,
           calculated 총매출 / calculated 순고객수 as 성별ARPPU format=10.2
    from work.sales_gender
    group by 성별;
quit;

proc print data=proj.gender_purchase_pattern noobs;
    title "D-1. 성별 구매패턴 요약 (구매건수/총매출/평균거래금액/ARPPU)";
run;
title;

/* 카테고리 x 성별 ARPPU - 어떤 카테고리를 어느 성별이 더 미는지 */
proc sql;
    create table proj.gender_category_arppu as
    select 제품카테고리, 성별,
           sum(거래금액) as 총매출,
           count(distinct 고객ID) as 순고객수,
           calculated 총매출 / calculated 순고객수 as ARPPU format=10.2
    from work.sales_gender
    group by 제품카테고리, 성별;
quit;

proc sgplot data=proj.gender_category_arppu;
    vbar 제품카테고리 / response=ARPPU group=성별 groupdisplay=cluster;
    xaxis fitpolicy=rotate;
    title "D-2. 카테고리별 성별 ARPPU 비교";
run;
title;


/* ============================= PART E. 요일별 구매패턴 ============================= */

proc format;
    value wkdayf 1='Sun' 2='Mon' 3='Tue' 4='Wed' 5='Thu' 6='Fri' 7='Sat';
quit;

data work.sales_weekday;
    set proj.sales_with_disc;
    요일번호 = weekday(거래날짜_num);
    format 요일번호 wkdayf.;
run;

proc sql;
    create table proj.weekday_pattern as
    select 요일번호,
           count(distinct 거래ID) as 구매건수,
           mean(거래금액) as 평균거래금액 format=10.2,
           sum(거래금액) as 총매출
    from work.sales_weekday
    group by 요일번호;
quit;

proc sgplot data=proj.weekday_pattern;
    vbar 요일번호 / response=총매출 datalabel;
    title "E-1. 요일별 총매출";
run;
title;

proc sgplot data=proj.weekday_pattern;
    vbar 요일번호 / response=평균거래금액 datalabel;
    title "E-2. 요일별 평균 거래금액";
run;
title;

/* 세그먼트 x 요일 - 어느 세그먼트가 어느 요일에 주로 오는지 (마케팅 타이밍용) */
proc sql;
    create table proj.segment_weekday_pattern as
    select b.군집라벨, weekday(a.거래날짜_num) as 요일번호 format=wkdayf.,
           count(distinct a.거래ID) as 구매건수
    from proj.sales_with_disc as a
    inner join proj.customer_final_tier as b on a.고객ID = b.고객ID
    group by b.군집라벨, calculated 요일번호;
quit;

proc sgplot data=proj.segment_weekday_pattern;
    vbar 요일번호 / response=구매건수 group=군집라벨 groupdisplay=cluster;
    title "E-3. 세그먼트별 요일 구매 패턴 (마케팅 발송 요일 결정용)";
run;
title;


/* ============================= PART F. 세그먼트별 쿠폰 재사용 전이패턴 ============================= */
/*=============================================================
  DACON은 파이썬 반복문으로 고객별 직전->현재 쿠폰상태 전이를 셌지만,
  SAS에서는 stage4의 재구매간격 계산과 동일한 retain/first. 패턴으로
  더 간단하게 구현함.
  [단순화] 한 거래(거래ID)에 여러 line-item이 있을 수 있어 거래 단위로
  먼저 압축(각 거래의 첫 쿠폰상태 사용)한 뒤 고객별 시간순 전이를 계산함
=============================================================*/

proc sql;
    create table work.txn_coupon_raw as
    select 고객ID, 거래ID, 거래날짜_num, 쿠폰상태
    from proj.sales_with_disc;
quit;

proc sort data=work.txn_coupon_raw out=work.txn_coupon_sorted nodupkey;
    by 고객ID 거래ID 거래날짜_num;
run;

proc sort data=work.txn_coupon_sorted;
    by 고객ID 거래날짜_num;
run;

data work.coupon_transition;
    set work.txn_coupon_sorted;
    by 고객ID;
    retain 이전쿠폰상태;
    length 전이유형 $20;
    if first.고객ID then do;
        이전쿠폰상태 = 쿠폰상태;
    end;
    else do;
        전이유형 = catx("->", 이전쿠폰상태, 쿠폰상태);
        output;
        이전쿠폰상태 = 쿠폰상태;
    end;
    keep 고객ID 전이유형;
run;

proc sql;
    create table work.coupon_transition_seg as
    select a.고객ID, a.전이유형, b.군집라벨
    from work.coupon_transition as a
    inner join proj.customer_final_tier as b on a.고객ID = b.고객ID;
quit;

proc freq data=work.coupon_transition_seg noprint;
    tables 군집라벨 * 전이유형 / out=work.transition_counts(drop=percent);
run;

proc sql;
    create table proj.coupon_transition_summary as
    select a.군집라벨, a.전이유형, a.count as 건수,
           a.count / b.세그먼트합계 * 100 as 비율_pct format=6.2
    from work.transition_counts as a
    inner join (select 군집라벨, sum(count) as 세그먼트합계
                from work.transition_counts group by 군집라벨) as b
      on a.군집라벨 = b.군집라벨
    order by a.군집라벨, calculated 비율_pct desc;
quit;

proc print data=proj.coupon_transition_summary noobs;
    title "F-1. 세그먼트별 쿠폰상태 전이패턴 (직전거래->현재거래 쿠폰사용 여부)";
    where 전이유형 is not missing;
run;
title;

/* 세그먼트별로 가장 두드러지는(다른 세그먼트 대비 비율이 가장 높은) 전이유형 확인 */
proc sql;
    create table proj.coupon_transition_pivot as
    select 전이유형,
           max(case when 군집라벨="핵심고객" then 비율_pct end) as 핵심고객,
           max(case when 군집라벨="이탈위험군" then 비율_pct end) as 이탈위험군,
           max(case when 군집라벨="쿠폰의존" then 비율_pct end) as 쿠폰의존,
           max(case when 군집라벨="배송이슈" then 비율_pct end) as 배송이슈,
           max(case when 군집라벨="저관여" then 비율_pct end) as 저관여,
           max(case when 군집라벨="일반고객" then 비율_pct end) as 일반고객
    from proj.coupon_transition_summary
    where 전이유형 is not missing
    group by 전이유형;
quit;

proc print data=proj.coupon_transition_pivot noobs;
    title "F-2. 전이유형 x 세그먼트 피벗 - 어느 세그먼트가 어떤 쿠폰행동에서 두드러지는지 한눈에 비교";
run;
title;
