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

/*=============================================================
  WEEK 1 보완. week1_data_cleaning.sas 에서 다루지 않은
  결측치 · 이상치 체크 추가분
  이미 week1에서 다룬 항목(재작성 안 함):
   - Onlinesales_info 수량/평균금액/배송료 기초통계, 반품비율,
     평균금액 백분위수, 쿠폰상태 분포, 고객ID/제품카테고리 정합성,
     Customer_info 가입기간, Marketing_info 날짜 중복
  ※ 아래 [존재 이유]는 모두 Week1 자체 목표("데이터 이해 및 정제")
    범위 안에서만 설명함 (2주차 이후 로직은 끌어오지 않음)
  ※ import 매크로/테이블명은 week1_data_cleaning.sas(1-1)와 동일
=============================================================*/

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
   1. Discount_info : 할인율 결측/이상치
   [존재 이유]
   할인율은 disc_raw의 핵심 수치형 변수인데, 아직 한 번도
   기초통계를 낸 적이 없음. Week1 목표가 "5개 테이블 구조 파악 +
   결측치·이상치 탐지"이므로, 이 테이블도 다른 4개와 동일하게
   범위(음수/100% 초과 여부)를 확인해야 데이터 이해가 끝남
------------------------------------------------------------- */
proc means data=proj.disc_raw n nmiss min max mean std;
    var 할인율;
    title "1. Discount_info - 할인율 기초 통계 (음수/100% 초과 여부 확인)";
run;
title;

/* [존재 이유] disc_raw는 "월+제품카테고리" 단위로 설계된
   테이블이므로, 이 조합은 유일해야 정상임. 중복이 있다면
   그 자체로 원본 데이터의 설계 오류/중복 입력이므로 정제 전
   단계에서 짚고 넘어가야 함 */
proc sql;
    select 월, 제품카테고리, count(*) as 중복건수
    from proj.disc_raw
    group by 월, 제품카테고리
    having count(*) > 1;
    title "1-1. Discount_info 월+제품카테고리 중복 조합";
quit;
title;


/* -------------------------------------------------------------
   2. Marketing_info : 오프라인/온라인비용 결측/이상치
   [존재 이유]
   Onlinesales_info(수량/금액/배송료)는 Week1 원본 코드에서 이미
   확인했지만, mkt_raw의 수치형 변수(비용)는 아직 안 함.
   같은 정제 단계에서 5개 테이블 모두 동일 수준으로 검증하는 게
   Week1 "정합성 체크"의 목표에 맞음
------------------------------------------------------------- */
proc means data=proj.mkt_raw n nmiss min max mean std;
    var 오프라인비용 온라인비용;
    title "2. Marketing_info - 오프라인/온라인비용 기초 통계";
run;
title;

/* [존재 이유] 음수는 명백한 입력 오류, 0은 "집행 안 한 날"일
   수도 "결측을 0으로 잘못 채운 것"일 수도 있어 구분이 필요함.
   둘 다 정제 단계에서 걸러야 할 이상치 후보이므로 규모 파악 */
proc sql;
    select
        sum(case when 오프라인비용 < 0 then 1 else 0 end) as 오프라인비용_음수건수,
        sum(case when 온라인비용 < 0 then 1 else 0 end)   as 온라인비용_음수건수,
        sum(case when 오프라인비용 = 0 and 온라인비용 = 0 then 1 else 0 end) as 마케팅비용_0인날
    from proj.mkt_raw;
    title "2-1. Marketing_info 비용 음수/0 건수";
quit;
title;


/* -------------------------------------------------------------
   3. Tax_info : GST 결측/이상치
   [존재 이유]
   week1_data_cleaning.sas 2-6에서 "제품카테고리가 Tax_info에
   없는 경우"는 확인했지만, 그건 Onlinesales_info 기준의 정합성
   체크였고 tax_raw 자체의 GST 값(수치)은 아직 기초통계를
   낸 적이 없음. 5개 테이블 전체를 같은 수준으로 봐야 함
------------------------------------------------------------- */
proc means data=proj.tax_raw n nmiss min max mean std;
    var GST;
    title "3. Tax_info - GST 기초 통계 (0~1 또는 0~100 범위 벗어나는지 확인)";
run;
title;

/* [존재 이유] 제품카테고리당 세율은 1개여야 정상인 테이블
   구조. 중복이 있다면 disc_raw와 마찬가지로 원본 데이터
   자체의 설계 오류이므로 정제 전에 확인해야 함 */
proc freq data=proj.tax_raw;
    tables 제품카테고리 / nocum;
    title "3-1. Tax_info 제품카테고리 중복 여부 (카테고리당 세율 1개여야 정상)";
run;
title;


/* -------------------------------------------------------------
   4. Customer_info : 범주형 변수 결측 (성별, 고객지역)
   ※ 가입기간(수치형)은 week1_data_cleaning.sas 2-7에서 이미 확인함
   [존재 이유]
   week1_data_cleaning.sas는 cust_raw의 수치형 변수(가입기간)만
   확인했고, 범주형 변수(성별, 고객지역)는 다루지 않음. Week1
   목표가 "5개 테이블의 결측치 탐지"이므로 같은 테이블 안에서도
   수치형·범주형 둘 다 봐야 데이터 이해가 끝남
------------------------------------------------------------- */
proc freq data=proj.cust_raw;
    tables 성별 고객지역 / missing nocum;
    title "4. Customer_info - 성별/고객지역 분포 및 결측(.) 확인";
run;
title;


/* -------------------------------------------------------------
   5. 5개 테이블 전체 - 중복행(완전 동일 row) 체크
   [존재 이유]
   week1_data_cleaning.sas의 DATA STEP 정제 로직(고객ID 매칭,
   평균금액<=0 제외)은 "행 내용이 이상한 경우"만 걸러내고
   "완전히 똑같은 행이 2번 들어간 경우"(예: CSV 추출 시 중복
   저장)는 걸러내지 않음. 이건 필터링으로는 안 잡히고
   count(*) vs count(distinct *) 비교로만 드러나는, 전형적인
   Week1 "정제" 단계에서 끝내야 할 이상치 유형이므로 여기서 확인
------------------------------------------------------------- */
%macro check_dup(ds=, label=);
    proc sql;
        select count(*) as 전체행수,
               count(*) - (select count(*) from (select distinct * from &ds.)) as 중복행수
        from &ds.;
        title "5. &label. 완전 중복행 개수";
    quit;
    title;
%mend;

%check_dup(ds=proj.sales_raw, label=Onlinesales_info);
%check_dup(ds=proj.cust_raw,  label=Customer_info);
%check_dup(ds=proj.disc_raw,  label=Discount_info);
%check_dup(ds=proj.mkt_raw,   label=Marketing_info);
%check_dup(ds=proj.tax_raw,   label=Tax_info);

/* -------------------------------------------------------------
   6. Onlinesales_info : 배송료 상위 백분위수 및 이상치 후보
   [존재 이유]
   week1_data_cleaning.sas 2-1은 배송료의 평균/표준편차만 확인함.
   평균금액과 동일한 수준(2-3)으로 상위 백분위수까지 봐야
   극단적으로 튀는 배송료 거래(오입력/원거리배송 등)를
   놓치지 않고 파악할 수 있음
------------------------------------------------------------- */
proc univariate data=proj.sales_raw noprint;
    var 배송료;
    output out=proj.shipping_pctl pctlpts=95 99 99.9 pctlpre=P_;
