LIBNAME shop "/home/student/shop_db";
/* ── [사전 준비] 강의용 분석 뷰 3 개 생성 (모든 세션 재사용) ──────── */

/* (A) work.ads : shop.campaigns 확장 
        · budget · revenue · impressions · clicks · conversions (원본)
        · cpc / cpa / roi / month / season (파생)                       */
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

/* (B) work.uo_sum : shop.users + shop.orders JOIN (Session 2~6 재사용)
       · tenure_days       = TODAY - signup_date (원 강의 tenure 대체)
       · marketing_consent = 0/1 (원 강의 app_user 대체)                 */
PROC SQL;
   CREATE TABLE work.uo_sum AS
   SELECT u.user_id,
          u.age,
          u.gender,
          u.city,
          u.channel,
          u.vip_grade,
          u.marketing_consent                                LABEL='마케팅수신동의',
          u.total_spent,
          u.order_count                                      LABEL='총주문건',
          u.churn,
          INTCK('DAY', u.signup_date, TODAY())    AS tenure_days
                                                             LABEL='가입경과일',
          COUNT(o.order_id)                        AS n_orders
                                                             LABEL='결제주문수',
          SUM(o.total_amount)                      AS spent
                                                             LABEL='실결제총액',
          MEAN(o.total_amount)                     AS avg_price
                                                             LABEL='평균결제액',
          CASE WHEN u.total_spent >= 1500000 THEN 1 ELSE 0 END
                                                    AS is_vip
                                                             LABEL='VIP여부'
   FROM shop.users  AS u
   INNER JOIN shop.orders AS o
           ON u.user_id = o.user_id
   WHERE o.status = 'paid'
   GROUP BY u.user_id, u.age, u.gender, u.city, u.channel, u.vip_grade,
            u.marketing_consent, u.total_spent, u.order_count, u.churn,
            u.signup_date;
QUIT;

/* (C) work.prod_sales : shop.products + shop.order_items JOIN
       · products.monthly_sales 가 없으므로 order_items 실판매수량 집계
       · sold_qty      = 총 판매 수량 (모든 주문)
       · sold_revenue  = 총 판매 매출 (line_total 합)
       · Session 7 종합 1 - price × sold_qty 상관 분석에 사용            */
PROC SQL;
   CREATE TABLE work.prod_sales AS
   SELECT p.product_id,
          p.product_name,
          p.brand,
          p.category_id,
          p.price,
          p.cost,
          p.stock,
          p.rating_avg,
          p.review_count,
          COALESCE(SUM(oi.quantity), 0)   AS sold_qty
                                                LABEL='총판매수량',
          COALESCE(SUM(oi.line_total), 0) AS sold_revenue
                                                LABEL='총판매매출',
          COUNT(oi.item_id)               AS n_items
                                                LABEL='주문라인수'
   FROM shop.products AS p
   LEFT JOIN shop.order_items AS oi
          ON p.product_id = oi.product_id
   GROUP BY p.product_id, p.product_name, p.brand, p.category_id,
            p.price, p.cost, p.stock, p.rating_avg, p.review_count;
QUIT;

