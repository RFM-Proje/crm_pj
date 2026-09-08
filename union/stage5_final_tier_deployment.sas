/*=============================================================
  STAGE 5. 최종 등급 설계 + SHAP 해석 보강 + VA 배포
  = week7_final_tier_design.sas + week7b_optuna_xgboost_shap.sas
    + week7c_promote_to_va.sas
  전제조건: STAGE 1~4 모두 실행 완료
  (proj.customer_segments, proj.cluster_category_top5,
   proj.churn_split_v2, proj.churn_scored_v2 필요)
  산출물: proj.customer_final_tier, proj.tier_action_summary,
          SHAP png 4종, CAS 승격 테이블 2개
  이 세 파일은 서로 대체 관계가 아니라 순서대로 이어지는 단계이므로
  원본 로직 변경 없이 그대로 이어붙임:
   PART A. 군집(Who) + 이탈위험등급(When) + 대표 연관구매카테고리(What)
           결합 -> 최종 고객 등급 및 실행전략 매핑 (base SAS)
   PART B. Optuna+XGBoost로 SAS GRADBOOST 대비 성능 재확인 + SHAP으로
           개별 고객 단위 해석 보강 (PROC PYTHON, PART A 산출물과
           무관하게 week6d의 churn_split_v2를 직접 로드)
   PART C. PART A의 최종등급 테이블을 SAS VA에서 바로 쓸 수 있도록
           CAS 세션에 promote
=============================================================*/

libname proj "/home/student/open";


/* =============================================================
   PART A. 최종 등급 설계 및 실행 전략
   (원본: week7_final_tier_design.sas)

   [주의] proj.cluster_category_top5의 정확한 컬럼 구조를 모르는 상태로
   작성함. 아래 "0-2. 진단" 스텝 결과 보고 조정 필요할 가능성 높음.
============================================================= */

/* -------------------------------------------------------------
   A0-1. [확인용] 필요한 원천 테이블들 존재/구조 확인
------------------------------------------------------------- */
proc contents data=proj.customer_segments varnum;
    title "A0-1a. [확인용] customer_segments 구조 - Cluster_ID/고객ID 있는지";
run;
title;

proc contents data=proj.churn_scored_v2 varnum;
    title "A0-1b. [확인용] churn_scored_v2 구조 - 고객ID/이탈확률 컬럼명 확인";
run;
title;


/* -------------------------------------------------------------
   A0-2. [확인용] cluster_category_top5 구조 - What 차원 소스
------------------------------------------------------------- */
proc contents data=proj.cluster_category_top5 varnum;
    title "A0-2a. [확인용] cluster_category_top5 컬럼 구조";
run;
title;

proc print data=proj.cluster_category_top5(obs=30);
    title "A0-2b. [확인용] cluster_category_top5 내용 미리보기 - Cluster별 순서/랭킹 확인용";
run;
title;


/* -------------------------------------------------------------
   A1. 이탈확률 컬럼 자동탐지 (매번 반복되는 패턴이라 매크로 재사용)
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

%find_prob_var(dsn=proj.churn_scored_v2, outvar=churn_pvar);


/* -------------------------------------------------------------
   A2. Who + When 결합 - 군집 + 이탈위험등급(3분위)
------------------------------------------------------------- */
proc rank data=proj.churn_scored_v2 groups=3 out=work.churn_ranked;
    var &churn_pvar;
    ranks 이탈위험순위;
run;

data work.churn_ranked;
    set work.churn_ranked;
    length 이탈위험등급 $6;
    if 이탈위험순위 = 0 then 이탈위험등급 = "Low";
    else if 이탈위험순위 = 1 then 이탈위험등급 = "Medium";
    else if 이탈위험순위 = 2 then 이탈위험등급 = "High";
run;

proc sql;
    create table work.who_when as
    select a.고객ID, a.Cluster_ID, b.&churn_pvar as 이탈확률, b.이탈위험등급
    from proj.customer_segments as a
    inner join work.churn_ranked as b
      on a.고객ID = b.고객ID;
quit;

/* 군집 라벨 포맷 - 3주차 프로파일링 결과 기준 */
proc format;
    value clusterf
        1 = "배송이슈"
        2 = "이탈위험군"
        3 = "저관여"
        4 = "쿠폰의존"
        5 = "핵심고객"
        6 = "일반고객";
quit;


/* -------------------------------------------------------------
   A3. What 차원 결합 - 군집별 대표(1순위) 연관구매 카테고리
   [가정] cluster_category_top5가 이미 군집별 순위 순서대로 정렬되어
   저장되어 있다고 가정 (PROC SORT는 stable이라 동순위 내 원래 순서 유지됨).
   실제로 안 맞으면 A0-2 진단 결과 보고 수정.
------------------------------------------------------------- */
proc sort data=proj.cluster_category_top5 out=work.cat_sorted;
    by Cluster_ID;