run;

proc print data=proj.shipping_pctl;
    title "6. 배송료 상위 백분위수";
run;
title;

/* 상위 0.1% 초과 거래 - 실제 이상치 후보 목록 확인 */
proc sql;
    select * from proj.shipping_pctl;
quit;

proc sql;
    create table proj.shipping_outlier_candidates as
    select 거래ID, 고객ID, 거래날짜, 제품카테고리, 배송료
    from proj.sales_raw
    having 배송료 > (select P_99_9 from proj.shipping_pctl);
quit;

proc print data=proj.shipping_outlier_candidates;
    title "6-1. 배송료 상위 0.1% 초과 거래 (이상치 후보)";
run;
title;

/* 거래ID 내에서 배송료가 정말 항상 동일한지 전체 검증 */
proc sql;
    select 거래ID, count(distinct 배송료) as 배송료_종류수
    from proj.sales_raw
    group by 거래ID
    having calculated 배송료_종류수 > 1;
    title "거래ID 내 배송료가 여러 값인 경우 (0건이어야 가설 확정)";
quit;
title;/*0건확인 */


/*=============================================================
  WEEK 2. 파생변수 및 RFM 설계 (수정본)
  입력: proj.sales_clean (1주차 정제 결과)
        proj.cust_raw, proj.disc_raw
  원칙: RFM은 별도 등급표가 아니라 3주차 군집분석(K-Means)의
        입력 변수로만 사용한다 (중복 세분화 방지)
  1주차 확인 결과 반영:
   - 반품/취소(수량 음수) 없음 → Frequency는 단순 거래건수로 계산
   - 쿠폰상태 = Clicked(50.9%) / Not Used(15.3%) / Used(33.8%) 3단계

  [수정 사항 1 - AvgShipping 계산 방식 변경]
  기존: sales_with_disc(제품카테고리별 line-item 단위)에서
        바로 mean(배송료)를 계산 → 한 거래(주문)에 여러
        제품카테고리가 담기면 배송료가 그 개수만큼 그대로
        복제되어 평균이 왜곡됨 (검증 결과: 거래ID 내 배송료는
        항상 동일한 값 1개 → 배송료는 "주문 단위" 고정값으로 확인됨)
  수정: 배송료를 거래ID(주문) 단위로 먼저 1행으로 압축한 뒤
        고객 단위로 평균을 내도록 변경

  [수정 사항 2 - AvgOrderValue 계산 방식 변경]
  기존: sales_with_disc(line-item 단위)에서 바로
        mean(거래금액)을 계산 → 배송료와 동일한 문제. 한 주문에
        카테고리가 여러 개 담기면 주문 총액이 아니라 "품목별
        금액"이 그대로 평균에 들어가서, 다품목 주문일수록
        평균객단가가 실제 주문 단위 결제금액보다 작게 왜곡됨
  수정: 거래ID(주문) 단위로 먼저 총액을 합산한 order_total을
        만들고, 그 주문단위 총액을 고객 단위로 평균 내도록 변경
        (AvgShipping과 동일한 패턴)
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
   1-2. [신규] 배송료 - 거래ID(주문) 단위 압축
   [존재 이유]
   sales_with_disc는 제품카테고리별 line-item 단위라서 배송료가
   거래ID당 여러 번 반복됨. 검증 결과 거래ID 내 배송료는 항상
   동일한 값이므로(주문 단위 고정값), distinct로 한 번만 남겨야
   고객 단위 평균 계산 시 다품목 주문의 배송료가 중복 반영되지
   않음
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
   1-3. [신규] 주문(거래ID) 단위 총 결제금액 집계
   [존재 이유]
   거래금액(=평균금액*수량)은 제품카테고리별 line-item 금액이라,
   AvgOrderValue("평균 객단가" = 주문 1건당 평균 결제금액)를
   구하려면 먼저 거래ID 단위로 합산해서 "그 주문에서 실제로
   얼마를 결제했는가"부터 만들어야 함. 배송료와 달리 거래금액은
   품목마다 다르므로 sum으로 합산 (distinct 아님)
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
     각각 별도 계산 후 병합 (수정 사항)
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

/* 고객 단위 평균배송료 - 주문단위로 압축된 테이블 기준 (수정된 계산) */
proc sql;
    create table proj.avg_shipping as
    select 고객ID,
           mean(배송료) as AvgShipping label="평균배송료"
    from proj.shipping_per_order
    group by 고객ID;
quit;

/* 고객 단위 평균객단가 - 주문단위로 합산된 테이블 기준 (수정된 계산) */
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



/*=============================================================
  WEEK 2 보완. week2_rfm_derived.sas 에서 다루지 않은
  검증 항목 추가분
  전제: week2_rfm_derived.sas 를 먼저 실행해서
        proj.sales_with_disc / rfm_base / customer_features 가
        이미 생성되어 있어야 함
  ※ 아래 [존재 이유]는 모두 Week2 자체 목표("고객별 RFM 지표
    산출 + 파생변수 설계") 범위 안에서만 설명함
    (3주차 군집분석·5주차 이탈예측 로직은 끌어오지 않음)
=============================================================*/

libname proj "/home/student/open";


/* -------------------------------------------------------------
   1. 미구매 고객(거래 이력 없는 고객) 규모 파악
   [존재 이유]
   week2의 산출물명은 "고객별 RFM 지표"임. 그런데 rfm_base는
   sales_with_disc(거래 테이블)를 group by 고객ID로 만들었기
   때문에, 실제로는 "거래가 있는 고객"만의 지표임. "고객별"이라는
   이름을 쓰려면 모집단이 Customer_info 전체 고객인지, 거래
   이력 있는 고객만인지 week2 안에서 명확히 확인하고 넘어가야 함
------------------------------------------------------------- */
proc sql;
    select
        (select count(distinct 고객ID) from proj.cust_raw)   as Customer_info_전체고객수,
        (select count(distinct 고객ID) from proj.rfm_base)   as RFM_포함고객수,
        calculated Customer_info_전체고객수 - calculated RFM_포함고객수 as 미구매_고객수
    from sashelp.class(obs=1);
    title "1. Customer_info 대비 RFM 미포함(미구매) 고객수";
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
    title "1-1. 미구매 고객 샘플 (상위 10건)";
run;
title;


/* -------------------------------------------------------------
   2. RFM 왜도(Skewness)/첨도(Kurtosis) 확인
   [존재 이유]
   week2_rfm_derived.sas 2-1은 Recency/Frequency/Monetary의
   min/max/mean/std만 확인함. 이 값들이 크게 치우친 분포라면
   평균·표준편차만으로는 지표 특성을 제대로 설명하지 못하므로,
   week2 산출물인 "파생변수 명세서"를 완성하려면 분포 형태
   (치우침 정도)까지 같이 기록해야 함
------------------------------------------------------------- */
proc means data=proj.rfm_base skewness kurtosis;
    var Recency Frequency Monetary AvgOrderValue;
    title "2. RFM 변수 왜도/첨도 (절대값 1 이상이면 치우친 분포)";
run;
title;


