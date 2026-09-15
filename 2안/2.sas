/*=============================================================
  STAGE 2B. RFM-P 가중치 세분화 (기존 7변수 K-means 세분화를 교체)

  RFM에 제품가치(P)까지 반영한 가중치 세분화 방법론:
    1) R(Recency), F(Frequency), M(Monetary) 계산
    2) P(제품가치) = 카테고리별 (구매횟수 x 평균단가) 순위 1~20점을
       고객이 산 카테고리마다 곱해서 합산
    3) R/F/M/P 각각 표준화 후 K-means (Elbow Method로 결정한 군집수:
       R=3, F=4, M=2, P=4)
    4) 군집별 변동계수(CV=표준편차/평균)를 구해서, 가장 일관된
       패턴을 보인 지표에 더 큰 가중치 부여
    5) RFMP_SCORE = W1*R + W2*F + W3*M + W4*P
    6) 6등분(PROC RANK)해서 VIP/Diamond/Platinum/Gold/Silver/Bronze
       등급 부여

  [주의] 기존 stage2(K-means 7변수)와는 완전히 다른 기준으로 고객이
  재배정되므로, 이후 stage3/5/6/7이 전부 이 결과를 기준으로 다시
  실행되어야 함 (기존 군집라벨 값과 호환 안 됨).

  전제조건: STAGE 1 실행 완료 (proj.sales_with_disc, proj.customer_segments)
  산출물: proj.customer_rfmp (고객ID, R, F, M, P, RFMP_SCORE, 등급, 등급명),
          proj.rfmp_tier_top_category (등급별 대표카테고리),
          proj.rfmp_weights (최종 가중치 기록용)
=============================================================*/

libname proj "/home/student/open";

/* -------------------------------------------------------------
   0. proj.customer_segments 재생성 (인구통계 전용 테이블)
   [주의] 이 테이블 이름은 "군집(세그먼트)"처럼 보이지만 실제로는
   성별/고객지역/가입기간 같은 고객 인구통계만 담고 있고, stage4/6
   등 여러 곳에서 세분화 방식과 무관하게 그냥 고객 기본정보 조회용
   으로 참조함. 기존 K-means stage2가 만들던 걸 여기서 다시 만들어둠
   (원본: proj.cust_raw) - 세분화 로직(RFM-P)과는 완전히 별개임.
------------------------------------------------------------- */
proc contents data=proj.cust_raw varnum;
    title "0-1. [확인용] cust_raw 컬럼 구조 - 고객ID/성별/고객지역/가입기간 있는지 확인";
run;
title;

proc sql;
    create table proj.customer_segments as
    select distinct 고객ID, 성별, 고객지역, 가입기간
    from proj.cust_raw;
quit;

proc print data=proj.customer_segments(obs=10) noobs;
    title "0-2. [확인용] customer_segments 미리보기";
run;
title;


/* -------------------------------------------------------------
   1. R, F, M 계산 (전체 관측기간 기준)
------------------------------------------------------------- */
proc sql noprint;
    select max(거래날짜_num) into :last_date from proj.sales_with_disc;
quit;

proc sql;
    create table work.rfm_base as
    select 고객ID,
           &last_date - max(거래날짜_num) as R,
           count(distinct 거래ID) as F,
           sum(거래금액) as M
    from proj.sales_with_disc
    group by 고객ID;
quit;

/* -------------------------------------------------------------
   2. P(제품가치) 계산
   2-1. 카테고리별 (구매횟수 x 평균단가) 순위 1~20점 부여
------------------------------------------------------------- */
proc sql;
    create table work.cat_stats as
    select 제품카테고리, count(*) as cnt, sum(평균금액)/count(*) as avgprice
    from proj.sales_with_disc
    group by 제품카테고리;
quit;

data work.cat_stats;
    set work.cat_stats;
    value = cnt * avgprice;
run;

proc sort data=work.cat_stats;
    by value;
run;

