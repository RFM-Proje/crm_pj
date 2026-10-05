"""r4-1.sas -> Python 변환본 (WBS 4.1 ~ 4.4)

  4.1  B_DAYS 로지스틱 기준모형 재현·검증, 전체 고객 상대위험 점수/순위   -> crm.w4_41_*
  4.2  RFMP 가치 x 상대위험(High/Medium/Low) 매핑, 가치위험순위, 실행규칙 7개 -> crm.w4_42_*
  4.3  공통 변수(R·F·M) 통제 전후 상관, 50:50 대안점수와 상위대상 안정성     -> crm.w4_43_*
  4.4  가치보호·위험관리 두 대기열(Top 50/100/200) 운영명단과 핵심 인사이트  -> crm.w4_44_*

변환 원칙
  - 4.1 의 PROC PYTHON 블록은 원문 그대로 두고 SAS 객체만 rcommon.SASBridge 로 연결한다.
  - 4.2~4.4 의 DATA step / PROC SQL / PROC SORT / PROC CORR / PROC REG 는 pandas·numpy 로 옮겼다.
      PROC CORR SPEARMAN -> 평균순위 상관, PROC REG 잔차 -> 절편 포함 최소제곱 잔차
  - %abort cancel 실행 게이트는 SystemExit 로 동일하게 멈춘다.

실행 순서: r1-1.py -> r2-2.py -> r3-1.py -> r4-1.py -> r5_viz.py
"""

import numpy as np
import pandas as pd

import rcommon as rc
from rcommon import (SASBridge, abort, delete, exists, load, proc_freq, proc_print,
                     require_table, save)

# ======================================================================
# WBS 4.1 Revised v2. B_DAYS 기준모형 검증 및 전체 고객 상대위험 점수 생성
# ======================================================================

# 0. 실행 옵션과 프로젝트 기준값 (%let)
MACROS = {"RANDOM_SEED": 2026, "MIN_VALID_AUC": 0.60, "MIN_NEW_VALID_AUC": 0.60,
          "MAX_MEAN_PROB_GAP": 0.05, "MODEL_MATCH_TOL": 0.000001,
          "HISTORY_CUT1": 90, "HISTORY_CUT2": 180}
SAS = SASBridge(macros=MACROS, plot_prefix="r41_pyplot")

# 1. 필수 입력 테이블
for _t, _step in [("w3_freq_abc_input", "WBS 3.2-A"), ("w3_freq_abc_metrics", "WBS 3.3-A"),
                  ("w3_freq_abc_decision", "WBS 3.3-A"), ("w3_frequency_policy", "WBS 3.4"),
                  ("w3_customer_rfmp_py", "WBS 3.5~3.9"), ("clean_online", "Week 1 정제"),
                  ("clean_customer", "Week 1 정제")]:
    require_table(_t, _step)

# 2. 이전 4.1 산출물 삭제
delete("w4_41_model_metrics", "w4_41_cohort_metrics", "w4_41_valid_scored", "w4_41_current_scored",
       "w4_41_topk_performance", "w4_41_coefficients", "w4_41_model_config",
       "w4_41_model_decision", "w4_41_qa_summary", "w4_41_output_catalog")

# 3. 3절에서 B_DAYS 와 frequency_days 가 선택되었는지 확인
SELECTED_MODEL = str(load("w3_freq_abc_decision")["selected_model"].iloc[0]).strip().upper()
_pol = load("w3_frequency_policy").iloc[0]
SELECTED_OPTION = str(_pol["selected_option"]).strip().upper()
OFFICIAL_FREQUENCY = str(_pol["official_frequency_variable"]).strip().lower()
if SELECTED_MODEL != "B_DAYS":
    abort("3.3의 선택 모형이 B_DAYS가 아닙니다.")
if SELECTED_OPTION != "B_DAYS":
    abort("3.4의 선택 옵션이 B_DAYS가 아닙니다.")
if OFFICIAL_FREQUENCY != "frequency_days":
    abort("공식 Frequency 변수가 frequency_days가 아닙니다.")
print("NOTE: 3절 B_DAYS 정책을 확인했습니다.")

# ---- 4. PROC PYTHON (원문) ------------------------------------------------
# [r4-1.sas 146~898행 원문]
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
# 쿠폰 변수(coupon_usage_rate, coupon_click_rate, last_coupon_used)는 분석 범위에서 제외 - 팀 결정
common_numeric_features = [
    "recency", "monetary", "avg_order_value", "avg_shipping", "tenure",
    "product_category_count", "category_concentration",
    "avg_days_between_orders", "std_days_between_orders"
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
model = Pipeline([("log", rc.LogSkewed()),   # 3.3 과 같은 log1p 변환 (rcommon.LOG_FEATURES)
                  ("preprocessor", preprocessor), ("classifier", classifier)])
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
     "LogisticRegression", "log1p(치우친 변수) + L2, C=1.0, liblinear"),
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
# ---- PROC PYTHON 끝 ------------------------------------------------------

# 5. 산출물 존재 여부와 목록
_w41 = ["w4_41_model_metrics", "w4_41_cohort_metrics", "w4_41_valid_scored", "w4_41_current_scored",
        "w4_41_topk_performance", "w4_41_coefficients", "w4_41_model_config",
        "w4_41_model_decision", "w4_41_qa_summary"]
for _t in _w41:
    print(f"NOTE: 산출물 crm.{_t} 을(를) 확인했습니다." if exists(_t)
          else f"ERROR: 필수 산출물 crm.{_t} 이(가) 생성되지 않았습니다.")


def output_catalog(prefix):
    rows = []
    for p in sorted(rc.CRM_DIR.glob(f"{prefix}*.pkl")):
        df = pd.read_pickle(p)
        rows.append({"table_name": p.stem.upper(), "row_count": len(df), "column_count": df.shape[1],
                     "created_datetime": pd.Timestamp(p.stat().st_ctime, unit="s")})
    return pd.DataFrame(rows)


save(output_catalog("w4_41_"), "w4_41_output_catalog")

# 6. 주요 결과 출력
proc_print(load("w4_41_model_metrics"), "WBS 4.1-1. B_DAYS 기준모형 성능", dec=4,
           png="r41_01_model_metrics")
proc_print(load("w4_41_cohort_metrics"), "WBS 4.1-2. 구매 이력 길이별 VALID 성능", dec=4,
           var=["history_band", "customer_count", "churn_count", "actual_churn_rate",
                "mean_probability", "probability_gap", "roc_auc", "pr_auc", "brier_score", "log_loss"],
           png="r41_02_cohort_metrics")
proc_print(load("w4_41_topk_performance"), "WBS 4.1-3. VALID 상위 100명·200명 포착 성과", dec=3,
           png="r41_03_topk")
proc_print(load("w4_41_coefficients"), "WBS 4.1-4. 기준모형 계수 상위 20개", obs=20, dec=5,
           var=["importance_rank", "feature_name", "coefficient", "absolute_coefficient",
                "coefficient_direction"], png="r41_04_coefficients")
proc_print(load("w4_41_current_scored"), "WBS 4.1-5. 전체 고객 상대위험순위 상위 20명", obs=20, dec=4,
           var=["risk_priority_rank", "customer_id", "raw_churn_probability", "relative_risk_percentile",
                "customer_maturity_group", "frequency_days", "recency", "monetary"],
           png="r41_05_top20_risk")
proc_print(load("w4_41_model_decision").T.reset_index().set_axis(["항목", "값"], axis=1),
           "WBS 4.1-6. 기준모형 사용 결정", png="r41_06_model_decision")
proc_print(load("w4_41_qa_summary"), "WBS 4.1-7. 자동 품질 점검", png="r41_07_qa_summary")
proc_print(load("w4_41_output_catalog"), "WBS 4.1-8. 산출물 목록")

# 7. 최종 실행 게이트
_qa41 = load("w4_41_qa_summary")
W4_41_FAIL_COUNT = int((_qa41["status"].astype(str).str.strip().str.upper() == "FAIL").sum())
W4_41_REVIEW_COUNT = int((_qa41["status"].astype(str).str.strip().str.upper() == "REVIEW").sum())
print(f"NOTE: WBS 4.1 QA FAIL = {W4_41_FAIL_COUNT}")
print(f"NOTE: WBS 4.1 QA REVIEW = {W4_41_REVIEW_COUNT}")
if W4_41_FAIL_COUNT > 0:
    abort("WBS 4.1 QA에서 FAIL이 발견되었습니다. W4_41_QA_SUMMARY를 확인한 뒤 수정하십시오.")
print("NOTE: WBS 4.1 치명적 오류 점검을 통과했습니다. REVIEW 항목은 분석 한계로 기록하십시오.")


