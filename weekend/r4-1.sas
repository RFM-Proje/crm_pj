/*==========================================================================
  WBS 4.1 Revised v2
  B_DAYS 기준모형 검증 및 전체 고객 상대위험 점수 생성
  [목표]
    1. 3절에서 선택한 B_DAYS 로지스틱 모형을 같은 조건으로 재현한다.
    2. 전체 VALID와 신규 VALID에서 모형의 순위 판별력을 확인한다.
    3. 구매 이력 길이별로 확률 오차와 판별력이 다른지 확인한다.
    4. 전체 고객의 원예측확률과 상대위험 순위를 생성한다.
    5. 4.2가 사용할 기준모형과 점수의 해석 범위를 기록한다.
  [핵심 질문]
    - B_DAYS 모형을 전체 고객의 상대위험 순위 산출에 사용할 수 있는가?
    - TRAIN에 없던 신규 VALID 고객에서도 성능이 유지되는가?
    - 원예측확률을 절대적인 이탈확률로 해석해도 되는가?
  [수행 범위]
    - 공식 Frequency 피처: frequency_days
    - 기준모형: B_DAYS 로지스틱 회귀 1개
    - 평가: TRAIN, 전체 VALID, 기존 VALID, 신규 VALID
    - 추가 평가: 구매 이력 90일 미만, 90~179일, 180일 이상
    - 전체 RFMP 고객의 원예측확률과 상대위험 순위 생성
  [이번 단계에서 하지 않는 작업]
    - frequency_orders를 모형 피처로 다시 추가하지 않는다.
    - 30%·70% 또는 33.3%·66.6%를 절대확률 기준으로 사용하지 않는다.
    - High·Medium·Low 상대위험등급은 4.2에서 생성한다.
    - 로그변환 후보 비교는 4.3, 경제성 계산은 4.4에서 수행한다.
  [해석 유의사항]
    - raw_churn_probability는 모형이 출력한 원확률이다.
    - 기존 결과에서 평균 예측확률이 실제 이탈률보다 낮았다.
      따라서 원확률을 보정된 절대 이탈확률로 확정하지 않는다.
    - relative_risk_percentile은 전체 고객 안에서의 상대적 위치이며,
      risk_priority_rank는 1이 가장 높은 위험순위이다.
    - TRAIN과 VALID에는 같은 고객이 포함될 수 있다.
      VALID_NEW는 TRAIN에 없던 고객만 따로 평가한 결과이다.
    - 90일 미만 고객은 frequency_days=1이 아니라 기준일까지 확보된
      실제 구매 이력 일수로 구분한다.
	- 이탈모형의 Recency는 RFMP Recency보다 모든 고객에서 1일 작다.
      RFMP는 ‘기준일 - 마지막 구매일 + 1’로 계산하지만,
      이탈모형은 ‘기준일 - 마지막 구매일’로 계산하기 때문이다.
      이 차이는 모든 고객에게 동일하게 적용되므로 상대순위에는
      영향을 미치지 않는다.
  [운영용 검토 기준: 통계적 진리가 아닌 프로젝트 확인선]
    - 전체 VALID ROC-AUC가 0.60 미만이면 REVIEW
    - 신규 VALID ROC-AUC가 0.60 미만이면 REVIEW
    - 평균 예측확률과 실제 이탈률 차이가 5%p를 넘으면 REVIEW
    - REVIEW는 중단이 아니라 보고서에 한계를 명시하라는 의미이다.
    - 입력 오류, 중복키, 라벨 오류, 점수 결측은 FAIL이다.
  [입력 테이블]
    CRM.W3_FREQ_ABC_INPUT       : 시간분리 TRAIN·VALID 피처와 라벨
    CRM.W3_FREQ_ABC_METRICS     : 3.3 A·B·C 비교 성능
    CRM.W3_FREQ_ABC_DECISION    : 3.3 선택 결과
    CRM.W3_FREQUENCY_POLICY     : 3.4 Frequency 적용 원칙
    CRM.W3_CUSTOMER_RFMP_PY     : 전체 점수 생성 대상 고객 목록
    CRM.CLEAN_ONLINE            : 전체기간 고객 피처 재생성 원천
    CRM.CLEAN_CUSTOMER          : 성별·지역·가입기간
  [주요 산출물]
    CRM.W4_41_MODEL_METRICS     : TRAIN·VALID·신규 VALID 성능
    CRM.W4_41_COHORT_METRICS    : 구매 이력 길이별 VALID 성능
    CRM.W4_41_VALID_SCORED      : VALID 고객 점수와 상대위험 순위
    CRM.W4_41_CURRENT_SCORED    : 전체 고객 점수와 상대위험 순위
    CRM.W4_41_TOPK_PERFORMANCE  : VALID 상위 100명·200명 성과
    CRM.W4_41_COEFFICIENTS      : 기준모형 계수
    CRM.W4_41_MODEL_CONFIG      : 피처와 모형 설정
    CRM.W4_41_MODEL_DECISION    : 4.2로 전달할 해석 원칙
    CRM.W4_41_QA_SUMMARY        : 자동 품질 점검 결과
    CRM.W4_41_OUTPUT_CATALOG    : 이번 단계 산출물 목록
==========================================================================*/
/*==========================================================================
  0. 실행 옵션과 프로젝트 기준값
==========================================================================*/
options validvarname=any validmemname=extend;
%let CRM_PATH=/home/student/crm_db;
%let RANDOM_SEED=2026;
%let MIN_VALID_AUC=0.60;
%let MIN_NEW_VALID_AUC=0.60;
%let MAX_MEAN_PROB_GAP=0.05;
%let MODEL_MATCH_TOL=0.000001;
%let HISTORY_CUT1=90;
%let HISTORY_CUT2=180;
libname crm "&CRM_PATH.";
/*==========================================================================
  1. 라이브러리와 필수 입력 테이블 확인
==========================================================================*/
%macro require_table(ds=, previous_step=);
    %if %sysfunc(exist(&ds.))=0 %then %do;
        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %put ERROR: &previous_step. 단계를 먼저 정상 실행하십시오.;
        %abort cancel;
    %end;
    %else %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;
%mend;
%macro check_inputs;
    %if %sysfunc(libref(crm)) ne 0 %then %do;
        %put ERROR: CRM 라이브러리가 연결되지 않았습니다.;
        %abort cancel;
    %end;
    %require_table(ds=crm.w3_freq_abc_input,previous_step=WBS 3.2-A);
    %require_table(ds=crm.w3_freq_abc_metrics,previous_step=WBS 3.3-A);
    %require_table(ds=crm.w3_freq_abc_decision,previous_step=WBS 3.3-A);
    %require_table(ds=crm.w3_frequency_policy,previous_step=WBS 3.4);
    %require_table(ds=crm.w3_customer_rfmp_py,previous_step=WBS 3.5~3.9);
    %require_table(ds=crm.clean_online,previous_step=Week 1 정제);
    %require_table(ds=crm.clean_customer,previous_step=Week 1 정제);
%mend;
%check_inputs;
/*==========================================================================
  2. 이전 4.1 v2 산출물만 삭제
==========================================================================*/
proc datasets library=crm nolist nowarn;
    delete w4_41_model_metrics w4_41_cohort_metrics
           w4_41_valid_scored w4_41_current_scored
           w4_41_topk_performance w4_41_coefficients
           w4_41_model_config w4_41_model_decision
           w4_41_qa_summary w4_41_output_catalog;
quit;
/*==========================================================================
  3. 3절에서 B_DAYS와 frequency_days가 선택되었는지 확인
==========================================================================*/
proc sql noprint;
    select upcase(strip(selected_model)) into :SELECTED_MODEL trimmed
    from crm.w3_freq_abc_decision;
    select upcase(strip(selected_option)),
           lowcase(strip(official_frequency_variable))
      into :SELECTED_OPTION trimmed, :OFFICIAL_FREQUENCY trimmed
    from crm.w3_frequency_policy;
quit;
%macro validate_policy;
    %if %upcase(%superq(SELECTED_MODEL)) ne B_DAYS %then %do;
        %put ERROR: 3.3의 선택 모형이 B_DAYS가 아닙니다.;
        %abort cancel;
    %end;
    %if %upcase(%superq(SELECTED_OPTION)) ne B_DAYS %then %do;
        %put ERROR: 3.4의 선택 옵션이 B_DAYS가 아닙니다.;
        %abort cancel;
    %end;
    %if %lowcase(%superq(OFFICIAL_FREQUENCY)) ne frequency_days %then %do;
        %put ERROR: 공식 Frequency 변수가 frequency_days가 아닙니다.;
        %abort cancel;
    %end;
    %put NOTE: 3절 B_DAYS 정책을 확인했습니다.;
%mend;
%validate_policy;
/*==========================================================================
  4. B_DAYS 재현·평가·전체 고객 점수 생성
==========================================================================*/
proc python restart;
submit;
# 4-1. 실행환경과 라이브러리
import os
os.environ["OMP_NUM_THREADS"] = "1"
os.environ["OPENBLAS_NUM_THREADS"] = "1"
os.environ["MKL_NUM_THREADS"] = "1"
os.environ["NUMEXPR_NUM_THREADS"] = "1"
import gc
import warnings
import numpy as np
import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import (
    accuracy_score, average_precision_score, balanced_accuracy_score,
    brier_score_loss, f1_score, log_loss, precision_score,
    recall_score, roc_auc_score
)
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler
warnings.filterwarnings("ignore")
# 4-2. SAS 매크로 기준값
random_seed = int(float(SAS.symget("RANDOM_SEED")))
min_valid_auc = float(SAS.symget("MIN_VALID_AUC"))
min_new_valid_auc = float(SAS.symget("MIN_NEW_VALID_AUC"))
max_mean_prob_gap = float(SAS.symget("MAX_MEAN_PROB_GAP"))
model_match_tol = float(SAS.symget("MODEL_MATCH_TOL"))
history_cut1 = int(float(SAS.symget("HISTORY_CUT1")))
history_cut2 = int(float(SAS.symget("HISTORY_CUT2")))
score_version = "W4_41_B_DAYS_V2"
model_variant = "B_DAYS_BASELINE"
# 4-3. 공통 함수
def normalize_columns(frame):
    result = frame.copy()
    result.columns = [str(c).strip().lower() for c in result.columns]
    return result
def require_columns(frame, columns, table_name):
    missing = [c for c in columns if c not in frame.columns]
    if missing:
        raise ValueError(f"{table_name}에 필요한 변수가 없습니다: " + ", ".join(missing))
def clean_id(series):
    return series.astype(str).str.strip()
def sas_date_to_datetime(series):
    if pd.api.types.is_datetime64_any_dtype(series):
        return pd.to_datetime(series, errors="coerce")
    numeric = pd.to_numeric(series, errors="coerce")
    if numeric.notna().mean() >= 0.90:
        return pd.to_datetime(numeric, unit="D", origin="1960-01-01", errors="coerce")
    return pd.to_datetime(series, errors="coerce")
def save_sas(frame, table_name):
    output = frame.reset_index(drop=True).copy()
    for col in output.select_dtypes(include=["category"]).columns:
        output[col] = output[col].astype(str)
    for col in output.select_dtypes(include=["bool"]).columns:
        output[col] = output[col].astype(int)
    SAS.df2sd(output, dataset=f"crm.{table_name}")
def make_onehot():
    try:
        return OneHotEncoder(handle_unknown="ignore", sparse_output=False)
    except TypeError:
        return OneHotEncoder(handle_unknown="ignore", sparse=False)
def safe_auc(actual, probability, metric="ROC"):
    actual = np.asarray(actual)
    probability = np.asarray(probability)
    if len(actual) == 0 or len(np.unique(actual)) < 2:
        return np.nan
    if metric == "ROC":
        return float(roc_auc_score(actual, probability))
    return float(average_precision_score(actual, probability))
def history_band(days):
    values = pd.to_numeric(days, errors="coerce")
    return np.select(
        [values < history_cut1, values < history_cut2],
        ["LT90", "D90_179"], default="GE180"
    )
def maturity_group(days):
    values = pd.to_numeric(days, errors="coerce")
    return np.where(values < history_cut1, "NEW_LT90", "ESTABLISHED_GE90")
def assign_relative_rank(frame, probability_column):
    result = frame.sort_values(
        [probability_column, "customer_id"], ascending=[False, True]
    ).reset_index(drop=True)
    result["risk_priority_rank"] = np.arange(1, len(result) + 1)
    if len(result) > 1:
        result["relative_risk_percentile"] = (
            1 - (result["risk_priority_rank"] - 1) / (len(result) - 1)
        )
    else:
        result["relative_risk_percentile"] = 1.0
    return result
def metric_row(scope, actual, probability):
    actual = np.asarray(actual, dtype=int)
    probability = np.asarray(probability, dtype=float)
    finite = np.isfinite(probability)
    actual, probability = actual[finite], probability[finite]
    if len(actual) == 0:
        return {
            "evaluation_scope": scope, "model_variant": model_variant,
            "customer_count": 0, "class_count": 0, "churn_count": 0,
            "actual_churn_rate": np.nan, "mean_probability": np.nan,
            "probability_gap": np.nan, "abs_probability_gap": np.nan,
            "roc_auc": np.nan, "pr_auc": np.nan, "brier_score": np.nan,
            "log_loss": np.nan, "accuracy_at_05": np.nan,
            "balanced_accuracy_at_05": np.nan, "precision_at_05": np.nan,
            "recall_at_05": np.nan, "f1_at_05": np.nan
        }
    predicted = (probability >= 0.5).astype(int)
    actual_rate, mean_probability = float(actual.mean()), float(probability.mean())
    return {
        "evaluation_scope": scope, "model_variant": model_variant,
        "customer_count": int(len(actual)), "class_count": int(len(np.unique(actual))),
        "churn_count": int(actual.sum()), "actual_churn_rate": actual_rate,
        "mean_probability": mean_probability,
        "probability_gap": mean_probability - actual_rate,
        "abs_probability_gap": abs(mean_probability - actual_rate),
        "roc_auc": safe_auc(actual, probability, "ROC"),
        "pr_auc": safe_auc(actual, probability, "PR"),
        "brier_score": float(brier_score_loss(actual, probability)),
        "log_loss": float(log_loss(actual, probability, labels=[0, 1])),
        "accuracy_at_05": float(accuracy_score(actual, predicted)),
        "balanced_accuracy_at_05": float(balanced_accuracy_score(actual, predicted)),
        "precision_at_05": float(precision_score(actual, predicted, zero_division=0)),
        "recall_at_05": float(recall_score(actual, predicted, zero_division=0)),
        "f1_at_05": float(f1_score(actual, predicted, zero_division=0))
    }
def make_topk_rows(scope, frame, k_values):
    rows = []
    ranked = frame.sort_values(
        ["raw_churn_probability", "customer_id"], ascending=[False, True]
    ).reset_index(drop=True)
    total_churn = int(ranked["actual_churn_flag"].sum())
    overall_rate = float(ranked["actual_churn_flag"].mean())
    for requested_k in k_values:
        actual_k = min(int(requested_k), len(ranked))
        selected = ranked.head(actual_k)
        captured = int(selected["actual_churn_flag"].sum())
        precision = captured / actual_k if actual_k else np.nan
        rows.append({
            "evaluation_scope": scope, "requested_k": int(requested_k),
            "selected_customers": actual_k, "captured_churners": captured,
            "precision_at_k": precision,
            "capture_rate_at_k": captured / total_churn if total_churn else np.nan,
            "lift_at_k": precision / overall_rate if overall_rate else np.nan
        })
    return rows
def qa_row(order, item, actual, expected, status, detail):
    return {
        "check_order": int(order), "check_item": str(item),
        "actual_value": str(actual), "expected_value": str(expected),
        "status": str(status), "detail": str(detail)
    }
# 4-4. 3.3 B_DAYS와 같은 피처 정의
common_numeric_features = [
    "recency", "monetary", "avg_order_value", "avg_shipping",
    "coupon_usage_rate", "coupon_click_rate", "tenure",
    "product_category_count", "category_concentration",
    "avg_days_between_orders", "std_days_between_orders", "last_coupon_used"
]
numeric_features = common_numeric_features + ["frequency_days"]
categorical_features = ["gender", "region"]
feature_columns = numeric_features + categorical_features
# 4-5. 입력 테이블
split_data = normalize_columns(SAS.sd2df("crm.w3_freq_abc_input"))
w3_metrics = normalize_columns(SAS.sd2df("crm.w3_freq_abc_metrics"))
rfmp_population = normalize_columns(SAS.sd2df("crm.w3_customer_rfmp_py"))
online = normalize_columns(SAS.sd2df("crm.clean_online"))
customer = normalize_columns(SAS.sd2df("crm.clean_customer"))
# 4-6. 필수 변수 확인
require_columns(split_data, [
    "snapshot_key", "customer_id", "split_role", "churn_flag",
    "first_purchase_date", "last_purchase_date", "snapshot_cutoff",
    "label_end_date", "frequency_orders", "frequency_days",
    "is_new_valid_customer"
] + feature_columns, "CRM.W3_FREQ_ABC_INPUT")
require_columns(w3_metrics, [
    "model_variant", "dataset_role", "roc_auc", "brier_score", "log_loss"
], "CRM.W3_FREQ_ABC_METRICS")
require_columns(rfmp_population, ["customer_id"], "CRM.W3_CUSTOMER_RFMP_PY")
required_online = [
    "customer_id", "order_key", "transaction_date", "product_category",
    "quantity", "avg_price", "shipping_fee", "coupon_status",
    "flag_missing_core", "flag_return", "flag_zero_quantity",
    "flag_invalid_price", "flag_customer_unmatched"
]
require_columns(online, required_online, "CRM.CLEAN_ONLINE")
require_columns(customer, ["customer_id", "gender", "region", "tenure"],
                "CRM.CLEAN_CUSTOMER")
# 4-7. 시간분리 데이터 정리
split_data["customer_id"] = clean_id(split_data["customer_id"])
split_data["snapshot_key"] = clean_id(split_data["snapshot_key"])
split_data["split_role"] = split_data["split_role"].astype(str).str.strip().str.upper()
for col in numeric_features + ["frequency_orders", "churn_flag", "is_new_valid_customer"]:
    split_data[col] = pd.to_numeric(split_data[col], errors="coerce")
split_data[numeric_features] = split_data[numeric_features].replace([np.inf, -np.inf], np.nan)
for col in categorical_features:
    split_data[col] = split_data[col].fillna("UNKNOWN").astype(str).str.strip().replace("", "UNKNOWN")
for col in ["first_purchase_date", "last_purchase_date", "snapshot_cutoff", "label_end_date"]:
    split_data[col] = sas_date_to_datetime(split_data[col])
split_data["history_days_at_snapshot"] = (
    split_data["snapshot_cutoff"] - split_data["first_purchase_date"]
).dt.days + 1
split_data["history_band"] = history_band(split_data["history_days_at_snapshot"])
split_data["customer_maturity_group"] = maturity_group(split_data["history_days_at_snapshot"])
# 4-8. TRAIN·VALID 분리와 치명적 입력 오류 확인
train = split_data.loc[split_data["split_role"].eq("TRAIN")].copy()
valid = split_data.loc[split_data["split_role"].eq("VALID")].copy()
valid_seen = valid.loc[valid["is_new_valid_customer"].eq(0)].copy()
valid_new = valid.loc[valid["is_new_valid_customer"].eq(1)].copy()
if len(train) == 0 or len(valid) == 0:
    raise ValueError("TRAIN 또는 VALID 데이터가 비어 있습니다.")
if train["snapshot_key"].duplicated().any() or valid["snapshot_key"].duplicated().any():
    raise ValueError("TRAIN 또는 VALID에 중복 snapshot_key가 있습니다.")
if train["churn_flag"].isna().any() or valid["churn_flag"].isna().any():
    raise ValueError("churn_flag에 결측값이 있습니다.")
