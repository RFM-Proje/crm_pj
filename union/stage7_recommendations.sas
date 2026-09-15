/*=============================================================
  STAGE 7. 추천 시스템 - DACON 코드공유에 있었지만 기존 파이프라인
  (stage1~6)에는 없었던 3가지를 추가함
    A) 인기제품 식별 - 카테고리별로 소수 제품이 판매를 독점하는지 확인
    B) 크로스셀링 추천 - 핵심고객 세그먼트 대상, 카테고리 확장 추천
    C) 세그먼트별 묶음상품(Bundle) 추천 - 구매 상위 25% 고객 장바구니 분석

  [설계 메모] DACON처럼 27개 컬럼짜리 메가테이블을 새로 만들지 않고,
  이미 있는 sales_with_disc / customer_final_tier / churn_split_v2를
  그때그때 join해서 이 분석 전용 임시(work) 테이블만 만들고, 최종
  결과만 proj.에 영구 저장함.

  전제조건: STAGE 1~6 실행 완료
  (proj.sales_with_disc, proj.customer_final_tier, proj.churn_split_v2 필요)

  산출물: proj.product_popularity, proj.category_top_products,
          proj.customer_category_targets(핵심고객 크로스셀링 추천),
          proj.bundle_recommendations(세그먼트별 묶음상품)
=============================================================*/

libname proj "/home/student/open";

/* ============================= PART A. 인기제품 식별 ============================= */
/*=============================================================
  카테고리 안에서 소수 제품ID가 판매를 독점하는지 확인.
  DACON 1-2-2)와 동일한 목적 - "이 카테고리는 대표 제품 몇 개만
  밀어주면 되는지, 아니면 여러 제품이 골고루 팔리는지" 판단용
=============================================================*/

proc sql;
    create table proj.product_popularity as
    select 제품카테고리, 제품ID,
           sum(수량) as 총판매수량,
           sum(거래금액) as 총판매금액,
           count(distinct 거래ID) as 거래건수
    from proj.sales_with_disc
    group by 제품카테고리, 제품ID
    order by 제품카테고리, calculated 총판매금액 desc;
quit;

/* 카테고리별 전체 금액 대비, 상위 3개 제품이 차지하는 비중(집중도) */
proc sql;
    create table work.category_total as
    select 제품카테고리, sum(총판매금액) as 카테고리전체금액
    from proj.product_popularity
    group by 제품카테고리;
quit;

data work.product_ranked;
    set proj.product_popularity;
    by 제품카테고리;
    if first.제품카테고리 then 순위 = 0;
    순위 + 1;
run;

proc sql;
    create table proj.category_top_products as
    select a.제품카테고리, a.제품ID, a.순위, a.총판매금액,
           b.카테고리전체금액,
           sum(a.총판매금액) as 상위N누적금액
    from work.product_ranked as a
    inner join work.category_total as b on a.제품카테고리 = b.제품카테고리
    where a.순위 <= 3
    group by a.제품카테고리, a.제품ID, a.순위, a.총판매금액, b.카테고리전체금액;
quit;

proc sql;
    create table proj.category_concentration as
    select 제품카테고리,
           max(카테고리전체금액) as 카테고리전체금액,
           max(상위N누적금액) as 상위3개누적금액,
           calculated 상위3개누적금액 / calculated 카테고리전체금액 as 상위3개집중도 format=percent8.1
    from proj.category_top_products
    group by 제품카테고리
    order by calculated 상위3개집중도 desc;
quit;

proc print data=proj.category_concentration noobs;
    title "A-1. 카테고리별 상위 3개 제품 판매 집중도 - 50% 넘으면 소수 제품이 독점";
run;
title;

proc sgplot data=proj.category_concentration;
    hbar 제품카테고리 / response=상위3개집중도 categoryorder=respdesc;
    refline 0.5 / axis=x lineattrs=(color=red pattern=dash) label="50% 기준";
    title "A-2. 카테고리별 상위3개 제품 집중도";