# ======================================================================
# WBS 4.2. RFMP 고객가치 x 상대이탈위험 매핑 및 실행규칙 설계
# ======================================================================

EXPECTED_CUSTOMERS = int(load("w3_customer_rfmp_py")["customer_id"].nunique())   # 3절 RFMP 모집단에서 계산 (고정값 1468 제거)
MAX_ACTION_RULES = 8


def require_vars(name, cols):
    """%require_var"""
    have = set(load(name).columns)
    for c in cols:
        if c not in have:
            abort(f"crm.{name} 에 필수 변수 {c} 이(가) 없습니다.")


for _t, _step in [("w3_customer_rfmp_py", "WBS 3.5~3.9"), ("w3_customer_category_p_py", "WBS 3.5~3.9"),
                  ("w3_rfmp_qa_summary_py", "WBS 3.5~3.9"), ("w4_41_current_scored", "WBS 4.1"),
                  ("w4_41_model_decision", "WBS 4.1"), ("w4_41_qa_summary", "WBS 4.1")]:
    require_table(_t, _step)
require_vars("w3_customer_rfmp_py", ["customer_id", "rfmp_score", "rfmp_tier", "tier_code",
                                     "frequency_days", "monetary"])
require_vars("w3_customer_category_p_py", ["customer_id", "product_category", "customer_category_days",
                                           "customer_category_orders", "category_p_contribution"])
require_vars("w4_41_current_scored", ["customer_id", "raw_churn_probability", "relative_risk_percentile",
                                      "risk_priority_rank", "customer_maturity_group", "score_version",
                                      "probability_usage"])
delete("w4_42_customer_action", "w4_42_segment_summary", "w4_42_qa_summary")


def fail_count(name):
    return int((load(name)["status"].astype(str).str.strip().str.upper() == "FAIL").sum())


# 3. 이전 단계 품질검사와 4.1 결정 확인
W3_FAIL_COUNT = fail_count("w3_rfmp_qa_summary_py")
W4_41_FAIL_COUNT = fail_count("w4_41_qa_summary")
_decision = load("w4_41_model_decision")
DECISION_ROW_COUNT = len(_decision)
_d0 = _decision.iloc[0]
DECISION_CODE = str(_d0["decision_code"]).strip().upper()
PROBABILITY_USAGE = str(_d0["probability_usage"]).strip().upper()
ABSOLUTE_STATUS = str(_d0["absolute_probability_status"]).strip().upper()
EXPECTED_SCORE_VERSION = str(_d0["score_version"]).strip()
if W3_FAIL_COUNT > 0:
    abort("WBS 3.5~3.9 QA에 FAIL이 있습니다.")
if W4_41_FAIL_COUNT > 0:
    abort("WBS 4.1 QA에 FAIL이 있습니다.")
if DECISION_ROW_COUNT != 1:
    abort("W4_41_MODEL_DECISION은 정확히 1행이어야 합니다.")
if DECISION_CODE != "USE_B_DAYS_RELATIVE_RANK":
    abort("4.1에서 상대위험순위 사용이 승인되지 않았습니다.")
if PROBABILITY_USAGE != "RELATIVE_RANK_ONLY":
    abort("4.1 확률 사용 원칙이 RELATIVE_RANK_ONLY가 아닙니다.")
if ABSOLUTE_STATUS != "NOT_APPROVED":
    abort("절대확률 사용 상태를 다시 확인하십시오.")
print("NOTE: 3.5~3.9와 4.1의 실행 게이트를 통과했습니다.")

# 4. 고객별 대표 카테고리 (P 기여도 > 구매일 수 > 주문 수 > 카테고리명)
_cat = load("w3_customer_category_p_py")
_cat = _cat[_cat["customer_id"].notna()].sort_values(
    ["customer_id", "category_p_contribution", "customer_category_days", "customer_category_orders",
     "product_category"], ascending=[True, False, False, False, True], kind="mergesort")
w4_42_customer_top_category = (_cat.drop_duplicates("customer_id", keep="first")
                               .assign(top_category=lambda d: d["product_category"].astype(str).str.strip())
                               .rename(columns={"category_p_contribution": "top_category_p_contribution",
                                                "customer_category_days": "top_category_purchase_days",
                                                "customer_category_orders": "top_category_orders"})
                               [["customer_id", "top_category", "top_category_p_contribution",
                                 "top_category_purchase_days", "top_category_orders"]])

# 5. RFMP 가치와 4.1 상대위험 결합
_rfmp = load("w3_customer_rfmp_py")[["customer_id", "rfmp_score", "rfmp_tier", "tier_code",
                                     "frequency_days", "monetary"]]
_scored = load("w4_41_current_scored")[["customer_id", "raw_churn_probability", "relative_risk_percentile",
                                         "risk_priority_rank", "customer_maturity_group", "score_version",
                                         "probability_usage"]]
w4_42_customer_base = (_rfmp.merge(_scored, on="customer_id", how="left")
                       .merge(w4_42_customer_top_category, on="customer_id", how="left"))

# 6. 결합 결과 사전 점검
b = w4_42_customer_base
BASE_ROWS, BASE_UNIQUE_CUSTOMERS = len(b), b["customer_id"].nunique()
if BASE_ROWS != EXPECTED_CUSTOMERS:
    abort(f"결합 결과 고객 수가 {EXPECTED_CUSTOMERS}명이 아닙니다. (현재 {BASE_ROWS})")
if BASE_ROWS != BASE_UNIQUE_CUSTOMERS:
    abort("결합 결과에 중복 customer_id가 있습니다.")
if b["raw_churn_probability"].isna().any() or b["risk_priority_rank"].isna().any():
    abort("4.1 상대위험 결과가 결합되지 않은 고객이 있습니다.")
if b["top_category"].isna().any():
    abort("개인 대표 카테고리가 없는 고객이 있습니다.")
if ((b["score_version"].astype(str).str.strip().str.upper() != EXPECTED_SCORE_VERSION.upper()).any()
        or (b["probability_usage"].astype(str).str.strip().str.upper() != "RELATIVE_RANK_ONLY").any()):
    abort("4.1 점수 버전 또는 확률 사용 원칙이 일치하지 않습니다.")

# 7. RFMP 가치순위·가치 백분위와 상대위험등급 (상위·중위·하위 1/3)
s = b.sort_values(["rfmp_score", "customer_id"], ascending=[False, True], kind="mergesort",
                  ignore_index=True)
total_customers = len(s)
s["value_priority_rank"] = np.arange(1, total_customers + 1)
s["rfmp_value_percentile"] = (1 - (s["value_priority_rank"] - 1) / (total_customers - 1)
                              if total_customers > 1 else 1.0)
s["relative_risk_grade"] = np.select(
    [s["relative_risk_percentile"] >= 2 / 3, s["relative_risk_percentile"] >= 1 / 3],
    ["High", "Medium"], default="Low")
# 공식 2: 가치와 상대위험이 모두 높을수록 1
s["value_risk_score"] = s["rfmp_value_percentile"] * s["relative_risk_percentile"]

# 8. 가치위험순위 (동점: 위험순위 -> 가치순위 -> 고객ID)
s = s.sort_values(["value_risk_score", "risk_priority_rank", "value_priority_rank", "customer_id"],
                  ascending=[False, True, True, True], kind="mergesort", ignore_index=True)
s["value_risk_priority_rank"] = np.arange(1, len(s) + 1)

# 9. 실행규칙 (규칙 1 신규고객 보호가 가장 먼저)
RULES = {
    1: ("NEW_LOW_COST_TEST", "신규고객 저비용 반응 확인", "EMAIL_OR_APP", "NONE_OR_LOW",
        "90일 미만 고객은 고비용 혜택 없이 대표 카테고리 반응을 확인"),
    2: ("HIGH_VALUE_RETENTION", "고가치 고객 우선 유지", "PERSONAL_CONTACT", "TEAM_REVIEW",
        "대표 카테고리를 활용한 개별 유지 제안을 우선 검토"),
    3: ("TARGETED_RETENTION", "중가치 고객 맞춤 유지", "EMAIL_OR_APP", "LOW",
        "대표 카테고리 중심의 제한적 맞춤 혜택을 검토"),
    4: ("LOW_COST_REACTIVATION", "저비용 재활성화", "AUTOMATED", "NONE_OR_LOW",
        "비용을 제한한 자동 알림과 대표 카테고리 노출"),
    5: ("LOYALTY_CROSSSELL", "충성도 유지와 교차판매", "EMAIL_OR_APP", "NONE_OR_LOW",
        "대표 카테고리를 기준으로 관련 상품을 제안"),
    6: ("CATEGORY_REMINDER", "대표 카테고리 재방문 유도", "AUTOMATED", "NONE",
        "개인 대표 카테고리를 활용한 저비용 리마인드"),
    7: ("MAINTAIN_MONITOR", "관계 유지 및 모니터링", "STANDARD_CRM", "NONE",
        "정상 마케팅을 유지하고 과도한 할인은 제공하지 않음"),
}
_new = s["customer_maturity_group"].astype(str).str.strip().str.upper() == "NEW_LT90"
_high, _med = s["relative_risk_grade"] == "High", s["relative_risk_grade"] == "Medium"
_top2 = s["rfmp_tier"].isin(["VIP", "Diamond"])
_mid2 = s["rfmp_tier"].isin(["Platinum", "Gold"])
s["action_rule_id"] = np.select([_new, _high & _top2, _high & _mid2, _high, _med & _top2, _med],
                                [1, 2, 3, 4, 5, 6], default=7)
