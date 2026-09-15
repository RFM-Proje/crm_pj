/*=============================================================
  STAGE 1. 데이터 준비 (정제 + RFM 파생변수)
  = week1_data_cleaning_merged.sas + week2_rfm_derived_merged.sas
  산출물: proj.sales_clean, proj.sales_with_disc, proj.customer_features
=============================================================*/

/* ============================= PART A. 데이터 정제 ============================= */
/*=============================================================
  WEEK 1 (병합본). 데이터 이해 및 정제
  week1_data_cleaning.sas + week1_data_cleaning_보완.sas 통합
  - 두 파일은 서로 다른 검증 항목을 다뤄 겹치지 않으므로,
    원본 로직 변경 없이 순서대로 이어붙임(정제 로직 자체는
    원본 그대로 유지)

  데이터셋: Kaggle E-commerce 5종 테이블
   - Onlinesales_info : 거래 팩트 테이블 (고객ID, 거래ID, 거래날짜,
                         제품ID, 제품카테고리, 수량, 평균금액, 배송료, 쿠폰상태)
   - Customer_info     : 고객 마스터 (고객ID, 성별, 고객지역, 가입기간)
   - Discount_info     : 월별/카테고리별 쿠폰 (월, 제품카테고리, 쿠폰코드, 할인율)
   - Marketing_info    : 일별 마케팅비 (날짜, 오프라인비용, 온라인비용)
   - Tax_info          : 카테고리별 세율 (제품카테고리, GST)
  ※ 컬럼명이 한글이므로 encoding=utf-8 옵션 필수
=============================================================*/

libname proj "/home/student/open";  /* 본인 작업 경로로 수정 */

/* -------------------------------------------------------------
   0. 원본 데이터 불러오기 (한글 컬럼 - UTF-8 인코딩)
------------------------------------------------------------- */
%macro import_csv(path=, out=);
    proc import datafile="&path."
        out=&out.
        dbms=csv
        replace;
        guessingrows=max;
    run;
%mend;

%import_csv(path=/home/student/open/Onlinesales_info.csv, out=proj.sales_raw);
%import_csv(path=/home/student/open/Customer_info.csv,   out=proj.cust_raw);
%import_csv(path=/home/student/open/Discount_info.csv,   out=proj.disc_raw);
%import_csv(path=/home/student/open/Marketing_info.csv,  out=proj.mkt_raw);
%import_csv(path=/home/student/open/Tax_info.csv,        out=proj.tax_raw);


/* -------------------------------------------------------------
   1. PROC CONTENTS - 5개 테이블 구조 한번에 확인
------------------------------------------------------------- */
%macro check_contents(ds=);
    proc contents data=&ds. varnum;
        title "1. &ds. 구조 확인";
    run;
    title;
%mend;

%check_contents(ds=proj.sales_raw);
%check_contents(ds=proj.cust_raw);
%check_contents(ds=proj.disc_raw);
%check_contents(ds=proj.mkt_raw);
%check_contents(ds=proj.tax_raw);


/* -------------------------------------------------------------
   2. 결측치 · 이상치 탐지 (Onlinesales_info / Customer_info / Marketing_info 일부)
------------------------------------------------------------- */

/* 2-1. Onlinesales_info : 수량/평균금액/배송료 기초통계 (nmiss로 결측 확인) */
proc means data=proj.sales_raw n nmiss min max mean std;
    var 수량 평균금액 배송료;
    title "2-1. 거래 테이블 - 수량/금액/배송료 기초 통계";
run;
title;

/* 2-2. 수량 음수(반품/취소 추정) 비율 확인 */
proc sql;
    select count(*) as 전체건수,
           sum(case when 수량 < 0 then 1 else 0 end) as 음수수량건수,
           calculated 음수수량건수 / calculated 전체건수 * 100 as 음수비율
    from proj.sales_raw;
    title "2-2. 수량 음수(반품 추정) 비율";
quit;
title;

/* 2-3. 평균금액 상위 백분위수 - 이상 고가 거래 탐지 */
proc univariate data=proj.sales_raw noprint;
    var 평균금액;
    output out=proj.price_pctl pctlpts=95 99 99.9 pctlpre=P_;