data work.cat_value;
    set work.cat_stats;
    구매가치 = _N_;
    keep 제품카테고리 구매가치;
run;

proc print data=work.cat_value;
    title "2-1. 카테고리별 구매가치(1~20점) - 낮은 것부터 1점";
run;
title;

/* 2-2. 고객별 카테고리 구매횟수 x 구매가치 합산 = P */
proc sql;
    create table work.cust_cat_count as
    select 고객ID, 제품카테고리, count(*) as 구매횟수
    from proj.sales_with_disc
    group by 고객ID, 제품카테고리;
quit;

proc sql;
    create table work.cust_p as
    select a.고객ID, sum(a.구매횟수 * b.구매가치) as P
    from work.cust_cat_count as a
    inner join work.cat_value as b on a.제품카테고리 = b.제품카테고리
    group by a.고객ID;
quit;

proc sql;
    create table work.rfmp as
    select a.*, b.P
    from work.rfm_base as a
    inner join work.cust_p as b on a.고객ID = b.고객ID;
quit;

proc means data=work.rfmp n mean std min p50 max;
    var R F M P;
    title "2-2. R/F/M/P 기술통계 - 계산 버그 조기 발견 목적";
run;
title;


/* -------------------------------------------------------------
   3. R/F/M/P 각각 표준화 -> K-means -> 군집별 변동계수(CV) -> 가중치
   (Elbow Method로 결정한 군집수: R=3, F=4, M=2, P=4)
------------------------------------------------------------- */
%macro rfmp_weight(var=, k=);

    proc sql;
        create table work.tmp_&var as
        select 고객ID, &var from work.rfmp;
    quit;

    proc standard data=work.tmp_&var out=work.std_&var mean=0 std=1;
        var &var;
    run;

    proc fastclus data=work.std_&var out=work.assign_&var
                  maxclusters=&k maxiter=50 noprint;
        var &var;
    run;

    proc sql;
        create table work.cvdata_&var as
        select a.고객ID, a.CLUSTER, b.&var as origval
        from work.assign_&var as a
        inner join work.rfmp as b on a.고객ID = b.고객ID;
    quit;

    proc means data=work.cvdata_&var noprint;
        class CLUSTER;
        var origval;
        output out=work.cvstat_&var(where=(_type_=1)) mean=m std=s;
    run;

    data work.cvstat_&var;
        set work.cvstat_&var;
        cv = s / m;
    run;

    proc sql noprint;
        select min(cv) into :mincv_&var from work.cvstat_&var;
        select sum(cv) into :sumcv_&var from work.cvstat_&var;
    quit;

    %global w_&var;
    %let w_&var = %sysevalf(&&mincv_&var / &&sumcv_&var);
    %put NOTE: [RFM-P 가중치] &var 원시가중치(w) = &&w_&var (군집수=&k);

%mend rfmp_weight;

%rfmp_weight(var=R, k=3);
%rfmp_weight(var=F, k=4);
%rfmp_weight(var=M, k=2);
%rfmp_weight(var=P, k=4);

%let wsum = %sysevalf(&w_R + &w_F + &w_M + &w_P);
%let W_R = %sysevalf(&w_R / &wsum);
%let W_F = %sysevalf(&w_F / &wsum);
%let W_M = %sysevalf(&w_M / &wsum);
%let W_P = %sysevalf(&w_P / &wsum);

%put NOTE: [RFM-P 최종가중치] W_R=&W_R W_F=&W_F W_M=&W_M W_P=&W_P;

data proj.rfmp_weights;
    length 변수 $10;
    변수 = "R"; 원시가중치 = &w_R; 최종가중치 = &W_R; output;
    변수 = "F"; 원시가중치 = &w_F; 최종가중치 = &W_F; output;
    변수 = "M"; 원시가중치 = &w_M; 최종가중치 = &W_M; output;
    변수 = "P"; 원시가중치 = &w_P; 최종가중치 = &W_P; output;
run;