for _i, _col in enumerate(["action_code", "action_name", "action_channel", "incentive_level",
                           "action_reason"]):
    s[_col] = s["action_rule_id"].map(lambda r, i=_i: RULES[r][i])
w4_42_customer_action = s
save(w4_42_customer_action, "w4_42_customer_action")

# 10. RFMP 가치등급 x 상대위험등급 요약
_risk_order = {"High": 1, "Medium": 2, "Low": 3}
w4_42_segment_summary = (s.groupby(["tier_code", "rfmp_tier", "relative_risk_grade"])
                         .agg(customer_count=("customer_id", "size"),
                              new_customer_count=("customer_maturity_group",
                                                  lambda x: int((x.astype(str).str.strip().str.upper()
                                                                 == "NEW_LT90").sum())),
                              avg_rfmp_score=("rfmp_score", "mean"),
                              avg_raw_probability=("raw_churn_probability", "mean"),
                              avg_risk_percentile=("relative_risk_percentile", "mean"),
                              avg_value_risk_score=("value_risk_score", "mean"),
                              best_value_risk_rank=("value_risk_priority_rank", "min"),
                              worst_value_risk_rank=("value_risk_priority_rank", "max"))
                         .reset_index())
w4_42_segment_summary = (w4_42_segment_summary
                         .assign(_o=w4_42_segment_summary["relative_risk_grade"].map(_risk_order))
                         .sort_values(["tier_code", "_o"]).drop(columns="_o").reset_index(drop=True))
save(w4_42_segment_summary, "w4_42_segment_summary")

# 11. 자동 품질 점검값
FINAL_ROWS, FINAL_UNIQUE_CUSTOMERS = len(s), s["customer_id"].nunique()
MISSING_RISK_GRADE = int(s["relative_risk_grade"].isna().sum())
FINAL_MISSING_TOP_CATEGORY = int(s["top_category"].isna().sum())
MISSING_ACTION = int(s["action_code"].isna().sum())
RISK_GRADE_COUNT = s["relative_risk_grade"].nunique()
ACTION_RULE_COUNT = s["action_code"].nunique()
RISK_RANK_MIN, RISK_RANK_MAX = int(s["risk_priority_rank"].min()), int(s["risk_priority_rank"].max())
VALUE_RISK_RANK_MIN, VALUE_RISK_RANK_MAX = (int(s["value_risk_priority_rank"].min()),
                                            int(s["value_risk_priority_rank"].max()))
INVALID_VALUE_RISK_SCORE = int(((s["value_risk_score"] < 0) | (s["value_risk_score"] > 1)).sum())
w4_42_risk_grade_count = s.groupby("relative_risk_grade").size().rename("customer_count").reset_index()
RISK_GRADE_SIZE_GAP = int(w4_42_risk_grade_count["customer_count"].max()
                          - w4_42_risk_grade_count["customer_count"].min())


def qa_row(order, item, actual, expected, ok, detail, bad="FAIL"):
    return {"check_order": order, "check_item": item, "actual_value": str(actual),
            "expected_value": str(expected), "status": "PASS" if ok else bad, "detail": detail}


w4_42_qa_summary = pd.DataFrame([
    qa_row(1, "3.5~3.9 QA FAIL count", W3_FAIL_COUNT, 0, W3_FAIL_COUNT == 0,
           "RFMP 입력 품질검사에 FAIL이 없어야 함"),
    qa_row(2, "4.1 QA FAIL count", W4_41_FAIL_COUNT, 0, W4_41_FAIL_COUNT == 0,
           "상대위험 입력 품질검사에 FAIL이 없어야 함"),
    qa_row(3, "Final customer rows", FINAL_ROWS, EXPECTED_CUSTOMERS, FINAL_ROWS == EXPECTED_CUSTOMERS,
           "RFMP 전 고객이 보존되어야 함"),
    qa_row(4, "Unique customer IDs", FINAL_UNIQUE_CUSTOMERS, FINAL_ROWS,
           FINAL_UNIQUE_CUSTOMERS == FINAL_ROWS, "고객 한 명당 한 행이어야 함"),
    qa_row(5, "Missing relative risk grade", MISSING_RISK_GRADE, 0, MISSING_RISK_GRADE == 0,
           "모든 고객에게 상대위험등급이 있어야 함"),
    qa_row(6, "Relative risk grade count", RISK_GRADE_COUNT, 3, RISK_GRADE_COUNT == 3,
           "High, Medium, Low 세 등급이어야 함"),
    qa_row(7, "Risk grade size difference", RISK_GRADE_SIZE_GAP, "<=1", RISK_GRADE_SIZE_GAP <= 1,
           "세 상대위험등급의 고객 수 차이는 최대 1명"),
    qa_row(8, "Risk priority rank range", f"{RISK_RANK_MIN} to {RISK_RANK_MAX}", f"1 to {FINAL_ROWS}",
           RISK_RANK_MIN == 1 and RISK_RANK_MAX == FINAL_ROWS, "위험순위는 1부터 전체 고객 수까지여야 함"),
    qa_row(9, "Value risk priority rank range", f"{VALUE_RISK_RANK_MIN} to {VALUE_RISK_RANK_MAX}",
           f"1 to {FINAL_ROWS}", VALUE_RISK_RANK_MIN == 1 and VALUE_RISK_RANK_MAX == FINAL_ROWS,
           "가치위험순위는 1부터 전체 고객 수까지여야 함"),
    qa_row(10, "Invalid value risk score", INVALID_VALUE_RISK_SCORE, 0, INVALID_VALUE_RISK_SCORE == 0,
           "가치위험점수는 0과 1 사이여야 함"),
    qa_row(11, "Missing personal top category", FINAL_MISSING_TOP_CATEGORY, 0,
           FINAL_MISSING_TOP_CATEGORY == 0, "모든 고객에게 개인 대표 카테고리가 있어야 함"),
    qa_row(12, "Missing action rule", MISSING_ACTION, 0, MISSING_ACTION == 0,
           "모든 고객에게 실행규칙이 있어야 함"),
    qa_row(13, "Action rule count", ACTION_RULE_COUNT, f"<={MAX_ACTION_RULES}",
           ACTION_RULE_COUNT <= MAX_ACTION_RULES, "팀이 검증할 수 있도록 규칙 수를 제한"),
    qa_row(14, "Absolute probability usage", ABSOLUTE_STATUS, "NOT_APPROVED",
           ABSOLUTE_STATUS == "NOT_APPROVED", "원예측확률을 절대위험 기준으로 사용하지 않음"),
])
save(w4_42_qa_summary, "w4_42_qa_summary")

# 13. 주요 결과 출력
proc_print(w4_42_risk_grade_count, "WBS 4.2-1. 상대위험등급별 고객 수", png="r42_01_risk_grade_count")
proc_print(w4_42_segment_summary, "WBS 4.2-2. RFMP 고객가치 x 상대위험등급", dec=3,
           png="r42_02_segment_summary")
proc_print(s, "WBS 4.2-3. 가치위험순위 상위 30명", obs=30, dec=4,
           var=["value_risk_priority_rank", "customer_id", "rfmp_tier", "relative_risk_grade",
                "risk_priority_rank", "rfmp_value_percentile", "relative_risk_percentile",
                "value_risk_score", "customer_maturity_group", "top_category", "action_code"],
           png="r42_03_top30_value_risk")
proc_freq(s, "action_code", "WBS 4.2-4. 실행규칙별 고객 수", order="data", png="r42_04_freq_action")
proc_print(w4_42_qa_summary, "WBS 4.2-5. 자동 품질 점검", png="r42_05_qa_summary")

