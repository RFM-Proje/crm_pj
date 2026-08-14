libname shop "/home/student/shop_db";

/* 4 케이스별 검정 매칭 */
/* ① 남 vs 여 평균 매출 → 2-Sample t */
PROC TTEST DATA=shop.users ALPHA=0.05;
	WHERE gender IN ('M','F');
	CLASS gender;
	VAR total_spent;
run;

/* 1남녀 */
Data work.users_demo;
	set shop.users(KEEP=user_id total_spent);
	where total_spent is not null
	and total_spent >0; /*구매 회원만 */
	before_spent = total_spent * 0.6;
	after_spent = total_spent * 0.4 + RAND('NORMAL', 5000, 2000);
 run;

/* ONE WAY ANOVA*/
PROC GLM DATA=SHOP.users;
	where vip_grade IS not null;
	class vip_grade;
	model total_spent = vip_grade;
run;
quit;

/* 비모수  2 그룹 -> wilcoxon*/
proc npar1way data=shop.users wilcoxon;
	class channel; var total_spent;
run;
RUN;

/* ② 프로모션 전·후 → Paired t */

PROC TTEST data=users_demo;
	paired after_spent*before_spent;
run;




/* ③ 3 등급 평균 → One-way ANOVA */
PROC GLM DATA=shop.users;
CLASS vip_grade; MODEL total_spent=vip_grade;
RUN; QUIT;
/* ④ 비모수 2 그룹 → Wilcoxon */
PROC NPAR1WAY DATA=shop.users WILCOXON;
CLASS channel; VAR total_spent;
RUN;


/*session 2: 2 sample t-test */
proc ttest data=shop.users
	alpha =0.05;
	where channel in ('organic', 'paid_search');
	class channel;				/*그룹 변수*/
	var age;					/* 비교 변수*/
Run;
quit;
/*(m1-m2)/std(age) m1 은m1그룹의 평균 m2는 m2그룹의 평균 */
/* 성별 매출 차이 분석*/
/*  1. 데이터 정제 -> user_id, gender, total_amount*/
proc sql;
	create table  work.uo as
	select u.user_id, u.gender, u.vip_grade, u.channel, o.total_amount
	from shop.users as u inner join shop.orders as o  ON u.user_id = o.user_id
	where o.status = 'paid';
quit;

/*	2. 데이터 분포 시각화 */
Proc sgplot data =work.uo;
	where gender in ('m', 'f');
	class gender;
	var total_amount;
RUN;

/*	3. 정규성 검증 -> univeriate normal*/


/*	4. 2-sample t 검정 */
	5. 비모수 검정 -> npay1way wilcoxon*/
PROC NPAR1WAY DATA=WORK.UO wilcoxon;


/* 이론 시연 - Cohen's d 직접 계산 (PROC SQL) */

PROC SQL;
   SELECT
      AVG(CASE WHEN channel='organic'
          THEN age END) AS m1,
      AVG(CASE WHEN channel='paid_search'
          THEN age END) AS m2,
      STD(age)          AS pooled_sd,
      ( AVG(CASE WHEN channel='organic'
          THEN age END)
      - AVG(CASE WHEN channel='paid_search'
          THEN age END) 
)
      / STD(age) AS d
   FROM shop.users
   WHERE channel IN ('organic',
                     'paid_search');
QUIT;

/*  사용자별 6월 7월  매출 집계 7월이 6월보다 매출이 높아서 h0 기각 */
/* session 3 : 같은 그룹에 대해 매출 비교 : ttest paired */
proc sql ;
	create table work.before_after AS
	SELECT USER_ID,
			SUM(case when month(order_date)=1)
				then total_amount else 0 end)
				as jun_amt,
			sum(case when month(order_date)=2)
				then total_amount else 0 end)
				as q2_amt
	from shop.orders
	where status='paid' and year(order_date) = 2025
	group by user_id
	having q1_amt > 0
	and q2_amt > 0;
quit;

/*paired t-test*/
proc ttest data work.before_after;
	paired q1_amt *q2_amt;
run;

/* 비모수 검정*/
proc univeriate data = before_after normal;		
	var q1_amt q2_amt;