/* -------------------------------------------------------------
   3. 쿠폰상태 비율 합계 검증 (Used + Clicked + NotUsed = 1)
   [존재 이유]
   CouponUseRate·CouponClickRate는 week2에서 새로 만든 파생변수
   임. CASE WHEN 로직으로 각각 따로 계산했기 때문에, 쿠폰상태
   값에 오타나 예상 못한 카테고리가 섞여 있으면 두 비율의 합이
   1보다 작아지는 오류가 생길 수 있음. 파생변수를 만든 직후
   계산 로직 자체가 맞는지 검증해야 함
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
    title "3. 쿠폰 미사용률(역산) 범위 확인 (0~1 벗어나면 쿠폰상태에 예상 못한 값 존재)";
run;
title;


/* -------------------------------------------------------------
   4. customer_features - 가입기간 결측 확인
   [존재 이유]
   week2_rfm_derived.sas 3-2는 customer_features(week2의 최종
   산출물)에서 성별·고객지역 결측만 확인하고 가입기간은 빠져
   있음. 같은 산출물 안에서 조인한 변수라면 전부 같은 수준으로
   검증해야 week2 파생변수 명세서가 완결됨
------------------------------------------------------------- */
proc sql;
    select
        count(*) as 고객수,
        sum(case when 가입기간 is missing then 1 else 0 end) as 가입기간_결측건수
    from proj.customer_features;
    title "4. customer_features 가입기간 결측 확인";
quit;
title;


/* -------------------------------------------------------------
   5. Monetary(총구매금액) 음수/0 여부 확인
   [존재 이유]
   거래금액(=평균금액*수량)은 week2 1단계에서 새로 만든 파생
   변수이고, Monetary는 거래금액을 고객 단위로 합산한 것임.
   week2 안에서 새로 계산을 만들었으면 그 계산이 의도대로
   나왔는지(음수/0 없음) 만든 직후 검증하는 게 맞음
------------------------------------------------------------- */
proc sql;
    select
        sum(case when Monetary < 0 then 1 else 0 end) as Monetary_음수_고객수,
        sum(case when Monetary = 0 then 1 else 0 end) as Monetary_0_고객수
    from proj.rfm_base;
    title "5. Monetary 음수/0 고객수 (0건이어야 정상)";
quit;
title;



/* week2_수정.sas 실행 직후, 이어서 바로 돌리면 됨 */
proc means data=proj.customer_features skewness kurtosis;
    var Recency Frequency Monetary AvgOrderValue
        CouponUseRate AvgDiscountRate AvgShipping;
    title "수정된 AvgOrderValue/AvgShipping 기준 왜도·첨도 재확인";
run;
title;
/*=============================================================
  WEEK 3. 군집분석 (핵심 세분화 축) - AvgShipping 로그변환 반영
  입력: proj.customer_features (2주차 산출물, AvgOrderValue
        주문단위 재계산 반영된 버전)
  원칙: CCC는 PROC FASTCLUS 단독으로는 산출되지 않는 계층적
        군집(PROC CLUSTER) 통계량이므로, SAS 표준 방식인
        "예비 군집(FASTCLUS) → CCC 기반 K 결정(CLUSTER) →
        최종 군집(FASTCLUS)" 3단계로 진행한다
  산출물: proj.customer_segments (Cluster ID 부여된 최종 세그먼트)

  [이번 수정 사항 - AvgShipping, AvgOrderValue 로그변환 추가]
  기존: AvgShipping을 원값 그대로 군집 변수에 사용
        -> K=7 재확인 시 배송료 300~500대인 이상치 고객 2명이
        각자 단독 군집(고객수 1명)으로 분리되는 문제 발견.
        AvgShipping의 R-Square가 0.87로 다른 변수 대비 비정상적
        으로 높게 나와 군집화를 사실상 이 변수 하나가 지배함
  수정: Frequency/Monetary와 동일하게 log(1+x) 변환한
        AvgShipping_log를 군집 변수로 사용

  추가 확인: week2에서 AvgOrderValue를 주문단위로 재계산한 뒤
        왜도 재검증 결과 5.16으로 확인됨(1 이상). 동일한 이유로
        AvgOrderValue_log를 만들어 군집 변수로 사용

  ※ 두 변수 모두 4-2(군집별 원단위 평균표)에서는 로그값이 아닌
    원래 단위(AvgShipping, AvgOrderValue)를 그대로 표시함 -
    군집화 입력변수와 해석/발표용 표시변수는 다를 수 있음
=============================================================*/

libname proj "/home/student/open";


/* -------------------------------------------------------------
   0. 왜도 반영 - 로그변환
   [결정 근거] week2 보완 2번에서 확인한 Recency/Frequency/
   Monetary/AvgOrderValue 왜도가 절대값 1 이상으로 나온 변수는
   PROC STDIZE 단순 표준화만으로는 스케일이 여전히 치우쳐 있어
   K-Means 거리 계산을 왜곡할 수 있음. Frequency/Monetary는
   구조적으로 항상 오른쪽 꼬리(소수 고객이 매우 큼)이므로
   log1p(=log(1+x)) 변환을 기본 적용. 실제 왜도 확인 결과에
   따라 아래 VAR 목록은 조정 가능
------------------------------------------------------------- */
data proj.customer_features_log;
    set proj.customer_features;
    Frequency_log = log(1 + Frequency);
    Monetary_log  = log(1 + Monetary);

    /* [신규] AvgShipping도 극단적 왜도(이상치 1~2명이 300~500대
       배송료) -> 로그변환 없이 그대로 쓰면 K-Means가 이 값만
       보고 해당 고객을 단독 군집으로 분리시킴 (K=7 재확인 시
       실제로 확인된 현상: 1명짜리 군집 2개 발생, R-Square=0.87로
       다른 변수 대비 비정상적으로 군집을 지배) */
    AvgShipping_log = log(1 + AvgShipping);

    /* [신규] AvgOrderValue 재검증 결과 왜도 5.16으로 확인됨
       (주문단위 재계산 이후 값 기준). Frequency/Monetary/
       AvgShipping과 동일하게 로그변환 필요 */
    AvgOrderValue_log = log(1 + AvgOrderValue);
run;


/* -------------------------------------------------------------
   1. PROC STDIZE - RFM 및 파생변수 표준화
   [존재 이유] K-Means는 유클리드 거리를 기반으로 하므로,
   단위가 다른 변수(원 단위 Monetary vs 비율 CouponUseRate)를
   그대로 두면 값이 큰 변수가 거리 계산을 지배함. METHOD=STD로
   평균0/표준편차1로 맞춰 모든 변수의 기여도를 동등하게 함
------------------------------------------------------------- */
proc stdize data=proj.customer_features_log out=proj.customer_features_std method=std;
    var Recency Frequency_log Monetary_log AvgOrderValue_log
        CouponUseRate AvgDiscountRate AvgShipping_log;
run;


/* -------------------------------------------------------------
   2단계. 예비 군집 (Preliminary Clustering)
   [존재 이유] 고객 수가 많을 경우 PROC CLUSTER(계층적 군집)를
   전체 데이터에 바로 돌리면 계산량이 과도함. SAS 권장 방식대로
   먼저 FASTCLUS로 다수(예: 50개)의 예비 군집으로 압축한 뒤,
   그 압축된 군집 평균에 대해 계층적 군집을 수행한다
------------------------------------------------------------- */
proc fastclus data=proj.customer_features_std maxclusters=50 maxiter=100
              out=proj.prelim_out mean=proj.prelim_mean noprint;
    var Recency Frequency_log Monetary_log AvgOrderValue_log
        CouponUseRate AvgDiscountRate AvgShipping_log;