/*- S1.1 [Slide 11] 실습 1 - 광고비 x 매출 x 트래픽 상관 ----*/
TITLE "[S1.1] 실습 1 - budget x revenue x clicks 상관 (shop.campaigns)";
proc corr data = work.ads
		 pearson spearman
		`plots = matrix(histogram);
	var budget renenue clicks;
/* ── [사전 준비] 강의용 분석 뷰 3 개 생성 (모든 세션 재사용) ──────── */

/* (A) work.ads : shop.campaigns 확장 
        · budget · revenue · impressions · clicks · conversions (원본)
        · cpc / cpa / roi / month / season (파생)                       */
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

/* (B) work.uo_sum : shop.users + shop.orders JOIN (Session 2~6 재사용)
       · tenure_days       = TODAY - signup_date (원 강의 tenure 대체)
       · marketing_consent = 0/1 (원 강의 app_user 대체)                 */
PROC SQL;
   CREATE TABLE work.uo_sum AS
   SELECT u.user_id,
          u.age,
          u.gender,
          u.city,
          u.channel,
          u.vip_grade,
          u.marketing_consent                                LABEL='마케팅수신동의',
          u.total_spent,
          u.order_count                                      LABEL='총주문건',
          u.churn,
          INTCK('DAY', u.signup_date, TODAY())    AS tenure_days
                                                             LABEL='가입경과일',
          COUNT(o.order_id)                        AS n_orders
                                                             LABEL='결제주문수',
          SUM(o.total_amount)                      AS spent
                                                             LABEL='실결제총액',
          MEAN(o.total_amount)                     AS avg_price
                                                             LABEL='평균결제액',
          CASE WHEN u.total_spent >= 1500000 THEN 1 ELSE 0 END
                                                    AS is_vip
                                                             LABEL='VIP여부'
   FROM shop.users  AS u
   INNER JOIN shop.orders AS o
           ON u.user_id = o.user_id
   WHERE o.status = 'paid'
   GROUP BY u.user_id, u.age, u.gender, u.city, u.channel, u.vip_grade,
            u.marketing_consent, u.total_spent, u.order_count, u.churn,
            u.signup_date;
QUIT;

/* (C) work.prod_sales : shop.products + shop.order_items JOIN
       · products.monthly_sales 가 없으므로 order_items 실판매수량 집계
       · sold_qty      = 총 판매 수량 (모든 주문)
       · sold_revenue  = 총 판매 매출 (line_total 합)
       · Session 7 종합 1 - price × sold_qty 상관 분석에 사용            */
PROC SQL;
   CREATE TABLE work.prod_sales AS
   SELECT p.product_id,
          p.product_name,
          p.brand,
          p.category_id,
          p.price,
          p.cost,
          p.stock,
          p.rating_avg,
          p.review_count,
          COALESCE(SUM(oi.quantity), 0)   AS sold_qty
                                                LABEL='총판매수량',
          COALESCE(SUM(oi.line_total), 0) AS sold_revenue
                                                LABEL='총판매매출',
          COUNT(oi.item_id)               AS n_items
                                                LABEL='주문라인수'
   FROM shop.products AS p
   LEFT JOIN shop.order_items AS oi
          ON p.product_id = oi.product_id
   GROUP BY p.product_id, p.product_name, p.brand, p.category_id,
            p.price, p.cost, p.stock, p.rating_avg, p.review_count;
QUIT;




RUN;
TITLE;

/* 편상관 */
proc corr data=work.uo_sum;
	var		spent	n_orders;
	partial	age;
RUN;


PROC CORR
Proc corr data = work.ads;
var	budget revenue;
partial season /* 시즌 통제 */
QUIT;

/* session 2: 단순 선형회귀분석 -> proc REG */
title "[S3.1] PROC REG 풀세트 - spent = f(age)";
proc reg data =work-uo_sum
		Plots=none;
	model spent = age / clb stb;
	output out		= work.pred
			predicted= yhat
			Residual = resid;
Run;
quit;
Title;

title "[S3.2] 실습 3 -budget -> revenue 단순 회귀";
PROC REG DATA = work.ads
		plots = (FIT RESIDUALS);
	MODEL REVENUE = budget;
	OUTPUT OUT	= work.pred_rev
			predicted = pred_revenue
			RESIDUAL= RESIDUAL;
RUN; QUIT;
TITLE;

/* 클릭 수와 매출 간의 상관관계
클릭 수가 X, Renvenue가 Y */

proc contents data=ads;
run;

title "[S3.3] 실습 4 -clicks -> revenue 단순 회귀";
PROC REG DATA = work.ads
		PLOTS = (FIT RESIDUALS);
	MODEL revenue =clicks;
	output = out	=work.pred_rev
	predicted = pred_revenue
	Residual = residual;

RUN; quit; 
title;

/*p34 Session 4 : 다중회귀분석 */
TITLE "[S4.2-(1)] step 2 - 다중 회귀 진단";

proc reg DATA = work.uo_sum
		PLOTS = None;
	MODEL spent = age n_order avg_price
	/ R CLB STB
	vif TOL		/* 다중공선성 */
	DW;			/* Durbin-Watson - 잔차 독립성 */

/* 2단계 : 잔차 정규성  :univariate */
/* (2) 잔차 정규성 - OO Plot */
title "[S4.2-(2)] 잔차 정규성 - proc univeriate qqplot";
proc univariate DATA = work.diag Normal;
	var resid / Normal(MU = est sigma = est);
RUN;

/* 잔차 vs 예측  - 등분산 -> 패턴 확인 */
proc sgplot data=diag;
	scatter X=yhat Y=resid;
	REFLINE 0 / AXIS = y;
run;

/* 변수 선택 -> stepwise + VIF */
proc reg data=ads;
	plot = (FIT RESIDUALS);
	MODEL revenue = budget cpc impressions clicks conversations season /
	selection =	stepwise
	slentry = 0.15
	slstay = 0.15
	vif stb;
RUN;

/* Session 5 logistic 회귀분석 -> sigmoid, logistic */
title "[S5.1] PROC LOGISTIC 풀세트 (CLOODS / CTABLE / RSQ / ROC)";
PROC LOGISTIC DATA =

/*고객 이탈율*/
PROC LOGISTIC DATA = shop.users descending;
	class gender (Param =ref ref = 'M');/* ref를 써서 M을 더미변수로 사용"*/
	model churn = age total_spent gender order_count
	/ clparm= wald;
utput out = work.score
		predicted = p_churn;
RUN;


/* 실제 스키마 반영 - work.uo_sum 사용  (tenure_days, marketing_con,
order_count 실컬럼 활용)*/
title "[S5.2] 실습 5 - 고객 이탈 예측 로지스틱 (work.uo_sum)";
proc logistic data = work.uo_sum descending;
	class gender		(param = ref ref = 'M')
	marketing_consent	(PARAM = REF REF = '0');
	MODEL churn = age  total_spent order_count tenure_days
quit;

/*session 6 : 이상치를 처리하는 방법 : robustreg */

/* (1) proc robustreg */
title "[S6.1-(1) ] Robust 회귀 - M-estimation";
ODS graphics on;

PROC Robustreg DATA = WORK.uo_sum
		METHOD = 'M';
	MODEL spent = age n_orders;
	output out	= work.robust
	R			= resid_r
	outlier		= outlier
	leverage	= leverage;
RUN;

TITLE "[S6.1-(2)] OLS - Robust 비교용";
Proc reg DATA = work.uo_sum;
	Model spent = age n_orders;
Run; quit;
Title;

	