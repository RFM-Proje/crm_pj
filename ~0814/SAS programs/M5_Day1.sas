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

/*표준 편차가 크기 때문에 왜도/첨도 확인도 해야 하니 univariate로 검증 필요*/
proc univariate data=shop.orders normal;
	var total_amount;
	histogram total_amount / normal;
Run;

/* proc means – 기술통계 풀세트 */
/* 전체*/
proc means data= shop.orders
	N nmiss mean std min max  median q1 q3 maxdec=2;
	var total_amount;
run;

/*그룹별 집계  - class*/
	proc means data=shop.orders
		N mean std median maxdec=2;
	CLASS PAYMENT_method;
	var total_amount;
RUN;

/*출력 저장 - output*/
proc means data=shop.orders noprint;
	class payment_method;
	var total_amount;
	output out=summary
	n=n	nmiss=nmiss	mean=avg STD=std
	min=min max=max median=median q1=q1;
Run;

Proc print DATA=SUMMARY NOOBS;
RUN;
/*nmiss는 없으면 굳이 보고서에서는 출력 안 해도 된다.*/

/*sas가 통계에서 탁월 기술통계는 Proc means에서 사용 가능 */

/*proc means data=shop.orders */

/* 기술통계 시각화 5. 지표 한눈에 */
/* 평균/ 중앙값/ 최빈값 histogram*/
proc sgplot data=shop.users;
	histogram total_spent /  transparency=0.4;
	Refine 78500 / axis=x label = '평균'

proc sgplot data=shop.users;
	DENSITY total_spent / TYPE=KENNEL
			LEGENDLABEL='실제 분포';
DENSITY TOTAL_SPENT / TYPE=NORMAL;
/* 체널별 매출 분석 - 기술통계 */
/* 1단계 : users와 orders inner join -> uo 데이터셋 생성*/	
proc sql;
	create table work.uo AS
	select u. channel, u.gender, o.total_amount
	from shop.users u
	inner join shop.orders o
		on u.user_id = o.user_id
		where o.status = 'paid';
	quit;
/* 2단계 : 생성된 uo 데이터셋 기술통계 확인*/
proc means DATA=work.uo
	N MEANS
/* 3단계 ; 시각 비교 */
/* histogram과 hbox 겹쳐 그리기 */
proc univeriate data=work.uo;
	var total_amount;
Run;

TITLE "[Slide 23] step";
PROC CONTENTS


	histogram total_amount / transparency=0.4;

			legendlabel='정규분포 비교';
Run;

/* session 2  실습 2 체널별 매출 EDA */
/* (1)*/

/* session 3: 정규성 검증 */
title "[slide 30] proc univeriate - 정규성 + 시각화";

PROC UNIVERIATE DATA=shop.users normal
				clbasic plots;
	var age;
	histogram age / Normal;
	qqplot age / normal(MU=EST, sigma=EST);
RUN;
title;

title "[slide 32] STEP 3 -proc univeriate normal + Q-Q