run;


/* -------------------------------------------------------------
   2단계. PROC CLUSTER - CCC/Pseudo-F/Pseudo-T² 기반 최적 K 결정
   [존재 이유] 예비 군집 평균(prelim_mean)에 Ward's method로
   계층적 군집을 수행하면서, 각 군집수(NCL)별 CCC/PSF/PST2를
   산출. PROC FASTCLUS의 MEAN= 출력 데이터셋에는 _FREQ_,
   _RMSSTD_ 변수가 이미 자동으로 포함되어 있고, PROC CLUSTER는
   이를 자동으로 인식해서 통계량 계산에 반영함(SAS 공식 문서/
   예제 방식). 따라서 FREQ 문을 별도로 명시하지 않는다 -
   명시적 FREQ 문을 쓰면 CCC/PSF/PST2 통계량 자체가 산출되지
   않는 오류(컬럼 자체가 생성 안 됨)가 발생할 수 있음
   ※ ODS output ClusterHistory 테이블의 실제 컬럼명은
     CCC / PSF / PST2 임 (PseudoF, PseudoT2 아님 - SAS 공식 명칭)
------------------------------------------------------------- */
proc cluster data=proj.prelim_mean method=ward ccc pseudo out=proj.cluster_tree;
    var Recency Frequency_log Monetary_log AvgOrderValue_log
        CouponUseRate AvgDiscountRate AvgShipping_log;
    ods output ClusterHistory=proj.cluster_stats;
run;

/* CCC/PseudoF 추이를 눈으로 확인 - 그래프상 CCC가 급격히
   꺾이는 지점(피크) 또는 PseudoF가 국소 최대인 지점이 후보 K
   ※ proc contents로 실제 확인된 컬럼명: CubicClusCrit(=CCC),
     PseudoF(=PSF), PseudoTSq(=PST2) */
proc sql;
    select NumberOfClusters, CubicClusCrit, PseudoF, PseudoTSq
    from proj.cluster_stats
    where NumberOfClusters between 2 and 10
    order by NumberOfClusters;
    title "2. 군집수(K)별 CCC / PseudoF / PseudoTSq (K=2~10)";
quit;
title;

proc sgplot data=proj.cluster_stats;
    where NumberOfClusters between 2 and 15;
    series x=NumberOfClusters y=CubicClusCrit;
    xaxis label="군집 수(K)";
    yaxis label="CCC (Cubic Clustering Criterion)";
    title "2-1. K별 CCC 추이 (피크 지점이 최적 K 후보)";
run;
title;

proc sgplot data=proj.cluster_stats;
    where NumberOfClusters between 2 and 15;
    series x=NumberOfClusters y=PseudoF;
    xaxis label="군집 수(K)";
    yaxis label="Pseudo F Statistic";
    title "2-2. K별 PseudoF 추이 (국소 최대 지점이 최적 K 후보)";
run;
title;

/* -------------------------------------------------------------
   ※ 여기서 그래프/표를 보고 최적 K를 확정한다 (예: K=4)
   팀 논의 후 아래 매크로변수를 실제 값으로 수정할 것
------------------------------------------------------------- */
%let optimal_k = 6;   /* 최종 확정 (2026.08.19)
                          - AvgOrderValue_log, AvgShipping_log 반영 후
                            K=4,5,6 비교 실행
                          - K=4: 통계 근소 우위, 심플하나 세그먼트 단순
                          - K=5: 쿠폰의존 세그먼트(CouponUseRate 0.69) 발견
                          - K=6: CCC(48.69)·전체R²(0.506) 3개 후보 중 최고,
                            쿠폰의존 세그먼트 + "이탈위험 고객군"(305명,
                            20.8%, Recency 250.8일로 최고인데 Frequency/
                            Monetary는 상위권) 신규 발견 - 다음 주차
                            이탈예측(PROC GRADBOOST)과 스토리 연결됨
                          -> K=6 최종 채택 */


/* -------------------------------------------------------------
   3단계. 최종 PROC FASTCLUS - 전체 고객 대상 K-Means 확정
   [존재 이유] 2단계는 예비 군집(50개) 기준의 근사치이므로,
   확정된 K로 전체 표준화 데이터에 대해 다시 K-Means를 수행해야
   실제 개별 고객 단위의 정확한 군집 배정(Cluster ID)이 나옴
------------------------------------------------------------- */
proc fastclus data=proj.customer_features_std maxclusters=&optimal_k maxiter=100
              out=proj.customer_clustered;
    var Recency Frequency_log Monetary_log AvgOrderValue_log
        CouponUseRate AvgDiscountRate AvgShipping_log;
    title "3. 최종 K-Means 군집화 (K=&optimal_k)";
run;
title;


/* -------------------------------------------------------------
   4. 군집별 특성 프로파일링
   [존재 이유] Cluster ID만으로는 각 군집이 어떤 성격의
   고객군인지 알 수 없으므로, 원 단위(표준화 이전) RFM 값과
   인구통계 분포를 군집별로 비교해 세그먼트 이름을 붙일 근거를
   마련해야 함
------------------------------------------------------------- */

/* 4-1. Cluster ID를 원본(비표준화) 고객 특성 테이블에 병합 */
proc sql;
    create table proj.customer_segments as
    select a.*, b.cluster as Cluster_ID
    from proj.customer_features as a
    left join proj.customer_clustered as b
        on a.고객ID = b.고객ID;
quit;

/* 4-2. 군집별 R/F/M 평균 (원 단위 - 해석 용이)
   [주의] 여기서는 군집화에 실제 쓰인 AvgShipping_log가 아니라
   원래 단위인 AvgShipping을 그대로 보여줌 - "군집7 평균배송료가
   몇 원이다"처럼 발표할 때 로그값이 아니라 실제 원 단위가
   필요하기 때문 (군집화 입력변수와 해석용 표시변수는 다를 수 있음) */
proc means data=proj.customer_segments mean std n;
    class Cluster_ID;
    var Recency Frequency Monetary AvgOrderValue
        CouponUseRate AvgDiscountRate AvgShipping;
    title "4-2. 군집별 RFM 및 파생변수 평균 (원 단위)";
run;
title;

/* 4-3. 군집별 지역/성별 분포 */
proc freq data=proj.customer_segments;
    tables Cluster_ID * (성별 고객지역) / nocol nopercent;
    title "4-3. 군집별 성별/지역 분포";
run;
title;

/* 4-4. 군집 크기(고객수) 및 비중 */
proc sql;
    select Cluster_ID,
           count(*) as 고객수,
           count(*) / (select count(*) from proj.customer_segments) * 100 as 비중_pct
    from proj.customer_segments
    group by Cluster_ID
    order by Cluster_ID;
    title "4-4. 군집별 고객수 및 비중";
quit;
title;


/* -------------------------------------------------------------
   5. 최종 산출물 확인
   proj.customer_segments = 이후 모든 분석(코호트, 연관분석,
   이탈예측, 대시보드)의 기준이 되는 세그먼트 테이블
------------------------------------------------------------- */
proc contents data=proj.customer_segments varnum;
    title "5. 최종 세그먼트 테이블(customer_segments) 구조";
