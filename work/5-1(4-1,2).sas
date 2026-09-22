/*====================================================================
  WBS 4.1. 이탈모형 비교·확률 선택 및 현재 고객 점수 산출
  파일명: WBS_4_1_v3_Revised.sas

  [이 절의 목표]
    1. TRAIN으로 Gradient Boosting 모형을 학습합니다.
    2. VALID에서 보정 전·후 확률과 단순 기준모형을 비교합니다.
    3. 팀이 검토한 확률 한 종류를 최종 확률로 선택합니다.
    4. 같은 모형으로 CURRENT 고객의 이탈확률을 산출합니다.

  [확인된 사실]
    - 이탈 여부 변수는 0/1이어야 합니다.
    - 기존 검토에서 RAW_UNWEIGHTED가 보정확률보다 Brier Score와
      Log Loss가 근소하게 좋았습니다.
    - 절대 위험등급 기준은 아직 확정되지 않았습니다.

  [이번 코드의 결정]
    - 현재 선택 확률은 RAW_UNWEIGHTED입니다.
    - 4.1에서는 Low/Medium/High 등급을 만들지 않습니다.
    - 전체 고객 상대 3분위 등급은 4.2에서 생성합니다.
    - 로그변환과 확률·등급 안정성은 4.3에서 재검증합니다.
    - class_weight는 사용하지 않습니다.

  [입력 테이블]
    CRM.W3_CHURN_SPLIT_V2 : TRAIN / VALID 시간분리 데이터
    CRM.CLEAN_ONLINE      : CURRENT 고객 피처 계산용 거래 데이터
    CRM.CLEAN_CUSTOMER    : 고객 성별·지역·가입기간

  [산출 테이블]
    CRM.W4_MODEL_COMPARISON     : VALID 모형 성능 비교
    CRM.W4_41_MODEL_DECISION    : 최종 확률 선택 결과
    CRM.W4_CHURN_VALID_SCORED   : VALID 고객별 예측확률
    CRM.W4_CHURN_CALIBRATION    : 확률구간별 예측값과 실제값
    CRM.W4_CHURN_CURRENT_SCORED : 4.2에서 사용할 CURRENT 최종 확률
    CRM.W4_41_QA_SUMMARY        : 핵심 품질 점검
====================================================================*/

options validvarname=any validmemname=extend;

%let CRM_PATH=/home/student/crm_db;
libname crm "&CRM_PATH.";

/* 현재 팀 검토 결과에 따른 선택값입니다: RAW 또는 CALIBRATED */
%let SELECTED_PROBABILITY=RAW;


/*====================================================================
  0. 입력 테이블과 설정 확인
====================================================================*/

%macro require_table(ds=, previous_step=);

    %if %sysfunc(exist(&ds.))=0 %then %do;

        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %put ERROR: &previous_step. 단계를 먼저 실행하십시오.;

        %abort cancel;

    %end;

    %else
        %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;

%mend;


%require_table(
    ds=crm.w3_churn_split_v2,
    previous_step=WBS 3.2
);

%require_table(
    ds=crm.clean_online,
    previous_step=Week 1-5 정제
);

%require_table(
    ds=crm.clean_customer,
    previous_step=Week 1-5 정제
);


%macro check_probability_choice;

    %if %upcase(&SELECTED_PROBABILITY.) ne RAW and
        %upcase(&SELECTED_PROBABILITY.) ne CALIBRATED
    %then %do;

        %put ERROR: SELECTED_PROBABILITY는 RAW 또는 CALIBRATED여야 합니다.;

        %abort cancel;

    %end;

%mend;

%check_probability_choice;


/* 실패한 이전 결과와 v2의 미확정 절대등급 표를 제거합니다. */

proc datasets library=crm nolist nowarn;

    delete
        w4_model_comparison
        w4_41_model_decision
        w4_churn_valid_scored
        w4_churn_calibration
        w4_churn_current_scored
        w4_41_qa_summary
        w4_threshold_candidates
        w4_churn_thresholds
        w4_churn_risk_validation;

quit;


/*====================================================================
  1. 모형 학습·확률 비교·CURRENT 스코어링

  RESTART는 이전 PROC PYTHON의 변수와 모델을 제거합니다.
====================================================================*/

proc python restart;
submit;


# --------------------------------------------------------------------
# 1-0. Python 환경 설정
# --------------------------------------------------------------------

# 수치계산 라이브러리의 과도한 메모리 사용을 막습니다.
import os

os.environ["OMP_NUM_THREADS"] = "1"
os.environ["OPENBLAS_NUM_THREADS"] = "1"
os.environ["MKL_NUM_THREADS"] = "1"
os.environ["NUMEXPR_NUM_THREADS"] = "1"


import gc
import numpy as np
import pandas as pd

from sklearn.calibration import CalibratedClassifierCV
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.impute import SimpleImputer
from sklearn.metrics import (
    average_precision_score,
    brier_score_loss,
    log_loss,
    roc_auc_score
)
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler


# --------------------------------------------------------------------
# 1-1. 공통 함수
# --------------------------------------------------------------------

def normalize_columns(frame):

    result = frame.copy()

    result.columns = [
        str(column).strip().lower()
        for column in result.columns
    ]

    return result


def require_columns(frame, columns, table_name):

    missing = [
        column
        for column in columns
        if column not in frame.columns
    ]

    if missing:

        raise ValueError(
            f"{table_name}에 필요한 변수가 없습니다: "
            + ", ".join(missing)
        )


def clean_id(series):

    return (
        series
        .where(series.notna(), "")
        .astype(str)
        .str.strip()
    )


def save_sas(frame, table_name):

    output = frame.reset_index(drop=True).copy()

    for column in output.select_dtypes(
        include=["category"]
    ).columns:

        output[column] = output[column].astype(str)

    SAS.df2sd(
        output,
        dataset=f"crm.{table_name}"
    )


def make_onehot():

    try:

        return OneHotEncoder(
            handle_unknown="ignore",
            sparse_output=False
        )

    except TypeError:

        return OneHotEncoder(
            handle_unknown="ignore",
            sparse=False
        )


def sas_date_to_datetime(series):

    if pd.api.types.is_datetime64_any_dtype(series):

        return pd.to_datetime(series)

    numeric = pd.to_numeric(
        series,
        errors="coerce"
    )

    if numeric.notna().mean() >= 0.90:

        return pd.to_datetime(
            numeric,
            unit="D",
            origin="1960-01-01",
            errors="coerce"
        )

    return pd.to_datetime(
        series,
        errors="coerce"
    )


def performance_row(
    model_name,
    probability_type,
    actual,
    probability
):

    actual_rate = float(
        np.mean(actual)
    )

    mean_probability = float(
        np.mean(probability)
    )

    return {
        "model_name":
            model_name,

        "probability_type":
            probability_type,

        "dataset_role":
            "VALID",

        "customer_count":
            int(len(actual)),

        "actual_churn_rate":
            actual_rate,

        "mean_predicted_probability":
            mean_probability,

        "absolute_mean_gap":
            abs(mean_probability - actual_rate),

        "roc_auc":
            float(
                roc_auc_score(
                    actual,
                    probability
                )
            ),

        "pr_auc":
            float(
                average_precision_score(
                    actual,
                    probability
                )
            ),

        "brier_score":
            float(
                brier_score_loss(
                    actual,
                    probability
                )
            ),

        "log_loss":
            float(
                log_loss(
                    actual,
                    probability,
                    labels=[0, 1]
                )
            )
    }


def make_calibration_table(
    actual,
    probability,
    probability_type,
    bins=5
):

    temp = pd.DataFrame({
        "actual":
            np.asarray(actual, dtype=int),

        "probability":
            np.asarray(probability, dtype=float)
    })

    # 예측확률 순위를 기준으로 고객 수가 비슷한
    # 5개 확률구간을 만듭니다.

    temp["bin_number"] = (
        pd.qcut(
            temp["probability"].rank(
                method="first"
            ),
            q=min(bins, len(temp)),
            labels=False
        )
        + 1
    )

    result = (
        temp
        .groupby(
            "bin_number",
            as_index=False
        )
        .agg(
            customer_count=(
                "actual",
                "size"
            ),

            actual_churn_count=(
                "actual",
                "sum"
            ),

            mean_predicted_probability=(
                "probability",
                "mean"
            ),

            observed_churn_rate=(
                "actual",
                "mean"
            ),

            min_predicted_probability=(
                "probability",
                "min"
            ),

            max_predicted_probability=(
                "probability",
                "max"
            )
        )
    )

    result["calibration_gap"] = (
        result["observed_churn_rate"]
        - result["mean_predicted_probability"]
    )

    result["probability_type"] = probability_type

    return result[[
        "probability_type",
        "bin_number",
        "customer_count",
        "actual_churn_count",
        "min_predicted_probability",
        "max_predicted_probability",
        "mean_predicted_probability",
        "observed_churn_rate",
        "calibration_gap"
    ]]


print(
    "=" * 72,
    flush=True
)

print(
    "WBS 4.1 v3_Revised. "
    "이탈모형 비교·확률 선택 및 현재 고객 점수 산출",
    flush=True
)

print(
    "=" * 72,
    flush=True
)


selected_setting = str(
    SAS.symget(
        "SELECTED_PROBABILITY"
    )
).strip().upper()


# --------------------------------------------------------------------
# 1-2. TRAIN / VALID 데이터 준비 및 이탈변수 확인
# --------------------------------------------------------------------

split_data = normalize_columns(
    SAS.sd2df(
        "crm.w3_churn_split_v2"
    )
)


numeric_features = [
    "recency",
    "frequency",
    "monetary",
    "avg_order_value",
    "avg_shipping",
    "coupon_usage_rate",
    "coupon_click_rate",
    "tenure",
    "product_category_count",
    "category_concentration",
    "avg_days_between_orders",
    "std_days_between_orders",
    "last_coupon_used",
    "clv_proxy"
]


categorical_features = [
    "gender",
    "region"
]


feature_columns = (
    numeric_features
    + categorical_features
)


required_split = [
    "snapshot_key",
    "customer_id",
    "split_role",
    "churn_flag"
] + feature_columns


require_columns(
    split_data,
    required_split,
    "CRM.W3_CHURN_SPLIT_V2"
)


split_data["customer_id"] = clean_id(
    split_data["customer_id"]
)

split_data["snapshot_key"] = clean_id(
    split_data["snapshot_key"]
)

split_data["split_role"] = (
    split_data["split_role"]
    .astype(str)
    .str.strip()
    .str.upper()
)


if split_data["customer_id"].eq("").any():

    raise ValueError(
        "분할 데이터에 빈 customer_id가 있습니다."
    )


if split_data["snapshot_key"].eq("").any():

    raise ValueError(
        "분할 데이터에 빈 snapshot_key가 있습니다."
    )


for column in numeric_features + ["churn_flag"]:

    split_data[column] = pd.to_numeric(
        split_data[column],
        errors="coerce"
    )


split_data[numeric_features] = (
    split_data[numeric_features]
    .replace(
        [np.inf, -np.inf],
        np.nan
    )
)


if split_data["churn_flag"].isna().any():

    raise ValueError(
        "churn_flag에 결측값 또는 숫자가 아닌 값이 있습니다."
    )


label_values = set(
    split_data["churn_flag"]
    .unique()
    .tolist()
)


if not label_values.issubset({0, 1}):

    raise ValueError(
        "churn_flag는 0과 1만 포함해야 합니다."
    )


for column in categorical_features:

    split_data[column] = (
        split_data[column]
        .fillna("UNKNOWN")
        .astype(str)
        .str.strip()
        .replace("", "UNKNOWN")
    )


train = split_data.loc[
    split_data["split_role"] == "TRAIN"
].copy()


valid = split_data.loc[
    split_data["split_role"] == "VALID"
].copy()


if len(train) == 0 or len(valid) == 0:

    raise ValueError(
        "TRAIN 또는 VALID 데이터가 비어 있습니다."
    )


if train["churn_flag"].nunique() < 2:

    raise ValueError(
        "TRAIN의 이탈 라벨이 한 종류뿐입니다."
    )


if valid["churn_flag"].nunique() < 2:

    raise ValueError(
        "VALID의 이탈 라벨이 한 종류뿐입니다."
    )


if train["snapshot_key"].duplicated().any():

    raise ValueError(
        "TRAIN에 중복 snapshot_key가 있습니다."
    )


if valid["snapshot_key"].duplicated().any():

    raise ValueError(
        "VALID에 중복 snapshot_key가 있습니다."
    )


train_valid_customer_overlap = len(
    set(
        train["customer_id"]
    ).intersection(
        set(valid["customer_id"])
    )
)


X_train = train[
    feature_columns
]

y_train = (
    train["churn_flag"]
    .astype(int)
)

X_valid = valid[
    feature_columns
]

y_valid = (
    valid["churn_flag"]
    .astype(int)
)


print(
    f"[1/7] 데이터 준비 완료: "
    f"TRAIN={len(train):,}, "
    f"VALID={len(valid):,}",
    flush=True
)

print(
    f"      TRAIN/VALID 중복 고객="
    f"{train_valid_customer_overlap:,}",
    flush=True
)


# --------------------------------------------------------------------
# 1-3. 전처리
#
# 결측 대체, 표준화, 범주형 인코딩은
# TRAIN에서만 학습합니다.
# --------------------------------------------------------------------

numeric_pipe = Pipeline([
    (
        "imputer",
        SimpleImputer(
            strategy="median"
        )
    ),
    (
        "scaler",
        StandardScaler()
    )
])


categorical_pipe = Pipeline([
    (
        "imputer",
        SimpleImputer(
            strategy="most_frequent"
        )
    ),
    (
        "onehot",
        make_onehot()
    )
])


preprocessor = ColumnTransformer([
    (
        "numeric",
        numeric_pipe,
        numeric_features
    ),
    (
        "categorical",
        categorical_pipe,
        categorical_features
    )
])


X_train_ready = (
    preprocessor
    .fit_transform(X_train)
)

X_valid_ready = (
    preprocessor
    .transform(X_valid)
)


print(
    f"[2/7] 전처리 완료: "
    f"변환 변수 수={X_train_ready.shape[1]:,}",
    flush=True
)


# --------------------------------------------------------------------
# 1-4. Gradient Boosting 학습
#
# 확률 자체를 해석하므로 클래스 가중치는 적용하지 않습니다.
# --------------------------------------------------------------------

def make_classifier():

    return GradientBoostingClassifier(
        n_estimators=40,
        learning_rate=0.03,
        max_depth=3,
        subsample=0.70,
        random_state=2026
    )


raw_model = make_classifier()

raw_model.fit(
    X_train_ready,
    y_train
)


valid_raw_probability = (
    raw_model
    .predict_proba(
        X_valid_ready
    )[:, 1]
)


print(
    "[3/7] Gradient Boosting 학습 완료",
    flush=True
)


# --------------------------------------------------------------------
# 1-5. TRAIN 내부 3-fold sigmoid 확률 보정
#
# VALID는 보정 학습에 사용하지 않습니다.
# --------------------------------------------------------------------

try:

    calibrated_model = CalibratedClassifierCV(
        estimator=make_classifier(),
        method="sigmoid",
        cv=3,
        ensemble=False,
        n_jobs=1
    )

except TypeError:

    calibrated_model = CalibratedClassifierCV(
        base_estimator=make_classifier(),
        method="sigmoid",
        cv=3,
        ensemble=False,
        n_jobs=1
    )


calibrated_model.fit(
    X_train_ready,
    y_train
)


valid_cal_probability = (
    calibrated_model
    .predict_proba(
        X_valid_ready
    )[:, 1]
)


print(
    "[4/7] 3-fold sigmoid 확률 보정 완료",
    flush=True
)


# --------------------------------------------------------------------
# 1-6. VALID 성능 비교 및 최종 확률 선택
#
# Brier Score와 Log Loss는 낮을수록 좋습니다.
# ROC-AUC와 PR-AUC는 높을수록 좋습니다.
# --------------------------------------------------------------------

train_churn_rate = float(
    y_train.mean()
)


valid_null_probability = np.full(
    len(y_valid),
    train_churn_rate
)


