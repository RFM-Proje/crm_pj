/*=============================================================
  WEEK 1. 데이터 이해 및 정제
  데이터셋: Kaggle E-commerce 5종 테이블
   - Onlinesales_info : 거래 팩트 테이블 (고객ID, 거래ID, 거래날짜,
                         제품ID, 제품카테고리, 수량, 평균금액, 배송료, 쿠폰상태)
   - Customer_info     : 고객 마스터 (고객ID, 성별, 고객지역, 가입기간)
   - Discount_info     : 월별/카테고리별 쿠폰 (월, 제품카테고리, 쿠폰코드, 할인율)
   - Marketing_info    : 일별 마케팅비 (날짜, 오프라인비용, 온라인비용)
   - Tax_info          : 카테고리별 세율 (제품카테고리, GST)
  ※ 컬럼명이 한글이므로 encoding=utf-8 옵션 필수
=============================================================*/

libname proj "/home/student/abcdefg/open";  /* 본인 작업 경로로 수정 */

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

%import_csv(path=/home/student/abcdefg/open/Onlinesales_info.csv, out=proj.sales_raw);
%import_csv(path=/home/student/abcdefg/open/Customer_info.csv,   out=proj.cust_raw);
%import_csv(path=/home/student/abcdefg/open/Discount_info.csv,   out=proj.disc_raw);
%import_csv(path=/home/student/abcdefg/open/Marketing_info.csv,  out=proj.mkt_raw);
%import_csv(path=/home/student/abcdefg/open/Tax_info.csv,        out=proj.tax_raw);


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
   2. 결측치 · 이상치 탐지
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