run;
title;


/*=============================================================
  WEEK 4. 일별 지표 스크리닝 및 변화점(급변 구간) 탐지
  - 목적: 문제정의 단계에서 "언제 갑자기 꺾이는가"를 데이터로 찾기
  - 전제조건: 이 스크립트를 돌리기 전, 같은 세션에서
              week1_data_cleaning.sas 와
              week2_rfm_derived_수정.sas 가 먼저 실행되어
              proj.sales_with_disc, proj.shipping_per_order,
              proj.mkt_raw 가 이미 존재해야 함
              (proc datasets library=proj; run; 으로 확인 가능)

  [이전 버전 대비 수정 사항]
  1) 원본 CSV를 다시 import하지 않음 → week1에서 이미 정제된
     proj.sales_with_disc, week2에서 이미 임포트된 proj.mkt_raw를
     그대로 재사용 (파이프라인 일관성 확보, 이상치 재유입 방지)
  2) libname 경로를 week1~3과 동일하게 "/home/student/open"으로 통일
  3) 평균배송료를 sales_with_disc(line-item 단위)가 아니라
     week2에서 만든 shipping_per_order(주문 단위)로 계산
     → 다품목 주문의 배송료 중복 반영 문제 해결
=============================================================*/

libname proj "/home/student/open";

/* -------------------------------------------------------------
   0. PNG 저장 목적지 설정
   [주의] 반드시 아래쪽 proc sgplot/sgpanel 호출보다
          "먼저" 실행되어 있어야 함. 순서가 바뀌면
          그림은 정상적으로 그려지지만 SAS Studio 기본
          임시폴더(SASWORK)에 저장되고 plots 폴더는 비어있게 됨
------------------------------------------------------------- */
options dlcreatedir;
libname _tmp "/home/student/open/plots";
libname _tmp clear;

ods _all_ close;
ods listing gpath="/home/student/open/plots";
ods graphics / reset=all imagefmt=png width=1200px height=500px;


/* -------------------------------------------------------------
   1. 일별 집계 테이블 생성
      - 거래건수, 총수량, 총매출액, 평균단가, 쿠폰사용률,
        고유고객수는 sales_with_disc(line-item 단위) 기준
      - 평균배송료만 shipping_per_order(주문 단위) 기준으로 별도 계산
------------------------------------------------------------- */
proc sql;
    create table proj.daily_agg_core as
    select 거래날짜_num as 날짜 format=yymmdd10.,
           count(distinct 거래ID)                                    as 거래건수,
           sum(수량)                                                 as 총수량,
           sum(거래금액)                                             as 총매출액,
           mean(평균금액)                                            as 평균단가,
           mean(case when 쿠폰상태="Used" then 1 else 0 end)         as 쿠폰사용률,
           count(distinct 고객ID)                                    as 고유고객수
    from proj.sales_with_disc
    group by 거래날짜_num
    order by 거래날짜_num;
quit;

/* 주문 단위 배송료를 날짜별로 다시 집계하려면 거래날짜 정보가 필요 -
   sales_with_disc에서 거래ID당 거래날짜를 1건만 붙여서 사용 */
proc sql;
    create table proj.shipping_daily as
    select 거래날짜_num as 날짜 format=yymmdd10.,
           mean(배송료) as 평균배송료
    from (
        select distinct 거래ID, 거래날짜_num, 배송료
        from proj.sales_with_disc
    )
    group by 거래날짜_num
    order by 거래날짜_num;
quit;

/* 일별 지표 + 배송료 + 마케팅비 병합 */
proc sql;
    create table proj.daily_agg as
    select a.*,
           b.평균배송료,
           c.오프라인비용,
           c.온라인비용,
           c.오프라인비용 + c.온라인비용 as 총마케팅비
    from proj.daily_agg_core as a
    left join proj.shipping_daily as b
        on a.날짜 = b.날짜
    left join proj.mkt_raw as c
        on a.날짜 = c.날짜
    order by a.날짜;
quit;


/* -------------------------------------------------------------
   2. 7일 이동평균 계산 (base SAS, DATA step + array 사용)
   [핵심 버그 수정 - 진짜 원인 발견]
   buf1~buf7(이동평균 계산용 임시 버퍼)을 drop하지 않아서
   proj.daily_agg에 그대로 남아있었음. 이 매크로가 지표마다
   반복 호출되는 구조라, 두 번째 호출부터는 "set proj.daily_agg"
   시점에 직전 지표가 남긴 buf1~buf7 값을 그대로 물려받아 이동
   평균 계산이 오염됨(예: 거래건수의 MA7에 총매출액 버퍼 값이
   섞여 들어감). "drop i;" -> "drop i buf1-buf7;"로 수정하여
   매 호출마다 버퍼가 확실히 초기화되도록 함. 지금까지 그래프가
   지표마다 다른 스케일로 깨져 보였던 근본 원인이 바로 이것임
   (ODS/캐시 문제가 아니었음)
------------------------------------------------------------- */
%macro add_rolling_mean(var=);
    data proj.daily_agg_tmp;
        set proj.daily_agg;
        retain buf1-buf7 0;
        array buf{7} buf1-buf7;
        do i = 1 to 6;
            buf{i} = buf{i+1};
        end;
        buf{7} = &var.;

        if _n_ >= 7 then do;
            &var._MA7 = mean(of buf1-buf7);
        end;
        drop i buf1-buf7;
    run;

    data proj.daily_agg;
        set proj.daily_agg_tmp;
    run;
%mend;

%add_rolling_mean(var=총매출액);
%add_rolling_mean(var=거래건수);
%add_rolling_mean(var=평균단가);
%add_rolling_mean(var=평균배송료);
%add_rolling_mean(var=쿠폰사용률);
%add_rolling_mean(var=고유고객수);
%add_rolling_mean(var=총마케팅비);

data proj.daily_agg_final;
    set proj.daily_agg;
run;


/* -------------------------------------------------------------
   3. 급변 구간(변화점 후보) 자동 탐지
      - 이동평균의 전일대비 차분(diff)을 표준화(z-score)해서
      - |z| > 2 인 지점을 "급변 후보"로 플래그
------------------------------------------------------------- */
%macro flag_changepoints(var=);
    data _tmp;
        set proj.daily_agg_final;
        diff_&var. = dif(&var._MA7);
    run;

    proc means data=_tmp noprint;
        var diff_&var.;
        output out=_stat mean=diff_mean std=diff_std;
    run;

    data proj.cp_&var.;
        if _n_ = 1 then set _stat;
        set _tmp;
        if diff_std > 0 then z_&var. = (diff_&var. - diff_mean) / diff_std;
        else z_&var. = .;
        if abs(z_&var.) > 2 then 변화점후보 = 1;
        else 변화점후보 = 0;
        keep 날짜 &var. &var._MA7 z_&var. 변화점후보;
    run;

    proc print data=proj.cp_&var.(where=(변화점후보=1));
        title "변화점 후보 - &var.";
        var 날짜 &var. z_&var.;
    run;
    title;
%mend;