model_comparison = pd.DataFrame([

    performance_row(
        "ConstantBaseline",
        "TRAIN_RATE_NULL",
        y_valid,
        valid_null_probability
    ),

    performance_row(
        "GradientBoosting",
        "RAW_UNWEIGHTED",
        y_valid,
        valid_raw_probability
    ),

    performance_row(
        "GradientBoosting",
        "CALIBRATED_UNWEIGHTED",
        y_valid,
        valid_cal_probability
    )

])


null_brier = float(
    model_comparison.loc[
        model_comparison[
            "probability_type"
        ] == "TRAIN_RATE_NULL",
        "brier_score"
    ].iloc[0]
)


null_log_loss = float(
    model_comparison.loc[
        model_comparison[
            "probability_type"
        ] == "TRAIN_RATE_NULL",
        "log_loss"
    ].iloc[0]
)


model_comparison[
    "brier_improvement_vs_null"
] = (
    null_brier
    - model_comparison["brier_score"]
)


model_comparison[
    "logloss_improvement_vs_null"
] = (
    null_log_loss
    - model_comparison["log_loss"]
)


if selected_setting == "RAW":

    selected_probability_type = (
        "RAW_UNWEIGHTED"
    )

    valid_final_probability = (
        valid_raw_probability
    )

else:

    selected_probability_type = (
        "CALIBRATED_UNWEIGHTED"
    )

    valid_final_probability = (
        valid_cal_probability
    )


candidate_metrics = model_comparison.loc[
    model_comparison[
        "probability_type"
    ].isin([
        "RAW_UNWEIGHTED",
        "CALIBRATED_UNWEIGHTED"
    ])
].copy()


best_brier_type = candidate_metrics.loc[
    candidate_metrics[
        "brier_score"
    ].idxmin(),
    "probability_type"
]


best_logloss_type = candidate_metrics.loc[
    candidate_metrics[
        "log_loss"
    ].idxmin(),
    "probability_type"
]


selected_metrics = model_comparison.loc[
    model_comparison[
        "probability_type"
    ] == selected_probability_type
].iloc[0]


decision_status = (
    "PASS"
    if selected_probability_type == best_brier_type
    and selected_probability_type == best_logloss_type
    else "REVIEW"
)


model_decision = pd.DataFrame([{

    "score_version":
        "W4_1_V3_REVISED",

    "selected_probability_type":
        selected_probability_type,

    "selection_setting":
        selected_setting,

    "primary_metric":
        "Brier Score and Log Loss",

    "best_brier_probability_type":
        best_brier_type,

    "best_logloss_probability_type":
        best_logloss_type,

    "valid_roc_auc":
        float(
            selected_metrics["roc_auc"]
        ),

    "valid_pr_auc":
        float(
            selected_metrics["pr_auc"]
        ),

    "valid_brier_score":
        float(
            selected_metrics["brier_score"]
        ),

    "valid_log_loss":
        float(
            selected_metrics["log_loss"]
        ),

    "valid_actual_churn_rate":
        float(
            selected_metrics[
                "actual_churn_rate"
            ]
        ),

    "valid_mean_probability":
        float(
            selected_metrics[
                "mean_predicted_probability"
            ]
        ),

    "valid_absolute_mean_gap":
        float(
            selected_metrics[
                "absolute_mean_gap"
            ]
        ),

    "decision_status":
        decision_status,

    "decision_note":
        (
            "RAW selected from prior team review; "
            "4.3 rechecks transformation and stability"
        )

}])


valid_scored = valid[[
    "snapshot_key",
    "customer_id",
    "split_role",
    "churn_flag"
]].copy()


valid_scored = valid_scored.rename(
    columns={
        "churn_flag":
            "actual_churn_flag"
    }
)


valid_scored["model_name"] = (
    "GradientBoosting"
)

valid_scored["score_version"] = (
    "W4_1_V3_REVISED"
)

valid_scored[
    "churn_probability_raw"
] = valid_raw_probability

valid_scored[
    "churn_probability_calibrated"
] = valid_cal_probability

valid_scored[
    "final_churn_probability"
] = valid_final_probability

valid_scored[
    "selected_probability_type"
] = selected_probability_type


calibration_table = pd.concat([

    make_calibration_table(
        y_valid,
        valid_raw_probability,
        "RAW_UNWEIGHTED"
    ),

    make_calibration_table(
        y_valid,
        valid_cal_probability,
        "CALIBRATED_UNWEIGHTED"
    )

], ignore_index=True)


calibration_table["is_selected"] = (
    calibration_table[
        "probability_type"
    ]
    .eq(
        selected_probability_type
    )
    .astype(int)
)


# CURRENT 계산이 실패하더라도
# VALID 검증 결과는 먼저 보존합니다.

save_sas(
    model_comparison,
    "w4_model_comparison"
)

save_sas(
    model_decision,
    "w4_41_model_decision"
)

save_sas(
    valid_scored,
    "w4_churn_valid_scored"
)

save_sas(
    calibration_table,
    "w4_churn_calibration"
)


print(
    f"[5/7] VALID 비교 완료: "
    f"최종 선택={selected_probability_type}",
    flush=True
)


del split_data
del X_train
del X_valid

gc.collect()


# --------------------------------------------------------------------
# 1-7. 전체 거래기간 기준 CURRENT 고객 피처 생성
# --------------------------------------------------------------------

online = normalize_columns(
    SAS.sd2df(
        "crm.clean_online"
    )
)


customer = normalize_columns(
    SAS.sd2df(
        "crm.clean_customer"
    )
)


required_online = [
    "customer_id",
    "order_key",
    "transaction_date",
    "product_category",
    "quantity",
    "avg_price",
    "shipping_fee",
    "coupon_status",
    "flag_missing_core",
    "flag_return",
    "flag_zero_quantity",
    "flag_invalid_price",
    "flag_customer_unmatched"
]


require_columns(
    online,
    required_online,
    "CRM.CLEAN_ONLINE"
)


require_columns(
    customer,
    [
        "customer_id",
        "gender",
        "region",
        "tenure"
    ],
    "CRM.CLEAN_CUSTOMER"
)


# 필요한 열만 남겨 Python 메모리 사용을 줄입니다.

online = online[
    required_online
].copy()


customer = customer[[
    "customer_id",
    "gender",
    "region",
    "tenure"
]].copy()


online["customer_id"] = clean_id(
    online["customer_id"]
)

customer["customer_id"] = clean_id(
    customer["customer_id"]
)


if customer["customer_id"].eq("").any():

    raise ValueError(
        "CRM.CLEAN_CUSTOMER에 빈 customer_id가 있습니다."
    )


if customer["customer_id"].duplicated().any():

    raise ValueError(
        "CRM.CLEAN_CUSTOMER에 중복 customer_id가 있습니다."
    )


online["order_key"] = (
    online["order_key"]
    .where(
        online["order_key"].notna(),
        ""
    )
    .astype(str)
    .str.strip()
)


online["product_category"] = (
    online["product_category"]
    .fillna("UNKNOWN")
    .astype(str)
    .str.strip()
    .replace("", "UNKNOWN")
)


for column in [
    "quantity",
    "avg_price",
    "shipping_fee",
    "flag_missing_core",
    "flag_return",
    "flag_zero_quantity",
    "flag_invalid_price",
    "flag_customer_unmatched"
]:

    online[column] = pd.to_numeric(
        online[column],
        errors="coerce"
    )


online["transaction_date"] = (
    sas_date_to_datetime(
        online["transaction_date"]
    )
)


online["coupon_status_std"] = (
    online["coupon_status"]
    .fillna("")
    .astype(str)
    .str.strip()
    .str.upper()
)


valid_mask = (

    online[
        "flag_missing_core"
    ].eq(0)

    & online[
        "flag_return"
    ].eq(0)

    & online[
        "flag_zero_quantity"
    ].eq(0)

    & online[
        "flag_invalid_price"
    ].eq(0)

    & online[
        "flag_customer_unmatched"
    ].eq(0)

    & online[
        "transaction_date"
    ].notna()

    & online[
        "customer_id"
    ].ne("")

    & online[
        "order_key"
    ].ne("")
)


online_valid = online.loc[
    valid_mask
].copy()


del online

gc.collect()


if len(online_valid) == 0:

    raise ValueError(
        "CURRENT 피처를 만들 유효 거래가 없습니다."
    )


online_valid["line_amount"] = (
    online_valid["quantity"]
    * online_valid["avg_price"]
)


online_valid["order_coupon_used"] = (
    online_valid[
        "coupon_status_std"
    ]
    .eq("USED")
    .astype(int)
)


online_valid["order_coupon_clicked"] = (
    online_valid[
        "coupon_status_std"
    ]
    .isin([
        "USED",
        "CLICKED"
    ])
    .astype(int)
)


current_cutoff = (
    online_valid[
        "transaction_date"
    ].max()
)


# 상품 행을 주문 단위로 합칩니다.

orders = (
    online_valid
    .groupby(
        [
            "customer_id",
            "order_key",
            "transaction_date"
        ],
        as_index=False
    )
    .agg(
        order_amount=(
            "line_amount",
            "sum"
        ),

        order_shipping=(
            "shipping_fee",
            "max"
        ),

        order_coupon_used=(
            "order_coupon_used",
            "max"
        ),

        order_coupon_clicked=(
            "order_coupon_clicked",
            "max"
        )
    )
)


# 고객별 기본 구매지표입니다.

core = (
    orders
    .groupby(
        "customer_id",
        as_index=False
    )
    .agg(
        first_purchase_date=(
            "transaction_date",
            "min"
        ),

        last_purchase_date=(
            "transaction_date",
            "max"
        ),

        frequency=(
            "order_key",
            "nunique"
        ),

        monetary=(
            "order_amount",
            "sum"
        ),

        avg_order_value=(
            "order_amount",
            "mean"
        ),

        avg_shipping=(
            "order_shipping",
            "mean"
        ),

        coupon_usage_rate=(
            "order_coupon_used",
            "mean"
        ),

        coupon_click_rate=(
            "order_coupon_clicked",
            "mean"
        )
    )
)


core["recency"] = (
    current_cutoff
    - core["last_purchase_date"]
).dt.days


core["observation_days"] = (
    core["last_purchase_date"]
    - core["first_purchase_date"]
).dt.days + 1


# 고객별 카테고리 수와 주 카테고리 집중도입니다.

cat_count = (
    online_valid
    .groupby(
        [
            "customer_id",
            "product_category"
        ],
        as_index=False
    )
    .agg(
        category_order_count=(
            "order_key",
            "nunique"
        )
    )
)


cat_feature = (
    cat_count
    .groupby(
        "customer_id",
        as_index=False
    )
    .agg(
        product_category_count=(
            "product_category",
            "nunique"
        ),

        max_category_orders=(
            "category_order_count",
            "max"
        ),

        total_category_orders=(
            "category_order_count",
            "sum"
        )
    )
)


cat_feature["category_concentration"] = (
    cat_feature["max_category_orders"]
    / cat_feature[
        "total_category_orders"
    ].replace(0, np.nan)
)


cat_feature = cat_feature[[
    "customer_id",
    "product_category_count",
    "category_concentration"
]]


# 고객별 구매일 사이의 간격입니다.

purchase_dates = (
    online_valid[[
        "customer_id",
        "transaction_date"
    ]]
    .drop_duplicates()
    .sort_values([
        "customer_id",
        "transaction_date"
    ])
)


purchase_dates["gap_days"] = (
    purchase_dates
    .groupby(
        "customer_id"
    )["transaction_date"]
    .diff()
    .dt.days
)


gap_feature = (
    purchase_dates.loc[
        purchase_dates[
            "gap_days"
        ] > 0
    ]
    .groupby(
        "customer_id",
        as_index=False
    )
    .agg(
        avg_days_between_orders=(
            "gap_days",
            "mean"
        ),

        std_days_between_orders=(
            "gap_days",
            "std"
        )
    )
)


# 마지막 구매일에 쿠폰을 사용했는지 확인합니다.

last_date = (
    orders
    .groupby(
        "customer_id"
    )["transaction_date"]
    .transform("max")
)


last_coupon = (
    orders.loc[
        orders[
            "transaction_date"
        ] == last_date
    ]
    .groupby(
        "customer_id",
        as_index=False
    )
    .agg(
        last_coupon_used=(
            "order_coupon_used",
            "max"
        )
    )
)


current_features = (
    core
    .merge(
        cat_feature,
        on="customer_id",
        how="left",
        validate="one_to_one"
    )
    .merge(
        gap_feature,
        on="customer_id",
        how="left",
        validate="one_to_one"
    )
    .merge(
        last_coupon,
        on="customer_id",
        how="left",
        validate="one_to_one"
    )
    .merge(
        customer[[
            "customer_id",
            "gender",
            "region",
            "tenure"
        ]],
        on="customer_id",
        how="left",
        validate="one_to_one"
    )
)


for column in [
    "product_category_count",
    "category_concentration",
    "avg_days_between_orders",
    "std_days_between_orders",
    "last_coupon_used",
    "tenure"
]:

    current_features[column] = (
        pd.to_numeric(
            current_features[column],
            errors="coerce"
        )
        .fillna(0)
    )


current_features["annual_order_frequency"] = (
    current_features["frequency"]
    / (
        current_features[
            "observation_days"
        ].clip(lower=30)
        / 365.25
    )
)


current_features["clv_proxy"] = (
    current_features[
        "avg_order_value"
    ]
    * current_features[
        "annual_order_frequency"
    ]
    * (
        current_features[
            "tenure"
        ].clip(lower=1)
        / 12
    )
)


for column in categorical_features:

    current_features[column] = (
        current_features[column]
        .fillna("UNKNOWN")
        .astype(str)
        .str.strip()
        .replace("", "UNKNOWN")
    )


if current_features[
    "customer_id"
].duplicated().any():

    raise ValueError(
        "CURRENT 피처에 중복 customer_id가 있습니다."
    )


current_features["split_role"] = (
    "CURRENT"
)

current_features["snapshot_cutoff"] = (
    current_cutoff
)

current_features["snapshot_key"] = (
    current_features["customer_id"]
    + "|CURRENT"
)


del online_valid
del orders
del cat_count
del purchase_dates
del customer

gc.collect()


print(
    f"[6/7] CURRENT 피처 생성 완료: "
    f"고객={len(current_features):,}",
    flush=True
)


# --------------------------------------------------------------------
# 1-8. CURRENT 고객 스코어 및 QA 생성
# --------------------------------------------------------------------

X_current_ready = (
    preprocessor
    .transform(
        current_features[
            feature_columns
        ]
    )
)


current_raw_probability = (
    raw_model
    .predict_proba(
        X_current_ready
    )[:, 1]
)


current_cal_probability = (
    calibrated_model
    .predict_proba(
        X_current_ready
    )[:, 1]
)


if selected_setting == "RAW":

    current_final_probability = (
        current_raw_probability
    )

else:

    current_final_probability = (
        current_cal_probability
    )


current_scored = current_features[[
    "snapshot_key",
    "customer_id",
    "split_role",
    "snapshot_cutoff",
    "recency",
    "frequency",
    "monetary"
]].copy()


current_scored["model_name"] = (
    "GradientBoosting"
)

current_scored["score_version"] = (
    "W4_1_V3_REVISED"
)

current_scored[
    "churn_probability_raw"
] = current_raw_probability

current_scored[
    "churn_probability_calibrated"
] = current_cal_probability

current_scored[
    "final_churn_probability"
] = current_final_probability

current_scored[
    "selected_probability_type"
] = selected_probability_type


selected_brier = float(
    selected_metrics["brier_score"]
)

selected_logloss = float(
    selected_metrics["log_loss"]
)

selected_mean_gap = float(
    selected_metrics[
        "absolute_mean_gap"
    ]
)


valid_probability_missing = int(
    valid_scored[
        "final_churn_probability"
    ].isna().sum()
)


current_probability_missing = int(
    current_scored[
        "final_churn_probability"
    ].isna().sum()
)


valid_probability_in_range = int(
    valid_scored[
        "final_churn_probability"
    ]
    .between(0, 1)
    .all()
)


current_probability_in_range = int(
    current_scored[
        "final_churn_probability"
    ]
    .between(0, 1)
    .all()
)