# 14. 최종 실행 게이트
W4_42_FAIL_COUNT = fail_count("w4_42_qa_summary")
print(f"NOTE: WBS 4.2 QA FAIL = {W4_42_FAIL_COUNT}")
if W4_42_FAIL_COUNT > 0:
    abort("WBS 4.2 QA에서 FAIL이 발견되었습니다.")
print("NOTE: WBS 4.2가 정상적으로 완료되었습니다.")


# ======================================================================
# WBS 4.3. 가치-위험 공통 정보 영향과 우선순위 안정성 검증
# ======================================================================

MIN_ALT_TOPK_OVERLAP = 0.70       # 대안 계산식의 상위대상 최소 중복률
MATERIAL_CORR_REDUCTION = 0.30    # 공통 변수 통제 후 상관 절댓값 감소 비율
VALUE_TOLERANCE, MONEY_TOLERANCE = 0.000001, 0.01

for _t, _step in [("w3_rfmp_base_py", "WBS 3.5~3.9"), ("w4_41_current_scored", "WBS 4.1"),
                  ("w4_41_qa_summary", "WBS 4.1"), ("w4_42_customer_action", "WBS 4.2"),
                  ("w4_42_qa_summary", "WBS 4.2")]:
    require_table(_t, _step)
require_vars("w3_rfmp_base_py", ["customer_id", "recency", "frequency_days", "monetary"])
require_vars("w4_41_current_scored", ["customer_id", "recency", "frequency_days", "monetary",
                                      "risk_priority_rank", "relative_risk_percentile"])
require_vars("w4_42_customer_action", ["customer_id", "rfmp_tier", "rfmp_value_percentile",
                                       "relative_risk_grade", "relative_risk_percentile",
                                       "risk_priority_rank", "value_priority_rank", "value_risk_score",
                                       "value_risk_priority_rank", "customer_maturity_group",
                                       "action_code"])
delete("w4_43_shared_info_check", "w4_43_stability_summary", "w4_43_decision", "w4_43_qa_summary")

W4_41_FAIL_COUNT, W4_42_FAIL_COUNT = fail_count("w4_41_qa_summary"), fail_count("w4_42_qa_summary")
if W4_41_FAIL_COUNT > 0:
    abort("WBS 4.1 QA에 FAIL이 있습니다.")
if W4_42_FAIL_COUNT > 0:
    abort("WBS 4.2 QA에 FAIL이 있습니다.")
print("NOTE: 4.1과 4.2 QA 실행 게이트를 통과했습니다.")

# 4. 공통 분석 테이블 (RFMP 변수와 이탈모형 변수를 나란히)
_act = load("w4_42_customer_action")[["customer_id", "rfmp_tier", "rfmp_value_percentile",
                                      "relative_risk_grade", "relative_risk_percentile",
                                      "risk_priority_rank", "value_priority_rank", "value_risk_score",
                                      "value_risk_priority_rank", "customer_maturity_group",
                                      "action_code"]]
_mdl = load("w4_41_current_scored")[["customer_id", "recency", "frequency_days", "monetary"]].rename(
    columns={"recency": "model_recency", "frequency_days": "model_frequency_days",
             "monetary": "model_monetary"})
_rb = load("w3_rfmp_base_py")[["customer_id", "recency", "frequency_days", "monetary"]].rename(
    columns={"recency": "rfmp_recency", "frequency_days": "rfmp_frequency_days",
             "monetary": "rfmp_monetary"})
w4_43_base = _act.merge(_mdl, on="customer_id", how="left").merge(_rb, on="customer_id", how="left")

# 5. 결합 상태와 공통 변수의 직접 일치 여부
bb = w4_43_base
BASE_ROWS, BASE_UNIQUE_CUSTOMERS = len(bb), bb["customer_id"].nunique()
MISSING_RECENCY_PAIR = int((bb["model_recency"].isna() | bb["rfmp_recency"].isna()).sum())
MISSING_FREQUENCY_PAIR = int((bb["model_frequency_days"].isna() | bb["rfmp_frequency_days"].isna()).sum())
MISSING_MONETARY_PAIR = int((bb["model_monetary"].isna() | bb["rfmp_monetary"].isna()).sum())
RECENCY_MISMATCH = int(((bb["model_recency"] - bb["rfmp_recency"]).abs() > VALUE_TOLERANCE).sum())
FREQUENCY_MISMATCH = int(((bb["model_frequency_days"] - bb["rfmp_frequency_days"]).abs()
                          > VALUE_TOLERANCE).sum())
MONETARY_MISMATCH = int(((bb["model_monetary"] - bb["rfmp_monetary"]).abs() > MONEY_TOLERANCE).sum())
TOTAL_PAIR_MISSING = MISSING_RECENCY_PAIR + MISSING_FREQUENCY_PAIR + MISSING_MONETARY_PAIR
TOTAL_FEATURE_MISMATCH = RECENCY_MISMATCH + FREQUENCY_MISMATCH + MONETARY_MISMATCH
if BASE_ROWS != EXPECTED_CUSTOMERS:
    abort(f"결합 결과가 {EXPECTED_CUSTOMERS}명이 아닙니다.")
if BASE_ROWS != BASE_UNIQUE_CUSTOMERS:
    abort("결합 결과에 중복 customer_id가 있습니다.")
if TOTAL_PAIR_MISSING > 0:
    abort("공통 변수 결합에 결측 고객이 있습니다.")


# 6. 가치와 상대위험의 원 Spearman 상관 (PROC CORR SPEARMAN)
def spearman(x, y):
    return float(pd.Series(x).rank().corr(pd.Series(y).rank()))


RAW_SPEARMAN = spearman(bb["rfmp_value_percentile"], bb["relative_risk_percentile"])


# 7. 공통 변수의 선형효과를 제거한 잔차 (PROC REG OUTPUT RESIDUAL=)
def ols_residual(y, X):
    A = np.column_stack([np.ones(len(X)), np.asarray(X, dtype=float)])
    coef, *_ = np.linalg.lstsq(A, np.asarray(y, dtype=float), rcond=None)
    return np.asarray(y, dtype=float) - A @ coef


bb["value_residual"] = ols_residual(bb["rfmp_value_percentile"],
                                    bb[["rfmp_recency", "rfmp_frequency_days", "rfmp_monetary"]])
bb["risk_residual"] = ols_residual(bb["relative_risk_percentile"],
                                   bb[["model_recency", "model_frequency_days", "model_monetary"]])
RESIDUAL_SPEARMAN = spearman(bb["value_residual"], bb["risk_residual"])

# 8. 상관 감소량과 공통 정보 영향 판정
absolute_correlation_reduction = abs(RAW_SPEARMAN) - abs(RESIDUAL_SPEARMAN)
CORR_REDUCTION_RATE = (absolute_correlation_reduction / abs(RAW_SPEARMAN)
                       if abs(RAW_SPEARMAN) > 0 else 0.0)
if TOTAL_FEATURE_MISMATCH == 0 and CORR_REDUCTION_RATE >= MATERIAL_CORR_REDUCTION:
    SHARED_INFO_STATUS = "MATERIAL_SHARED_INFORMATION"
elif TOTAL_FEATURE_MISMATCH == 0:
    SHARED_INFO_STATUS = "DIRECT_OVERLAP_CONFIRMED"
else:
    SHARED_INFO_STATUS = "SOURCE_VALUES_DIFFER"
print(f"NOTE: WBS 4.3 CORR_REDUCTION_RATE raw = {CORR_REDUCTION_RATE}")
print(f"NOTE: WBS 4.3 SHARED_INFO_STATUS = {SHARED_INFO_STATUS}")