%flag_changepoints(var=총매출액);
%flag_changepoints(var=거래건수);
%flag_changepoints(var=평균단가);
%flag_changepoints(var=평균배송료);
%flag_changepoints(var=쿠폰사용률);
%flag_changepoints(var=고유고객수);
%flag_changepoints(var=총마케팅비);


/* -------------------------------------------------------------
   4. 시각화 - 지표별 일별 값 + 7일 이동평균 + 변화점 표시
   [참고] 그동안 그림이 지표마다 뒤섞여 보였던 진짜 원인은
   2번 섹션의 buf1-buf7 누수 버그였음(이미 수정 완료). 파일명이나
   ODS 방식 자체는 문제가 아니었으므로, 이번엔 보기 편하도록
   지표명 그대로 파일명으로 사용함
------------------------------------------------------------- */

/* --- 총매출액 --- */
ods _all_ close;
ods listing gpath="/home/student/open/plots";
ods graphics / reset=all imagefmt=png imagename="총매출액";
proc sgplot data=proj.cp_총매출액;
    series x=날짜 y=총매출액 / lineattrs=(color=lightblue thickness=1) legendlabel="일별 값";
    series x=날짜 y=총매출액_MA7 / lineattrs=(color=orange thickness=2) legendlabel="7일 이동평균";
    scatter x=날짜 y=총매출액 / group=변화점후보
                                markerattrs=(symbol=circlefilled size=8)
                                filledoutlinedmarkers
                                legendlabel="변화점 후보";
    xaxis label="날짜" grid;
    yaxis label="총매출액" grid;
    title "총매출액 일별 추이 및 변화점 후보";
run;
title;
ods listing close;
ods html5;

/* --- 거래건수 --- */
ods _all_ close;
ods listing gpath="/home/student/open/plots";
ods graphics / reset=all imagefmt=png imagename="거래건수";
proc sgplot data=proj.cp_거래건수;
    series x=날짜 y=거래건수 / lineattrs=(color=lightblue thickness=1) legendlabel="일별 값";
    series x=날짜 y=거래건수_MA7 / lineattrs=(color=orange thickness=2) legendlabel="7일 이동평균";
    scatter x=날짜 y=거래건수 / group=변화점후보
                                markerattrs=(symbol=circlefilled size=8)
                                filledoutlinedmarkers
                                legendlabel="변화점 후보";
    xaxis label="날짜" grid;
    yaxis label="거래건수" grid;
    title "거래건수 일별 추이 및 변화점 후보";
run;
title;
ods listing close;
ods html5;

/* --- 평균단가 --- */
ods _all_ close;
ods listing gpath="/home/student/open/plots";
ods graphics / reset=all imagefmt=png imagename="평균단가";
proc sgplot data=proj.cp_평균단가;
    series x=날짜 y=평균단가 / lineattrs=(color=lightblue thickness=1) legendlabel="일별 값";
    series x=날짜 y=평균단가_MA7 / lineattrs=(color=orange thickness=2) legendlabel="7일 이동평균";
    scatter x=날짜 y=평균단가 / group=변화점후보
                                markerattrs=(symbol=circlefilled size=8)
                                filledoutlinedmarkers
                                legendlabel="변화점 후보";
    xaxis label="날짜" grid;
    yaxis label="평균단가" grid;
    title "평균단가 일별 추이 및 변화점 후보";
run;
title;
ods listing close;
ods html5;

/* --- 평균배송료 --- */
ods _all_ close;
ods listing gpath="/home/student/open/plots";
ods graphics / reset=all imagefmt=png imagename="평균배송료";
proc sgplot data=proj.cp_평균배송료;
    series x=날짜 y=평균배송료 / lineattrs=(color=lightblue thickness=1) legendlabel="일별 값";
    series x=날짜 y=평균배송료_MA7 / lineattrs=(color=orange thickness=2) legendlabel="7일 이동평균";
    scatter x=날짜 y=평균배송료 / group=변화점후보
                                  markerattrs=(symbol=circlefilled size=8)
                                  filledoutlinedmarkers
                                  legendlabel="변화점 후보";
    xaxis label="날짜" grid;
    yaxis label="평균배송료" grid;
    title "평균배송료 일별 추이 및 변화점 후보";
run;
title;
ods listing close;
ods html5;

/* --- 쿠폰사용률 --- */
ods _all_ close;
ods listing gpath="/home/student/open/plots";
ods graphics / reset=all imagefmt=png imagename="쿠폰사용률";
proc sgplot data=proj.cp_쿠폰사용률;
    series x=날짜 y=쿠폰사용률 / lineattrs=(color=lightblue thickness=1) legendlabel="일별 값";
    series x=날짜 y=쿠폰사용률_MA7 / lineattrs=(color=orange thickness=2) legendlabel="7일 이동평균";
    scatter x=날짜 y=쿠폰사용률 / group=변화점후보
                                  markerattrs=(symbol=circlefilled size=8)
                                  filledoutlinedmarkers
                                  legendlabel="변화점 후보";
    xaxis label="날짜" grid;
    yaxis label="쿠폰사용률" grid;
    title "쿠폰사용률 일별 추이 및 변화점 후보";
run;
title;
ods listing close;
ods html5;

/* --- 고유고객수 --- */
ods _all_ close;
ods listing gpath="/home/student/open/plots";
ods graphics / reset=all imagefmt=png imagename="고유고객수";
proc sgplot data=proj.cp_고유고객수;
    series x=날짜 y=고유고객수 / lineattrs=(color=lightblue thickness=1) legendlabel="일별 값";
    series x=날짜 y=고유고객수_MA7 / lineattrs=(color=orange thickness=2) legendlabel="7일 이동평균";
    scatter x=날짜 y=고유고객수 / group=변화점후보
                                  markerattrs=(symbol=circlefilled size=8)
                                  filledoutlinedmarkers
                                  legendlabel="변화점 후보";
    xaxis label="날짜" grid;
    yaxis label="고유고객수" grid;
    title "고유고객수 일별 추이 및 변화점 후보";
run;
title;
ods listing close;
ods html5;

/* --- 총마케팅비 --- */
ods _all_ close;
ods listing gpath="/home/student/open/plots";
ods graphics / reset=all imagefmt=png imagename="총마케팅비";
proc sgplot data=proj.cp_총마케팅비;
    series x=날짜 y=총마케팅비 / lineattrs=(color=lightblue thickness=1) legendlabel="일별 값";
    series x=날짜 y=총마케팅비_MA7 / lineattrs=(color=orange thickness=2) legendlabel="7일 이동평균";
    scatter x=날짜 y=총마케팅비 / group=변화점후보
                                  markerattrs=(symbol=circlefilled size=8)
                                  filledoutlinedmarkers
                                  legendlabel="변화점 후보";
    xaxis label="날짜" grid;
    yaxis label="총마케팅비" grid;
    title "총마케팅비 일별 추이 및 변화점 후보";
run;
title;
ods listing close;
ods html5;


/* -------------------------------------------------------------
   6. ODS 목적지 원복 - 결과 탭에서 다시 보이게 복구
------------------------------------------------------------- */
ods listing close;
ods html5;


/* 08-21 에러 파악하기 */
proc sgplot data=sashelp.class;
    scatter x=age y=height;