def qa_row(
    check_item,
    actual_value,
    expected_value,
    status
):

    return {
        "check_item":
            check_item,

        "actual_value":
            actual_value,

        "expected_value":
            expected_value,

        "status":
            status
    }


qa_rows = []


qa_rows.append(
    qa_row(
        "TRAIN rows greater than zero",
        int(len(train) > 0),
        1,
        "PASS" if len(train) > 0 else "FAIL"
    )
)


qa_rows.append(
    qa_row(
        "VALID rows greater than zero",
        int(len(valid) > 0),
        1,
        "PASS" if len(valid) > 0 else "FAIL"
    )
)


qa_rows.append(
    qa_row(
        "TRAIN churn labels are 0 and 1",
        int(
            set(
                y_train.unique()
            ) == {0, 1}
        ),
        1,
        (
            "PASS"
            if set(
                y_train.unique()
            ) == {0, 1}
            else "FAIL"
        )
    )
)


qa_rows.append(
    qa_row(
        "VALID churn labels are 0 and 1",
        int(
            set(
                y_valid.unique()
            ) == {0, 1}
        ),
        1,
        (
            "PASS"
            if set(
                y_valid.unique()
            ) == {0, 1}
            else "FAIL"
        )
    )
)


qa_rows.append(
    qa_row(
        "TRAIN VALID customer overlap",
        train_valid_customer_overlap,
        0,
        "INFO"
    )
)


valid_duplicate_count = int(
    valid_scored[
        "snapshot_key"
    ].duplicated().sum()
)


qa_rows.append(
    qa_row(
        "VALID duplicate snapshot",
        valid_duplicate_count,
        0,
        (
            "PASS"
            if valid_duplicate_count == 0
            else "FAIL"
        )
    )
)


current_duplicate_count = int(
    current_scored[
        "customer_id"
    ].duplicated().sum()
)


qa_rows.append(
    qa_row(
        "CURRENT duplicate customer",
        current_duplicate_count,
        0,
        (
            "PASS"
            if current_duplicate_count == 0
            else "FAIL"
        )
    )
)


qa_rows.append(
    qa_row(
        "VALID missing final probability",
        valid_probability_missing,
        0,
        (
            "PASS"
            if valid_probability_missing == 0
            else "FAIL"
        )
    )
)


qa_rows.append(
    qa_row(
        "CURRENT missing final probability",
        current_probability_missing,
        0,
        (
            "PASS"
            if current_probability_missing == 0
            else "FAIL"
        )
    )
)


qa_rows.append(
    qa_row(
        "VALID final probability in 0 to 1",
        valid_probability_in_range,
        1,
        (
            "PASS"
            if valid_probability_in_range == 1
            else "FAIL"
        )
    )
)


qa_rows.append(
    qa_row(
        "CURRENT final probability in 0 to 1",
        current_probability_in_range,
        1,
        (
            "PASS"
            if current_probability_in_range == 1
            else "FAIL"
        )
    )
)


qa_rows.append(
    qa_row(
        "Selected Brier better than null",
        selected_brier,
        null_brier,
        (
            "PASS"
            if selected_brier < null_brier
            else "REVIEW"
        )
    )
)


qa_rows.append(
    qa_row(
        "Selected LogLoss better than null",
        selected_logloss,
        null_log_loss,
        (
            "PASS"
            if selected_logloss < null_log_loss
            else "REVIEW"
        )
    )
)


qa_rows.append(
    qa_row(
        "Selected probability has best Brier",
        int(
            selected_probability_type
            == best_brier_type
        ),
        1,
        (
            "PASS"
            if selected_probability_type
            == best_brier_type
            else "REVIEW"
        )
    )
)


qa_rows.append(
    qa_row(
        "Selected probability has best LogLoss",
        int(
            selected_probability_type
            == best_logloss_type
        ),
        1,
        (
            "PASS"
            if selected_probability_type
            == best_logloss_type
            else "REVIEW"
        )
    )
)


qa_rows.append(
    qa_row(
        "Mean probability gap within 3pct",
        selected_mean_gap,
        0.03,
        (
            "PASS"
            if selected_mean_gap <= 0.03
            else "REVIEW"
        )
    )
)


risk_column_created = int(
    any(
        "risk_grade" in column
        for column in current_scored.columns
    )
)


qa_rows.append(
    qa_row(
        "Risk grade columns created in 4.1",
        risk_column_created,
        0,
        (
            "PASS"
            if risk_column_created == 0
            else "FAIL"
        )
    )
)


qa_summary = pd.DataFrame(
    qa_rows
)


save_sas(
    current_scored,
    "w4_churn_current_scored"
)

save_sas(
    qa_summary,
    "w4_41_qa_summary"
)


print(
    f"[7/7] CURRENT 점수 저장 완료: "
    f"고객={len(current_scored):,}",
    flush=True
)


print(
    "\n[VALID 모형 성능 비교]",
    flush=True
)

print(
    model_comparison
    .round(4)
    .to_string(index=False),
    flush=True
)


print(
    "\n[최종 확률 선택]",
    flush=True
)

print(
    model_decision
    .round(4)
    .to_string(index=False),
    flush=True
)


print(
    "\n[QA 결과]",
    flush=True
)

print(
    qa_summary
    .round(4)
    .to_string(index=False),
    flush=True
)


print(
    "\nWBS 4.1 v3_Revised Python 작업이 완료되었습니다.",
    flush=True
)


endsubmit;
quit;


/*====================================================================
  2. 핵심 산출물 생성 여부 확인
====================================================================*/

%macro check_w4_outputs;

    %global W4_OUTPUT_OK;

    %let W4_OUTPUT_OK=1;


    %if %sysfunc(
        exist(crm.w4_model_comparison)
    )=0
    %then %let W4_OUTPUT_OK=0;


    %if %sysfunc(
        exist(crm.w4_41_model_decision)
    )=0
    %then %let W4_OUTPUT_OK=0;


    %if %sysfunc(
        exist(crm.w4_churn_valid_scored)
    )=0
    %then %let W4_OUTPUT_OK=0;


    %if %sysfunc(
        exist(crm.w4_churn_calibration)
    )=0
    %then %let W4_OUTPUT_OK=0;


    %if %sysfunc(
        exist(crm.w4_churn_current_scored)
    )=0
    %then %let W4_OUTPUT_OK=0;


    %if %sysfunc(
        exist(crm.w4_41_qa_summary)
    )=0
    %then %let W4_OUTPUT_OK=0;


    %if &W4_OUTPUT_OK.=0 %then %do;

        %put ERROR: WBS 4.1 v3_Revised 핵심 산출물이 모두 생성되지 않았습니다.;
        %put ERROR: 마지막으로 출력된 Python 단계 번호를 확인하십시오.;

        %abort cancel;

    %end;


    %put NOTE: WBS 4.1 v3_Revised 핵심 산출물 6개를 확인했습니다.;

%mend;

%check_w4_outputs;


/*====================================================================
  3. 결과 확인
====================================================================*/

title "WBS 4.1 v3_Revised VALID 모형 성능 비교";

proc print
    data=crm.w4_model_comparison
    noobs;

    format
        actual_churn_rate
        mean_predicted_probability
        absolute_mean_gap
        roc_auc
        pr_auc
        brier_score
        log_loss
        brier_improvement_vs_null
        logloss_improvement_vs_null
        8.4;

run;


title "WBS 4.1 v3_Revised 최종 확률 선택 결과";

proc print
    data=crm.w4_41_model_decision
    noobs;

    format
        valid_roc_auc
        valid_pr_auc
        valid_brier_score
        valid_log_loss
        valid_actual_churn_rate
        valid_mean_probability
        valid_absolute_mean_gap
        8.4;

run;


title "WBS 4.1 v3_Revised 확률구간별 예측확률과 실제 이탈률";

proc print
    data=crm.w4_churn_calibration
    noobs;

    format
        min_predicted_probability
        max_predicted_probability
        mean_predicted_probability
        observed_churn_rate
        calibration_gap
        percent8.2;

run;


title "WBS 4.1 v3_Revised VALID 고객 점수 앞 10행";

proc print
    data=crm.w4_churn_valid_scored(obs=10)
    noobs;

    format
        churn_probability_raw
        churn_probability_calibrated
        final_churn_probability
        percent8.2;

run;


title "WBS 4.1 v3_Revised CURRENT 고객 점수 앞 10행";

proc print
    data=crm.w4_churn_current_scored(obs=10)
    noobs;

    format
        churn_probability_raw
        churn_probability_calibrated
        final_churn_probability
        percent8.2;

run;


title "WBS 4.1 v3_Revised 품질 점검";

proc print
    data=crm.w4_41_qa_summary
    noobs;

run;


title;

%put NOTE: WBS 4.1 v3_Revised 전체 작업이 정상적으로 끝났습니다.;

/*====================================================================
  WBS 4.2 Revised_new
  RFMP x 상대위험 매핑 및 실행대상 설계

  [목표]
    1. VALID와 CURRENT 고객을 각각 전체 기준으로 3등분합니다.
    2. RFMP 고객가치와 상대위험을 서로 다른 축으로 유지합니다.
    3. 개인별 대표 카테고리와 실행전략을 연결합니다.
    4. 위험 우선순위와 가치위험 우선순위를 분리합니다.

  [이번 수정]
    - risk_priority_rank:
        예측확률이 높은 고객부터 부여하는 순수 위험 순위입니다.
    - value_at_risk_rank:
        예측확률 x 과거 구매금액이 큰 고객부터 부여하는
        위험노출가치 순위입니다.
    - 두 순위는 PROC RANK 결과를 그대로 사용하므로 1부터 시작합니다.
    - High와 Medium은 이탈방지 실행후보로 구분합니다.
    - Low는 유지·교차판매 대상으로 분리합니다.

  [해석 제한]
    - High / Medium / Low는 절대위험이 아니라 상대위험 등급입니다.
    - 가치위험은 미래 매출이나 실제 손실액이 아닌 비교용 대리값입니다.
    - 비용·반응률·유지효과는 실험값이 아니라 시나리오 가정입니다.

  [입력 테이블]
    CRM.W4_CHURN_VALID_SCORED
    CRM.W4_CHURN_CURRENT_SCORED
    CRM.W4_41_QA_SUMMARY
    CRM.W3_CUSTOMER_RFMP_PY
    CRM.CLEAN_ONLINE

  [주요 산출물]
    CRM.W4_RELATIVE_RISK_CUTOFFS
    CRM.W4_VALID_RELATIVE_RISK
    CRM.W4_RELATIVE_RISK_METRICS
    CRM.W4_CUSTOMER_TOP_CATEGORY
    CRM.W4_CUSTOMER_RISK_RFMP
    CRM.W4_ACTION_ASSUMPTIONS
    CRM.W4_CUSTOMER_ACTION_PLAN
    CRM.W4_TIER_ACTION_SUMMARY
    CRM.W4_42_QA_SUMMARY
====================================================================*/

options validvarname=any obs=max replace;

%let CRM_PATH=/home/student/crm_db;
libname crm "&CRM_PATH.";

%let EXPECTED_SCORE_VERSION=W4_1_V3_REVISED;
%let EXPECTED_CURRENT_N=1468;


/*====================================================================
  0. 필수 입력 테이블과 변수 확인
====================================================================*/

%macro require_table(ds=, previous_step=);
    %if %sysfunc(exist(&ds.))=0 %then %do;
        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %put ERROR: &previous_step. 단계를 먼저 실행하십시오.;
        %abort cancel;
    %end;
    %else %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;
%mend;

%macro require_var(ds=, var=);
    %local dsid varnum rc;

    %let dsid=%sysfunc(open(&ds., i));

    %if &dsid.=0 %then %do;
        %put ERROR: &ds. 데이터셋을 열 수 없습니다.;
        %abort cancel;
    %end;

    %let varnum=%sysfunc(varnum(&dsid., &var.));
    %let rc=%sysfunc(close(&dsid.));

    %if &varnum.=0 %then %do;
        %put ERROR: &ds. 에 필수 변수 &var. 이(가) 없습니다.;
        %abort cancel;
    %end;
%mend;

%require_table(
    ds=crm.w4_churn_valid_scored,
    previous_step=WBS 4.1 v3_Revised
);

%require_table(
    ds=crm.w4_churn_current_scored,
    previous_step=WBS 4.1 v3_Revised
);

%require_table(
    ds=crm.w4_41_qa_summary,
    previous_step=WBS 4.1 v3_Revised
);

%require_table(
    ds=crm.w3_customer_rfmp_py,
    previous_step=WBS 3.5-3.9 RFMP 분석
);

%require_table(
    ds=crm.clean_online,
    previous_step=Week 1 데이터 정제
);

%require_var(ds=crm.w4_churn_valid_scored, var=customer_id);
%require_var(ds=crm.w4_churn_valid_scored, var=actual_churn_flag);
%require_var(ds=crm.w4_churn_valid_scored, var=final_churn_probability);
%require_var(ds=crm.w4_churn_valid_scored, var=score_version);

%require_var(ds=crm.w4_churn_current_scored, var=customer_id);
%require_var(ds=crm.w4_churn_current_scored, var=final_churn_probability);
%require_var(ds=crm.w4_churn_current_scored, var=score_version);
%require_var(ds=crm.w4_churn_current_scored, var=monetary);

%require_var(ds=crm.w3_customer_rfmp_py, var=customer_id);
%require_var(ds=crm.w3_customer_rfmp_py, var=rfmp_tier);

%require_var(ds=crm.clean_online, var=customer_id);
%require_var(ds=crm.clean_online, var=order_key);
%require_var(ds=crm.clean_online, var=product_category);
%require_var(ds=crm.clean_online, var=quantity);
%require_var(ds=crm.clean_online, var=avg_price);


/* 조인 전에 고객 중복 여부를 확인합니다. */
proc sql noprint;
    select count(*) - count(distinct customer_id)
      into :CURRENT_INPUT_DUP trimmed
    from crm.w4_churn_current_scored;

    select count(*) - count(distinct customer_id)
      into :RFMP_INPUT_DUP trimmed
    from crm.w3_customer_rfmp_py;
quit;

%macro stop_for_duplicate;
    %if %sysevalf(&CURRENT_INPUT_DUP. > 0) %then %do;
        %put ERROR: W4_CHURN_CURRENT_SCORED에 고객 중복이 있습니다.;
        %abort cancel;
    %end;

    %if %sysevalf(&RFMP_INPUT_DUP. > 0) %then %do;
        %put ERROR: W3_CUSTOMER_RFMP_PY에 고객 중복이 있습니다.;
        %abort cancel;
    %end;
%mend;

%stop_for_duplicate;


/*====================================================================
  1. VALID 고객의 상대위험 3등급 생성

  PROC RANK 그룹값: 0=Low, 1=Medium, 2=High
  동점 확률은 같은 등급에 배치합니다.
====================================================================*/

proc rank
    data=crm.w4_churn_valid_scored
    out=work.valid_relative_ranked
    groups=3
    ties=mean;

    var final_churn_probability;
    ranks relative_risk_group;
run;

data crm.w4_valid_relative_risk;
    set work.valid_relative_ranked;

    length relative_risk_grade $8;

    if missing(final_churn_probability) then do;
        relative_risk_rank = .;
        relative_risk_grade = "UNSCORED";
    end;
    else do;
        relative_risk_rank = relative_risk_group + 1;

        select (relative_risk_group);
            when (2) relative_risk_grade = "High";
            when (1) relative_risk_grade = "Medium";
            when (0) relative_risk_grade = "Low";
            otherwise relative_risk_grade = "UNSCORED";
        end;
    end;

    drop relative_risk_group;

    label
        relative_risk_rank  = "상대위험 순서(1=Low, 3=High)"
        relative_risk_grade = "전체 고객 기준 상대위험등급";
run;


/* VALID 전체 실제 이탈률을 Lift 기준으로 사용합니다. */
proc sql noprint;
    select mean(actual_churn_flag)
      into :VALID_CHURN_RATE trimmed
    from crm.w4_valid_relative_risk;
quit;


/*====================================================================
  2. VALID 등급별 실제 이탈률과 상위 1/3 타기팅 성능
====================================================================*/