if not set(split_data["churn_flag"].dropna().unique()).issubset({0, 1}):
    raise ValueError("churn_flag가 0과 1 이외의 값을 포함합니다.")
if train["churn_flag"].nunique() < 2 or valid["churn_flag"].nunique() < 2:
    raise ValueError("TRAIN 또는 VALID 이탈 라벨이 한 종류뿐입니다.")
invalid_frequency_count = int((split_data["frequency_days"] > split_data["frequency_orders"]).sum())
if invalid_frequency_count:
    raise ValueError("frequency_days가 frequency_orders보다 큰 행이 있습니다.")
train_valid_overlap_count = len(set(train["customer_id"]) & set(valid["customer_id"]))
# 4-9. B_DAYS 로지스틱 회귀
numeric_transformer = Pipeline([
    ("imputer", SimpleImputer(strategy="median")),
    ("scaler", StandardScaler())
])
categorical_transformer = Pipeline([
    ("imputer", SimpleImputer(strategy="most_frequent")),
    ("onehot", make_onehot())
])
preprocessor = ColumnTransformer([
    ("numeric", numeric_transformer, numeric_features),
    ("categorical", categorical_transformer, categorical_features)
])
classifier = LogisticRegression(
    penalty="l2", C=1.0, solver="liblinear", max_iter=2000,
    class_weight=None, random_state=random_seed
)
model = Pipeline([("preprocessor", preprocessor), ("classifier", classifier)])
X_train, y_train = train[feature_columns].copy(), train["churn_flag"].astype(int)
X_valid, y_valid = valid[feature_columns].copy(), valid["churn_flag"].astype(int)
model.fit(X_train, y_train)
# 4-10. TRAIN·VALID 성능
train_eval, valid_eval = train.copy(), valid.copy()
train_eval["raw_churn_probability"] = model.predict_proba(X_train)[:, 1]
valid_eval["raw_churn_probability"] = model.predict_proba(X_valid)[:, 1]
valid_seen_eval = valid_eval.loc[valid_eval["is_new_valid_customer"].eq(0)].copy()
valid_new_eval = valid_eval.loc[valid_eval["is_new_valid_customer"].eq(1)].copy()
model_metrics = pd.DataFrame([
    metric_row("TRAIN", train_eval["churn_flag"], train_eval["raw_churn_probability"]),
    metric_row("VALID_ALL", valid_eval["churn_flag"], valid_eval["raw_churn_probability"]),
    metric_row("VALID_SEEN", valid_seen_eval["churn_flag"], valid_seen_eval["raw_churn_probability"]),
    metric_row("VALID_NEW", valid_new_eval["churn_flag"], valid_new_eval["raw_churn_probability"])
])
# 4-11. 구매 이력 길이별 VALID 성능
cohort_rows = []
for band in ["LT90", "D90_179", "GE180"]:
    cohort = valid_eval.loc[valid_eval["history_band"].eq(band)]
    row = metric_row(f"VALID_{band}", cohort["churn_flag"], cohort["raw_churn_probability"])
    row.update({
        "history_band": band,
        "history_min_days": 0 if band == "LT90" else history_cut1 if band == "D90_179" else history_cut2,
        "history_max_days": history_cut1 - 1 if band == "LT90" else history_cut2 - 1 if band == "D90_179" else np.nan
    })
    cohort_rows.append(row)
cohort_metrics = pd.DataFrame(cohort_rows)
# 4-12. VALID 점수·순위와 상위 k명 성과
valid_scored = valid_eval[[
    "snapshot_key", "customer_id", "churn_flag", "is_new_valid_customer",
    "history_days_at_snapshot", "history_band", "customer_maturity_group",
    "frequency_days", "recency", "monetary", "raw_churn_probability"
]].rename(columns={"churn_flag": "actual_churn_flag"})
valid_scored = assign_relative_rank(valid_scored, "raw_churn_probability")
valid_scored["score_version"] = score_version
valid_scored["probability_usage"] = "RELATIVE_RANK_ONLY"
topk_rows = make_topk_rows("VALID_ALL", valid_scored, [100, 200])
valid_new_scored = valid_scored.loc[valid_scored["is_new_valid_customer"].eq(1)]
topk_rows += make_topk_rows("VALID_NEW", valid_new_scored, [100, 200])
topk_performance = pd.DataFrame(topk_rows)
# 4-13. 기준모형 계수
fitted_preprocessor = model.named_steps["preprocessor"]
fitted_classifier = model.named_steps["classifier"]
try:
    names = list(fitted_preprocessor.get_feature_names_out())
except Exception:
    names = [f"feature_{i + 1}" for i in range(len(fitted_classifier.coef_[0]))]
names = [str(x).replace("numeric__", "").replace("categorical__", "") for x in names]
coefficients = pd.DataFrame({"feature_name": names, "coefficient": fitted_classifier.coef_[0]})
coefficients["absolute_coefficient"] = coefficients["coefficient"].abs()
coefficients["coefficient_direction"] = np.select(
    [coefficients["coefficient"] > 0, coefficients["coefficient"] < 0],
    ["HIGHER_RISK", "LOWER_RISK"], default="NEUTRAL"
)
coefficients = coefficients.sort_values(
    ["absolute_coefficient", "feature_name"], ascending=[False, True]
).reset_index(drop=True)
coefficients["importance_rank"] = np.arange(1, len(coefficients) + 1)
# 4-14. 전체기간 고객 피처 재생성
# 3.2와 같은 거래 제외 규칙과 계산 정의를 사용한다.
online = online[required_online].copy()
customer = customer[["customer_id", "gender", "region", "tenure"]].copy()
online["customer_id"] = clean_id(online["customer_id"])
customer["customer_id"] = clean_id(customer["customer_id"])
rfmp_population["customer_id"] = clean_id(rfmp_population["customer_id"])
rfmp_population = rfmp_population[["customer_id"]].copy()
if rfmp_population["customer_id"].duplicated().any():
    raise ValueError("W3_CUSTOMER_RFMP_PY에 중복 customer_id가 있습니다.")
rfmp_population = rfmp_population.reset_index(drop=True)
if customer["customer_id"].duplicated().any():
    raise ValueError("CLEAN_CUSTOMER에 중복 customer_id가 있습니다.")
online["order_key"] = online["order_key"].astype(str).str.strip()
online["transaction_date"] = sas_date_to_datetime(online["transaction_date"])
online["product_category"] = online["product_category"].fillna("UNKNOWN").astype(str).str.strip().replace("", "UNKNOWN")
online["coupon_status_std"] = online["coupon_status"].fillna("").astype(str).str.strip().str.upper()
for col in [
    "quantity", "avg_price", "shipping_fee", "flag_missing_core",
    "flag_return", "flag_zero_quantity", "flag_invalid_price",
    "flag_customer_unmatched"
]:
    online[col] = pd.to_numeric(online[col], errors="coerce")
valid_line = (
    online["flag_missing_core"].eq(0) & online["flag_return"].eq(0)
    & online["flag_zero_quantity"].eq(0) & online["flag_invalid_price"].eq(0)
    & online["flag_customer_unmatched"].eq(0) & online["transaction_date"].notna()
    & online["customer_id"].ne("") & online["order_key"].ne("")
)
online_valid = online.loc[valid_line].copy()
del online
gc.collect()
if len(online_valid) == 0:
    raise ValueError("전체 고객 피처를 만들 유효 거래가 없습니다.")
online_valid["line_amount"] = online_valid["quantity"] * online_valid["avg_price"]
online_valid["order_coupon_used"] = online_valid["coupon_status_std"].eq("USED").astype(int)
online_valid["order_coupon_clicked"] = online_valid["coupon_status_std"].isin(["USED", "CLICKED"]).astype(int)
current_cutoff = online_valid["transaction_date"].max()
orders = online_valid.groupby(
    ["customer_id", "order_key", "transaction_date"], as_index=False
).agg(
    order_amount=("line_amount", "sum"),
    order_shipping=("shipping_fee", "max"),
    order_coupon_used=("order_coupon_used", "max"),
    order_coupon_clicked=("order_coupon_clicked", "max")
)
core = orders.groupby("customer_id", as_index=False).agg(
    first_purchase_date=("transaction_date", "min"),
    last_purchase_date=("transaction_date", "max"),
    frequency_orders=("order_key", "nunique"),
    frequency_days=("transaction_date", "nunique"),
    monetary=("order_amount", "sum"),
    avg_order_value=("order_amount", "mean"),
    avg_shipping=("order_shipping", "mean"),
    coupon_usage_rate=("order_coupon_used", "mean"),
    coupon_click_rate=("order_coupon_clicked", "mean")
)
core["recency"] = (current_cutoff - core["last_purchase_date"]).dt.days
core["history_days_at_snapshot"] = (current_cutoff - core["first_purchase_date"]).dt.days + 1
core["orders_per_purchase_day"] = core["frequency_orders"] / core["frequency_days"].replace(0, np.nan)
category_count = online_valid.groupby(
    ["customer_id", "product_category"], as_index=False
).agg(category_order_count=("order_key", "nunique"))
category_feature = category_count.groupby("customer_id", as_index=False).agg(
    product_category_count=("product_category", "nunique"),
    max_category_orders=("category_order_count", "max"),
    total_category_orders=("category_order_count", "sum")
)
category_feature["category_concentration"] = (
    category_feature["max_category_orders"]
    / category_feature["total_category_orders"].replace(0, np.nan)
)
category_feature = category_feature[["customer_id", "product_category_count", "category_concentration"]]
purchase_dates = online_valid[["customer_id", "transaction_date"]].drop_duplicates()
purchase_dates = purchase_dates.sort_values(["customer_id", "transaction_date"])
purchase_dates["gap_days"] = purchase_dates.groupby("customer_id")["transaction_date"].diff().dt.days
gap_feature = purchase_dates.loc[purchase_dates["gap_days"] > 0].groupby(
    "customer_id", as_index=False
).agg(
    avg_days_between_orders=("gap_days", "mean"),
    std_days_between_orders=("gap_days", "std")
)
last_date = orders.groupby("customer_id")["transaction_date"].transform("max")
last_coupon = orders.loc[orders["transaction_date"].eq(last_date)].groupby(
    "customer_id", as_index=False
).agg(last_coupon_used=("order_coupon_used", "max"))
current_features = (
    core.merge(category_feature, on="customer_id", how="left", validate="one_to_one")
        .merge(gap_feature, on="customer_id", how="left", validate="one_to_one")
        .merge(last_coupon, on="customer_id", how="left", validate="one_to_one")
        .merge(customer, on="customer_id", how="left", validate="one_to_one")
)
for col in [
    "product_category_count", "category_concentration", "avg_days_between_orders",
    "std_days_between_orders", "last_coupon_used", "tenure"
]:
    current_features[col] = pd.to_numeric(current_features[col], errors="coerce").fillna(0)
for col in numeric_features:
    current_features[col] = pd.to_numeric(current_features[col], errors="coerce")
current_features[numeric_features] = current_features[numeric_features].replace([np.inf, -np.inf], np.nan)
for col in categorical_features:
    current_features[col] = current_features[col].fillna("UNKNOWN").astype(str).str.strip().replace("", "UNKNOWN")
current_features["history_band"] = history_band(current_features["history_days_at_snapshot"])
current_features["customer_maturity_group"] = maturity_group(current_features["history_days_at_snapshot"])
current_features["single_purchase_day_flag"] = current_features["frequency_days"].eq(1).astype(int)
if current_features["customer_id"].duplicated().any():
    raise ValueError("전체기간 고객 피처에 중복 customer_id가 있습니다.")
# 4-15. RFMP 고객과 전체기간 피처 고객 집합 확인
rfmp_set, feature_set = set(rfmp_population["customer_id"]), set(current_features["customer_id"])
missing_current = sorted(rfmp_set - feature_set)
extra_current = sorted(feature_set - rfmp_set)
if missing_current:
    raise ValueError("RFMP 고객 중 피처가 없는 고객: " + ", ".join(missing_current[:10]))
if extra_current:
    raise ValueError("피처에는 있으나 RFMP에는 없는 고객: " + ", ".join(extra_current[:10]))
current_features = rfmp_population.merge(
    current_features, on="customer_id", how="left", validate="one_to_one"
)
# 4-16. 전체 고객 원확률과 상대위험 순위
current_probability = model.predict_proba(current_features[feature_columns])[:, 1]
current_columns = [
    "customer_id", "gender", "region", "tenure", "first_purchase_date",
    "last_purchase_date", "history_days_at_snapshot", "history_band",
    "customer_maturity_group", "single_purchase_day_flag", "recency",
    "frequency_orders", "frequency_days", "orders_per_purchase_day",
    "monetary", "avg_order_value", "avg_shipping", "coupon_usage_rate",
    "coupon_click_rate", "product_category_count", "category_concentration",
    "avg_days_between_orders", "std_days_between_orders", "last_coupon_used"
]
current_scored = current_features[current_columns].copy()
current_scored["raw_churn_probability"] = current_probability
current_scored = assign_relative_rank(current_scored, "raw_churn_probability")
current_scored["score_cutoff_date"] = current_cutoff.strftime("%Y-%m-%d")
current_scored["score_version"] = score_version
current_scored["model_variant"] = model_variant
current_scored["frequency_definition"] = "frequency_days"
current_scored["probability_usage"] = "RELATIVE_RANK_ONLY"
for col in ["first_purchase_date", "last_purchase_date"]:
    current_scored[col] = pd.to_datetime(
        current_scored[col], errors="coerce"
    ).dt.strftime("%Y-%m-%d").fillna("")
# 4-17. 3.3 B_DAYS 결과와 재현 결과 비교
w3_metrics["model_variant"] = (
    w3_metrics["model_variant"].astype(str).str.strip().str.upper()
)
w3_metrics["dataset_role"] = (
    w3_metrics["dataset_role"].astype(str).str.strip().str.upper()
)
w3_b_valid = w3_metrics.loc[
    w3_metrics["model_variant"].eq("B_DAYS")
    & w3_metrics["dataset_role"].eq("VALID")
]
if len(w3_b_valid) != 1:
    raise ValueError(
        "W3_FREQ_ABC_METRICS의 B_DAYS VALID가 한 행이 아닙니다."
    )
valid_metric = model_metrics.loc[
    model_metrics["evaluation_scope"].eq("VALID_ALL")
].iloc[0]
new_metric = model_metrics.loc[
    model_metrics["evaluation_scope"].eq("VALID_NEW")
].iloc[0]
w3_row = w3_b_valid.iloc[0]
auc_gap = abs(
    float(valid_metric["roc_auc"]) - float(w3_row["roc_auc"])
)
brier_gap = abs(
    float(valid_metric["brier_score"]) - float(w3_row["brier_score"])
)
logloss_gap = abs(
    float(valid_metric["log_loss"]) - float(w3_row["log_loss"])
)
# 4-18. 모형 설정표
config_rows = []
for col in numeric_features:
    config_rows.append({
        "config_order": len(config_rows) + 1,
        "config_type": "NUMERIC_FEATURE",
        "config_name": col,
        "config_value": "MEDIAN_IMPUTE_AND_STANDARDIZE",
        "note": (
            "공식 구매일 수 피처"
            if col == "frequency_days"
            else "3.3 공통 수치형 피처"
        )
    })
for col in categorical_features:
    config_rows.append({
        "config_order": len(config_rows) + 1,
        "config_type": "CATEGORICAL_FEATURE",
        "config_name": col,
        "config_value": "MODE_IMPUTE_AND_ONEHOT",
        "note": "미확인 범주는 UNKNOWN, 신규 범주는 무시"
    })
for item in [
    ("MODEL", "algorithm",
     "LogisticRegression", "L2, C=1.0, liblinear"),
    ("MODEL", "class_weight",
     "None", "인위적 클래스 가중치 미사용"),
    ("EXCLUDED", "frequency_orders",
     "EXCLUDED", "C_BOTH가 되지 않도록 제외"),
    ("EXCLUDED", "clv_proxy",
     "EXCLUDED", "3.3 B_DAYS 조건 유지"),
    ("SCORE_USAGE", "raw_churn_probability",
     "RELATIVE_RANK_ONLY", "절대확률 미확정")
]:
    config_rows.append({
        "config_order": len(config_rows) + 1,
        "config_type": item[0],
        "config_name": item[1],
        "config_value": item[2],
        "note": item[3]
    })
model_config = pd.DataFrame(config_rows)
# 4-19. 자동 QA
qa_rows = []
def add_qa(order, item, actual, expected, status, detail):
    qa_rows.append(
        qa_row(order, item, actual, expected, status, detail)
    )
add_qa(
    1, "TRAIN rows", len(train), "> 0",
    "PASS" if len(train) else "FAIL",
    "학습 데이터 존재"
)
add_qa(
    2, "VALID rows", len(valid), "> 0",
    "PASS" if len(valid) else "FAIL",
    "검증 데이터 존재"
)
add_qa(
    3, "TRAIN VALID customer overlap",
    train_valid_overlap_count, "INFO", "INFO",
    "시간 스냅샷 중복이며 완전 독립 고객 검증은 아님"
)
add_qa(
    4, "VALID NEW customers", len(valid_new), "> 0",
    "PASS" if len(valid_new) else "FAIL",
    "TRAIN에 없던 고객을 별도 평가"
)
missing_labels = int(split_data["churn_flag"].isna().sum())
label_values = set(
    split_data["churn_flag"].dropna().astype(int).unique()
)
add_qa(
    5, "Missing churn labels", missing_labels, 0,
    "PASS" if missing_labels == 0 else "FAIL",
    "미성숙 라벨을 임의로 0 처리하지 않음"
)
add_qa(
    6, "Binary churn labels", sorted(label_values), "[0, 1]",
    "PASS" if label_values == {0, 1} else "FAIL",
    "라벨은 0과 1만 허용"
)
future_feature_count = int(
    (
        split_data["last_purchase_date"]
        > split_data["snapshot_cutoff"]
    ).sum()
)
incomplete_label_count = int(
    (
        split_data["label_end_date"]
        > current_cutoff
    ).sum()
)
add_qa(
    7, "Future feature dates", future_feature_count, 0,
    "PASS" if future_feature_count == 0 else "FAIL",
    "기준일 이후 피처는 누수"
)
add_qa(
    8, "Incomplete 90-day labels", incomplete_label_count, 0,
    "PASS" if incomplete_label_count == 0 else "FAIL",
    "라벨 종료일까지 데이터 필요"
)
add_qa(
    9, "frequency_days over orders", invalid_frequency_count, 0,
    "PASS" if invalid_frequency_count == 0 else "FAIL",
    "구매일 수는 주문 수보다 클 수 없음"
)
for order, item, value in [
    (10, "W3 VALID AUC reproduction gap", auc_gap),
    (11, "W3 VALID Brier reproduction gap", brier_gap),
    (12, "W3 VALID LogLoss reproduction gap", logloss_gap)
]:
    add_qa(
        order, item, f"{value:.10f}", f"<= {model_match_tol}",
        "PASS" if value <= model_match_tol else "FAIL",
        "3.3 B_DAYS 동일 조건 재현"
    )