run;
title;


/* ============================= PART B. 크로스셀링 추천 (핵심고객) ============================= */
/*=============================================================
  DACON 4-2와 동일한 로직을 "고객별 반복문" 대신 "카테고리수(n)
  구간별 1회 계산 + 매칭"으로 재구성해서 SAS에 맞게 효율화함.

  1) 고객별 구매 카테고리 수(n), 카테고리 목록 확보
  2) n이 짝수면 목표 k=n+2, 홀수면 k=n+1 (DACON과 동일)
  3) k값별로: "카테고리 수가 k~k+1인 고객들"이 실제 많이 사는
     카테고리 top-k를 target_list로 미리 계산해둠 (고객마다 반복
     계산할 필요 없이, 존재하는 k값 개수만큼만 계산)
  4) 각 고객은 자신의 k에 해당하는 target_list와 비교해서,
     안 사본 카테고리를 추천
  대상: 핵심고객 세그먼트만 (DACON의 VIP/Diamond에 해당)
=============================================================*/

proc sql;
    create table work.core_customers as
    select 고객ID from proj.customer_final_tier where 군집라벨 = "핵심고객";
quit;

proc sql;
    create table work.core_txn as
    select a.고객ID, a.제품카테고리
    from proj.sales_with_disc as a
    inner join work.core_customers as b on a.고객ID = b.고객ID
    group by a.고객ID, a.제품카테고리;
quit;

proc sql;
    create table work.customer_cat_count as
    select 고객ID, count(distinct 제품카테고리) as n
    from work.core_txn
    group by 고객ID;
quit;

data work.customer_cat_count;
    set work.customer_cat_count;
    if mod(n, 2) = 0 then k = n + 2;
    else k = n + 1;
run;

proc sql noprint;
    select distinct k into :klist separated by ' ' from work.customer_cat_count;
    select count(distinct k) into :knum from work.customer_cat_count;
quit;

%put NOTE: [크로스셀링] 존재하는 목표(k)값 목록 = &klist (총 &knum 개) - 고객 수가 아니라 이 개수만큼만 계산함;

/* k값별로 target_list(그 k 구간대 고객들이 많이 사는 카테고리 top-k) 생성 */
%macro build_target(k=);
    proc sql;
        create table work.kgrp_&k as
        select 고객ID from work.customer_cat_count where n >= &k and n <= &k + 1;
    quit;

    proc sql noprint;
        select count(*) into :nkgrp from work.kgrp_&k;
    quit;

    %if &nkgrp > 0 %then %do;
        proc sql;
            create table work.kcat_&k as
            select 제품카테고리, count(*) as cnt
            from work.core_txn
            where 고객ID in (select 고객ID from work.kgrp_&k)
            group by 제품카테고리
            order by cnt desc;
        quit;

        data work.ktarget_&k;
            set work.kcat_&k(obs=&k);
            k = &k;
            keep k 제품카테고리;
        run;

        proc append base=work.all_targets data=work.ktarget_&k force;
        run;
    %end;
%mend build_target;

proc datasets library=work nolist;
    delete all_targets;
quit;
data work.all_targets;
    length k 8 제품카테고리 $20;
    stop;
run;

%macro run_all_targets;
    %local i thisk;
    %let i = 1;
    %do %while (%scan(&klist, &i, %str( )) ne );
        %let thisk = %scan(&klist, &i, %str( ));
        %build_target(k=&thisk);
        %let i = %eval(&i + 1);
    %end;
%mend run_all_targets;

%run_all_targets;

/* 고객별 카테고리 세트 vs target_list 차집합 = 추천 카테고리 */
proc sql;
    create table proj.customer_category_targets as
    select a.고객ID, a.n as 보유카테고리수, a.k as 목표카테고리수,
           b.제품카테고리 as 추천카테고리
    from work.customer_cat_count as a
    inner join work.all_targets as b on a.k = b.k
    where b.제품카테고리 not in
          (select 제품카테고리 from work.core_txn where 고객ID = a.고객ID)
    order by a.고객ID;