run;

proc print data=proj.price_pctl;
    title "2-3. 평균금액 상위 백분위수";
run;
title;

/* 2-4. 쿠폰상태 값 분포 확인 (Used/Not Used/Clicked 등 카테고리 파악) */
proc freq data=proj.sales_raw;
    tables 쿠폰상태 / nocum;
    title "2-4. 쿠폰상태 분포";
run;
title;

/* 2-5. 거래 테이블의 고객ID가 Customer_info에 없는 경우(고아 레코드) 확인 */
proc sql;
    select count(distinct a.고객ID) as 매칭안되는_고객수
    from proj.sales_raw as a
    left join proj.cust_raw as b
        on a.고객ID = b.고객ID
    where b.고객ID is missing;
    title "2-5. Customer_info에 없는 거래 고객ID 건수";
quit;
title;

/* 2-6. 거래 테이블의 제품카테고리가 Tax_info에 없는 경우 확인 (세율 조인 시 결측 방지) */
proc sql;
    select distinct a.제품카테고리
    from proj.sales_raw as a
    left join proj.tax_raw as b
        on a.제품카테고리 = b.제품카테고리
    where b.제품카테고리 is missing;
    title "2-6. Tax_info에 세율 없는 제품카테고리";
quit;
title; /*NOTE: No rows were selected.*/

/* 2-7. 가입기간(Customer_info) 이상치 확인 - 음수/비정상 대값 여부 */
proc means data=proj.cust_raw n nmiss min max mean;
    var 가입기간;
    title "2-7. 가입기간 기초 통계";
run;
title;

/* 2-8. Marketing_info 날짜 결측/중복(하루 2건 이상) 확인 */
proc sort data=proj.mkt_raw out=proj.mkt_sorted;
    by 날짜;
run;

proc freq data=proj.mkt_sorted noprint;
    tables 날짜 / out=proj.mkt_date_cnt;
run;

proc sql;
    select count(*) as 중복날짜건수
    from proj.mkt_date_cnt
    where count > 1;
    title "2-8. Marketing_info 날짜 중복 건수";
quit;
title;


/* -------------------------------------------------------------
   2-보완-1. Discount_info : 할인율 결측/이상치
   [존재 이유] 할인율은 disc_raw의 핵심 수치형 변수인데 아직 기초통계를
   낸 적이 없음. 다른 4개 테이블과 동일 수준(음수/100% 초과 여부)으로 확인
------------------------------------------------------------- */
proc means data=proj.disc_raw n nmiss min max mean std;
    var 할인율;
    title "2-보완-1. Discount_info - 할인율 기초 통계 (음수/100% 초과 여부 확인)";
run;
title;

/* disc_raw는 "월+제품카테고리" 단위 유일해야 정상 - 중복 조합 확인 */
proc sql;
    select 월, 제품카테고리, count(*) as 중복건수
    from proj.disc_raw
    group by 월, 제품카테고리
    having count(*) > 1;
    title "2-보완-1-1. Discount_info 월+제품카테고리 중복 조합";
quit;
title;


/* -------------------------------------------------------------
   2-보완-2. Marketing_info : 오프라인/온라인비용 결측/이상치
------------------------------------------------------------- */
proc means data=proj.mkt_raw n nmiss min max mean std;
    var 오프라인비용 온라인비용;
    title "2-보완-2. Marketing_info - 오프라인/온라인비용 기초 통계";
run;
title;

/* 음수는 입력 오류, 0은 "집행 안 한 날"/"결측을 0으로 채운 것"일 수 있어 구분 필요 */
proc sql;
    select
        sum(case when 오프라인비용 < 0 then 1 else 0 end) as 오프라인비용_음수건수,
        sum(case when 온라인비용 < 0 then 1 else 0 end)   as 온라인비용_음수건수,
        sum(case when 오프라인비용 = 0 and 온라인비용 = 0 then 1 else 0 end) as 마케팅비용_0인날
    from proj.mkt_raw;
    title "2-보완-2-1. Marketing_info 비용 음수/0 건수";
