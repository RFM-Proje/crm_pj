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
