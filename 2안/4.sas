/* =================================================================
   PART 3. 등급별 상위 구매 카테고리 Top5
   [교체] 예전엔 proj.customer_segments의 Cluster_ID(K-means)를
   참조했지만, 이제 stage2_rfmp_segmentation.sas가 만든
   proj.customer_rfmp의 등급명(VIP/Diamond/Platinum/Gold/Silver/
   Bronze)을 사용함. 패널 개수도 8개(예전 군집)에서 6개(등급)로 맞춤
================================================================= */

/* 등급 x 카테고리 별 구매건수 집계 */
proc sql;
    create table proj.cluster_category as
    select b.등급명,
           a.제품카테고리,
           count(distinct a.거래ID) as 구매건수
    from proj.sales_with_disc as a
    inner join proj.customer_rfmp as b
        on a.고객ID = b.고객ID
    group by b.등급명, a.제품카테고리
    order by b.등급명, 구매건수 descending;
quit;

/* 등급 내 순위 부여 후 Top5만 추출 */
data proj.cluster_category_top5;
    set proj.cluster_category;
    by 등급명 descending 구매건수;
    retain 순위;
    if first.등급명 then 순위 = 1;
    else 순위 + 1;
    if 순위 <= 5;
run;

proc print data=proj.cluster_category_top5;
    var 등급명 순위 제품카테고리 구매건수;
    title "등급별 상위 구매 카테고리 Top5";
run;
title;

/* 발표용 시각화 - 등급별 Top5 막대그래프 (6등급 -> 2열 3행) */
proc sgpanel data=proj.cluster_category_top5;
    panelby 등급명 / columns=2 rows=3 novarname;
    hbar 제품카테고리 / response=구매건수 categoryorder=respdesc;
    rowaxis label="";
    colaxis label="구매건수";
    title "등급별 상위 구매 카테고리 Top5";
run;
title;