quit;
title;


/* -------------------------------------------------------------
   2-보완-3. Tax_info : GST 결측/이상치
------------------------------------------------------------- */
proc means data=proj.tax_raw n nmiss min max mean std;
    var GST;
    title "2-보완-3. Tax_info - GST 기초 통계 (0~1 또는 0~100 범위 벗어나는지 확인)";
run;
title;

/* 제품카테고리당 세율은 1개여야 정상 - 중복 여부 */
proc freq data=proj.tax_raw;
    tables 제품카테고리 / nocum;
    title "2-보완-3-1. Tax_info 제품카테고리 중복 여부 (카테고리당 세율 1개여야 정상)";
run;
title;


/* -------------------------------------------------------------
   2-보완-4. Customer_info : 범주형 변수 결측 (성별, 고객지역)
   ※ 가입기간(수치형)은 위 2-7에서 이미 확인함
------------------------------------------------------------- */
proc freq data=proj.cust_raw;
    tables 성별 고객지역 / missing nocum;
    title "2-보완-4. Customer_info - 성별/고객지역 분포 및 결측(.) 확인";
run;
title;


/* -------------------------------------------------------------
   2-보완-5. 5개 테이블 전체 - 중복행(완전 동일 row) 체크
   [존재 이유] 아래 3번 DATA STEP 정제 로직은 "행 내용이 이상한 경우"만
   걸러내고 "완전히 똑같은 행이 2번 들어간 경우"는 걸러내지 않음.
   count(*) vs count(distinct *) 비교로만 드러나는 이상치 유형이므로 확인
------------------------------------------------------------- */
%macro check_dup(ds=, label=);
    proc sql;
        select count(*) as 전체행수,
               count(*) - (select count(*) from (select distinct * from &ds.)) as 중복행수
        from &ds.;
        title "2-보완-5. &label. 완전 중복행 개수";
    quit;
    title;
%mend;

%check_dup(ds=proj.sales_raw, label=Onlinesales_info);
%check_dup(ds=proj.cust_raw,  label=Customer_info);
%check_dup(ds=proj.disc_raw,  label=Discount_info);
%check_dup(ds=proj.mkt_raw,   label=Marketing_info);
%check_dup(ds=proj.tax_raw,   label=Tax_info);

/* -------------------------------------------------------------
   2-보완-6. Onlinesales_info : 배송료 상위 백분위수 및 이상치 후보
   [존재 이유] 위 2-1은 배송료의 평균/표준편차만 확인함. 2-3(평균금액)과
   동일 수준으로 상위 백분위수까지 봐야 극단적으로 튀는 배송료 거래를
   놓치지 않고 파악할 수 있음
------------------------------------------------------------- */
proc univariate data=proj.sales_raw noprint;
    var 배송료;
    output out=proj.shipping_pctl pctlpts=95 99 99.9 pctlpre=P_;
run;

proc print data=proj.shipping_pctl;
    title "2-보완-6. 배송료 상위 백분위수";
run;
title;

/* 상위 0.1% 초과 거래 - 실제 이상치 후보 목록 확인 */
proc sql;
    create table proj.shipping_outlier_candidates as
    select 거래ID, 고객ID, 거래날짜, 제품카테고리, 배송료
    from proj.sales_raw
    having 배송료 > (select P_99_9 from proj.shipping_pctl);
quit;

proc print data=proj.shipping_outlier_candidates;
    title "2-보완-6-1. 배송료 상위 0.1% 초과 거래 (이상치 후보)";
run;
title;

/* 거래ID 내에서 배송료가 정말 항상 동일한지 전체 검증 (0건이어야 가설 확정) */
proc sql;
    select 거래ID, count(distinct 배송료) as 배송료_종류수
    from proj.sales_raw
    group by 거래ID
    having calculated 배송료_종류수 > 1;
    title "2-보완-6-2. 거래ID 내 배송료가 여러 값인 경우 (0건이어야 가설 확정)";
quit;
title;


