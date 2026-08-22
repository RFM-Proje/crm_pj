/*=============================================================
  보조분석. 9~12월 평균단가 상승 원인 분해
  - 목적: week4에서 발견된 9~12월 평균단가 계단식 상승이
    (a) 고가 카테고리 판매 비중 증가 때문인지
    (b) 할인율(프로모션) 축소 때문인지 구분
  - 입력: proj.sales_with_disc (2주차 산출물)
  - 전제조건: week1 -> week2_rfm_derived_수정 이 같은 세션에서
    먼저 실행되어 있어야 함
=============================================================*/

libname proj "/home/student/open";

/* -------------------------------------------------------------
   1. 월별 + 카테고리별 매출/할인율/평균단가 집계
------------------------------------------------------------- */
proc sql;
    create table proj.monthly_category_mix as
    select put(거래날짜_num, monname3.) as 월,
           month(거래날짜_num)          as 월번호,
           제품카테고리,
           count(*)                     as 거래건수,
           sum(거래금액)                as 카테고리매출,
           mean(평균금액)               as 카테고리평균단가,
           mean(할인율)                 as 카테고리평균할인율
    from proj.sales_with_disc
    group by 월, 월번호, 제품카테고리
    order by 월번호, 카테고리매출 descending;
quit;


/* -------------------------------------------------------------
   2. 시기 구분: 전반기(1~8월) vs 후반기(9~12월)
   - 후반기가 week4 그래프에서 평균단가 상승이 시작된 구간
------------------------------------------------------------- */
data proj.sales_with_period;
    set proj.sales_with_disc;
    if month(거래날짜_num) <= 8 then 시기 = "1_전반기(1~8월)";
    else 시기 = "2_후반기(9~12월)";
run;


/* -------------------------------------------------------------
   3. (a) 카테고리 믹스가 바뀌었는지 확인
   - 전반기 vs 후반기, 카테고리별 매출 비중(%) 비교
   - 특정 카테고리 비중이 후반기에 커졌다면 "믹스 변화"가 원인
   [수정] SAS PROC SQL은 OVER(PARTITION BY ...) 윈도우 함수를
   지원하지 않음 -> 시기별 총매출을 먼저 별도로 구한 뒤
   서브쿼리로 조인하는 방식으로 변경
------------------------------------------------------------- */
proc sql;
    create table proj.period_total as
    select 시기, sum(거래금액) as 시기총매출
    from proj.sales_with_period
    group by 시기;
quit;

proc sql;
    create table proj.period_category_share as
    select a.시기, a.제품카테고리,
           sum(a.거래금액) as 카테고리매출,
           sum(a.거래금액) / b.시기총매출 * 100 as 매출비중_pct
    from proj.sales_with_period as a
    inner join proj.period_total as b
        on a.시기 = b.시기
    group by a.시기, a.제품카테고리, b.시기총매출
    order by a.시기, 매출비중_pct descending;
quit;

proc print data=proj.period_category_share;
    var 시기 제품카테고리 카테고리매출 매출비중_pct;
    title "3. 전반기 vs 후반기 - 카테고리별 매출 비중 변화";
run;
title;


/* -------------------------------------------------------------
   4. (b) 할인율이 후반기에 줄었는지 확인
   - 전반기 vs 후반기 평균 할인율 비교
------------------------------------------------------------- */
proc sql;
    select 시기,
           mean(할인율) as 평균할인율,
           mean(평균금액) as 평균단가,
           count(*) as 거래건수
    from proj.sales_with_period
    group by 시기;
    title "4. 전반기 vs 후반기 - 평균할인율 및 평균단가 비교";
quit;
title;

/* 월별 추이로 더 세밀하게 - 할인율과 평균단가가 같은 시점에
   반대로 움직이는지(할인율↓ 평균단가↑) 시각적으로 확인 */
proc sql;
    create table proj.monthly_price_discount as
    select month(거래날짜_num) as 월번호,
           put(거래날짜_num, monname3.) as 월,
           mean(할인율) as 평균할인율,
           mean(평균금액) as 평균단가
    from proj.sales_with_disc
    group by 월번호, 월
    order by 월번호;
quit;

proc sgplot data=proj.monthly_price_discount;
    series x=월번호 y=평균단가 / y2axis lineattrs=(color=orange thickness=2) markers legendlabel="평균단가";
    series x=월번호 y=평균할인율 / lineattrs=(color=blue thickness=2) markers legendlabel="평균할인율";
    xaxis label="월" values=(1 to 12) valuesdisplay=("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec");
    yaxis label="평균할인율";
    y2axis label="평균단가";
    title "월별 평균단가 vs 평균할인율 - 반대 방향으로 움직이는지 확인";
run;
title;


/* -------------------------------------------------------------
   5. 결론 판단 기준
   - 3번 결과에서 특정 카테고리(예: 고가 전자기기류) 비중이
     후반기에 뚜렷이 커졌다면 -> "카테고리 믹스 변화"가 주 원인
   - 4번/5번 결과에서 할인율이 후반기에 눈에 띄게 낮아졌다면
     -> "프로모션 축소"가 주 원인
   - 둘 다 나타나면 두 요인이 함께 작용한 것으로 해석
------------------------------------------------------------- */
