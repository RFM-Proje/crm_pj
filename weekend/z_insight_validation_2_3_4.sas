/*=============================================================
  보조분석 2. week4에서 발견된 인사이트 2/3/4번 검증
  1) 배송료 이상치(1~3월 집중) - 원거리/고배송비 군집(K=6 기준
     Cluster_ID=1로 확인됨)과 시기적으로 관련 있는지
  2) 총마케팅비 감소 -> 매출/거래건수 반응까지의 시차(lag)
  3) 12월 말 거래건수 급락 - 실제 냉각인지 데이터 절단인지

  전제조건 (같은 세션에서 순서대로 먼저 실행):
    week1_data_cleaning(_보완) -> week2_rfm_derived_수정 ->
    week3_clustering_수정(K=6 확정본) -> week4_changepoint_screening_수정
  위 4개가 만들어두는 proj.sales_with_disc, proj.customer_segments,
  proj.daily_agg_final, proj.cp_* 테이블들을 그대로 재사용함
=============================================================*/

libname proj "/home/student/open";


/* =================================================================
   인사이트 2. 배송료 이상치 시기(1~3월 집중) x 원거리/고배송비 군집
   [배경] week4 그래프에서 평균배송료 변화점 후보(빨간 점)가
   1~3월에 몰려있었음. week3 K=6 프로파일링에서 AvgShipping이
   유독 높았던 군집(Cluster_ID=1, 69명, 평균배송료 35.1원)이
   "원거리/고배송비" 세그먼트로 해석됨. 이 두 발견이 실제로
   연결되는지, 즉 그 군집 고객들이 1~3월에 유독 몰려서 첫구매/
   활동을 했는지 확인
================================================================= */

/* 2-1. week1에서 확인했던 배송료 상위 이상치 거래 날짜들이
   실제로 어느 군집 고객의 거래인지 확인 */
proc sql;
    create table proj.shipping_outlier_by_cluster as
    select a.거래ID, a.고객ID, a.거래날짜_num as 날짜 format=yymmdd10.,
           a.제품카테고리, a.배송료,
           b.Cluster_ID
    from proj.sales_with_disc as a
    inner join proj.customer_segments as b
        on a.고객ID = b.고객ID
    where a.배송료 >= 300   /* week1에서 확인한 상위 0.1% 이상치 기준 */
    order by a.거래날짜_num;
quit;

proc print data=proj.shipping_outlier_by_cluster;
    title "2-1. 배송료 이상치 거래의 군집 소속 확인";
    var 날짜 고객ID 제품카테고리 배송료 Cluster_ID;
run;
title;

proc freq data=proj.shipping_outlier_by_cluster;
    tables Cluster_ID / nocum;
    title "2-1-1. 배송료 이상치 거래 - 군집별 분포 (특정 군집에 몰려있는지 확인)";
run;
title;

/* 2-2. 군집1(고배송비 추정) 고객들의 첫구매월 분포 -
   1~3월에 몰려있는지 다른 군집과 비교 */
proc sql;
    create table proj.cluster_first_purchase_month as
    select b.Cluster_ID,
           put(min(a.거래날짜_num), monname3.) as 첫구매월,
           month(min(a.거래날짜_num)) as 첫구매월번호,
           a.고객ID
    from proj.sales_with_disc as a
    inner join proj.customer_segments as b
        on a.고객ID = b.고객ID
    group by b.Cluster_ID, a.고객ID;
quit;

proc freq data=proj.cluster_first_purchase_month;
    tables Cluster_ID * 첫구매월번호 / nocol norow nopercent;
    title "2-2. 군집별 첫구매월 분포 - 군집1이 1~3월에 몰려있는지 확인";
run;
title;

/* 요약 - 군집별 평균 첫구매월번호 (숫자가 작을수록 초반에 몰림) */
proc sql;
    select Cluster_ID,
           mean(첫구매월번호) as 평균첫구매월,
           count(*) as 고객수
    from proj.cluster_first_purchase_month
    group by Cluster_ID
    order by 평균첫구매월;
    title "2-2-1. 군집별 평균 첫구매월 (숫자가 작을수록 연초에 몰림)";
quit;
title;


/* =================================================================
   인사이트 3. 총마케팅비 감소 -> 매출/거래건수 반응 시차(lag) 분석
   [배경] week4에서 1~2월, 6월에 마케팅비가 뚝 떨어졌다가 다시
   오르는 구간이 있었음. 이 변화가 매출/거래건수에 즉시 반영되는지,
   며칠~몇 주 지연되어 나타나는지 lag별 상관관계로 확인
================================================================= */

/* 0~14일 lag별 상관계수를 계산하기 위해 마케팅비를 미리 당겨놓은
   테이블 생성 (lag된 총마케팅비 vs 당일 총매출액/거래건수) */
proc sql;
    create table proj.lag_base as
    select 날짜, 총마케팅비, 총매출액, 거래건수
    from proj.daily_agg_final
    order by 날짜;