/* -------------------------------------------------------------
   3. DATA STEP - 정제
   정제 기준(가설 - 팀 논의 후 확정):
   a) 수량 <= 0 인 거래 → 반품/취소로 별도 플래그 (제외 대신 분리, 이탈 신호로 활용 가능)
   b) 평균금액 <= 0 인 비정상 거래 제외
   c) Customer_info에 매칭 안 되는 고객ID → 제외 (고객 단위 분석 필수 요건)
   d) 거래날짜 → SAS date로 변환 (문자로 들어왔을 경우 대비)
------------------------------------------------------------- */
data proj.sales_clean
     proj.sales_excluded(keep=거래ID 고객ID reason);

    length reason $50;

    /* Customer_info에 존재하는 고객만 남기기 위한 해시 매칭 */
    if _n_ = 1 then do;
        declare hash h(dataset:"proj.cust_raw");
        h.definekey("고객ID");
        h.definedone();
    end;

    set proj.sales_raw;

    /* 거래날짜 문자형이면 SAS date로 변환 (이미 date형이면 이 블록 생략) */
    if vtype(거래날짜) = "C" then
        거래날짜_num = input(거래날짜, yymmdd10.);
    else
        거래날짜_num = 거래날짜;
    format 거래날짜_num yymmdd10.;

    if h.check() ne 0 then do;   /* Customer_info에 없는 고객 */
        reason = "고객ID 매칭 불가";
        output proj.sales_excluded;
    end;
    else if 평균금액 <= 0 then do;
        reason = "평균금액 0 이하 비정상";
        output proj.sales_excluded;
    end;
    else do;
        is_return = (수량 <= 0);   /* 반품/취소 플래그 - 제외하지 않고 변수로 보존 */
        output proj.sales_clean;
    end;
run;

/* 정제 결과 요약 */
proc sql;
    select count(*) as raw_건수 from proj.sales_raw;
    select count(*) as clean_건수 from proj.sales_clean;
    select count(*) as excluded_건수 from proj.sales_excluded;
quit;

proc freq data=proj.sales_excluded;
    tables reason;
    title "3. 정제 단계 제외 건 - 사유별 집계";
run;
title;

/* 반품 비율 최종 확인 */
proc freq data=proj.sales_clean;
    tables is_return;
    title "3-1. 정제 후 반품(수량<=0) 비율";
run;
title;

/* ============================= PART B. RFM 파생변수 설계 ============================= */
/*=============================================================
  WEEK 2 (병합본). 파생변수 및 RFM 설계
  week2_rfm_derived.sas + week2_rfm_derived_보완.sas 통합
  - 두 파일은 서로 다른 검증 항목을 다뤄 겹치지 않으므로,
    원본 로직 변경 없이 순서대로 이어붙임

  입력: proj.sales_clean (1주차 정제 결과)
        proj.cust_raw, proj.disc_raw
  원칙: RFM은 별도 등급표가 아니라 3주차 군집분석(K-Means)의
        입력 변수로만 사용한다 (중복 세분화 방지)
  1주차 확인 결과 반영:
   - 반품/취소(수량 음수) 없음 → Frequency는 단순 거래건수로 계산
   - 쿠폰상태 = Clicked(50.9%) / Not Used(15.3%) / Used(33.8%) 3단계

  [수정 사항 1 - AvgShipping 계산 방식]
  배송료는 거래ID(주문) 단위 고정값 → line-item 단위에서 바로
  평균내면 다품목 주문에서 중복 반영되어 왜곡됨. 거래ID 단위로
  먼저 1행으로 압축한 뒤 고객 단위로 평균

  [수정 사항 2 - AvgOrderValue 계산 방식]
  거래금액(=평균금액*수량)은 line-item 단위 → 거래ID(주문)
  단위로 먼저 총액을 합산한 order_total을 만든 뒤, 그 주문단위
  총액을 고객 단위로 평균 (AvgShipping과 동일 패턴)
=============================================================*/

libname proj "/home/student/open";