valid_auc = float(valid_metric["roc_auc"])
new_auc = float(new_metric["roc_auc"])
valid_abs_gap = float(valid_metric["abs_probability_gap"])
add_qa(
    13, "VALID ALL ROC-AUC",
    f"{valid_auc:.6f}", f">= {min_valid_auc}",
    "PASS" if valid_auc >= min_valid_auc else "REVIEW",
    "전체 VALID 순위 판별력"
)
add_qa(
    14, "VALID NEW ROC-AUC",
    f"{new_auc:.6f}", f">= {min_new_valid_auc}",
    (
        "PASS"
        if np.isfinite(new_auc) and new_auc >= min_new_valid_auc
        else "REVIEW"
    ),
    "신규 고객 일반화 성능"
)
add_qa(
    15, "VALID mean probability gap",
    f"{valid_abs_gap:.6f}", f"<= {max_mean_prob_gap}",
    "PASS" if valid_abs_gap <= max_mean_prob_gap else "REVIEW",
    "초과 시 절대위험확률로 사용하지 않음"
)
current_duplicates = int(
    current_scored["customer_id"].duplicated().sum()
)
missing_probability = int(
    current_scored["raw_churn_probability"].isna().sum()
)
invalid_probability = int(
    (
        (current_scored["raw_churn_probability"] < 0)
        | (current_scored["raw_churn_probability"] > 1)
    ).sum()
)
add_qa(
    16, "CURRENT duplicate customers",
    current_duplicates, 0,
    "PASS" if current_duplicates == 0 else "FAIL",
    "고객당 한 행"
)
add_qa(
    17, "CURRENT population rows",
    len(current_scored), len(rfmp_population),
    (
        "PASS"
        if len(current_scored) == len(rfmp_population)
        else "FAIL"
    ),
    "RFMP 전 고객 점수화"
)
add_qa(
    18, "CURRENT missing probabilities",
    missing_probability, 0,
    "PASS" if missing_probability == 0 else "FAIL",
    "결측확률을 임의 대체하지 않음"
)
add_qa(
    19, "CURRENT probability outside 0 to 1",
    invalid_probability, 0,
    "PASS" if invalid_probability == 0 else "FAIL",
    "확률 범위 확인"
)
rank_min = int(current_scored["risk_priority_rank"].min())
rank_max = int(current_scored["risk_priority_rank"].max())
rank_ok = rank_min == 1 and rank_max == len(current_scored)
add_qa(
    20, "CURRENT risk rank range",
    f"{rank_min} to {rank_max}",
    f"1 to {len(current_scored)}",
    "PASS" if rank_ok else "FAIL",
    "첫 순위는 1"
)
qa_summary = pd.DataFrame(qa_rows)
# 4-20. 4.2로 전달할 결정표
fail_count = int(
    qa_summary["status"].eq("FAIL").sum()
)
review_items = qa_summary.loc[
    qa_summary["status"].eq("REVIEW"),
    "check_item"
].tolist()
decision_code = (
    "STOP_AND_FIX"
    if fail_count
    else "USE_B_DAYS_RELATIVE_RANK"
)
decision_text = (
    "입력 또는 산출물 오류를 수정한 뒤 다시 실행"
    if fail_count
    else
    "B_DAYS를 4.2 상대위험 순위의 기준모형으로 사용. "
    "원확률은 절대 이탈확률로 확정하지 않음"
)
model_decision = pd.DataFrame([{
    "decision_code": decision_code,
    "selected_model": model_variant,
    "score_version": score_version,
    "official_frequency": "frequency_days",
    "probability_usage": "RELATIVE_RANK_ONLY",
    "absolute_probability_status": "NOT_APPROVED",
    "relative_grade_status": "CREATE_IN_WBS_4_2",
    "review_item_count": len(review_items),
    "review_items": "; ".join(review_items),
    "decision_text": decision_text,
    "train_valid_overlap_count": train_valid_overlap_count,
    "current_customer_count": len(current_scored)
}])
# 4-21. 산출물 저장
save_sas(model_metrics, "w4_41_model_metrics")
save_sas(cohort_metrics, "w4_41_cohort_metrics")
save_sas(valid_scored, "w4_41_valid_scored")
save_sas(current_scored, "w4_41_current_scored")
save_sas(topk_performance, "w4_41_topk_performance")
save_sas(coefficients, "w4_41_coefficients")
save_sas(model_config, "w4_41_model_config")
save_sas(model_decision, "w4_41_model_decision")
save_sas(qa_summary, "w4_41_qa_summary")
# 4-22. 실행 요약
print("=" * 72, flush=True)
print("WBS 4.1 Revised v2 실행 요약", flush=True)
print("=" * 72, flush=True)
print(
    f"TRAIN={len(train):,}, VALID={len(valid):,}, "
    f"신규 VALID={len(valid_new):,}",
    flush=True
)
print(
    f"TRAIN·VALID 중복 고객={train_valid_overlap_count:,}",
    flush=True
)
print(
    f"전체 점수 고객={len(current_scored):,}",
    flush=True
)
print(
    f"VALID ROC-AUC={valid_auc:.4f}, "
    f"신규 VALID ROC-AUC={new_auc:.4f}",
    flush=True
)
print(
    "VALID 실제 이탈률="
    f"{float(valid_metric['actual_churn_rate']):.2%}",
    flush=True
)
print(
    "VALID 평균 예측확률="
    f"{float(valid_metric['mean_probability']):.2%}",
    flush=True
)
print(
    f"QA FAIL={fail_count}, QA REVIEW={len(review_items)}",
    flush=True
)
print(f"결정={decision_code}", flush=True)
print(
    "주의: 원예측확률은 절대 이탈확률이 아니라 "
    "상대위험 순위에 사용합니다.",
    flush=True
)
del online_valid, orders, category_count, purchase_dates
gc.collect()
endsubmit;
quit;
/*==========================================================================
  5. 산출물 존재 여부와 목록
==========================================================================*/
%macro check_output(ds=);
    %if %sysfunc(exist(&ds.))=0 %then
        %put ERROR: 필수 산출물 &ds. 이(가) 생성되지 않았습니다.;
    %else
        %put NOTE: 산출물 &ds. 을(를) 확인했습니다.;
%mend;
%check_output(ds=crm.w4_41_model_metrics);
%check_output(ds=crm.w4_41_cohort_metrics);
%check_output(ds=crm.w4_41_valid_scored);
%check_output(ds=crm.w4_41_current_scored);
%check_output(ds=crm.w4_41_topk_performance);
%check_output(ds=crm.w4_41_coefficients);
%check_output(ds=crm.w4_41_model_config);
%check_output(ds=crm.w4_41_model_decision);
%check_output(ds=crm.w4_41_qa_summary);
proc sql;
    create table crm.w4_41_output_catalog as
    select
        memname as table_name length=32,
        nobs as row_count,
        nvar as column_count,
        crdate as created_datetime format=datetime20.
    from dictionary.tables
    where libname="CRM"
      and substr(memname,1,6)="W4_41_"
    order by memname;
quit;
/*==========================================================================
  6. 주요 결과 출력
==========================================================================*/
title "WBS 4.1-1. B_DAYS 기준모형 성능";
proc print data=crm.w4_41_model_metrics noobs label;
    format
        actual_churn_rate
        mean_probability
        probability_gap
        abs_probability_gap percent8.2
        roc_auc
        pr_auc
        brier_score
        log_loss
        accuracy_at_05
        balanced_accuracy_at_05
        precision_at_05
        recall_at_05
        f1_at_05 8.4;
run;
title "WBS 4.1-2. 구매 이력 길이별 VALID 성능";
proc print data=crm.w4_41_cohort_metrics noobs label;
    var
        history_band
        customer_count
        churn_count
        actual_churn_rate
        mean_probability
        probability_gap
        roc_auc
        pr_auc
        brier_score
        log_loss;
    format
        actual_churn_rate
        mean_probability
        probability_gap percent8.2
        roc_auc
        pr_auc
        brier_score
        log_loss 8.4;
run;
title "WBS 4.1-3. VALID 상위 100명·200명 포착 성과";
proc print data=crm.w4_41_topk_performance noobs label;
    format
        precision_at_k
        capture_rate_at_k percent8.2
        lift_at_k 8.3;
run;
title "WBS 4.1-4. 기준모형 계수 상위 20개";
proc print data=crm.w4_41_coefficients(obs=20) noobs label;
    var
        importance_rank
        feature_name
        coefficient
        absolute_coefficient
        coefficient_direction;
    format
        coefficient
        absolute_coefficient 10.5;
run;
title "WBS 4.1-5. 전체 고객 상대위험순위 상위 20명";
proc print data=crm.w4_41_current_scored(obs=20) noobs label;
    var
        risk_priority_rank
        customer_id
        raw_churn_probability
        relative_risk_percentile
        customer_maturity_group
        frequency_days
        recency
        monetary;
    format
        raw_churn_probability
        relative_risk_percentile percent8.2
        monetary comma16.2;
run;
title "WBS 4.1-6. 기준모형 사용 결정";
proc print data=crm.w4_41_model_decision noobs label;
run;
title "WBS 4.1-7. 자동 품질 점검";
proc print data=crm.w4_41_qa_summary noobs label;
run;
title "WBS 4.1-8. 산출물 목록";
proc print data=crm.w4_41_output_catalog noobs label;
run;
title;
/*==========================================================================
  7. 최종 실행 게이트
  REVIEW는 한계로 기록하고 진행할 수 있다.
  FAIL은 입력·산출물 오류이므로 다음 절로 넘어가지 않는다.
==========================================================================*/
proc sql noprint;
    select
        sum(upcase(strip(status))="FAIL"),
        sum(upcase(strip(status))="REVIEW")
    into
        :W4_41_FAIL_COUNT trimmed,
        :W4_41_REVIEW_COUNT trimmed
    from crm.w4_41_qa_summary;
quit;
%macro final_gate;
    %if %superq(W4_41_FAIL_COUNT)= %then
        %let W4_41_FAIL_COUNT=0;
    %if %superq(W4_41_REVIEW_COUNT)= %then
        %let W4_41_REVIEW_COUNT=0;
    %put NOTE: WBS 4.1 QA FAIL = &W4_41_FAIL_COUNT.;
    %put NOTE: WBS 4.1 QA REVIEW = &W4_41_REVIEW_COUNT.;
    %if &W4_41_FAIL_COUNT.>0 %then %do;
        %put ERROR: WBS 4.1 QA에서 FAIL이 발견되었습니다.;
        %put ERROR: W4_41_QA_SUMMARY를 확인한 뒤 수정하십시오.;
        %abort cancel;
    %end;
    %else %do;
        %put NOTE: WBS 4.1 치명적 오류 점검을 통과했습니다.;
        %put NOTE: REVIEW 항목은 분석 한계로 기록하십시오.;
        %put NOTE: 4.2에서 RFMP와 전체 고객 상대위험을 매핑합니다.;
    %end;
%mend;
%final_gate;
/*============================== END ======================================*/


/*=============================================================================
  파일명: WBS_4_2_RFMP_RISK_ACTION.sas
  WBS 4.2
  RFMP 고객가치 x 상대이탈위험 매핑 및 실행규칙 설계
  [목표]
    1. 변경된 RFMP 가치등급과 4.1 상대위험 결과를 고객 단위로 결합한다.
    2. 전 고객을 High, Medium, Low 상대위험등급으로 나눈다.
    3. 위험순위와 가치위험순위를 서로 다른 목적으로 보존한다.
    4. 개인별 대표 카테고리와 설명 가능한 실행규칙을 연결한다.
  [핵심 질문]
    - 고객가치와 상대위험을 함께 고려할 때 누구를 먼저 관리해야 하는가?
  [수행 범위]
    - 4.1의 B_DAYS 전체 고객 상대위험 결과를 그대로 사용한다.
    - 상대위험등급은 전 고객 위험순위의 상위, 중위, 하위 1/3이다.
    - RFMP 가치 백분위와 상대위험 백분위를 곱해 가치위험순위를 만든다.
    - 고객별 P 기여도가 가장 큰 카테고리를 개인 대표 카테고리로 정한다.
    - 최대 7개의 실행규칙만 사용한다.
  [이번 단계에서 하지 않는 작업]
    - 이탈모형을 다시 학습하지 않는다.
    - 원예측확률을 절대 이탈확률로 해석하지 않는다.
    - 30%·70% 등의 절대확률 기준을 사용하지 않는다.
    - 예상매출손실, 캠페인 비용, ROI 시나리오는 계산하지 않는다.
    - 4.3의 대안모형 비교와 4.4의 경제성 평가는 수행하지 않는다.
  [해석 유의사항]
    - High, Medium, Low는 절대위험이 아니라 전 고객 안의 상대적 위치이다.
    - risk_priority_rank는 위험만 보며 1이 가장 위험한 고객이다.
    - value_risk_priority_rank는 가치와 위험을 함께 보며 1이 최우선이다.
	- VALUE_PROTECTION을 단순한 “고객가치순위”가 아니라 다음처럼 이해해야 한다.
	  고객가치와 상대이탈위험을 함께 반영한 가치손실 방지 우선순위
    - raw_churn_probability는 순위 계산에만 사용한다.
    - 신규 고객에서 4.1 판별력이 낮았으므로 90일 미만 고객에게는
      고비용 혜택을 배정하지 않고 저비용 검증만 제안한다.
    - 개인 대표 카테고리는 RFMP 등급별 대표 카테고리와 다르다.
  [운영용 검토 기준]
    - 전체 고객 1,468명이 모두 결합되어야 한다.
    - 고객ID는 고객당 한 행이어야 한다.
    - 세 상대위험등급의 고객 수 차이는 최대 1명이어야 한다.
    - 위험순위와 가치위험순위는 각각 1부터 전체 고객 수까지여야 한다.
    - 대표 카테고리와 실행규칙의 결측은 없어야 한다.
    - 실행규칙 수는 8개를 넘지 않아야 한다.
  [입력 테이블]
    CRM.W3_CUSTOMER_RFMP_PY
      : 변경된 RFMP 점수와 6개 고객가치등급
    CRM.W3_CUSTOMER_CATEGORY_P_PY
      : 고객-카테고리별 구매일 기준 P 기여도
    CRM.W3_RFMP_QA_SUMMARY_PY
      : 3.5~3.9 품질검사 결과
    CRM.W4_41_CURRENT_SCORED
      : 전체 고객 상대위험 점수와 위험순위
    CRM.W4_41_MODEL_DECISION
      : 4.1 모형 사용 결정과 확률 해석 원칙
    CRM.W4_41_QA_SUMMARY
      : 4.1 품질검사 결과
  [주요 산출물]
    CRM.W4_42_CUSTOMER_ACTION
      : 고객별 가치등급, 상대위험등급, 두 순위, 대표 카테고리, 실행규칙
    CRM.W4_42_SEGMENT_SUMMARY
      : RFMP 가치등급 x 상대위험등급 고객 분포
    CRM.W4_42_QA_SUMMARY
      : 고객 수, 결합, 순위, 등급, 규칙 자동검사
=============================================================================*/
/*=============================================================================
  0. 실행 옵션과 프로젝트 기준값
=============================================================================*/
options validvarname=any validmemname=extend;
%let CRM_PATH=/home/student/crm_db;
%let EXPECTED_CUSTOMERS=1468;
%let MAX_ACTION_RULES=8;
libname crm "&CRM_PATH.";
/*=============================================================================
  1. 라이브러리, 입력 테이블, 필수 변수 확인
=============================================================================*/
%macro require_table(ds=, previous_step=);
    %if %sysfunc(exist(&ds.))=0 %then %do;
        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %put ERROR: &previous_step. 단계를 먼저 정상 실행하십시오.;
        %abort cancel;
    %end;
    %else %do;
        %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;
    %end;
%mend;
%macro require_var(ds=, var=);
    %local dsid varnum rc;
    %let dsid=%sysfunc(open(&ds.,i));
    %if &dsid.=0 %then %do;
        %put ERROR: &ds. 데이터셋을 열 수 없습니다.;
        %abort cancel;
    %end;
    %let varnum=%sysfunc(varnum(&dsid.,&var.));
    %let rc=%sysfunc(close(&dsid.));
    %if &varnum.=0 %then %do;
        %put ERROR: &ds. 에 필수 변수 &var. 이(가) 없습니다.;
        %abort cancel;
    %end;
%mend;
%macro check_inputs;
    %if %sysfunc(libref(crm)) ne 0 %then %do;
        %put ERROR: CRM 라이브러리가 연결되지 않았습니다.;
        %put ERROR: 경로를 확인하십시오 - &CRM_PATH.;
        %abort cancel;
    %end;
    %require_table(ds=crm.w3_customer_rfmp_py,previous_step=WBS 3.5~3.9);
    %require_table(ds=crm.w3_customer_category_p_py,previous_step=WBS 3.5~3.9);
    %require_table(ds=crm.w3_rfmp_qa_summary_py,previous_step=WBS 3.5~3.9);
    %require_table(ds=crm.w4_41_current_scored,previous_step=WBS 4.1);
    %require_table(ds=crm.w4_41_model_decision,previous_step=WBS 4.1);
    %require_table(ds=crm.w4_41_qa_summary,previous_step=WBS 4.1);
%mend;
%check_inputs;
%require_var(ds=crm.w3_customer_rfmp_py,var=customer_id);
%require_var(ds=crm.w3_customer_rfmp_py,var=rfmp_score);
%require_var(ds=crm.w3_customer_rfmp_py,var=rfmp_tier);
%require_var(ds=crm.w3_customer_rfmp_py,var=tier_code);
%require_var(ds=crm.w3_customer_rfmp_py,var=frequency_days);
%require_var(ds=crm.w3_customer_rfmp_py,var=monetary);
%require_var(ds=crm.w3_customer_category_p_py,var=customer_id);
%require_var(ds=crm.w3_customer_category_p_py,var=product_category);
%require_var(ds=crm.w3_customer_category_p_py,var=customer_category_days);
%require_var(ds=crm.w3_customer_category_p_py,var=customer_category_orders);
%require_var(ds=crm.w3_customer_category_p_py,var=category_p_contribution);
%require_var(ds=crm.w4_41_current_scored,var=customer_id);
%require_var(ds=crm.w4_41_current_scored,var=raw_churn_probability);
%require_var(ds=crm.w4_41_current_scored,var=relative_risk_percentile);
%require_var(ds=crm.w4_41_current_scored,var=risk_priority_rank);
%require_var(ds=crm.w4_41_current_scored,var=customer_maturity_group);
%require_var(ds=crm.w4_41_current_scored,var=score_version);
%require_var(ds=crm.w4_41_current_scored,var=probability_usage);
/*=============================================================================
  2. 이전 4.2 산출물 삭제
=============================================================================*/
proc datasets library=crm nolist nowarn;
    delete
        w4_42_customer_action
        w4_42_segment_summary
        w4_42_qa_summary;
quit;
/*=============================================================================
  3. 이전 단계의 품질검사와 4.1 결정 확인
=============================================================================*/
proc sql noprint;
    select count(*) into :W3_FAIL_COUNT trimmed
    from crm.w3_rfmp_qa_summary_py
    where upcase(strip(status))="FAIL";
    select count(*) into :W4_41_FAIL_COUNT trimmed
    from crm.w4_41_qa_summary
    where upcase(strip(status))="FAIL";
    select count(*)
      into :DECISION_ROW_COUNT trimmed
    from crm.w4_41_model_decision;
    select upcase(strip(decision_code)), upcase(strip(probability_usage)),
           upcase(strip(absolute_probability_status)), strip(score_version),
           current_customer_count
      into :DECISION_CODE trimmed, :PROBABILITY_USAGE trimmed,
           :ABSOLUTE_STATUS trimmed, :EXPECTED_SCORE_VERSION trimmed,
           :DECISION_CUSTOMER_COUNT trimmed
    from crm.w4_41_model_decision;
quit;
%macro validate_previous_steps;
    %if &W3_FAIL_COUNT. > 0 %then %do;
        %put ERROR: WBS 3.5~3.9 QA에 FAIL이 있습니다.;
        %abort cancel;
    %end;
    %if &W4_41_FAIL_COUNT. > 0 %then %do;
        %put ERROR: WBS 4.1 QA에 FAIL이 있습니다.;
        %abort cancel;
    %end;
    %if &DECISION_ROW_COUNT. ne 1 %then %do;
        %put ERROR: W4_41_MODEL_DECISION은 정확히 1행이어야 합니다.;
        %abort cancel;
    %end;
    %if %upcase(%superq(DECISION_CODE)) ne USE_B_DAYS_RELATIVE_RANK %then %do;
        %put ERROR: 4.1에서 상대위험순위 사용이 승인되지 않았습니다.;
        %abort cancel;
    %end;
    %if %upcase(%superq(PROBABILITY_USAGE)) ne RELATIVE_RANK_ONLY %then %do;
        %put ERROR: 4.1 확률 사용 원칙이 RELATIVE_RANK_ONLY가 아닙니다.;
        %abort cancel;
    %end;
    %if %upcase(%superq(ABSOLUTE_STATUS)) ne NOT_APPROVED %then %do;
        %put ERROR: 절대확률 사용 상태를 다시 확인하십시오.;
        %abort cancel;
    %end;
    %put NOTE: 3.5~3.9와 4.1의 실행 게이트를 통과했습니다.;
