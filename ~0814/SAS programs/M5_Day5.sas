LIBNAME shop "/home/student/shop_db";

%let csvdir=/home/student/shop_csv;

/* csv to sas macro*/
%macro imp(name=);
   proc import datafile="&csvdir/&name..csv"
   out=shop.&name
   dbms=csv replace;
   getnames=yes;
   guessingrows=max;
run;
%put note:=====&name..csv -> shop_db.&name 변환완료=====;
%mend;

%imp(name=users);

proc contents data = shop.users;
RUN;
/*★실측 결과 요약 (8 시나리오)
	(1) 남녀 매출 t-test
	(2) pre/post_promo_spent paired
	(3) vip_grade ANOVA
	(4) 체널x등급 (카이스퀘어 제곱)
	(5) budget-revenue Pearson
	(6) churn Logistic
	(7) gender x churn Fisher
	(8) 남녀 매출 wilcoxon
*/

/*1. 남녀 매출은 같다. -> 2-sample ttest : p-value cohen's d */
Title "2 Sample t-test : 남녀 매출 ";
proc ttest DATA=shop.users;
	class gender;
	var total_spent;
	where gender in ('F' ,'M');
RUN;

/* 2. PRE/post_promo_spent_paired 매출 : ttest -> paired */
title "paired t-test :PROMOTION  전후 매출";

PROC TTEST DATA=shop.users;
	paired post_promo_spent * pre_promo_spent;
RUN;
  
/*3. vip_grade별 매출 :ANOVA ->glm */
title "one-way Anova : VIP 등급별 매출 ";
proc glm data=shop.users;
	class vip_grade;
	model total_spent = vip_grade;
RUN;
title;

/* 4. : 체널 * 등급 -> 카이제곱 검정, 빈도 변수 :FREQ */

TITLE "채널과 등급 간의 차이";
proc freq data=shop.users;
	tables channel * vip_grade / chisq;
Run;
title;

DATA work.ads;
   SET shop.campaigns;
   IF clicks      > 0 THEN cpc = budget / clicks;         ELSE cpc = .;
   IF conversions > 0 THEN cpa = budget / conversions;    ELSE cpa = .;
   IF budget      > 0 THEN roi = (revenue - budget) / budget; ELSE roi = .;
   month = MONTH(start_date);
   IF      month IN (3,4,5)  THEN season = 1;   /* 봄 */
   ELSE IF month IN (6,7,8)  THEN season = 2;   /* 여름 */
   ELSE IF month IN (9,10,11) THEN season = 3;  /* 가을 */
   ELSE                            season = 4;  /* 겨울 */
   LABEL cpc    = '클릭당비용(CPC)'
         cpa    = '전환당비용(CPA)'
         roi    = '광고ROI'
         season = '시즌(1봄 2여름 3가을 4겨울)';
RUN;


/* 5. : 광고비와 매출 간의 상관관계 */
TITLE "Pearson r -> 광고비 매출 ";
proc corr data=shop.users;
	var budget revenue;
RUN;

/* 5-1 전환과 매출 간의 상관관계*/
TITLE "PEARSON R -> 전환 매출";
proc corr data=shop.users;
	var CONVERSIONS revenue;
RUN;

/* 이탈 예측 -> logistic 이진 분류 */
PROC LOGISTIC DATA=SHOP.USERS;
	CLASS gender (PARAM = ref ref='M');
	model churn(event='1') = age total_spent gender;
RUN;

/* 소표본 분할 -> gender, churn -> FISHER*/
PROC FREQ DATA=shop.users;
	tables gender * churn / Fisher;
	where gender in ('M','F');
Run;
/* 8. 비정규 그룹 -> npar1way */
PROC NPAR1WAY DATA = SHOP.users WILCOXON;
	CLASS GENDER;
	var total_spent;
	WHERE gender in ('F','M');
Run;

TITLE "2-SAMPLE t-test : 남녀 매출 ";
PROC  TTEST DATA=SHOP.USERS;
	CLASS gender;
	var total_spent;
	WHERE gender in ('F','M');
Run;