proc print data=proj.rfmp_weights noobs;
    title "3-1. R/F/M/P 최종 가중치 - 값이 클수록 그 지표의 군집화가 더 일관적(CV 작음)";
run;
title;


/* -------------------------------------------------------------
   4. RFMP_SCORE 계산 + 6등급 부여
------------------------------------------------------------- */
data proj.customer_rfmp;
    set work.rfmp;
    RFMP_SCORE = R * &W_R + F * &W_F + M * &W_M + P * &W_P;
run;

proc rank data=proj.customer_rfmp groups=6 out=proj.customer_rfmp descending;
    var RFMP_SCORE;
    ranks 등급순위;
run;

data proj.customer_rfmp;
    set proj.customer_rfmp;
    등급 = 등급순위 + 1;
    length 등급명 $10;
    select (등급);
        when (1) 등급명 = "VIP";
        when (2) 등급명 = "Diamond";
        when (3) 등급명 = "Platinum";
        when (4) 등급명 = "Gold";
        when (5) 등급명 = "Silver";
        when (6) 등급명 = "Bronze";
        otherwise 등급명 = "미분류";
    end;
    drop 등급순위;
run;

proc freq data=proj.customer_rfmp;
    tables 등급명;
    title "4-1. RFM-P 등급별 고객 분포";
run;
title;

proc means data=proj.customer_rfmp mean min max;
    class 등급명;
    var RFMP_SCORE;
    title "4-2. 등급별 RFMP_SCORE 범위";
run;
title;


/* -------------------------------------------------------------
   5. 등급별 대표카테고리
   [주의] 단순히 "등급 안에서 제일 많이 팔린 카테고리"로 뽑으면
   Apparel처럼 원래 전체 1위인 카테고리가 모든 등급에서 항상
   1등으로 나와서 등급 구분에 아무 의미가 없어짐. 그래서 "전체
   평균 대비 이 등급에서 상대적으로 더 쏠린 정도(lift)"로 계산함:
   lift = (그 등급 안에서 이 카테고리 비중) / (전체 고객 기준 이
   카테고리 비중). lift가 1보다 크면 이 등급이 그 카테고리를
   평균보다 더 많이 사는 것.
------------------------------------------------------------- */
proc sql;
    create table work.overall_cat as
    select 제품카테고리, count(*) as 전체건수
    from proj.sales_with_disc
    group by 제품카테고리;
quit;

proc sql noprint;
    select count(*) into :overall_total from proj.sales_with_disc;
quit;

proc sql;
    create table work.tier_cat_agg as
    select b.등급명, a.제품카테고리, count(*) as 등급건수
    from proj.sales_with_disc as a
    inner join proj.customer_rfmp as b on a.고객ID = b.고객ID
    group by b.등급명, a.제품카테고리;
quit;

proc sql;
    create table work.tier_total as
    select 등급명, sum(등급건수) as 등급전체건수
    from work.tier_cat_agg
    group by 등급명;
quit;

/* 표본이 너무 작은 카테고리는 lift가 우연히 크게 튈 수 있어서
   등급건수 5 미만은 제외 */
proc sql;
    create table work.tier_cat_lift as
    select a.등급명, a.제품카테고리, a.등급건수,
           (a.등급건수 / b.등급전체건수) as 등급내비중,
           (c.전체건수 / &overall_total) as 전체비중,
           calculated 등급내비중 / calculated 전체비중 as lift format=6.2
    from work.tier_cat_agg as a
    inner join work.tier_total as b on a.등급명 = b.등급명
    inner join work.overall_cat as c on a.제품카테고리 = c.제품카테고리
    where a.등급건수 >= 5
    order by a.등급명, calculated lift desc;
quit;

data proj.rfmp_tier_top_category;
    set work.tier_cat_lift;
    by 등급명;
    if first.등급명;
    keep 등급명 제품카테고리 등급건수 lift;
run;

proc print data=proj.rfmp_tier_top_category noobs;
    title "5-1. 등급별 대표카테고리";
run;
title;