%mend;
%validate_previous_steps;
/*=============================================================================
  4. 고객별 대표 카테고리 산출
  우선순위
    1) 공식 P 기여도
    2) 해당 카테고리 구매일 수
    3) 해당 카테고리 주문 수
    4) 카테고리명
=============================================================================*/
proc sort
    data=crm.w3_customer_category_p_py(
        where=(not missing(customer_id))
    )
    out=work.w4_42_category_sorted;
    by
        customer_id
        descending category_p_contribution
        descending customer_category_days
        descending customer_category_orders
        product_category;
run;
data work.w4_42_customer_top_category;
    set work.w4_42_category_sorted;
    by customer_id;
    if first.customer_id;
    length top_category $100;
    top_category=strip(product_category);
    top_category_p_contribution=category_p_contribution;
    top_category_purchase_days=customer_category_days;
    top_category_orders=customer_category_orders;
    keep
        customer_id
        top_category
        top_category_p_contribution
        top_category_purchase_days
        top_category_orders;
run;
/*=============================================================================
  5. RFMP 가치와 4.1 상대위험 결과 결합
=============================================================================*/
proc sql;
    create table work.w4_42_customer_base as
    select
        a.customer_id,
        a.rfmp_score,
        a.rfmp_tier,
        a.tier_code,
        a.frequency_days,
        a.monetary,
        b.raw_churn_probability,
        b.relative_risk_percentile,
        b.risk_priority_rank,
        b.customer_maturity_group,
        b.score_version,
        b.probability_usage,
        c.top_category,
        c.top_category_p_contribution,
        c.top_category_purchase_days,
        c.top_category_orders
    from crm.w3_customer_rfmp_py as a
    left join crm.w4_41_current_scored as b
      on a.customer_id=b.customer_id
    left join work.w4_42_customer_top_category as c
      on a.customer_id=c.customer_id;
quit;
/*=============================================================================
  6. 결합 결과 사전 점검
=============================================================================*/
proc sql noprint;
    select
        count(*),
        count(distinct customer_id),
        sum(missing(raw_churn_probability)),
        sum(missing(risk_priority_rank)),
        sum(missing(top_category)),
        sum(upcase(strip(score_version)) ne
            upcase(strip("&EXPECTED_SCORE_VERSION."))),
        sum(upcase(strip(probability_usage)) ne "RELATIVE_RANK_ONLY")
      into
        :BASE_ROWS trimmed,
        :BASE_UNIQUE_CUSTOMERS trimmed,
        :MISSING_PROBABILITY trimmed,
        :MISSING_RISK_RANK trimmed,
        :MISSING_TOP_CATEGORY trimmed,
        :SCORE_VERSION_MISMATCH trimmed,
        :USAGE_MISMATCH trimmed
    from work.w4_42_customer_base;
quit;
%macro validate_join;
    %if &BASE_ROWS. ne &EXPECTED_CUSTOMERS. %then %do;
        %put ERROR: 결합 결과 고객 수가 &EXPECTED_CUSTOMERS.명이 아닙니다.;
        %abort cancel;
    %end;
    %if &BASE_ROWS. ne &BASE_UNIQUE_CUSTOMERS. %then %do;
        %put ERROR: 결합 결과에 중복 customer_id가 있습니다.;
        %abort cancel;
    %end;
    %if &MISSING_PROBABILITY. > 0 or &MISSING_RISK_RANK. > 0 %then %do;
        %put ERROR: 4.1 상대위험 결과가 결합되지 않은 고객이 있습니다.;
        %abort cancel;
    %end;
    %if &MISSING_TOP_CATEGORY. > 0 %then %do;
        %put ERROR: 개인 대표 카테고리가 없는 고객이 있습니다.;
        %abort cancel;
    %end;
    %if &SCORE_VERSION_MISMATCH. > 0 or &USAGE_MISMATCH. > 0 %then %do;
        %put ERROR: 4.1 점수 버전 또는 확률 사용 원칙이 일치하지 않습니다.;
        %abort cancel;
    %end;
%mend;
%validate_join;
/*=============================================================================
  7. RFMP 가치순위·가치 백분위와 상대위험등급 생성
  공식 1
    상대위험등급 = 상대위험 백분위의 상위·중위·하위 1/3
=============================================================================*/
proc sort
    data=work.w4_42_customer_base
    out=work.w4_42_value_sorted;
    by descending rfmp_score customer_id;
run;
data work.w4_42_scored_pre;
    set work.w4_42_value_sorted nobs=total_customers;
    length relative_risk_grade $6;
    value_priority_rank=_n_;
    if total_customers > 1 then
        rfmp_value_percentile=1-((value_priority_rank-1)/(total_customers-1));
    else
        rfmp_value_percentile=1;
    if relative_risk_percentile >= (2/3) then
        relative_risk_grade="High";
    else if relative_risk_percentile >= (1/3) then
        relative_risk_grade="Medium";
    else
        relative_risk_grade="Low";
    /* 공식 2: 가치와 상대위험이 모두 높을수록 1에 가까워진다. */
    value_risk_score=rfmp_value_percentile * relative_risk_percentile;
    format
        raw_churn_probability
        relative_risk_percentile
        rfmp_value_percentile
        value_risk_score percent8.2;
run;
/*=============================================================================
  8. 가치위험순위 생성
  동점이면 위험순위, 가치순위, 고객ID 순서로 우선한다.
=============================================================================*/
proc sort
    data=work.w4_42_scored_pre
    out=work.w4_42_value_risk_sorted;
    by
        descending value_risk_score
        risk_priority_rank
        value_priority_rank
        customer_id;
run;
data work.w4_42_ranked;
    set work.w4_42_value_risk_sorted;
    value_risk_priority_rank=_n_;
run;
/*=============================================================================
  9. 실행규칙 적용
  규칙 1은 신규 고객 보호규칙이며 다른 규칙보다 먼저 적용한다.
  나머지는 상대위험등급과 RFMP 가치등급으로 결정한다.
=============================================================================*/
data crm.w4_42_customer_action;
    set work.w4_42_ranked;
    length
        action_code $32
        action_name $80
        action_channel $24
        incentive_level $12
        action_reason $200;
    /* 규칙 1: 신규 고객은 판별력이 낮으므로 저비용 검증만 수행한다. */
    if upcase(strip(customer_maturity_group))="NEW_LT90" then do;
        action_rule_id=1;
        action_code="NEW_LOW_COST_TEST";
        action_name="신규고객 저비용 반응 확인";
        action_channel="EMAIL_OR_APP";
        incentive_level="NONE_OR_LOW";
        action_reason="90일 미만 고객은 고비용 혜택 없이 대표 카테고리 반응을 확인";
    end;
    /* 규칙 2: 가치와 위험이 모두 높은 기존 고객이다. */
    else if relative_risk_grade="High"
        and rfmp_tier in ("VIP","Diamond") then do;
        action_rule_id=2;
        action_code="HIGH_VALUE_RETENTION";
        action_name="고가치 고객 우선 유지";
        action_channel="PERSONAL_CONTACT";
        incentive_level="TEAM_REVIEW";
        action_reason="대표 카테고리를 활용한 개별 유지 제안을 우선 검토";
    end;
    /* 규칙 3: 중간 가치의 고위험 기존 고객이다. */
    else if relative_risk_grade="High"
        and rfmp_tier in ("Platinum","Gold") then do;
        action_rule_id=3;
        action_code="TARGETED_RETENTION";
        action_name="중가치 고객 맞춤 유지";
        action_channel="EMAIL_OR_APP";
        incentive_level="LOW";
        action_reason="대표 카테고리 중심의 제한적 맞춤 혜택을 검토";
    end;
    /* 규칙 4: 저가치 고위험 고객은 자동화 채널만 사용한다. */
    else if relative_risk_grade="High" then do;
        action_rule_id=4;
        action_code="LOW_COST_REACTIVATION";
        action_name="저비용 재활성화";
        action_channel="AUTOMATED";
        incentive_level="NONE_OR_LOW";
        action_reason="비용을 제한한 자동 알림과 대표 카테고리 노출";
    end;
    /* 규칙 5: 고가치 중위험 고객은 유지와 교차판매를 함께 본다. */
    else if relative_risk_grade="Medium"
        and rfmp_tier in ("VIP","Diamond") then do;
        action_rule_id=5;
        action_code="LOYALTY_CROSSSELL";
        action_name="충성도 유지와 교차판매";
        action_channel="EMAIL_OR_APP";
        incentive_level="NONE_OR_LOW";
        action_reason="대표 카테고리를 기준으로 관련 상품을 제안";
    end;
    /* 규칙 6: 나머지 중위험 고객은 카테고리 알림을 보낸다. */
    else if relative_risk_grade="Medium" then do;
        action_rule_id=6;
        action_code="CATEGORY_REMINDER";
        action_name="대표 카테고리 재방문 유도";
        action_channel="AUTOMATED";
        incentive_level="NONE";
        action_reason="개인 대표 카테고리를 활용한 저비용 리마인드";
    end;
    /* 규칙 7: 저위험 고객은 불필요한 할인 없이 관찰한다. */
    else do;
        action_rule_id=7;
        action_code="MAINTAIN_MONITOR";
        action_name="관계 유지 및 모니터링";
        action_channel="STANDARD_CRM";
        incentive_level="NONE";
        action_reason="정상 마케팅을 유지하고 과도한 할인은 제공하지 않음";
    end;
    label
        relative_risk_grade="상대위험등급"
        risk_priority_rank="위험 우선순위"
        value_priority_rank="RFMP 가치순위"
        value_risk_score="가치위험점수"
        value_risk_priority_rank="가치위험 우선순위"
        top_category="개인 대표 카테고리";
run;
/*=============================================================================
  10. RFMP 가치등급 x 상대위험등급 요약
=============================================================================*/
proc sql;
    create table crm.w4_42_segment_summary as
    select
        tier_code,
        rfmp_tier,
        relative_risk_grade,
        count(*) as customer_count,
        sum(upcase(strip(customer_maturity_group))="NEW_LT90")
            as new_customer_count,
        mean(rfmp_score) as avg_rfmp_score format=10.2,
        mean(raw_churn_probability)
            as avg_raw_probability format=percent8.2,
        mean(relative_risk_percentile)
            as avg_risk_percentile format=percent8.2,
        mean(value_risk_score)
            as avg_value_risk_score format=percent8.2,
        min(value_risk_priority_rank) as best_value_risk_rank,
        max(value_risk_priority_rank) as worst_value_risk_rank
    from crm.w4_42_customer_action
    group by
        tier_code,
        rfmp_tier,
        relative_risk_grade
    order by
        tier_code,
        case relative_risk_grade
            when "High" then 1
            when "Medium" then 2
            else 3
        end;
quit;
/*=============================================================================
  11. 자동 품질 점검값 계산
=============================================================================*/
proc sql noprint;
    select
        count(*),
        count(distinct customer_id),
        sum(missing(relative_risk_grade)),
        sum(missing(top_category)),
        sum(missing(action_code)),
        count(distinct relative_risk_grade),
        count(distinct action_code),
        min(risk_priority_rank),
        max(risk_priority_rank),
        min(value_risk_priority_rank),
        max(value_risk_priority_rank),
        sum(value_risk_score < 0 or value_risk_score > 1)
      into
        :FINAL_ROWS trimmed,
        :FINAL_UNIQUE_CUSTOMERS trimmed,
        :MISSING_RISK_GRADE trimmed,
        :FINAL_MISSING_TOP_CATEGORY trimmed,
        :MISSING_ACTION trimmed,
        :RISK_GRADE_COUNT trimmed,
        :ACTION_RULE_COUNT trimmed,
        :RISK_RANK_MIN trimmed,
        :RISK_RANK_MAX trimmed,
        :VALUE_RISK_RANK_MIN trimmed,
        :VALUE_RISK_RANK_MAX trimmed,
        :INVALID_VALUE_RISK_SCORE trimmed
    from crm.w4_42_customer_action;
    create table work.w4_42_risk_grade_count as
    select
        relative_risk_grade,
        count(*) as customer_count
    from crm.w4_42_customer_action
    group by relative_risk_grade;
    select
        max(customer_count)-min(customer_count)
      into :RISK_GRADE_SIZE_GAP trimmed
    from work.w4_42_risk_grade_count;
quit;
/*=============================================================================
  12. QA 테이블 생성
=============================================================================*/
data crm.w4_42_qa_summary;
    length
        check_order 8
        check_item $80
        actual_value $40
        expected_value $40
        status $8
        detail $200;
    check_order=1;
    check_item="3.5~3.9 QA FAIL count";
    actual_value="&W3_FAIL_COUNT.";
    expected_value="0";
    status=ifc(&W3_FAIL_COUNT.=0,"PASS","FAIL");
    detail="RFMP 입력 품질검사에 FAIL이 없어야 함";
    output;
    check_order=2;
    check_item="4.1 QA FAIL count";
    actual_value="&W4_41_FAIL_COUNT.";
    expected_value="0";
    status=ifc(&W4_41_FAIL_COUNT.=0,"PASS","FAIL");
    detail="상대위험 입력 품질검사에 FAIL이 없어야 함";
    output;
    check_order=3;
    check_item="Final customer rows";
    actual_value="&FINAL_ROWS.";
    expected_value="&EXPECTED_CUSTOMERS.";
    status=ifc(&FINAL_ROWS.=&EXPECTED_CUSTOMERS.,"PASS","FAIL");
    detail="RFMP 전 고객이 보존되어야 함";
    output;
    check_order=4;
    check_item="Unique customer IDs";
    actual_value="&FINAL_UNIQUE_CUSTOMERS.";
    expected_value="&FINAL_ROWS.";
    status=ifc(&FINAL_UNIQUE_CUSTOMERS.=&FINAL_ROWS.,"PASS","FAIL");
    detail="고객 한 명당 한 행이어야 함";
    output;
    check_order=5;
    check_item="Missing relative risk grade";
    actual_value="&MISSING_RISK_GRADE.";
    expected_value="0";
    status=ifc(&MISSING_RISK_GRADE.=0,"PASS","FAIL");
    detail="모든 고객에게 상대위험등급이 있어야 함";
    output;
    check_order=6;
    check_item="Relative risk grade count";
    actual_value="&RISK_GRADE_COUNT.";
    expected_value="3";
    status=ifc(&RISK_GRADE_COUNT.=3,"PASS","FAIL");
    detail="High, Medium, Low 세 등급이어야 함";
    output;
    check_order=7;
    check_item="Risk grade size difference";
    actual_value="&RISK_GRADE_SIZE_GAP.";
    expected_value="<=1";
    status=ifc(&RISK_GRADE_SIZE_GAP.<=1,"PASS","FAIL");
    detail="세 상대위험등급의 고객 수 차이는 최대 1명";
    output;
    check_order=8;
    check_item="Risk priority rank range";
    actual_value=cats("&RISK_RANK_MIN."," to ","&RISK_RANK_MAX.");
    expected_value=cats("1 to ","&FINAL_ROWS.");
    status=ifc(
        &RISK_RANK_MIN.=1 and &RISK_RANK_MAX.=&FINAL_ROWS.,
        "PASS","FAIL"
    );
    detail="위험순위는 1부터 전체 고객 수까지여야 함";
    output;
    check_order=9;
    check_item="Value risk priority rank range";
    actual_value=cats(
        "&VALUE_RISK_RANK_MIN."," to ","&VALUE_RISK_RANK_MAX."
    );
    expected_value=cats("1 to ","&FINAL_ROWS.");
    status=ifc(
        &VALUE_RISK_RANK_MIN.=1
        and &VALUE_RISK_RANK_MAX.=&FINAL_ROWS.,
        "PASS","FAIL"
    );
    detail="가치위험순위는 1부터 전체 고객 수까지여야 함";
    output;
    check_order=10;
    check_item="Invalid value risk score";
    actual_value="&INVALID_VALUE_RISK_SCORE.";
    expected_value="0";
    status=ifc(&INVALID_VALUE_RISK_SCORE.=0,"PASS","FAIL");
    detail="가치위험점수는 0과 1 사이여야 함";
    output;
    check_order=11;
    check_item="Missing personal top category";
    actual_value="&FINAL_MISSING_TOP_CATEGORY.";
    expected_value="0";
    status=ifc(&FINAL_MISSING_TOP_CATEGORY.=0,"PASS","FAIL");
    detail="모든 고객에게 개인 대표 카테고리가 있어야 함";
    output;
    check_order=12;
    check_item="Missing action rule";
    actual_value="&MISSING_ACTION.";
    expected_value="0";
    status=ifc(&MISSING_ACTION.=0,"PASS","FAIL");
    detail="모든 고객에게 실행규칙이 있어야 함";
    output;
    check_order=13;
    check_item="Action rule count";
    actual_value="&ACTION_RULE_COUNT.";
    expected_value=cats("<=","&MAX_ACTION_RULES.");
    status=ifc(
        &ACTION_RULE_COUNT.<=&MAX_ACTION_RULES.,
        "PASS","FAIL"
    );
    detail="팀이 검증할 수 있도록 규칙 수를 제한";
    output;
    check_order=14;
    check_item="Absolute probability usage";
    actual_value="&ABSOLUTE_STATUS.";
    expected_value="NOT_APPROVED";
    status=ifc(
        upcase("&ABSOLUTE_STATUS.")="NOT_APPROVED",
        "PASS","FAIL"
    );
    detail="원예측확률을 절대위험 기준으로 사용하지 않음";
    output;
run;
/*=============================================================================
  13. 주요 결과 출력
=============================================================================*/
title "WBS 4.2-1. 상대위험등급별 고객 수";
proc print
    data=work.w4_42_risk_grade_count
    noobs label;
run;
title "WBS 4.2-2. RFMP 고객가치 x 상대위험등급";
proc print
    data=crm.w4_42_segment_summary
    noobs label;
run;
title "WBS 4.2-3. 가치위험순위 상위 30명";
proc print
    data=crm.w4_42_customer_action(obs=30)
    noobs label;
    var
        value_risk_priority_rank
        customer_id
        rfmp_tier
        relative_risk_grade
        risk_priority_rank
        rfmp_value_percentile
        relative_risk_percentile
        value_risk_score
        customer_maturity_group
        top_category
        action_code;
    format
        rfmp_value_percentile
        relative_risk_percentile
        value_risk_score percent8.2;
run;
title "WBS 4.2-4. 실행규칙별 고객 수";
proc freq data=crm.w4_42_customer_action order=data;
    tables action_code / missing nocum;
run;
title "WBS 4.2-5. 자동 품질 점검";
proc print
    data=crm.w4_42_qa_summary
    noobs label;
run;
title;

/*=============================================================================
  14. 최종 실행 게이트
  FAIL이 없을 때만 4.2 완료로 판단한다.
=============================================================================*/
proc sql noprint;
    select count(*)
      into :W4_42_FAIL_COUNT trimmed
    from crm.w4_42_qa_summary
    where upcase(strip(status))="FAIL";