proc sql;
    create table work.valid_risk_summary as
    select
        "VALID" as dataset_role length=8,
        relative_risk_rank,
        relative_risk_grade,
        count(*) as customer_count,
        min(final_churn_probability) as min_probability,
        max(final_churn_probability) as max_probability,
        mean(final_churn_probability) as mean_probability,
        sum(actual_churn_flag) as actual_churn_count,
        mean(actual_churn_flag) as observed_churn_rate,
        calculated observed_churn_rate / &VALID_CHURN_RATE.
            as lift_vs_overall
    from crm.w4_valid_relative_risk
    where relative_risk_grade ne "UNSCORED"
    group by relative_risk_rank, relative_risk_grade;
quit;


/* High를 타깃, Medium·Low를 비타깃으로 놓은 운영 규칙입니다. */
proc sql;
    create table work.high_target_confusion as
    select
        count(*) as valid_customer_count,

        sum(case
                when relative_risk_grade="High"
                 and actual_churn_flag=1 then 1
                else 0
            end) as true_positive,

        sum(case
                when relative_risk_grade="High"
                 and actual_churn_flag=0 then 1
                else 0
            end) as false_positive,

        sum(case
                when relative_risk_grade ne "High"
                 and actual_churn_flag=0 then 1
                else 0
            end) as true_negative,

        sum(case
                when relative_risk_grade ne "High"
                 and actual_churn_flag=1 then 1
                else 0
            end) as false_negative

    from crm.w4_valid_relative_risk
    where relative_risk_grade ne "UNSCORED";
quit;

data crm.w4_relative_risk_metrics;
    set work.high_target_confusion;

    length
        metric_scope $40
        interpretation $200;

    metric_scope = "High vs Medium+Low targeting rule";
    overall_churn_rate = &VALID_CHURN_RATE.;

    if true_positive + false_positive > 0 then
        precision = true_positive /
                    (true_positive + false_positive);

    if true_positive + false_negative > 0 then
        recall = true_positive /
                 (true_positive + false_negative);

    if true_negative + false_positive > 0 then
        specificity = true_negative /
                      (true_negative + false_positive);

    if not missing(recall) and not missing(specificity) then
        balanced_accuracy = (recall + specificity) / 2;

    high_observed_churn_rate = precision;

    if overall_churn_rate > 0 then
        high_lift_vs_overall =
            high_observed_churn_rate / overall_churn_rate;

    interpretation =
        "상위 1/3 타기팅 규칙 평가이며 절대 이탈 판정 성능이 아님";

    format
        overall_churn_rate
        precision
        recall
        specificity
        balanced_accuracy
        high_observed_churn_rate
        high_lift_vs_overall 8.4;
run;


/*====================================================================
  3. CURRENT 고객의 상대위험 3등급 생성

  CURRENT 안에서 상대적 캠페인 순서를 정하기 위한 별도 3등분입니다.
====================================================================*/

proc rank
    data=crm.w4_churn_current_scored
    out=work.current_relative_ranked
    groups=3
    ties=mean;

    var final_churn_probability;
    ranks relative_risk_group;
run;

data work.current_relative_risk;
    set work.current_relative_ranked;

    length relative_risk_grade $8;

    if missing(final_churn_probability) then do;
        relative_risk_rank = .;
        relative_risk_grade = "UNSCORED";
    end;
    else do;
        relative_risk_rank = relative_risk_group + 1;

        select (relative_risk_group);
            when (2) relative_risk_grade = "High";
            when (1) relative_risk_grade = "Medium";
            when (0) relative_risk_grade = "Low";
            otherwise relative_risk_grade = "UNSCORED";
        end;
    end;

    drop relative_risk_group;

    label
        relative_risk_rank  = "상대위험 순서(1=Low, 3=High)"
        relative_risk_grade = "전체 고객 기준 상대위험등급";
run;


/* CURRENT에는 실제 이탈결과가 없어 확률 범위만 저장합니다. */
proc sql;
    create table work.current_risk_summary as
    select
        "CURRENT" as dataset_role length=8,
        relative_risk_rank,
        relative_risk_grade,
        count(*) as customer_count,
        min(final_churn_probability) as min_probability,
        max(final_churn_probability) as max_probability,
        mean(final_churn_probability) as mean_probability,
        . as actual_churn_count,
        . as observed_churn_rate,
        . as lift_vs_overall
    from work.current_relative_risk
    where relative_risk_grade ne "UNSCORED"
    group by relative_risk_rank, relative_risk_grade;
quit;


/* VALID와 CURRENT의 경계를 한 테이블에 기록합니다. */
data crm.w4_relative_risk_cutoffs;
    set
        work.valid_risk_summary
        work.current_risk_summary;

    format
        min_probability
        max_probability
        mean_probability
        observed_churn_rate percent8.2
        lift_vs_overall 8.3;

    label
        min_probability     = "등급 내 최소 예측확률"
        max_probability     = "등급 내 최대 예측확률"
        mean_probability    = "등급 내 평균 예측확률"
        observed_churn_rate = "VALID 실제 이탈률"
        lift_vs_overall     = "VALID 전체 대비 Lift";
run;


/*====================================================================
  4. 고객별 실제 대표 카테고리 생성

  구매금액 대리값, 주문 수, 카테고리명 순으로 대표값을 정합니다.
====================================================================*/

proc sql;
    create table work.customer_category_summary as
    select
        customer_id,
        product_category,
        sum(quantity * avg_price) as category_sales,
        count(distinct order_key) as category_order_count
    from crm.clean_online
    where not missing(customer_id)
      and not missing(product_category)
      and quantity > 0
      and avg_price > 0
    group by customer_id, product_category;
quit;

proc sort data=work.customer_category_summary;
    by
        customer_id
        descending category_sales
        descending category_order_count
        product_category;
run;

data crm.w4_customer_top_category;
    set work.customer_category_summary;
    by customer_id;

    if first.customer_id;

    rename
        product_category     = personal_top_category
        category_sales       = personal_category_sales
        category_order_count = personal_category_orders;

    label
        product_category     = "개인별 실제 대표 카테고리"
        category_sales       = "대표 카테고리 구매금액 대리값"
        category_order_count = "대표 카테고리 주문 수";
run;


/*====================================================================
  5. CURRENT 상대위험 + RFMP + 개인 대표 카테고리 결합

  CURRENT를 기준으로 LEFT JOIN하여 고객 모집단을 보존합니다.
====================================================================*/

proc sql;
    create table work.customer_risk_rfmp_raw as
    select
        a.*,
        b.rfmp_tier as rfmp_tier_source length=12,
        c.personal_top_category,
        c.personal_category_sales,
        c.personal_category_orders
    from work.current_relative_risk as a

    left join crm.w3_customer_rfmp_py as b
      on a.customer_id = b.customer_id

    left join crm.w4_customer_top_category as c
      on a.customer_id = c.customer_id;
quit;

data crm.w4_customer_risk_rfmp;
    length
        rfmp_tier $12
        personal_top_category $80;

    set work.customer_risk_rfmp_raw;

    select (upcase(strip(rfmp_tier_source)));
        when ("VIP")      rfmp_tier = "VIP";
        when ("DIAMOND")  rfmp_tier = "Diamond";
        when ("PLATINUM") rfmp_tier = "Platinum";
        when ("GOLD")     rfmp_tier = "Gold";
        when ("SILVER")   rfmp_tier = "Silver";
        when ("BRONZE")   rfmp_tier = "Bronze";
        otherwise          rfmp_tier = "UNMATCHED";
    end;

    if missing(personal_top_category) then
        personal_top_category = "UNKNOWN";

    flag_rfmp_unmatched = (rfmp_tier = "UNMATCHED");
    flag_category_unmatched =
        (personal_top_category = "UNKNOWN");

    drop rfmp_tier_source;

    label
        rfmp_tier               = "RFMP 고객가치 등급"
        personal_top_category   = "개인별 실제 대표 카테고리"
        flag_rfmp_unmatched     = "RFMP 미매칭 여부"
        flag_category_unmatched = "대표 카테고리 미매칭 여부";
run;


/*====================================================================
  6. RFMP x 상대위험 18개 실행전략 매핑
====================================================================*/

data work.action_map;
    length
        rfmp_tier $12
        relative_risk_grade $8
        action_level $20
        contact_channel $20
        action_strategy $150;

    infile datalines dsd dlm='|' truncover;

    input
        rfmp_tier :$12.
        relative_risk_grade :$8.
        action_level :$20.
        contact_channel :$20.
        action_strategy :$150.;

    datalines;
VIP|High|HIGH_TOUCH|CALL|VIP_긴급_1대1_리텐션
VIP|Medium|DIGITAL_PAID|APP_CALL|VIP_개인화_혜택_리마인드
VIP|Low|OWNED_MONITOR|EMAIL_APP|VIP_관계유지_교차판매
Diamond|High|HIGH_TOUCH|CALL_APP|다이아몬드_우선_리텐션
Diamond|Medium|DIGITAL_PAID|APP|다이아몬드_맞춤혜택
Diamond|Low|OWNED_MONITOR|EMAIL_APP|다이아몬드_교차판매
Platinum|High|DIGITAL_PAID|APP_SMS|플래티넘_선별_리텐션
Platinum|Medium|DIGITAL_PAID|APP|플래티넘_개인화_리마인드
Platinum|Low|OWNED_MONITOR|EMAIL_APP|플래티넘_상품추천
Gold|High|DIGITAL_PAID|APP_SMS|골드_조건부_맞춤쿠폰
Gold|Medium|OWNED_MONITOR|APP|골드_행동기반_리마인드
Gold|Low|OWNED_MONITOR|EMAIL|골드_저비용_상품추천
Silver|High|DIGITAL_PAID|APP|실버_소액혜택_파일럿
Silver|Medium|OWNED_MONITOR|EMAIL|실버_저비용_리마인드
Silver|Low|OWNED_MONITOR|EMAIL|실버_자동추천_모니터링
Bronze|High|OWNED_MONITOR|EMAIL_APP|브론즈_저비용_윈백
Bronze|Medium|OWNED_MONITOR|EMAIL|브론즈_저비용_리타겟팅
Bronze|Low|OWNED_MONITOR|OWNED|브론즈_일반콘텐츠_모니터링
;
run;


/*====================================================================
  7. 경제성 시나리오 가정

  아래 수치는 관측 사실이 아닌 수정 가능한 가정입니다.
====================================================================*/

data crm.w4_action_assumptions;
    length
        action_level $20
        assumption_status $20
        assumption_note $200;

    format
        unit_cost comma12.2
        assumed_response_rate percent8.2
        assumed_retention_uplift percent8.2;

    infile datalines dsd dlm='|' truncover;

    input
        action_level :$20.
        unit_cost
        assumed_response_rate
        assumed_retention_uplift
        assumption_status :$20.
        assumption_note :$200.;

    datalines;
HIGH_TOUCH|12|0.25|0.12|SCENARIO_ONLY|1대1 접촉의 가정값이며 실제 실험값이 아님
DIGITAL_PAID|2|0.15|0.08|SCENARIO_ONLY|유료 디지털 접촉의 가정값이며 실제 실험값이 아님
OWNED_MONITOR|0.2|0.08|0.04|SCENARIO_ONLY|보유채널 운영의 가정값이며 실제 실험값이 아님
;
run;


/*====================================================================
  8. 고객별 액션 및 경제성 대리값 계산

  revenue_at_risk_proxy
    = 예측확률 x 과거 Monetary

  scenario_expected_value
    = 위험노출가치 x 가정 반응률 x 가정 유지상승률
====================================================================*/

proc sql;
    create table work.customer_action_raw as
    select
        a.*,
        b.action_level,
        b.contact_channel,
        b.action_strategy,
        c.unit_cost,
        c.assumed_response_rate,
        c.assumed_retention_uplift,
        c.assumption_status
    from crm.w4_customer_risk_rfmp as a

    left join work.action_map as b
      on a.rfmp_tier = b.rfmp_tier
     and a.relative_risk_grade = b.relative_risk_grade

    left join crm.w4_action_assumptions as c
      on b.action_level = c.action_level;
quit;

data work.customer_action_scored;
    set work.customer_action_raw;

    length
        economic_decision $24
        operational_queue $20;

    flag_action_unmatched = missing(action_strategy);

    /* High·Medium은 이탈방지 후보, Low는 유지·교차판매 대상입니다. */
    if relative_risk_grade in ("High", "Medium") then do;
        retention_target_flag = 1;
        operational_queue = "RETENTION";
    end;
    else if relative_risk_grade = "Low" then do;
        retention_target_flag = 0;
        operational_queue = "MAINTENANCE";
    end;
    else do;
        retention_target_flag = .;
        operational_queue = "MANUAL_REVIEW";
    end;

    if not missing(final_churn_probability)
       and not missing(monetary) then
        revenue_at_risk_proxy =
            final_churn_probability * monetary;

    if flag_action_unmatched=0 then do;
        scenario_campaign_cost = unit_cost;

        scenario_expected_value =
            revenue_at_risk_proxy
            * assumed_response_rate
            * assumed_retention_uplift;

        scenario_net_value_proxy =
            scenario_expected_value
            - scenario_campaign_cost;

        if action_level="OWNED_MONITOR" then
            economic_decision="OWNED_OR_MONITOR";
        else if scenario_net_value_proxy > 0 then
            economic_decision="PILOT_CANDIDATE";
        else
            economic_decision="HOLD_OR_REDESIGN";
    end;
    else economic_decision="MANUAL_REVIEW";

    label
        revenue_at_risk_proxy    = "예측 위험노출가치 대리값"
        retention_target_flag    = "이탈방지 실행후보 여부(High·Medium=1)"
        operational_queue        = "운영 대상 구분"
        scenario_campaign_cost   = "가정 캠페인 비용"
        scenario_expected_value  = "가정 기대가치"
        scenario_net_value_proxy = "가정 순가치 대리값"
        flag_action_unmatched    = "액션 매핑 누락 여부"
        economic_decision        = "시나리오 기반 실행 판단";
run;


/*====================================================================
  8-1. 목적이 다른 두 우선순위를 분리

  risk_priority_rank:
    예측확률이 높은 고객부터 1, 2, 3 ... 순위를 부여합니다.

  value_at_risk_rank:
    예측확률 x Monetary가 큰 고객부터 1, 2, 3 ... 순위를 부여합니다.

  PROC RANK 기본 순위가 1부터 시작하므로 별도로 1을 더하지 않습니다.
====================================================================*/

proc rank
    data=work.customer_action_scored
    out=work.customer_risk_ranked
    descending
    ties=low;

    var final_churn_probability;
    ranks risk_priority_rank;
run;

proc rank
    data=work.customer_risk_ranked
    out=work.customer_both_ranked
    descending
    ties=low;

    var revenue_at_risk_proxy;
    ranks value_at_risk_rank;
run;

data crm.w4_customer_action_plan;
    set work.customer_both_ranked;

    format
        final_churn_probability percent8.2
        monetary
        personal_category_sales
        revenue_at_risk_proxy
        scenario_campaign_cost
        scenario_expected_value
        scenario_net_value_proxy comma14.2
        assumed_response_rate
        assumed_retention_uplift percent8.2;

    label
        risk_priority_rank
            = "예측확률 기준 위험 우선순위"
        value_at_risk_rank
            = "예측확률 x 구매가치 기준 가치위험 순위";
run;

/* 저장 순서는 순수 위험 우선순위를 기준으로 정렬합니다. */
proc sort data=crm.w4_customer_action_plan;
    by risk_priority_rank;
run;


/*====================================================================
  9. RFMP x 상대위험 18개 셀 요약
====================================================================*/

proc sql;
    create table crm.w4_tier_action_summary as
    select
        rfmp_tier,
        relative_risk_rank,
        relative_risk_grade,
        action_level,
        contact_channel,
        action_strategy,
        count(distinct customer_id) as customer_count,
        mean(final_churn_probability) as mean_churn_probability,
        sum(monetary) as total_historical_monetary,
        sum(revenue_at_risk_proxy) as total_revenue_at_risk_proxy,
        sum(scenario_campaign_cost) as total_scenario_campaign_cost,
        sum(scenario_expected_value) as total_scenario_expected_value,
        sum(scenario_net_value_proxy) as total_scenario_net_value_proxy
    from crm.w4_customer_action_plan
    group by
        rfmp_tier,
        relative_risk_rank,
        relative_risk_grade,
        action_level,
        contact_channel,
        action_strategy
    order by
        relative_risk_rank descending,
        rfmp_tier;