quit;

%macro lag_corr(lag=);
    data proj.lag_tmp;
        set proj.lag_base;
        마케팅비_lag = lag&lag.(총마케팅비);
    run;

    proc corr data=proj.lag_tmp outp=proj.corr_out_&lag. noprint;
        var 마케팅비_lag;
        with 총매출액;
    run;

    data proj.corr_result_&lag.;
        set proj.corr_out_&lag.(where=(_type_="CORR" and _name_="마케팅비_lag"));
        lag일수 = &lag.;
        상관계수 = 총매출액;
        keep lag일수 상관계수;
    run;
%mend;

%lag_corr(lag=0);
%lag_corr(lag=1);
%lag_corr(lag=2);
%lag_corr(lag=3);
%lag_corr(lag=5);
%lag_corr(lag=7);
%lag_corr(lag=10);
%lag_corr(lag=14);

data proj.lag_corr_summary;
    set proj.corr_result_0 proj.corr_result_1 proj.corr_result_2
        proj.corr_result_3 proj.corr_result_5 proj.corr_result_7
        proj.corr_result_10 proj.corr_result_14;
run;

proc sort data=proj.lag_corr_summary;
    by lag일수;
run;

proc print data=proj.lag_corr_summary;
    title "3-1. lag일수별 (마케팅비 vs 총매출액) 상관계수";
    title2 "상관계수가 가장 높은 lag일수가 실제 반응 시차";
run;
title;

proc sgplot data=proj.lag_corr_summary;
    series x=lag일수 y=상관계수 / markers lineattrs=(thickness=2);
    refline 0 / axis=y lineattrs=(pattern=dash);
    xaxis label="마케팅비 지연일수(lag)" integer;
    yaxis label="상관계수 (마케팅비 vs 총매출액)";
    title "3-2. 마케팅비 변화가 매출에 반영되기까지 걸리는 시차";
run;
title;


/* =================================================================
   인사이트 4. 12월 말 거래건수 급락 - 실제 냉각 vs 데이터 절단
   [배경] week4 거래건수 그래프에서 12월 초 205건까지 찍고
   12월 말엔 20~50건대로 급락함. 진짜 소비 냉각인지, 연말
   공휴일 효과인지, 데이터 자체가 12/31 근처에서 불완전 집계된
   것인지 확인
================================================================= */

/* 4-1. 12월 일자별 거래건수 + 요일 표시 (주말/공휴일 패턴 확인) */
proc sql;
    create table proj.december_check as
    select 날짜,
           day(날짜) as 일,
           weekday(날짜) as 요일번호,
           put(날짜, downame3.) as 요일,
           거래건수,
           총매출액
    from proj.daily_agg_final
    where month(날짜) = 12
    order by 날짜;
quit;

proc print data=proj.december_check;
    var 날짜 요일 거래건수 총매출액;
    title "4-1. 12월 일자별 거래건수 - 특정 요일(주말)에만 낮은지, 12/25 전후 급락인지 확인";
run;
title;

/* 4-2. 원본 데이터의 실제 최대 날짜 확인 -
   12/31 이후로 데이터가 아예 없는지, 그 전부터 이미 누락되는지 */
proc sql;
    select max(거래날짜_num) as 최종거래일 format=yymmdd10.,
           min(거래날짜_num) as 최초거래일 format=yymmdd10.,
           count(distinct 거래날짜_num) as 관측일수
    from proj.sales_with_disc;
    title "4-2. 데이터 관측 기간 자체 확인 (365일 전부 있는지)";
quit;
title;

/* 4-3. 12월 마지막 주(25일~31일) vs 그 이전 주(18~24일) 비교 -
   요일 구성이 같은 두 구간을 비교해서 순수 감소폭 확인 */
proc sql;
    select case when day(날짜) between 18 and 24 then "1_크리스마스 이전 주"
                when day(날짜) between 25 and 31 then "2_크리스마스~연말 주"
           end as 구간,
           mean(거래건수) as 평균거래건수,
           mean(총매출액) as 평균총매출액
    from proj.daily_agg_final
    where month(날짜) = 12 and day(날짜) >= 18
    group by calculated 구간;
    title "4-3. 12월 크리스마스 전후 주간 비교 (동일 요일수 기준)";
quit;
title;

/* -------------------------------------------------------------
   해석 기준
   - 4-1에서 급락이 특정 요일(토/일)에 반복되는 패턴이면
     -> 정상적인 주말 효과, 데이터 문제 아님
   - 4-2에서 관측일수가 365일 미만이면
     -> 특정 날짜 데이터 자체가 누락된 것, 절단 문제 있음
   - 4-3에서 크리스마스 이후 주가 확연히 낮으면
     -> 연말 공휴일로 인한 실제 소비 패턴(정상), 데이터 문제 아님
------------------------------------------------------------- */