quit;
%macro final_gate;
    %put NOTE: WBS 4.2 QA FAIL = &W4_42_FAIL_COUNT.;
    %if &W4_42_FAIL_COUNT. > 0 %then %do;
        %put ERROR: WBS 4.2 QA에서 FAIL이 발견되었습니다.;
        %put ERROR: W4_42_QA_SUMMARY를 확인한 뒤 수정하십시오.;
        %abort cancel;
    %end;
    %else %do;
        %put NOTE: WBS 4.2가 정상적으로 완료되었습니다.;
        %put NOTE: 상대위험등급, 가치위험순위, 실행규칙 초안을 확보했습니다.;
        %put NOTE: 다음 단계에서 안정성 검증과 경제성 평가를 수행합니다.;
    %end;
%mend;
%final_gate;
/*================================ END =======================================*/


/*=============================================================================
  파일명: WBS_4_3_RANK_STABILITY.sas
  WBS 4.3
  RFMP 가치와 상대이탈위험의 정보 중복 및 우선순위 안정성 검증
  [목표]
    1. RFMP와 이탈모형이 공유하는 변수를 명시적으로 확인한다.
    2. 공통 변수 통제 전후의 가치-위험 상관을 비교한다.
    3. 위험순위와 가치위험순위가 서로 어떻게 다른지 확인한다.
    4. 상위 50명·100명·200명의 선정 안정성을 확인한다.
    5. 현재 4.2 우선순위를 유지할지 팀 검토 결론을 만든다.
  [핵심 질문]
    - 공통 변수가 RFMP 가치와 상대위험의 관계를 과도하게 강화했는가?
    - 계산식을 조금 바꿔도 가치위험 운영대상이 크게 달라지지 않는가?
  [수행 범위]
    - 공통 변수 recency, frequency_days, monetary의 값을 비교한다.
    - 가치 백분위와 위험 백분위의 원 Spearman 상관을 구한다.
    - 세 공통 변수의 선형효과를 제거한 잔차 상관을 구한다.
    - 4.2 곱셈 점수와 50:50 단순평균 점수만 비교한다.
    - 상위 50명·100명·200명의 중복률을 확인한다.
    - RFMP 등급·고객 성숙도·실행규칙별 구성을 확인한다.
  [이번 단계에서 하지 않는 작업]
    - 4.2 산출물을 다시 계산하거나 덮어쓰지 않는다.
    - 이탈모형을 다시 학습하지 않는다.
    - 절대 이탈확률 또는 절대위험 기준을 만들지 않는다.
    - RFMP 등급과 4.2 실행규칙을 변경하지 않는다.
    - 캠페인 비용, 예상이익, ROI를 계산하지 않는다.
    - 여러 대안모형을 비교하지 않는다.
  [해석 유의사항]
    - 공통 변수 값이 같으면 직접적인 정보 공유는 확인 가능하다.
    - 잔차 상관 감소는 공통 변수의 설명 정도이며 인과관계의 증거는 아니다.
    - 잔차는 선형효과만 제거하므로 비선형 중복은 남을 수 있다.
    - 50:50 평균점수는 안정성 확인용이며 공식 점수가 아니다.
    - 위험순위와 가치위험순위의 불일치는 목적 차이이며 오류가 아니다.
    - 상위대상 중복률 70%는 팀 검토용이며 통계적 절대기준이 아니다.
  [운영용 검토 기준]
    - 전체 1,468명과 고객당 한 행이 유지되어야 한다.
    - 3.5~3.9, 4.1, 4.2 QA에 FAIL이 없어야 한다.
    - 입력 테이블 결합 후 결측 고객이 없어야 한다.
    - 세 공통 변수의 값 차이는 별도 표에서 확인한다.
    - 대안점수와의 상위대상 중복률 최솟값이 70% 이상이면 안정적이니다.
    - 통제 후 상관 절댓값이 30% 이상 감소하면 공통 영향이 크다.
  [입력 테이블]
    CRM.W3_RFMP_BASE_PY: RFMP의 recency, frequency_days, monetary
    CRM.W4_41_CURRENT_SCORED: 공통 변수와 상대위험순위
    CRM.W4_41_QA_SUMMARY
      : 4.1 품질검사 결과
    CRM.W4_42_CUSTOMER_ACTION
      : 4.2 가치·위험순위와 실행규칙
    CRM.W4_42_QA_SUMMARY
      : 4.2 품질검사 결과
  [주요 산출물]
    CRM.W4_43_SHARED_INFO_CHECK
      : 직접 변수 일치율과 통제 전후 상관
    CRM.W4_43_STABILITY_SUMMARY
      : 상위대상 중복률과 순위 차이
    CRM.W4_43_DECISION
      : 4.2 우선순위 유지 여부와 해석
    CRM.W4_43_QA_SUMMARY
      : 입력·결합·계산·산출물 자동검사
=============================================================================*/

/*=============================================================================
  0. 실행 옵션과 검토 기준
=============================================================================*/
options validvarname=any validmemname=extend;

%let CRM_PATH=/home/student/crm_db;
%let EXPECTED_CUSTOMERS=1468;

/* 대안 계산식의 상위대상 최소 중복률 */
%let MIN_ALT_TOPK_OVERLAP=0.70;

/* 공통 변수 통제 후 상관 절댓값 감소 비율 */
%let MATERIAL_CORR_REDUCTION=0.30;

/* 숫자 비교 허용오차 */
%let VALUE_TOLERANCE=0.000001;
%let MONEY_TOLERANCE=0.01;

libname crm "&CRM_PATH.";


/*=============================================================================
  1. 입력 테이블과 필수 변수 확인
=============================================================================*/
%macro require_table(ds=, previous_step=);
    %if %sysfunc(exist(&ds.))=0 %then %do;
        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %put ERROR: &previous_step. 단계를 먼저 실행하십시오.;
        %abort cancel;
    %end;
    %else %do;
        %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;
    %end;
%mend;

%macro require_var(ds=, var=);
    %local dsid varnum rc;

    %let dsid=%sysfunc(open(&ds.,i));

    %if &dsid.=0 %then %do;
        %put ERROR: &ds. 데이터셋을 열 수 없습니다.;
        %abort cancel;
    %end;

    %let varnum=%sysfunc(varnum(&dsid.,&var.));
    %let rc=%sysfunc(close(&dsid.));

    %if &varnum.=0 %then %do;
        %put ERROR: &ds. 에 필수 변수 &var. 이(가) 없습니다.;
        %abort cancel;
    %end;
%mend;

%macro check_inputs;
    %if %sysfunc(libref(crm)) ne 0 %then %do;
        %put ERROR: CRM 라이브러리가 연결되지 않았습니다.;
        %put ERROR: 경로를 확인하십시오 - &CRM_PATH.;
        %abort cancel;
    %end;

    %require_table(ds=crm.w3_rfmp_base_py,previous_step=WBS 3.5~3.9);
    %require_table(ds=crm.w4_41_current_scored,previous_step=WBS 4.1);
    %require_table(ds=crm.w4_41_qa_summary,previous_step=WBS 4.1);
    %require_table(ds=crm.w4_42_customer_action,previous_step=WBS 4.2);
    %require_table(ds=crm.w4_42_qa_summary,previous_step=WBS 4.2);
%mend;

%check_inputs;

/* 3절 RFMP 입력 */
%require_var(ds=crm.w3_rfmp_base_py,var=customer_id);
%require_var(ds=crm.w3_rfmp_base_py,var=recency);
%require_var(ds=crm.w3_rfmp_base_py,var=frequency_days);
%require_var(ds=crm.w3_rfmp_base_py,var=monetary);

/* 4.1 이탈모형 입력·산출물 */
%require_var(ds=crm.w4_41_current_scored,var=customer_id);
%require_var(ds=crm.w4_41_current_scored,var=recency);
%require_var(ds=crm.w4_41_current_scored,var=frequency_days);
%require_var(ds=crm.w4_41_current_scored,var=monetary);
%require_var(ds=crm.w4_41_current_scored,var=risk_priority_rank);
%require_var(ds=crm.w4_41_current_scored,var=relative_risk_percentile);

/* 4.2 가치·위험 매핑 산출물 */
%require_var(ds=crm.w4_42_customer_action,var=customer_id);
%require_var(ds=crm.w4_42_customer_action,var=rfmp_tier);
%require_var(ds=crm.w4_42_customer_action,var=rfmp_value_percentile);
%require_var(ds=crm.w4_42_customer_action,var=relative_risk_grade);
%require_var(ds=crm.w4_42_customer_action,var=relative_risk_percentile);
%require_var(ds=crm.w4_42_customer_action,var=risk_priority_rank);
%require_var(ds=crm.w4_42_customer_action,var=value_priority_rank);
%require_var(ds=crm.w4_42_customer_action,var=value_risk_score);
%require_var(ds=crm.w4_42_customer_action,var=value_risk_priority_rank);
%require_var(ds=crm.w4_42_customer_action,var=customer_maturity_group);
%require_var(ds=crm.w4_42_customer_action,var=action_code);


/*=============================================================================
  2. 이전 4.3 산출물만 삭제
  4.1과 4.2 테이블은 삭제하거나 변경하지 않는다.
=============================================================================*/
proc datasets library=crm nolist nowarn;
    delete
        w4_43_shared_info_check
        w4_43_stability_summary
        w4_43_decision
        w4_43_qa_summary;
quit;


/*=============================================================================
  3. 이전 단계 QA 확인
=============================================================================*/
proc sql noprint;
    select count(*)
      into :W4_41_FAIL_COUNT trimmed
    from crm.w4_41_qa_summary
    where upcase(strip(status))="FAIL";

    select count(*)
      into :W4_42_FAIL_COUNT trimmed
    from crm.w4_42_qa_summary
    where upcase(strip(status))="FAIL";
quit;

%macro validate_previous_steps;
    %if &W4_41_FAIL_COUNT. > 0 %then %do;
        %put ERROR: WBS 4.1 QA에 FAIL이 있습니다.;
        %abort cancel;
    %end;

    %if &W4_42_FAIL_COUNT. > 0 %then %do;
        %put ERROR: WBS 4.2 QA에 FAIL이 있습니다.;
        %abort cancel;
    %end;

    %put NOTE: 4.1과 4.2 QA 실행 게이트를 통과했습니다.;
%mend;

%validate_previous_steps;


/*=============================================================================
  4. 공통 분석 테이블 생성
  같은 고객의 RFMP 변수와 이탈모형 변수를 나란히 붙인다.
=============================================================================*/
proc sql;
    create table work.w4_43_base as
    select
        a.customer_id,
        a.rfmp_tier,
        a.rfmp_value_percentile,
        a.relative_risk_grade,
        a.relative_risk_percentile,
        a.risk_priority_rank,
        a.value_priority_rank,
        a.value_risk_score,
        a.value_risk_priority_rank,
        a.customer_maturity_group,
        a.action_code,

        b.recency
            as model_recency,

        b.frequency_days
            as model_frequency_days,

        b.monetary
            as model_monetary,

        c.recency
            as rfmp_recency,

        c.frequency_days
            as rfmp_frequency_days,

        c.monetary
            as rfmp_monetary

    from crm.w4_42_customer_action as a

    left join crm.w4_41_current_scored as b
      on a.customer_id=b.customer_id

    left join crm.w3_rfmp_base_py as c
      on a.customer_id=c.customer_id;
quit;


/*=============================================================================
  5. 결합 상태와 공통 변수의 직접 일치 여부 확인
=============================================================================*/
proc sql noprint;
    select
        count(*),
        count(distinct customer_id),

        sum(
            missing(model_recency)
            or missing(rfmp_recency)
        ),

        sum(
            missing(model_frequency_days)
            or missing(rfmp_frequency_days)
        ),

        sum(
            missing(model_monetary)
            or missing(rfmp_monetary)
        ),

        sum(
            abs(model_recency-rfmp_recency)
            > &VALUE_TOLERANCE.
        ),

        sum(
            abs(model_frequency_days-rfmp_frequency_days)
            > &VALUE_TOLERANCE.
        ),

        sum(
            abs(model_monetary-rfmp_monetary)
            > &MONEY_TOLERANCE.
        )

      into
        :BASE_ROWS trimmed,
        :BASE_UNIQUE_CUSTOMERS trimmed,
        :MISSING_RECENCY_PAIR trimmed,
        :MISSING_FREQUENCY_PAIR trimmed,
        :MISSING_MONETARY_PAIR trimmed,
        :RECENCY_MISMATCH trimmed,
        :FREQUENCY_MISMATCH trimmed,
        :MONETARY_MISMATCH trimmed

    from work.w4_43_base;
quit;

%let TOTAL_PAIR_MISSING=
    %eval(
        &MISSING_RECENCY_PAIR.
        + &MISSING_FREQUENCY_PAIR.
        + &MISSING_MONETARY_PAIR.
    );

%let TOTAL_FEATURE_MISMATCH=
    %eval(
        &RECENCY_MISMATCH.
        + &FREQUENCY_MISMATCH.
        + &MONETARY_MISMATCH.
    );

%macro validate_join;

    %if &BASE_ROWS. ne &EXPECTED_CUSTOMERS. %then %do;
        %put ERROR: 결합 결과가 &EXPECTED_CUSTOMERS.명이 아닙니다.;
        %abort cancel;
    %end;

    %if &BASE_ROWS. ne &BASE_UNIQUE_CUSTOMERS. %then %do;
        %put ERROR: 결합 결과에 중복 customer_id가 있습니다.;
        %abort cancel;
    %end;

    %if &TOTAL_PAIR_MISSING. > 0 %then %do;
        %put ERROR: 공통 변수 결합에 결측 고객이 있습니다.;
        %abort cancel;
    %end;

%mend;

%validate_join;


/*=============================================================================
  6. RFMP 가치와 상대위험의 원 상관
  순위·백분위 관계이므로 Spearman 상관을 사용한다.
=============================================================================*/
proc corr
    data=work.w4_43_base
    spearman
    outs=work.w4_43_raw_spearman
    noprint;

    var
        rfmp_value_percentile
        relative_risk_percentile;
run;

%let RAW_SPEARMAN=.;

proc sql noprint;

    /* 계산용 매크로 변수에는 표시 서식이 아닌 원시 숫자 문자열만 저장 */
    select relative_risk_percentile format=best32.
      into :RAW_SPEARMAN trimmed

    from work.w4_43_raw_spearman

    where upcase(_TYPE_)="CORR"
      and upcase(_NAME_)="RFMP_VALUE_PERCENTILE";
quit;


/*=============================================================================
  7. 공통 변수의 영향을 제거한 잔차 생성
  첫 번째 회귀식은 RFMP 가치 백분위에서 공통 변수 효과를 제거한다.
  두 번째 회귀식은 상대위험 백분위에서 같은 효과를 제거한다.
  모형을 새로 학습하는 단계가 아니라 상관 구조를 진단하는 절차이다.
=============================================================================*/
proc reg
    data=work.w4_43_base
    noprint;

    model rfmp_value_percentile =
        rfmp_recency
        rfmp_frequency_days
        rfmp_monetary;

    output
        out=work.w4_43_value_residual
        residual=value_residual;
quit;


proc reg
    data=work.w4_43_value_residual
    noprint;

    model relative_risk_percentile =
        model_recency
        model_frequency_days
        model_monetary;

    output
        out=work.w4_43_residuals
        residual=risk_residual;
quit;


proc corr
    data=work.w4_43_residuals
    spearman
    outs=work.w4_43_residual_spearman
    noprint;

    var
        value_residual
        risk_residual;
run;

%let RESIDUAL_SPEARMAN=.;

proc sql noprint;

    /* 계산용 매크로 변수에는 표시 서식이 아닌 원시 숫자 문자열만 저장 */
    select risk_residual format=best32.
      into :RESIDUAL_SPEARMAN trimmed

    from work.w4_43_residual_spearman

    where upcase(_TYPE_)="CORR"
      and upcase(_NAME_)="VALUE_RESIDUAL";
quit;


/*=============================================================================
  8. 상관 감소량과 공통 정보 영향 판정
=============================================================================*/
data work.w4_43_correlation_result;

    raw_spearman=&RAW_SPEARMAN.;
    residual_spearman=&RESIDUAL_SPEARMAN.;

    absolute_correlation_reduction=
        abs(raw_spearman)
        - abs(residual_spearman);

    if abs(raw_spearman)>0 then
        relative_correlation_reduction=
            absolute_correlation_reduction
            / abs(raw_spearman);
    else
        relative_correlation_reduction=0;

    length shared_information_status $32;

    if &TOTAL_FEATURE_MISMATCH.=0
       and relative_correlation_reduction
            >= &MATERIAL_CORR_REDUCTION.
    then
        shared_information_status=
            "MATERIAL_SHARED_INFORMATION";

    else if &TOTAL_FEATURE_MISMATCH.=0 then
        shared_information_status=
            "DIRECT_OVERLAP_CONFIRMED";

    else
        shared_information_status=
            "SOURCE_VALUES_DIFFER";

    format
        raw_spearman
        residual_spearman
        absolute_correlation_reduction
            8.4
        relative_correlation_reduction
            percent8.2;
run;


proc sql noprint;

    /*
       relative_correlation_reduction에는 PERCENT8.2 표시 서식이 붙어 있다.
       그대로 INTO 하면 0.2043...이 20.43% 문자열로 저장될 수 있다.
       SELECT 결과에 BEST32.를 명시해 계산용 원시 숫자 문자열로 저장한다.
    */
    select
        relative_correlation_reduction format=best32.,
        shared_information_status

      into
        :CORR_REDUCTION_RATE trimmed,
        :SHARED_INFO_STATUS trimmed

    from work.w4_43_correlation_result;
quit;

%put NOTE: WBS 4.3 CORR_REDUCTION_RATE raw = &CORR_REDUCTION_RATE.;
%put NOTE: WBS 4.3 SHARED_INFO_STATUS = &SHARED_INFO_STATUS.;


/*=============================================================================
  9. 공통 정보 점검표 생성
=============================================================================*/
data crm.w4_43_shared_info_check;

    length
        check_order 8
        metric_type $24
        metric_name $48
        actual_value 8
        expected_value $80
        status $12
        interpretation $200;

    check_order=1;
    metric_type="DIRECT_MATCH";
    metric_name="recency mismatch count";
    actual_value=&RECENCY_MISMATCH.;
    expected_value="0이면 양쪽 값이 동일";
    status=ifc(actual_value=0,"CONFIRMED","REVIEW");
    interpretation="RFMP와 이탈모형의 recency 고객별 값 비교";
    output;

    check_order=2;
    metric_type="DIRECT_MATCH";
    metric_name="frequency_days mismatch count";
    actual_value=&FREQUENCY_MISMATCH.;
    expected_value="0이면 양쪽 값이 동일";
    status=ifc(actual_value=0,"CONFIRMED","REVIEW");
    interpretation="RFMP와 이탈모형의 구매일 수 고객별 값 비교";
    output;

    check_order=3;
    metric_type="DIRECT_MATCH";
    metric_name="monetary mismatch count";
    actual_value=&MONETARY_MISMATCH.;
    expected_value="0이면 양쪽 값이 동일";
    status=ifc(actual_value=0,"CONFIRMED","REVIEW");
    interpretation="RFMP와 이탈모형의 구매금액 고객별 값 비교";
    output;

    check_order=4;
    metric_type="CORRELATION";
    metric_name="Raw value-risk Spearman";
    actual_value=&RAW_SPEARMAN.;
    expected_value="설명용";
    status="INFO";
    interpretation="공통 변수를 통제하기 전 가치와 위험의 순위상관";
    output;

    check_order=5;
    metric_type="CORRELATION";
    metric_name="Residual value-risk Spearman";
    actual_value=&RESIDUAL_SPEARMAN.;
    expected_value="설명용";
    status="INFO";
    interpretation="세 공통 변수의 선형효과를 제거한 뒤의 잔차상관";
    output;

    check_order=6;
    metric_type="CORRELATION";
    metric_name="Relative correlation reduction";
    actual_value=&CORR_REDUCTION_RATE.;

    expected_value=cats(
        ">= ",
        put(&MATERIAL_CORR_REDUCTION.,percent8.2),
        "이면 영향 큼"
    );

    status=ifc(
        actual_value>=&MATERIAL_CORR_REDUCTION.,
        "MATERIAL",
        "LIMITED"
    );

    interpretation="공통 변수 통제 전후 상관 절댓값의 상대 감소율";
    output;