quit;


/*====================================================================
  10. 최종 QA
====================================================================*/

proc sql noprint;
    select count(*)
      into :CURRENT_INPUT_N trimmed
    from crm.w4_churn_current_scored;

    select count(*)
      into :CURRENT_OUTPUT_N trimmed
    from crm.w4_customer_action_plan;

    select count(*) - count(distinct customer_id)
      into :CURRENT_OUTPUT_DUP trimmed
    from crm.w4_customer_action_plan;

    select sum(missing(final_churn_probability))
      into :CURRENT_MISSING_PROB trimmed
    from crm.w4_customer_action_plan;

    select sum(upcase(strip(score_version)) ne
               upcase("&EXPECTED_SCORE_VERSION."))
      into :SCORE_VERSION_MISMATCH trimmed
    from crm.w4_customer_action_plan;

    select sum(relative_risk_grade not in
               ("High", "Medium", "Low"))
      into :RISK_UNCLASSIFIED trimmed
    from crm.w4_customer_action_plan;

    select count(distinct relative_risk_grade)
      into :VALID_RISK_GRADE_N trimmed
    from crm.w4_valid_relative_risk
    where relative_risk_grade ne "UNSCORED";

    select count(distinct relative_risk_grade)
      into :CURRENT_RISK_GRADE_N trimmed
    from crm.w4_customer_action_plan
    where relative_risk_grade ne "UNSCORED";

    select sum(flag_rfmp_unmatched)
      into :RFMP_UNMATCHED trimmed
    from crm.w4_customer_action_plan;

    select sum(flag_category_unmatched)
      into :CATEGORY_UNMATCHED trimmed
    from crm.w4_customer_action_plan;

    select sum(flag_action_unmatched)
      into :ACTION_UNMATCHED trimmed
    from crm.w4_customer_action_plan;

    select count(*)
      into :ACTION_MAP_N trimmed
    from work.action_map;

    select count(*)
      into :ACTION_ASSUMPTION_N trimmed
    from crm.w4_action_assumptions;

    select mean(actual_churn_flag)
      into :VALID_ACTUAL_RATE trimmed
    from crm.w4_valid_relative_risk;

    select mean(final_churn_probability)
      into :VALID_MEAN_PROB trimmed
    from crm.w4_valid_relative_risk;

    select abs(
               mean(actual_churn_flag)
               - mean(final_churn_probability)
           )
      into :VALID_MEAN_GAP trimmed
    from crm.w4_valid_relative_risk;

    select observed_churn_rate
      into :RATE_HIGH trimmed
    from work.valid_risk_summary
    where relative_risk_grade="High";

    select observed_churn_rate
      into :RATE_MEDIUM trimmed
    from work.valid_risk_summary
    where relative_risk_grade="Medium";

    select observed_churn_rate
      into :RATE_LOW trimmed
    from work.valid_risk_summary
    where relative_risk_grade="Low";

    select high_lift_vs_overall
      into :HIGH_LIFT trimmed
    from crm.w4_relative_risk_metrics;

    select sum(scenario_campaign_cost)
      into :CUSTOMER_COST_TOTAL trimmed
    from crm.w4_customer_action_plan;

    select sum(total_scenario_campaign_cost)
      into :SUMMARY_COST_TOTAL trimmed
    from crm.w4_tier_action_summary;

    select coalesce(max(actual_value), 0)
      into :TRAIN_VALID_OVERLAP trimmed
    from crm.w4_41_qa_summary
    where upcase(strip(check_item))=
          "TRAIN VALID CUSTOMER OVERLAP";

    /* 이번 수정에서 추가한 순위 시작값 점검입니다. */
    select min(risk_priority_rank)
      into :MIN_RISK_PRIORITY_RANK trimmed
    from crm.w4_customer_action_plan
    where not missing(risk_priority_rank);

    select min(value_at_risk_rank)
      into :MIN_VALUE_PRIORITY_RANK trimmed
    from crm.w4_customer_action_plan
    where not missing(value_at_risk_rank);
quit;

data crm.w4_42_qa_summary;
    length
        check_item $60
        status $8
        detail $220;

    check_item="CURRENT population preserved";
    actual_value=&CURRENT_OUTPUT_N.;
    expected_value=&CURRENT_INPUT_N.;
    status=ifc(actual_value=expected_value, "PASS", "FAIL");
    detail="CURRENT 기준 LEFT JOIN 후 고객 수가 보존되어야 함";
    output;

    check_item="CURRENT population equals project total";
    actual_value=&CURRENT_OUTPUT_N.;
    expected_value=&EXPECTED_CURRENT_N.;
    status=ifc(actual_value=expected_value, "PASS", "REVIEW");
    detail="현재 프로젝트 기준 고객 수 1,468명과 비교";
    output;

    check_item="Customer ID duplicate";
    actual_value=&CURRENT_OUTPUT_DUP.;
    expected_value=0;
    status=ifc(actual_value=0, "PASS", "FAIL");
    detail="최종 고객 테이블은 고객당 정확히 1행이어야 함";
    output;

    check_item="Missing final probability";
    actual_value=&CURRENT_MISSING_PROB.;
    expected_value=0;
    status=ifc(actual_value=0, "PASS", "FAIL");
    detail="결측 확률을 임의 값으로 대체하지 않음";
    output;

    check_item="Score version mismatch";
    actual_value=&SCORE_VERSION_MISMATCH.;
    expected_value=0;
    status=ifc(actual_value=0, "PASS", "FAIL");
    detail="모든 점수는 W4_1_V3_REVISED에서 생성되어야 함";
    output;

    check_item="Relative risk unclassified";
    actual_value=&RISK_UNCLASSIFIED.;
    expected_value=0;
    status=ifc(actual_value=0, "PASS", "FAIL");
    detail="확률이 있는 고객은 High Medium Low 중 하나여야 함";
    output;

    check_item="VALID relative risk grade count";
    actual_value=&VALID_RISK_GRADE_N.;
    expected_value=3;
    status=ifc(actual_value=3, "PASS", "FAIL");
    detail="VALID에 High Medium Low 세 등급이 모두 생성되어야 함";
    output;

    check_item="CURRENT relative risk grade count";
    actual_value=&CURRENT_RISK_GRADE_N.;
    expected_value=3;
    status=ifc(actual_value=3, "PASS", "FAIL");
    detail="CURRENT에 High Medium Low 세 등급이 모두 생성되어야 함";
    output;

    check_item="RFMP unmatched customer";
    actual_value=&RFMP_UNMATCHED.;
    expected_value=0;
    status=ifc(actual_value=0, "PASS", "REVIEW");
    detail="RFMP 미매칭 고객은 제거하지 않고 UNMATCHED로 보존";
    output;

    check_item="Personal category unmatched customer";
    actual_value=&CATEGORY_UNMATCHED.;
    expected_value=0;
    status=ifc(actual_value=0, "PASS", "REVIEW");
    detail="유효 거래가 없는 고객은 UNKNOWN으로 보존";
    output;

    check_item="Action mapping missing";
    actual_value=&ACTION_UNMATCHED.;
    expected_value=0;
    status=ifc(actual_value=0, "PASS", "FAIL");
    detail="6개 RFMP x 3개 상대위험의 전략 매핑 누락 확인";
    output;

    check_item="Action mapping row count";
    actual_value=&ACTION_MAP_N.;
    expected_value=18;
    status=ifc(actual_value=18, "PASS", "FAIL");
    detail="6개 RFMP x 3개 상대위험 정책표는 18행이어야 함";
    output;

    check_item="Action assumption row count";
    actual_value=&ACTION_ASSUMPTION_N.;
    expected_value=3;
    status=ifc(actual_value=3, "PASS", "FAIL");
    detail="세 가지 실행수준 가정 확인";
    output;

    check_item="VALID risk rates ordered";
    actual_value=(
        &RATE_HIGH. > &RATE_MEDIUM.
        and &RATE_MEDIUM. > &RATE_LOW.
    );
    expected_value=1;
    status=ifc(actual_value=1, "PASS", "REVIEW");
    detail="VALID 실제 이탈률이 High > Medium > Low인지 확인";
    output;

    check_item="VALID High lift greater than 1";
    actual_value=&HIGH_LIFT.;
    expected_value=1;
    status=ifc(actual_value>1, "PASS", "REVIEW");
    detail="High 실제 이탈률이 VALID 전체보다 높은지 확인";
    output;

    check_item="Mean probability gap within 3pct";
    actual_value=&VALID_MEAN_GAP.;
    expected_value=0.03;
    status=ifc(actual_value<=expected_value, "PASS", "REVIEW");
    detail="미해결: 실제 이탈률과 평균 예측확률의 차이";
    output;

    check_item="TRAIN VALID customer overlap";
    actual_value=&TRAIN_VALID_OVERLAP.;
    expected_value=0;
    status=ifc(actual_value=0, "PASS", "INFO");
    detail="미해결: 시간 스냅샷 중복이며 고객 독립 검증이 아님";
    output;

    check_item="Scenario cost aggregation";
    actual_value=&CUSTOMER_COST_TOTAL.;
    expected_value=&SUMMARY_COST_TOTAL.;
    status=ifc(
        abs(actual_value-expected_value)<0.000001,
        "PASS",
        "FAIL"
    );
    detail="고객별 가정 비용과 18개 셀 요약 합계 비교";
    output;

    check_item="Risk priority starts at 1";
    actual_value=&MIN_RISK_PRIORITY_RANK.;
    expected_value=1;
    status=ifc(actual_value=1, "PASS", "FAIL");
    detail="예측확률 기준 위험 우선순위의 첫 순위 확인";
    output;

    check_item="Value-at-risk priority starts at 1";
    actual_value=&MIN_VALUE_PRIORITY_RANK.;
    expected_value=1;
    status=ifc(actual_value=1, "PASS", "FAIL");
    detail="위험노출가치 기준 순위의 첫 순위 확인";
    output;
run;


/*====================================================================
  11. 핵심 결과 출력
====================================================================*/

title "WBS 4.2 VALID·CURRENT 상대위험 등급 범위";
proc print data=crm.w4_relative_risk_cutoffs noobs;
run;
title;

title "WBS 4.2 상위 1/3 타기팅 규칙 성능";
proc print data=crm.w4_relative_risk_metrics noobs;
run;
title;

title "WBS 4.2 CURRENT 상대위험등급 분포";
proc freq data=crm.w4_customer_risk_rfmp;
    tables relative_risk_grade / missing nocum;
run;
title;

title "WBS 4.2 RFMP 등급 x 상대위험등급 고객 수";
proc freq data=crm.w4_customer_risk_rfmp;
    tables rfmp_tier * relative_risk_grade /
        missing norow nocol nopercent;
run;
title;

title "WBS 4.2 경제성 시나리오 가정";
proc print data=crm.w4_action_assumptions noobs;
run;
title;

title "WBS 4.2 RFMP x 상대위험 실행전략 요약";
proc print data=crm.w4_tier_action_summary noobs;
    var
        rfmp_tier
        relative_risk_grade
        customer_count
        action_level
        contact_channel
        action_strategy
        mean_churn_probability
        total_revenue_at_risk_proxy
        total_scenario_campaign_cost
        total_scenario_net_value_proxy;

    format
        mean_churn_probability percent8.2
        total_revenue_at_risk_proxy
        total_scenario_campaign_cost
        total_scenario_net_value_proxy comma14.2;
run;
title;


/* 순수 위험 우선순위: 이탈가능성이 높은 고객을 확인합니다. */
title "WBS 4.2 예측확률 기준 위험 우선순위 상위 20명";
proc print data=crm.w4_customer_action_plan(obs=20) noobs;
    var
        risk_priority_rank
        customer_id
        rfmp_tier
        relative_risk_grade
        final_churn_probability
        monetary
        value_at_risk_rank
        personal_top_category
        action_strategy;
run;
title;


/* High·Medium 중 경제적 노출이 큰 실행후보를 확인합니다. */
proc sort
    data=crm.w4_customer_action_plan(
        where=(retention_target_flag=1)
    )
    out=work.retention_value_priority;

    by value_at_risk_rank;
run;

title "WBS 4.2 High·Medium 가치위험 실행후보 상위 20명";
proc print data=work.retention_value_priority(obs=20) noobs;
    var
        value_at_risk_rank
        risk_priority_rank
        customer_id
        rfmp_tier
        relative_risk_grade
        final_churn_probability
        monetary
        revenue_at_risk_proxy
        personal_top_category
        action_strategy
        economic_decision;
run;
title;


title "WBS 4.2 최종 품질 점검";
proc print data=crm.w4_42_qa_summary noobs;
run;
title;

%put NOTE: WBS 4.2 Revised_new 실행이 완료되었습니다.;
%put NOTE: risk_priority_rank와 value_at_risk_rank는 서로 다른 목적의 순위입니다.;
%put NOTE: 두 순위는 1부터 시작하며 QA에서 확인합니다.;
%put NOTE: 평균확률 오차와 TRAIN VALID 고객 중복은 4.4 이전까지 추가 검토합니다.;

/*====================================================================
  WBS 4.3 Revised
  로그변환 및 확률·위험등급 안정성 재검증

  [목표]
    1. 4.1 기준모델과 로그변환 후보모델을 같은 VALID에서 비교합니다.
    2. 로그변환이 전체 VALID와 신규 고객 VALID에서 개선되는지 확인합니다.
    3. 로그변환 전후 상대위험등급과 위험 우선순위의 안정성을 확인합니다.
    4. 로그변환 전후 가치위험 우선순위의 안정성을 확인합니다.
    5. 아래 두 결론 중 하나를 근거와 함께 출력합니다.
       - KEEP_BASELINE
       - LOG_MODEL_REVIEW

  [수행 범위]
    - 기준모델은 W4_1_V3_REVISED의 RAW_UNWEIGHTED 확률입니다.
    - 후보모델은 기준모델과 같은 입력변수·전처리·알고리즘을 사용합니다.
    - 후보모델에서 달라지는 것은 선택된 변수의 log(1+x) 변환뿐입니다.
    - VALID 전체와 TRAIN에 없었던 신규 VALID 고객을 따로 평가합니다.
    - 4.2의 상대위험 3등급과 두 우선순위가 유지되는지 비교합니다.

  [해석 유의사항]
    - High·Medium·Low는 절대위험이 아니라 전체 고객 내 상대위험입니다.
    - 로그변환 후보의 근소한 성능 개선만으로 모델을 자동 교체하지 않습니다.
    - 이 코드는 4.1과 4.2의 기존 산출물을 변경하지 않습니다.
====================================================================*/

options validvarname=any obs=max replace;

%let CRM_PATH=/home/student/crm_db;
libname crm "&CRM_PATH.";

/* 팀의 실무 검토 기준입니다. 통계적 유의성 기준은 아닙니다. */
%let MIN_BRIER_GAIN=0.01;
%let MAX_AUC_LOSS=0.01;
%let MAX_UNSEEN_BRIER_LOSS=0.01;

%let EXPECTED_SCORE_VERSION=W4_1_V3_REVISED;
%let EXPECTED_TRAIN_N=900;
%let EXPECTED_VALID_N=1211;
%let EXPECTED_CURRENT_N=1468;

/* 4.1 기준모델의 재현 확인값입니다. */
%let EXPECTED_BASELINE_AUC=0.6534;
%let EXPECTED_BASELINE_PR_AUC=0.8405;
%let EXPECTED_BASELINE_BRIER=0.1816;
%let EXPECTED_BASELINE_LOGLOSS=0.5484;
%let METRIC_TOLERANCE=0.005;


/*====================================================================
  0. 필수 입력 테이블과 변수 확인
====================================================================*/

%macro require_table(ds=, previous_step=);
    %if %sysfunc(exist(&ds.))=0 %then %do;
        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %put ERROR: &previous_step. 단계를 먼저 실행하십시오.;
        %abort cancel;
    %end;
    %else %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;
%mend;

