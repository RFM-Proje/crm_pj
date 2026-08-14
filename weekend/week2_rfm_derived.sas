/*=============================================================
  WEEK 2. 파생변수 및 RFM 설계
  입력: proj.sales_clean (1주차 정제 결과)
        proj.cust_raw, proj.disc_raw
  원칙: RFM은 별도 등급표가 아니라 3주차 군집분석(K-Means)의
        입력 변수로만 사용한다 (중복 세분화 방지)
  1주차 확인 결과 반영:
   - 반품/취소(수량 음수) 없음 → Frequency는 단순 거래건수로 계산
   - 쿠폰상태 = Clicked(50.9%) / Not Used(15.3%) / Used(33.8%) 3단계
=============================================================*/

libname proj "/home/student/abcdefg/open";

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
   2. 고객 단위 RFM 지표 산출
   - 기준일(Reference Date) = 데이터 내 최종 거래일 + 1일
------------------------------------------------------------- */
proc sql noprint;
    select max(거래날짜_num) + 1 into :ref_date
    from proj.sales_with_disc;
quit;

%put 기준일 = &ref_date;
%put 기준일(날짜형식) = %sysfunc(putn(&ref_date, yymmdd10.));

proc sql;
    create table proj.rfm_base as
    select
        고객ID,
        &ref_date - max(거래날짜_num)              as Recency label="최근성(일)",
        count(distinct 거래ID)                      as Frequency label="구매빈도(건)",
        sum(거래금액)                                as Monetary label="총구매금액",
        mean(거래금액)                               as AvgOrderValue label="평균객단가",
        mean(case when 쿠폰상태="Used" then 1 else 0 end)    as CouponUseRate label="쿠폰실사용률",
        mean(case when 쿠폰상태="Clicked" then 1 else 0 end) as CouponClickRate label="쿠폰클릭만비율",
        mean(할인율)                                 as AvgDiscountRate label="평균할인율",
        mean(배송료)                                 as AvgShipping label="평균배송료"
    from proj.sales_with_disc
    group by 고객ID;
quit;

/* RFM 분포 확인 (이상치 유무, 3주차 표준화 전 스케일 파악용) */
proc means data=proj.rfm_base n nmiss min max mean std;
    var Recency Frequency Monetary AvgOrderValue CouponUseRate CouponClickRate AvgDiscountRate;
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
    var Recency Frequency Monetary AvgOrderValue CouponUseRate AvgDiscountRate;
    title "4-1. RFM/파생변수 간 상관관계";
run;
title;