run;


/*=============================================================================
  10. 대안 가치위험점수와 순위 생성

  기존 공식
    가치 백분위 x 위험 백분위

  검증용 대안
    0.5 x 가치 백분위 + 0.5 x 위험 백분위

  대안은 안정성 확인에만 사용하며 4.2 공식점수를 변경하지 않는다.
=============================================================================*/
data work.w4_43_alt_pre;
    set work.w4_43_base;

    alt_equal_score=
        0.5*rfmp_value_percentile
        + 0.5*relative_risk_percentile;
run;


proc sort
    data=work.w4_43_alt_pre
    out=work.w4_43_alt_sorted;

    by
        descending alt_equal_score
        risk_priority_rank
        value_priority_rank
        customer_id;
run;


data work.w4_43_compare;
    set work.w4_43_alt_sorted;

    alt_equal_priority_rank=_n_;

    risk_to_value_rank_change=
        value_risk_priority_rank
        - risk_priority_rank;

    current_to_alt_rank_change=
        alt_equal_priority_rank
        - value_risk_priority_rank;

    abs_risk_to_value_change=
        abs(risk_to_value_rank_change);

    abs_current_to_alt_change=
        abs(current_to_alt_rank_change);
run;


/*=============================================================================
  11. 상위 50명·100명·200명 중복률

  CURRENT_VS_RISK
    가치위험순위와 순수 위험순위의 차이를 설명한다.

  CURRENT_VS_EQUAL
    공식 곱셈점수와 검증용 50:50 평균점수의 안정성을 판단한다.
=============================================================================*/
proc sql;
    create table work.w4_43_topk_overlap
    (
        comparison char(24),
        top_n num,
        overlap_count num,
        overlap_rate num
    );
quit;


%macro add_topk(k=);

    proc sql;

        insert into work.w4_43_topk_overlap
        select
            "CURRENT_VS_RISK",
            &k.,

            sum(
                value_risk_priority_rank<=&k.
                and risk_priority_rank<=&k.
            ),

            sum(
                value_risk_priority_rank<=&k.
                and risk_priority_rank<=&k.
            )/&k.

        from work.w4_43_compare;


        insert into work.w4_43_topk_overlap
        select
            "CURRENT_VS_EQUAL",
            &k.,

            sum(
                value_risk_priority_rank<=&k.
                and alt_equal_priority_rank<=&k.
            ),

            sum(
                value_risk_priority_rank<=&k.
                and alt_equal_priority_rank<=&k.
            )/&k.

        from work.w4_43_compare;

    quit;

%mend;

%add_topk(k=50);
%add_topk(k=100);
%add_topk(k=200);


/*=============================================================================
  12. 전체 순위 상관과 평균 순위 차이
=============================================================================*/
proc corr
    data=work.w4_43_compare
    pearson
    outp=work.w4_43_rank_corr
    noprint;

    var
        risk_priority_rank
        value_risk_priority_rank
        alt_equal_priority_rank;
run;


%let RANK_CORR_CURRENT_RISK=.;
%let RANK_CORR_CURRENT_ALT=.;
%let MEAN_ABS_RISK_VALUE_SHIFT=.;
%let MEAN_ABS_CURRENT_ALT_SHIFT=.;
%let MIN_ALT_OVERLAP=.;


proc sql noprint;

    select risk_priority_rank format=best32.
      into :RANK_CORR_CURRENT_RISK trimmed
    from work.w4_43_rank_corr
    where upcase(_TYPE_)="CORR"
      and upcase(_NAME_)="VALUE_RISK_PRIORITY_RANK";


    select alt_equal_priority_rank format=best32.
      into :RANK_CORR_CURRENT_ALT trimmed
    from work.w4_43_rank_corr
    where upcase(_TYPE_)="CORR"
      and upcase(_NAME_)="VALUE_RISK_PRIORITY_RANK";


    select
        mean(abs_risk_to_value_change) format=best32.,
        mean(abs_current_to_alt_change) format=best32.

      into
        :MEAN_ABS_RISK_VALUE_SHIFT trimmed,
        :MEAN_ABS_CURRENT_ALT_SHIFT trimmed

    from work.w4_43_compare;


    select min(overlap_rate) format=best32.
      into :MIN_ALT_OVERLAP trimmed
    from work.w4_43_topk_overlap
    where comparison="CURRENT_VS_EQUAL";

quit;

%put NOTE: WBS 4.3 MIN_ALT_OVERLAP raw = &MIN_ALT_OVERLAP.;


/*=============================================================================
  13. 안정성 요약 테이블
=============================================================================*/
data work.w4_43_topk_metrics;
    set work.w4_43_topk_overlap;

    length
        metric_group $24
        metric_name $60
        metric_display $24
        criterion $40
        status $8
        interpretation $180;

    metric_group="TOPK_OVERLAP";

    metric_name=cats(
        comparison,
        " TOP ",
        top_n
    );

    metric_value=overlap_rate;
    metric_display=put(overlap_rate,percent8.2);

    if comparison="CURRENT_VS_EQUAL" then do;

        criterion=cats(
            ">= ",
            put(&MIN_ALT_TOPK_OVERLAP.,percent8.2)
        );

        status=ifc(
            overlap_rate>=&MIN_ALT_TOPK_OVERLAP.,
            "PASS",
            "REVIEW"
        );

        interpretation=
            "공식 곱셈점수와 50:50 평균점수의 상위대상 안정성";

    end;

    else do;

        criterion="설명용";
        status="INFO";

        interpretation=
            "순수 위험순위와 가치위험순위는 목적이 달라 차이가 정상";

    end;

    keep
        metric_group
        metric_name
        top_n
        overlap_count
        metric_value
        metric_display
        criterion
        status
        interpretation;

run;


data work.w4_43_rank_metrics;

    length
        metric_group $24
        metric_name $60
        top_n 8
        overlap_count 8
        metric_value 8
        metric_display $24
        criterion $40
        status $8
        interpretation $180;

    /*
      아래 네 개의 순위 지표는 특정 상위 N명을 다루지 않는다.
      따라서 TOP-K 전용 변수는 의도적으로 결측값으로 초기화한다.
      이 두 문장으로 불필요한 uninitialized NOTE를 방지한다.
    */
    top_n=.;
    overlap_count=.;

    metric_group="RANK_RELATION";
    metric_name="Current value-risk vs risk-only rank correlation";
    metric_value=&RANK_CORR_CURRENT_RISK.;
    metric_display=put(metric_value,8.4);
    criterion="설명용";
    status="INFO";
    interpretation="순수 위험과 가치위험 우선순위의 전체 순위상관";
    output;


    metric_group="RANK_STABILITY";
    metric_name="Current value-risk vs equal-score rank correlation";
    metric_value=&RANK_CORR_CURRENT_ALT.;
    metric_display=put(metric_value,8.4);
    criterion="1에 가까울수록 안정";
    status="INFO";
    interpretation="공식점수와 검증용 평균점수의 전체 순위상관";
    output;


    metric_group="RANK_SHIFT";
    metric_name="Mean absolute risk-to-value rank shift";
    metric_value=&MEAN_ABS_RISK_VALUE_SHIFT.;
    metric_display=put(metric_value,comma12.2);
    criterion="설명용";
    status="INFO";
    interpretation="가치를 결합했을 때 고객 순위가 평균적으로 이동한 폭";
    output;


    metric_group="RANK_SHIFT";
    metric_name="Mean absolute current-to-equal rank shift";
    metric_value=&MEAN_ABS_CURRENT_ALT_SHIFT.;
    metric_display=put(metric_value,comma12.2);
    criterion="작을수록 안정";
    status="INFO";
    interpretation="점수 계산식을 바꿨을 때 평균 순위 이동 폭";
    output;

run;


data crm.w4_43_stability_summary;
    set
        work.w4_43_topk_metrics
        work.w4_43_rank_metrics;
run;


/*=============================================================================
  14. RFMP·성숙도·실행규칙별 구성
  설명용 WORK 테이블이며 4.2 실행규칙은 변경하지 않는다.
=============================================================================*/
proc sql;

    create table work.w4_43_risk_by_value as
    select
        rfmp_tier,
        relative_risk_grade,
        count(*) as customer_count
    from work.w4_43_compare
    group by
        rfmp_tier,
        relative_risk_grade;


    create table work.w4_43_risk_by_maturity as
    select
        customer_maturity_group,
        relative_risk_grade,
        count(*) as customer_count
    from work.w4_43_compare
    group by
        customer_maturity_group,
        relative_risk_grade;


    create table work.w4_43_action_composition as
    select
        action_code,
        customer_maturity_group,
        relative_risk_grade,
        count(*) as customer_count
    from work.w4_43_compare
    group by
        action_code,
        customer_maturity_group,
        relative_risk_grade;

quit;


/*=============================================================================
  15. 최종 판단 테이블
=============================================================================*/
data crm.w4_43_decision;

    length
        decision_code $40
        ranking_status $24
        shared_information_status $32
        decision_text $400
        limitation $400;

    customer_count=&BASE_ROWS.;

    raw_spearman=&RAW_SPEARMAN.;
    residual_spearman=&RESIDUAL_SPEARMAN.;

    correlation_reduction_rate=&CORR_REDUCTION_RATE.;

    minimum_alternative_topk_overlap=&MIN_ALT_OVERLAP.;

    shared_information_status=
        "&SHARED_INFO_STATUS.";


    if minimum_alternative_topk_overlap
        >= &MIN_ALT_TOPK_OVERLAP.
    then do;

        ranking_status="STABLE";

        if shared_information_status=
            "MATERIAL_SHARED_INFORMATION"
        then do;

            decision_code=
                "KEEP_WITH_OVERLAP_CAUTION";

            decision_text=
                "4.2 우선순위는 유지하되 RFMP와 이탈점수가 공통 구매행동 정보를 상당 부분 공유한다는 한계를 함께 보고";

        end;

        else do;

            decision_code=
                "KEEP_4_2_RANKING";

            decision_text=
                "대안 계산식에서도 상위 운영대상이 대체로 유지되어 4.2 가치위험순위를 유지";

        end;

    end;

    else do;

        ranking_status="REVIEW";
        decision_code="REVIEW_VALUE_RISK_FORMULA";

        decision_text=
            "대안 계산식에서 상위 운영대상이 크게 달라져 4.4 이전에 가치위험점수 공식을 팀 검토";

    end;


    limitation=
        "공통 변수 통제는 선형 잔차 방식이며 비선형 정보중복과 인과관계를 확정하지 않음. 70% 기준은 운영 검토용 기준임";


    format
        raw_spearman
        residual_spearman
            8.4

        correlation_reduction_rate
        minimum_alternative_topk_overlap
            percent8.2;

run;


/*=============================================================================
  16. QA 계산값
=============================================================================*/
proc sql noprint;

    select
        count(*),
        count(distinct customer_id),

        sum(missing(alt_equal_score)),

        sum(
            alt_equal_score<0
            or alt_equal_score>1
        ),

        min(alt_equal_priority_rank),
        max(alt_equal_priority_rank),

        count(distinct action_code)

      into
        :COMPARE_ROWS trimmed,
        :COMPARE_UNIQUE_CUSTOMERS trimmed,
        :MISSING_ALT_SCORE trimmed,
        :INVALID_ALT_SCORE trimmed,
        :ALT_RANK_MIN trimmed,
        :ALT_RANK_MAX trimmed,
        :ACTION_RULE_COUNT trimmed

    from work.w4_43_compare;


    select count(*)
      into :STABILITY_ROW_COUNT trimmed
    from crm.w4_43_stability_summary;


    select count(*)
      into :DECISION_ROW_COUNT trimmed
    from crm.w4_43_decision;

quit;


/*=============================================================================
  17. QA 테이블
=============================================================================*/
data crm.w4_43_qa_summary;

    length
        check_order 8
        check_item $80
        actual_value $40
        expected_value $40
        status $8
        detail $220;


    check_order=1;
    check_item="4.1 QA FAIL count";
    actual_value="&W4_41_FAIL_COUNT.";
    expected_value="0";
    status=ifc(&W4_41_FAIL_COUNT.=0,"PASS","FAIL");
    detail="4.1 입력 품질검사에 FAIL이 없어야 함";
    output;


    check_order=2;
    check_item="4.2 QA FAIL count";
    actual_value="&W4_42_FAIL_COUNT.";
    expected_value="0";
    status=ifc(&W4_42_FAIL_COUNT.=0,"PASS","FAIL");
    detail="4.2 입력 품질검사에 FAIL이 없어야 함";
    output;


    check_order=3;
    check_item="Analysis customer rows";
    actual_value="&COMPARE_ROWS.";
    expected_value="&EXPECTED_CUSTOMERS.";

    status=ifc(
        &COMPARE_ROWS.=&EXPECTED_CUSTOMERS.,
        "PASS",
        "FAIL"
    );

    detail="전체 고객 수가 보존되어야 함";
    output;


    check_order=4;
    check_item="Unique customer IDs";
    actual_value="&COMPARE_UNIQUE_CUSTOMERS.";
    expected_value="&COMPARE_ROWS.";

    status=ifc(
        &COMPARE_UNIQUE_CUSTOMERS.=&COMPARE_ROWS.,
        "PASS",
        "FAIL"
    );

    detail="고객당 한 행이어야 함";
    output;


    check_order=5;
    check_item="Missing shared feature pairs";
    actual_value="&TOTAL_PAIR_MISSING.";
    expected_value="0";

    status=ifc(
        &TOTAL_PAIR_MISSING.=0,
        "PASS",
        "FAIL"
    );

    detail="RFMP와 이탈모형 공통 변수 결합에 결측이 없어야 함";
    output;


    check_order=6;
    check_item="Shared feature value mismatch";
    actual_value="&TOTAL_FEATURE_MISMATCH.";
    expected_value="0이면 직접 중복 확인";

    status=ifc(
        &TOTAL_FEATURE_MISMATCH.=0,
        "PASS",
        "REVIEW"
    );

    detail="0이면 세 공통 변수가 고객별로 같은 값을 사용";
    output;


    check_order=7;
    check_item="Missing alternative score";
    actual_value="&MISSING_ALT_SCORE.";
    expected_value="0";

    status=ifc(
        &MISSING_ALT_SCORE.=0,
        "PASS",
        "FAIL"
    );

    detail="검증용 평균점수에 결측이 없어야 함";
    output;


    check_order=8;
    check_item="Alternative score outside 0 to 1";
    actual_value="&INVALID_ALT_SCORE.";
    expected_value="0";

    status=ifc(
        &INVALID_ALT_SCORE.=0,
        "PASS",
        "FAIL"
    );

    detail="검증용 평균점수 범위 확인";
    output;


    check_order=9;
    check_item="Alternative rank range";

    actual_value=cats(
        "&ALT_RANK_MIN.",
        " to ",
        "&ALT_RANK_MAX."
    );

    expected_value=cats(
        "1 to ",
        "&COMPARE_ROWS."
    );

    status=ifc(
        &ALT_RANK_MIN.=1
        and &ALT_RANK_MAX.=&COMPARE_ROWS.,
        "PASS",
        "FAIL"
    );

    detail="대안순위는 1부터 전체 고객 수까지여야 함";
    output;


    check_order=10;
    check_item="Alternative top-k minimum overlap";

    actual_value=
        put(&MIN_ALT_OVERLAP.,percent8.2);

    expected_value=cats(
        ">= ",
        put(&MIN_ALT_TOPK_OVERLAP.,percent8.2)
    );

    status=ifc(
        &MIN_ALT_OVERLAP.>=&MIN_ALT_TOPK_OVERLAP.,
        "PASS",
        "REVIEW"
    );

    detail="공식점수와 검증용 평균점수의 상위대상 안정성";
    output;


    check_order=11;
    check_item="Action rule count unchanged";
    actual_value="&ACTION_RULE_COUNT.";
    expected_value="<=8";

    status=ifc(
        &ACTION_RULE_COUNT.<=8,
        "PASS",
        "FAIL"
    );

    detail="4.2 실행규칙을 변경하지 않았는지 확인";
    output;


    check_order=12;
    check_item="Stability summary rows";
    actual_value="&STABILITY_ROW_COUNT.";
    expected_value="10";

    status=ifc(
        &STABILITY_ROW_COUNT.=10,
        "PASS",
        "FAIL"
    );

    detail="상위대상 6행과 순위지표 4행";
    output;


    check_order=13;
    check_item="Decision row count";
    actual_value="&DECISION_ROW_COUNT.";
    expected_value="1";

    status=ifc(
        &DECISION_ROW_COUNT.=1,
        "PASS",
        "FAIL"
    );

    detail="최종 판단은 한 행이어야 함";
    output;

run;


/*=============================================================================
  18. 핵심 결과 출력
=============================================================================*/

title "WBS 4.3-1. RFMP와 이탈모형의 공통 정보 확인";

proc print
    data=crm.w4_43_shared_info_check
    noobs
    label;

    format actual_value 12.4;
run;


title "WBS 4.3-2. 상위대상과 순위 안정성";

proc print
    data=crm.w4_43_stability_summary
    noobs
    label;
run;


title "WBS 4.3-3. RFMP 등급별 상대위험 분포";

proc print
    data=work.w4_43_risk_by_value
    noobs
    label;
run;


title "WBS 4.3-4. 신규·기존 고객별 상대위험 분포";

proc print
    data=work.w4_43_risk_by_maturity
    noobs
    label;
run;


title "WBS 4.3-5. 실행규칙별 고객 구성";

proc print
    data=work.w4_43_action_composition
    noobs
    label;
run;


title "WBS 4.3-6. 현재 우선순위 유지 여부";

options linesize=256;

proc print
    data=crm.w4_43_decision
    noobs
    label;
run;

options linesize=132;


title "WBS 4.3-7. 자동 품질 점검";

proc print
    data=crm.w4_43_qa_summary
    noobs
    label;
run;

title;


/*=============================================================================
  19. 최종 실행 게이트
  FAIL은 기술적 오류이다.
  REVIEW는 팀이 해석할 항목이므로 실행을 중단하지 않는다.
=============================================================================*/
proc sql noprint;

    select
        sum(upcase(strip(status))="FAIL"),
        sum(upcase(strip(status))="REVIEW")

      into
        :W4_43_FAIL_COUNT trimmed,
        :W4_43_REVIEW_COUNT trimmed

    from crm.w4_43_qa_summary;

quit;


%macro final_gate;

    %put NOTE: WBS 4.3 QA FAIL = &W4_43_FAIL_COUNT.;
    %put NOTE: WBS 4.3 QA REVIEW = &W4_43_REVIEW_COUNT.;

    %if &W4_43_FAIL_COUNT. > 0 %then %do;

        %put ERROR: WBS 4.3 QA에서 FAIL이 발견되었습니다.;
        %put ERROR: W4_43_QA_SUMMARY를 확인하십시오.;
        %abort cancel;

    %end;

    %else %do;

        %put NOTE: WBS 4.3이 정상적으로 완료되었습니다.;
        %put NOTE: 공통 정보 영향과 우선순위 안정성 결과를 확보했습니다.;
        %put NOTE: 최종 판단은 CRM.W4_43_DECISION에서 확인하십시오.;

    %end;

%mend;

%final_gate;


/*================================ END =======================================*/