# 9. 공통 정보 점검표
w4_43_shared_info_check = pd.DataFrame([
    {"check_order": 1, "metric_type": "DIRECT_MATCH", "metric_name": "recency mismatch count",
     "actual_value": RECENCY_MISMATCH, "expected_value": "0이면 양쪽 값이 동일",
     "status": "CONFIRMED" if RECENCY_MISMATCH == 0 else "REVIEW",
     "interpretation": "RFMP와 이탈모형의 recency 고객별 값 비교"},
    {"check_order": 2, "metric_type": "DIRECT_MATCH", "metric_name": "frequency_days mismatch count",
     "actual_value": FREQUENCY_MISMATCH, "expected_value": "0이면 양쪽 값이 동일",
     "status": "CONFIRMED" if FREQUENCY_MISMATCH == 0 else "REVIEW",
     "interpretation": "RFMP와 이탈모형의 구매일 수 고객별 값 비교"},
    {"check_order": 3, "metric_type": "DIRECT_MATCH", "metric_name": "monetary mismatch count",
     "actual_value": MONETARY_MISMATCH, "expected_value": "0이면 양쪽 값이 동일",
     "status": "CONFIRMED" if MONETARY_MISMATCH == 0 else "REVIEW",
     "interpretation": "RFMP와 이탈모형의 구매금액 고객별 값 비교"},
    {"check_order": 4, "metric_type": "CORRELATION", "metric_name": "Raw value-risk Spearman",
     "actual_value": RAW_SPEARMAN, "expected_value": "설명용", "status": "INFO",
     "interpretation": "공통 변수를 통제하기 전 가치와 위험의 순위상관"},
    {"check_order": 5, "metric_type": "CORRELATION", "metric_name": "Residual value-risk Spearman",
     "actual_value": RESIDUAL_SPEARMAN, "expected_value": "설명용", "status": "INFO",
     "interpretation": "세 공통 변수의 선형효과를 제거한 뒤의 잔차상관"},
    {"check_order": 6, "metric_type": "CORRELATION", "metric_name": "Relative correlation reduction",
     "actual_value": CORR_REDUCTION_RATE, "expected_value": f">= {MATERIAL_CORR_REDUCTION:.2%}이면 영향 큼",
     "status": "MATERIAL" if CORR_REDUCTION_RATE >= MATERIAL_CORR_REDUCTION else "LIMITED",
     "interpretation": "공통 변수 통제 전후 상관 절댓값의 상대 감소율"},
])
save(w4_43_shared_info_check, "w4_43_shared_info_check")

# 10. 검증용 대안점수 (0.5 가치 + 0.5 위험) 와 순위
cmp_ = bb.assign(alt_equal_score=0.5 * bb["rfmp_value_percentile"] + 0.5 * bb["relative_risk_percentile"])
cmp_ = cmp_.sort_values(["alt_equal_score", "risk_priority_rank", "value_priority_rank", "customer_id"],
                        ascending=[False, True, True, True], kind="mergesort", ignore_index=True)
cmp_["alt_equal_priority_rank"] = np.arange(1, len(cmp_) + 1)
cmp_["risk_to_value_rank_change"] = cmp_["value_risk_priority_rank"] - cmp_["risk_priority_rank"]
cmp_["current_to_alt_rank_change"] = cmp_["alt_equal_priority_rank"] - cmp_["value_risk_priority_rank"]
cmp_["abs_risk_to_value_change"] = cmp_["risk_to_value_rank_change"].abs()
cmp_["abs_current_to_alt_change"] = cmp_["current_to_alt_rank_change"].abs()
w4_43_compare = cmp_

# 11. 상위 50·100·200명 중복률
_topk = []
for k in (50, 100, 200):
    for comp, col in (("CURRENT_VS_RISK", "risk_priority_rank"),
                      ("CURRENT_VS_EQUAL", "alt_equal_priority_rank")):
        n = int(((cmp_["value_risk_priority_rank"] <= k) & (cmp_[col] <= k)).sum())
        _topk.append({"comparison": comp, "top_n": k, "overlap_count": n, "overlap_rate": n / k})
w4_43_topk_overlap = pd.DataFrame(_topk)

# 12. 전체 순위 상관(Pearson)과 평균 순위 차이
RANK_CORR_CURRENT_RISK = float(cmp_["value_risk_priority_rank"].corr(cmp_["risk_priority_rank"]))
RANK_CORR_CURRENT_ALT = float(cmp_["value_risk_priority_rank"].corr(cmp_["alt_equal_priority_rank"]))
MEAN_ABS_RISK_VALUE_SHIFT = float(cmp_["abs_risk_to_value_change"].mean())
MEAN_ABS_CURRENT_ALT_SHIFT = float(cmp_["abs_current_to_alt_change"].mean())
MIN_ALT_OVERLAP = float(w4_43_topk_overlap.loc[w4_43_topk_overlap["comparison"] == "CURRENT_VS_EQUAL",
                                               "overlap_rate"].min())
print(f"NOTE: WBS 4.3 MIN_ALT_OVERLAP raw = {MIN_ALT_OVERLAP}")

# 13. 안정성 요약
_stab = []
for _, r in w4_43_topk_overlap.iterrows():
    eq = r["comparison"] == "CURRENT_VS_EQUAL"
    _stab.append({"metric_group": "TOPK_OVERLAP", "metric_name": f"{r['comparison']} TOP {r['top_n']}",
                  "top_n": r["top_n"], "overlap_count": r["overlap_count"], "metric_value": r["overlap_rate"],
                  "metric_display": f"{r['overlap_rate']:.2%}",
                  "criterion": f">= {MIN_ALT_TOPK_OVERLAP:.2%}" if eq else "설명용",
                  "status": ("PASS" if r["overlap_rate"] >= MIN_ALT_TOPK_OVERLAP else "REVIEW") if eq else "INFO",
                  "interpretation": "공식 곱셈점수와 50:50 평균점수의 상위대상 안정성" if eq
                  else "순수 위험순위와 가치위험순위는 목적이 달라 차이가 정상"})
for grp, name, val, disp, crit, interp in [
        ("RANK_RELATION", "Current value-risk vs risk-only rank correlation", RANK_CORR_CURRENT_RISK,
         f"{RANK_CORR_CURRENT_RISK:.4f}", "설명용", "순수 위험과 가치위험 우선순위의 전체 순위상관"),
        ("RANK_STABILITY", "Current value-risk vs equal-score rank correlation", RANK_CORR_CURRENT_ALT,
         f"{RANK_CORR_CURRENT_ALT:.4f}", "1에 가까울수록 안정", "공식점수와 검증용 평균점수의 전체 순위상관"),
        ("RANK_SHIFT", "Mean absolute risk-to-value rank shift", MEAN_ABS_RISK_VALUE_SHIFT,
         f"{MEAN_ABS_RISK_VALUE_SHIFT:,.2f}", "설명용", "가치를 결합했을 때 고객 순위가 평균적으로 이동한 폭"),
        ("RANK_SHIFT", "Mean absolute current-to-equal rank shift", MEAN_ABS_CURRENT_ALT_SHIFT,
         f"{MEAN_ABS_CURRENT_ALT_SHIFT:,.2f}", "작을수록 안정", "점수 계산식을 바꿨을 때 평균 순위 이동 폭")]:
    _stab.append({"metric_group": grp, "metric_name": name, "top_n": np.nan, "overlap_count": np.nan,
                  "metric_value": val, "metric_display": disp, "criterion": crit, "status": "INFO",
                  "interpretation": interp})
w4_43_stability_summary = pd.DataFrame(_stab)
save(w4_43_stability_summary, "w4_43_stability_summary")

# 14. RFMP·성숙도·실행규칙별 구성 (설명용 WORK)
w4_43_risk_by_value = cmp_.groupby(["rfmp_tier", "relative_risk_grade"]).size().rename(
    "customer_count").reset_index()
w4_43_risk_by_maturity = cmp_.groupby(["customer_maturity_group", "relative_risk_grade"]).size().rename(
    "customer_count").reset_index()
w4_43_action_composition = cmp_.groupby(["action_code", "customer_maturity_group",
                                         "relative_risk_grade"]).size().rename("customer_count").reset_index()

# 15. 최종 판단
if MIN_ALT_OVERLAP >= MIN_ALT_TOPK_OVERLAP:
    ranking_status = "STABLE"
    if SHARED_INFO_STATUS == "MATERIAL_SHARED_INFORMATION":
        decision_code = "KEEP_WITH_OVERLAP_CAUTION"
        decision_text = ("4.2 우선순위는 유지하되 RFMP와 이탈점수가 공통 구매행동 정보를 상당 부분 "
                         "공유한다는 한계를 함께 보고")
    else:
        decision_code = "KEEP_4_2_RANKING"
        decision_text = "대안 계산식에서도 상위 운영대상이 대체로 유지되어 4.2 가치위험순위를 유지"
else:
    ranking_status = "REVIEW"
    decision_code = "REVIEW_VALUE_RISK_FORMULA"
    decision_text = "대안 계산식에서 상위 운영대상이 크게 달라져 4.4 이전에 가치위험점수 공식을 팀 검토"
w4_43_decision = pd.DataFrame([{
    "decision_code": decision_code, "ranking_status": ranking_status,
    "shared_information_status": SHARED_INFO_STATUS, "decision_text": decision_text,
    "limitation": "공통 변수 통제는 선형 잔차 방식이며 비선형 정보중복과 인과관계를 확정하지 않음. "
                  "70% 기준은 운영 검토용 기준임",
    "customer_count": BASE_ROWS, "raw_spearman": RAW_SPEARMAN, "residual_spearman": RESIDUAL_SPEARMAN,
    "correlation_reduction_rate": CORR_REDUCTION_RATE,
    "minimum_alternative_topk_overlap": MIN_ALT_OVERLAP}])
