/*=============================================================
  WEEK 6c. GRADBOOST 하이퍼파라미터 AUTOTUNE

  전제조건: week1~week6 (또는 week6b) 실행 후, proj.churn_split 존재해야 함.

  목적:
  - 기존 GRADBOOST(ntrees=100, learningrate=0.1 등 기본값)의 AUC 0.9107이
    최선인지, 하이퍼파라미터 조합을 자동 탐색해서 더 나은 조합이 있는지 확인
  - AUTOTUNE은 유전 알고리즘(GA)으로 여러 조합을 시도하며 VALID 성능(AUC) 기준
    최적 조합을 찾음. MAXTIME으로 탐색 시간 상한을 둠(기본 900초=15분).

  [주의] AUTOTUNE 문법은 이 프로젝트에서 처음 사용. 첫 실행에서 옵션명/구조가
  안 맞을 수 있음 - 에러 나면 로그 그대로 공유해줄 것.
=============================================================*/

libname proj "/home/student/open";

%if %sysfunc(sessfound(mysession)) = 0 %then %do;
    cas mysession;
%end;
libname mycas cas caslib="casuser";

data mycas.churn_split;
    set proj.churn_split;
run;


/* -------------------------------------------------------------
   1. AUTOTUNE 실행
   튜닝 대상: ntrees, learningrate, maxdepth, subsamplerate, vars_to_try
   목적함수: AUC (검증셋 기준) - 기존 비교와 동일 기준으로 맞춤
------------------------------------------------------------- */
proc gradboost data=mycas.churn_split;
    partition rolevar=구분(TRAIN='TRAIN' VALIDATE='VALID');
    target 이탈여부 / level=nominal;
    input Frequency Monetary AvgOrderValue CouponUseRate CouponClickRate
          AvgDiscountRate AvgShipping 가입기간 / level=interval;
    input 성별 고객지역 / level=nominal;

    autotune tuningparameters=(
                ntrees(lb=50 ub=200)
                learningrate(lb=0.01 ub=0.3)
                maxdepth(lb=2 ub=6)
                samplingrate(lb=0.5 ub=1.0)
             )
             objective=AUC
             searchmethod=GA
             maxtime=900;

    output out=mycas.churn_scored_tuned copyvars=(고객ID 이탈여부);
    savestate rstore=mycas.gb_astore_tuned;

    ods output TunerResults=proj.autotune_history
               BestConfiguration=proj.autotune_best;
run;

proc print data=proj.autotune_best;
    title "1-1. AUTOTUNE 최적 하이퍼파라미터 조합";
run;
title;

proc print data=proj.autotune_history(obs=20);
    title "1-2. AUTOTUNE 탐색 이력 (상위 20개 시도) - 조합별 성능 비교용";
run;
title;


/* -------------------------------------------------------------
   2. 튜닝된 모델 AUC 확인 - 기존 0.9107과 비교
------------------------------------------------------------- */
%macro find_prob_var(dsn=, outvar=);
    %global &outvar;
    proc contents data=&dsn out=work._cols_&outvar(keep=name) noprint;
    run;
    proc sql noprint;
        select name into :&outvar trimmed
        from work._cols_&outvar
        where upcase(name) like 'P\_%1' escape '\';
    quit;
    %put NOTE: [find_prob_var] &dsn 에서 찾은 예측확률 컬럼 = %superq(&outvar);
%mend find_prob_var;

%find_prob_var(dsn=mycas.churn_scored_tuned, outvar=tuned_pvar);

proc assess data=mycas.churn_scored_tuned;
    target 이탈여부 / event="1" level=nominal;
    input &tuned_pvar;
    ods output ROCInfo=work.roc_tuned;
run;

proc sql;
    title "2-1. 튜닝 전(0.9107) vs 튜닝 후 AUC 비교";
    select max(C) as 튜닝후_AUC format=6.4
    from work.roc_tuned;
quit;
title;


/* -------------------------------------------------------------
   3. 마무리
------------------------------------------------------------- */
cas mysession terminate;
