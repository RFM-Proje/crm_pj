/*=============================================================
  WEEK 6a. 이탈예측 - PROC GRADBOOST (복원판)

  [주의] 이 파일은 사용자가 실수로 원본을 덮어써서, 그동안의 로그/대화
  기록을 바탕으로 최대한 동일하게 재구성한 버전입니다. 100% 원본과
  일치한다고 보장은 못 하니, 실행 후 이상한 부분 있으면 알려주세요.

  전제조건: week1~week5 실행 완료, proj.customer_segments (K=6 군집,
  Cluster_ID/Recency/Frequency/Monetary/AvgOrderValue/CouponUseRate/
  CouponClickRate/AvgDiscountRate/AvgShipping/가입기간/성별/고객지역
  포함) 존재해야 함.

  이탈 정의: Recency > 90일 → 이탈여부=1
  예측변수에서 Recency, Cluster_ID 제외 (이탈 정의에 쓰인 변수라 leakage 방지)
=============================================================*/

libname proj "/home/student/open";

%if %sysfunc(sessfound(mysession)) = 0 %then %do;
    cas mysession;
%end;
libname mycas cas caslib="casuser";


/* -------------------------------------------------------------
   0. 이탈여부 파생변수 생성 + 학습/검증 분할
------------------------------------------------------------- */
data proj.churn_split;
    set proj.customer_segments;
    이탈여부 = (Recency > 90);

    call streaminit(2026);
    if rand("uniform") < 0.7 then 구분 = "TRAIN";
    else 구분 = "VALID";
run;

data mycas.churn_split;
    set proj.churn_split;
run;


/* -------------------------------------------------------------
   1-1. 이탈여부 분포 (90일 기준)
------------------------------------------------------------- */
proc freq data=proj.churn_split;
    tables 이탈여부;
    title "1-1. 이탈여부 분포 (90일 기준)";
run;
title;


/* -------------------------------------------------------------
   1-2. [참고용] 군집별 이탈률 - Cluster_ID=2(이탈위험 세그먼트)와 일치하는지 확인
------------------------------------------------------------- */
proc freq data=proj.churn_split;
    tables Cluster_ID * 이탈여부;
    title "1-2. [참고용] 군집별 이탈률 - Cluster_ID=2(이탈위험 세그먼트)와 일치하는지 확인";
run;
title;


/* -------------------------------------------------------------
   2-1. 학습/검증 분할 및 각 구간의 이탈여부 분포 확인
------------------------------------------------------------- */
proc freq data=proj.churn_split;
    tables 구분 * 이탈여부;
    title "2-1. 학습/검증 분할 및 각 구간의 이탈여부 분포 확인";
run;
title;


/* -------------------------------------------------------------
   3. PROC GRADBOOST 학습
   Recency, Cluster_ID는 이탈 정의에 쓰인 변수라 예측변수에서 제외
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
    ods output VariableImportance=proj.churn_var_importance
               FitStatistics=proj.churn_fit_stats;
run;


/* -------------------------------------------------------------
   4-1. 변수 중요도 - 어떤 특성이 이탈 예측에 가장 크게 기여하는지
------------------------------------------------------------- */
proc print data=proj.churn_var_importance;
    title "4-1. 변수 중요도 - 어떤 특성이 이탈 예측에 가장 크게 기여하는지";
run;
title;


/* -------------------------------------------------------------
   4-2. 학습/검증 적합도 지표 (오분류율 등)
------------------------------------------------------------- */
proc print data=proj.churn_fit_stats;
    title "4-2. 학습/검증 적합도 지표 (오분류율 등)";
run;
title;


/* -------------------------------------------------------------
   5. PROC ASSESS - AUC, ROC, Lift 확인
   [주의] ROCInfo 실제 컬럼명: AUC=C, TPR=Sensitivity, FPR은 컬럼이 따로
   없어 1-Specificity로 직접 계산해야 함 (week6b에서 재확인된 명명규칙)
------------------------------------------------------------- */
proc assess data=mycas.churn_scored;
    target 이탈여부 / event="1" level=nominal;
    input P_이탈여부1;
    ods output ROCInfo=proj.churn_roc_info;
run;

proc sql;
    title "5-1. 최종 AUC";
    select max(C) as AUC format=6.4
    from proj.churn_roc_info;
quit;
title;

data proj.churn_roc_plot;
    set proj.churn_roc_info;
    OneMinusSpecificity = 1 - Specificity;
run;

proc sgplot data=proj.churn_roc_plot;
    series x=OneMinusSpecificity y=Sensitivity / lineattrs=(thickness=2);
    lineparm x=0 y=0 slope=1 / lineattrs=(pattern=dash color=gray);
    xaxis label="FPR (1-Specificity)";
    yaxis label="TPR (Sensitivity)";
    title "5-2. ROC Curve - GRADBOOST 이탈예측 모델";
run;
title;


/* -------------------------------------------------------------
   6. 마무리
------------------------------------------------------------- */
cas mysession terminate;
