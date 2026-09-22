/*=============================================================
  STAGE 5 (4번 스크립트): 고객 VIP 등급 x 이탈 위험도 최종 매핑
  [수정] tier_action_summary 생성 시 count(*)와 비집계컬럼(action_strategy)을
  같은 GROUP BY에 섞어 쓰면서 재병합(remerge) 문제로 action_strategy가
  엉뚱한 (rfmp_grade, churn_risk_grade) 조합에 붙는 버그 수정.
  -> 집계(고객수 카운트)와 조인(액션플랜 붙이기)을 두 단계로 분리.

  [경로 및 연동 설정]
  - 라이브러리 경로: /home/student/crm_db
  - 연동 테이블:
    1) crm.w3_customer_rfmp_py      (RFM-P 6단계 등급)
    2) crm.w3_churn_scored_v2       (ML 이탈 예측 확률)
    3) crm.w3_rfmp_category_top5_py (Lift 기준 등급별 대표 카테고리)
=============================================================*/

options validvarname=any;

/*-------------------------------------------------------------
   0. 경로 설정 및 라이브러리 연결
-------------------------------------------------------------*/
%let CRM_PATH = /home/student/crm_db;
libname crm "&CRM_PATH.";


/*-------------------------------------------------------------
   A1. 이탈 위험 등급(3분위: Low / Medium / High) 부여
-------------------------------------------------------------*/
proc rank data=crm.w3_churn_scored_v2 groups=3 out=work.churn_ranked;
    var churn_probability;
    ranks churn_risk_rank;
run;

data work.churn_ranked;
    set work.churn_ranked;
    length churn_risk_grade $6;
    if churn_risk_rank = 0 then churn_risk_grade = "Low";
    else if churn_risk_rank = 1 then churn_risk_grade = "Medium";
    else if churn_risk_rank = 2 then churn_risk_grade = "High";
run;


/*-------------------------------------------------------------
   A2. RFM-P 등급 + 이탈위험등급 + 대표 카테고리 결합
-------------------------------------------------------------*/
proc sql;
    create table work.customer_tier_temp as
    select a.customer_id,
           a.rfmp_tier as rfmp_grade,
           b.churn_probability,
           b.churn_risk_grade
    from crm.w3_customer_rfmp_py as a
    inner join work.churn_ranked as b
      on a.customer_id = b.customer_id;

    create table crm.customer_final_tier as
    select a.customer_id,
           a.rfmp_grade,
           a.churn_probability,
           a.churn_risk_grade,
           b.product_category as top_category,
           catx("_", a.rfmp_grade, a.churn_risk_grade) as final_tier_code length=30
    from work.customer_tier_temp as a
    left join crm.w3_rfmp_category_top5_py as b
      on a.rfmp_grade = b.rfmp_tier and b.category_rank = 1;
quit;

proc freq data=crm.customer_final_tier;
    tables final_tier_code / nocum;
    title "18개 최종 매트릭스 셀별 고객 분포 (6개 VIP 등급 x 3개 이탈위험군)";
run;
title;


/*-------------------------------------------------------------
   A3. 18개 세그먼트별 액션 플랜(실행 전략) 매핑

   [진짜 원인] action_strategy $100. 처럼 콜론(:) 없이 명시적 너비를
   가진 informat을 list input 자리에 쓰면, SAS가 그 변수를
   "고정폭(formatted) 입력"으로 처리함. 그러면 현재 줄에 100바이트가
   안 남았을 때 줄바꿈을 무시하고 다음 줄까지 읽어버려서, 포인터가
   엉뚱한 위치로 밀리고 이후 레코드들이 통째로 어긋남
   (일부는 등급명까지 껴서 들어가고 일부는 비어버리는 현상의 원인).

   [수정] "action_strategy : $100."처럼 콜론을 붙여 modified list
   input으로 명시 -> 공백으로 구분된 한 단어만 읽고 informat만 적용.

   [참고] 이전에 시도했던 count(*)/GROUP BY 분리는 근본 원인이 아니었고
   (실제 원인은 이 DATA step), 그래도 재병합 방지 관점에서 나쁜 습관은
   아니므로 그대로 유지함.
-------------------------------------------------------------*/
data work.action_plan;
    length rfmp_grade $10 churn_risk_grade $6 action_strategy $100;
    input rfmp_grade $ churn_risk_grade $ action_strategy : $100.;
    datalines;
VIP Low VIP전용혜택_크로스셀링유지
VIP Medium VIP이탈방지_크로스셀링프로모션
VIP High VIP긴급리텐션_1대1컨택
Diamond Low 크로스셀링_오프라인마케팅유지
Diamond Medium 크로스셀링_쿠폰미사용고객타겟프로모션
Diamond High 크로스셀링_긴급할인쿠폰
Platinum Low 묶음상품_정상마케팅
Platinum Medium 묶음상품_쿠폰사용유도프로모션
Platinum High 묶음상품_긴급할인프로모션
Gold Low 묶음상품_맞춤쿠폰
Gold Medium 묶음상품_맞춤쿠폰_리마인드
Gold High 묶음상품_긴급맞춤쿠폰
Silver Low 주카테고리확립_정기모니터링
Silver Medium 주카테고리확립_리마인드이메일
Silver High 주카테고리확립_적립금제공_긴급
Bronze Low 이탈방지_무조건쿠폰발급
Bronze Medium 이탈방지_리타겟팅광고
Bronze High 이탈방지_고할인쿠폰_긴급
;
run;

/* 1단계: (rfmp_grade, churn_risk_grade) 기준 고객수만 집계 */
proc sql;
    create table work.tier_customer_count as
    select a.rfmp_grade,
           a.churn_risk_grade,
           count(*) as customer_count
    from crm.customer_final_tier as a
    group by a.rfmp_grade, a.churn_risk_grade;
quit;

/* 2단계: 집계된 결과에 action_plan을 조인 (action_strategy가
   섞일 여지 없이 rfmp_grade/churn_risk_grade 기준 1:1로만 붙음) */
proc sql;
    create table crm.tier_action_summary as
    select a.rfmp_grade,
           a.churn_risk_grade,
           a.customer_count,
           b.action_strategy
    from work.tier_customer_count as a
    left join work.action_plan as b
      on a.rfmp_grade = b.rfmp_grade and a.churn_risk_grade = b.churn_risk_grade
    order by a.rfmp_grade, a.churn_risk_grade;
quit;

proc print data=crm.tier_action_summary;
    title "최종 18개 그룹별 고객수 및 타겟팅 실행 전략 요약";
run;
title;
