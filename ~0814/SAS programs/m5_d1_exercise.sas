libname shop "/home/student/shop_db";
Title "[Slide 5] Population (전체) vs  Sample (10%)";
proc sql;
	select 'population' as type lngth=12, count(*) as n
	from shop.orders
	union all
	select 'Sample 10%', count(*)
	from shop.orders(where = (RANUNI (1) < 0.1 ));
quit;
title;
/*proc contents data*/

title "[Slide 10] 미니 실습 1 - orders 첫 인상 (3 Proc 종합)";
/* 데이터 구조 파악 */
proc contents data=shop.orders;
run;

/* 수치 요약 */
proc means data=shop.orders N mean std min max nmiss maxdec=2;
	var total_amount;
Run;


/*범주 빈도 */
proc freq data=shop.orders;
	tables status payment_method / NOCUM;
run;
title;