run;

data work.cat_top1;
    set work.cat_sorted;
    by Cluster_ID;
    if first.Cluster_ID;
run;


/* -------------------------------------------------------------
   A4. 최종 결합 - Who + When + What
------------------------------------------------------------- */
proc sql;
    create table proj.customer_final_tier as
    select a.고객ID, a.Cluster_ID,
           put(a.Cluster_ID, clusterf.) as 군집라벨,
           a.이탈확률, a.이탈위험등급,
           b.제품카테고리 as 대표카테고리
    from work.who_when as a
    left join work.cat_top1 as b
      on a.Cluster_ID = b.Cluster_ID;
quit;

/* 최종 등급명 생성 - 군집라벨 + 이탈위험등급 조합 */
data proj.customer_final_tier;
    set proj.customer_final_tier;
    length 최종등급 $30;
    최종등급 = catx("_", 군집라벨, 이탈위험등급);
run;

proc freq data=proj.customer_final_tier;
    tables 최종등급 / nocum;
    title "A4-1. 최종 등급별 고객 분포 (18개 셀 = 6군집 x 3위험등급)";
run;
title;


/* -------------------------------------------------------------
   A5. 등급별 실행전략 매핑
------------------------------------------------------------- */
data work.action_plan;
    length 군집라벨 $10 이탈위험등급 $6 실행전략 $60;
    input 군집라벨 $ 이탈위험등급 $ 실행전략 $60.;
    datalines;
핵심고객 Low VIP전용혜택_유지관리
핵심고객 Medium VIP이탈방지_개인화프로모션
핵심고객 High VIP긴급리텐션_1대1컨택
이탈위험군 Low 관계재형성_뉴스레터
이탈위험군 Medium 윈백쿠폰_발송
이탈위험군 High 긴급윈백쿠폰_대폭할인
쿠폰의존 Low 쿠폰의존관리_정상가유도
쿠폰의존 Medium 쿠폰의존관리_정상가유도
쿠폰의존 High 쿠폰재발송_이탈방지
배송이슈 Low 배송이슈케어_정기모니터링
배송이슈 Medium 배송비할인_리텐션
배송이슈 High 배송비할인_긴급리텐션
저관여 Low 저관여활성화_추천상품노출
저관여 Medium 저관여활성화_추천상품노출
저관여 High 자연이탈_저비용대응
일반고객 Low 일반유지_정기프로모션
일반고객 Medium 일반유지_정기프로모션
일반고객 High 일반이탈방지_쿠폰발송
;
run;

proc sql;
    create table proj.tier_action_summary as
    select a.군집라벨, a.이탈위험등급, count(*) as 고객수, b.실행전략
    from proj.customer_final_tier as a
    left join work.action_plan as b
      on a.군집라벨 = b.군집라벨 and a.이탈위험등급 = b.이탈위험등급
    group by a.군집라벨, a.이탈위험등급, b.실행전략
    order by a.군집라벨, a.이탈위험등급;
quit;

proc print data=proj.tier_action_summary;
    title "A5-1. 등급별 고객수 + 실행전략 매핑표";
run;
title;


/* -------------------------------------------------------------
   A6. [초안] ROI 추정 - 매우 러프한 방향성 추정치
   [주의] 정확한 CAC 계산 소스를 못 찾아서, Marketing_info 총비용을
   전체 고객수로 나눈 단순 평균으로 근사함. 정밀한 값 아님 - 방향성
   참고용으로만 사용할 것.
------------------------------------------------------------- */
proc sql;
    title "A6-1. [초안] 대략적 CAC 추정 - 총마케팅비 / 전체고객수";
    select sum(오프라인비용 + 온라인비용) as 총마케팅비,
           (select count(distinct 고객ID) from proj.customer_segments) as 전체고객수,
           calculated 총마케팅비 / calculated 전체고객수 as 대략적_CAC format=8.0
    from proj.mkt_raw;
quit;
title;

proc sql;
    title "A6-2. 이탈위험군(High) 규모 - 리텐션 캠페인 대상 예상 규모";
    select 군집라벨, count(*) as 대상고객수, mean(이탈확률) as 평균이탈확률 format=6.4
    from proj.customer_final_tier
    where 이탈위험등급 = "High"
    group by 군집라벨
    order by calculated 대상고객수 desc;
quit;
title;



/* =============================================================
   PART B. Optuna 기반 XGBoost 튜닝 + SHAP 해석
   (원본: week7b_optuna_xgboost_shap.sas)

   PROC PYTHON으로 Python 코드(pandas/optuna/xgboost/shap)를 그대로
   감싼 것으로, PART A의 산출물과 무관하게 week6d가 만든
   proj.churn_split_v2를 직접 로드해서 별도로 진행함.

   사전 설치 필요 (SAS Studio 터미널 또는 PROC PYTHON에서):
     pip install optuna xgboost shap pandas scikit-learn matplotlib

   산출물: /home/student/open/plots/ 밑에 shap_*.png 4개 저장됨
============================================================= */

