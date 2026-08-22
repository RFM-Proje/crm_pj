/*=============================================================
  WEEK 6. 이탈예측 (PROC GRADBOOST)
  입력: proj.customer_segments (3주차 K=6 산출물)
  목표: 90일 이상 미구매 고객을 "이탈"로 정의하고,
        Recency/Cluster_ID를 제외한 나머지 특성으로 예측

  [이탈 정의 관련 핵심 주의사항]
  Recency(최근성)로 이탈 여부를 정의하기 때문에, Recency 자체와
  Recency 기반으로 만들어진 Cluster_ID를 예측변수에 그대로 넣으면
  "정답을 미리 알려주고 맞히는" 순환논리(data leakage)가 됨.
  따라서 두 변수 모두 예측 입력에서 제외하고, Frequency/Monetary/
  AvgOrderValue/쿠폰·할인·배송료/인구통계만 사용함
=============================================================*/

libname proj "/home/student/open";


/* -------------------------------------------------------------
   1. 이탈 라벨 생성 (90일 기준)
------------------------------------------------------------- */
data proj.churn_base;
    set proj.customer_segments;
    if Recency > 90 then 이탈여부 = 1;
    else 이탈여부 = 0;
run;

/* 이탈 비율 확인 - 너무 한쪽으로 쏠려있으면(예: 95:5) 모델링 시
   클래스 불균형 보정이 추가로 필요할 수 있음 */
proc freq data=proj.churn_base;
    tables 이탈여부 / nocum;
    title "1-1. 이탈여부 분포 (90일 기준)";
run;
title;

/* 참고 - 군집(K=6)별 이탈률도 같이 확인 (검증용, 예측변수 아님) */
proc freq data=proj.churn_base;
    tables Cluster_ID * 이탈여부 / nopercent norow;
    title "1-2. [참고용] 군집별 이탈률 - Cluster_ID=2(이탈위험 세그먼트)와 일치하는지 확인";
run;
title;


/* -------------------------------------------------------------
   2. 학습/검증 데이터 분할 (70:30)
------------------------------------------------------------- */
data proj.churn_split;
    set proj.churn_base;
    call streaminit(2026);
    _rand = rand("uniform");
    if _rand <= 0.7 then 구분 = "TRAIN";
    else 구분 = "VALID";
    drop _rand;
run;

proc freq data=proj.churn_split;
    tables 구분 * 이탈여부 / nopercent norow nocol;
    title "2-1. 학습/검증 분할 및 각 구간의 이탈여부 분포 확인";
run;
title;


/* -------------------------------------------------------------
   3. CAS 세션 연결 및 데이터 업로드
   [참고] PROC GRADBOOST는 SAS Viya(CAS) 전용 프로시저로, 반드시
   CAS 라이브러리에 있는 테이블을 대상으로 실행해야 함. 아래
   caslib 이름(casuser)은 환경마다 다를 수 있으니, 만약 에러가
   나면 담당 조교/환경설정에 맞는 caslib 이름으로 바꿀 것
   [수정] 세션을 다시 실행할 때 "이미 존재하는 세션" 경고가
   반복되지 않도록, 기존 세션이 없을 때만 새로 만들도록 처리
------------------------------------------------------------- */
%if %sysfunc(sessfound(mysession)) = 0 %then %do;
    cas mysession;
%end;
libname mycas cas caslib="casuser";

data mycas.churn_split;
    set proj.churn_split;
run;


/* -------------------------------------------------------------
   4. PROC GRADBOOST 모델링
   - Recency, Cluster_ID, 고객ID는 예측변수에서 제외 (data leakage
     방지 + 식별자이기 때문)
------------------------------------------------------------- */
proc gradboost data=mycas.churn_split
                ntrees=100
                seed=2026;
    partition rolevar=구분(TRAIN='TRAIN' VALIDATE='VALID');
    target 이탈여부 / level=nominal;
    input Frequency Monetary AvgOrderValue CouponUseRate CouponClickRate
          AvgDiscountRate AvgShipping 가입기간 / level=interval;
    input 성별 고객지역 / level=nominal;
    output out=mycas.churn_scored copyvars=(고객ID 이탈여부);
    ods output VariableImportance=proj.var_importance
               FitStatistics=proj.fit_stats;
run;

proc print data=proj.var_importance;
    title "4-1. 변수 중요도 - 어떤 특성이 이탈 예측에 가장 크게 기여하는지";
run;
title;

proc print data=proj.fit_stats;
    title "4-2. 학습/검증 적합도 지표 (오분류율 등)";
run;
title;


/* -------------------------------------------------------------
   5. 검증셋 성능 평가 - ROC/AUC
   [수정] FITSTAT 문의 PVAR=에 실제 타겟변수(이탈여부)를 잘못
   넣었던 게 에러 원인. PVAR는 예측"확률" 컬럼용이라 이미 INPUT
   문에 지정한 P_이탈여부1과 중복이라 FITSTAT 문 자체를 제거하고
   INPUT 문만으로 ROC 계산
------------------------------------------------------------- */
proc assess data=mycas.churn_scored;
    target 이탈여부 / event="1" level=nominal;
    input P_이탈여부1;
    ods output ROCInfo=proj.roc_info
               FitStat=proj.assess_fitstat;
run;

proc sql;
    select max(area) as AUC
    from proj.roc_info;
    title "5-1. 검증셋 AUC (0.5=무작위, 1.0=완벽 예측)";
quit;
title;

proc sgplot data=proj.roc_info;
    series x=fpr y=tpr;
    lineparm x=0 y=0 slope=1 / lineattrs=(pattern=dash color=gray);
    xaxis label="FPR (위양성률)";
    yaxis label="TPR (재현율)";
    title "5-2. ROC Curve";
run;
title;


/* -------------------------------------------------------------
   6. 마무리 - CAS 세션 정리
------------------------------------------------------------- */
cas mysession terminate;

proc contents data=proj.roc_info varnum;
run;
