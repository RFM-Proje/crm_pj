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