proc python;
submit;
"""
Optuna 기반 XGBoost 하이퍼파라미터 튜닝
- SAS week6d가 만든 proj.churn_split_v2 (.sas7bdat)를 pandas로 직접 로드
- SAS에서 이미 나눈 TRAIN/VALID 분할(구분 컬럼)을 그대로 재사용 -> 공정 비교
- 목표: SAS GRADBOOST 결과(AUC 0.8803)를 넘어서는 조합을 찾을 수 있는지 확인

사전 설치 필요 (안 되어 있으면):
    pip install optuna xgboost pandas scikit-learn

[주의] 파일 경로는 이전 로그에서 확인된 패턴
(/home/student/open/customer_segments.sas7bdat 등)을 따라
/home/student/open/churn_split_v2.sas7bdat 로 가정했습니다.
실제 경로가 다르면 DATA_PATH만 수정하면 됩니다.
"""

import sys
import site
# [수정] pip install --user 로 설치한 패키지(optuna, shap 등)가
# conda 환경의 기본 sys.path에 안 잡혀서 import가 실패했던 문제 해결 -
# user site-packages 경로를 직접 추가
_user_site = site.getusersitepackages()
if _user_site not in sys.path:
    sys.path.insert(0, _user_site)

import pandas as pd
import numpy as np
import optuna
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from xgboost import XGBClassifier
from sklearn.metrics import roc_auc_score
import koreanize_matplotlib
DATA_PATH = "/home/student/open/churn_split_v2.sas7bdat"

# -------------------------------------------------------------
# 1. 데이터 로드
# -------------------------------------------------------------
df = pd.read_sas(DATA_PATH, encoding="utf-8")

print("전체 데이터 shape:", df.shape)
print(df["구분"].value_counts())
print(df["이탈여부"].value_counts(normalize=True))

# -------------------------------------------------------------
# 2. 범주형 변수 인코딩 (성별, 고객지역 -> 원핫)
#    SAS GRADBOOST는 level=nominal로 알아서 처리했지만
#    XGBoost는 숫자 인코딩이 필요함
# -------------------------------------------------------------
df = pd.get_dummies(df, columns=["성별", "고객지역"], drop_first=True)

# -------------------------------------------------------------
# 3. SAS에서 만든 TRAIN/VALID 분할 그대로 재사용
# -------------------------------------------------------------
train = df[df["구분"] == b"TRAIN"] if df["구분"].dtype == object and isinstance(df["구분"].iloc[0], bytes) else df[df["구분"] == "TRAIN"]
valid = df[df["구분"] == b"VALID"] if df["구분"].dtype == object and isinstance(df["구분"].iloc[0], bytes) else df[df["구분"] == "VALID"]

exclude_cols = ["고객ID", "이탈여부", "구분"]
feature_cols = [c for c in df.columns if c not in exclude_cols]

X_train, y_train = train[feature_cols], train["이탈여부"]
X_valid, y_valid = valid[feature_cols], valid["이탈여부"]

print("TRAIN:", X_train.shape, "VALID:", X_valid.shape)

# -------------------------------------------------------------
# 4. Optuna 목적함수 - VALID AUC 최대화
# -------------------------------------------------------------
def objective(trial):
    params = {
        "n_estimators": trial.suggest_int("n_estimators", 50, 300),
        "max_depth": trial.suggest_int("max_depth", 2, 8),
        "learning_rate": trial.suggest_float("learning_rate", 0.01, 0.3, log=True),
        "subsample": trial.suggest_float("subsample", 0.5, 1.0),
        "colsample_bytree": trial.suggest_float("colsample_bytree", 0.5, 1.0),
        "reg_alpha": trial.suggest_float("reg_alpha", 0.0, 5.0),
        "reg_lambda": trial.suggest_float("reg_lambda", 0.0, 5.0),
        "random_state": 2026,
        "eval_metric": "logloss",
        "use_label_encoder": False,
    }
    model = XGBClassifier(**params)
    model.fit(X_train, y_train)
    preds = model.predict_proba(X_valid)[:, 1]
    return roc_auc_score(y_valid, preds)


study = optuna.create_study(
    direction="maximize",
    sampler=optuna.samplers.TPESampler(seed=2026),
)
study.optimize(objective, n_trials=100)

print("\n===== 튜닝 결과 =====")
print("Best AUC (Optuna/XGBoost):", study.best_value)
print("SAS GRADBOOST(시점분리) AUC: 0.8803  <- 비교 기준")
print("Best params:", study.best_params)