/* -------------------------------------------------------------
   1. 거래 테이블에 월(月) 파생 + Discount_info 조인
   - Discount_info가 "월+제품카테고리" 단위 할인율이므로,
     거래날짜에서 월(Jan/Feb..) 추출 후 매칭
------------------------------------------------------------- */
data proj.sales_month;
    set proj.sales_clean;
    length 월 $3;
    월 = put(거래날짜_num, monname3.);   /* Jan, Feb ... 형태로 변환 */
    거래금액 = 평균금액 * 수량;          /* 실제 매출액 = 단가 * 수량 */
run;

proc sql;
    create table proj.sales_with_disc as
    select a.*,
           b.할인율
    from proj.sales_month as a
    left join proj.disc_raw as b
        on a.월 = b.월 and a.제품카테고리 = b.제품카테고리;
quit;

/* 할인율 매칭 안 된 경우(해당 월/카테고리 프로모션 없음) → 0으로 대체 */
data proj.sales_with_disc;
    set proj.sales_with_disc;
    if missing(할인율) then 할인율 = 0;
run;

/* 매칭 확인 */
proc means data=proj.sales_with_disc n nmiss;
    var 할인율;
    title "1-1. 할인율 조인 후 결측 확인 (0건이어야 정상)";
run;
title;


/* -------------------------------------------------------------
   1-2. 배송료 - 거래ID(주문) 단위 압축
   [존재 이유] sales_with_disc는 제품카테고리별 line-item 단위라서
   배송료가 거래ID당 여러 번 반복됨. 검증 결과 거래ID 내 배송료는
   항상 동일한 값이므로(주문 단위 고정값), distinct로 한 번만
   남겨야 고객 단위 평균 계산 시 중복 반영되지 않음
------------------------------------------------------------- */
proc sql;
    create table proj.shipping_per_order as
    select distinct 고객ID, 거래ID, 배송료
    from proj.sales_with_disc;
quit;

/* 압축 검증 - 거래ID당 정확히 1행이어야 정상 */
proc sql;
    select count(*) as 압축후_행수,
           count(distinct 거래ID) as 고유_거래ID수
    from proj.shipping_per_order;
    title "1-2. 배송료 주문단위 압축 검증 (두 값이 같아야 정상)";
quit;
title;


/* -------------------------------------------------------------
   1-3. 주문(거래ID) 단위 총 결제금액 집계
   [존재 이유] AvgOrderValue("평균 객단가")를 구하려면 먼저 거래ID
   단위로 합산해서 "그 주문에서 실제로 얼마를 결제했는가"부터
   만들어야 함. 배송료와 달리 거래금액은 품목마다 다르므로
   sum으로 합산 (distinct 아님)
------------------------------------------------------------- */
proc sql;
    create table proj.order_total as
    select 고객ID, 거래ID,
           sum(거래금액) as 주문총액
    from proj.sales_with_disc
    group by 고객ID, 거래ID;
quit;

/* 검증 - 주문총액 합계가 전체 매출액 합계와 같아야 정상 */
proc sql;
    select sum(주문총액) as 주문단위_총매출
    from proj.order_total;
quit;
proc sql;
    select sum(거래금액) as 라인아이템단위_총매출
    from proj.sales_with_disc;
    title "1-3. 주문단위 집계 검증 (위 두 값이 같아야 정상)";
quit;
title;


/* -------------------------------------------------------------
   2. 고객 단위 RFM 지표 산출
   - 기준일(Reference Date) = 데이터 내 최종 거래일 + 1일
   - AvgShipping은 1-2의 shipping_per_order,
     AvgOrderValue는 1-3의 order_total 기준으로
     각각 별도 계산 후 병합
------------------------------------------------------------- */
proc sql noprint;
    select max(거래날짜_num) + 1 into :ref_date
    from proj.sales_with_disc;
quit;

%put 기준일 = &ref_date;
%put 기준일(날짜형식) = %sysfunc(putn(&ref_date, yymmdd10.));