%macro require_var(ds=, var=);
    %local dsid varnum rc;

    %let dsid=%sysfunc(open(&ds., i));

    %if &dsid.=0 %then %do;
        %put ERROR: &ds. 데이터셋을 열 수 없습니다.;
        %abort cancel;
    %end;

    %let varnum=%sysfunc(varnum(&dsid., &var.));
    %let rc=%sysfunc(close(&dsid.));

    %if &varnum.=0 %then %do;
        %put ERROR: &ds. 에 필수 변수 &var. 이(가) 없습니다.;
        %abort cancel;
    %end;
%mend;

%require_table(ds=crm.w3_churn_split_v2, previous_step=WBS 3.2);
%require_table(ds=crm.w4_churn_valid_scored, previous_step=WBS 4.1 v3_Revised);
%require_table(ds=crm.w4_churn_current_scored, previous_step=WBS 4.1 v3_Revised);
%require_table(ds=crm.w4_valid_relative_risk, previous_step=WBS 4.2 Revised_new);
%require_table(ds=crm.w4_customer_action_plan, previous_step=WBS 4.2 Revised_new);
%require_table(ds=crm.w4_42_qa_summary, previous_step=WBS 4.2 Revised_new);
%require_table(ds=crm.clean_online, previous_step=Week 1-5 정제);
%require_table(ds=crm.clean_customer, previous_step=Week 1-5 정제);

%require_var(ds=crm.w4_churn_valid_scored, var=customer_id);
%require_var(ds=crm.w4_churn_valid_scored, var=snapshot_key);
%require_var(ds=crm.w4_churn_valid_scored, var=actual_churn_flag);
%require_var(ds=crm.w4_churn_valid_scored, var=final_churn_probability);
%require_var(ds=crm.w4_churn_valid_scored, var=score_version);

%require_var(ds=crm.w4_churn_current_scored, var=customer_id);
%require_var(ds=crm.w4_churn_current_scored, var=final_churn_probability);
%require_var(ds=crm.w4_churn_current_scored, var=score_version);
%require_var(ds=crm.w4_churn_current_scored, var=monetary);

%require_var(ds=crm.w4_valid_relative_risk, var=relative_risk_grade);
%require_var(ds=crm.w4_customer_action_plan, var=risk_priority_rank);
%require_var(ds=crm.w4_customer_action_plan, var=value_at_risk_rank);
%require_var(ds=crm.w4_customer_action_plan, var=revenue_at_risk_proxy);


proc datasets library=crm nolist nowarn;
    delete
        w4_43_log_rule
        w4_43_model_compare
        w4_43_stability_summary
        w4_43_grade_transition
        w4_43_customer_compare
        w4_43_decision_check
        w4_43_qa_summary;
quit;


/*====================================================================
  1. 로그변환 후보모델 학습 및 안정성 검증
====================================================================*/

proc python restart;
submit;

import os
os.environ["OMP_NUM_THREADS"] = "1"
os.environ["OPENBLAS_NUM_THREADS"] = "1"
os.environ["MKL_NUM_THREADS"] = "1"
os.environ["NUMEXPR_NUM_THREADS"] = "1"

import gc
import numpy as np
import pandas as pd

from sklearn.compose import ColumnTransformer
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.impute import SimpleImputer
from sklearn.metrics import (
    average_precision_score,
    brier_score_loss,
    log_loss,
    roc_auc_score
)
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler


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


def save_sas(frame, table_name):
    output = frame.reset_index(drop=True).copy()
    for column in output.select_dtypes(include=["category"]).columns:
        output[column] = output[column].astype(str)
    for column in output.select_dtypes(include=["bool"]).columns:
        output[column] = output[column].astype(int)
    SAS.df2sd(output, dataset=f"crm.{table_name}")


def make_onehot():
    try:
        return OneHotEncoder(handle_unknown="ignore", sparse_output=False)
    except TypeError:
        return OneHotEncoder(handle_unknown="ignore", sparse=False)


def sas_date_to_datetime(series):
    if pd.api.types.is_datetime64_any_dtype(series):
        return pd.to_datetime(series)
    numeric = pd.to_numeric(series, errors="coerce")
    if numeric.notna().mean() >= 0.90:
        return pd.to_datetime(numeric, unit="D", origin="1960-01-01", errors="coerce")
    return pd.to_datetime(series, errors="coerce")


def metric_row(scope, model_variant, actual, probability):
    actual = np.asarray(actual, dtype=int)
    probability = np.asarray(probability, dtype=float)

    valid = np.isfinite(probability)
    actual = actual[valid]
    probability = probability[valid]

    class_count = len(np.unique(actual))

    if len(actual) == 0:
        return {
            "evaluation_scope": scope,
            "model_variant": model_variant,
            "customer_count": 0,
            "class_count": 0,
            "actual_churn_rate": np.nan,
            "mean_probability": np.nan,
            "probability_gap": np.nan,
            "roc_auc": np.nan,
            "pr_auc": np.nan,
            "brier_score": np.nan,
            "log_loss": np.nan
        }

    if class_count >= 2:
        auc_value = float(roc_auc_score(actual, probability))
        pr_value = float(average_precision_score(actual, probability))
    else:
        auc_value = np.nan
        pr_value = np.nan

    return {
        "evaluation_scope": scope,
        "model_variant": model_variant,
        "customer_count": int(len(actual)),
        "class_count": int(class_count),
        "actual_churn_rate": float(actual.mean()),
        "mean_probability": float(probability.mean()),
        "probability_gap": float(actual.mean() - probability.mean()),
        "roc_auc": auc_value,
        "pr_auc": pr_value,
        "brier_score": float(brier_score_loss(actual, probability)),
        "log_loss": float(log_loss(actual, probability, labels=[0, 1]))
    }


def relative_grade(probability):
    probability = pd.Series(probability, dtype="float64")
    result = pd.Series("UNSCORED", index=probability.index, dtype="object")

    valid = probability.notna() & np.isfinite(probability)
    valid_probability = probability.loc[valid]

    if len(valid_probability) == 0:
        return result

    ranks = valid_probability.rank(method="average", ascending=True)
    groups = np.floor(ranks * 3 / (len(valid_probability) + 1)).clip(lower=0, upper=2).astype(int)

    grade_map = {0: "Low", 1: "Medium", 2: "High"}
    result.loc[valid] = groups.map(grade_map)
    return result


def descending_rank(values):
    return pd.Series(values, dtype="float64").rank(method="min", ascending=False)


def rank_correlation(rank_a, rank_b):
    pair = pd.DataFrame({
        "rank_a": pd.to_numeric(rank_a, errors="coerce"),
        "rank_b": pd.to_numeric(rank_b, errors="coerce")
    }).dropna()

    if len(pair) < 2:
        return np.nan

    return float(pair["rank_a"].corr(pair["rank_b"]))


def overlap_statistics(keys, baseline_grade, candidate_grade):
    keys = pd.Series(keys).astype(str)
    baseline_grade = pd.Series(baseline_grade).astype(str)
    candidate_grade = pd.Series(candidate_grade).astype(str)

    baseline_high = set(keys.loc[baseline_grade.eq("High")])
    candidate_high = set(keys.loc[candidate_grade.eq("High")])

    intersection = baseline_high.intersection(candidate_high)
    union = baseline_high.union(candidate_high)

    retention_rate = len(intersection) / len(baseline_high) if len(baseline_high) > 0 else np.nan
    jaccard = len(intersection) / len(union) if len(union) > 0 else np.nan

    return {
        "baseline_high_count": len(baseline_high),
        "candidate_high_count": len(candidate_high),
        "high_overlap_count": len(intersection),
        "high_retention_rate": retention_rate,
        "high_jaccard": jaccard
    }


def stability_row(dataset_role, key, baseline_probability, candidate_probability,
                  baseline_grade, candidate_grade, baseline_risk_rank, candidate_risk_rank,
                  baseline_value_rank=None, candidate_value_rank=None):
    key = pd.Series(key).astype(str)
    baseline_probability = pd.Series(baseline_probability, dtype="float64")
    candidate_probability = pd.Series(candidate_probability, dtype="float64")
    baseline_grade = pd.Series(baseline_grade).astype(str)
    candidate_grade = pd.Series(candidate_grade).astype(str)

    overlap = overlap_statistics(key, baseline_grade, candidate_grade)

    row = {
        "dataset_role": dataset_role,
        "customer_count": int(len(key)),
        "mean_probability_abs_diff": float(np.mean(np.abs(baseline_probability - candidate_probability))),
        "max_probability_abs_diff": float(np.max(np.abs(baseline_probability - candidate_probability))),
        "risk_rank_correlation": rank_correlation(baseline_risk_rank, candidate_risk_rank),
        "grade_match_rate": float(np.mean(baseline_grade.to_numpy() == candidate_grade.to_numpy())),
        **overlap,
        "value_rank_correlation": np.nan,
        "top100_value_overlap_count": np.nan,
        "top100_val_overlap_rate": np.nan # 32자 제한 수정
    }

    if baseline_value_rank is not None and candidate_value_rank is not None:
        baseline_value_rank = pd.to_numeric(baseline_value_rank, errors="coerce")
        candidate_value_rank = pd.to_numeric(candidate_value_rank, errors="coerce")

        row["value_rank_correlation"] = rank_correlation(baseline_value_rank, candidate_value_rank)

        baseline_top100 = set(key.loc[baseline_value_rank <= 100])
        candidate_top100 = set(key.loc[candidate_value_rank <= 100])

        overlap_count = len(baseline_top100.intersection(candidate_top100))

        row["top100_value_overlap_count"] = overlap_count
        row["top100_val_overlap_rate"] = overlap_count / len(baseline_top100) if len(baseline_top100) > 0 else np.nan

    return row


def transition_rows(dataset_role, baseline_grade, candidate_grade):
    grade_order = ["Low", "Medium", "High"]
    baseline_grade = pd.Series(baseline_grade).astype(str)
    candidate_grade = pd.Series(candidate_grade).astype(str)
    rows = []

    for base_grade in grade_order:
        base_total = int(baseline_grade.eq(base_grade).sum())

        for log_grade in grade_order:
            count = int((baseline_grade.eq(base_grade) & candidate_grade.eq(log_grade)).sum())

            rows.append({
                "dataset_role": dataset_role,
                "baseline_grade": base_grade,
                "candidate_grade": log_grade,
                "customer_count": count,
                "row_share": count / base_total if base_total > 0 else np.nan
            })

    return rows


print("=" * 72, flush=True)
print("WBS 4.3 Revised. 로그변환 및 확률·위험등급 안정성 재검증", flush=True)
print("=" * 72, flush=True)


min_brier_gain = float(SAS.symget("MIN_BRIER_GAIN"))
max_auc_loss = float(SAS.symget("MAX_AUC_LOSS"))
max_unseen_brier_loss = float(SAS.symget("MAX_UNSEEN_BRIER_LOSS"))

expected_score_version = str(SAS.symget("EXPECTED_SCORE_VERSION")).strip().upper()

split_data = normalize_columns(SAS.sd2df("crm.w3_churn_split_v2"))
valid_score = normalize_columns(SAS.sd2df("crm.w4_churn_valid_scored"))
current_score = normalize_columns(SAS.sd2df("crm.w4_churn_current_scored"))
valid_risk = normalize_columns(SAS.sd2df("crm.w4_valid_relative_risk"))
current_action = normalize_columns(SAS.sd2df("crm.w4_customer_action_plan"))
qa_42 = normalize_columns(SAS.sd2df("crm.w4_42_qa_summary"))


numeric_features = [
    "recency", "frequency", "monetary", "avg_order_value", "avg_shipping",
    "coupon_usage_rate", "coupon_click_rate", "tenure", "product_category_count",
    "category_concentration", "avg_days_between_orders", "std_days_between_orders",
    "last_coupon_used", "clv_proxy"
]

categorical_features = ["gender", "region"]
feature_columns = numeric_features + categorical_features


require_columns(split_data, ["snapshot_key", "customer_id", "split_role", "churn_flag"] + feature_columns, "CRM.W3_CHURN_SPLIT_V2")
require_columns(valid_score, ["snapshot_key", "customer_id", "actual_churn_flag", "final_churn_probability", "score_version"], "CRM.W4_CHURN_VALID_SCORED")
require_columns(current_score, ["customer_id", "final_churn_probability", "score_version", "monetary"], "CRM.W4_CHURN_CURRENT_SCORED")
require_columns(valid_risk, ["snapshot_key", "customer_id", "relative_risk_grade", "final_churn_probability"], "CRM.W4_VALID_RELATIVE_RISK")
require_columns(current_action, ["customer_id", "rfmp_tier", "relative_risk_grade", "final_churn_probability", "monetary", "revenue_at_risk_proxy", "risk_priority_rank", "value_at_risk_rank"], "CRM.W4_CUSTOMER_ACTION_PLAN")

if "status" in qa_42.columns:
    fail_count_42 = int(qa_42["status"].astype(str).str.strip().str.upper().eq("FAIL").sum())
else:
    fail_count_42 = 0

if fail_count_42 > 0:
    raise ValueError("W4_42_QA_SUMMARY에 FAIL이 있으므로 4.3을 중단합니다.")


for frame in [split_data, valid_score, current_score, valid_risk, current_action]:
    frame["customer_id"] = clean_id(frame["customer_id"])

split_data["snapshot_key"] = clean_id(split_data["snapshot_key"])
valid_score["snapshot_key"] = clean_id(valid_score["snapshot_key"])
valid_risk["snapshot_key"] = clean_id(valid_risk["snapshot_key"])

split_data["split_role"] = split_data["split_role"].astype(str).str.strip().str.upper()

for column in numeric_features + ["churn_flag"]:
    split_data[column] = pd.to_numeric(split_data[column], errors="coerce")

split_data[numeric_features] = split_data[numeric_features].replace([np.inf, -np.inf], np.nan)

for column in categorical_features:
    split_data[column] = split_data[column].fillna("UNKNOWN").astype(str).str.strip().replace("", "UNKNOWN")

valid_score["actual_churn_flag"] = pd.to_numeric(valid_score["actual_churn_flag"], errors="coerce")
valid_score["final_churn_probability"] = pd.to_numeric(valid_score["final_churn_probability"], errors="coerce")
valid_risk["final_churn_probability"] = pd.to_numeric(valid_risk["final_churn_probability"], errors="coerce")
current_score["final_churn_probability"] = pd.to_numeric(current_score["final_churn_probability"], errors="coerce")

for column in ["final_churn_probability", "monetary", "revenue_at_risk_proxy", "risk_priority_rank", "value_at_risk_rank"]:
    current_action[column] = pd.to_numeric(current_action[column], errors="coerce")

train = split_data.loc[split_data["split_role"].eq("TRAIN")].copy()
valid = split_data.loc[split_data["split_role"].eq("VALID")].copy()

if len(train) == 0 or len(valid) == 0:
    raise ValueError("TRAIN 또는 VALID 데이터가 비어 있습니다.")

if train["churn_flag"].nunique() < 2 or valid["churn_flag"].nunique() < 2:
    raise ValueError("TRAIN 또는 VALID의 churn_flag가 한 종류뿐입니다.")

if train["snapshot_key"].duplicated().any() or valid["snapshot_key"].duplicated().any():
    raise ValueError("TRAIN 또는 VALID에 중복 snapshot_key가 있습니다.")

print(f"[1/8] 입력 확인: TRAIN={len(train):,}, VALID={len(valid):,}", flush=True)


valid_base = valid[["snapshot_key", "customer_id", "churn_flag"]].copy()
valid_score_small = valid_score[["snapshot_key", "customer_id", "actual_churn_flag", "final_churn_probability", "score_version"]].rename(columns={"final_churn_probability": "score_table_probability"})
valid_risk_small = valid_risk[["snapshot_key", "customer_id", "relative_risk_grade", "final_churn_probability"]].rename(columns={"relative_risk_grade": "baseline_risk_grade", "final_churn_probability": "risk_table_probability"})

valid_eval = valid_base.merge(valid_score_small, on=["snapshot_key", "customer_id"], how="left", validate="one_to_one").merge(valid_risk_small, on=["snapshot_key", "customer_id"], how="left", validate="one_to_one")
valid_eval["baseline_probability"] = valid_eval["score_table_probability"]