quit;

proc print data=proj.customer_category_targets(obs=20) noobs;
    title "B-1. 핵심고객 크로스셀링 추천 (일부 20건 미리보기)";
run;
title;

proc sql;
    title "B-2. 핵심고객 중 추천 카테고리가 1개 이상 있는 고객 수";
    select count(distinct 고객ID) as 추천대상고객수
    from proj.customer_category_targets;
quit;
title;


/* ============================= PART C. 세그먼트별 묶음상품(Bundle) 추천 ============================= */
/*=============================================================
  DACON 3-2와 동일한 목적 - 세그먼트별 구매횟수 상위 25% 고객의
  장바구니(같은 거래 안에 같이 담긴 제품ID)를 분석해서 2개짜리
  묶음상품 후보를 뽑음. STAGE 3의 PAIR_COUNT/ASSOC_RULES_MANUAL과
  동일한 수동 co-occurrence 방식을 세그먼트 단위로 재사용함.
=============================================================*/

%macro bundle_recommend(seg=, topn=10);

    proc sql;
        create table work.seg_freq as
        select b.고객ID, c.Frequency
        from proj.customer_final_tier as b
        inner join proj.churn_split_v2 as c on b.고객ID = c.고객ID
        where b.군집라벨 = "&seg";
    quit;

    proc means data=work.seg_freq noprint;
        var Frequency;
        output out=work.seg_p75(drop=_type_ _freq_) p75=p75;
    run;

    proc sql noprint;
        select p75 into :p75val from work.seg_p75;
    quit;

    proc sql;
        create table work.seg_top25 as
        select 고객ID from work.seg_freq where Frequency > &p75val;
    quit;

    proc sql;
        create table work.seg_txn as
        select a.고객ID, a.거래ID, a.제품ID
        from proj.sales_with_disc as a
        where a.고객ID in (select 고객ID from work.seg_top25);
    quit;

    /* 거래(고객ID+거래ID) 단위로 유니크한 거래번호 부여 후, 같은
       거래 안의 제품ID 쌍(A<B로 정렬해서 중복 방지)을 co-occurrence로 셈 */
    proc sort data=work.seg_txn out=work.seg_txn_sorted nodupkey;
        by 고객ID 거래ID 제품ID;
    run;

    proc sql;
        create table work.seg_pairs as
        select a.고객ID, a.거래ID, a.제품ID as 제품A, b.제품ID as 제품B
        from work.seg_txn_sorted as a
        inner join work.seg_txn_sorted as b
          on a.고객ID = b.고객ID and a.거래ID = b.거래ID and a.제품ID < b.제품ID;
    quit;

    proc sql;
        create table work.seg_pair_count as
        select 제품A, 제품B, count(*) as 동시구매건수
        from work.seg_pairs
        group by 제품A, 제품B
        order by calculated 동시구매건수 desc;
    quit;

    data work.seg_bundle_top;
        length 군집라벨 $15;
        set work.seg_pair_count(obs=&topn);
        군집라벨 = "&seg";
    run;

    proc append base=proj.bundle_recommendations data=work.seg_bundle_top force;
    run;

%mend bundle_recommend;

proc datasets library=proj nolist;
    delete bundle_recommendations;
quit;
data proj.bundle_recommendations;
    length 군집라벨 $15 제품A $12 제품B $12 동시구매건수 8;
    stop;
run;

%bundle_recommend(seg=핵심고객);
%bundle_recommend(seg=이탈위험군);
%bundle_recommend(seg=쿠폰의존);
%bundle_recommend(seg=배송이슈);
%bundle_recommend(seg=저관여);
%bundle_recommend(seg=일반고객);

proc print data=proj.bundle_recommendations noobs;
    title "C-1. 세그먼트별 묶음상품(Bundle) 추천 - 동시구매 상위 10쌍";
    by 군집라벨 notsorted;
run;
title;