proc sql;
    create table proj.rfm_core as
    select
        고객ID,
        &ref_date - max(거래날짜_num)              as Recency label="최근성(일)",
        count(distinct 거래ID)                      as Frequency label="구매빈도(건)",
        sum(거래금액)                                as Monetary label="총구매금액",
        mean(case when 쿠폰상태="Used" then 1 else 0 end)    as CouponUseRate label="쿠폰실사용률",
        mean(case when 쿠폰상태="Clicked" then 1 else 0 end) as CouponClickRate label="쿠폰클릭만비율",
        mean(할인율)                                 as AvgDiscountRate label="평균할인율"
    from proj.sales_with_disc
    group by 고객ID;
quit;

/* 고객 단위 평균배송료 - 주문단위로 압축된 테이블 기준 */
proc sql;
    create table proj.avg_shipping as
    select 고객ID,
           mean(배송료) as AvgShipping label="평균배송료"
    from proj.shipping_per_order
    group by 고객ID;
quit;

/* 고객 단위 평균객단가 - 주문단위로 합산된 테이블 기준 */
proc sql;
    create table proj.avg_order_value as
    select 고객ID,
           mean(주문총액) as AvgOrderValue label="평균객단가(주문단위)"
    from proj.order_total
    group by 고객ID;
quit;

/* RFM 핵심 지표 + 평균배송료 + 평균객단가 병합 */
proc sql;
    create table proj.rfm_base as
    select a.*,
           b.AvgShipping,
           c.AvgOrderValue
    from proj.rfm_core as a
    left join proj.avg_shipping as b
        on a.고객ID = b.고객ID
    left join proj.avg_order_value as c
        on a.고객ID = c.고객ID;
quit;

/* RFM 분포 확인 (이상치 유무, 3주차 표준화 전 스케일 파악용) */
proc means data=proj.rfm_base n nmiss min max mean std;
    var Recency Frequency Monetary AvgOrderValue CouponUseRate CouponClickRate AvgDiscountRate AvgShipping;
    title "2-1. 고객 단위 RFM 및 파생변수 기초 통계";
run;
title;


/* -------------------------------------------------------------
   3. Customer_info(인구통계) 조인 - 파생변수 명세서 완성
------------------------------------------------------------- */
proc sql;
    create table proj.customer_features as
    select
        a.고객ID,
        a.Recency,
        a.Frequency,
        a.Monetary,
        a.AvgOrderValue,
        a.CouponUseRate,
        a.CouponClickRate,
        a.AvgDiscountRate,
        a.AvgShipping,
        b.성별,
        b.고객지역,
        b.가입기간
    from proj.rfm_base as a
    left join proj.cust_raw as b
        on a.고객ID = b.고객ID;
quit;

/* 최종 파생변수 테이블 검증 */
proc contents data=proj.customer_features varnum;
    title "3-1. 최종 고객 특성 테이블(customer_features) 구조";
run;
title;

proc sql;
    select count(*) as 고객수,
           sum(case when 성별 is missing then 1 else 0 end) as 성별결측,
           sum(case when 고객지역 is missing then 1 else 0 end) as 지역결측
    from proj.customer_features;
    title "3-2. Customer_info 조인 후 결측 확인";
quit;
title;

/* 지역/성별 분포 - 3주차 군집 프로파일링 시 참고용 */
proc freq data=proj.customer_features;
    tables 성별 고객지역 / nocum;
    title "3-3. 성별/지역 분포";
run;
title;

/* -------------------------------------------------------------
   4. RFM 상관관계 확인 (군집 변수 선정 참고용)
   - 지나치게 상관 높은 변수는 3주차 표준화 시 가중치 왜곡 유발 가능
------------------------------------------------------------- */
proc corr data=proj.customer_features;
    var Recency Frequency Monetary AvgOrderValue CouponUseRate AvgDiscountRate AvgShipping;
    title "4-1. RFM/파생변수 간 상관관계";
run;
title;


