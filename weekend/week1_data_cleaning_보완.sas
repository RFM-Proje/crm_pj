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