# -------------------------------------------------------------
# 5. 최적 모델로 최종 확인 + 변수중요도
# -------------------------------------------------------------
best_model = XGBClassifier(**study.best_params, random_state=2026, eval_metric="logloss")
best_model.fit(X_train, y_train)
final_auc = roc_auc_score(y_valid, best_model.predict_proba(X_valid)[:, 1])
print("최종 검증 AUC:", final_auc)

importance = pd.Series(best_model.feature_importances_, index=feature_cols).sort_values(ascending=False)
print("\n변수 중요도:\n", importance)

# -------------------------------------------------------------
# 6. XAI - SHAP 해석
# (M6 Day7 자료 Session 5 참고, 우리 프로젝트 데이터에 맞게 적용)
#
# 왜 필요한가: feature_importances_는 "얼마나 중요한지" 순위만 알려줌
# (SAS PDP로도 일부 확인했지만), SHAP은 "각 고객 개별로 어떤 변수가
# 이탈확률을 얼마나/어느 방향으로 밀어올렸는지"까지 분해해서 보여줌.
# 사전 설치 필요 시: pip install shap
# -------------------------------------------------------------
import shap

explainer = shap.TreeExplainer(best_model)
shap_values = explainer.shap_values(X_valid)

# 6-1. 글로벌 해석 - 변수별 영향 방향 + 크기 (summary plot)
shap.summary_plot(shap_values, X_valid, show=False)
plt.tight_layout()
plt.savefig("/home/student/open/plots/shap_summary.png", dpi=120)
plt.close()

# 6-2. 변수 중요도 막대그래프 (SHAP 기준 - feature_importances_와 비교용)
shap.summary_plot(shap_values, X_valid, plot_type="bar", show=False)
plt.tight_layout()
plt.savefig("/home/student/open/plots/shap_bar.png", dpi=120)
plt.close()

# 6-3. 개별 고객 해석 - 이탈확률이 가장 높은 고객 1명 (마케팅 액션 근거로 활용 가능)
valid_probs = best_model.predict_proba(X_valid)[:, 1]
high_risk_pos = int(np.argmax(valid_probs))
print(f"\n최고 위험 고객 이탈확률: {valid_probs[high_risk_pos]:.4f}")

shap.force_plot(
    explainer.expected_value, shap_values[high_risk_pos],
    X_valid.iloc[high_risk_pos], matplotlib=True, show=False
)
plt.savefig("/home/student/open/plots/shap_force_top_risk_customer.png", dpi=120)
plt.close()

# 6-4. 의존성 plot - Recency (SAS PDP에서도 1위 변수였음, 방향성 교차검증 목적)
shap.dependence_plot("Recency", shap_values, X_valid, show=False)
plt.tight_layout()
plt.savefig("/home/student/open/plots/shap_dependence_recency.png", dpi=120)
plt.close()

print("\nSHAP 분석 완료 - 아래 파일 생성됨:")
print("  shap_summary.png (글로벌 해석)")
print("  shap_bar.png (변수 중요도)")
print("  shap_force_top_risk_customer.png (최고위험 고객 1명 해석)")
print("  shap_dependence_recency.png (Recency 방향성 - SAS PDP와 비교용)")

endsubmit;
quit;



/* =============================================================
   PART C. week7 최종등급 결과를 SAS VA용 CAS 테이블로 승격(promote)
   (원본: week7c_promote_to_va.sas)

   전제조건: PART A 실행 완료로 proj.customer_final_tier 존재해야 함.

   PROMOTE의 의미: 이 CAS 세션이 끝나도 테이블이 계속 메모리에 남아서
   SAS VA(별도 세션)에서 데이터소스로 바로 잡을 수 있게 됨.
   (일반 CAS 세션 스코프 테이블은 세션 끝나면 사라져서 VA에서 안 보임)
============================================================= */

%if %sysfunc(sessfound(mysession)) = 0 %then %do;
    cas mysession;
%end;
libname mycas cas caslib="casuser";

/* 최종등급 테이블 승격 (replace: 재실행 시 기존 테이블 자동 덮어쓰기) */
proc casutil;
    load data=proj.customer_final_tier
         outcaslib="casuser"
         casout="customer_final_tier"
         promote replace;
run;

/* 참고용 - 이탈확률/변수까지 포함된 상세 테이블도 승격 (VA에서 산점도/히스토그램용) */
proc casutil;
    load data=proj.churn_split_v2
         outcaslib="casuser"
         casout="churn_split_v2"
         promote replace;
run;

/* 승격 확인 */
proc casutil;
    list tables incaslib="casuser";
run;

/* [주의] VA에서 데이터 탐색기(Explorer) 열었을 때 casuser 캐스립 밑에
   CUSTOMER_FINAL_TIER, CHURN_SPLIT_V2 두 테이블이 보이면 성공.
   세션 종료해도 사라지지 않음 (promote 했으므로). */