save(w4_43_decision, "w4_43_decision")

# 16~17. QA
_alt = cmp_["alt_equal_score"]
w4_43_qa_summary = pd.DataFrame([
    qa_row(1, "4.1 QA FAIL count", W4_41_FAIL_COUNT, 0, W4_41_FAIL_COUNT == 0, "4.1 입력 품질검사에 FAIL이 없어야 함"),
    qa_row(2, "4.2 QA FAIL count", W4_42_FAIL_COUNT, 0, W4_42_FAIL_COUNT == 0, "4.2 입력 품질검사에 FAIL이 없어야 함"),
    qa_row(3, "Analysis customer rows", len(cmp_), EXPECTED_CUSTOMERS, len(cmp_) == EXPECTED_CUSTOMERS,
           "전체 고객 수가 보존되어야 함"),
    qa_row(4, "Unique customer IDs", cmp_["customer_id"].nunique(), len(cmp_),
           cmp_["customer_id"].nunique() == len(cmp_), "고객당 한 행이어야 함"),
    qa_row(5, "Missing shared feature pairs", TOTAL_PAIR_MISSING, 0, TOTAL_PAIR_MISSING == 0,
           "RFMP와 이탈모형 공통 변수 결합에 결측이 없어야 함"),
    qa_row(6, "Shared feature value mismatch", TOTAL_FEATURE_MISMATCH, "0이면 직접 중복 확인",
           TOTAL_FEATURE_MISMATCH == 0, "0이면 세 공통 변수가 고객별로 같은 값을 사용", bad="REVIEW"),
    qa_row(7, "Missing alternative score", int(_alt.isna().sum()), 0, _alt.isna().sum() == 0,
           "검증용 평균점수에 결측이 없어야 함"),
    qa_row(8, "Alternative score outside 0 to 1", int(((_alt < 0) | (_alt > 1)).sum()), 0,
           ((_alt < 0) | (_alt > 1)).sum() == 0, "검증용 평균점수 범위 확인"),
    qa_row(9, "Alternative rank range",
           f"{cmp_['alt_equal_priority_rank'].min()} to {cmp_['alt_equal_priority_rank'].max()}",
           f"1 to {len(cmp_)}", cmp_["alt_equal_priority_rank"].min() == 1
           and cmp_["alt_equal_priority_rank"].max() == len(cmp_), "대안순위는 1부터 전체 고객 수까지여야 함"),
    qa_row(10, "Alternative top-k minimum overlap", f"{MIN_ALT_OVERLAP:.2%}", f">= {MIN_ALT_TOPK_OVERLAP:.2%}",
           MIN_ALT_OVERLAP >= MIN_ALT_TOPK_OVERLAP, "공식점수와 검증용 평균점수의 상위대상 안정성", bad="REVIEW"),
    qa_row(11, "Action rule count unchanged", cmp_["action_code"].nunique(), "<=8",
           cmp_["action_code"].nunique() <= 8, "4.2 실행규칙을 변경하지 않았는지 확인"),
    qa_row(12, "Stability summary rows", len(w4_43_stability_summary), 10, len(w4_43_stability_summary) == 10,
           "상위대상 6행과 순위지표 4행"),
    qa_row(13, "Decision row count", len(w4_43_decision), 1, len(w4_43_decision) == 1,
           "최종 판단은 한 행이어야 함"),
])
save(w4_43_qa_summary, "w4_43_qa_summary")

# 18. 핵심 결과 출력
proc_print(w4_43_shared_info_check, "WBS 4.3-1. RFMP와 이탈모형의 공통 정보 확인", dec=4,
           png="r43_01_shared_info")
proc_print(w4_43_stability_summary, "WBS 4.3-2. 상위대상과 순위 안정성", dec=4, png="r43_02_stability")
proc_print(w4_43_risk_by_value, "WBS 4.3-3. RFMP 등급별 상대위험 분포", png="r43_03_risk_by_value")
proc_print(w4_43_risk_by_maturity, "WBS 4.3-4. 신규·기존 고객별 상대위험 분포", png="r43_04_risk_by_maturity")
proc_print(w4_43_action_composition, "WBS 4.3-5. 실행규칙별 고객 구성")
proc_print(w4_43_decision.T.reset_index().set_axis(["항목", "값"], axis=1),
           "WBS 4.3-6. 현재 우선순위 유지 여부", png="r43_05_decision")
proc_print(w4_43_qa_summary, "WBS 4.3-7. 자동 품질 점검", png="r43_06_qa_summary")

# 19. 최종 실행 게이트 (REVIEW 는 중단하지 않음)
W4_43_FAIL_COUNT = fail_count("w4_43_qa_summary")
print(f"NOTE: WBS 4.3 QA FAIL = {W4_43_FAIL_COUNT}")
if W4_43_FAIL_COUNT > 0:
    abort("WBS 4.3 QA에서 FAIL이 발견되었습니다.")
print("NOTE: WBS 4.3이 정상적으로 완료되었습니다. 최종 판단은 CRM.W4_43_DECISION에서 확인하십시오.")


# ======================================================================
# WBS 4.4. 핵심 인사이트 확정 및 이중 운영대상 설계
# ======================================================================

CAPACITY_SMALL, CAPACITY_MEDIUM, CAPACITY_LARGE = 50, 100, 200
MAX_ALLOWED_RECENCY_GAP = 1

for _t, _step in [("w3_rfmp_base_py", "WBS 3.5~3.9"), ("w4_41_current_scored", "WBS 4.1"),
                  ("w4_42_customer_action", "WBS 4.2"), ("w4_42_qa_summary", "WBS 4.2"),
                  ("w4_43_decision", "WBS 4.3"), ("w4_43_qa_summary", "WBS 4.3"),
                  ("w4_43_stability_summary", "WBS 4.3")]:
    require_table(_t, _step)
require_vars("w4_42_customer_action", ["top_category", "action_code", "action_name", "action_channel",
                                       "incentive_level", "action_reason"])
require_vars("w4_43_decision", ["decision_code", "ranking_status", "decision_text", "limitation"])
delete("w4_44_final_roster", "w4_44_pilot_summary", "w4_44_insight_summary", "w4_44_decision",
       "w4_44_qa_summary", "w4_44_output_catalog")

# 3. 이전 단계 실행 게이트
W4_42_FAIL_COUNT, W4_43_FAIL_COUNT = fail_count("w4_42_qa_summary"), fail_count("w4_43_qa_summary")
_d43 = load("w4_43_decision")
W4_43_DECISION_ROWS = len(_d43)
W4_43_DECISION_CODE = str(_d43["decision_code"].iloc[0]).strip().upper()
W4_43_RANKING_STATUS = str(_d43["ranking_status"].iloc[0]).strip().upper()
if W4_42_FAIL_COUNT > 0:
    abort("WBS 4.2 QA에 FAIL이 있습니다.")
if W4_43_FAIL_COUNT > 0:
    abort("WBS 4.3 QA에 FAIL이 있습니다.")
if W4_43_DECISION_ROWS != 1:
    abort("WBS 4.3 최종 판단이 한 행이 아닙니다.")
print("NOTE: 4.2와 4.3 실행 게이트를 통과했습니다.")

# 4. recency 기준 차이 확인 (전 고객 동일한 0 또는 1일이면 정의 차이)
w4_44_recency_check = (load("w3_rfmp_base_py")[["customer_id", "recency"]]
                       .rename(columns={"recency": "rfmp_recency"})
                       .merge(load("w4_41_current_scored")[["customer_id", "recency"]]
                              .rename(columns={"recency": "model_recency"}), on="customer_id"))
w4_44_recency_check["recency_gap"] = w4_44_recency_check["model_recency"] - w4_44_recency_check["rfmp_recency"]
_g = w4_44_recency_check["recency_gap"]
RECENCY_ROWS, RECENCY_CUSTOMERS = len(w4_44_recency_check), w4_44_recency_check["customer_id"].nunique()
RECENCY_GAP_MIN, RECENCY_GAP_MAX, RECENCY_GAP_MEAN = _g.min(), _g.max(), _g.mean()
RECENCY_GAP_DISTINCT, RECENCY_GAP_MAX_ABS = _g.nunique(), _g.abs().max()
RECENCY_REVIEW_FLAG = int(RECENCY_ROWS != EXPECTED_CUSTOMERS or RECENCY_CUSTOMERS != EXPECTED_CUSTOMERS
                          or RECENCY_GAP_DISTINCT != 1 or RECENCY_GAP_MAX_ABS > MAX_ALLOWED_RECENCY_GAP)


def _fmt_num(v):
    return f"{int(v)}" if float(v).is_integer() else f"{v}"