valid_probability_alignment = float(np.nanmax(np.abs(valid_eval["score_table_probability"] - valid_eval["risk_table_probability"])))
label_mismatch = int((valid_eval["churn_flag"] != valid_eval["actual_churn_flag"]).sum())

if label_mismatch > 0:
    raise ValueError("W3_CHURN_SPLIT_V2와 W4_CHURN_VALID_SCORED의 라벨이 다릅니다.")


log_candidates = [
    "recency", "frequency", "monetary", "avg_order_value", "avg_shipping",
    "avg_days_between_orders", "std_days_between_orders", "clv_proxy"
]

log_rule_rows = []
log_columns = []

for column in log_candidates:
    series = pd.to_numeric(train[column], errors="coerce").dropna()
    skewness = float(series.skew()) if len(series) >= 3 else np.nan
    minimum = float(series.min()) if len(series) > 0 else np.nan

    apply_log = bool(np.isfinite(skewness) and np.isfinite(minimum) and skewness > 1.0 and minimum >= 0)

    if apply_log:
        log_columns.append(column)
        reason = "TRAIN 왜도>1, 최솟값>=0"
    else:
        reason = "적용 기준 미충족"

    log_rule_rows.append({
        "variable_name": column,
        "train_skewness": skewness,
        "train_minimum": minimum,
        "log_applied": int(apply_log),
        "decision_reason": reason
    })

log_rule = pd.DataFrame(log_rule_rows)
print("[2/8] 로그변환 변수: " + (", ".join(log_columns) if log_columns else "없음"), flush=True)


online = normalize_columns(SAS.sd2df("crm.clean_online"))
customer = normalize_columns(SAS.sd2df("crm.clean_customer"))

required_online = [
    "customer_id", "order_key", "transaction_date", "product_category", "quantity",
    "avg_price", "shipping_fee", "coupon_status", "flag_missing_core", "flag_return",
    "flag_zero_quantity", "flag_invalid_price", "flag_customer_unmatched"
]

online = online[required_online].copy()
customer = customer[["customer_id", "gender", "region", "tenure"]].copy()

online["customer_id"] = clean_id(online["customer_id"])
customer["customer_id"] = clean_id(customer["customer_id"])

if customer["customer_id"].duplicated().any():
    raise ValueError("CLEAN_CUSTOMER에 중복 customer_id가 있습니다.")

online["order_key"] = online["order_key"].astype(str).str.strip()
online["product_category"] = online["product_category"].fillna("UNKNOWN").astype(str).str.strip().replace("", "UNKNOWN")

for column in ["quantity", "avg_price", "shipping_fee", "flag_missing_core", "flag_return", "flag_zero_quantity", "flag_invalid_price", "flag_customer_unmatched"]:
    online[column] = pd.to_numeric(online[column], errors="coerce")

online["transaction_date"] = sas_date_to_datetime(online["transaction_date"])
online["coupon_status_std"] = online["coupon_status"].fillna("").astype(str).str.strip().str.upper()

valid_mask = (
    online["flag_missing_core"].eq(0) & online["flag_return"].eq(0) &
    online["flag_zero_quantity"].eq(0) & online["flag_invalid_price"].eq(0) &
    online["flag_customer_unmatched"].eq(0) & online["transaction_date"].notna() &
    online["customer_id"].ne("") & online["order_key"].ne("")
)

online_valid = online.loc[valid_mask].copy()
del online
gc.collect()

online_valid["line_amount"] = online_valid["quantity"] * online_valid["avg_price"]
online_valid["order_coupon_used"] = online_valid["coupon_status_std"].eq("USED").astype(int)
online_valid["order_coupon_clicked"] = online_valid["coupon_status_std"].isin(["USED", "CLICKED"]).astype(int)

current_cutoff = online_valid["transaction_date"].max()

orders = online_valid.groupby(["customer_id", "order_key", "transaction_date"], as_index=False).agg(
    order_amount=("line_amount", "sum"),
    order_shipping=("shipping_fee", "max"),
    order_coupon_used=("order_coupon_used", "max"),
    order_coupon_clicked=("order_coupon_clicked", "max")
)

core = orders.groupby("customer_id", as_index=False).agg(
    first_purchase_date=("transaction_date", "min"),
    last_purchase_date=("transaction_date", "max"),
    frequency=("order_key", "nunique"),
    monetary=("order_amount", "sum"),
    avg_order_value=("order_amount", "mean"),
    avg_shipping=("order_shipping", "mean"),
    coupon_usage_rate=("order_coupon_used", "mean"),
    coupon_click_rate=("order_coupon_clicked", "mean")
)

core["recency"] = (current_cutoff - core["last_purchase_date"]).dt.days
core["observation_days"] = (core["last_purchase_date"] - core["first_purchase_date"]).dt.days + 1

category_count = online_valid.groupby(["customer_id", "product_category"], as_index=False).agg(category_order_count=("order_key", "nunique"))
category_feature = category_count.groupby("customer_id", as_index=False).agg(
    product_category_count=("product_category", "nunique"),
    max_category_orders=("category_order_count", "max"),
    total_category_orders=("category_order_count", "sum")
)

category_feature["category_concentration"] = category_feature["max_category_orders"] / category_feature["total_category_orders"].replace(0, np.nan)
category_feature = category_feature[["customer_id", "product_category_count", "category_concentration"]]

purchase_dates = online_valid[["customer_id", "transaction_date"]].drop_duplicates().sort_values(["customer_id", "transaction_date"])
purchase_dates["gap_days"] = purchase_dates.groupby("customer_id")["transaction_date"].diff().dt.days

gap_feature = purchase_dates.loc[purchase_dates["gap_days"] > 0].groupby("customer_id", as_index=False).agg(
    avg_days_between_orders=("gap_days", "mean"),
    std_days_between_orders=("gap_days", "std")
)

last_date = orders.groupby("customer_id")["transaction_date"].transform("max")
last_coupon = orders.loc[orders["transaction_date"] == last_date].groupby("customer_id", as_index=False).agg(last_coupon_used=("order_coupon_used", "max"))

current_features = core.merge(category_feature, on="customer_id", how="left", validate="one_to_one").merge(gap_feature, on="customer_id", how="left", validate="one_to_one").merge(last_coupon, on="customer_id", how="left", validate="one_to_one").merge(customer[["customer_id", "gender", "region", "tenure"]], on="customer_id", how="left", validate="one_to_one")

for column in ["product_category_count", "category_concentration", "avg_days_between_orders", "std_days_between_orders", "last_coupon_used", "tenure"]:
    current_features[column] = pd.to_numeric(current_features[column], errors="coerce").fillna(0)

current_features["annual_order_frequency"] = current_features["frequency"] / (current_features["observation_days"].clip(lower=30) / 365.25)
current_features["clv_proxy"] = current_features["avg_order_value"] * current_features["annual_order_frequency"] * (current_features["tenure"].clip(lower=1) / 12)

for column in numeric_features:
    current_features[column] = pd.to_numeric(current_features[column], errors="coerce")

current_features[numeric_features] = current_features[numeric_features].replace([np.inf, -np.inf], np.nan)

for column in categorical_features:
    current_features[column] = current_features[column].fillna("UNKNOWN").astype(str).str.strip().replace("", "UNKNOWN")

if current_features["customer_id"].duplicated().any():
    raise ValueError("CURRENT 피처에 중복 customer_id가 있습니다.")

del online_valid, orders, category_count, purchase_dates, customer
gc.collect()

print(f"[3/8] CURRENT 피처 생성: {len(current_features):,}명", flush=True)


train_log = train.copy()
valid_log = valid.copy()
current_log = current_features.copy()

for column in log_columns:
    for frame_name, frame in [("TRAIN", train_log), ("VALID", valid_log), ("CURRENT", current_log)]:
        values = pd.to_numeric(frame[column], errors="coerce")
        if (values.dropna() < 0).any():
            raise ValueError(f"{frame_name}.{column}에 음수가 있어 log1p를 적용할 수 없습니다.")
        frame[column] = np.log1p(values)

numeric_pipe = Pipeline([("imputer", SimpleImputer(strategy="median")), ("scaler", StandardScaler())])
categorical_pipe = Pipeline([("imputer", SimpleImputer(strategy="most_frequent")), ("onehot", make_onehot())])

preprocessor = ColumnTransformer([("numeric", numeric_pipe, numeric_features), ("categorical", categorical_pipe, categorical_features)])

X_train_log = preprocessor.fit_transform(train_log[feature_columns])
X_valid_log = preprocessor.transform(valid_log[feature_columns])
X_current_log = preprocessor.transform(current_log[feature_columns])

y_train = train_log["churn_flag"].astype(int)

log_model = GradientBoostingClassifier(n_estimators=40, learning_rate=0.03, max_depth=3, subsample=0.70, random_state=2026)
log_model.fit(X_train_log, y_train)

valid_log_probability = log_model.predict_proba(X_valid_log)[:, 1]
current_log_probability = log_model.predict_proba(X_current_log)[:, 1]

valid_eval["log_probability"] = valid_log_probability
print("[4/8] 로그변환 후보모델 학습 및 점수 생성 완료", flush=True)


train_customer_set = set(train["customer_id"])
unseen_mask = ~valid_eval["customer_id"].isin(train_customer_set)

model_compare_rows = []
for scope, mask in [("ALL_VALID", np.ones(len(valid_eval), dtype=bool)), ("UNSEEN_CUSTOMER_VALID", unseen_mask.to_numpy())]:
    actual_scope = valid_eval.loc[mask, "actual_churn_flag"].astype(int)
    model_compare_rows.append(metric_row(scope, "BASELINE_RAW_UNWEIGHTED", actual_scope, valid_eval.loc[mask, "baseline_probability"]))
    model_compare_rows.append(metric_row(scope, "LOG1P_CANDIDATE", actual_scope, valid_eval.loc[mask, "log_probability"]))

model_compare = pd.DataFrame(model_compare_rows)
print(f"[5/8] 성능 비교 완료: 신규 VALID={int(unseen_mask.sum()):,}명", flush=True)


valid_eval["baseline_risk_grade"] = valid_eval["baseline_risk_grade"].astype(str).str.strip().str.title()
valid_eval["log_risk_grade"] = relative_grade(valid_eval["log_probability"])
valid_eval["baseline_risk_priority_rank"] = descending_rank(valid_eval["baseline_probability"])
valid_eval["log_risk_priority_rank"] = descending_rank(valid_eval["log_probability"])
valid_eval["probability_difference"] = valid_eval["log_probability"] - valid_eval["baseline_probability"]
valid_eval["probability_abs_difference"] = valid_eval["probability_difference"].abs()
valid_eval["grade_changed"] = (valid_eval["baseline_risk_grade"] != valid_eval["log_risk_grade"]).astype(int)


current_candidate = current_features[["customer_id", "monetary"]].copy().rename(columns={"monetary": "recreated_monetary"})
current_candidate["log_probability"] = current_log_probability

current_baseline = current_action[["customer_id", "rfmp_tier", "relative_risk_grade", "final_churn_probability", "monetary", "revenue_at_risk_proxy", "risk_priority_rank", "value_at_risk_rank"]].rename(columns={
    "relative_risk_grade": "baseline_risk_grade", "final_churn_probability": "baseline_probability",
    "monetary": "baseline_monetary", "revenue_at_risk_proxy": "baseline_value_at_risk",
    "risk_priority_rank": "baseline_risk_priority_rank", "value_at_risk_rank": "baseline_value_at_risk_rank"
})

current_compare = current_candidate.merge(current_baseline, on="customer_id", how="left", validate="one_to_one")

current_compare["baseline_risk_grade"] = current_compare["baseline_risk_grade"].astype(str).str.strip().str.title()
current_compare["log_risk_grade"] = relative_grade(current_compare["log_probability"])
current_compare["log_risk_priority_rank"] = descending_rank(current_compare["log_probability"])
current_compare["log_value_at_risk"] = current_compare["log_probability"] * current_compare["baseline_monetary"]
current_compare["log_value_at_risk_rank"] = descending_rank(current_compare["log_value_at_risk"])
current_compare["probability_difference"] = current_compare["log_probability"] - current_compare["baseline_probability"]
current_compare["probability_abs_difference"] = current_compare["probability_difference"].abs()
current_compare["grade_changed"] = (current_compare["baseline_risk_grade"] != current_compare["log_risk_grade"]).astype(int)
current_compare["risk_rank_change"] = current_compare["log_risk_priority_rank"] - current_compare["baseline_risk_priority_rank"]
current_compare["risk_rank_abs_change"] = current_compare["risk_rank_change"].abs()
current_compare["value_rank_change"] = current_compare["log_value_at_risk_rank"] - current_compare["baseline_value_at_risk_rank"]
current_compare["value_rank_abs_change"] = current_compare["value_rank_change"].abs()


current_score_small = current_score[["customer_id", "final_churn_probability", "score_version", "monetary"]].rename(columns={"final_churn_probability": "score_table_probability", "monetary": "score_table_monetary"})
current_alignment = current_compare[["customer_id", "baseline_probability", "baseline_monetary"]].merge(current_score_small, on="customer_id", how="left", validate="one_to_one")

current_probability_alignment = float(np.nanmax(np.abs(current_alignment["baseline_probability"] - current_alignment["score_table_probability"])))
current_monetary_alignment = float(np.nanmax(np.abs(current_compare["baseline_monetary"] - current_compare["recreated_monetary"])))


stability_summary = pd.DataFrame([
    stability_row("VALID", valid_eval["snapshot_key"], valid_eval["baseline_probability"], valid_eval["log_probability"], valid_eval["baseline_risk_grade"], valid_eval["log_risk_grade"], valid_eval["baseline_risk_priority_rank"], valid_eval["log_risk_priority_rank"]),
    stability_row("CURRENT", current_compare["customer_id"], current_compare["baseline_probability"], current_compare["log_probability"], current_compare["baseline_risk_grade"], current_compare["log_risk_grade"], current_compare["baseline_risk_priority_rank"], current_compare["log_risk_priority_rank"], current_compare["baseline_value_at_risk_rank"], current_compare["log_value_at_risk_rank"])
])

grade_transition = pd.DataFrame(transition_rows("VALID", valid_eval["baseline_risk_grade"], valid_eval["log_risk_grade"]) + transition_rows("CURRENT", current_compare["baseline_risk_grade"], current_compare["log_risk_grade"]))

print("[6/8] 상대위험등급·두 우선순위 안정성 계산 완료", flush=True)


all_baseline = model_compare.loc[(model_compare["evaluation_scope"].eq("ALL_VALID") & model_compare["model_variant"].eq("BASELINE_RAW_UNWEIGHTED"))].iloc[0]
all_candidate = model_compare.loc[(model_compare["evaluation_scope"].eq("ALL_VALID") & model_compare["model_variant"].eq("LOG1P_CANDIDATE"))].iloc[0]
unseen_baseline = model_compare.loc[(model_compare["evaluation_scope"].eq("UNSEEN_CUSTOMER_VALID") & model_compare["model_variant"].eq("BASELINE_RAW_UNWEIGHTED"))].iloc[0]
unseen_candidate = model_compare.loc[(model_compare["evaluation_scope"].eq("UNSEEN_CUSTOMER_VALID") & model_compare["model_variant"].eq("LOG1P_CANDIDATE"))].iloc[0]

brier_gain = float(all_baseline["brier_score"] - all_candidate["brier_score"])
logloss_gain = float(all_baseline["log_loss"] - all_candidate["log_loss"])
auc_change = float(all_candidate["roc_auc"] - all_baseline["roc_auc"])
pr_auc_change = float(all_candidate["pr_auc"] - all_baseline["pr_auc"])
unseen_brier_change = float(unseen_candidate["brier_score"] - unseen_baseline["brier_score"])

unseen_evaluable = int(unseen_baseline["class_count"] >= 2 and unseen_candidate["class_count"] >= 2)

practical_rule_pass = int(len(log_columns) > 0 and brier_gain >= min_brier_gain and logloss_gain > 0 and auc_change >= -max_auc_loss and unseen_evaluable == 1 and unseen_brier_change <= max_unseen_brier_loss)

current_stability = stability_summary.loc[stability_summary["dataset_role"].eq("CURRENT")].iloc[0]

