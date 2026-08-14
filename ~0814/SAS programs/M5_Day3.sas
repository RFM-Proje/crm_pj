libname shop "/home/student/shop_db";

/* session 1 */
/*(1)  독립성 - 성별x체널 */
/*H0: 성별과 체널간의 관계가 없다.  p-value가 0보다 작으니까 가설을 채택할 수 있다.*/
/*크레머를 보면 효과는 굉장히 미미하다.*/
proc freq data=shop.users;
	tables gender*channel / CHISQ;
Run;

/* H0: 결제수단이 균등하다. */
/* (2) 적합도 - 결제수단 균등 */
PROC FREQ DATA =SHOP=USERS;
/* (3) 동질성 - vip등급x체널 */
PROC FREQ DATA =SHOP=USERS;
	Table vip_grade*channel / CHISQ;
RUN;
/*(4) fisher - 소표본 시연*/
data work.trial_demo
	input drug $ effect $count;
	DATALINES;
A successn 8
A failure 2
B success 3
B failure 12
;
Run;

Title "[S1.3-(4)] fisher - 소표본 임상";
proc freq data=work.trial_demo order=data;
	weight count;
tables drug*effect /CHISQ FISHER EXPECTED;
RUN;
TITLE;
/*FISHER는 카이제곱 보는 게 아니고 양쪽 P값 보는 거다.*/

/*SESSION 2*/
/* proc freq chisq - 독립성 */
/*성별과 체널간에 관련성이 있는가-있긴 있지만 효과는 미미 */
PROC FREQ DATA=shop.users;
	tables gender * channel /
	chisq
	EXPECTED
	NOPRINT
	PLOTS=NOSAIC;
RUN;

DATA work.ad_purchase;
	input ad_view $ purchase $count;
Yes Buy		60
Yes Nobuy	40
No	Buy		40
No	NoBuy	60
;Run;

proc freq data=ad_purchase ORDER=DATA;
	WEIGHT COUNT;
	tables ad_view * purchase /
	chisq
	expected
	NOPERCENT NOCOL NOROW
	plots=mosaic;
Run;
/*광고와 구매 간에 효과가 없다고 할 수 없다.*/

/*MISSION 성별 x 결제수단 관련 둘 간의 관계*/
/* 실습 독립성 검정 */
/* 성별과 결제수단과의 관계를 검정 */
/* 1단계: 데이터셋 생성*/
proc SQL;
	CREATE TABLE user_orders as
	select gender, payment_method
	FROM SHOP.USERS U inner join shop.orders o on u.user_id = o.user_id
	where o.status = 'paid'
	and u.gender in ('F','M');
quit;

/* 2단계 : 두변수간의 독립성 검정 */
PROC FREQ DATA=user_orders;
	tables gender * payment_method /
		CHISQ EXPECTED NOPERCENT NOROW NOCOL PLOTS=MOSAIC;
RUN;
/* signup 체널이 아니라 내가 실제로 주문한 체널과 고객 등급과의 관계 */
/* 고객 등급이 있고 결제를 한 건만 하면 된다 */
/*고객등급별 주문한 채널과의 관계를 검정*/
/*1단계 : 데이터셋 생성*/
PROC SQL;
	CREATE TABLE user_orders as
	SELECT u.vip_grade, o.channel
	from shop.users u inner join shop.orders o on u.user_id = o.user_id
	where o.status = 'paid'
	and u.vip_grade is not null;
quit;
/* 2단계: 두 변수간의 독립성 검정*/
proc freq data=user_orders;
	tables vip_grade * channel /
		chisq expected nopercent norow nocol plots=mosaic;

RUN;

/*데이터셋 생성 */
Proc sql;
	create table work.camp-agg AS
	select channel,
			sum(clicks)		AS clicks,
			sum(conversions) as conversions
	from shop.campaigns
	group by channel
quit;

DATA work.camp_agg;
	converted='Y'; count=conversions;		OUTPUT;
	converted='N'; count=clicks-conversions; output;
	Keep channel converted count;
Run;

Title "[S2.6] 비즈니스 실습 2 - 광고 체널 X 구매전환 독립성 (광고 ROI)";
TITLE2 "work.camp_conv (shop.campaigns 실측 집계) - channel x converted";

Proc freq data=work.camp_conv ORDER=data;
	weight count;
	tables channel * converted /
	CHISQ NOPERCENT NOCOL
	EXPECTED CELLCHI2
	MEASURES PLOTS==MOSAIC;
RUN;

data work.small_data;
   input treatment $ outcome $ count;
   datalines;
A success 8
A failure 2
B success 3
B failure 12
;run;
/* proc freq fisher*/
proc freq data=work.small_data;
   tables treatment * outcome/
chisq fisher expected;
run;

proc freq data=work.small_data
   order=data;
weight count;
tables treatment * outcome/
chisq fisher expected
;run;

PROC FREQ DATA=work.small_data
ORDER=DATA;
WEIGHT count;
TABLES treatment * outcome /
CHISQ FISHER EXPECTED;
RUN;

/*신약, 위약*/
data work.drug_trial;
   input drug $ effect $ count;
   datalines;
new success 9
new failure 3
placebo success 4
placebo failure 9
;run;

proc freq data=work.drug_trial order=data;
   weight count;
   tables drug * effect / chisq fisher expected;
run;
/* 약 효과가있다*/


TITLE "[S3.1] fisher's exact - 소표본 (n=25) 진단";
PROC FREQ DATA=drug_trial order=data;
	weight count;
 table drug * effect /
		chisq fisher
		expected cellchi2;
Run;
title;
/*
Data work.ab_test
	input design $ click $ count;
	data
*/

data work.ab_test;
   input design $ click $ count;
   datalines;
A click 7
A nclick 13
B click 14
B nclick 6
;
run;

title'[s3.4]비즈니스 실습 3 - A|B테스트 결제 버튼 (n=40)';
title2 "기대빈도 < 5 >> Fisher's Exact 권장";
proc freq data= work.ab_test order=data;
   weight count;
   tables design*click/ chisq expected fisher measures;
run;
title;title2;
/*기대값보다 크면 좋음 */

/*session 4 : ODDS Ratio*/
Data work.smoke_cancer order=data;
	weight count;
	tables smoking  * cancer /
			CHISQ MEASURES RELRISK
			EXPECTED;
RUN;
TITLE;

/* 모바일 앱 사용자와 이탈과의 관계--> OR */
PROC CONTENTS DATA=shop.users;
run;

/* device의 종류 확인 */
PROC SQL;
	SELECT DISTINCT SIGNUP_DEVICE from shop.users;
quit;

/* mobile, PC, tablet */

/* 검정할 데이터셋 생성-> users2*/
data user2;
	set shop.users;
	if signup_device = 'mobile' then app_user = 'Y';
	else app_user = 'N';
run;

proc contents data=users2;
run;

/* users의 app_user(mobile app 사용자)	와 churn (이탈율) 관계 검정 ->odd*/
proc freq data=users2;
	tables app_user * churn /
		chisq measures relisk expected;
run;
	/*input smoking $ cancer $ count*/

/* 마케팅  수신 여부와 재구매 관계 */
/* marketing_consent -> 1 이면 push_exposedn <- 'Y'아니면 'N'
	repurchase <- odres_count가 1보다 크면 'Y'를 아니면 'N'*/

data push_user;
	set shop.users;
	
	if marketing_consent = 1 then push_exposed = 'Y';
	else repurchase = 'N';
run;

proc freq data=push_users;
	tables push_exposed * repurchase /
		chisq measures relrisk expected;
run;		
