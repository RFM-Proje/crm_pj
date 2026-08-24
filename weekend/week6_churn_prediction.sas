/*=============================================================
  WEEK 6b. 모델 비교(로지스틱 베이스라인 vs 랜덤포레스트 vs GRADBOOST)
           + GRADBOOST 상위 변수 PDP(방향성 해석)  [수정판 v2]

  전제조건: 이 파일은 week6_churn_prediction.sas가 만든
            proj.churn_split (구분=TRAIN/VALID, 이탈여부) 를 그대로 사용함.
            세션을 새로 열었다면 week1~week6 순서대로 먼저 실행 후 이 파일 실행.

  v2에서 수정된 것:
  1) savestate=옵션 -> savestate statement로 수정 (PROC GRADBOOST 문법오류,
     이게 연쇄적으로 이후 전체 스텝을 구문확인모드(OBS=0)로 만들었던 근본원인)
  2) PROC MEANS의 PCTLPTS=/PCTLPRE=는 PROC UNIVARIATE 문법이었음 -> p10=~p90= 로 수정
  3) 한글 변수명(가입기간)을 매크로 변수 이름에 직접 써서 나던 오류 ->
     ASCII 태그(tenure) 별도 파라미터로 분리
  4) 예측확률 컬럼명을 하드코딩하지 않고 find_prob_var 매크로로 자동탐지
     (로지스틱/RF/GRADBOOST가 각각 다른 이름을 쓸 수 있어서)
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
   0. 예측확률 컬럼 자동탐지 매크로
   'P_'로 시작하고 '1'로 끝나는 컬럼을 찾음 (P_1, P_이탈여부1 등 모두 대응)
------------------------------------------------------------- */
%macro find_prob_var(dsn=, outvar=);
    %global &outvar;  /* 이게 빠져서 매크로 밖에서 값이 사라졌던 게 근본 원인 */
    proc contents data=&dsn out=work._cols_&outvar(keep=name) noprint;
    run;
    proc sql noprint;
        select name into :&outvar trimmed
        from work._cols_&outvar
        where upcase(name) like 'P\_%1' escape '\';
    quit;
    %put NOTE: [find_prob_var] &dsn 에서 찾은 예측확률 컬럼 = %superq(&outvar);
%mend find_prob_var;


/* -------------------------------------------------------------
   1. 베이스라인 - PROC LOGISTIC (base SAS, CAS 불필요)
------------------------------------------------------------- */
proc logistic data=proj.churn_split(where=(구분="TRAIN")) outmodel=work.logit_model;
    class 성별 고객지역 / param=ref;
    model 이탈여부(event="1") = Frequency Monetary AvgOrderValue
          CouponUseRate CouponClickRate AvgDiscountRate AvgShipping
          가입기간 성별 고객지역;
run;

proc logistic inmodel=work.logit_model;
    score data=proj.churn_split(where=(구분="VALID"))
          out=proj.logit_scored;
run;

data mycas.logit_scored;
    set proj.logit_scored;
run;

%find_prob_var(dsn=mycas.logit_scored, outvar=logit_pvar);


/* -------------------------------------------------------------
   2. 랜덤포레스트 - PROC FOREST (CAS/Viya 전용)
------------------------------------------------------------- */
proc forest data=mycas.churn_split
            ntrees=100
            seed=2026;
    partition rolevar=구분(TRAIN='TRAIN' VALIDATE='VALID');
    target 이탈여부 / level=nominal;
    input Frequency Monetary AvgOrderValue CouponUseRate CouponClickRate
          AvgDiscountRate AvgShipping 가입기간 / level=interval;
    input 성별 고객지역 / level=nominal;
    output out=mycas.rf_scored copyvars=(고객ID 이탈여부);
    ods output VariableImportance=proj.rf_var_importance
               FitStatistics=proj.rf_fit_stats;
run;

proc print data=proj.rf_var_importance;
    title "2-1. 랜덤포레스트 변수 중요도 - GRADBOOST 순위와 비교";
run;
title;

proc print data=proj.rf_fit_stats;
    title "2-2. 랜덤포레스트 적합도 - train/valid 오분류율 격차로 과적합 재확인";
run;
title;

%find_prob_var(dsn=mycas.rf_scored, outvar=rf_pvar);


/* -------------------------------------------------------------
   3. GRADBOOST 재학습 (savestate STATEMENT로 astore 저장 - v2에서 수정)
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
    savestate rstore=mycas.gb_astore;
run;

%find_prob_var(dsn=mycas.churn_scored, outvar=gb_pvar);


/* -------------------------------------------------------------
   4. 3개 모델 동일 기준으로 AUC 산출 (PROC ASSESS)
   [주의] ROCInfo 실제 컬럼명은 AUC=C, TPR=Sensitivity, FPR은 컬럼이
   따로 없어 1-Specificity로 직접 계산 (이전 프로젝트에서 확인된 명명규칙)
   만약 아래 결과가 이상하면 proc contents data=work.roc_gb; 로 실제
   컬럼명부터 재확인할 것
------------------------------------------------------------- */
proc assess data=mycas.logit_scored;
    target 이탈여부 / event="1" level=nominal;
    input &logit_pvar;
    ods output ROCInfo=work.roc_logit;