reason_parts = []
if brier_gain < min_brier_gain: reason_parts.append("전체 VALID Brier 개선이 0.01 미만")
if logloss_gain <= 0: reason_parts.append("전체 VALID Log Loss가 개선되지 않음")
if auc_change < -max_auc_loss: reason_parts.append("ROC-AUC 하락이 허용범위를 초과")
if unseen_evaluable == 0: reason_parts.append("신규 VALID에 두 이탈 클래스가 없어 평가 불가")
elif unseen_brier_change > max_unseen_brier_loss: reason_parts.append("신규 VALID Brier Score가 허용범위보다 악화")

if practical_rule_pass == 1:
    final_decision = "LOG_MODEL_REVIEW"
    conclusion_text = "로그변환 모델이 확률 오차를 실질적으로 줄였으며 신규 고객에서도 성능이 유지되므로 모델 변경을 팀 검토 대상으로 올린다."
    decision_reason = "Brier·Log Loss·ROC-AUC 기준과 신규 고객 성능 비악화 기준을 모두 충족함"
    rerun_42_required = "TEAM_DECISION"
else:
    final_decision = "KEEP_BASELINE"
    conclusion_text = "로그변환으로 인한 성능 개선이 미미하고 위험등급·우선순위가 대체로 유지되므로 기존 기준모델과 4.2 결과를 유지한다."
    decision_reason = "; ".join(reason_parts)
    if decision_reason == "": decision_reason = "실무 검토 기준 전체를 동시에 충족하지 못함"
    rerun_42_required = "NO"

# 변수명 32자 이하 단축 수정 (current_top100_val_overlap_rate)
decision_check = pd.DataFrame([{
    "final_decision": final_decision,
    "conclusion_text": conclusion_text,
    "decision_reason": decision_reason,
    "rerun_42_required": rerun_42_required,
    "log_variable_count": int(len(log_columns)),
    "brier_improvement": brier_gain,
    "logloss_improvement": logloss_gain,
    "roc_auc_change": auc_change,
    "pr_auc_change": pr_auc_change,
    "unseen_brier_change": unseen_brier_change,
    "current_grade_match_rate": float(current_stability["grade_match_rate"]),
    "current_risk_rank_correlation": float(current_stability["risk_rank_correlation"]),
    "current_value_rank_correlation": float(current_stability["value_rank_correlation"]),
    "current_top100_val_overlap_rate": float(current_stability["top100_val_overlap_rate"]),
    "minimum_brier_gain": min_brier_gain,
    "maximum_auc_loss": max_auc_loss,
    "maximum_unseen_brier_loss": max_unseen_brier_loss,
    "practical_rule_pass": practical_rule_pass
}])

print(f"[7/8] 최종 판단: {final_decision}", flush=True)


score_version_mismatch = int(valid_score["score_version"].astype(str).str.strip().str.upper().ne(expected_score_version).sum() + current_score["score_version"].astype(str).str.strip().str.upper().ne(expected_score_version).sum())
baseline_auc_difference = abs(float(all_baseline["roc_auc"]) - float(SAS.symget("EXPECTED_BASELINE_AUC")))
baseline_pr_difference = abs(float(all_baseline["pr_auc"]) - float(SAS.symget("EXPECTED_BASELINE_PR_AUC")))
baseline_brier_difference = abs(float(all_baseline["brier_score"]) - float(SAS.symget("EXPECTED_BASELINE_BRIER")))
baseline_logloss_difference = abs(float(all_baseline["log_loss"]) - float(SAS.symget("EXPECTED_BASELINE_LOGLOSS")))
metric_tolerance = float(SAS.symget("METRIC_TOLERANCE"))
train_valid_overlap = len(set(train["customer_id"]).intersection(set(valid["customer_id"])))

qa_rows = []
def add_qa(item, actual, expected, status, detail):
    qa_rows.append({"check_item": item, "actual_value": actual, "expected_value": expected, "status": status, "detail": detail})

add_qa("TRAIN row count", len(train), int(SAS.symget("EXPECTED_TRAIN_N")), "PASS" if len(train) == int(SAS.symget("EXPECTED_TRAIN_N")) else "REVIEW", "4.1과 같은 TRAIN 모집단인지 확인")
add_qa("VALID row count", len(valid), int(SAS.symget("EXPECTED_VALID_N")), "PASS" if len(valid) == int(SAS.symget("EXPECTED_VALID_N")) else "REVIEW", "4.1과 같은 VALID 모집단인지 확인")
add_qa("CURRENT row count", len(current_compare), int(SAS.symget("EXPECTED_CURRENT_N")), "PASS" if len(current_compare) == int(SAS.symget("EXPECTED_CURRENT_N")) else "FAIL", "4.2의 1,468명 모집단 보존")
add_qa("Score version mismatch", score_version_mismatch, 0, "PASS" if score_version_mismatch == 0 else "FAIL", "기준점수가 W4_1_V3_REVISED인지 확인")
add_qa("4.2 QA FAIL count", fail_count_42, 0, "PASS" if fail_count_42 == 0 else "FAIL", "4.2 품질검사에 FAIL이 없어야 함")
add_qa("VALID label mismatch", label_mismatch, 0, "PASS" if label_mismatch == 0 else "FAIL", "분할 데이터와 기준점수의 실제 라벨 비교")
add_qa("VALID probability alignment", valid_probability_alignment, 0, "PASS" if valid_probability_alignment < 1e-12 else "FAIL", "4.1 점수와 4.2 VALID 점수 비교")
add_qa("CURRENT probability alignment", current_probability_alignment, 0, "PASS" if current_probability_alignment < 1e-12 else "FAIL", "4.1 CURRENT와 4.2 액션 테이블 확률 비교")
add_qa("CURRENT monetary alignment", current_monetary_alignment, 0, "PASS" if current_monetary_alignment < 1e-6 else "REVIEW", "재생성 피처와 4.2 Monetary 비교")
add_qa("VALID candidate missing probability", int(valid_eval["log_probability"].isna().sum()), 0, "PASS" if valid_eval["log_probability"].notna().all() else "FAIL", "로그후보 VALID 확률 결측 확인")
add_qa("CURRENT candidate missing probability", int(current_compare["log_probability"].isna().sum()), 0, "PASS" if current_compare["log_probability"].notna().all() else "FAIL", "로그후보 CURRENT 확률 결측 확인")

valid_probability_in_range = int(valid_eval["log_probability"].between(0, 1).all())
current_probability_in_range = int(current_compare["log_probability"].between(0, 1).all())

add_qa("VALID candidate probability range", valid_probability_in_range, 1, "PASS" if valid_probability_in_range == 1 else "FAIL", "로그후보 VALID 확률이 0과 1 사이인지 확인")
add_qa("CURRENT candidate probability range", current_probability_in_range, 1, "PASS" if current_probability_in_range == 1 else "FAIL", "로그후보 CURRENT 확률이 0과 1 사이인지 확인")
add_qa("Log rule row count", len(log_rule), len(log_candidates), "PASS" if len(log_rule) == len(log_candidates) else "FAIL", "로그변환 후보 8개가 모두 기록되어야 함")
add_qa("VALID relative grade count", valid_eval["log_risk_grade"].nunique(), 3, "PASS" if valid_eval["log_risk_grade"].nunique() == 3 else "FAIL", "로그후보 VALID에 Low Medium High가 모두 존재해야 함")
add_qa("CURRENT relative grade count", current_compare["log_risk_grade"].nunique(), 3, "PASS" if current_compare["log_risk_grade"].nunique() == 3 else "FAIL", "로그후보 CURRENT에 Low Medium High가 모두 존재해야 함")

minimum_candidate_risk_rank = float(current_compare["log_risk_priority_rank"].min())
minimum_candidate_value_rank = float(current_compare["log_value_at_risk_rank"].min())

add_qa("Candidate risk priority starts at 1", minimum_candidate_risk_rank, 1, "PASS" if minimum_candidate_risk_rank == 1 else "FAIL", "로그후보 위험 우선순위 시작값 확인")
add_qa("Candidate value priority starts at 1", minimum_candidate_value_rank, 1, "PASS" if minimum_candidate_value_rank == 1 else "FAIL", "로그후보 가치위험 우선순위 시작값 확인")
add_qa("Baseline ROC-AUC reproduced", baseline_auc_difference, metric_tolerance, "PASS" if baseline_auc_difference <= metric_tolerance else "REVIEW", "4.1 기준 ROC-AUC와 허용오차 내 일치 확인")
add_qa("Baseline PR-AUC reproduced", baseline_pr_difference, metric_tolerance, "PASS" if baseline_pr_difference <= metric_tolerance else "REVIEW", "4.1 기준 PR-AUC와 허용오차 내 일치 확인")
add_qa("Baseline Brier reproduced", baseline_brier_difference, metric_tolerance, "PASS" if baseline_brier_difference <= metric_tolerance else "REVIEW", "4.1 기준 Brier Score와 허용오차 내 일치 확인")
add_qa("Baseline LogLoss reproduced", baseline_logloss_difference, metric_tolerance, "PASS" if baseline_logloss_difference <= metric_tolerance else "REVIEW", "4.1 기준 Log Loss와 허용오차 내 일치 확인")
add_qa("TRAIN VALID customer overlap", train_valid_overlap, 0, "INFO" if train_valid_overlap > 0 else "PASS", "시간 스냅샷 중복이며 신규 고객 VALID를 별도 평가함")
add_qa("Unseen VALID customer count", int(unseen_mask.sum()), len(valid) - train_valid_overlap, "INFO", "TRAIN에 없었던 신규 VALID 고객 수")
add_qa("Final decision created", int(final_decision in ["KEEP_BASELINE", "LOG_MODEL_REVIEW"]), 1, "PASS" if final_decision in ["KEEP_BASELINE", "LOG_MODEL_REVIEW"] else "FAIL", "두 최종 결론 중 하나가 생성되어야 함")

qa_summary = pd.DataFrame(qa_rows)

customer_compare_output = current_compare[[
    "customer_id", "rfmp_tier", "baseline_monetary", "baseline_probability", "log_probability",
    "probability_difference", "probability_abs_difference", "baseline_risk_grade", "log_risk_grade",
    "grade_changed", "baseline_risk_priority_rank", "log_risk_priority_rank", "risk_rank_change",
    "risk_rank_abs_change", "baseline_value_at_risk", "log_value_at_risk", "baseline_value_at_risk_rank",
    "log_value_at_risk_rank", "value_rank_change", "value_rank_abs_change"
]].copy()

save_sas(log_rule, "w4_43_log_rule")
save_sas(model_compare, "w4_43_model_compare")
save_sas(stability_summary, "w4_43_stability_summary")
save_sas(grade_transition, "w4_43_grade_transition")
save_sas(customer_compare_output, "w4_43_customer_compare")
save_sas(decision_check, "w4_43_decision_check")
save_sas(qa_summary, "w4_43_qa_summary")

print("[8/8] WBS 4.3 산출 테이블 7개 저장 완료", flush=True)

del X_train_log, X_valid_log, X_current_log, log_model, preprocessor
gc.collect()

endsubmit;
quit;


/*====================================================================
  2. 산출물 생성 확인
====================================================================*/

%macro verify_outputs;
    %local missing_count;
    %let missing_count=0;

    %if %sysfunc(exist(crm.w4_43_log_rule))=0 %then %let missing_count=%eval(&missing_count.+1);
    %if %sysfunc(exist(crm.w4_43_model_compare))=0 %then %let missing_count=%eval(&missing_count.+1);
    %if %sysfunc(exist(crm.w4_43_stability_summary))=0 %then %let missing_count=%eval(&missing_count.+1);
    %if %sysfunc(exist(crm.w4_43_grade_transition))=0 %then %let missing_count=%eval(&missing_count.+1);
    %if %sysfunc(exist(crm.w4_43_customer_compare))=0 %then %let missing_count=%eval(&missing_count.+1);
    %if %sysfunc(exist(crm.w4_43_decision_check))=0 %then %let missing_count=%eval(&missing_count.+1);
    %if %sysfunc(exist(crm.w4_43_qa_summary))=0 %then %let missing_count=%eval(&missing_count.+1);

    %if &missing_count. > 0 %then %do;
        %put ERROR: WBS 4.3 산출물 &missing_count.개가 생성되지 않았습니다.;
        %abort cancel;
    %end;

    %put NOTE: WBS 4.3 산출물 7개를 확인했습니다.;
%mend;

%verify_outputs;


/*====================================================================
  3. 핵심 결과 출력
====================================================================*/

title "WBS 4.3 로그변환 적용 규칙";
proc print data=crm.w4_43_log_rule noobs label;
    format train_skewness train_minimum 12.4;
run;
title;


title "WBS 4.3 전체·신규 VALID 모델 성능 비교";
proc print data=crm.w4_43_model_compare noobs label;
    var evaluation_scope model_variant customer_count class_count actual_churn_rate mean_probability probability_gap roc_auc pr_auc brier_score log_loss;
    format actual_churn_rate mean_probability probability_gap percent8.2 roc_auc pr_auc brier_score log_loss 10.4;
run;
title;


title "WBS 4.3 확률·상대위험등급·우선순위 안정성";
proc print data=crm.w4_43_stability_summary noobs label;
    var dataset_role customer_count mean_probability_abs_diff max_probability_abs_diff risk_rank_correlation grade_match_rate baseline_high_count candidate_high_count high_overlap_count high_retention_rate high_jaccard value_rank_correlation top100_value_overlap_count top100_val_overlap_rate;
    format mean_probability_abs_diff max_probability_abs_diff grade_match_rate high_retention_rate high_jaccard top100_val_overlap_rate percent8.2 risk_rank_correlation value_rank_correlation 10.4;
run;
title;


title "WBS 4.3 상대위험등급 이동표";
proc print data=crm.w4_43_grade_transition noobs label;
    format row_share percent8.2;
run;
title;


proc sort data=crm.w4_43_customer_compare out=work.w4_43_risk_movers;
    by descending risk_rank_abs_change;
run;

title "WBS 4.3 위험 우선순위 변동 상위 20명";
proc print data=work.w4_43_risk_movers(obs=20) noobs label;
    var customer_id rfmp_tier baseline_probability log_probability baseline_risk_grade log_risk_grade baseline_risk_priority_rank log_risk_priority_rank risk_rank_change;
    format baseline_probability log_probability percent8.2;
run;
title;


proc sort data=crm.w4_43_customer_compare out=work.w4_43_value_movers;
    by descending value_rank_abs_change;
run;

title "WBS 4.3 가치위험 우선순위 변동 상위 20명";
proc print data=work.w4_43_value_movers(obs=20) noobs label;
    var customer_id rfmp_tier baseline_monetary baseline_probability log_probability baseline_value_at_risk log_value_at_risk baseline_value_at_risk_rank log_value_at_risk_rank value_rank_change;
    format baseline_probability log_probability percent8.2 baseline_monetary baseline_value_at_risk log_value_at_risk comma14.2;
run;
title;


title "WBS 4.3 최종 판단 및 판단 근거";
proc print data=crm.w4_43_decision_check noobs label;
    var final_decision conclusion_text decision_reason rerun_42_required log_variable_count brier_improvement logloss_improvement roc_auc_change pr_auc_change unseen_brier_change current_grade_match_rate current_risk_rank_correlation current_value_rank_correlation current_top100_val_overlap_rate practical_rule_pass;
    format brier_improvement logloss_improvement roc_auc_change pr_auc_change unseen_brier_change current_risk_rank_correlation current_value_rank_correlation 10.4 current_grade_match_rate current_top100_val_overlap_rate percent8.2;
run;
title;


title "WBS 4.3 최종 품질 점검";
proc print data=crm.w4_43_qa_summary noobs label;
run;
title;


data _null_;
    set crm.w4_43_decision_check;
    put "NOTE: ========================================================";
    put "NOTE: WBS 4.3 FINAL DECISION = " final_decision;
    put "NOTE: 결론 = " conclusion_text;
    put "NOTE: 사유 = " decision_reason;
    put "NOTE: 4.2 재실행 필요 = " rerun_42_required;
    put "NOTE: ========================================================";
run;

%put NOTE: WBS 4.3 Revised 전체 작업이 완료되었습니다.;
%put NOTE: 이 코드는 4.1과 4.2의 기존 산출물을 변경하지 않았습니다.;