run;
/*=============================================================
  WEEK 5. 코호트 · 연관분석 (보조 인사이트)
  입력: proj.sales_with_disc (2주차), proj.customer_segments (3주차)
  산출물:
    1) 코호트 리텐션 히트맵 (첫구매월 기준)
    2) 전체 연관 규칙 (카테고리 조합, 지지도/신뢰도/향상도)
    3) 군집별 상위 구매 카테고리 Top5 (풀 교차분석 지양)

  [코호트 기준 관련 참고]
  Customer_info에 실제 가입일(캘린더 날짜)이 없고 가입기간(누적
  개월수)만 존재함. 따라서 "가입월" 대신 고객의 첫구매월을
  코호트 기준(Acquisition Cohort)으로 사용함 - 이커머스
  리텐션 분석에서 통상적으로 쓰이는 대안 방식

  [실행 전 필수 확인 - K=6 반영 여부]
  PART 3(군집별 Top5)는 proj.customer_segments를 그대로 참조함.
  이 파일 실행 전, 반드시 최신 K=6 기준으로 확정된
  week3_clustering_수정.sas를 먼저(재)실행해서 customer_segments가
  K=6 결과로 갱신되어 있는지 확인할 것. 코드 자체는 K값과 무관하게
  Cluster_ID 컬럼만 참조하므로 수정 불필요, 실행 순서만 주의
=============================================================*/

libname proj "/home/student/open";


/* =================================================================
   PART 1. 코호트 리텐션 히트맵
================================================================= */

/* -------------------------------------------------------------
   1-1. 고객별 첫구매월 = 코호트월 산출
------------------------------------------------------------- */
proc sql;
    create table proj.cohort_base as
    select 고객ID,
           intnx('month', min(거래날짜_num), 0) as 코호트월 format=yymmn6.
    from proj.sales_with_disc
    group by 고객ID;
quit;

/* -------------------------------------------------------------
   1-2. 고객x월 단위 활동(구매) 여부 테이블
------------------------------------------------------------- */
proc sql;
    create table proj.monthly_activity as
    select distinct 고객ID,
           intnx('month', 거래날짜_num, 0) as 활동월 format=yymmn6.
    from proj.sales_with_disc;
quit;

/* -------------------------------------------------------------
   1-3. 코호트월 대비 경과개월(Period) 계산
------------------------------------------------------------- */
proc sql;
    create table proj.cohort_activity as
    select a.고객ID,
           b.코호트월,
           a.활동월,
           intck('month', b.코호트월, a.활동월) as 경과개월
    from proj.monthly_activity as a
    inner join proj.cohort_base as b
        on a.고객ID = b.고객ID;
quit;

/* -------------------------------------------------------------
   1-4. 코호트 크기(월별 최초 유입 고객수) 산출
------------------------------------------------------------- */
proc sql;
    create table proj.cohort_size as
    select 코호트월,
           count(*) as 코호트고객수
    from proj.cohort_base
    group by 코호트월;
quit;

/* -------------------------------------------------------------
   1-5. 코호트월 x 경과개월 별 잔존 고객수 -> 리텐션율(%)
------------------------------------------------------------- */
proc sql;
    create table proj.cohort_retention_raw as
    select a.코호트월,
           a.경과개월,
           count(distinct a.고객ID) as 잔존고객수,
           b.코호트고객수,
           calculated 잔존고객수 / b.코호트고객수 * 100 as 리텐션율
    from proj.cohort_activity as a
    inner join proj.cohort_size as b
        on a.코호트월 = b.코호트월
    group by a.코호트월, a.경과개월, b.코호트고객수
    order by a.코호트월, a.경과개월;
quit;

/* -------------------------------------------------------------
   1-5-1. [수정] 활동이 아예 없었던 (코호트월, 경과개월) 조합은
   cohort_retention_raw에 행 자체가 없어서 히트맵에서 빈칸으로
   보임 -> "0%"와 "결측"이 구분 안 되는 문제.
   전체 (코호트월 x 가능한 경과개월) 격자를 만들고 활동 없는
   조합은 리텐션율 0으로 명시적으로 채움
------------------------------------------------------------- */
proc sql noprint;
    select max(경과개월) into :max_period
    from proj.cohort_retention_raw;
quit;

/* 0~max_period까지의 경과개월 시퀀스 테이블 */
data proj.period_seq;
    do 경과개월 = 0 to &max_period.;
        output;
    end;
run;

/* 코호트월 x 경과개월 전체 격자 (cross join) */
proc sql;
    create table proj.cohort_grid as
    select a.코호트월, b.경과개월
    from (select distinct 코호트월 from proj.cohort_base) as a
    cross join proj.period_seq as b;
quit;

proc sql;
    create table proj.cohort_retention as
    select g.코호트월,
           g.경과개월,
           coalesce(r.잔존고객수, 0) as 잔존고객수,
           s.코호트고객수,
           /* [중요] 코호트월+경과개월이 데이터 관측 종료 시점(2019-12)을
              넘어가면 "0%"가 아니라 "아직 관찰 불가능"임 - 이 둘을
              섞으면 늦게 들어온 코호트가 실제보다 리텐션이 나쁜 것처럼
              왜곡되어 보임(우측 절단 문제) */
           case when intnx('month', g.코호트월, g.경과개월) <= "31DEC2019"d
                then 1 else 0 end as 관측가능,
           case when intnx('month', g.코호트월, g.경과개월) <= "31DEC2019"d
                then coalesce(r.리텐션율, 0)
                else .
           end as 리텐션율
    from proj.cohort_grid as g
    inner join proj.cohort_size as s
        on g.코호트월 = s.코호트월
    left join proj.cohort_retention_raw as r
        on g.코호트월 = r.코호트월 and g.경과개월 = r.경과개월
    order by g.코호트월, g.경과개월;
quit;

/* -------------------------------------------------------------
   1-6. 리텐션 히트맵 시각화
   x=경과개월(0,1,2...), y=코호트월, 색상=리텐션율(%)
   [수정] 관측 불가능 구간(늦게 들어온 코호트의 미래 시점)은
   결측(.)이라 자동으로 빈칸 처리됨 - 진짜 0%(파란색 계열 중
   가장 옅은 색)와 구분됨
------------------------------------------------------------- */
proc sgplot data=proj.cohort_retention;
    heatmapparm x=경과개월 y=코호트월 colorresponse=리텐션율 /
        colormodel=(cxf0f0f0 cx4393c3 cx2166ac);
    xaxis label="경과개월(코호트월 이후)" integer;
    yaxis label="코호트월(첫구매월)" discreteorder=data reverse;
    title "코호트 리텐션 히트맵 (첫구매월 기준, 단위: %)";
    footnote "빈칸 = 관측기간 부족으로 아직 확인 불가능한 구간 (0퍼센트와는 다름)";
run;
title;
footnote;

/* 숫자로도 확인 - 발표자료용 표. 관측가능 컬럼으로 0퍼센트와
   관측불가를 명확히 구분해서 표시 */
proc print data=proj.cohort_retention;
    var 코호트월 경과개월 코호트고객수 잔존고객수 리텐션율 관측가능;
    title "코호트 리텐션 표 (숫자, 관측가능=0이면 아직 확인 불가능한 구간)";
run;
title;


/* =================================================================
   PART 2. 연관분석 - 전체 규칙
================================================================= */