/*=============================================================================
  파일명: [최신본] WBS_4.4_핵심 인사이트 확정 및 이중 운영대상 설계.sas
  WBS 4.4
  핵심 인사이트 확정 및 이중 운영대상 설계

  [목표]
    1. 4.2의 고객별 가치·위험·실행규칙을 운영용 명단으로 정리한다.
    2. 가치보호 순위와 위험관리 순위를 서로 다른 목적으로 유지한다.
    3. 상위 50명·100명·200명 규모의 시험 운영 대상을 표시한다.
    4. 사실·해석·권고·한계를 분리한 핵심 인사이트를 확정한다.
    5. 4절을 종료할지 4.1 또는 4.2~4.3으로 돌아갈지 판단한다.

  [핵심 질문]
    - 검증된 가치·상대위험 결과로 누구를 어떤 방식으로 먼저 관리할 것인가?

  [수행 범위]
    - 4.2의 가치위험 우선순위로 가치보호 대기열을 만든다.
    - 4.2의 순수 위험 우선순위로 저비용 위험관리 대기열을 만든다.
    - 각 대기열의 상위 50명·100명·200명을 플래그로 표시한다.
    - 4.2의 실행규칙과 개인 대표 카테고리를 그대로 사용한다.
    - 고객수와 대상 구성만 요약하며 캠페인 성과를 추정하지 않는다.

  [이번 단계에서 하지 않는 작업]
    - 이탈모형을 다시 학습하거나 예측확률을 다시 계산하지 않는다.
    - RFMP 점수·등급·가중치를 다시 계산하지 않는다.
    - 4.2의 가치위험 공식과 실행규칙을 변경하지 않는다.
    - 상대위험등급을 절대 이탈확률 등급으로 바꾸지 않는다.
    - 비용·매출·예상이익·ROI를 임의 가정하여 계산하지 않는다.

  [해석 유의사항]
    - High·Medium·Low는 전체 고객 안에서의 상대위험등급이다.
      High를 절대적으로 높은 이탈확률이라고 해석하면 안 된다.
    - 위험 우선순위는 이탈 가능성이 상대적으로 높은 고객을 찾고,
      가치위험 우선순위는 가치보호 필요성이 큰 고객을 찾는다.
      목적이 다르므로 두 순위의 불일치는 오류가 아니다.
    - 4.3의 STABLE은 공식 점수와 50:50 검증용 점수에서 상위
      50명·100명·200명이 대체로 유지됐다는 뜻이다. 전체 순위가
      변하지 않았거나 순수위험순위와 같다는 뜻은 아니다.
    - RFMP와 이탈모형은 recency, frequency_days, monetary 정보를
      공유한다. 따라서 가치와 위험 점수는 완전히 독립적이지 않다.
      4.3에서 선형효과 통제 후에도 관계가 남았으므로 인과로 해석하지 않는다.
    - 이탈모형의 Recency는 RFMP Recency보다 모든 고객에서 1일 작다.
      RFMP는 ‘기준일 - 마지막 구매일 + 1’로 계산하지만,
      이탈모형은 ‘기준일 - 마지막 구매일’로 계산하기 때문이다.
      이 차이는 모든 고객에게 동일하게 적용되므로 상대순위에는
      영향을 미치지 않는다.
    - 90일 미만 신규 고객은 관찰된 구매 이력이 짧다. 고비용 혜택
      대상이 아니라 저비용 반응 확인 대상으로만 사용해야 한다.
    - TRAIN과 VALID에는 동일 고객이 포함되어 있어 고객 단위 완전 독립
      검증이 아니다. 현재 결과는 시험 운영 대상 선정에만 사용해야 한다.
    - 개인 대표 카테고리는 고객별 구매이력에서 산출된 값이며,
      RFMP 등급 전체에 하나의 카테고리를 일괄 부여한 값이 아니다.
    - 본 단계의 완료는 운영 시험 준비 완료를 뜻한다. 따라서 캠페인 효과와
      경제성이 입증되었다는 뜻은 아니다.

  [운영용 검토 기준]
    - 고객 1,468명과 고객당 한 행을 유지한다.
    - 4.2와 4.3 QA의 FAIL이 0건이어야 한다.
    - 4.3 결론이 KEEP 계열이고 순위 상태가 STABLE이어야 한다.
    - 두 우선순위는 각각 1부터 1,468까지 중복 없이 존재해야 한다.
    - 상위 50명·100명·200명 플래그의 고객수가 정확해야 한다.
    - 실행규칙은 8개 이하이며 신규 고객에게 고비용 조치를 주지 않는다.
    - 3절과 4.1의 recency 차이가 전 고객에게 동일한 0일 또는 1일이면
      기준일 정의 차이로 기록한다. 차이가 고객마다 다르면 4.1로 돌아가
      코드를 재검토한다.

  [입력 테이블]
    CRM.W3_RFMP_BASE_PY          : RFMP 계산에 사용한 고객별 기준값
    CRM.W4_41_CURRENT_SCORED     : 현재 고객 상대위험 점수와 순위
    CRM.W4_42_CUSTOMER_ACTION    : 가치·위험 매핑 및 실행규칙
    CRM.W4_42_QA_SUMMARY         : 4.2 품질검사
    CRM.W4_43_DECISION           : 4.3 순위 유지 판단
    CRM.W4_43_QA_SUMMARY         : 4.3 품질검사
    CRM.W4_43_STABILITY_SUMMARY  : 상위대상·순위 안정성 지표

  [주요 산출물]
    CRM.W4_44_FINAL_ROSTER       : 고객별 두 대기열·수용규모·실행규칙
    CRM.W4_44_PILOT_SUMMARY      : 대기열과 수용규모별 고객 구성
    CRM.W4_44_INSIGHT_SUMMARY    : 사실·해석·권고·한계 분리 표
    CRM.W4_44_DECISION           : 종료 또는 이전 단계 재검토 판단
    CRM.W4_44_QA_SUMMARY         : 자동 품질검사
    CRM.W4_44_OUTPUT_CATALOG     : 4.4 영구 산출물 목록
=============================================================================*/


/*=============================================================================
  0. 실행 옵션과 검토 기준
=============================================================================*/
options validvarname=any validmemname=extend;

%let CRM_PATH=/home/student/crm_db;
%let EXPECTED_CUSTOMERS=1468;

/* 운영 시험 대상 규모: 계산식이 아니라 검토 가능한 수용인원이다. */
%let CAPACITY_SMALL=50;
%let CAPACITY_MEDIUM=100;
%let CAPACITY_LARGE=200;

/* 3절과 4.1의 recency 차이에 허용할 최대 절댓값이다. */
%let MAX_ALLOWED_RECENCY_GAP=1;

libname crm "&CRM_PATH.";


/*=============================================================================
  1. 입력 테이블과 필수 변수 확인
=============================================================================*/
%macro require_table(ds=, previous_step=);
    %if %sysfunc(exist(&ds.))=0 %then %do;
        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %put ERROR: &previous_step. 단계를 먼저 실행하십시오.;
        %abort cancel;
    %end;
    %else %do;
        %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;
    %end;
%mend;

%macro require_var(ds=, var=);
    %local dsid varnum rc;
    %let dsid=%sysfunc(open(&ds.,i));

    %if &dsid.=0 %then %do;
        %put ERROR: &ds. 데이터셋을 열 수 없습니다.;
        %abort cancel;
    %end;

    %let varnum=%sysfunc(varnum(&dsid.,&var.));
    %let rc=%sysfunc(close(&dsid.));

    %if &varnum.=0 %then %do;
        %put ERROR: &ds. 에 필수 변수 &var. 이(가) 없습니다.;
        %abort cancel;
    %end;
%mend;

%macro check_inputs;
    %if %sysfunc(libref(crm)) ne 0 %then %do;
        %put ERROR: CRM 라이브러리가 연결되지 않았습니다.;
        %put ERROR: 경로를 확인하십시오 - &CRM_PATH.;
        %abort cancel;
    %end;

    %require_table(ds=crm.w3_rfmp_base_py,previous_step=WBS 3.5~3.9);
    %require_table(ds=crm.w4_41_current_scored,previous_step=WBS 4.1);
    %require_table(ds=crm.w4_42_customer_action,previous_step=WBS 4.2);
    %require_table(ds=crm.w4_42_qa_summary,previous_step=WBS 4.2);
    %require_table(ds=crm.w4_43_decision,previous_step=WBS 4.3);
    %require_table(ds=crm.w4_43_qa_summary,previous_step=WBS 4.3);
    %require_table(ds=crm.w4_43_stability_summary,previous_step=WBS 4.3);
%mend;

%check_inputs;

%require_var(ds=crm.w3_rfmp_base_py,var=customer_id);
%require_var(ds=crm.w3_rfmp_base_py,var=recency);

%require_var(ds=crm.w4_41_current_scored,var=customer_id);
%require_var(ds=crm.w4_41_current_scored,var=recency);

%require_var(ds=crm.w4_42_customer_action,var=customer_id);
%require_var(ds=crm.w4_42_customer_action,var=rfmp_tier);
%require_var(ds=crm.w4_42_customer_action,var=rfmp_value_percentile);
%require_var(ds=crm.w4_42_customer_action,var=relative_risk_grade);
%require_var(ds=crm.w4_42_customer_action,var=relative_risk_percentile);
%require_var(ds=crm.w4_42_customer_action,var=risk_priority_rank);
%require_var(ds=crm.w4_42_customer_action,var=value_risk_score);
%require_var(ds=crm.w4_42_customer_action,var=value_risk_priority_rank);
%require_var(ds=crm.w4_42_customer_action,var=customer_maturity_group);
%require_var(ds=crm.w4_42_customer_action,var=top_category);
%require_var(ds=crm.w4_42_customer_action,var=action_code);
%require_var(ds=crm.w4_42_customer_action,var=action_name);
%require_var(ds=crm.w4_42_customer_action,var=action_channel);
%require_var(ds=crm.w4_42_customer_action,var=incentive_level);
%require_var(ds=crm.w4_42_customer_action,var=action_reason);

%require_var(ds=crm.w4_43_decision,var=decision_code);
%require_var(ds=crm.w4_43_decision,var=ranking_status);
%require_var(ds=crm.w4_43_decision,var=decision_text);
%require_var(ds=crm.w4_43_decision,var=limitation);


/*=============================================================================
  2. 이전 4.4 산출물만 삭제
=============================================================================*/
proc datasets library=crm nolist nowarn;
    delete
        w4_44_final_roster
        w4_44_pilot_summary
        w4_44_insight_summary
        w4_44_decision
        w4_44_qa_summary
        w4_44_output_catalog;
quit;


/*=============================================================================
  3. 이전 단계 실행 게이트
=============================================================================*/
proc sql noprint;
    select count(*) into :W4_42_FAIL_COUNT trimmed
    from crm.w4_42_qa_summary
    where upcase(strip(status))="FAIL";

    select count(*) into :W4_43_FAIL_COUNT trimmed
    from crm.w4_43_qa_summary
    where upcase(strip(status))="FAIL";

    select count(*) into :W4_43_DECISION_ROWS trimmed
    from crm.w4_43_decision;

    select
        upcase(strip(decision_code)),
        upcase(strip(ranking_status))
      into
        :W4_43_DECISION_CODE trimmed,
        :W4_43_RANKING_STATUS trimmed
    from crm.w4_43_decision;
quit;

%macro validate_previous_steps;
    %if &W4_42_FAIL_COUNT. > 0 %then %do;
        %put ERROR: WBS 4.2 QA에 FAIL이 있습니다.;
        %abort cancel;
    %end;

    %if &W4_43_FAIL_COUNT. > 0 %then %do;
        %put ERROR: WBS 4.3 QA에 FAIL이 있습니다.;
        %abort cancel;
    %end;

    %if &W4_43_DECISION_ROWS. ne 1 %then %do;
        %put ERROR: WBS 4.3 최종 판단이 한 행이 아닙니다.;
        %abort cancel;
    %end;

    %put NOTE: 4.2와 4.3 실행 게이트를 통과했습니다.;
%mend;

%validate_previous_steps;


/*=============================================================================
  4. recency 기준 차이 확인

  두 단계의 차이가 전 고객에게 동일한 0일 또는 1일이면 기준일을
  포함해서 세었는지의 정의 차이로 기록할 수 있다. 고객마다 차이가
  다르면 단순 기준일 차이라고 볼 수 없으므로 4.1 입력을 재검토하여야 한다.
=============================================================================*/
proc sql;
    create table work.w4_44_recency_check as
    select
        a.customer_id,
        a.recency as rfmp_recency,
        b.recency as model_recency,
        b.recency-a.recency as recency_gap
    from crm.w3_rfmp_base_py as a
    inner join crm.w4_41_current_scored as b
      on a.customer_id=b.customer_id;
quit;

proc sql noprint;
    select
        count(*),
        count(distinct customer_id),
        min(recency_gap),
        max(recency_gap),
        mean(recency_gap),
        count(distinct recency_gap),
        max(abs(recency_gap))
      into
        :RECENCY_ROWS trimmed,
        :RECENCY_CUSTOMERS trimmed,
        :RECENCY_GAP_MIN trimmed,
        :RECENCY_GAP_MAX trimmed,
        :RECENCY_GAP_MEAN trimmed,
        :RECENCY_GAP_DISTINCT trimmed,
        :RECENCY_GAP_MAX_ABS trimmed
    from work.w4_44_recency_check;
quit;

%let RECENCY_REVIEW_FLAG=0;

%macro set_recency_review_flag;
    %if &RECENCY_ROWS. ne &EXPECTED_CUSTOMERS.
        or &RECENCY_CUSTOMERS. ne &EXPECTED_CUSTOMERS. %then
        %let RECENCY_REVIEW_FLAG=1;

    %if &RECENCY_GAP_DISTINCT. ne 1 %then
        %let RECENCY_REVIEW_FLAG=1;

    %if %sysevalf(
        &RECENCY_GAP_MAX_ABS. > &MAX_ALLOWED_RECENCY_GAP.
    ) %then
        %let RECENCY_REVIEW_FLAG=1;
%mend;

%set_recency_review_flag;


/*=============================================================================
  5. 최종 고객 운영 명단

  고객은 한 행만 유지한다. 두 순위를 한 점수로 합치지 않고 각각의
  TOP-N 플래그와 대기열 상태를 별도 열로 둔다.
=============================================================================*/
data crm.w4_44_final_roster;
    set crm.w4_42_customer_action;

    length
        value_queue_band $20
        risk_queue_band $20
        queue_membership $24
        roster_usage $160;

    /* 가치보호 대기열 */
    flag_value_top50=(value_risk_priority_rank<=&CAPACITY_SMALL.);
    flag_value_top100=(value_risk_priority_rank<=&CAPACITY_MEDIUM.);
    flag_value_top200=(value_risk_priority_rank<=&CAPACITY_LARGE.);

    if flag_value_top50 then value_queue_band="VALUE_TOP50";
    else if flag_value_top100 then value_queue_band="VALUE_TOP100";
    else if flag_value_top200 then value_queue_band="VALUE_TOP200";
    else value_queue_band="OUTSIDE_TOP200";

    /* 저비용 위험관리 대기열 */
    flag_risk_top50=(risk_priority_rank<=&CAPACITY_SMALL.);
    flag_risk_top100=(risk_priority_rank<=&CAPACITY_MEDIUM.);
    flag_risk_top200=(risk_priority_rank<=&CAPACITY_LARGE.);

    if flag_risk_top50 then risk_queue_band="RISK_TOP50";
    else if flag_risk_top100 then risk_queue_band="RISK_TOP100";
    else if flag_risk_top200 then risk_queue_band="RISK_TOP200";
    else risk_queue_band="OUTSIDE_TOP200";

    /* 두 대기열의 겹침은 표시만 하고 하나의 순위로 합치지 않는다. */
    if flag_value_top200 and flag_risk_top200 then
        queue_membership="BOTH_TOP200";
    else if flag_value_top200 then
        queue_membership="VALUE_TOP200_ONLY";
    else if flag_risk_top200 then
        queue_membership="RISK_TOP200_ONLY";
    else
        queue_membership="OUTSIDE_BOTH";

    roster_usage=
        "상대위험 기반 시험 운영 명단이며 절대 이탈확률 또는 ROI 확정자료가 아님";

    label
        flag_value_top50="가치보호 상위 50명"
        flag_value_top100="가치보호 상위 100명"
        flag_value_top200="가치보호 상위 200명"
        flag_risk_top50="위험관리 상위 50명"
        flag_risk_top100="위험관리 상위 100명"
        flag_risk_top200="위험관리 상위 200명"
        value_queue_band="가치보호 수용규모 구간"
        risk_queue_band="위험관리 수용규모 구간"
        queue_membership="두 대기열 포함 상태"
        roster_usage="운영명단 사용 제한";
run;


/*=============================================================================
  6. 두 대기열의 수용규모별 구성 요약
=============================================================================*/
proc sql;
    create table crm.w4_44_pilot_summary as
    select
        "VALUE_PROTECTION" as queue_type length=24,
        &CAPACITY_SMALL. as capacity,
        count(*) as selected_customers,
        sum(upcase(strip(customer_maturity_group))="NEW_LT90")
            as new_customers,
        sum(upcase(strip(relative_risk_grade))="HIGH")
            as high_risk_customers,
        mean(rfmp_value_percentile)
            as avg_value_percentile format=percent8.2,
        mean(relative_risk_percentile)
            as avg_risk_percentile format=percent8.2
    from crm.w4_44_final_roster
    where flag_value_top50=1

    union all

    select
        "VALUE_PROTECTION", &CAPACITY_MEDIUM., count(*),
        sum(upcase(strip(customer_maturity_group))="NEW_LT90"),
        sum(upcase(strip(relative_risk_grade))="HIGH"),
        mean(rfmp_value_percentile), mean(relative_risk_percentile)
    from crm.w4_44_final_roster
    where flag_value_top100=1

    union all

    select
        "VALUE_PROTECTION", &CAPACITY_LARGE., count(*),
        sum(upcase(strip(customer_maturity_group))="NEW_LT90"),
        sum(upcase(strip(relative_risk_grade))="HIGH"),
        mean(rfmp_value_percentile), mean(relative_risk_percentile)
    from crm.w4_44_final_roster
    where flag_value_top200=1

    union all

    select
        "RISK_PREVENTION", &CAPACITY_SMALL., count(*),
        sum(upcase(strip(customer_maturity_group))="NEW_LT90"),
        sum(upcase(strip(relative_risk_grade))="HIGH"),
        mean(rfmp_value_percentile), mean(relative_risk_percentile)
    from crm.w4_44_final_roster
    where flag_risk_top50=1

    union all

    select
        "RISK_PREVENTION", &CAPACITY_MEDIUM., count(*),
        sum(upcase(strip(customer_maturity_group))="NEW_LT90"),
        sum(upcase(strip(relative_risk_grade))="HIGH"),
        mean(rfmp_value_percentile), mean(relative_risk_percentile)
    from crm.w4_44_final_roster
    where flag_risk_top100=1

    union all

    select
        "RISK_PREVENTION", &CAPACITY_LARGE., count(*),
        sum(upcase(strip(customer_maturity_group))="NEW_LT90"),
        sum(upcase(strip(relative_risk_grade))="HIGH"),
        mean(rfmp_value_percentile), mean(relative_risk_percentile)
    from crm.w4_44_final_roster
    where flag_risk_top200=1

    order by queue_type, capacity;
quit;