# 5. 최종 고객 운영 명단 (두 순위를 하나로 합치지 않음)
ro = load("w4_42_customer_action").copy()
for k in (CAPACITY_SMALL, CAPACITY_MEDIUM, CAPACITY_LARGE):
    ro[f"flag_value_top{k}"] = (ro["value_risk_priority_rank"] <= k).astype(int)
    ro[f"flag_risk_top{k}"] = (ro["risk_priority_rank"] <= k).astype(int)
ro["value_queue_band"] = np.select([ro["flag_value_top50"] == 1, ro["flag_value_top100"] == 1,
                                    ro["flag_value_top200"] == 1],
                                   ["VALUE_TOP50", "VALUE_TOP100", "VALUE_TOP200"], default="OUTSIDE_TOP200")
ro["risk_queue_band"] = np.select([ro["flag_risk_top50"] == 1, ro["flag_risk_top100"] == 1,
                                   ro["flag_risk_top200"] == 1],
                                  ["RISK_TOP50", "RISK_TOP100", "RISK_TOP200"], default="OUTSIDE_TOP200")
ro["queue_membership"] = np.select(
    [(ro["flag_value_top200"] == 1) & (ro["flag_risk_top200"] == 1), ro["flag_value_top200"] == 1,
     ro["flag_risk_top200"] == 1], ["BOTH_TOP200", "VALUE_TOP200_ONLY", "RISK_TOP200_ONLY"],
    default="OUTSIDE_BOTH")
ro["roster_usage"] = "상대위험 기반 시험 운영 명단이며 절대 이탈확률 또는 ROI 확정자료가 아님"
w4_44_final_roster = ro
save(w4_44_final_roster, "w4_44_final_roster")

# 6. 두 대기열의 수용규모별 구성
_ps = []
for qt, prefix in (("VALUE_PROTECTION", "flag_value_top"), ("RISK_PREVENTION", "flag_risk_top")):
    for k in (CAPACITY_SMALL, CAPACITY_MEDIUM, CAPACITY_LARGE):
        g = ro[ro[f"{prefix}{k}"] == 1]
        _ps.append({"queue_type": qt, "capacity": k, "selected_customers": len(g),
                    "new_customers": int((g["customer_maturity_group"].astype(str).str.strip().str.upper()
                                          == "NEW_LT90").sum()),
                    "high_risk_customers": int((g["relative_risk_grade"].str.upper() == "HIGH").sum()),
                    "avg_value_percentile": g["rfmp_value_percentile"].mean(),
                    "avg_risk_percentile": g["relative_risk_percentile"].mean()})
w4_44_pilot_summary = pd.DataFrame(_ps).sort_values(["queue_type", "capacity"], ignore_index=True)
save(w4_44_pilot_summary, "w4_44_pilot_summary")

# 7. 핵심 수치
_new44 = ro["customer_maturity_group"].astype(str).str.strip().str.upper() == "NEW_LT90"
NEW_CUSTOMER_COUNT = int(_new44.sum())
NEW_HIGH_COST_COUNT = int((_new44 & (ro["incentive_level"].str.strip().str.upper() == "TEAM_REVIEW")).sum())
TOP100_BOTH_COUNT = int(((ro["flag_value_top100"] == 1) & (ro["flag_risk_top100"] == 1)).sum())
TOP100_BOTH_RATE = TOP100_BOTH_COUNT / CAPACITY_MEDIUM
_d43r = _d43.iloc[0]
RAW_SPEARMAN, RESIDUAL_SPEARMAN = float(_d43r["raw_spearman"]), float(_d43r["residual_spearman"])
CORR_REDUCTION_RATE = float(_d43r["correlation_reduction_rate"])
MIN_ALT_OVERLAP = float(_d43r["minimum_alternative_topk_overlap"])

# 8. 핵심 인사이트 (사실·해석·권고·한계 분리)
w4_44_insight_summary = pd.DataFrame([
    {"insight_id": "I01",
     "fact": f"4.3 decision={W4_43_DECISION_CODE}, ranking_status={W4_43_RANKING_STATUS}, "
             f"대안식 최소 TOP-K 중복률={MIN_ALT_OVERLAP:.2%}",
     "business_interpretation": "공식 가치위험순위의 상위 운영대상은 검증용 50:50 점수에서도 대체로 유지됨"
     if W4_43_RANKING_STATUS == "STABLE" else "검증용 50:50 점수에서 상위 운영대상이 크게 달라짐",
     "recommended_action": "4.2 가치위험순위를 가치보호 대기열의 공식 순위로 유지"
     if W4_43_RANKING_STATUS == "STABLE" else "가치위험점수 공식을 팀이 재검토한 뒤 대기열 확정",
     "limitation": "STABLE은 상위 대상의 안정성이며 전체 순위 불변 또는 위험순위와의 동일성을 뜻하지 않음"},
    {"insight_id": "I02",
     "fact": f"상위 100명에서 두 대기열 공통 고객={TOP100_BOTH_COUNT}명, 중복률={TOP100_BOTH_RATE:.2%}",
     "business_interpretation": "순수 위험관리와 가치보호는 서로 다른 고객을 상당 부분 선택할 수 있음"
     if TOP100_BOTH_RATE < 0.5 else "두 대기열이 상당 부분 같은 고객을 선택함",
     "recommended_action": "두 순위를 하나로 합치지 말고 가치보호와 저비용 위험관리 대기열로 분리 운영"
     if TOP100_BOTH_RATE < 0.5 else "두 대기열을 통합 운영해도 되는지 팀 검토",
     "limitation": "중복률은 대상 구성의 차이를 보여주며 어느 순위가 인과적으로 더 효과적인지는 증명하지 않음"},
    {"insight_id": "I03",
     "fact": f"원 상관={RAW_SPEARMAN:.4f}, 공통 변수 통제 후 상관={RESIDUAL_SPEARMAN:.4f}, "
             f"절댓값 감소율={CORR_REDUCTION_RATE:.2%}",
     "business_interpretation": "RFMP와 상대위험은 공통 구매행동 정보를 공유하지만 선형 통제 후에도 관계가 남음"
     if abs(RESIDUAL_SPEARMAN) >= 0.1 else "공통 구매행동 정보를 통제하면 두 점수의 관계가 거의 사라짐",
     "recommended_action": "두 점수의 목적을 분리해 사용하고 성과 검증 전 중복 정보를 독립 효과로 해석하지 않음",
     "limitation": "잔차 검증은 선형효과만 통제하며 비선형 중복과 인과관계를 확정하지 않음"},
    {"insight_id": "I04",
     "fact": f"90일 미만 신규 고객={NEW_CUSTOMER_COUNT}명, 신규 고객 중 TEAM_REVIEW 고비용 후보="
             f"{NEW_HIGH_COST_COUNT}명",
     "business_interpretation": "구매이력이 짧은 신규 고객은 기존 고객과 같은 강도의 조치보다 반응 확인이 우선임",
     "recommended_action": "NEW_LOW_COST_TEST 규칙을 유지하고 이메일·앱 기반 저비용 시험만 시행",
     "limitation": "90일 기준은 운영 정의이며 신규 고객의 장기 이탈 가능성을 충분히 관찰한 결과가 아님"},
    {"insight_id": "I05",
     "fact": f"RFMP-model recency 차이 min={_fmt_num(RECENCY_GAP_MIN)}, max={_fmt_num(RECENCY_GAP_MAX)}, "
             f"서로 다른 차이값 수={RECENCY_GAP_DISTINCT}",
     "business_interpretation": "전 고객의 차이가 동일한 0일 또는 1일 범위여서 기준일 정의 차이로 관리 가능"
     if RECENCY_REVIEW_FLAG == 0 else "고객마다 recency 차이가 달라 단순 기준일 정의 차이로 보기 어려움",
     "recommended_action": "정의 차이를 문서화하고 현재 순위를 유지" if RECENCY_REVIEW_FLAG == 0
     else "4.1로 돌아가 recency 기준일과 계산식을 재검토",
     "limitation": "이 점검은 두 산출물의 일관성을 확인하며 어느 recency 정의가 유일하게 옳다는 증거는 아님"},
])
save(w4_44_insight_summary, "w4_44_insight_summary")