run;

proc sql ;
create table work.before_after;
	PAIRED JUN_AMT * JUL_AMT;
ruN;
/*one-way anova + tukey HAD*/

/*H0: 체널별 ltv가 동일하다.*/

/* session 4  Anova 분석 -> 그룹이 3개 이상*/
proc glm Data=work.uo;
		class channel;
		model total_amount = channel;

means channel / tukey
				hovtest=levene
				alpha = 0.05;
Run;
quit;
 
/* 결제 수단별 매출차이 anova 분석 */
/* users + orders 조인 테이블 생성 */
PROC SQL;
create table  work.uo as
	select u.user_id, u.gender, u.vip_grade, u.channel, o.total_amount
	from shop.users as u inner join shop.orders as o  ON u.user_id = o.user_id
	where o.status = 'paid';
QUIT;

TITLE "[S4.2 / slide 36] proc glm* tukey *LEVENE (6체널)";
PROC GLM DATA=WORK.UO plots=none;
	class channel;
	model total_amount = channel;
	means channel /TUKEY HOVTEST=LEVENE;
RUN; QUIT;

/*plots=none이 plot 안 하겠다.*/
/*vip 등급별 평균ㄴ 지출 분석*/

/* ① Box Plot */
PROC SGPLOT DATA=shop.users;
WHERE vip_grade IS NOT NULL;
VBOX total_spent / CATEGORY=vip_grade;
RUN;

/* ② ANOVA + Tukey + Levene */
PROC GLM DATA=shop.users;
WHERE vip_grade IS NOT NULL;
CLASS vip_grade;
MODEL total_spent = vip_grade;
MEANS vip_grade / TUKEY
HOVTEST=LEVENE;
RUN;
QUIT;

/* ⑤ 비모수 대조 */
PROC NPAR1WAY DATA=shop.users
WILCOXON DSCF;
WHERE vip_grade IS NOT NULL;
CLASS vip_grade;
VAR total_spent;
RUN;

/* Vip, Gold, Bronze 등급 사이에 매출 차이가 있는지 분석하자. */
PROC GLM data=shop.users;
	CLASS vip_grade; /*vip_grade*/
	model total_spent = vip_grade;
	means tukey hovtest=levene;
run; quit;

PROC GLM data=shop.users;
	where vip_grade IN ('vip', 'gold', 'bronze');
	class vip_grade;
	model total_spent = vip_grade;
	means tukey hovtest=levene;
run; quit;


/*vip 등급 사후검정 3종 비교*/

/* Tukey */
PROC GLM DATA=shop.users;
WHERE vip_grade IS NOT NULL;
CLASS vip_grade;
MODEL total_spent = vip_grade;
MEANS vip_grade / TUKEY;
RUN;
QUIT;

/* Bonferroni */
PROC GLM DATA=shop.users;
WHERE vip_grade IS NOT NULL;
CLASS vip_grade;
MODEL total_spent = vip_grade;
MEANS vip_grade / BON;
RUN;
QUIT;

/* α 인플레이션 계산 */
DATA work.alpha;
k = 5;
n_pairs = k*(k-1)/2;
alpha = 0.05;
prob_err = 1 - (1-alpha)**n_pairs;
alpha_bon = alpha / n_pairs;
RUN;

/* session 6 : 비모수 검증 -> npar1way / wilcoxn*/
/* ① Wilcoxon Rank-Sum (2 그룹) */
PROC NPAR1WAY DATA=work.uo WILCOXON;
WHERE channel IN ('organic', 'paid_search');
CLASS channel;
VAR total_amount;
RUN;
/* ② Kruskal-Wallis (3+ 그룹) */
PROC NPAR1WAY DATA=work.uo WILCOXON;
CLASS channel; /* 5 채널 */
VAR total_amount;
RUN;
/* ③ DSCF - 사후검정 */
PROC NPAR1WAY DATA=shop.users
WILCOXON DSCF;
WHERE vip_grade IS NOT NULL;
CLASS vip_grade;
VAR total_spent;
RUN;
/* 출력: Chi-Square (Kruskal)
+ Wilcoxon Z + p-value */