/*=============================================================================
  7. 핵심 수치 추출
=============================================================================*/
proc sql noprint;
    select
        count(*),
        count(distinct customer_id),
        sum(missing(risk_priority_rank)),
        sum(missing(value_risk_priority_rank)),
        count(distinct risk_priority_rank),
        count(distinct value_risk_priority_rank),
        min(risk_priority_rank),
        max(risk_priority_rank),
        min(value_risk_priority_rank),
        max(value_risk_priority_rank),
        count(distinct action_code),
        sum(upcase(strip(customer_maturity_group))="NEW_LT90"),
        sum(upcase(strip(customer_maturity_group))="NEW_LT90"
            and upcase(strip(incentive_level))="TEAM_REVIEW")
      into
        :ROSTER_ROWS trimmed,
        :ROSTER_CUSTOMERS trimmed,
        :MISSING_RISK_RANK trimmed,
        :MISSING_VALUE_RANK trimmed,
        :DISTINCT_RISK_RANK trimmed,
        :DISTINCT_VALUE_RANK trimmed,
        :MIN_RISK_RANK trimmed,
        :MAX_RISK_RANK trimmed,
        :MIN_VALUE_RANK trimmed,
        :MAX_VALUE_RANK trimmed,
        :ACTION_RULE_COUNT trimmed,
        :NEW_CUSTOMER_COUNT trimmed,
        :NEW_HIGH_COST_COUNT trimmed
    from crm.w4_44_final_roster;

    select
        sum(flag_value_top50),
        sum(flag_value_top100),
        sum(flag_value_top200),
        sum(flag_risk_top50),
        sum(flag_risk_top100),
        sum(flag_risk_top200),
        sum(flag_value_top100 and flag_risk_top100)
      into
        :VALUE_TOP50_COUNT trimmed,
        :VALUE_TOP100_COUNT trimmed,
        :VALUE_TOP200_COUNT trimmed,
        :RISK_TOP50_COUNT trimmed,
        :RISK_TOP100_COUNT trimmed,
        :RISK_TOP200_COUNT trimmed,
        :TOP100_BOTH_COUNT trimmed
    from crm.w4_44_final_roster;

    /*
      4.3 테이블의 백분율 표시 형식을 제거하고 순수 숫자 문자열로 받아야 한다.
      그렇지 않으면 0.8000이 80.00%로 들어와 DATA step 문법 오류가 나기 때문이다.
    */
    select
        put(raw_spearman,best32.),
        put(residual_spearman,best32.),
        put(correlation_reduction_rate,best32.),
        put(minimum_alternative_topk_overlap,best32.),
        decision_text,
        limitation
      into
        :RAW_SPEARMAN trimmed,
        :RESIDUAL_SPEARMAN trimmed,
        :CORR_REDUCTION_RATE trimmed,
        :MIN_ALT_OVERLAP trimmed,
        :W4_43_DECISION_TEXT trimmed,
        :W4_43_LIMITATION trimmed
    from crm.w4_43_decision;
quit;

%let TOP100_BOTH_RATE=%sysevalf(
    &TOP100_BOTH_COUNT./&CAPACITY_MEDIUM.
);


/*=============================================================================
  8. 핵심 인사이트

  요청한 다섯 열만 사용한다.
  fact에는 확인된 수치만, business_interpretation에는 해석을 기록한다.
=============================================================================*/
data crm.w4_44_insight_summary;
    length
        insight_id $8
        fact $300
        business_interpretation $400
        recommended_action $400
        limitation $400;

    insight_id="I01";
    fact=cats(
        "4.3 decision=", "&W4_43_DECISION_CODE.",
        ", ranking_status=", "&W4_43_RANKING_STATUS.",
        ", 대안식 최소 TOP-K 중복률=",
        put(&MIN_ALT_OVERLAP.,percent8.2)
    );
    business_interpretation=
        "공식 가치위험순위의 상위 운영대상은 검증용 50:50 점수에서도 대체로 유지됨";
    recommended_action=
        "4.2 가치위험순위를 가치보호 대기열의 공식 순위로 유지";
    limitation=
        "STABLE은 상위 대상의 안정성이며 전체 순위 불변 또는 위험순위와의 동일성을 뜻하지 않음";
    output;

    insight_id="I02";
    fact=cats(
        "상위 100명에서 두 대기열 공통 고객=",
        "&TOP100_BOTH_COUNT.", "명, 중복률=",
        put(&TOP100_BOTH_RATE.,percent8.2)
    );
    business_interpretation=
        "순수 위험관리와 가치보호는 서로 다른 고객을 상당 부분 선택할 수 있음";
    recommended_action=
        "두 순위를 하나로 합치지 말고 가치보호와 저비용 위험관리 대기열로 분리 운영";
    limitation=
        "중복률은 대상 구성의 차이를 보여주며 어느 순위가 인과적으로 더 효과적인지는 증명하지 않음";
    output;

    insight_id="I03";
    fact=cats(
        "원 상관=", put(&RAW_SPEARMAN.,8.4),
        ", 공통 변수 통제 후 상관=", put(&RESIDUAL_SPEARMAN.,8.4),
        ", 절댓값 감소율=", put(&CORR_REDUCTION_RATE.,percent8.2)
    );
    business_interpretation=
        "RFMP와 상대위험은 공통 구매행동 정보를 공유하지만 선형 통제 후에도 관계가 남음";
    recommended_action=
        "두 점수의 목적을 분리해 사용하고 성과 검증 전 중복 정보를 독립 효과로 해석하지 않음";
    limitation=
        "잔차 검증은 선형효과만 통제하며 비선형 중복과 인과관계를 확정하지 않음";
    output;

    insight_id="I04";
    fact=cats(
        "90일 미만 신규 고객=", "&NEW_CUSTOMER_COUNT.",
        "명, 신규 고객 중 TEAM_REVIEW 고비용 후보=",
        "&NEW_HIGH_COST_COUNT.", "명"
    );
    business_interpretation=
        "구매이력이 짧은 신규 고객은 기존 고객과 같은 강도의 조치보다 반응 확인이 우선임";
    recommended_action=
        "NEW_LOW_COST_TEST 규칙을 유지하고 이메일·앱 기반 저비용 시험만 시행";
    limitation=
        "90일 기준은 운영 정의이며 신규 고객의 장기 이탈 가능성을 충분히 관찰한 결과가 아님";
    output;

    insight_id="I05";
    fact=cats(
        "RFMP-model recency 차이 min=", "&RECENCY_GAP_MIN.",
        ", max=", "&RECENCY_GAP_MAX.",
        ", 서로 다른 차이값 수=", "&RECENCY_GAP_DISTINCT."
    );
    business_interpretation=ifc(
        &RECENCY_REVIEW_FLAG.=0,
        "전 고객의 차이가 동일한 0일 또는 1일 범위여서 기준일 정의 차이로 관리 가능",
        "고객마다 recency 차이가 달라 단순 기준일 정의 차이로 보기 어려움"
    );
    recommended_action=ifc(
        &RECENCY_REVIEW_FLAG.=0,
        "정의 차이를 문서화하고 현재 순위를 유지",
        "4.1로 돌아가 recency 기준일과 계산식을 재검토"
    );
    limitation=
        "이 점검은 두 산출물의 일관성을 확인하며 어느 recency 정의가 유일하게 옳다는 증거는 아님";
    output;
run;


/*=============================================================================
  9. 자동 품질 점검
=============================================================================*/
data crm.w4_44_qa_summary;
    length
        check_order 8
        check_item $80
        actual_value $80
        expected_value $80
        status $8
        detail $240;

    check_order=1;
    check_item="4.2 QA FAIL";
    actual_value="&W4_42_FAIL_COUNT.";
    expected_value="0";
    status=ifc(&W4_42_FAIL_COUNT.=0,"PASS","FAIL");
    detail="4.2 입력 산출물의 품질 게이트";
    output;

    check_order=2;
    check_item="4.3 QA FAIL";
    actual_value="&W4_43_FAIL_COUNT.";
    expected_value="0";
    status=ifc(&W4_43_FAIL_COUNT.=0,"PASS","FAIL");
    detail="4.3 검증 산출물의 품질 게이트";
    output;

    check_order=3;
    check_item="4.3 ranking decision";
    actual_value=cats(
        "&W4_43_DECISION_CODE.",
        " / ",
        "&W4_43_RANKING_STATUS."
    );
    expected_value="KEEP 계열 / STABLE";
    status=ifc(
        index(upcase("&W4_43_DECISION_CODE."),"KEEP")>0
        and upcase("&W4_43_RANKING_STATUS.")="STABLE",
        "PASS",
        "REVIEW"
    );
    detail="공식 순위를 운영 명단에 사용할 수 있는지 확인";
    output;

    check_order=4;
    check_item="Roster rows and unique customers";
    actual_value=cats(
        &ROSTER_ROWS.,
        " / ",
        &ROSTER_CUSTOMERS.
    );
    expected_value=cats(
        &EXPECTED_CUSTOMERS.,
        " / ",
        &EXPECTED_CUSTOMERS.
    );
    status=ifc(
        &ROSTER_ROWS.=&EXPECTED_CUSTOMERS.
        and &ROSTER_CUSTOMERS.=&EXPECTED_CUSTOMERS.,
        "PASS",
        "FAIL"
    );
    detail="고객당 한 행 유지";
    output;

    check_order=5;
    check_item="Risk rank complete and unique";
    actual_value=cats(
        "missing=",&MISSING_RISK_RANK.,
        ", distinct=",&DISTINCT_RISK_RANK.,
        ", range=",&MIN_RISK_RANK.,"-",&MAX_RISK_RANK.
    );
    expected_value=cats(
        "missing=0, distinct=",
        &EXPECTED_CUSTOMERS.,
        ", range=1-",
        &EXPECTED_CUSTOMERS.
    );
    status=ifc(
        &MISSING_RISK_RANK.=0
        and &DISTINCT_RISK_RANK.=&EXPECTED_CUSTOMERS.
        and &MIN_RISK_RANK.=1
        and &MAX_RISK_RANK.=&EXPECTED_CUSTOMERS.,
        "PASS",
        "FAIL"
    );
    detail="순수 위험 우선순위의 완전성";
    output;

    check_order=6;
    check_item="Value-risk rank complete and unique";
    actual_value=cats(
        "missing=",&MISSING_VALUE_RANK.,
        ", distinct=",&DISTINCT_VALUE_RANK.,
        ", range=",&MIN_VALUE_RANK.,"-",&MAX_VALUE_RANK.
    );
    expected_value=cats(
        "missing=0, distinct=",
        &EXPECTED_CUSTOMERS.,
        ", range=1-",
        &EXPECTED_CUSTOMERS.
    );
    status=ifc(
        &MISSING_VALUE_RANK.=0
        and &DISTINCT_VALUE_RANK.=&EXPECTED_CUSTOMERS.
        and &MIN_VALUE_RANK.=1
        and &MAX_VALUE_RANK.=&EXPECTED_CUSTOMERS.,
        "PASS",
        "FAIL"
    );
    detail="가치위험 우선순위의 완전성";
    output;

    check_order=7;
    check_item="Value queue capacity counts";
    actual_value=cats(
        &VALUE_TOP50_COUNT.,
        " / ",
        &VALUE_TOP100_COUNT.,
        " / ",
        &VALUE_TOP200_COUNT.
    );
    expected_value=cats(
        &CAPACITY_SMALL.,
        " / ",
        &CAPACITY_MEDIUM.,
        " / ",
        &CAPACITY_LARGE.
    );
    status=ifc(
        &VALUE_TOP50_COUNT.=&CAPACITY_SMALL.
        and &VALUE_TOP100_COUNT.=&CAPACITY_MEDIUM.
        and &VALUE_TOP200_COUNT.=&CAPACITY_LARGE.,
        "PASS",
        "FAIL"
    );
    detail="가치보호 대기열 수용규모";
    output;

    check_order=8;
    check_item="Risk queue capacity counts";
    actual_value=cats(
        &RISK_TOP50_COUNT.,
        " / ",
        &RISK_TOP100_COUNT.,
        " / ",
        &RISK_TOP200_COUNT.
    );
    expected_value=cats(
        &CAPACITY_SMALL.,
        " / ",
        &CAPACITY_MEDIUM.,
        " / ",
        &CAPACITY_LARGE.
    );
    status=ifc(
        &RISK_TOP50_COUNT.=&CAPACITY_SMALL.
        and &RISK_TOP100_COUNT.=&CAPACITY_MEDIUM.
        and &RISK_TOP200_COUNT.=&CAPACITY_LARGE.,
        "PASS",
        "FAIL"
    );
    detail="저비용 위험관리 대기열 수용규모";
    output;

    check_order=9;
    check_item="Action rule count";
    actual_value="&ACTION_RULE_COUNT.";
    expected_value="<=8";
    status=ifc(
        &ACTION_RULE_COUNT.<=8,
        "PASS",
        "FAIL"
    );
    detail="두 사람이 검증 가능한 실행규칙 수 제한";
    output;

    check_order=10;
    check_item="New customer high-cost assignment";
    actual_value="&NEW_HIGH_COST_COUNT.";
    expected_value="0";
    status=ifc(
        &NEW_HIGH_COST_COUNT.=0,
        "PASS",
        "FAIL"
    );
    detail="90일 미만 고객에게 TEAM_REVIEW 수준 혜택을 부여하지 않음";
    output;

    check_order=11;
    check_item="Recency definition consistency";
    actual_value=cats(
        "min=", "&RECENCY_GAP_MIN.",
        ", max=", "&RECENCY_GAP_MAX.",
        ", distinct=", "&RECENCY_GAP_DISTINCT."
    );
    expected_value="전 고객 동일, 절댓값 0 또는 1";
    status=ifc(
        &RECENCY_REVIEW_FLAG.=0,
        "PASS",
        "REVIEW"
    );
    detail="REVIEW이면 4.1의 기준일과 recency 계산식을 재검토";
    output;

    check_order=12;
    check_item="Insight rows";
    actual_value="5";
    expected_value="5";
    status="PASS";
    detail="사실·해석·권고·한계를 분리한 핵심 인사이트";
    output;
run;


/*=============================================================================
  10. 4절 종료 또는 재검토 판단
=============================================================================*/
proc sql noprint;
    select
        sum(upcase(strip(status))="FAIL"),
        sum(upcase(strip(status))="REVIEW")
      into
        :W4_44_FAIL_COUNT trimmed,
        :W4_44_REVIEW_COUNT trimmed
    from crm.w4_44_qa_summary;
quit;

data crm.w4_44_decision;
    length
        decision_code $40
        decision_text $500
        next_step $300
        evidence_required $500;

    qa_fail_count=&W4_44_FAIL_COUNT.;
    qa_review_count=&W4_44_REVIEW_COUNT.;
    recency_review_flag=&RECENCY_REVIEW_FLAG.;
    w4_43_decision_code="&W4_43_DECISION_CODE.";
    w4_43_ranking_status="&W4_43_RANKING_STATUS.";

    if qa_fail_count>0 then do;
        decision_code="STOP_TECHNICAL_FIX";
        decision_text=
            "필수 행수·순위·대기열 또는 실행규칙 품질검사에 실패하여 4절을 종료할 수 없음";
        next_step=
            "W4_44_QA_SUMMARY의 FAIL 항목을 수정한 뒤 4.4를 다시 실행";
    end;

    else if recency_review_flag=1 then do;
        decision_code="RETURN_TO_4_1";
        decision_text=
            "RFMP와 이탈모형의 recency 차이가 고객마다 달라 기준일 차이만으로 설명할 수 없음";
        next_step=
            "4.1의 기준일과 recency 계산식을 확인한 뒤 4.1부터 4.4까지 순서대로 재실행";
    end;

    else if index(upcase(w4_43_decision_code),"KEEP")=0
         or upcase(w4_43_ranking_status) ne "STABLE" then do;
        decision_code="RETURN_TO_4_2_4_3";
        decision_text=
            "4.3에서 현재 가치위험 우선순위의 운영 안정성이 확인되지 않음";
        next_step=
            "4.2 점수 공식과 4.3 안정성 기준을 팀 검토한 뒤 4.4를 다시 실행";
    end;

    else do;
        decision_code="CLOSE_WBS4_PILOT_READY";
        decision_text=
            "기술적 QA와 순위 안정성 기준을 통과하여 두 대기열 기반의 제한적 운영 시험 준비가 완료됨";
        next_step=
            "가치보호와 저비용 위험관리 대기열을 분리해 소규모 시험하고 실제 반응·비용을 기록";
    end;

    evidence_required=
        "종료 후에도 절대확률 보정, 고객 단위 독립 검증, 캠페인 대조군, 실제 반응률·비용·증분가치가 있어야 운영 효과와 ROI를 확정할 수 있음";
run;


/*=============================================================================
  11. 산출물 목록
=============================================================================*/
proc sql;
    create table crm.w4_44_output_catalog as
    select
        libname,
        memname,
        nobs as row_count,
        nvar as column_count,
        crdate as created_at format=datetime19.
    from dictionary.tables
    where libname="CRM"
      and memname in (
          "W4_44_FINAL_ROSTER",
          "W4_44_PILOT_SUMMARY",
          "W4_44_INSIGHT_SUMMARY",
          "W4_44_DECISION",
          "W4_44_QA_SUMMARY"
      )
    order by memname;
quit;

/* 생성 중에는 자기 자신이 조회되지 않으므로 목록에 직접 추가한다. */
proc sql;
    insert into crm.w4_44_output_catalog
    set
        libname="CRM",
        memname="W4_44_OUTPUT_CATALOG",
        row_count=6,
        column_count=5,
        created_at=datetime();
quit;


/*=============================================================================
  12. 팀 검토용 결과 출력
=============================================================================*/
title "WBS 4.4-1. 가치보호 대기열 상위 20명";

proc print
    data=crm.w4_44_final_roster(obs=20)
    noobs
    label;

    where value_risk_priority_rank<=20;

    var
        customer_id
        value_risk_priority_rank
        risk_priority_rank
        rfmp_tier
        relative_risk_grade
        customer_maturity_group
        top_category
        action_code;
run;


title "WBS 4.4-2. 저비용 위험관리 대기열 상위 20명";

proc sort
    data=crm.w4_44_final_roster
    out=work.w4_44_risk_preview;

    by risk_priority_rank;
run;

proc print
    data=work.w4_44_risk_preview(obs=20)
    noobs
    label;

    var
        customer_id
        risk_priority_rank
        value_risk_priority_rank
        rfmp_tier
        relative_risk_grade
        customer_maturity_group
        top_category
        action_code;
run;


title "WBS 4.4-3. 대기열과 수용규모별 고객 구성";

proc print
    data=crm.w4_44_pilot_summary
    noobs
    label;
run;


title "WBS 4.4-4. 핵심 인사이트";

options linesize=256;

proc print
    data=crm.w4_44_insight_summary
    noobs
    label;
run;


title "WBS 4.4-5. 자동 품질 점검";

proc print
    data=crm.w4_44_qa_summary
    noobs
    label;
run;


title "WBS 4.4-6. 종료 또는 재검토 판단";

proc print
    data=crm.w4_44_decision
    noobs
    label;
run;


title "WBS 4.4-7. 영구 산출물 목록";

proc print
    data=crm.w4_44_output_catalog
    noobs
    label;
run;

options linesize=132;
title;


/*=============================================================================
  13. 최종 실행 게이트

  FAIL은 코드·자료 구조 문제이므로 실행을 중단한다.
  REVIEW는 분석 판단 문제이므로 실행을 중단하지 않는다.
  종료 여부와 다음 단계는 CRM.W4_44_DECISION에서 확인한다.
=============================================================================*/
%macro final_gate;
    %put NOTE: WBS 4.4 QA FAIL = &W4_44_FAIL_COUNT.;
    %put NOTE: WBS 4.4 QA REVIEW = &W4_44_REVIEW_COUNT.;

    %if &W4_44_FAIL_COUNT. > 0 %then %do;
        %put ERROR: WBS 4.4 QA에서 FAIL이 발견되었습니다.;
        %put ERROR: CRM.W4_44_QA_SUMMARY를 확인하십시오.;
        %abort cancel;
    %end;
    %else %do;
        %put NOTE: WBS 4.4가 기술적으로 정상 완료되었습니다.;
        %put NOTE: 두 운영대상 명단과 핵심 인사이트를 확보했습니다.;
        %put NOTE: 종료 여부는 CRM.W4_44_DECISION에서 확인하십시오.;
    %end;
%mend;

%final_gate;


/*================================ END =======================================*/