# 9. 자동 품질 점검
_rr, _vr = ro["risk_priority_rank"], ro["value_risk_priority_rank"]
_cnt = {f"{q}{k}": int(ro[f"flag_{q}_top{k}"].sum()) for q in ("value", "risk") for k in (50, 100, 200)}
ACTION_RULE_COUNT = ro["action_code"].nunique()
w4_44_qa_summary = pd.DataFrame([
    qa_row(1, "4.2 QA FAIL", W4_42_FAIL_COUNT, 0, W4_42_FAIL_COUNT == 0, "4.2 입력 산출물의 품질 게이트"),
    qa_row(2, "4.3 QA FAIL", W4_43_FAIL_COUNT, 0, W4_43_FAIL_COUNT == 0, "4.3 검증 산출물의 품질 게이트"),
    qa_row(3, "4.3 ranking decision", f"{W4_43_DECISION_CODE} / {W4_43_RANKING_STATUS}", "KEEP 계열 / STABLE",
           "KEEP" in W4_43_DECISION_CODE and W4_43_RANKING_STATUS == "STABLE",
           "공식 순위를 운영 명단에 사용할 수 있는지 확인", bad="REVIEW"),
    qa_row(4, "Roster rows and unique customers", f"{len(ro)} / {ro['customer_id'].nunique()}",
           f"{EXPECTED_CUSTOMERS} / {EXPECTED_CUSTOMERS}",
           len(ro) == EXPECTED_CUSTOMERS and ro["customer_id"].nunique() == EXPECTED_CUSTOMERS, "고객당 한 행 유지"),
    qa_row(5, "Risk rank complete and unique",
           f"missing={int(_rr.isna().sum())}, distinct={_rr.nunique()}, range={int(_rr.min())}-{int(_rr.max())}",
           f"missing=0, distinct={EXPECTED_CUSTOMERS}, range=1-{EXPECTED_CUSTOMERS}",
           _rr.isna().sum() == 0 and _rr.nunique() == EXPECTED_CUSTOMERS and _rr.min() == 1
           and _rr.max() == EXPECTED_CUSTOMERS, "순수 위험 우선순위의 완전성"),
    qa_row(6, "Value-risk rank complete and unique",
           f"missing={int(_vr.isna().sum())}, distinct={_vr.nunique()}, range={int(_vr.min())}-{int(_vr.max())}",
           f"missing=0, distinct={EXPECTED_CUSTOMERS}, range=1-{EXPECTED_CUSTOMERS}",
           _vr.isna().sum() == 0 and _vr.nunique() == EXPECTED_CUSTOMERS and _vr.min() == 1
           and _vr.max() == EXPECTED_CUSTOMERS, "가치위험 우선순위의 완전성"),
    qa_row(7, "Value queue capacity counts", f"{_cnt['value50']} / {_cnt['value100']} / {_cnt['value200']}",
           "50 / 100 / 200", (_cnt["value50"], _cnt["value100"], _cnt["value200"]) == (50, 100, 200),
           "가치보호 대기열 수용규모"),
    qa_row(8, "Risk queue capacity counts", f"{_cnt['risk50']} / {_cnt['risk100']} / {_cnt['risk200']}",
           "50 / 100 / 200", (_cnt["risk50"], _cnt["risk100"], _cnt["risk200"]) == (50, 100, 200),
           "저비용 위험관리 대기열 수용규모"),
    qa_row(9, "Action rule count", ACTION_RULE_COUNT, "<=8", ACTION_RULE_COUNT <= 8,
           "두 사람이 검증 가능한 실행규칙 수 제한"),
    qa_row(10, "New customer high-cost assignment", NEW_HIGH_COST_COUNT, 0, NEW_HIGH_COST_COUNT == 0,
           "90일 미만 고객에게 TEAM_REVIEW 수준 혜택을 부여하지 않음"),
    qa_row(11, "Recency definition consistency",
           f"min={_fmt_num(RECENCY_GAP_MIN)}, max={_fmt_num(RECENCY_GAP_MAX)}, distinct={RECENCY_GAP_DISTINCT}",
           "전 고객 동일, 절댓값 0 또는 1", RECENCY_REVIEW_FLAG == 0,
           "REVIEW이면 4.1의 기준일과 recency 계산식을 재검토", bad="REVIEW"),
    qa_row(12, "Insight rows", len(w4_44_insight_summary), 5, len(w4_44_insight_summary) == 5,
           "사실·해석·권고·한계를 분리한 핵심 인사이트"),
])
save(w4_44_qa_summary, "w4_44_qa_summary")

# 10. 4절 종료 또는 재검토 판단
W4_44_FAIL_COUNT = fail_count("w4_44_qa_summary")
W4_44_REVIEW_COUNT = int((w4_44_qa_summary["status"] == "REVIEW").sum())
if W4_44_FAIL_COUNT > 0:
    _dc, _dt = "STOP_TECHNICAL_FIX", "필수 행수·순위·대기열 또는 실행규칙 품질검사에 실패하여 4절을 종료할 수 없음"
    _ns = "W4_44_QA_SUMMARY의 FAIL 항목을 수정한 뒤 4.4를 다시 실행"
elif RECENCY_REVIEW_FLAG == 1:
    _dc, _dt = "RETURN_TO_4_1", "RFMP와 이탈모형의 recency 차이가 고객마다 달라 기준일 차이만으로 설명할 수 없음"
    _ns = "4.1의 기준일과 recency 계산식을 확인한 뒤 4.1부터 4.4까지 순서대로 재실행"
elif "KEEP" not in W4_43_DECISION_CODE or W4_43_RANKING_STATUS != "STABLE":
    _dc, _dt = "RETURN_TO_4_2_4_3", "4.3에서 현재 가치위험 우선순위의 운영 안정성이 확인되지 않음"
    _ns = "4.2 점수 공식과 4.3 안정성 기준을 팀 검토한 뒤 4.4를 다시 실행"
else:
    _dc = "CLOSE_WBS4_PILOT_READY"
    _dt = "기술적 QA와 순위 안정성 기준을 통과하여 두 대기열 기반의 제한적 운영 시험 준비가 완료됨"
    _ns = "가치보호와 저비용 위험관리 대기열을 분리해 소규모 시험하고 실제 반응·비용을 기록"
w4_44_decision = pd.DataFrame([{
    "decision_code": _dc, "decision_text": _dt, "next_step": _ns,
    "evidence_required": "종료 후에도 절대확률 보정, 고객 단위 독립 검증, 캠페인 대조군, 실제 반응률·비용·"
                         "증분가치가 있어야 운영 효과와 ROI를 확정할 수 있음",
    "qa_fail_count": W4_44_FAIL_COUNT, "qa_review_count": W4_44_REVIEW_COUNT,
    "recency_review_flag": RECENCY_REVIEW_FLAG, "w4_43_decision_code": W4_43_DECISION_CODE,
    "w4_43_ranking_status": W4_43_RANKING_STATUS}])
save(w4_44_decision, "w4_44_decision")

# 11. 산출물 목록
save(output_catalog("w4_44_"), "w4_44_output_catalog")

# 12. 팀 검토용 결과 출력
proc_print(ro[ro["value_risk_priority_rank"] <= 20], "WBS 4.4-1. 가치보호 대기열 상위 20명",
           var=["customer_id", "value_risk_priority_rank", "risk_priority_rank", "rfmp_tier",
                "relative_risk_grade", "customer_maturity_group", "top_category", "action_code"],
           png="r44_01_value_queue_top20")
proc_print(ro.sort_values("risk_priority_rank"), "WBS 4.4-2. 저비용 위험관리 대기열 상위 20명", obs=20,
           var=["customer_id", "risk_priority_rank", "value_risk_priority_rank", "rfmp_tier",
                "relative_risk_grade", "customer_maturity_group", "top_category", "action_code"],
           png="r44_02_risk_queue_top20")
proc_print(w4_44_pilot_summary, "WBS 4.4-3. 대기열과 수용규모별 고객 구성", dec=4, png="r44_03_pilot_summary")
proc_print(w4_44_insight_summary, "WBS 4.4-4. 핵심 인사이트", png="r44_04_insight_summary")
proc_print(w4_44_qa_summary, "WBS 4.4-5. 자동 품질 점검", png="r44_05_qa_summary")
proc_print(w4_44_decision.T.reset_index().set_axis(["항목", "값"], axis=1),
           "WBS 4.4-6. 종료 또는 재검토 판단", png="r44_06_decision")
proc_print(load("w4_44_output_catalog"), "WBS 4.4-7. 영구 산출물 목록")

# 13. 최종 실행 게이트
print(f"NOTE: WBS 4.4 QA FAIL = {W4_44_FAIL_COUNT}")
print(f"NOTE: WBS 4.4 QA REVIEW = {W4_44_REVIEW_COUNT}")
if W4_44_FAIL_COUNT > 0:
    abort("WBS 4.4 QA에서 FAIL이 발견되었습니다. CRM.W4_44_QA_SUMMARY를 확인하십시오.")
print(f"NOTE: WBS 4.4가 기술적으로 정상 완료되었습니다. 판단 = {_dc}")