/* -------------------------------------------------------------
   [보완] 1. 미구매 고객(거래 이력 없는 고객) 규모 파악
   [존재 이유] rfm_base는 sales_with_disc(거래 테이블)를
   group by 고객ID로 만들었기 때문에, 실제로는 "거래가 있는
   고객"만의 지표임. 모집단이 Customer_info 전체 고객인지,
   거래 이력 있는 고객만인지 명확히 확인
------------------------------------------------------------- */
proc sql;
    select
        (select count(distinct 고객ID) from proj.cust_raw)   as Customer_info_전체고객수,
        (select count(distinct 고객ID) from proj.rfm_base)   as RFM_포함고객수,
        calculated Customer_info_전체고객수 - calculated RFM_포함고객수 as 미구매_고객수
    from sashelp.class(obs=1);
    title "보완-1. Customer_info 대비 RFM 미포함(미구매) 고객수";
quit;
title;

/* 미구매 고객 목록을 별도 테이블로 남겨, rfm_base가 다루는
   범위와 다루지 않는 범위를 명시적으로 구분해 둠 */
proc sql;
    create table proj.customer_no_purchase as
    select b.고객ID, b.성별, b.고객지역, b.가입기간
    from proj.cust_raw as b
    left join proj.rfm_base as a
        on b.고객ID = a.고객ID
    where a.고객ID is missing;
quit;

proc print data=proj.customer_no_purchase(obs=10);
    title "보완-1-1. 미구매 고객 샘플 (상위 10건)";
run;
title;


/* -------------------------------------------------------------
   [보완] 2. RFM 왜도(Skewness)/첨도(Kurtosis) 확인
   [존재 이유] 위 2-1은 min/max/mean/std만 확인함. 값이 크게
   치우친 분포라면 평균·표준편차만으로는 지표 특성을 제대로
   설명하지 못하므로, 분포 형태(치우침 정도)까지 기록
------------------------------------------------------------- */
proc means data=proj.rfm_base skewness kurtosis;
    var Recency Frequency Monetary AvgOrderValue;
    title "보완-2. RFM 변수 왜도/첨도 (절대값 1 이상이면 치우친 분포)";
run;
title;


/* -------------------------------------------------------------
   [보완] 3. 쿠폰상태 비율 합계 검증 (Used + Clicked + NotUsed = 1)
   [존재 이유] CASE WHEN 로직으로 각각 따로 계산했기 때문에,
   쿠폰상태 값에 오타나 예상 못한 카테고리가 섞여 있으면 두
   비율의 합이 1보다 작아지는 오류가 생길 수 있음
------------------------------------------------------------- */
proc sql;
    create table proj.coupon_rate_check as
    select
        고객ID,
        CouponUseRate,
        CouponClickRate,
        1 - CouponUseRate - CouponClickRate as CouponNotUsedRate_역산
    from proj.rfm_base;
quit;

proc means data=proj.coupon_rate_check min max;
    var CouponNotUsedRate_역산;
    title "보완-3. 쿠폰 미사용률(역산) 범위 확인 (0~1 벗어나면 쿠폰상태에 예상 못한 값 존재)";
run;
title;


/* -------------------------------------------------------------
   [보완] 4. customer_features - 가입기간 결측 확인
   [존재 이유] 위 3-2는 성별·고객지역 결측만 확인하고 가입기간은
   빠져 있음. 같은 산출물 안에서 조인한 변수라면 전부 같은
   수준으로 검증해야 파생변수 명세서가 완결됨
------------------------------------------------------------- */
proc sql;
    select
        count(*) as 고객수,
        sum(case when 가입기간 is missing then 1 else 0 end) as 가입기간_결측건수
    from proj.customer_features;
    title "보완-4. customer_features 가입기간 결측 확인";
quit;
title;


/* -------------------------------------------------------------
   [보완] 5. Monetary(총구매금액) 음수/0 여부 확인
   [존재 이유] 거래금액(=평균금액*수량)은 1단계에서 새로 만든
   파생변수이고, Monetary는 이를 고객 단위로 합산한 것임.
   계산이 의도대로 나왔는지(음수/0 없음) 만든 직후 검증
------------------------------------------------------------- */
proc sql;
    select
        sum(case when Monetary < 0 then 1 else 0 end) as Monetary_음수_고객수,
        sum(case when Monetary = 0 then 1 else 0 end) as Monetary_0_고객수
    from proj.rfm_base;
    title "보완-5. Monetary 음수/0 고객수 (0건이어야 정상)";
quit;
title;