/* -------------------------------------------------------------
   2-0. 주문(거래ID) x 제품카테고리 - 중복 제거된 basket 테이블
   [존재 이유] sales_with_disc는 제품ID 단위라 같은 카테고리
   상품을 여러 개 담으면 중복 행이 생김. 연관분석은 "그 주문에
   해당 카테고리가 있었는가(0/1)"만 필요하므로 distinct 처리
------------------------------------------------------------- */
proc sql;
    create table proj.basket as
    select distinct 거래ID, 제품카테고리
    from proj.sales_with_disc;
quit;

proc sql noprint;
    select count(distinct 거래ID) into :total_orders
    from proj.basket;
quit;
%put 전체 주문수 = &total_orders;


/* -------------------------------------------------------------
   2-1. [옵션 A] PROC ASSOC 시도
   [주의] PROC ASSOC은 SAS Enterprise Miner 라이선스가 필요한
   프로시저로, 실행 전 PROC DMDB로 카탈로그를 먼저 만들어야
   합니다. 사용 중인 SAS Studio(OnDemand for Academics 등)에는
   보통 포함되어 있지 않아 아래 코드가 "PROCEDURE ASSOC not
   found" 에러로 실패할 수 있습니다. 에러가 나면 2-2(옵션 B,
   PROC SQL 수동 계산)로 바로 넘어가세요 - 결과는 동일합니다.
------------------------------------------------------------- */
/*
proc dmdb data=proj.basket dmdbcat=proj.basket_dmdb;
    id 거래ID;
    class 제품카테고리;
run;

proc assoc data=proj.basket dmdbcat=proj.basket_dmdb
           out=proj.assoc_rules
           itemsout=proj.assoc_items
           minsupport=0.01
           minconf=0.1
           maxitems=2;
    target 제품카테고리;
    id 거래ID;
run;

proc sort data=proj.assoc_rules;
    by descending lift;
run;

proc print data=proj.assoc_rules(obs=20);
    title "PROC ASSOC 연관규칙 상위 20개 (Lift 기준)";
run;
title;
*/


/* -------------------------------------------------------------
   2-2. [옵션 B] PROC SQL 수동 연관분석 (기본 사용 권장)
   지지도(Support), 신뢰도(Confidence), 향상도(Lift) 직접 계산
   A -> B : A를 산 주문 중 B도 같이 산 비율
------------------------------------------------------------- */

/* 카테고리별 단일 지지도 */
proc sql;
    create table proj.support_single as
    select 제품카테고리,
           count(distinct 거래ID) as 주문수,
           calculated 주문수 / &total_orders as 지지도
    from proj.basket
    group by 제품카테고리;
quit;

/* 카테고리 쌍(A,B) 동시 등장 주문수 - 자기조인, A<B로 중복 방지 */
proc sql;
    create table proj.pair_count as
    select a.제품카테고리 as 카테고리A,
           b.제품카테고리 as 카테고리B,
           count(distinct a.거래ID) as 동시주문수
    from proj.basket as a
    inner join proj.basket as b
        on a.거래ID = b.거래ID and a.제품카테고리 < b.제품카테고리
    group by a.제품카테고리, b.제품카테고리;
quit;

/* A->B, B->A 양방향 규칙으로 펼치고 지지도/신뢰도/향상도 계산 */
proc sql;
    create table proj.assoc_rules_manual as
    select 카테고리A as 선행, 카테고리B as 후행,
           동시주문수,
           동시주문수 / &total_orders as 지지도_AB,
           s1.지지도 as 지지도_A,
           s2.지지도 as 지지도_B,
           (동시주문수 / &total_orders) / s1.지지도 as 신뢰도,
           ((동시주문수 / &total_orders) / s1.지지도) / s2.지지도 as 향상도
    from proj.pair_count as p
    inner join proj.support_single as s1 on p.카테고리A = s1.제품카테고리
    inner join proj.support_single as s2 on p.카테고리B = s2.제품카테고리

    outer union corr

    select 카테고리B as 선행, 카테고리A as 후행,
           동시주문수,
           동시주문수 / &total_orders as 지지도_AB,
           s2.지지도 as 지지도_A,
           s1.지지도 as 지지도_B,
           (동시주문수 / &total_orders) / s2.지지도 as 신뢰도,
           ((동시주문수 / &total_orders) / s2.지지도) / s1.지지도 as 향상도
    from proj.pair_count as p
    inner join proj.support_single as s1 on p.카테고리A = s1.제품카테고리
    inner join proj.support_single as s2 on p.카테고리B = s2.제품카테고리;
quit;

proc sort data=proj.assoc_rules_manual;
    by descending 향상도;
run;

/* [수정] 지지도 필터 없는 표를 먼저 보여주면 희귀 조합의 극단적
   향상도가 상위권을 오염시켜 첫인상이 왜곡될 수 있음 -> 필터링된
   (지지도 1% 이상) 안정적인 표를 먼저 보여주는 순서로 변경 */
proc print data=proj.assoc_rules_manual(where=(지지도_AB >= 0.01) obs=20);
    var 선행 후행 동시주문수 지지도_AB 신뢰도 향상도;
    title "연관규칙 상위 20개 (지지도 1% 이상, 향상도 기준) - 기본 확인용";
run;
title;

/* 참고용 - 필터 없는 전체 결과 (희귀 조합 포함, 해석 시 주의) */
proc print data=proj.assoc_rules_manual(obs=20);
    var 선행 후행 동시주문수 지지도_AB 신뢰도 향상도;
    title "참고: 연관규칙 상위 20개 (향상도 기준, 최소 지지도 필터 없음 - 희귀 조합 포함 주의)";
run;
title;


/* =================================================================
   PART 3. 군집별 상위 구매 카테고리 Top5
   [존재 이유] 8개 군집 x 20개 카테고리 풀 교차표는 정보량이
   과해서 발표자료에 부적합. 군집 성격 해석에 필요한 "이 군집이
   특히 많이 사는 카테고리"만 Top5로 압축
================================================================= */

/* 군집 x 카테고리 별 구매건수 집계 */
proc sql;
    create table proj.cluster_category as
    select b.Cluster_ID,
           a.제품카테고리,
           count(distinct a.거래ID) as 구매건수
    from proj.sales_with_disc as a
    inner join proj.customer_segments as b
        on a.고객ID = b.고객ID
    group by b.Cluster_ID, a.제품카테고리
    order by b.Cluster_ID, 구매건수 descending;
quit;

/* 군집 내 순위 부여 후 Top5만 추출 */
data proj.cluster_category_top5;
    set proj.cluster_category;
    by Cluster_ID descending 구매건수;
    retain 순위;
    if first.Cluster_ID then 순위 = 1;
    else 순위 + 1;
    if 순위 <= 5;
run;

proc print data=proj.cluster_category_top5;
    var Cluster_ID 순위 제품카테고리 구매건수;
    title "군집별 상위 구매 카테고리 Top5";
run;
title;

/* 발표용 시각화 - 군집별 Top5 막대그래프 */
proc sgpanel data=proj.cluster_category_top5;
    panelby Cluster_ID / columns=2 rows=4 novarname;
    hbar 제품카테고리 / response=구매건수 categoryorder=respdesc;
    rowaxis label="";
    colaxis label="구매건수";
    title "군집별 상위 구매 카테고리 Top5";
run;
title;