run;
data work.roc_logit; set work.roc_logit; 모델="1_로지스틱(베이스라인)"; run;

proc assess data=mycas.rf_scored;
    target 이탈여부 / event="1" level=nominal;
    input &rf_pvar;
    ods output ROCInfo=work.roc_rf;
run;
data work.roc_rf; set work.roc_rf; 모델="2_랜덤포레스트"; run;

proc assess data=mycas.churn_scored;
    target 이탈여부 / event="1" level=nominal;
    input &gb_pvar;
    ods output ROCInfo=work.roc_gb;
run;
data work.roc_gb; set work.roc_gb; 모델="3_GRADBOOST"; run;

/* [확인용] 실제 컬럼명 확인 - 여기 결과 보고 아래 C/Sensitivity가 맞는지 체크 */
proc contents data=work.roc_gb varnum;
    title "4-0. [확인용] ROCInfo 실제 컬럼명 목록";
run;
title;

data proj.roc_compare;
    set work.roc_logit work.roc_rf work.roc_gb;
    OneMinusSpecificity = 1 - Specificity;
run;

proc sql;
    create table proj.auc_summary as
    select 모델, max(C) as AUC format=6.4
    from proj.roc_compare
    group by 모델;
    title "4-1. 3개 모델 AUC 비교 - GRADBOOST가 베이스라인보다 유의미하게 나은지 확인";
    select * from proj.auc_summary order by 모델;
quit;
title;

proc sgplot data=proj.roc_compare;
    series x=OneMinusSpecificity y=Sensitivity / group=모델 lineattrs=(thickness=2);
    lineparm x=0 y=0 slope=1 / lineattrs=(pattern=dash color=gray);
    xaxis label="FPR (1-Specificity)";
    yaxis label="TPR (Sensitivity)";
    title "4-2. 모델별 ROC Curve 비교";
run;
title;


/* -------------------------------------------------------------
   5. GRADBOOST 상위 변수 PDP
------------------------------------------------------------- */
data work.pdp_base_sample;
    set proj.churn_split(where=(구분="VALID"));
    call streaminit(2026);
    if rand("uniform") <= 300/424 then output;
run;

data mycas.pdp_base;
    set work.pdp_base_sample;
run;

/* vname: 실제 스코어링에 쓰일 컬럼명(한글 가능) / tag: 매크로변수·파일명용 ASCII 태그 */
%macro make_pdp(vname=, tag=);

    proc means data=proj.churn_split noprint;
        var &vname;
        output out=work.pctl_&tag
            p10=g1 p20=g2 p30=g3 p40=g4 p50=g5 p60=g6 p70=g7 p80=g8 p90=g9;
    run;

    data _null_;
        set work.pctl_&tag;
        array g g1-g9;
        do i=1 to 9;
            call symputx(cats('grid_', "&tag", '_', i), g(i));
        end;
    run;

    data mycas.pdp_grid_&tag;
        set mycas.pdp_base;
        %do i=1 %to 9;
            &vname = &&grid_&tag._&i;
            grid_id = &i;
            grid_value = &&grid_&tag._&i;
            output;
        %end;
    run;

    proc astore;
        score data=mycas.pdp_grid_&tag
              out=mycas.pdp_scored_&tag
              rstore=mycas.gb_astore
              copyvars=(grid_id grid_value);
    run;

    %find_prob_var(dsn=mycas.pdp_scored_&tag, outvar=pdp_pvar_&tag);

    proc means data=mycas.pdp_scored_&tag noprint nway;
        class grid_value;
        var &&pdp_pvar_&tag;
        output out=proj.pdp_&tag(drop=_type_ _freq_) mean=평균예측확률;
    run;

    proc sgplot data=proj.pdp_&tag;
        series x=grid_value y=평균예측확률 / markers;
        xaxis label="&vname (P10~P90)";
        yaxis label="평균 예측 이탈확률";
        title "5. PDP - &vname 값에 따른 이탈확률 변화";
    run;
    title;

%mend make_pdp;

%make_pdp(vname=AvgShipping, tag=AvgShipping);
%make_pdp(vname=AvgOrderValue, tag=AvgOrderValue);
%make_pdp(vname=Monetary, tag=Monetary);
%make_pdp(vname=가입기간, tag=tenure);


/* -------------------------------------------------------------
   6. 마무리
------------------------------------------------------------- */
cas mysession terminate;
