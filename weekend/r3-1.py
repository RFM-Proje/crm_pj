"""r3-1.sas -> Python 변환본 (WBS 3.1 ~ 3.9)

  3.1-A  RFM 원본·로그 변환·표준화 데이터 준비          -> crm.w3_model_input 외 2
  3.2    이탈예측 피처(TRAIN 2019-06-30 / VALID 2019-10-02 스냅샷, 90일 이탈 라벨)
  3.1-B  RFM 군집 수(K=2~8) 참고 비교                  -> crm.w3_k_eval
  3.2-A  Frequency 정의 비교용 피처(주문 수 vs 구매일 수) -> crm.w3_freq_abc_input
  3.3    Gradient Boosting 이탈예측 검증                -> crm.w3_churn_*_v2
  3.3-A  Frequency A·B·C 로지스틱 비교                 -> crm.w3_freq_abc_*
  3.4    Frequency 공식 후보(B_DAYS) 확정 게이트        -> crm.w3_frequency_policy 외
  3.5~3.9 구매일 수 기준 RFM-P 재산출, 6개 고객등급     -> crm.w3_customer_rfmp_py 외

변환 원칙
  - SAS 안의 PROC PYTHON 블록은 원문 코드를 그대로 두고, SAS 객체만 rcommon.SASBridge 로
    바꿔 연결한다 (sd2df/df2sd -> crm_db/*.pkl, symget -> %let 값, pyplot -> rplots/*.png).
  - SAS 의 DATA step / PROC SQL / 매크로 구간은 pandas 로 옮겼다. %abort cancel 게이트는
    SystemExit 로 동일하게 실행을 멈춘다.
  - 원본 SAS 에 똑같이 두 번 들어 있는 구간은 한 번만 실행한다.
      * 3.3 Gradient Boosting 섹션: 두 섹션이 글자 하나까지 동일 -> 한 번 실행
      * 3.1-B: 초기판(crm.w3_k_eval 직접 저장) 뒤에 수정판(WORK 검증 후 저장)이 다시 덮어씀
        -> 최종 결과를 만드는 수정판만 실행
  - SAS 의 WORK 라이브러리는 SAS.work 딕셔너리(메모리)로 대응한다.

경로 (SAS -> VSCode)
  libname crm "/home/student/crm_db" -> crm_pj/weekend/crm_db (*.pkl)

실행 순서: r1-1.py -> r2-2.py -> r3-1.py -> r4-1.py -> r5_viz.py
"""

import datetime as _dt

import numpy as np
import pandas as pd

import rcommon as rc
from rcommon import (SASBridge, abort, delete, exists, load, nobs, proc_contents, proc_freq,
                     proc_freq_cross, proc_means, proc_print, require_table, save)

# %let P_METHOD=DAYS;  (HAS_OLD_RFMP 는 3.5 직전에 계산)
SAS = SASBridge(macros={"P_METHOD": "DAYS", "HAS_OLD_RFMP": "0"}, plot_prefix="r31_pyplot")
WORK = SAS.work


def sas_date(text):
    return pd.Timestamp(text)


# ======================================================================
# 3.1-A. RFM 원본·로그 변환·표준화 데이터 준비
# ======================================================================

require_table("w2_customer_features", "2-3")
delete("w3_model_input", "w3_rfm_profile", "w3_scaler_stats")
proc_contents(load("w2_customer_features"), "3.1-A 입력 테이블 구조 확인")

# ---- 4. PROC PYTHON (원문) ------------------------------------------------
# [r3-1.sas 98~698행 원문]

import pandas as pd
import numpy as np
import matplotlib.pyplot as plt

from sklearn.preprocessing import StandardScaler


# ---------------------------------------------------------
# 4-1. SAS 테이블을 Pandas DataFrame으로 가져오기
# ---------------------------------------------------------

source = SAS.sd2df(
    "crm.w2_customer_features"
)

# 변수명의 앞뒤 공백을 없애고 소문자로 통일합니다.
source.columns = [
    str(column).strip().lower()
    for column in source.columns
]

print("=" * 70)
print("3.1-A. RFM 원본·로그 변환·표준화 데이터 준비")
print("=" * 70)

print(f"입력 데이터 행 개수: {len(source):,}")
print(f"입력 데이터 열 개수: {len(source.columns):,}")

print("\n[입력 변수 목록]")
print(source.columns.tolist())


# ---------------------------------------------------------
# 4-2. 필수 변수 존재 여부 확인
# ---------------------------------------------------------

required_cols = [
    "customer_id",
    "recency",
    "frequency",
    "monetary"
]

missing_cols = [
    column
    for column in required_cols
    if column not in source.columns
]

if missing_cols:

    raise ValueError(
        "다음 필수 변수가 없습니다: "
        + ", ".join(missing_cols)
    )


# 소문자로 변경한 뒤 중복된 변수명이 생겼는지 확인합니다.
duplicated_col_count = int(
    source.columns.duplicated().sum()
)

if duplicated_col_count > 0:

    raise ValueError(
        f"중복된 변수명이 "
        f"{duplicated_col_count}개 발견되었습니다."
    )


# ---------------------------------------------------------
# 4-3. 고객ID와 RFM 변수만 선택
# ---------------------------------------------------------

model = source[required_cols].copy()

rfm_cols = [
    "recency",
    "frequency",
    "monetary"
]


# ---------------------------------------------------------
# 4-4. 고객ID 검증
# ---------------------------------------------------------

missing_id_count = int(
    model["customer_id"].isna().sum()
)

blank_id_count = int(
    model["customer_id"]
    .fillna("")
    .astype(str)
    .str.strip()
    .eq("")
    .sum()
)

# 고객ID를 문자형으로 변환하고 공백을 제거합니다.
model["customer_id"] = (
    model["customer_id"]
    .astype(str)
    .str.strip()
)

duplicate_id_count = int(
    model.duplicated(
        subset=["customer_id"],
        keep=False
    ).sum()
)


# ---------------------------------------------------------
# 4-5. RFM을 숫자형으로 변환
# ---------------------------------------------------------

for column in rfm_cols:

    model[column] = pd.to_numeric(
        model[column],
        errors="coerce"
    )


# ---------------------------------------------------------
# 4-6. 결측값과 비정상 값 확인
# ---------------------------------------------------------

missing_rfm_count = int(
    model[rfm_cols]
    .isna()
    .any(axis=1)
    .sum()
)

nonfinite_rfm_count = int(
    (
        ~np.isfinite(
            model[rfm_cols].to_numpy(dtype=float)
        )
    )
    .any(axis=1)
    .sum()
)

negative_recency_count = int(
    (model["recency"] < 0).sum()
)

nonpositive_frequency_count = int(
    (model["frequency"] <= 0).sum()
)

negative_monetary_count = int(
    (model["monetary"] < 0).sum()
)

constant_rfm_cols = [
    column
    for column in rfm_cols
    if model[column].nunique(dropna=True) <= 1
]


print("\n[RFM 입력 데이터 검증]")

print(f"고객ID 결측 행: {missing_id_count:,}")
print(f"고객ID 공백 행: {blank_id_count:,}")
print(f"고객ID 중복 행: {duplicate_id_count:,}")
print(f"RFM 결측 행: {missing_rfm_count:,}")
print(f"RFM 비유한값 행: {nonfinite_rfm_count:,}")
print(f"Recency 음수 행: {negative_recency_count:,}")
print(f"Frequency 0 이하 행: {nonpositive_frequency_count:,}")
print(f"Monetary 음수 행: {negative_monetary_count:,}")
print(f"값이 하나뿐인 RFM 변수: {constant_rfm_cols}")


# 문제가 발견되면 임의로 삭제하지 않고 실행을 중단합니다.
validation_errors = []

if missing_id_count > 0:
    validation_errors.append("고객ID 결측값 존재")

if blank_id_count > 0:
    validation_errors.append("고객ID 공백값 존재")

if duplicate_id_count > 0:
    validation_errors.append("고객ID 중복 존재")

if missing_rfm_count > 0:
    validation_errors.append("RFM 결측값 존재")

if nonfinite_rfm_count > 0:
    validation_errors.append("RFM NaN 또는 무한대 존재")

if negative_recency_count > 0:
    validation_errors.append("Recency 음수 존재")

if nonpositive_frequency_count > 0:
    validation_errors.append("Frequency 0 이하 존재")

if negative_monetary_count > 0:
    validation_errors.append("Monetary 음수 존재")

if constant_rfm_cols:

    validation_errors.append(
        "값이 하나뿐인 RFM 변수 존재: "
        + ", ".join(constant_rfm_cols)
    )

if validation_errors:

    raise ValueError(
        "RFM 입력 데이터 검증 실패: "
        + " / ".join(validation_errors)
    )


# ---------------------------------------------------------
# 4-7. Frequency와 Monetary 로그 변환
# ---------------------------------------------------------

# log1p(x)는 log(1+x)를 계산합니다.
# 큰 구매 횟수와 구매금액의 영향을 완화합니다.
model["log_frequency"] = np.log1p(
    model["frequency"]
)

model["log_monetary"] = np.log1p(
    model["monetary"]
)


# ---------------------------------------------------------
# 4-8. RAW 버전 표준화
# ---------------------------------------------------------

# 원본 RFM을 그대로 표준화합니다.
raw_input_cols = [
    "recency",
    "frequency",
    "monetary"
]

raw_scaler = StandardScaler()

raw_scaled = raw_scaler.fit_transform(
    model[raw_input_cols]
)

model[
    [
        "z_recency_raw",
        "z_frequency_raw",
        "z_monetary_raw"
    ]
] = raw_scaled


# ---------------------------------------------------------
# 4-9. LOG_FM 버전 표준화
# ---------------------------------------------------------

# Recency는 원본을 사용합니다.
# Frequency와 Monetary는 로그 변환값을 사용합니다.
logfm_input_cols = [
    "recency",
    "log_frequency",
    "log_monetary"
]

logfm_scaler = StandardScaler()

logfm_scaled = logfm_scaler.fit_transform(
    model[logfm_input_cols]
)

model[
    [
        "z_recency_logfm",
        "z_frequency_log",
        "z_monetary_log"
    ]
] = logfm_scaled


# ---------------------------------------------------------
# 4-10. 변환 후 결측값과 무한대 확인
# ---------------------------------------------------------

transformed_cols = [
    "log_frequency",
    "log_monetary",
    "z_recency_raw",
    "z_frequency_raw",
    "z_monetary_raw",
    "z_recency_logfm",
    "z_frequency_log",
    "z_monetary_log"
]

missing_after_transform = int(
    model[transformed_cols]
    .isna()
    .any(axis=1)
    .sum()
)

nonfinite_after_transform = int(
    (
        ~np.isfinite(
            model[
                transformed_cols
            ].to_numpy(dtype=float)
        )
    )
    .any(axis=1)
    .sum()
)

if missing_after_transform > 0:

    raise ValueError(
        f"변환 후 결측값이 있는 행이 "
        f"{missing_after_transform:,}개 발견되었습니다."
    )

if nonfinite_after_transform > 0:

    raise ValueError(
        f"변환 후 무한대 값이 있는 행이 "
        f"{nonfinite_after_transform:,}개 발견되었습니다."
    )


# ---------------------------------------------------------
# 4-11. RFM 프로파일링 표 생성
# ---------------------------------------------------------

profile_cols = [
    "recency",
    "frequency",
    "monetary",
    "log_frequency",
    "log_monetary"
]

profile_rows = []

for column in profile_cols:

    values = model[column]

    profile_rows.append(
        {
            "variable": column,
            "count": int(values.notna().sum()),
            "missing": int(values.isna().sum()),
            "mean": float(values.mean()),
            "std": float(values.std(ddof=1)),
            "minimum": float(values.min()),
            "p01": float(values.quantile(0.01)),
            "p25": float(values.quantile(0.25)),
            "median": float(values.median()),
            "p75": float(values.quantile(0.75)),
            "p99": float(values.quantile(0.99)),
            "maximum": float(values.max()),
            "skewness": float(values.skew())
        }
    )

rfm_profile = pd.DataFrame(
    profile_rows
)


# ---------------------------------------------------------
# 4-12. 표준화 기준값 표 생성
# ---------------------------------------------------------

scaler_rows = []

for index, column in enumerate(raw_input_cols):

    scaler_rows.append(
        {
            "model_version": "RAW",
            "input_variable": column,
            "center_mean": float(
                raw_scaler.mean_[index]
            ),
            "scale_std": float(
                raw_scaler.scale_[index]
            )
        }
    )

for index, column in enumerate(logfm_input_cols):

    scaler_rows.append(
        {
            "model_version": "LOG_FM",
            "input_variable": column,
            "center_mean": float(
                logfm_scaler.mean_[index]
            ),
            "scale_std": float(
                logfm_scaler.scale_[index]
            )
        }
    )

scaler_stats = pd.DataFrame(
    scaler_rows
)


# ---------------------------------------------------------
# 4-13. SAS 데이터셋으로 저장
#
# 중요:
# 현재 환경에서는 dataset=에 라이브러리와 테이블명을
# 함께 적어 CRM 라이브러리에 저장합니다.
# ---------------------------------------------------------

SAS.df2sd(
    model,
    dataset="crm.w3_model_input"
)

SAS.df2sd(
    rfm_profile,
    dataset="crm.w3_rfm_profile"
)

SAS.df2sd(
    scaler_stats,
    dataset="crm.w3_scaler_stats"
)


# ---------------------------------------------------------
# 4-14. Python 로그에 결과 출력
# ---------------------------------------------------------

print("\n[RFM 프로파일링 결과]")

print(
    rfm_profile
    .round(3)
    .to_string(index=False)
)

print("\n[표준화 기준값]")

print(
    scaler_stats
    .round(6)
    .to_string(index=False)
)

print("\n[표준화 데이터 앞 5행]")

print(
    model
    .head()
    .round(4)
    .to_string(index=False)
)

print("\n[3.1-A 최종 검증]")

print(f"최종 고객 수: {len(model):,}")

print(
    f"고유 고객 수: "
    f"{model['customer_id'].nunique():,}"
)

print(f"고객ID 중복 행: {duplicate_id_count:,}")

print(
    f"변환 후 결측 행: "
    f"{missing_after_transform:,}"
)

print(
    f"변환 후 비유한값 행: "
    f"{nonfinite_after_transform:,}"
)


# ---------------------------------------------------------
# 4-15. 원본과 변환 후 분포 시각화
# ---------------------------------------------------------

fig, axes = plt.subplots(
    2,
    3,
    figsize=(15, 8)
)


# 원본 Recency
axes[0, 0].hist(
    model["recency"],
    bins=30,
    color="steelblue",
    edgecolor="white"
)

axes[0, 0].set_title("Original Recency")
axes[0, 0].set_xlabel("Recency")
axes[0, 0].set_ylabel("Customers")


# 원본 Frequency
axes[0, 1].hist(
    model["frequency"],
    bins=30,
    color="darkorange",
    edgecolor="white"
)

axes[0, 1].set_title("Original Frequency")
axes[0, 1].set_xlabel("Frequency")
axes[0, 1].set_ylabel("Customers")


# 원본 Monetary
axes[0, 2].hist(
    model["monetary"],
    bins=30,
    color="seagreen",
    edgecolor="white"
)

axes[0, 2].set_title("Original Monetary")
axes[0, 2].set_xlabel("Monetary")
axes[0, 2].set_ylabel("Customers")


# 표준화 Recency
axes[1, 0].hist(
    model["z_recency_logfm"],
    bins=30,
    color="steelblue",
    edgecolor="white"
)

axes[1, 0].set_title("Standardized Recency")
axes[1, 0].set_xlabel("Z-score")
axes[1, 0].set_ylabel("Customers")


# 로그 변환 Frequency
axes[1, 1].hist(
    model["log_frequency"],
    bins=30,
    color="darkorange",
    edgecolor="white"
)

axes[1, 1].set_title("Log Frequency")
axes[1, 1].set_xlabel("log1p(Frequency)")
axes[1, 1].set_ylabel("Customers")


# 로그 변환 Monetary
axes[1, 2].hist(
    model["log_monetary"],
    bins=30,
    color="seagreen",
    edgecolor="white"
)

axes[1, 2].set_title("Log Monetary")
axes[1, 2].set_xlabel("log1p(Monetary)")
axes[1, 2].set_ylabel("Customers")


plt.suptitle(
    "RFM Distribution Before and After Transformation",
    fontsize=14
)

plt.tight_layout(
    rect=[0, 0, 1, 0.96]
)

SAS.pyplot(plt)

plt.close()

print("\n3.1-A 작업이 정상적으로 완료되었습니다.")
# ---- PROC PYTHON 끝 ------------------------------------------------------

# 5. Python 결과 테이블 생성 여부 확인
if not all(exists(t) for t in ("w3_model_input", "w3_rfm_profile", "w3_scaler_stats")):
    abort("3.1-A 결과 테이블이 정상적으로 생성되지 않았습니다.")
print("NOTE: 3.1-A 결과 테이블 3개가 모두 생성되었습니다.")

_mi = load("w3_model_input")
proc_contents(_mi, "3.1-A 군집분석 입력 테이블 구조", png="r31_01_contents_model_input")
proc_print(pd.DataFrame([{
    "total_customer_count": len(_mi),
    "unique_customer_count": _mi["customer_id"].nunique(),
    "rfm_missing_rows": int(_mi[["recency", "frequency", "monetary"]].isna().any(axis=1).sum()),
    "raw_missing_rows": int(_mi[["z_recency_raw", "z_frequency_raw", "z_monetary_raw"]]
                            .isna().any(axis=1).sum()),
    "logfm_missing_rows": int(_mi[["z_recency_logfm", "z_frequency_log", "z_monetary_log"]]
                              .isna().any(axis=1).sum())}]),
    "3.1-A 데이터 품질 최종 확인", png="r31_02_quality")
proc_print(pd.DataFrame([{"duplicated_customer_ids":
                          int((_mi.groupby("customer_id").size() > 1).sum())}]),
           "고객ID 중복 검사 결과")
proc_means(_mi, ["recency", "frequency", "monetary", "log_frequency", "log_monetary"],
           ("n", "nmiss", "mean", "std", "min", "p1", "q1", "median", "q3", "p99", "max"),
           "원본 및 로그 변환 RFM 기술통계", maxdec=3, png="r31_03_means_rfm")
proc_means(_mi, ["z_recency_raw", "z_frequency_raw", "z_monetary_raw",
                 "z_recency_logfm", "z_frequency_log", "z_monetary_log"],
           ("n", "nmiss", "mean", "std", "min", "max"),
           "표준화 변수 평균과 표준편차 확인", maxdec=6, png="r31_04_means_z")
proc_print(load("w3_scaler_stats"), "표준화에 사용한 평균과 표준편차", dec=6,
           png="r31_05_scaler_stats")
proc_print(_mi, "3.1-A 최종 군집분석 입력 데이터 표본", obs=10, dec=4)


# ======================================================================
# WBS 3.2. 이탈예측 피처 확장 및 기준 검토
# ======================================================================

require_table("clean_online", "Week 1-5 정제")
require_table("clean_customer", "Week 1-5 정제")
delete("w3_churn_window_compare", "w3_churn_split_v2", "w3_churn_feature_profile",
       "w3_churn_qa_summary")
for _k in [k for k in WORK if k.startswith("w3_")]:
    del WORK[_k]

clean_online = load("clean_online")
clean_customer = load("clean_customer")

# 2. 모델링에 사용할 유효 거래 행 (고액·대량구매는 제외하지 않음)
_flags_ok = ((clean_online["flag_missing_core"] == 0) & (clean_online["flag_return"] == 0)
             & (clean_online["flag_zero_quantity"] == 0) & (clean_online["flag_invalid_price"] == 0)
             & (clean_online["flag_customer_unmatched"] == 0))
w3_valid_online = clean_online[_flags_ok].copy()
# upcase(compbl(strip(coupon_status)))
w3_valid_online["coupon_status_std"] = (w3_valid_online["coupon_status"].astype(str).str.strip()
                                        .str.replace(r"\s+", " ", regex=True).str.upper())
w3_valid_online["line_amount"] = w3_valid_online["avg_price"] * w3_valid_online["quantity"]
WORK["w3_valid_online"] = w3_valid_online

_d = w3_valid_online["transaction_date"]
proc_print(pd.DataFrame([{
    "first_date": _d.min(), "last_date": _d.max(),
    "observed_days": (_d.max() - _d.min()).days + 1,
    "valid_line_count": len(w3_valid_online),
    "customer_count": w3_valid_online["customer_id"].nunique(),
    "order_count": w3_valid_online["order_key"].nunique()}]),
    "WBS 3.2-1. 모델링용 거래기간 확인", png="r32_01_period")

# 3. 이탈 기준 30/60/90/120일 비교 (같은 기준일 2019-06-30)
WINDOW_CHECK_CUTOFF = sas_date("2019-06-30")


def compare_window(days):
    window_end = WINDOW_CHECK_CUTOFF + pd.Timedelta(days=days)
    base = w3_valid_online.loc[_d <= WINDOW_CHECK_CUTOFF, "customer_id"].drop_duplicates()
    active = w3_valid_online.loc[(_d > WINDOW_CHECK_CUTOFF) & (_d <= window_end),
                                 "customer_id"].drop_duplicates()
    churn = int((~base.isin(active)).sum())
    return {"window_days": days, "cutoff_date": WINDOW_CHECK_CUTOFF, "window_end": window_end,
            "total_customers": len(base), "churn_customers": churn,
            "churn_rate": churn / len(base)}


w3_churn_window_compare = pd.DataFrame([compare_window(d) for d in (30, 60, 90, 120)])
save(w3_churn_window_compare, "w3_churn_window_compare")
proc_print(w3_churn_window_compare, "WBS 3.2-2. 이탈 라벨 윈도우별 이탈률", dec=4,
           png="r32_02_window_compare")
# proc sgplot vbar window_days / response=churn_rate datalabel
rc.sas_bar_png(w3_churn_window_compare["window_days"], w3_churn_window_compare["churn_rate"],
               "30·60·90·120일 기준에 따른 이탈률 변화", "r32_03_window_churn_rate",
               xlabel="이탈 라벨 윈도우(일)", ylabel="이탈률")


# 4. 한 개 시점의 이탈예측 피처를 만드는 매크로 %build_churn_snapshot
def build_churn_snapshot(tag, role, cutoff, label_end):
    src = w3_valid_online
    feature = src[src["transaction_date"] <= cutoff]
    label = src[(src["transaction_date"] > cutoff) & (src["transaction_date"] <= label_end)]
    WORK[f"w3_{tag}_feature"], WORK[f"w3_{tag}_label"] = feature, label

    # 4-2. 상품 행 -> 주문 단위 (배송료는 주문당 한 번)
    orders = (feature.assign(_used=(feature["coupon_status_std"] == "USED").astype(int),
                             _clicked=feature["coupon_status_std"].isin(["USED", "CLICKED"]).astype(int))
              .groupby(["customer_id", "order_key", "transaction_date"], as_index=False)
              .agg(order_amount=("line_amount", "sum"), order_quantity=("quantity", "sum"),
                   order_shipping=("shipping_fee", "max"), order_coupon_used=("_used", "max"),
                   order_coupon_clicked=("_clicked", "max")))
    WORK[f"w3_{tag}_orders"] = orders

    # 4-3. 고객별 기본 구매행동 피처
    core = orders.groupby("customer_id", as_index=False).agg(
        first_purchase_date=("transaction_date", "min"),
        last_purchase_date=("transaction_date", "max"),
        frequency=("order_key", "size"),
        monetary=("order_amount", "sum"),
        avg_order_value=("order_amount", "mean"),
        avg_shipping=("order_shipping", "mean"),
        coupon_usage_rate=("order_coupon_used", "mean"),
        coupon_click_rate=("order_coupon_clicked", "mean"))
    core.insert(3, "recency", (cutoff - core["last_purchase_date"]).dt.days)
    core["observation_days"] = (cutoff - core["first_purchase_date"]).dt.days + 1
    WORK[f"w3_{tag}_core"] = core

    # 4-4. 이용카테고리수와 주이용카테고리 집중도
    cat_count = (feature.groupby(["customer_id", "product_category"])["order_key"].nunique()
                 .rename("category_order_count").reset_index())
    cat_feature = cat_count.groupby("customer_id").agg(
        product_category_count=("product_category", "size"),
        _max=("category_order_count", "max"), _sum=("category_order_count", "sum"))
    cat_feature["category_concentration"] = cat_feature["_max"] / cat_feature["_sum"]
    cat_feature = cat_feature[["product_category_count", "category_concentration"]].reset_index()

    # 4-5. 재구매 간격 (고유 구매일 기준, 0일 간격 제외)
    dates = (feature[["customer_id", "transaction_date"]].drop_duplicates()
             .sort_values(["customer_id", "transaction_date"]))
    gaps = dates.assign(gap_days=dates.groupby("customer_id")["transaction_date"].diff().dt.days)
    gaps = gaps[gaps["gap_days"] > 0]
    gap_feature = gaps.groupby("customer_id")["gap_days"].agg(
        avg_days_between_orders="mean", std_days_between_orders="std").reset_index()

    # 4-6. 마지막 구매일의 쿠폰 사용 여부 (하나라도 Used 면 1)
    last_coupon = (orders.merge(core[["customer_id", "last_purchase_date"]],
                                left_on=["customer_id", "transaction_date"],
                                right_on=["customer_id", "last_purchase_date"])
                   .groupby("customer_id")["order_coupon_used"].max()
                   .rename("last_coupon_used").reset_index())

    # 4-7. 라벨 구간 구매 여부로 이탈 라벨
    active = label[["customer_id"]].drop_duplicates().assign(_active=1)
    out = (core.merge(cat_feature, on="customer_id", how="left")
           .merge(gap_feature, on="customer_id", how="left")
           .merge(last_coupon, on="customer_id", how="left")
           .merge(clean_customer[["customer_id", "gender", "region", "tenure"]],
                  on="customer_id", how="left")
           .merge(active, on="customer_id", how="left"))
    for c in ("product_category_count", "category_concentration", "avg_days_between_orders",
              "std_days_between_orders", "last_coupon_used"):
        out[c] = out[c].fillna(0)
    out["churn_flag"] = out.pop("_active").isna().astype(int)
    out["split_role"] = role
    out["snapshot_cutoff"] = cutoff
    out["label_end_date"] = label_end

    # 4-8. 연환산 구매빈도와 CLV 대용지표 (관측기간 최소 30일)
    out["tenure"] = out["tenure"].fillna(0)
    out["annual_order_frequency"] = out["frequency"] / (out["observation_days"].clip(lower=30) / 365.25)
    out["clv_proxy"] = (out["avg_order_value"] * out["annual_order_frequency"]
                        * (out["tenure"].clip(lower=1) / 12))
    out["snapshot_key"] = out["customer_id"].astype(str) + "|" + role
    return out.sort_values("customer_id", ignore_index=True)


# 5. TRAIN(라벨 2019-07-01~09-28) / VALID(라벨 2019-10-03~12-31)
WORK["w3_train_snapshot"] = build_churn_snapshot("train", "TRAIN", sas_date("2019-06-30"),
                                                 sas_date("2019-09-28"))
WORK["w3_valid_snapshot"] = build_churn_snapshot("valid", "VALID", sas_date("2019-10-02"),
                                                 sas_date("2019-12-31"))
w3_churn_split_v2 = pd.concat([WORK["w3_train_snapshot"], WORK["w3_valid_snapshot"]],
                              ignore_index=True)
save(w3_churn_split_v2, "w3_churn_split_v2")

# 6. 피처 기술통계 (ods output Summary, stackodsoutput)
CHURN_NUM = ["recency", "frequency", "monetary", "avg_order_value", "avg_shipping",
             "coupon_usage_rate", "coupon_click_rate", "tenure", "product_category_count",
             "category_concentration", "avg_days_between_orders", "std_days_between_orders",
             "last_coupon_used", "clv_proxy"]
_rows = []
for _role, _g in w3_churn_split_v2.groupby("split_role"):
    for _v in CHURN_NUM:
        _s = _g[_v]
        _rows.append({"split_role": _role, "NObs": len(_g), "Variable": _v, "N": int(_s.count()),
                      "NMiss": int(_s.isna().sum()), "Mean": _s.mean(), "StdDev": _s.std(),
                      "Min": _s.min(), "P50": rc.pctl(_s, 50), "Max": _s.max()})
w3_churn_feature_profile = pd.DataFrame(_rows)
save(w3_churn_feature_profile, "w3_churn_feature_profile")
proc_print(w3_churn_feature_profile, "WBS 3.2 이탈예측 피처 기술통계 (역할별)", dec=3,
           png="r32_04_feature_profile")

w3_churn_qa_summary = (w3_churn_split_v2.groupby("split_role")
                       .apply(lambda g: pd.Series({
                           "row_count": len(g),
                           "customer_count": g["customer_id"].nunique(),
                           "missing_customer_id": int(g["customer_id"].isna().sum()),
                           "missing_churn_flag": int(g["churn_flag"].isna().sum()),
                           "future_feature_date_count":
                               int((g["last_purchase_date"] > g["snapshot_cutoff"]).sum()),
                           "churn_rate": g["churn_flag"].mean()}), include_groups=False)
                       .reset_index())
save(w3_churn_qa_summary, "w3_churn_qa_summary")
proc_print(w3_churn_qa_summary, "WBS 3.2-3. TRAIN·VALID 고객수와 이탈률", dec=4,
           png="r32_05_qa_summary")
proc_freq_cross(w3_churn_split_v2, "split_role", "churn_flag", "시간 분리 역할별 이탈 라벨 분포",
                png="r32_06_cross_role_churn")

_dup = w3_churn_split_v2.groupby(["split_role", "customer_id"]).size()
proc_print(pd.DataFrame([{"duplicated_snapshot_keys": int((_dup > 1).sum())}]),
           "WBS 3.2-4. 역할 내부 고객ID 중복 검사")

# 7. 최종 결과 확인
proc_contents(w3_churn_split_v2, "WBS 3.2 최종 학습·검증 테이블 구조",
              png="r32_07_contents_split")
proc_print(w3_churn_split_v2, "WBS 3.2 최종 데이터 앞 10행", obs=10, dec=3,
           var=["snapshot_key", "customer_id", "split_role", "snapshot_cutoff", "label_end_date",
                "recency", "frequency", "monetary", "product_category_count",
                "category_concentration", "avg_days_between_orders", "last_coupon_used",
                "clv_proxy", "churn_flag"])
if not all(exists(t) for t in ("w3_churn_window_compare", "w3_churn_split_v2",
                               "w3_churn_feature_profile", "w3_churn_qa_summary")):
    abort("WBS 3.2 결과 테이블 중 생성되지 않은 것이 있습니다.")
print("NOTE: WBS 3.2 결과 테이블 네 개가 모두 생성되었습니다.")


# ======================================================================
# 3.1-B. 기존 주문 수 기반 RFM 군집 수(K) 참고 비교 (수정판)
# ======================================================================

require_table("w3_model_input", "3.1-A")
WORK.pop("w3_k_eval_new", None)

# ---- 2. PROC PYTHON (원문) ------------------------------------------------
# [r3-1.sas 2106~2433행 원문]

import itertools
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

from sklearn.cluster import KMeans
from sklearn.metrics import (
    adjusted_rand_score,
    calinski_harabasz_score,
    davies_bouldin_score,
    silhouette_score
)


# ---------------------------------------------------------
# 2-1. 3.1-A 결과 불러오기
# ---------------------------------------------------------

df = SAS.sd2df("crm.w3_model_input")

df.columns = [
    str(column).strip().lower()
    for column in df.columns
]

print("=" * 72)
print("3.1-B. 기존 주문 수 기반 RFM 군집 수(K) 참고 비교")
print("=" * 72)
print(f"입력 고객 수: {len(df):,}")


# ---------------------------------------------------------
# 2-2. 평가할 두 가지 입력 버전
# ---------------------------------------------------------

feature_sets = {
    "RAW": [
        "z_recency_raw",
        "z_frequency_raw",
        "z_monetary_raw"
    ],
    "LOG_FM": [
        "z_recency_logfm",
        "z_frequency_log",
        "z_monetary_log"
    ]
}

required_cols = [
    column
    for columns in feature_sets.values()
    for column in columns
]

missing_cols = [
    column
    for column in required_cols
    if column not in df.columns
]

if missing_cols:
    raise ValueError(
        "3.1-B에 필요한 변수가 없습니다: "
        + ", ".join(sorted(set(missing_cols)))
    )


# 결측값이나 무한대가 있으면 임의로 제거하지 않고 중단합니다.
check_values = df[required_cols].to_numpy(dtype=float)

if not np.isfinite(check_values).all():
    raise ValueError(
        "군집 입력 변수에 결측값 또는 무한대가 있습니다. "
        "3.1-A 결과를 다시 확인하십시오."
    )


# ---------------------------------------------------------
# 2-3. 군집 품질과 반복 실행 안정성 평가
# ---------------------------------------------------------

rows = []
k_values = list(range(2, 9))
stability_seeds = list(range(10))

for model_version, columns in feature_sets.items():

    X = df[columns].to_numpy(dtype=float)
    previous_inertia = None

    for k in k_values:

        final_model = KMeans(
            n_clusters=k,
            random_state=2026,
            n_init=30
        )

        labels = final_model.fit_predict(X)
        counts = pd.Series(labels).value_counts()

        # 서로 다른 초기값으로 반복했을 때 군집이 비슷한지 확인합니다.
        repeated_labels = []

        for seed in stability_seeds:
            repeated_model = KMeans(
                n_clusters=k,
                random_state=seed,
                n_init=10
            )
            repeated_labels.append(
                repeated_model.fit_predict(X)
            )

        ari_values = [
            adjusted_rand_score(left, right)
            for left, right in itertools.combinations(
                repeated_labels,
                2
            )
        ]

        if previous_inertia is None:
            inertia_drop_pct = np.nan
        else:
            inertia_drop_pct = (
                (previous_inertia - final_model.inertia_)
                / previous_inertia
                * 100
            )

        row = {
            "model_version": model_version,
            "k": int(k),
            "inertia": float(final_model.inertia_),
            "inertia_drop_pct": float(inertia_drop_pct),
            "silhouette": float(
                silhouette_score(X, labels)
            ),
            "calinski_harabasz": float(
                calinski_harabasz_score(X, labels)
            ),
            "davies_bouldin": float(
                davies_bouldin_score(X, labels)
            ),
            "min_cluster_n": int(counts.min()),
            "min_cluster_pct": float(
                counts.min() / len(df) * 100
            ),
            "stability_ari": float(np.mean(ari_values)),
            "initial_reference_candidate": int(
                model_version == "LOG_FM" and k == 4
            ),
            "analysis_scope": "INITIAL_ORDER_FREQUENCY",
            "decision_status": "REFERENCE_ONLY"
        }

        rows.append(row)
        previous_inertia = final_model.inertia_


k_eval = pd.DataFrame(rows)


# 각 입력 버전에서 지표별 최적 K를 표시한다.
# 하나의 지표만으로 공식 K를 자동 선택하지는 않는다.
k_eval["best_silhouette_flag"] = 0
k_eval["best_davies_flag"] = 0
k_eval["best_stability_flag"] = 0

for model_version in feature_sets:

    part = k_eval[
        k_eval["model_version"] == model_version
    ]

    k_eval.loc[
        part["silhouette"].idxmax(),
        "best_silhouette_flag"
    ] = 1

    k_eval.loc[
        part["davies_bouldin"].idxmin(),
        "best_davies_flag"
    ] = 1

    k_eval.loc[
        part["stability_ari"].idxmax(),
        "best_stability_flag"
    ] = 1


# ---------------------------------------------------------
# 2-4. 평가 결과 저장
# ---------------------------------------------------------

SAS.df2sd(
    k_eval,
    dataset="work.w3_k_eval_new"
)


# ---------------------------------------------------------
# 2-5. 로그에 비교표 출력
# ---------------------------------------------------------

print("\n[K 비교 결과]")
print(
    k_eval.round(4).to_string(index=False)
)

for model_version in feature_sets:

    part = k_eval[
        k_eval["model_version"] == model_version
    ]

    best_silhouette_k = int(
        part.loc[part["silhouette"].idxmax(), "k"]
    )

    best_davies_k = int(
        part.loc[part["davies_bouldin"].idxmin(), "k"]
    )

    print(
        f"\n{model_version}: "
        f"실루엣 최고 K={best_silhouette_k}, "
        f"Davies-Bouldin 최저 K={best_davies_k}"
    )

print("\n[해석 범위]")
print("LOG_FM·K=4는 기존 주문 수 Frequency를 사용한 초기 참고 후보입니다.")
print("이 결과는 공식 Frequency, 공식 RFMP 군집 수 또는 등급을 결정하지 않습니다.")
print("공식 RFMP는 3.5~3.9에서 frequency_days를 사용하여 다시 계산합니다.")


# ---------------------------------------------------------
# 2-6. Elbow와 군집 평가 지표 시각화
# ---------------------------------------------------------

fig, axes = plt.subplots(
    2,
    2,
    figsize=(12, 8)
)

for model_version, color in [
    ("RAW", "gray"),
    ("LOG_FM", "steelblue")
]:

    part = k_eval[
        k_eval["model_version"] == model_version
    ]

    axes[0, 0].plot(
        part["k"],
        part["inertia"],
        marker="o",
        label=model_version,
        color=color
    )

    axes[0, 1].plot(
        part["k"],
        part["silhouette"],
        marker="o",
        label=model_version,
        color=color
    )

    axes[1, 0].plot(
        part["k"],
        part["davies_bouldin"],
        marker="o",
        label=model_version,
        color=color
    )

    axes[1, 1].plot(
        part["k"],
        part["stability_ari"],
        marker="o",
        label=model_version,
        color=color
    )


axes[0, 0].set_title("Elbow: Inertia")
axes[0, 0].set_ylabel("Inertia")

axes[0, 1].set_title("Silhouette: Higher is Better")
axes[0, 1].set_ylabel("Silhouette")

axes[1, 0].set_title("Davies-Bouldin: Lower is Better")
axes[1, 0].set_ylabel("Davies-Bouldin")

axes[1, 1].set_title("Seed Stability: Higher is Better")
axes[1, 1].set_ylabel("Mean ARI")

for axis in axes.flat:
    axis.set_xlabel("K")
    # 빨간 점선은 공식 선택값이 아니라 초기 참고 위치이다.
    axis.axvline(
        4,
        color="red",
        linestyle="--",
        linewidth=1
    )
    axis.grid(alpha=0.25)
    axis.legend()

plt.suptitle(
    "Initial RFM K Reference: RAW vs LOG_FM",
    fontsize=14
)

plt.tight_layout(
    rect=[0, 0, 1, 0.96]
)

SAS.pyplot(plt)
plt.close()

print("\n3.1-B 참고 평가 계산이 완료되었습니다.")
# ---- PROC PYTHON 끝 ------------------------------------------------------

# 3. 임시 결과 검증 후 CRM 테이블 교체
_ke = WORK["w3_k_eval_new"]
K_EVAL_ROWS = len(_ke)
K_EVAL_KEYS = _ke[["model_version", "k"]].drop_duplicates().shape[0]
K_EVAL_MISSING = int(_ke[["model_version", "k", "inertia", "silhouette", "davies_bouldin",
                          "stability_ari", "min_cluster_n"]].isna().any(axis=1).sum())
if K_EVAL_ROWS != 14:
    abort("W3_K_EVAL 임시 결과의 행 수가 14개가 아닙니다.")
if K_EVAL_KEYS != 14:
    abort("model_version과 K 조합이 중복되었습니다.")
if K_EVAL_MISSING != 0:
    abort("핵심 군집 평가 지표에 결측값이 있습니다.")
save(_ke, "w3_k_eval")
print("NOTE: CRM.W3_K_EVAL을 검증 후 저장했습니다.")

proc_print(load("w3_k_eval"), "3.1-B. RFM 군집 수(K) 평가 결과", dec=4, png="r31b_01_k_eval")
proc_print(load("w3_k_eval").query("initial_reference_candidate == 1"),
           "3.1-B 초기 참고 후보: LOG_FM, K=4", dec=4)


# ======================================================================
# WBS 3.2-A. Frequency 정의 비교용 피처 생성
# ======================================================================

require_table("clean_online", "Week 1-5 정제")
require_table("w3_churn_split_v2", "WBS 3.2")
delete("w3_freq_abc_input", "w3_freq_abc_qa")
for _k in [k for k in WORK if k.startswith("fabc_")]:
    del WORK[_k]

# 2. 3.2와 같은 조건의 유효 거래 + 핵심값 확인
fabc_valid_lines = clean_online[_flags_ok & clean_online["customer_id"].notna()
                                & clean_online["order_key"].notna()
                                & clean_online["transaction_date"].notna()][
    ["customer_id", "order_key", "transaction_date"]]
WORK["fabc_valid_lines"] = fabc_valid_lines

# 3. 상품 행 -> 주문 단위 (select distinct)
fabc_orders = fabc_valid_lines.drop_duplicates()
WORK["fabc_orders"] = fabc_orders


# 4. 기준일별 Frequency (%build_frequency)
def build_frequency(role, cutoff):
    o = fabc_orders[fabc_orders["transaction_date"] <= cutoff]
    out = o.groupby("customer_id").agg(frequency_orders=("order_key", "size"),
                                       frequency_days=("transaction_date", "nunique")).reset_index()
    out.insert(1, "split_role", role)
    out["orders_per_purchase_day"] = (out["frequency_orders"] / out["frequency_days"]).where(
        out["frequency_days"] > 0)
    return out


WORK["fabc_train_frequency"] = build_frequency("TRAIN", sas_date("2019-06-30"))
WORK["fabc_valid_frequency"] = build_frequency("VALID", sas_date("2019-10-02"))
fabc_frequency = pd.concat([WORK["fabc_train_frequency"], WORK["fabc_valid_frequency"]],
                           ignore_index=True)
WORK["fabc_frequency"] = fabc_frequency

# 5. TRAIN 에 없던 신규 VALID 고객
_split = load("w3_churn_split_v2")
fabc_train_customers = _split.loc[_split["split_role"].str.strip().str.upper() == "TRAIN",
                                  "customer_id"].drop_duplicates()
WORK["fabc_train_customers"] = fabc_train_customers.to_frame()

# 6. 3.2 피처에 Frequency 두 종류 결합
w3_freq_abc_input = _split.copy()
w3_freq_abc_input["frequency_original"] = w3_freq_abc_input["frequency"]
w3_freq_abc_input = w3_freq_abc_input.merge(
    fabc_frequency.assign(split_role=fabc_frequency["split_role"].str.upper()),
    on=["customer_id", "split_role"], how="left")
w3_freq_abc_input["is_new_valid_customer"] = (
    (w3_freq_abc_input["split_role"].str.strip().str.upper() == "VALID")
    & ~w3_freq_abc_input["customer_id"].isin(fabc_train_customers)).astype(int)
save(w3_freq_abc_input, "w3_freq_abc_input")

# 7. 역할 내부 고객 중복
fabc_duplicate_customer = (w3_freq_abc_input.groupby(["split_role", "customer_id"]).size()
                           .loc[lambda s: s > 1])

# 8. QA 요약
fa = w3_freq_abc_input
w3_freq_abc_qa = (fa.groupby("split_role").apply(lambda g: pd.Series({
    "row_count": len(g),
    "customer_count": g["customer_id"].nunique(),
    "missing_frequency_orders": int(g["frequency_orders"].isna().sum()),
    "missing_frequency_days": int(g["frequency_days"].isna().sum()),
    "invalid_days_over_orders": int((g["frequency_days"] > g["frequency_orders"]).sum()),
    "original_frequency_mismatch": int((g["frequency_original"].notna() & g["frequency_orders"].notna()
                                        & (g["frequency_original"] != g["frequency_orders"])).sum()),
    "new_valid_customer_count": int(g["is_new_valid_customer"].sum()),
    "avg_frequency_orders": g["frequency_orders"].mean(),
    "avg_frequency_days": g["frequency_days"].mean(),
    "median_frequency_orders": g["frequency_orders"].median(),
    "median_frequency_days": g["frequency_days"].median(),
    "max_frequency_orders": g["frequency_orders"].max(),
    "max_frequency_days": g["frequency_days"].max()}), include_groups=False).reset_index())
save(w3_freq_abc_qa, "w3_freq_abc_qa")

# 9. QA 오류 건수
FABC_DUPLICATE_COUNT = len(fabc_duplicate_customer)
FABC_MISSING_ORDERS = int(fa["frequency_orders"].isna().sum())
FABC_MISSING_DAYS = int(fa["frequency_days"].isna().sum())
FABC_INVALID_RELATION = int((fa["frequency_days"] > fa["frequency_orders"]).sum())
FABC_OLD_MISMATCH = int(w3_freq_abc_qa["original_frequency_mismatch"].sum())

# 10. QA 결과 출력
proc_print(w3_freq_abc_qa, "WBS 3.2-A-1. Frequency 정의 비교 QA", dec=2, png="r32a_01_freq_qa")
for _role, _g in fa.groupby("split_role"):
    proc_means(_g, ["frequency_orders", "frequency_days", "orders_per_purchase_day"],
               ("n", "nmiss", "mean", "std", "min", "p25", "median", "p75", "p90", "p95", "p99", "max"),
               f"WBS 3.2-A-2. Frequency 분포 (split_role={_role})",
               png=f"r32a_02_freq_dist_{_role.lower()}")
proc_freq_cross(fa, "split_role", "is_new_valid_customer", "WBS 3.2-A-3. 신규 VALID 고객 수",
                png="r32a_03_cross_new_valid")
proc_print(fa[fa["customer_id"].str.strip().str.upper() == "USER_1358"],
           "WBS 3.2-A-4. USER_1358 Frequency 확인",
           var=["customer_id", "split_role", "snapshot_cutoff", "frequency_original",
                "frequency_orders", "frequency_days", "orders_per_purchase_day", "churn_flag"],
           png="r32a_04_user_1358")

# 11. 핵심 QA 판정
if FABC_DUPLICATE_COUNT > 0:
    abort("역할 내부에 중복 고객ID가 있습니다.")
if FABC_MISSING_ORDERS > 0:
    abort("frequency_orders에 결측값이 있습니다.")
if FABC_MISSING_DAYS > 0:
    abort("frequency_days에 결측값이 있습니다.")
if FABC_INVALID_RELATION > 0:
    abort("구매일 수가 주문 수보다 큰 고객이 있습니다.")
if FABC_OLD_MISMATCH > 0:
    abort("기존 frequency와 frequency_orders가 일치하지 않습니다.")
print("NOTE: Frequency 비교용 입력 테이블의 핵심 QA를 통과했습니다.")

# 12. 최종 테이블 확인
proc_contents(fa, "WBS 3.2-A 최종 입력 테이블 구조")
proc_print(fa, "WBS 3.2-A 최종 입력 데이터 앞 10행", obs=10,
           var=["snapshot_key", "customer_id", "split_role", "snapshot_cutoff", "churn_flag",
                "frequency_original", "frequency_orders", "frequency_days",
                "orders_per_purchase_day", "is_new_valid_customer"])


# ======================================================================
# WBS 3.3. 데이터 누수 방지 및 이탈예측 검증 (Gradient Boosting)
# ======================================================================

require_table("w3_churn_split_v2", "WBS 3.2")
delete("w3_churn_scored_v2", "w3_churn_metrics_v2", "w3_churn_importance_v2",
       "w3_churn_confusion_v2", "w3_churn_roc_valid", "w3_churn_model_config")

_s = load("w3_churn_split_v2")
proc_print(_s.groupby("split_role").agg(
    row_count=("customer_id", "size"),
    future_feature_date_count=("last_purchase_date",
                               lambda x: int((x > _s.loc[x.index, "snapshot_cutoff"]).sum())),
    snapshot_cutoff=("snapshot_cutoff", "min"),
    label_end_date=("label_end_date", "max")).reset_index(),
    "WBS 3.3-1. 피처에 미래 거래일이 포함되었는지 확인", png="r33_01_leak_check")

# ---- 2. PROC PYTHON (원문) ------------------------------------------------
# [r3-1.sas 3187~3689행 원문]

import warnings

import numpy as np
import pandas as pd

from sklearn.compose import ColumnTransformer
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.impute import SimpleImputer
from sklearn.inspection import permutation_importance
from sklearn.metrics import (
    accuracy_score,
    average_precision_score,
    balanced_accuracy_score,
    confusion_matrix,
    f1_score,
    precision_score,
    recall_score,
    roc_auc_score,
    roc_curve
)
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder
from sklearn.utils.class_weight import compute_sample_weight

warnings.filterwarnings("ignore")


# ---------------------------------------------------------
# 2-1. SAS 테이블 불러오기
# ---------------------------------------------------------

df = SAS.sd2df("crm.w3_churn_split_v2")

df.columns = [
    str(column).strip().lower()
    for column in df.columns
]


# ---------------------------------------------------------
# 2-2. 사용할 피처 정의
#
# 기본 수치형 8개
#   recency, frequency, monetary, avg_order_value,
#   avg_shipping, tenure   (쿠폰 변수 3개는 분석 범위에서 제외 - 팀 결정)
#
# 확장 수치형 5개
#   product_category_count, category_concentration,
#   avg_days_between_orders, std_days_between_orders, clv_proxy
# ---------------------------------------------------------

numeric_features = [
    "recency",
    "frequency",
    "monetary",
    "avg_order_value",
    "avg_shipping",
    "tenure",
    "product_category_count",
    "category_concentration",
    "avg_days_between_orders",
    "std_days_between_orders",
    "clv_proxy"
]

categorical_features = [
    "gender",
    "region"
]

required_columns = (
    [
        "snapshot_key",
        "customer_id",
        "split_role",
        "churn_flag"
    ]
    + numeric_features
    + categorical_features
)

missing_columns = [
    column
    for column in required_columns
    if column not in df.columns
]

if missing_columns:
    raise ValueError(
        "WBS 3.3에 필요한 변수가 없습니다: "
        + ", ".join(missing_columns)
    )


# ---------------------------------------------------------
# 2-3. 자료형 정리
# ---------------------------------------------------------

for column in numeric_features + ["churn_flag"]:
    df[column] = pd.to_numeric(
        df[column],
        errors="coerce"
    )

df[numeric_features] = df[numeric_features].replace(
    [np.inf, -np.inf],
    np.nan
)

for column in categorical_features:
    df[column] = (
        df[column]
        .fillna("UNKNOWN")
        .astype(str)
        .str.strip()
        .replace("", "UNKNOWN")
    )

df["split_role"] = (
    df["split_role"]
    .astype(str)
    .str.strip()
    .str.upper()
)


# ---------------------------------------------------------
# 2-4. TRAIN과 VALID 분리
# ---------------------------------------------------------

train = df.loc[df["split_role"] == "TRAIN"].copy()
valid = df.loc[df["split_role"] == "VALID"].copy()

if len(train) == 0 or len(valid) == 0:
    raise ValueError(
        "TRAIN 또는 VALID 데이터가 비어 있습니다. "
        "WBS 3.2의 시간 분리 결과를 확인하십시오."
    )

if train["churn_flag"].nunique() < 2:
    raise ValueError("TRAIN의 이탈 라벨이 한 종류뿐입니다.")

if valid["churn_flag"].nunique() < 2:
    raise ValueError("VALID의 이탈 라벨이 한 종류뿐입니다.")

feature_columns = numeric_features + categorical_features

X_train = train[feature_columns]
y_train = train["churn_flag"].astype(int)

X_valid = valid[feature_columns]
y_valid = valid["churn_flag"].astype(int)


# ---------------------------------------------------------
# 2-5. TRAIN에만 적합되는 전처리기
#
# 수치형 결측: TRAIN 중앙값
# 범주형 결측: TRAIN 최빈값
# 범주형 변수: 원-핫 인코딩
# ---------------------------------------------------------

numeric_transformer = Pipeline(
    steps=[
        (
            "imputer",
            SimpleImputer(strategy="median")
        )
    ]
)

try:
    onehot = OneHotEncoder(
        handle_unknown="ignore",
        sparse_output=False
    )
except TypeError:
    # 구버전 scikit-learn과의 호환을 위한 옵션입니다.
    onehot = OneHotEncoder(
        handle_unknown="ignore",
        sparse=False
    )

categorical_transformer = Pipeline(
    steps=[
        (
            "imputer",
            SimpleImputer(strategy="most_frequent")
        ),
        (
            "onehot",
            onehot
        )
    ]
)

preprocessor = ColumnTransformer(
    transformers=[
        (
            "numeric",
            numeric_transformer,
            numeric_features
        ),
        (
            "categorical",
            categorical_transformer,
            categorical_features
        )
    ]
)


# ---------------------------------------------------------
# 2-6. 과적합을 줄인 Gradient Boosting 설정
#
# 이 설정은 실행 전에 정한 고정 설정입니다.
# VALID 결과를 본 뒤 반복해서 값을 맞추지 않습니다.
# ---------------------------------------------------------

classifier = GradientBoostingClassifier(
    n_estimators=40,
    learning_rate=0.03,
    max_depth=3,
    subsample=0.70,
    random_state=2026
)

model = Pipeline(
    steps=[
        ("log", rc.LogSkewed()),   # 치우친 금액·횟수·간격 변수 log1p (rcommon.LOG_FEATURES)
        ("preprocessor", preprocessor),
        ("classifier", classifier)
    ]
)

# 이탈·비이탈 비율 차이를 학습 가중치로 보정합니다.
train_weights = compute_sample_weight(
    class_weight="balanced",
    y=y_train
)

model.fit(
    X_train,
    y_train,
    classifier__sample_weight=train_weights
)


# ---------------------------------------------------------
# 2-7. 고객별 예측확률 생성
# ---------------------------------------------------------

train_probability = model.predict_proba(X_train)[:, 1]
valid_probability = model.predict_proba(X_valid)[:, 1]

train_scored = train[
    ["snapshot_key", "customer_id", "split_role", "churn_flag"]
].copy()

valid_scored = valid[
    ["snapshot_key", "customer_id", "split_role", "churn_flag"]
].copy()

train_scored["churn_probability"] = train_probability
valid_scored["churn_probability"] = valid_probability

scored = pd.concat(
    [train_scored, valid_scored],
    ignore_index=True
)

scored["predicted_churn_flag"] = (
    scored["churn_probability"] >= 0.5
).astype(int)

scored = scored.rename(
    columns={"churn_flag": "actual_churn_flag"}
)


# ---------------------------------------------------------
# 2-8. TRAIN·VALID·MIXED 평가표
#
# MIXED는 학습자료가 섞였으므로 실제 성능으로 해석하면 안 됩니다.
# ---------------------------------------------------------

def make_metric_row(dataset_role, actual, probability):

    predicted = (probability >= 0.5).astype(int)

    return {
        "dataset_role": dataset_role,
        "row_count": int(len(actual)),
        "churn_rate": float(np.mean(actual)),
        "roc_auc": float(roc_auc_score(actual, probability)),
        "pr_auc": float(average_precision_score(actual, probability)),
        "accuracy": float(accuracy_score(actual, predicted)),
        "balanced_accuracy": float(
            balanced_accuracy_score(actual, predicted)
        ),
        "precision": float(
            precision_score(actual, predicted, zero_division=0)
        ),
        "recall": float(
            recall_score(actual, predicted, zero_division=0)
        ),
        "f1_score": float(
            f1_score(actual, predicted, zero_division=0)
        ),
        "threshold": 0.5,
        "official_validation_flag": (
            1 if dataset_role == "VALID" else 0
        )
    }

metric_rows = [
    make_metric_row(
        "TRAIN",
        y_train.to_numpy(),
        train_probability
    ),
    make_metric_row(
        "VALID",
        y_valid.to_numpy(),
        valid_probability
    ),
    make_metric_row(
        "MIXED_DIAGNOSTIC",
        scored["actual_churn_flag"].to_numpy(),
        scored["churn_probability"].to_numpy()
    )
]

metrics = pd.DataFrame(metric_rows)


# ---------------------------------------------------------
# 2-9. VALID 혼동행렬
# ---------------------------------------------------------

valid_prediction = (valid_probability >= 0.5).astype(int)

tn, fp, fn, tp = confusion_matrix(
    y_valid,
    valid_prediction,
    labels=[0, 1]
).ravel()

confusion = pd.DataFrame(
    [
        {
            "dataset_role": "VALID",
            "true_negative": int(tn),
            "false_positive": int(fp),
            "false_negative": int(fn),
            "true_positive": int(tp),
            "threshold": 0.5
        }
    ]
)


# ---------------------------------------------------------
# 2-10. VALID ROC 곡선 좌표
# ---------------------------------------------------------

fpr, tpr, thresholds = roc_curve(
    y_valid,
    valid_probability
)

thresholds = np.where(
    np.isfinite(thresholds),
    thresholds,
    np.nan
)

roc_valid = pd.DataFrame(
    {
        "false_positive_rate": fpr,
        "true_positive_rate": tpr,
        "threshold": thresholds
    }
)


# ---------------------------------------------------------
# 2-11. VALID 순열 중요도
#
# 각 변수를 섞었을 때 VALID AUC가 얼마나 감소하는지 계산합니다.
# 값이 클수록 미래 검증 성능에 더 중요한 변수입니다.
# ---------------------------------------------------------

perm = permutation_importance(
    model,
    X_valid,
    y_valid,
    scoring="roc_auc",
    n_repeats=10,
    random_state=2026,
    n_jobs=1
)

importance = pd.DataFrame(
    {
        "feature_name": feature_columns,
        "importance_mean": perm.importances_mean,
        "importance_std": perm.importances_std
    }
).sort_values(
    "importance_mean",
    ascending=False
).reset_index(drop=True)

importance["importance_rank"] = (
    np.arange(len(importance)) + 1
)


# ---------------------------------------------------------
# 2-12. 모델 설정 기록
# ---------------------------------------------------------

config = pd.DataFrame(
    [
        ["model", "GradientBoostingClassifier"],
        ["train_snapshot", "2019-06-30"],
        ["valid_snapshot", "2019-10-02"],
        ["label_window_days", "90"],
        ["numeric_feature_count", "14"],
        ["categorical_feature_count", "2"],
        ["n_estimators", "40"],
        ["learning_rate", "0.03"],
        ["max_depth", "3"],
        ["subsample", "0.70"],
        ["random_state", "2026"],
        ["official_metric", "VALID ROC_AUC"]
    ],
    columns=["parameter_name", "parameter_value"]
)


# ---------------------------------------------------------
# 2-13. SAS 영구 테이블로 저장
# ---------------------------------------------------------

SAS.df2sd(
    scored,
    dataset="crm.w3_churn_scored_v2"
)

SAS.df2sd(
    metrics,
    dataset="crm.w3_churn_metrics_v2"
)

SAS.df2sd(
    importance,
    dataset="crm.w3_churn_importance_v2"
)

SAS.df2sd(
    confusion,
    dataset="crm.w3_churn_confusion_v2"
)

SAS.df2sd(
    roc_valid,
    dataset="crm.w3_churn_roc_valid"
)

SAS.df2sd(
    config,
    dataset="crm.w3_churn_model_config"
)


# ---------------------------------------------------------
# 2-14. Python 로그 요약
# ---------------------------------------------------------

print("=" * 70)
print("WBS 3.3. 데이터 누수 방지 및 이탈예측 검증")
print("=" * 70)

print(f"TRAIN 행 수: {len(train):,}")
print(f"VALID 행 수: {len(valid):,}")

print("\n[평가 결과]")
print(metrics.round(4).to_string(index=False))

print("\n[VALID 순열 중요도 상위 10개]")
print(importance.head(10).round(5).to_string(index=False))

print(
    "\n주의: 공식 모델 성능은 "
    "dataset_role=VALID 행의 ROC_AUC입니다."
)
# ---- PROC PYTHON 끝 ------------------------------------------------------

# 3. SAS 결과표와 시각화
proc_print(load("w3_churn_metrics_v2"), "WBS 3.3-2. 이탈예측 평가 결과", dec=4,
           png="r33_02_metrics")
proc_print(load("w3_churn_confusion_v2"), "WBS 3.3-3. VALID 혼동행렬", png="r33_03_confusion")
proc_print(load("w3_churn_importance_v2"), "WBS 3.3-4. VALID 순열 중요도", obs=16, dec=5,
           var=["importance_rank", "feature_name", "importance_mean", "importance_std"],
           png="r33_04_importance")
rc.sas_roc_png(load("w3_churn_roc_valid"), "WBS 3.3-5. VALID ROC 곡선", "r33_05_roc_valid")
if not all(exists(t) for t in ("w3_churn_scored_v2", "w3_churn_metrics_v2",
                               "w3_churn_importance_v2", "w3_churn_confusion_v2",
                               "w3_churn_roc_valid", "w3_churn_model_config")):
    abort("WBS 3.3 결과 테이블 중 생성되지 않은 것이 있습니다.")
print("NOTE: WBS 3.3 결과 테이블 여섯 개가 모두 생성되었습니다.")


# ======================================================================
# WBS 3.3-A. Frequency A·B·C 모형 비교
# ======================================================================

require_table("w3_freq_abc_input", "WBS 3.2-A")
delete("w3_freq_abc_metrics", "w3_freq_abc_topk", "w3_freq_abc_auc_diff", "w3_freq_abc_scored",
       "w3_freq_abc_coef", "w3_freq_abc_decision")

_fa = load("w3_freq_abc_input")
proc_print(_fa.groupby("split_role").apply(lambda g: pd.Series({
    "row_count": len(g), "customer_count": g["customer_id"].nunique(),
    "churn_rate": g["churn_flag"].mean(),
    "new_valid_customer_count": int(g["is_new_valid_customer"].sum()),
    "future_feature_date_count": int((g["last_purchase_date"] > g["snapshot_cutoff"]).sum()),
    "missing_frequency_orders": int(g["frequency_orders"].isna().sum()),
    "missing_frequency_days": int(g["frequency_days"].isna().sum())}), include_groups=False)
    .reset_index(), "WBS 3.3-A-1. 비교용 입력 데이터 확인", dec=4, png="r33a_01_input_check")

# ---- 3. PROC PYTHON (원문) ------------------------------------------------
# [r3-1.sas 4587~5973행 원문]

import warnings

import numpy as np
import pandas as pd

from sklearn.compose import ColumnTransformer
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import (
    accuracy_score,
    average_precision_score,
    balanced_accuracy_score,
    brier_score_loss,
    f1_score,
    log_loss,
    precision_score,
    recall_score,
    roc_auc_score
)
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler

warnings.filterwarnings("ignore")


# ---------------------------------------------------------
# 3-1. SAS 테이블 불러오기
# ---------------------------------------------------------

df = SAS.sd2df("crm.w3_freq_abc_input")

df.columns = [
    str(column).strip().lower()
    for column in df.columns
]


# ---------------------------------------------------------
# 3-2. 공통 피처와 모형별 Frequency 정의
#
# clv_proxy는 기존 주문 수를 사용하므로 제외합니다.
# 이번 비교에서 달라지는 것은 Frequency 정의뿐입니다.
# ---------------------------------------------------------

# 쿠폰 변수(coupon_usage_rate, coupon_click_rate, last_coupon_used)는 분석 범위에서 제외 - 팀 결정
common_numeric_features = [
    "recency",
    "monetary",
    "avg_order_value",
    "avg_shipping",
    "tenure",
    "product_category_count",
    "category_concentration",
    "avg_days_between_orders",
    "std_days_between_orders"
]

categorical_features = [
    "gender",
    "region"
]

model_feature_map = {
    "A_ORDERS": (
        common_numeric_features
        + ["frequency_orders"]
    ),

    "B_DAYS": (
        common_numeric_features
        + ["frequency_days"]
    ),

    "C_BOTH": (
        common_numeric_features
        + ["frequency_orders", "frequency_days"]
    )
}


# ---------------------------------------------------------
# 3-3. 필수 변수 확인
# ---------------------------------------------------------

all_numeric_features = (
    common_numeric_features
    + ["frequency_orders", "frequency_days"]
)

required_columns = (
    [
        "snapshot_key",
        "customer_id",
        "split_role",
        "churn_flag",
        "is_new_valid_customer"
    ]
    + all_numeric_features
    + categorical_features
)

missing_columns = [
    column
    for column in required_columns
    if column not in df.columns
]

if missing_columns:

    raise ValueError(
        "WBS 3.3-A에 필요한 변수가 없습니다: "
        + ", ".join(missing_columns)
    )


# ---------------------------------------------------------
# 3-4. 자료형 정리
# ---------------------------------------------------------

for column in all_numeric_features + [
    "churn_flag",
    "is_new_valid_customer"
]:

    df[column] = pd.to_numeric(
        df[column],
        errors="coerce"
    )

df[all_numeric_features] = (
    df[all_numeric_features]
    .replace([np.inf, -np.inf], np.nan)
)

for column in categorical_features:

    df[column] = (
        df[column]
        .fillna("UNKNOWN")
        .astype(str)
        .str.strip()
        .replace("", "UNKNOWN")
    )

df["split_role"] = (
    df["split_role"]
    .astype(str)
    .str.strip()
    .str.upper()
)

df["customer_id"] = (
    df["customer_id"]
    .astype(str)
    .str.strip()
)

df["snapshot_key"] = (
    df["snapshot_key"]
    .astype(str)
    .str.strip()
)


# ---------------------------------------------------------
# 3-5. TRAIN과 VALID 분리
# ---------------------------------------------------------

train = df.loc[
    df["split_role"] == "TRAIN"
].copy()

valid = df.loc[
    df["split_role"] == "VALID"
].copy()

valid_new = valid.loc[
    valid["is_new_valid_customer"] == 1
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

if train["customer_id"].duplicated().any():

    raise ValueError(
        "TRAIN 안에 중복 고객ID가 있습니다."
    )

if valid["customer_id"].duplicated().any():

    raise ValueError(
        "VALID 안에 중복 고객ID가 있습니다."
    )

y_train = train["churn_flag"].astype(int)
y_valid = valid["churn_flag"].astype(int)
y_valid_new = valid_new["churn_flag"].astype(int)


# ---------------------------------------------------------
# 3-6. 안전한 평가 함수
# ---------------------------------------------------------

def safe_roc_auc(actual, probability):

    if len(actual) == 0:
        return np.nan

    if pd.Series(actual).nunique() < 2:
        return np.nan

    return float(
        roc_auc_score(actual, probability)
    )


def safe_pr_auc(actual, probability):

    if len(actual) == 0:
        return np.nan

    if pd.Series(actual).nunique() < 2:
        return np.nan

    return float(
        average_precision_score(actual, probability)
    )


def make_metric_row(
    model_variant,
    dataset_role,
    actual,
    probability
):

    actual = np.asarray(actual)
    probability = np.asarray(probability)

    if len(actual) == 0:

        return {
            "model_variant": model_variant,
            "dataset_role": dataset_role,
            "row_count": 0,
            "churn_rate": np.nan,
            "mean_probability": np.nan,
            "calibration_gap": np.nan,
            "roc_auc": np.nan,
            "pr_auc": np.nan,
            "brier_score": np.nan,
            "log_loss": np.nan,
            "accuracy": np.nan,
            "balanced_accuracy": np.nan,
            "precision": np.nan,
            "recall": np.nan,
            "f1_score": np.nan,
            "threshold": 0.5
        }

    predicted = (
        probability >= 0.5
    ).astype(int)

    churn_rate = float(
        np.mean(actual)
    )

    mean_probability = float(
        np.mean(probability)
    )

    return {
        "model_variant": model_variant,
        "dataset_role": dataset_role,
        "row_count": int(len(actual)),
        "churn_rate": churn_rate,
        "mean_probability": mean_probability,
        "calibration_gap": (
            mean_probability - churn_rate
        ),
        "roc_auc": safe_roc_auc(
            actual,
            probability
        ),
        "pr_auc": safe_pr_auc(
            actual,
            probability
        ),
        "brier_score": float(
            brier_score_loss(
                actual,
                probability
            )
        ),
        "log_loss": float(
            log_loss(
                actual,
                probability,
                labels=[0, 1]
            )
        ),
        "accuracy": float(
            accuracy_score(
                actual,
                predicted
            )
        ),
        "balanced_accuracy": float(
            balanced_accuracy_score(
                actual,
                predicted
            )
        ),
        "precision": float(
            precision_score(
                actual,
                predicted,
                zero_division=0
            )
        ),
        "recall": float(
            recall_score(
                actual,
                predicted,
                zero_division=0
            )
        ),
        "f1_score": float(
            f1_score(
                actual,
                predicted,
                zero_division=0
            )
        ),
        "threshold": 0.5
    }


# ---------------------------------------------------------
# 3-7. 모형 생성 함수
#
# 수치형 변수는 TRAIN 중앙값 대체 후 표준화합니다.
# 범주형 변수는 TRAIN 최빈값 대체 후 원-핫 인코딩합니다.
# 확률 해석을 위해 class_weight는 사용하지 않습니다.
# ---------------------------------------------------------

def make_model(numeric_features):

    numeric_transformer = Pipeline(
        steps=[
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
        ]
    )

    try:

        onehot = OneHotEncoder(
            handle_unknown="ignore",
            sparse_output=False
        )

    except TypeError:

        onehot = OneHotEncoder(
            handle_unknown="ignore",
            sparse=False
        )

    categorical_transformer = Pipeline(
        steps=[
            (
                "imputer",
                SimpleImputer(
                    strategy="most_frequent"
                )
            ),
            (
                "onehot",
                onehot
            )
        ]
    )

    preprocessor = ColumnTransformer(
        transformers=[
            (
                "numeric",
                numeric_transformer,
                numeric_features
            ),
            (
                "categorical",
                categorical_transformer,
                categorical_features
            )
        ]
    )

    classifier = LogisticRegression(
        penalty="l2",
        C=1.0,
        solver="liblinear",
        max_iter=2000,
        class_weight=None,
        random_state=2026
    )

    return Pipeline(
        steps=[
            ("log", rc.LogSkewed()),   # 치우친 금액·횟수·간격 변수 log1p (rcommon.LOG_FEATURES)
            (
                "preprocessor",
                preprocessor
            ),
            (
                "classifier",
                classifier
            )
        ]
    )


# ---------------------------------------------------------
# 3-8. A·B·C 모형 학습 및 예측
# ---------------------------------------------------------

metric_rows = []
scored_frames = []
topk_rows = []
coefficient_frames = []

valid_probability_map = {}

for model_variant, numeric_features in model_feature_map.items():

    feature_columns = (
        numeric_features
        + categorical_features
    )

    X_train = train[
        feature_columns
    ].copy()

    X_valid = valid[
        feature_columns
    ].copy()

    X_valid_new = valid_new[
        feature_columns
    ].copy()

    model = make_model(
        numeric_features
    )

    model.fit(
        X_train,
        y_train
    )

    train_probability = (
        model.predict_proba(X_train)[:, 1]
    )

    valid_probability = (
        model.predict_proba(X_valid)[:, 1]
    )

    if len(valid_new) > 0:

        valid_new_probability = (
            model.predict_proba(
                X_valid_new
            )[:, 1]
        )

    else:

        valid_new_probability = (
            np.array([])
        )

    valid_probability_map[
        model_variant
    ] = valid_probability

    metric_rows.append(
        make_metric_row(
            model_variant,
            "TRAIN",
            y_train,
            train_probability
        )
    )

    metric_rows.append(
        make_metric_row(
            model_variant,
            "VALID",
            y_valid,
            valid_probability
        )
    )

    metric_rows.append(
        make_metric_row(
            model_variant,
            "VALID_NEW",
            y_valid_new,
            valid_new_probability
        )
    )


    # -----------------------------------------------------
    # 고객별 예측확률 저장
    # -----------------------------------------------------

    train_scored = train[
        [
            "snapshot_key",
            "customer_id",
            "split_role",
            "churn_flag",
            "is_new_valid_customer"
        ]
    ].copy()

    valid_scored = valid[
        [
            "snapshot_key",
            "customer_id",
            "split_role",
            "churn_flag",
            "is_new_valid_customer"
        ]
    ].copy()

    train_scored[
        "churn_probability"
    ] = train_probability

    valid_scored[
        "churn_probability"
    ] = valid_probability

    model_scored = pd.concat(
        [
            train_scored,
            valid_scored
        ],
        ignore_index=True
    )

    model_scored[
        "model_variant"
    ] = model_variant

    model_scored[
        "risk_rank"
    ] = (
        model_scored
        .groupby("split_role")[
            "churn_probability"
        ]
        .rank(
            method="first",
            ascending=False
        )
        .astype(int)
    )

    model_scored = model_scored.rename(
        columns={
            "churn_flag":
            "actual_churn_flag"
        }
    )

    scored_frames.append(
        model_scored
    )


    # -----------------------------------------------------
    # VALID 상위 100명·200명 성과
    # -----------------------------------------------------

    valid_ranked = (
        valid_scored
        .sort_values(
            "churn_probability",
            ascending=False
        )
        .reset_index(drop=True)
    )

    total_valid_churn = int(
        y_valid.sum()
    )

    valid_churn_rate = float(
        y_valid.mean()
    )

    for requested_k in [100, 200]:

        actual_k = min(
            requested_k,
            len(valid_ranked)
        )

        selected = valid_ranked.head(
            actual_k
        )

        captured_churn = int(
            selected["churn_flag"].sum()
        )

        precision_at_k = (
            captured_churn / actual_k
            if actual_k > 0
            else np.nan
        )

        recall_at_k = (
            captured_churn
            / total_valid_churn
            if total_valid_churn > 0
            else np.nan
        )

        lift_at_k = (
            precision_at_k
            / valid_churn_rate
            if valid_churn_rate > 0
            else np.nan
        )

        topk_rows.append(
            {
                "model_variant":
                    model_variant,

                "dataset_role":
                    "VALID",

                "requested_k":
                    requested_k,

                "actual_k":
                    actual_k,

                "captured_churn":
                    captured_churn,

                "precision_at_k":
                    precision_at_k,

                "recall_at_k":
                    recall_at_k,

                "lift_at_k":
                    lift_at_k
            }
        )


    # -----------------------------------------------------
    # 표준화 로지스틱 회귀계수
    # -----------------------------------------------------

    fitted_preprocessor = (
        model.named_steps[
            "preprocessor"
        ]
    )

    fitted_classifier = (
        model.named_steps[
            "classifier"
        ]
    )

    try:

        feature_names = (
            fitted_preprocessor
            .get_feature_names_out()
        )

        feature_names = [
            str(name)
            .replace(
                "numeric__",
                ""
            )
            .replace(
                "categorical__",
                ""
            )
            for name in feature_names
        ]

    except Exception:

        feature_names = [
            "feature_" + str(index + 1)
            for index in range(
                len(
                    fitted_classifier.coef_[0]
                )
            )
        ]

    coefficients = pd.DataFrame(
        {
            "model_variant":
                model_variant,

            "feature_name":
                feature_names,

            "coefficient":
                fitted_classifier.coef_[0]
        }
    )

    coefficients[
        "abs_coefficient"
    ] = (
        coefficients[
            "coefficient"
        ]
        .abs()
    )

    coefficients = (
        coefficients
        .sort_values(
            "abs_coefficient",
            ascending=False
        )
        .reset_index(drop=True)
    )

    coefficients[
        "importance_rank"
    ] = (
        np.arange(
            len(coefficients)
        )
        + 1
    )

    coefficient_frames.append(
        coefficients
    )


# ---------------------------------------------------------
# 3-9. 결과 데이터 결합
# ---------------------------------------------------------

metrics = pd.DataFrame(
    metric_rows
)

topk = pd.DataFrame(
    topk_rows
)

scored = pd.concat(
    scored_frames,
    ignore_index=True
)

coefficients = pd.concat(
    coefficient_frames,
    ignore_index=True
)


# ---------------------------------------------------------
# 3-10. VALID AUC 차이 부트스트랩
#
# 같은 VALID 고객을 함께 재표집하여 AUC 차이를 계산합니다.
# 신뢰구간이 0을 넘으면 후보모형이 더 우수하다는 근거가 됩니다.
# ---------------------------------------------------------

BOOTSTRAP_REPEATS = 1000
BOOTSTRAP_SEED = 2026

comparison_pairs = [
    (
        "B_DAYS",
        "A_ORDERS"
    ),
    (
        "C_BOTH",
        "A_ORDERS"
    ),
    (
        "C_BOTH",
        "B_DAYS"
    )
]


def paired_auc_difference(
    candidate_name,
    reference_name
):

    candidate_probability = (
        valid_probability_map[
            candidate_name
        ]
    )

    reference_probability = (
        valid_probability_map[
            reference_name
        ]
    )

    actual = y_valid.to_numpy()

    observed_difference = (
        roc_auc_score(
            actual,
            candidate_probability
        )
        -
        roc_auc_score(
            actual,
            reference_probability
        )
    )

    rng = np.random.RandomState(
        BOOTSTRAP_SEED
    )

    differences = []

    row_count = len(actual)

    for repeat in range(
        BOOTSTRAP_REPEATS
    ):

        sample_index = rng.randint(
            0,
            row_count,
            row_count
        )

        sample_actual = actual[
            sample_index
        ]

        if np.unique(
            sample_actual
        ).size < 2:

            continue

        candidate_auc = roc_auc_score(
            sample_actual,
            candidate_probability[
                sample_index
            ]
        )

        reference_auc = roc_auc_score(
            sample_actual,
            reference_probability[
                sample_index
            ]
        )

        differences.append(
            candidate_auc
            - reference_auc
        )

    if len(differences) > 0:

        ci_low = float(
            np.percentile(
                differences,
                2.5
            )
        )

        ci_high = float(
            np.percentile(
                differences,
                97.5
            )
        )

    else:

        ci_low = np.nan
        ci_high = np.nan

    return {
        "candidate_model":
            candidate_name,

        "reference_model":
            reference_name,

        "auc_difference":
            float(
                observed_difference
            ),

        "ci_low":
            ci_low,

        "ci_high":
            ci_high,

        "bootstrap_repeats":
            int(
                len(differences)
            )
    }


auc_difference = pd.DataFrame(
    [
        paired_auc_difference(
            candidate,
            reference
        )
        for candidate, reference
        in comparison_pairs
    ]
)


# ---------------------------------------------------------
# 3-11. 잠정 권고안 생성
#
# 후보모형 채택 조건
#   1. VALID AUC가 A안보다 높음
#   2. AUC 차이 신뢰구간 하한이 0보다 큼
#   3. Brier Score가 A안보다 0.002 초과 악화되지 않음
#   4. 신규 VALID AUC가 A안보다 0.01 초과 악화되지 않음
#
# B와 C가 모두 통과하면 C가 B보다 명확히 좋아야 C를 선택합니다.
# 그렇지 않으면 설명이 간단한 B를 우선합니다.
# ---------------------------------------------------------

BRIER_TOLERANCE = 0.002
NEW_AUC_TOLERANCE = 0.010
MIN_EXTRA_AUC_FOR_C = 0.005


def metric_value(
    model_variant,
    dataset_role,
    metric_name
):

    selected = metrics.loc[
        (
            metrics["model_variant"]
            == model_variant
        )
        &
        (
            metrics["dataset_role"]
            == dataset_role
        ),
        metric_name
    ]

    if len(selected) == 0:

        return np.nan

    return float(
        selected.iloc[0]
    )


def difference_value(
    candidate_model,
    reference_model,
    column_name
):

    selected = auc_difference.loc[
        (
            auc_difference[
                "candidate_model"
            ]
            == candidate_model
        )
        &
        (
            auc_difference[
                "reference_model"
            ]
            == reference_model
        ),
        column_name
    ]

    if len(selected) == 0:

        return np.nan

    return float(
        selected.iloc[0]
    )


a_valid_auc = metric_value(
    "A_ORDERS",
    "VALID",
    "roc_auc"
)

a_valid_brier = metric_value(
    "A_ORDERS",
    "VALID",
    "brier_score"
)

a_new_auc = metric_value(
    "A_ORDERS",
    "VALID_NEW",
    "roc_auc"
)


def candidate_passes(
    candidate_model
):

    candidate_auc = metric_value(
        candidate_model,
        "VALID",
        "roc_auc"
    )

    candidate_brier = metric_value(
        candidate_model,
        "VALID",
        "brier_score"
    )

    candidate_new_auc = metric_value(
        candidate_model,
        "VALID_NEW",
        "roc_auc"
    )

    ci_low = difference_value(
        candidate_model,
        "A_ORDERS",
        "ci_low"
    )

    auc_ok = (
        not np.isnan(candidate_auc)
        and candidate_auc > a_valid_auc
    )

    ci_ok = (
        not np.isnan(ci_low)
        and ci_low > 0
    )

    brier_ok = (
        not np.isnan(candidate_brier)
        and candidate_brier
            <= a_valid_brier
               + BRIER_TOLERANCE
    )

    if (
        np.isnan(a_new_auc)
        or np.isnan(candidate_new_auc)
    ):

        new_valid_ok = True

    else:

        new_valid_ok = (
            candidate_new_auc
            >= a_new_auc
               - NEW_AUC_TOLERANCE
        )

    return {
        "pass": (
            auc_ok
            and ci_ok
            and brier_ok
            and new_valid_ok
        ),
        "auc_ok": auc_ok,
        "ci_ok": ci_ok,
        "brier_ok": brier_ok,
        "new_valid_ok": new_valid_ok
    }


b_check = candidate_passes(
    "B_DAYS"
)

c_check = candidate_passes(
    "C_BOTH"
)


if b_check["pass"] and c_check["pass"]:

    c_minus_b_auc = difference_value(
        "C_BOTH",
        "B_DAYS",
        "auc_difference"
    )

    c_minus_b_ci_low = difference_value(
        "C_BOTH",
        "B_DAYS",
        "ci_low"
    )

    if (
        not np.isnan(c_minus_b_auc)
        and not np.isnan(c_minus_b_ci_low)
        and c_minus_b_auc
            >= MIN_EXTRA_AUC_FOR_C
        and c_minus_b_ci_low > 0
    ):

        decision_code = (
            "SELECT_C_BOTH"
        )

        selected_model = (
            "C_BOTH"
        )

        decision_reason = (
            "B와 C가 모두 A보다 우수하며, "
            "C가 B보다도 유의하고 실질적인 "
            "VALID AUC 개선을 보였습니다."
        )

    else:

        decision_code = (
            "SELECT_B_DAYS"
        )

        selected_model = (
            "B_DAYS"
        )

        decision_reason = (
            "B와 C가 모두 A보다 우수하지만, "
            "C의 추가 개선이 충분하지 않아 "
            "더 단순한 B를 우선합니다."
        )


elif b_check["pass"]:

    decision_code = (
        "SELECT_B_DAYS"
    )

    selected_model = (
        "B_DAYS"
    )

    decision_reason = (
        "구매일 수 모형이 VALID에서 A보다 "
        "안정적으로 개선되었고 보조 조건도 통과했습니다."
    )


elif c_check["pass"]:

    decision_code = (
        "SELECT_C_BOTH"
    )

    selected_model = (
        "C_BOTH"
    )

    decision_reason = (
        "주문 수와 구매일 수를 함께 사용한 모형만 "
        "A보다 안정적인 개선을 보였습니다."
    )


else:

    decision_code = (
        "KEEP_A_ORDERS"
    )

    selected_model = (
        "A_ORDERS"
    )

    decision_reason = (
        "B와 C가 사전에 정한 검증 조건을 모두 통과하지 못했습니다. "
        "현재 단계에서는 기존 주문 수 정의를 유지합니다."
    )


decision = pd.DataFrame(
    [
        {
            "decision_code":
                decision_code,

            "selected_model":
                selected_model,

            "decision_reason":
                decision_reason,

            "b_pass":
                int(
                    b_check["pass"]
                ),

            "c_pass":
                int(
                    c_check["pass"]
                ),

            "b_valid_auc":
                metric_value(
                    "B_DAYS",
                    "VALID",
                    "roc_auc"
                ),

            "c_valid_auc":
                metric_value(
                    "C_BOTH",
                    "VALID",
                    "roc_auc"
                ),

            "a_valid_auc":
                a_valid_auc,

            "team_review_required":
                1
        }
    ]
)


# ---------------------------------------------------------
# 3-12. SAS 영구 테이블 저장
# ---------------------------------------------------------

SAS.df2sd(
    metrics,
    dataset="crm.w3_freq_abc_metrics"
)

SAS.df2sd(
    topk,
    dataset="crm.w3_freq_abc_topk"
)

SAS.df2sd(
    auc_difference,
    dataset="crm.w3_freq_abc_auc_diff"
)

SAS.df2sd(
    scored,
    dataset="crm.w3_freq_abc_scored"
)

SAS.df2sd(
    coefficients,
    dataset="crm.w3_freq_abc_coef"
)

SAS.df2sd(
    decision,
    dataset="crm.w3_freq_abc_decision"
)


# ---------------------------------------------------------
# 3-13. Python 로그 요약
# ---------------------------------------------------------

print("=" * 72)
print("WBS 3.3-A. Frequency A·B·C 모형 비교")
print("=" * 72)

print(f"TRAIN 고객 수: {len(train):,}")
print(f"VALID 고객 수: {len(valid):,}")
print(
    "TRAIN에 없던 신규 VALID 고객 수: "
    f"{len(valid_new):,}"
)

print("\n[모형별 평가 결과]")
print(
    metrics
    .round(5)
    .to_string(index=False)
)

print("\n[VALID 상위 100명·200명 결과]")
print(
    topk
    .round(5)
    .to_string(index=False)
)

print("\n[VALID AUC 차이와 95% 부트스트랩 신뢰구간]")
print(
    auc_difference
    .round(5)
    .to_string(index=False)
)

print("\n[잠정 권고안]")
print(
    decision
    .to_string(index=False)
)

print(
    "\n주의: 이 결과는 Frequency 정의 선택을 위한 진단 결과입니다."
)

print(
    "공식 3절·4절 산출물은 팀 검토 후 별도로 갱신해야 합니다."
)
# ---- PROC PYTHON 끝 ------------------------------------------------------

# 4. SAS 결과표 출력
proc_print(load("w3_freq_abc_metrics"), "WBS 3.3-A-2. A·B·C 모형별 성능", dec=5,
           png="r33a_02_metrics")
proc_print(load("w3_freq_abc_topk"), "WBS 3.3-A-3. VALID 상위 100명·200명 성과", dec=4,
           png="r33a_03_topk")
proc_print(load("w3_freq_abc_auc_diff"), "WBS 3.3-A-4. VALID AUC 차이와 신뢰구간", dec=5,
           png="r33a_04_auc_diff")
proc_print(load("w3_freq_abc_decision"), "WBS 3.3-A-5. 잠정 권고안", dec=5, png="r33a_05_decision")
_coef = load("w3_freq_abc_coef")
proc_print(_coef[_coef["feature_name"].astype(str).str.upper().str.contains("FREQUENCY")],
           "WBS 3.3-A-6. Frequency 관련 표준화 회귀계수", dec=5,
           var=["model_variant", "feature_name", "coefficient", "abs_coefficient", "importance_rank"],
           png="r33a_06_freq_coef")
# 5. VALID ROC-AUC 비교 그래프 (categoryorder=respdesc)
_m = load("w3_freq_abc_metrics")
_m = _m[_m["dataset_role"] == "VALID"].sort_values("roc_auc", ascending=False)
rc.sas_bar_png(_m["model_variant"], _m["roc_auc"], "WBS 3.3-A-7. VALID ROC-AUC 비교",
               "r33a_07_valid_auc", xlabel="Frequency 모형", ylabel="VALID ROC-AUC",
               ylim=(0.5, 1), datalabel=True)
if not all(exists(t) for t in ("w3_freq_abc_metrics", "w3_freq_abc_topk", "w3_freq_abc_auc_diff",
                               "w3_freq_abc_scored", "w3_freq_abc_coef", "w3_freq_abc_decision")):
    abort("WBS 3.3-A 결과 테이블 중 생성되지 않은 것이 있습니다.")
print("NOTE: WBS 3.3-A 결과 테이블 여섯 개가 모두 생성되었습니다.")


# ======================================================================
# WBS 3.4. Frequency 공식 후보 확정 및 산출물 정리
# ======================================================================

for _t, _step in [("w3_model_input", "WBS 3.1-A"), ("w3_freq_abc_input", "WBS 3.2-A"),
                  ("w3_freq_abc_qa", "WBS 3.2-A"), ("w3_freq_abc_metrics", "WBS 3.3-A"),
                  ("w3_freq_abc_topk", "WBS 3.3-A"), ("w3_freq_abc_auc_diff", "WBS 3.3-A"),
                  ("w3_freq_abc_scored", "WBS 3.3-A"), ("w3_freq_abc_coef", "WBS 3.3-A"),
                  ("w3_freq_abc_decision", "WBS 3.3-A")]:
    require_table(_t, _step)
delete("w3_frequency_policy", "w3_frequency_gate_qa", "w3_final_qa", "w3_cleanup_log",
       "w3_output_catalog")

# 3. 3.2-A Frequency 피처 품질
_q = load("w3_freq_abc_qa")
freq_qa_issue_count = int(_q["missing_frequency_orders"].sum() + _q["missing_frequency_days"].sum()
                          + _q["invalid_days_over_orders"].sum()
                          + _q["original_frequency_mismatch"].sum())
freq_duplicate_count = int((load("w3_freq_abc_input").groupby(["split_role", "customer_id"]).size()
                            > 1).sum())

# 4. A·B·C 핵심 평가값 (매크로 변수)
_met = load("w3_freq_abc_metrics")
_diff = load("w3_freq_abc_auc_diff")


def _metric(variant, role, col):
    return float(_met.loc[(_met["model_variant"] == variant) & (_met["dataset_role"] == role),
                          col].iloc[0])


def _auc_diff(cand, ref):
    r = _diff[(_diff["candidate_model"] == cand) & (_diff["reference_model"] == ref)].iloc[0]
    return float(r["auc_difference"]), float(r["ci_low"]), float(r["ci_high"])


a_valid_auc, b_valid_auc, c_valid_auc = (_metric(v, "VALID", "roc_auc")
                                         for v in ("A_ORDERS", "B_DAYS", "C_BOTH"))
a_valid_brier, b_valid_brier = (_metric(v, "VALID", "brier_score") for v in ("A_ORDERS", "B_DAYS"))
a_valid_logloss, b_valid_logloss = (_metric(v, "VALID", "log_loss") for v in ("A_ORDERS", "B_DAYS"))
b_calibration_gap = _metric("B_DAYS", "VALID", "calibration_gap")
b_new_auc = _metric("B_DAYS", "VALID_NEW", "roc_auc")
ba_auc_diff, ba_ci_low, ba_ci_high = _auc_diff("B_DAYS", "A_ORDERS")
cb_auc_diff, cb_ci_low, cb_ci_high = _auc_diff("C_BOTH", "B_DAYS")
_dec = load("w3_freq_abc_decision").iloc[0]
abc_decision_code = str(_dec["decision_code"]).strip()
abc_selected_model = str(_dec["selected_model"]).strip()

# 5. B안 후보 확정 전 핵심 조건 (%validate_b_candidate)
if freq_qa_issue_count > 0:
    abort(f"WBS 3.2-A Frequency QA에서 문제가 발견되었습니다. 문제 건수 = {freq_qa_issue_count}")
if freq_duplicate_count > 0:
    abort(f"역할 내부에 중복 고객ID가 있습니다. 중복 고객 건수 = {freq_duplicate_count}")
if abc_selected_model.upper() != "B_DAYS":
    abort(f"WBS 3.3-A의 선택 결과가 B_DAYS가 아닙니다. 현재 선택 결과 = {abc_selected_model}")
if b_valid_auc <= a_valid_auc:
    abort("B_DAYS의 VALID AUC가 A_ORDERS보다 높지 않습니다.")
if ba_ci_low <= 0:
    abort("B-A AUC 차이의 신뢰구간 하한이 0보다 크지 않습니다.")
if b_valid_brier > a_valid_brier:
    abort("B_DAYS의 Brier Score가 A_ORDERS보다 높습니다.")
print("NOTE: B_DAYS 잠정 공식 후보의 핵심 검증 조건을 통과했습니다.")

# 6. Frequency 후보 확정 정책 테이블
w3_frequency_policy = pd.DataFrame([{
    "decision_status": "PROVISIONAL_OFFICIAL_CANDIDATE",
    "selected_option": "B_DAYS",
    "official_frequency_variable": "frequency_days",
    "official_frequency_definition": "해당 기준일까지 구매가 발생한 서로 다른 날짜 수",
    "reference_frequency_variable": "frequency_orders",
    "reference_frequency_usage": "기존 값을 삭제하지 않고 주문 강도와 데이터 점검용으로 보존",
    "modeling_rule": "이탈모형 공식 후보는 frequency_days 단독 사용. "
                     "frequency_orders 동시 투입은 현재 채택하지 않음",
    "rfmp_rule": "3.5에서 RFMP 기준일까지의 frequency_days를 새로 계산. "
                 "3.2-A 스냅샷 값을 그대로 사용하지 않음",
    "unresolved_issue_1": "신규 VALID 고객 AUC가 약 0.55로 낮아 별도 신규고객 전략 필요",
    "unresolved_issue_2": "평균 예측확률이 실제 이탈률보다 낮아 확률 보정 문제 미해결",
    "decision_basis": "B_DAYS가 A_ORDERS보다 VALID ROC-AUC, Brier Score, "
                      "Log Loss에서 개선. C_BOTH는 B_DAYS보다 추가 개선 없음",
    "policy_id": 1, "decision_date": pd.Timestamp(_dt.date.today()),
    "a_valid_auc": a_valid_auc, "b_valid_auc": b_valid_auc, "c_valid_auc": c_valid_auc,
    "b_minus_a_auc": ba_auc_diff, "b_minus_a_ci_low": ba_ci_low, "b_minus_a_ci_high": ba_ci_high,
    "a_valid_brier": a_valid_brier, "b_valid_brier": b_valid_brier,
    "a_valid_logloss": a_valid_logloss, "b_valid_logloss": b_valid_logloss,
    "b_new_valid_auc": b_new_auc, "b_calibration_gap": b_calibration_gap,
    "new_customer_issue_resolved": 0, "calibration_issue_resolved": 0, "team_review_required": 1,
}])
save(w3_frequency_policy, "w3_frequency_policy")

# 7. Frequency 후보 확정 QA
_gate = [
    (1, "3.2-A Frequency 품질 오류", str(freq_qa_issue_count), "0",
     "PASS" if freq_qa_issue_count == 0 else "FAIL", "결측·역전·기존 Frequency 불일치가 없어야 함"),
    (2, "TRAIN·VALID 역할 내부 중복 고객", str(freq_duplicate_count), "0",
     "PASS" if freq_duplicate_count == 0 else "FAIL", "각 역할에서 고객 한 명은 한 행만 가져야 함"),
    (3, "3.3-A 잠정 선택 모형", abc_selected_model, "B_DAYS",
     "PASS" if abc_selected_model.upper() == "B_DAYS" else "FAIL",
     "사전 판정 규칙의 선택 결과와 팀의 잠정 결정이 일치해야 함"),
    (4, "B_DAYS와 A_ORDERS VALID AUC", f"A={a_valid_auc:.5f}, B={b_valid_auc:.5f}", "B > A",
     "PASS" if b_valid_auc > a_valid_auc else "FAIL",
     "구매일 수가 주문 수보다 전체 VALID 순위 구분력이 높아야 함"),
    (5, "B-A AUC 차이 95% 신뢰구간", f"[{ba_ci_low:.5f}, {ba_ci_high:.5f}]", "신뢰구간 하한 > 0",
     "PASS" if ba_ci_low > 0 else "FAIL", "VALID에서 관측된 개선이 단순 표본 변동일 가능성을 점검"),
    (6, "B_DAYS와 A_ORDERS Brier Score", f"A={a_valid_brier:.5f}, B={b_valid_brier:.5f}", "B <= A",
     "PASS" if b_valid_brier <= a_valid_brier else "FAIL", "낮을수록 고객별 예측확률 오차가 작음"),
    (7, "C_BOTH의 B_DAYS 대비 추가 효과",
     f"차이={cb_auc_diff:.5f}, CI=[{cb_ci_low:.5f}, {cb_ci_high:.5f}]", "추가 개선이 확인되지 않음",
     "PASS" if (cb_ci_low <= 0 <= cb_ci_high) else "REVIEW",
     "C안의 추가 개선이 없으면 더 단순한 B안을 우선"),
    (8, "B_DAYS 신규 VALID ROC-AUC", f"{b_new_auc:.5f}", "후속 단계에서 별도 검토", "REVIEW",
     "신규 고객에서는 구분력이 낮아 기존 고객과 분리 운영 필요"),
    (9, "B_DAYS 평균 예측확률 오차", f"{b_calibration_gap:.2%}", "절대값 3%p 이내 또는 후속 보정",
     "PASS" if abs(b_calibration_gap) <= 0.03 else "REVIEW",
     "현재 B안은 순위 비교에 사용하고 절대확률 해석은 보류"),
]
w3_frequency_gate_qa = pd.DataFrame(_gate, columns=["check_order", "check_item", "actual_value",
                                                    "expected_value", "status", "interpretation"])
save(w3_frequency_gate_qa, "w3_frequency_gate_qa")

# 8. 정책과 QA 출력
proc_print(w3_frequency_policy.T.reset_index().set_axis(["항목", "값"], axis=1).iloc[:11],
           "WBS 3.4-1. Frequency 잠정 공식 후보 정책", png="r34_01_policy")
proc_print(w3_frequency_gate_qa, "WBS 3.4-2. Frequency 후보 확정 QA", png="r34_02_gate_qa")

# 9~10. 주요 산출물 존재 여부
_required = [
    ("3.1-A", "W3_MODEL_INPUT", "RFM 원본·로그·표준화 고객 데이터"),
    ("3.1-A", "W3_RFM_PROFILE", "RFM 기술통계와 왜도"),
    ("3.1-A", "W3_SCALER_STATS", "RFM 표준화 기준값"),
    ("3.1-B", "W3_K_EVAL", "RFM K 후보별 군집 품질 비교"),
    ("3.2", "W3_CHURN_WINDOW_COMPARE", "30·60·90·120일 이탈률 비교"),
    ("3.2", "W3_CHURN_SPLIT_V2", "시간 순서대로 분리된 이탈예측 피처"),
    ("3.2", "W3_CHURN_FEATURE_PROFILE", "이탈예측 피처별 기술통계"),
    ("3.2", "W3_CHURN_QA_SUMMARY", "시간 분리 데이터 품질 요약"),
    ("3.3", "W3_CHURN_SCORED_V2", "고객별 실제 이탈값과 예측확률"),
    ("3.3", "W3_CHURN_METRICS_V2", "TRAIN·VALID·혼합 평가 결과"),
    ("3.3", "W3_CHURN_IMPORTANCE_V2", "VALID 순열 중요도"),
    ("3.3", "W3_CHURN_CONFUSION_V2", "VALID 혼동행렬"),
    ("3.3", "W3_CHURN_ROC_VALID", "VALID ROC 곡선 좌표"),
    ("3.3", "W3_CHURN_MODEL_CONFIG", "이탈예측 모델 설정 기록"),
    ("3.2-A", "W3_FREQ_ABC_INPUT", "A·B·C Frequency 비교 입력 데이터"),
    ("3.2-A", "W3_FREQ_ABC_QA", "A·B·C Frequency 비교 입력 QA"),
    ("3.3-A", "W3_FREQ_ABC_METRICS", "A·B·C 모형 성능 비교"),
    ("3.3-A", "W3_FREQ_ABC_TOPK", "A·B·C 상위 고객 적중 비교"),
    ("3.3-A", "W3_FREQ_ABC_AUC_DIFF", "AUC 차이와 신뢰구간"),
    ("3.3-A", "W3_FREQ_ABC_SCORED", "고객별 A·B·C 예측결과"),
    ("3.3-A", "W3_FREQ_ABC_COEF", "A·B·C 모형 계수"),
    ("3.3-A", "W3_FREQ_ABC_DECISION", "Frequency 후보 자동 권고"),
    ("3.4", "W3_FREQUENCY_POLICY", "Frequency 잠정 공식 후보와 적용 원칙"),
    ("3.4", "W3_FREQUENCY_GATE_QA", "Frequency 후보 확정 검증 결과"),
]


def _table_info(name):
    """dictionary.tables 의 nobs / nvar / crdate / modate"""
    path = rc.CRM_DIR / f"{name.lower()}.pkl"
    if not path.exists():
        return {"exists_flag": 0, "row_count": np.nan, "column_count": np.nan,
                "created_at": pd.NaT, "modified_at": pd.NaT}
    df = pd.read_pickle(path)
    st = path.stat()
    return {"exists_flag": 1, "row_count": len(df), "column_count": df.shape[1],
            "created_at": pd.Timestamp(st.st_ctime, unit="s"),
            "modified_at": pd.Timestamp(st.st_mtime, unit="s")}


w3_final_qa = (pd.DataFrame([{"wbs_step": s, "table_name": t, "table_purpose": p, **_table_info(t)}
                             for s, t, p in _required])
               .sort_values(["wbs_step", "table_name"], ignore_index=True))
save(w3_final_qa, "w3_final_qa")
proc_print(w3_final_qa, "WBS 3.4-3. 주요 산출물 존재 여부", png="r34_03_final_qa")
missing_output_count = int((w3_final_qa["exists_flag"] == 0).sum())
print(f"NOTE: 주요 산출물 중 누락된 테이블 수 = {missing_output_count}")

# 11. WORK 임시 테이블 개수 기록
work_w3_count = sum(k.startswith("w3_") for k in WORK)
work_fabc_count = sum(k.startswith("fabc_") for k in WORK)
w3_cleanup_log = pd.DataFrame([
    {"cleanup_scope": "WORK.W3_", "cleanup_action": "WORK의 W3_ 임시 테이블 삭제. CRM 영구 테이블은 보존",
     "cleanup_datetime": pd.Timestamp.now(), "temporary_table_count": work_w3_count},
    {"cleanup_scope": "WORK.FABC_", "cleanup_action": "WORK의 FABC_ 임시 테이블 삭제. CRM 영구 테이블은 보존",
     "cleanup_datetime": pd.Timestamp.now(), "temporary_table_count": work_fabc_count}])
save(w3_cleanup_log, "w3_cleanup_log")

# 12. CRM W3_ 영구 테이블 목록
w3_output_catalog = pd.DataFrame(
    [{"table_name": p.stem.upper(), **{k: v for k, v in _table_info(p.stem).items() if k != "exists_flag"}}
     for p in sorted(rc.CRM_DIR.glob("w3_*.pkl"))])
save(w3_output_catalog, "w3_output_catalog")
proc_print(w3_output_catalog, "WBS 3.4-4. CRM W3_ 영구 산출물 목록")

# 13. WORK 임시 테이블 삭제
for _k in [k for k in WORK if k.startswith(("w3_", "fabc_"))]:
    del WORK[_k]
proc_print(pd.DataFrame([{"remaining_work_tables":
                          sum(k.startswith(("w3_", "fabc_")) for k in WORK)}]),
           "WBS 3.4-5. 정리 후 WORK 임시 테이블 확인")

# 14. 3.4 최종 메시지
if missing_output_count == 0:
    rc.note("WBS 3.1부터 3.4까지의 주요 산출물이 모두 존재합니다.",
            "B_DAYS가 Frequency 잠정 공식 후보로 기록되었습니다.",
            "기존 frequency_orders는 삭제하지 않고 보존합니다.",
            "다음 3.5에서 RFMP용 전체기간 frequency_days를 계산하십시오.")
else:
    print("WARNING: 일부 기존 산출물이 존재하지 않습니다. CRM.W3_FINAL_QA 를 확인하십시오.")
if not all(exists(t) for t in ("w3_frequency_policy", "w3_frequency_gate_qa", "w3_final_qa",
                               "w3_cleanup_log", "w3_output_catalog")):
    abort("WBS 3.4 결과 테이블 중 생성되지 않은 것이 있습니다.")


# ======================================================================
# WBS 3.5~3.9 구매일 수 기준 RFM-P 재산출 및 최종 고객 분석 테이블
# ======================================================================

P_METHOD = SAS.symget("P_METHOD")
for _t, _step in [("clean_online", "Week 1 데이터 정제"), ("w2_customer_features", "Week 2 고객 특성 생성"),
                  ("w3_model_input", "WBS 3.1 RFM 데이터 준비"),
                  ("w3_frequency_policy", "WBS 3.4 Frequency 후보 확정"),
                  ("w3_freq_abc_scored", "WBS 3.3 A·B·C 비교")]:
    require_table(_t, _step)

# 3. WBS 3.4 정책 확인
_pol = load("w3_frequency_policy")
_pol = _pol[_pol["policy_id"] == 1].iloc[0]
SELECTED_OPTION = str(_pol["selected_option"]).strip()
OFFICIAL_FREQUENCY = str(_pol["official_frequency_variable"]).strip()
print(f"NOTE: 선택된 Frequency 방법 = {SELECTED_OPTION}")
print(f"NOTE: 공식 Frequency 변수 = {OFFICIAL_FREQUENCY}")
if SELECTED_OPTION.upper() != "B_DAYS":
    abort(f"WBS 3.4에서 B_DAYS가 선택되지 않았습니다. 현재 선택값 = {SELECTED_OPTION}")
if OFFICIAL_FREQUENCY.upper() != "FREQUENCY_DAYS":
    abort(f"공식 Frequency 변수가 frequency_days가 아닙니다. 현재 변수 = {OFFICIAL_FREQUENCY}")
if P_METHOD.upper() not in ("DAYS", "ORDERS"):
    abort("P_METHOD는 DAYS 또는 ORDERS만 가능합니다.")
print("NOTE: WBS 3.4 정책과 P_METHOD 설정을 확인했습니다.")

# 4. 기존 RFMP 결과 보존 (백업이 없거나 0행일 때만 최초 1회 복사)
CURRENT_RFMP_NOBS = nobs("w3_customer_rfmp_py")
OLD_RFMP_REF_NOBS = nobs("w3_customer_rfmp_orders_ref")
CURRENT_WEIGHT_NOBS = nobs("w3_rfmp_weights_py")
OLD_WEIGHT_REF_NOBS = nobs("w3_rfmp_weights_orders_ref")
if CURRENT_RFMP_NOBS > 0 and OLD_RFMP_REF_NOBS == 0:
    save(load("w3_customer_rfmp_py"), "w3_customer_rfmp_orders_ref")
    print("NOTE: 기존 RFMP 고객 결과를 비교용으로 보존했습니다.")
elif OLD_RFMP_REF_NOBS > 0:
    print("NOTE: 기존 RFMP 고객 비교자료가 이미 존재합니다.")
else:
    print("NOTE: 비교할 기존 RFMP 고객 결과가 없습니다.")
if CURRENT_WEIGHT_NOBS > 0 and OLD_WEIGHT_REF_NOBS == 0:
    save(load("w3_rfmp_weights_py"), "w3_rfmp_weights_orders_ref")
    print("NOTE: 기존 RFMP 가중치를 비교용으로 보존했습니다.")
elif OLD_WEIGHT_REF_NOBS > 0:
    print("NOTE: 기존 RFMP 가중치 비교자료가 이미 존재합니다.")
else:
    print("NOTE: 비교할 기존 RFMP 가중치가 없습니다.")
OLD_RFMP_REF_NOBS = nobs("w3_customer_rfmp_orders_ref")
HAS_OLD_RFMP = 1 if OLD_RFMP_REF_NOBS > 0 else 0
SAS.symput("HAS_OLD_RFMP", HAS_OLD_RFMP)
print(f"NOTE: 기존 RFMP 비교자료 존재 여부 = {HAS_OLD_RFMP}")

# 5. 이전 실행 결과 삭제 (ORDERS_REF 비교용 테이블은 삭제하지 않음)
delete("w3_frequency_full_py", "w3_rfmp_category_value_py", "w3_customer_category_p_py",
       "w3_rfmp_base_py", "w3_rfmp_standardized_py", "w3_rfmp_clustered_py", "w3_rfmp_cluster_cv_py",
       "w3_rfmp_weights_py", "w3_customer_rfmp_py", "w3_rfmp_tier_profile_py",
       "w3_rfmp_category_top5_py", "w3_rfmp_method_compare_py", "w3_rfmp_tier_transition_py",
       "w3_customer_analytic_base_py", "w3_rfmp_qa_summary_py", "w3_rfmp_output_catalog_py")

# ---- 6. PROC PYTHON (원문) ------------------------------------------------
# [r3-1.sas 7578~10367행 원문]

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

from sklearn.cluster import KMeans
from sklearn.preprocessing import StandardScaler


# ====================================================================
# 공통 함수
# ====================================================================

def normalize_columns(frame):
    """변수명을 소문자로 바꾸고 앞뒤 공백을 제거합니다."""

    result = frame.copy()

    result.columns = [
        str(column).strip().lower()
        for column in result.columns
    ]

    return result


def require_columns(frame, columns, table_name):
    """필수 변수가 없으면 분석을 중단합니다."""

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


def clean_customer_id(series):
    """고객ID를 문자열로 바꾸고 공백을 제거합니다."""

    return (
        series
        .astype(str)
        .str.strip()
    )


def make_purchase_date_key(series):
    """거래일자를 날짜 단위 비교가 가능한 값으로 변환합니다."""

    if pd.api.types.is_datetime64_any_dtype(series):

        return series.dt.normalize()

    if pd.api.types.is_numeric_dtype(series):

        return pd.to_numeric(
            series,
            errors="coerce"
        )

    converted = pd.to_datetime(
        series,
        errors="coerce"
    )

    return converted.dt.normalize()


def save_sas(frame, table_name):
    """DataFrame을 CRM 라이브러리에 저장합니다."""

    output = frame.reset_index(drop=True).copy()

    for column in output.select_dtypes(
        include=["category"]
    ).columns:

        output[column] = output[column].astype(str)

    SAS.df2sd(
        output,
        dataset=f"crm.{table_name}"
    )


def safe_correlation(frame, first_column, second_column):
    """두 변수의 상관계수를 안전하게 계산합니다."""

    part = frame[
        [first_column, second_column]
    ].dropna()

    if len(part) < 2:
        return np.nan

    if part[first_column].nunique() < 2:
        return np.nan

    if part[second_column].nunique() < 2:
        return np.nan

    return float(
        part[first_column].corr(
            part[second_column]
        )
    )


print("=" * 78)
print("WBS 3.5~3.9 구매일 수 기준 RFM-P 재산출")
print("=" * 78)


# ====================================================================
# 3.5-1. 입력 테이블 불러오기
# ====================================================================

online = normalize_columns(
    SAS.sd2df("crm.clean_online")
)

model_input = normalize_columns(
    SAS.sd2df("crm.w3_model_input")
)

customer_features = normalize_columns(
    SAS.sd2df("crm.w2_customer_features")
)

frequency_policy = normalize_columns(
    SAS.sd2df("crm.w3_frequency_policy")
)

abc_scored = normalize_columns(
    SAS.sd2df("crm.w3_freq_abc_scored")
)


required_online = [
    "customer_id",
    "order_key",
    "transaction_date",
    "product_category",
    "quantity",
    "avg_price",
    "flag_missing_core",
    "flag_return",
    "flag_zero_quantity",
    "flag_invalid_price",
    "flag_customer_unmatched"
]

required_rfm = [
    "customer_id",
    "recency",
    "frequency",
    "monetary"
]

required_abc_scored = [
    "customer_id",
    "model_variant",
    "split_role",
    "actual_churn_flag",
    "churn_probability"
]


require_columns(
    online,
    required_online,
    "CRM.CLEAN_ONLINE"
)

require_columns(
    model_input,
    required_rfm,
    "CRM.W3_MODEL_INPUT"
)

require_columns(
    customer_features,
    ["customer_id"],
    "CRM.W2_CUSTOMER_FEATURES"
)

require_columns(
    frequency_policy,
    [
        "selected_option",
        "official_frequency_variable"
    ],
    "CRM.W3_FREQUENCY_POLICY"
)

require_columns(
    abc_scored,
    required_abc_scored,
    "CRM.W3_FREQ_ABC_SCORED"
)


# ====================================================================
# 3.5-2. 문자형·숫자형 변수 정리
# ====================================================================

online["customer_id"] = clean_customer_id(
    online["customer_id"]
)

online["order_key"] = (
    online["order_key"]
    .astype(str)
    .str.strip()
)

online["product_category"] = (
    online["product_category"]
    .fillna("UNKNOWN")
    .astype(str)
    .str.strip()
)

online["purchase_date_key"] = make_purchase_date_key(
    online["transaction_date"]
)

model_input["customer_id"] = clean_customer_id(
    model_input["customer_id"]
)

customer_features["customer_id"] = clean_customer_id(
    customer_features["customer_id"]
)

abc_scored["customer_id"] = clean_customer_id(
    abc_scored["customer_id"]
)

abc_scored["model_variant"] = (
    abc_scored["model_variant"]
    .astype(str)
    .str.strip()
    .str.upper()
)

abc_scored["split_role"] = (
    abc_scored["split_role"]
    .astype(str)
    .str.strip()
    .str.upper()
)


online_numeric_columns = [
    "quantity",
    "avg_price",
    "flag_missing_core",
    "flag_return",
    "flag_zero_quantity",
    "flag_invalid_price",
    "flag_customer_unmatched"
]

for column in online_numeric_columns:

    online[column] = pd.to_numeric(
        online[column],
        errors="coerce"
    )


for column in [
    "recency",
    "frequency",
    "monetary"
]:

    model_input[column] = pd.to_numeric(
        model_input[column],
        errors="coerce"
    )


for column in [
    "actual_churn_flag",
    "churn_probability"
]:

    abc_scored[column] = pd.to_numeric(
        abc_scored[column],
        errors="coerce"
    )


# ====================================================================
# 3.5-3. 분석에 사용할 유효 거래 선택
#
# 오류 가능성이 높은 행만 제외합니다.
# 대량구매와 고액구매는 실제 거래일 수 있으므로 제외하지 않습니다.
# ====================================================================

valid_mask = (
    online["flag_missing_core"].eq(0)
    & online["flag_return"].eq(0)
    & online["flag_zero_quantity"].eq(0)
    & online["flag_invalid_price"].eq(0)
    & online["flag_customer_unmatched"].eq(0)
    & online["purchase_date_key"].notna()
    & online["customer_id"].ne("")
    & online["order_key"].ne("")
)

valid_online = online.loc[
    valid_mask
].copy()


if len(valid_online) == 0:

    raise ValueError(
        "3.5 계산에 사용할 유효 거래가 없습니다."
    )


valid_online["line_amount"] = (
    valid_online["quantity"]
    * valid_online["avg_price"]
)


# ====================================================================
# 3.5-4. 전체기간 Frequency 재계산
#
# frequency_orders : 서로 다른 주문 수
# frequency_days   : 구매가 발생한 서로 다른 날짜 수
#
# 동일 주문에 여러 상품 행이 있어도 주문은 한 번만 셉니다.
# ====================================================================

order_events = (
    valid_online[
        [
            "customer_id",
            "order_key",
            "purchase_date_key"
        ]
    ]
    .drop_duplicates()
)


frequency_full = (
    order_events
    .groupby(
        "customer_id",
        as_index=False
    )
    .agg(
        frequency_orders=("order_key", "nunique"),
        frequency_days=("purchase_date_key", "nunique")
    )
)


frequency_full["orders_per_purchase_day"] = (
    frequency_full["frequency_orders"]
    / frequency_full["frequency_days"].replace(0, np.nan)
)


frequency_full["official_frequency"] = (
    frequency_full["frequency_days"]
)

frequency_full["official_frequency_name"] = (
    "frequency_days"
)


# 기존 3.1 Frequency와 새로 계산한 주문 수를 비교합니다.
frequency_full = frequency_full.merge(
    model_input[
        ["customer_id", "frequency"]
    ].rename(
        columns={
            "frequency": "frequency_original"
        }
    ),
    on="customer_id",
    how="outer",
    validate="one_to_one"
)


frequency_full["order_count_difference"] = (
    frequency_full["frequency_orders"]
    - frequency_full["frequency_original"]
)


frequency_full["order_count_match"] = np.where(
    frequency_full["order_count_difference"].fillna(1).eq(0),
    1,
    0
)


if (
    frequency_full["frequency_days"]
    > frequency_full["frequency_orders"]
).any():

    raise ValueError(
        "구매일 수가 주문 수보다 큰 고객이 발견되었습니다."
    )


save_sas(
    frequency_full,
    "w3_frequency_full_py"
)


# ====================================================================
# 3.5-5. 카테고리 가치 계산
#
# 두 가지 P를 함께 계산합니다.
#
# ORDERS 방식:
#   카테고리 주문 수 × 카테고리 평균단가
#
# DAYS 방식:
#   카테고리 고객-구매일 발생 수 × 카테고리 평균단가
# ====================================================================

category_order_summary = (
    valid_online
    .groupby(
        "product_category",
        as_index=False,
        dropna=False
    )
    .agg(
        category_order_count=("order_key", "nunique"),
        category_quantity=("quantity", "sum"),
        category_sales=("line_amount", "sum")
    )
)


category_day_events = (
    valid_online[
        [
            "product_category",
            "customer_id",
            "purchase_date_key"
        ]
    ]
    .drop_duplicates()
)


category_day_summary = (
    category_day_events
    .groupby(
        "product_category",
        as_index=False,
        dropna=False
    )
    .agg(
        category_purchase_day_count=(
            "purchase_date_key",
            "size"
        )
    )
)


category_value = category_order_summary.merge(
    category_day_summary,
    on="product_category",
    how="left",
    validate="one_to_one"
)


category_value["category_avg_unit_price"] = (
    category_value["category_sales"]
    / category_value["category_quantity"].replace(
        0,
        np.nan
    )
)


category_value["category_value_raw_orders"] = (
    category_value["category_order_count"]
    * category_value["category_avg_unit_price"]
)


category_value["category_value_raw_days"] = (
    category_value["category_purchase_day_count"]
    * category_value["category_avg_unit_price"]
)


category_value["category_value_score_orders"] = (
    np.ceil(
        category_value["category_value_raw_orders"]
        .rank(method="average", pct=True)
        * 20
    )
    .clip(1, 20)
    .astype(int)
)


category_value["category_value_score_days"] = (
    np.ceil(
        category_value["category_value_raw_days"]
        .rank(method="average", pct=True)
        * 20
    )
    .clip(1, 20)
    .astype(int)
)


p_method = str(
    SAS.symget("P_METHOD")
).strip().upper()


if p_method == "DAYS":

    category_value["category_value_raw"] = (
        category_value["category_value_raw_days"]
    )

    category_value["category_value_score"] = (
        category_value["category_value_score_days"]
    )

else:

    category_value["category_value_raw"] = (
        category_value["category_value_raw_orders"]
    )

    category_value["category_value_score"] = (
        category_value["category_value_score_orders"]
    )


category_value["official_p_method"] = p_method

category_value = category_value.sort_values(
    [
        "category_value_score",
        "category_value_raw"
    ],
    ascending=[True, True]
).reset_index(drop=True)


# ====================================================================
# 3.5-6. 고객별 제품가치 P 계산
# ====================================================================

customer_category_orders = (
    valid_online
    .groupby(
        [
            "customer_id",
            "product_category"
        ],
        as_index=False,
        dropna=False
    )
    .agg(
        customer_category_orders=(
            "order_key",
            "nunique"
        )
    )
)


customer_category_days = (
    valid_online[
        [
            "customer_id",
            "product_category",
            "purchase_date_key"
        ]
    ]
    .drop_duplicates()
    .groupby(
        [
            "customer_id",
            "product_category"
        ],
        as_index=False,
        dropna=False
    )
    .agg(
        customer_category_days=(
            "purchase_date_key",
            "size"
        )
    )
)


customer_category_p = (
    customer_category_orders
    .merge(
        customer_category_days,
        on=[
            "customer_id",
            "product_category"
        ],
        how="outer",
        validate="one_to_one"
    )
    .merge(
        category_value[
            [
                "product_category",
                "category_value_score_orders",
                "category_value_score_days",
                "category_value_score"
            ]
        ],
        on="product_category",
        how="left",
        validate="many_to_one"
    )
)


customer_category_p[
    "category_p_contribution_orders"
] = (
    customer_category_p["customer_category_orders"]
    * customer_category_p["category_value_score_orders"]
)


customer_category_p[
    "category_p_contribution_days"
] = (
    customer_category_p["customer_category_days"]
    * customer_category_p["category_value_score_days"]
)


if p_method == "DAYS":

    customer_category_p[
        "category_p_contribution"
    ] = customer_category_p[
        "category_p_contribution_days"
    ]

else:

    customer_category_p[
        "category_p_contribution"
    ] = customer_category_p[
        "category_p_contribution_orders"
    ]


customer_category_p["official_p_method"] = p_method


customer_p = (
    customer_category_p
    .groupby(
        "customer_id",
        as_index=False
    )
    .agg(
        product_value_p_orders=(
            "category_p_contribution_orders",
            "sum"
        ),
        product_value_p_days=(
            "category_p_contribution_days",
            "sum"
        ),
        product_value_p=(
            "category_p_contribution",
            "sum"
        ),
        p_category_count=(
            "product_category",
            "nunique"
        )
    )
)


customer_p["official_p_method"] = p_method


# ====================================================================
# 3.5-7. RFMP 기본 테이블 생성
# ====================================================================

rfmp_base = (
    model_input[
        [
            "customer_id",
            "recency",
            "frequency",
            "monetary"
        ]
    ]
    .rename(
        columns={
            "frequency": "frequency_original"
        }
    )
    .merge(
        frequency_full[
            [
                "customer_id",
                "frequency_orders",
                "frequency_days",
                "orders_per_purchase_day"
            ]
        ],
        on="customer_id",
        how="left",
        validate="one_to_one"
    )
    .merge(
        customer_p,
        on="customer_id",
        how="left",
        validate="one_to_one"
    )
)


numeric_fill_columns = [
    "frequency_orders",
    "frequency_days",
    "orders_per_purchase_day",
    "product_value_p_orders",
    "product_value_p_days",
    "product_value_p",
    "p_category_count"
]

for column in numeric_fill_columns:

    rfmp_base[column] = (
        pd.to_numeric(
            rfmp_base[column],
            errors="coerce"
        )
        .fillna(0)
    )


#공식 Frequency의 호환 변수입니다.
rfmp_base["frequency"] = (
    rfmp_base["frequency_days"]
)

rfmp_base["official_frequency_name"] = (
    "frequency_days"
)

rfmp_base["official_p_method"] = p_method


required_rfmp_numeric = [
    "recency",
    "frequency",
    "frequency_orders",
    "frequency_days",
    "monetary",
    "product_value_p"
]


if rfmp_base["customer_id"].duplicated().any():

    raise ValueError(
        "RFMP 기본 테이블에 중복 고객ID가 있습니다."
    )


if rfmp_base[required_rfmp_numeric].isna().any().any():

    raise ValueError(
        "RFMP 필수 변수에 결측값이 있습니다."
    )


if not np.isfinite(
    rfmp_base[
        required_rfmp_numeric
    ].to_numpy(dtype=float)
).all():

    raise ValueError(
        "RFMP 필수 변수에 무한대 값이 있습니다."
    )


if (rfmp_base["recency"] < 0).any():

    raise ValueError(
        "Recency에 음수가 있습니다."
    )


if (rfmp_base["frequency"] <= 0).any():

    raise ValueError(
        "공식 Frequency에 0 이하 값이 있습니다."
    )


if (rfmp_base["monetary"] < 0).any():

    raise ValueError(
        "Monetary에 음수가 있습니다."
    )


rfmp_base["log_frequency"] = np.log1p(
    rfmp_base["frequency"].clip(lower=0)
)

rfmp_base["log_monetary"] = np.log1p(
    rfmp_base["monetary"].clip(lower=0)
)

rfmp_base["log_product_value_p"] = np.log1p(
    rfmp_base["product_value_p"].clip(lower=0)
)


save_sas(
    category_value,
    "w3_rfmp_category_value_py"
)

save_sas(
    customer_category_p,
    "w3_customer_category_p_py"
)

save_sas(
    rfmp_base,
    "w3_rfmp_base_py"
)


print("\n[3.5 완료]")

print(
    f"유효 거래 행: {len(valid_online):,}"
)

print(
    f"RFMP 고객 수: {len(rfmp_base):,}"
)

print(
    "공식 Frequency: frequency_days"
)

print(
    f"공식 P 계산방법: {p_method}"
)


# ====================================================================
# 3.6. 지표별 K-means 및 CV 기반 가중치 계산
#
# 고정 군집 수
#   R=3, F=4, M=2, P=4
#
# F와 P가 변경되었으므로 기존 가중치를 재사용하지 않습니다.
# ====================================================================

metric_configs = {

    "R": {
        "original": "recency",
        "cluster_input": "recency",
        "cv_input": "recency_cv_value",
        "k": 3
    },

    "F": {
        "original": "frequency",
        "cluster_input": "log_frequency",
        "cv_input": "log_frequency",
        "k": 4
    },

    "M": {
        "original": "monetary",
        "cluster_input": "log_monetary",
        "cv_input": "log_monetary",
        "k": 2
    },

    "P": {
        "original": "product_value_p",
        "cluster_input": "log_product_value_p",
        "cv_input": "log_product_value_p",
        "k": 4
    }
}


rfmp_base["recency_cv_value"] = (
    rfmp_base["recency"] + 1
)


rfmp_standardized = rfmp_base[
    [
        "customer_id",
        "recency",
        "frequency",
        "frequency_orders",
        "frequency_days",
        "monetary",
        "product_value_p",
        "product_value_p_orders",
        "product_value_p_days"
    ]
].copy()


rfmp_clustered = rfmp_base.copy()

cluster_cv_rows = []


for metric, config in metric_configs.items():

    input_column = config["cluster_input"]
    cv_column = config["cv_input"]
    k = int(config["k"])

    input_values = (
        rfmp_base[input_column]
        .to_numpy(dtype=float)
        .reshape(-1, 1)
    )

    scaler = StandardScaler()

    z_values = (
        scaler
        .fit_transform(input_values)
        .ravel()
    )

    model = KMeans(
        n_clusters=k,
        random_state=2026,
        n_init=50,
        max_iter=500
    )

    raw_cluster = model.fit_predict(
        z_values.reshape(-1, 1)
    )

    center_order = np.argsort(
        model.cluster_centers_.ravel()
    )

    cluster_map = {
        int(raw_number): int(order + 1)
        for order, raw_number
        in enumerate(center_order)
    }

    ordered_cluster = np.array(
        [
            cluster_map[int(value)]
            for value in raw_cluster
        ],
        dtype=int
    )

    metric_lower = metric.lower()

    rfmp_standardized[
        f"z_{metric_lower}"
    ] = z_values

    rfmp_clustered[
        f"{metric_lower}_cluster"
    ] = ordered_cluster

    cv_values = (
        rfmp_base[cv_column]
        .to_numpy(dtype=float)
    )

    for cluster_number in range(1, k + 1):

        cluster_values = cv_values[
            ordered_cluster == cluster_number
        ]

        cluster_n = int(
            len(cluster_values)
        )

        mean_value = float(
            np.mean(cluster_values)
        )

        if cluster_n > 1:

            std_value = float(
                np.std(
                    cluster_values,
                    ddof=1
                )
            )

        else:

            std_value = 0.0

        if np.isclose(mean_value, 0.0):

            cv_value = np.nan

        else:

            cv_value = float(
                std_value / abs(mean_value)
            )

        cluster_cv_rows.append({

            "metric": metric,
            "cluster": cluster_number,
            "cluster_n": cluster_n,
            "mean_value": mean_value,
            "std_value": std_value,
            "cv": cv_value,
            "cluster_input": input_column,
            "k": k

        })


cluster_cv = pd.DataFrame(
    cluster_cv_rows
)


weight_rows = []


for metric in ["R", "F", "M", "P"]:

    # 값이 모두 같은 군집(CV=0)은 제외한다. 구매한 날 수처럼 띄엄띄엄한 지표는
    # 1일·2일 군집의 CV가 0이 되어, 일관성과 무관하게 가중치가 커지기 때문이다.
    part = cluster_cv.loc[
        (cluster_cv["metric"] == metric)
        & cluster_cv["cv"].notna()
        & (cluster_cv["cv"] > 1e-9)
    ].copy()

    if len(part) == 0:

        raise ValueError(
            f"{metric} 지표의 CV를 계산할 수 없습니다."
        )

    weighted_cv = float(
        np.average(
            part["cv"],
            weights=part["cluster_n"]
        )
    )

    if weighted_cv <= 0:

        raise ValueError(
            f"{metric} 지표의 가중평균 CV가 0 이하입니다."
        )

    weight_rows.append({

        "metric": metric,
        "k": int(
            metric_configs[metric]["k"]
        ),
        "weighted_cv": weighted_cv,
        "raw_weight": float(
            1.0 / weighted_cv
        )

    })


rfmp_weights = pd.DataFrame(
    weight_rows
)


rfmp_weights["final_weight"] = (
    rfmp_weights["raw_weight"]
    / rfmp_weights["raw_weight"].sum()
)


rfmp_weights["frequency_definition"] = (
    "frequency_days"
)

rfmp_weights["p_method"] = p_method


save_sas(
    rfmp_standardized,
    "w3_rfmp_standardized_py"
)

save_sas(
    rfmp_clustered,
    "w3_rfmp_clustered_py"
)

save_sas(
    cluster_cv,
    "w3_rfmp_cluster_cv_py"
)

save_sas(
    rfmp_weights,
    "w3_rfmp_weights_py"
)


print("\n[3.6 R/F/M/P 최종 가중치]")

print(
    rfmp_weights[
        [
            "metric",
            "k",
            "weighted_cv",
            "raw_weight",
            "final_weight"
        ]
    ]
    .round(6)
    .to_string(index=False)
)


# 지표별 1차원 군집 분포
fig, axes = plt.subplots(
    2,
    2,
    figsize=(13, 8)
)


for ax, metric in zip(
    axes.ravel(),
    ["R", "F", "M", "P"]
):

    config = metric_configs[metric]

    original_column = (
        config["original"]
    )

    cluster_column = (
        f"{metric.lower()}_cluster"
    )

    cluster_numbers = sorted(
        rfmp_clustered[
            cluster_column
        ].unique()
    )

    for cluster_number in cluster_numbers:

        values = rfmp_clustered.loc[
            rfmp_clustered[
                cluster_column
            ] == cluster_number,
            original_column
        ]

        ax.hist(
            values,
            bins=25,
            alpha=0.55,
            label=f"Cluster {cluster_number}"
        )

    ax.set_title(
        f"{metric} 1D K-Means"
    )

    ax.set_xlabel(
        original_column
    )

    ax.set_ylabel(
        "Customers"
    )

    ax.legend(
        fontsize=8
    )


plt.tight_layout()

SAS.pyplot(plt)

plt.close(fig)


# ====================================================================
# 3.7. RFMP 점수와 6개 고객등급 산출
#
# R은 작을수록 높은 점수입니다.
# F·M·P는 클수록 높은 점수입니다.
# ====================================================================

weight_map = dict(
    zip(
        rfmp_weights["metric"],
        rfmp_weights["final_weight"]
    )
)


customer_rfmp = (
    rfmp_clustered
    .sort_values("customer_id")
    .reset_index(drop=True)
    .copy()
)


customer_rfmp["r_score"] = (
    customer_rfmp["recency"]
    .rank(
        method="average",
        ascending=False,
        pct=True
    )
    * 100
)


customer_rfmp["f_score"] = (
    customer_rfmp["frequency"]
    .rank(
        method="average",
        ascending=True,
        pct=True
    )
    * 100
)


customer_rfmp["m_score"] = (
    customer_rfmp["monetary"]
    .rank(
        method="average",
        ascending=True,
        pct=True
    )
    * 100
)


customer_rfmp["p_score"] = (
    customer_rfmp["product_value_p"]
    .rank(
        method="average",
        ascending=True,
        pct=True
    )
    * 100
)


customer_rfmp["rfmp_score"] = (

    customer_rfmp["r_score"]
    * weight_map["R"]

    + customer_rfmp["f_score"]
    * weight_map["F"]

    + customer_rfmp["m_score"]
    * weight_map["M"]

    + customer_rfmp["p_score"]
    * weight_map["P"]

)


tier_labels_low_to_high = [
    "Bronze",
    "Silver",
    "Gold",
    "Platinum",
    "Diamond",
    "VIP"
]


score_order = (
    customer_rfmp["rfmp_score"]
    .rank(
        method="first",
        ascending=True
    )
)


customer_rfmp["rfmp_tier"] = pd.qcut(
    score_order,
    q=6,
    labels=tier_labels_low_to_high
).astype(str)


tier_code_map = {
    "VIP": 1,
    "Diamond": 2,
    "Platinum": 3,
    "Gold": 4,
    "Silver": 5,
    "Bronze": 6
}


customer_rfmp["tier_code"] = (
    customer_rfmp["rfmp_tier"]
    .map(tier_code_map)
    .astype(int)
)


customer_rfmp["frequency_definition"] = (
    "frequency_days"
)

customer_rfmp["p_method"] = p_method


customer_rfmp = customer_rfmp.sort_values(
    [
        "tier_code",
        "rfmp_score"
    ],
    ascending=[
        True,
        False
    ]
).reset_index(drop=True)


save_sas(
    customer_rfmp,
    "w3_customer_rfmp_py"
)


tier_count_result = (
    customer_rfmp
    .groupby(
        [
            "tier_code",
            "rfmp_tier"
        ],
        as_index=False
    )
    .agg(
        customer_count=(
            "customer_id",
            "nunique"
        )
    )
    .sort_values("tier_code")
)


print("\n[3.7 RFMP 등급별 고객 수]")

print(
    tier_count_result.to_string(
        index=False
    )
)


# ====================================================================
# 3.8-1. 등급별 RFMP 프로파일
# ====================================================================

tier_profile = (
    customer_rfmp
    .groupby(
        [
            "tier_code",
            "rfmp_tier"
        ],
        as_index=False
    )
    .agg(
        customer_count=(
            "customer_id",
            "nunique"
        ),
        avg_recency=(
            "recency",
            "mean"
        ),
        avg_frequency_days=(
            "frequency_days",
            "mean"
        ),
        avg_frequency_orders=(
            "frequency_orders",
            "mean"
        ),
        avg_orders_per_day=(
            "orders_per_purchase_day",
            "mean"
        ),
        avg_monetary=(
            "monetary",
            "mean"
        ),
        avg_product_value_p=(
            "product_value_p",
            "mean"
        ),
        avg_p_orders=(
            "product_value_p_orders",
            "mean"
        ),
        avg_p_days=(
            "product_value_p_days",
            "mean"
        ),
        avg_rfmp_score=(
            "rfmp_score",
            "mean"
        ),
        min_rfmp_score=(
            "rfmp_score",
            "min"
        ),
        max_rfmp_score=(
            "rfmp_score",
            "max"
        )
    )
    .sort_values("tier_code")
)


tier_profile["customer_pct"] = (
    tier_profile["customer_count"]
    / tier_profile["customer_count"].sum()
    * 100
)


tier_profile["frequency_definition"] = (
    "frequency_days"
)

tier_profile["p_method"] = p_method


# ====================================================================
# 3.8-2. 등급별 대표 카테고리 Top 5
#
# 구매일 발생 횟수를 기준으로 Lift를 계산합니다.
# 주문 수와 매출도 참고용으로 함께 보존합니다.
# ====================================================================

tier_transactions = valid_online.merge(
    customer_rfmp[
        [
            "customer_id",
            "tier_code",
            "rfmp_tier"
        ]
    ],
    on="customer_id",
    how="inner",
    validate="many_to_one"
)


tier_category_orders = (
    tier_transactions
    .groupby(
        [
            "tier_code",
            "rfmp_tier",
            "product_category"
        ],
        as_index=False,
        dropna=False
    )
    .agg(
        category_orders=(
            "order_key",
            "nunique"
        ),
        category_customers=(
            "customer_id",
            "nunique"
        ),
        category_sales=(
            "line_amount",
            "sum"
        )
    )
)


tier_category_days = (
    tier_transactions[
        [
            "tier_code",
            "rfmp_tier",
            "product_category",
            "customer_id",
            "purchase_date_key"
        ]
    ]
    .drop_duplicates()
    .groupby(
        [
            "tier_code",
            "rfmp_tier",
            "product_category"
        ],
        as_index=False,
        dropna=False
    )
    .agg(
        category_purchase_days=(
            "purchase_date_key",
            "size"
        )
    )
)


tier_category = tier_category_orders.merge(
    tier_category_days,
    on=[
        "tier_code",
        "rfmp_tier",
        "product_category"
    ],
    how="left",
    validate="one_to_one"
)


tier_totals = (
    tier_category
    .groupby(
        [
            "tier_code",
            "rfmp_tier"
        ],
        as_index=False
    )
    .agg(
        tier_purchase_day_sum=(
            "category_purchase_days",
            "sum"
        )
    )
)


overall_category = (
    tier_category
    .groupby(
        "product_category",
        as_index=False
    )
    .agg(
        overall_purchase_days=(
            "category_purchase_days",
            "sum"
        )
    )
)


overall_purchase_day_sum = float(
    overall_category[
        "overall_purchase_days"
    ].sum()
)


tier_category = (
    tier_category
    .merge(
        tier_totals,
        on=[
            "tier_code",
            "rfmp_tier"
        ],
        how="left",
        validate="many_to_one"
    )
    .merge(
        overall_category,
        on="product_category",
        how="left",
        validate="many_to_one"
    )
)


tier_category["tier_category_share"] = (
    tier_category["category_purchase_days"]
    / tier_category[
        "tier_purchase_day_sum"
    ].replace(0, np.nan)
)


tier_category["overall_category_share"] = (
    tier_category["overall_purchase_days"]
    / overall_purchase_day_sum
)


tier_category["lift"] = (
    tier_category["tier_category_share"]
    / tier_category[
        "overall_category_share"
    ].replace(0, np.nan)
)


#구매일 발생이 5회 이상인 카테고리만
#대표 카테고리 후보로 사용합니다.

top5_candidates = tier_category.loc[
    tier_category[
        "category_purchase_days"
    ] >= 5
].copy()


top5 = (
    top5_candidates
    .sort_values(
        [
            "tier_code",
            "lift",
            "category_purchase_days",
            "product_category"
        ],
        ascending=[
            True,
            False,
            False,
            True
        ]
    )
    .copy()
)


top5["category_rank"] = (
    top5
    .groupby("tier_code")
    .cumcount()
    + 1
)


top5 = top5.loc[
    top5["category_rank"] <= 5
].reset_index(drop=True)


top5["ranking_basis"] = (
    "purchase_day_lift"
)


save_sas(
    tier_profile,
    "w3_rfmp_tier_profile_py"
)

save_sas(
    top5,
    "w3_rfmp_category_top5_py"
)


print("\n[3.8 RFMP 등급 프로파일]")

print(
    tier_profile
    .round(2)
    .to_string(index=False)
)


print(
    "\n[3.8 등급별 대표 카테고리 Top 5]"
)

print(
    top5[
        [
            "tier_code",
            "rfmp_tier",
            "category_rank",
            "product_category",
            "category_purchase_days",
            "category_orders",
            "lift"
        ]
    ]
    .round(3)
    .to_string(index=False)
)


# ====================================================================
# 3.8-3. RFMP 등급별 점수 분포 그래프
# ====================================================================

tier_order = [
    "VIP",
    "Diamond",
    "Platinum",
    "Gold",
    "Silver",
    "Bronze"
]


box_values = [
    customer_rfmp.loc[
        customer_rfmp["rfmp_tier"] == tier,
        "rfmp_score"
    ].to_numpy()
    for tier in tier_order
]


fig, ax = plt.subplots(
    figsize=(10, 5)
)


ax.boxplot(
    box_values,
    showfliers=False
)

ax.set_xticks(
    range(1, len(tier_order) + 1)
)

ax.set_xticklabels(
    tier_order
)


ax.set_title(
    "RFMP Score by Customer Tier"
)

ax.set_xlabel(
    "RFMP Tier"
)

ax.set_ylabel(
    "RFMP Score"
)

ax.grid(
    axis="y",
    alpha=0.3
)


plt.tight_layout()

SAS.pyplot(plt)

plt.close(fig)


# ====================================================================
# 3.8-4. 등급별 대표 카테고리 그래프
# ====================================================================

fig, axes = plt.subplots(
    3,
    2,
    figsize=(14, 14)
)


for ax, tier in zip(
    axes.ravel(),
    tier_order
):

    part = (
        top5.loc[
            top5["rfmp_tier"] == tier
        ]
        .sort_values(
            "lift",
            ascending=True
        )
    )

    ax.barh(
        part["product_category"],
        part["lift"],
        color="steelblue"
    )

    ax.axvline(
        1,
        color="red",
        linestyle="--",
        linewidth=1
    )

    ax.set_title(tier)
    ax.set_xlabel("Lift")
    ax.set_ylabel("")


plt.suptitle(
    "Top Categories by Purchase-Day Lift",
    y=1.01
)

plt.tight_layout()

SAS.pyplot(plt)

plt.close(fig)


# ====================================================================
# 3.9-1. 기존 방식과 변경 방식 비교
# ====================================================================

frequency_correlation = safe_correlation(
    rfmp_base,
    "frequency_orders",
    "frequency_days"
)

p_correlation = safe_correlation(
    rfmp_base,
    "product_value_p_orders",
    "product_value_p_days"
)

old_fp_correlation = safe_correlation(
    rfmp_base,
    "frequency_orders",
    "product_value_p_orders"
)

new_fp_correlation = safe_correlation(
    rfmp_base,
    "frequency_days",
    "product_value_p_days"
)


average_order_day_ratio = float(
    rfmp_base[
        "orders_per_purchase_day"
    ].mean()
)


method_compare = pd.DataFrame([

    {
        "comparison_name":
            "frequency_orders vs frequency_days",
        "value":
            frequency_correlation,
        "interpretation":
            "기존 주문 수와 구매일 수의 상관관계"
    },

    {
        "comparison_name":
            "P_orders vs P_days",
        "value":
            p_correlation,
        "interpretation":
            "주문 기준 P와 구매일 기준 P의 상관관계"
    },

    {
        "comparison_name":
            "old F-P correlation",
        "value":
            old_fp_correlation,
        "interpretation":
            "기존 주문 수와 주문 기준 P의 상관관계"
    },

    {
        "comparison_name":
            "new F-P correlation",
        "value":
            new_fp_correlation,
        "interpretation":
            "구매일 수와 구매일 기준 P의 상관관계"
    },

    {
        "comparison_name":
            "average orders per purchase day",
        "value":
            average_order_day_ratio,
        "interpretation":
            "구매일 하루당 평균 주문 수"
    }

])


method_compare["official_frequency"] = (
    "frequency_days"
)

method_compare["official_p_method"] = (
    p_method
)


save_sas(
    method_compare,
    "w3_rfmp_method_compare_py"
)


# ====================================================================
# 3.9-2. 기존 RFMP 등급과 변경 등급 비교
#
# 기존 백업이 있을 때만 고객별 등급 이동표를 만듭니다.
# ====================================================================

has_old_rfmp = str(
    SAS.symget("HAS_OLD_RFMP")
).strip() == "1"


tier_changed_count = np.nan
tier_transition_created = False


if has_old_rfmp:

    old_rfmp = normalize_columns(
        SAS.sd2df(
            "crm.w3_customer_rfmp_orders_ref"
        )
    )

    require_columns(
        old_rfmp,
        [
            "customer_id",
            "rfmp_tier",
            "tier_code"
        ],
        "CRM.W3_CUSTOMER_RFMP_ORDERS_REF"
    )

    old_rfmp["customer_id"] = clean_customer_id(
        old_rfmp["customer_id"]
    )

    old_columns = [
        "customer_id",
        "rfmp_tier",
        "tier_code"
    ]

    if "rfmp_score" in old_rfmp.columns:

        old_columns.append(
            "rfmp_score"
        )


    old_selected = old_rfmp[
        old_columns
    ].copy()


    rename_map = {
        "rfmp_tier": "old_rfmp_tier",
        "tier_code": "old_tier_code",
        "rfmp_score": "old_rfmp_score"
    }


    old_selected = old_selected.rename(
        columns=rename_map
    )


    tier_transition = (
        customer_rfmp[
            [
                "customer_id",
                "rfmp_tier",
                "tier_code",
                "rfmp_score",
                "frequency_orders",
                "frequency_days",
                "product_value_p_orders",
                "product_value_p_days"
            ]
        ]
        .rename(
            columns={
                "rfmp_tier":
                    "new_rfmp_tier",
                "tier_code":
                    "new_tier_code",
                "rfmp_score":
                    "new_rfmp_score"
            }
        )
        .merge(
            old_selected,
            on="customer_id",
            how="inner",
            validate="one_to_one"
        )
    )


    tier_transition["tier_changed"] = np.where(
        tier_transition["old_rfmp_tier"]
        != tier_transition["new_rfmp_tier"],
        1,
        0
    )


    tier_transition["tier_step_change"] = (
        tier_transition["new_tier_code"]
        - tier_transition["old_tier_code"]
    )


    tier_transition[
        "absolute_tier_step_change"
    ] = (
        tier_transition[
            "tier_step_change"
        ].abs()
    )


    tier_changed_count = int(
        tier_transition["tier_changed"].sum()
    )


    save_sas(
        tier_transition,
        "w3_rfmp_tier_transition_py"
    )


    tier_transition_created = True


    print(
        "\n[기존 방식 대비 등급 변경]"
    )

    print(
        f"비교 고객: {len(tier_transition):,}"
    )

    print(
        f"등급 변경 고객: {tier_changed_count:,}"
    )

    print(
        "등급 변경률: "
        f"{tier_transition['tier_changed'].mean() * 100:.2f}%"
    )


else:

    print(
        "\n기존 RFMP 백업이 없어 등급 이동 비교를 생략합니다."
    )


# ====================================================================
# 3.9-3. B_DAYS VALID 이탈예측 후보 결합
#
# 이 확률은 비교모형의 후보 결과입니다.
# 절대 위험확률로 확정하지 않습니다.
# ====================================================================

b_days_valid = abc_scored.loc[
    (abc_scored["model_variant"] == "B_DAYS")
    & (abc_scored["split_role"] == "VALID")
].copy()


if len(b_days_valid) == 0:

    raise ValueError(
        "W3_FREQ_ABC_SCORED에 B_DAYS VALID 결과가 없습니다."
    )


if b_days_valid["customer_id"].duplicated().any():

    raise ValueError(
        "B_DAYS VALID 결과에 중복 고객ID가 있습니다."
    )


candidate_columns = [
    "customer_id",
    "actual_churn_flag",
    "churn_probability"
]


if "risk_rank" in b_days_valid.columns:

    candidate_columns.append(
        "risk_rank"
    )


b_days_valid = b_days_valid[
    candidate_columns
].copy()


b_days_valid = b_days_valid.rename(
    columns={
        "actual_churn_flag":
            "actual_churn_flag_b_days",
        "churn_probability":
            "churn_probability_b_days",
        "risk_rank":
            "risk_rank_b_days"
    }
)


b_days_valid[
    "churn_model_status"
] = "B_DAYS_CANDIDATE"


# ====================================================================
# 3.9-4. 최종 고객 분석 테이블 생성
# ====================================================================

customer_features_for_merge = (
    customer_features.copy()
)


# W2의 기존 frequency는 주문 수에 해당할 수 있으므로
# 이름을 바꿔 보존합니다.
if "frequency" in customer_features_for_merge.columns:

    customer_features_for_merge = (
        customer_features_for_merge.rename(
            columns={
                "frequency":
                    "frequency_orders_w2"
            }
        )
    )


rfmp_add_columns = [
    "customer_id",
    "recency",
    "frequency_orders",
    "frequency_days",
    "orders_per_purchase_day",
    "monetary",
    "product_value_p_orders",
    "product_value_p_days",
    "product_value_p",
    "p_category_count",
    "r_cluster",
    "f_cluster",
    "m_cluster",
    "p_cluster",
    "r_score",
    "f_score",
    "m_score",
    "p_score",
    "rfmp_score",
    "tier_code",
    "rfmp_tier",
    "frequency_definition",
    "p_method"
]


# 동일 이름의 변수가 W2에 있으면 기존 변수임을 표시합니다.
for column in rfmp_add_columns:

    if (
        column != "customer_id"
        and column
        in customer_features_for_merge.columns
    ):

        customer_features_for_merge = (
            customer_features_for_merge.rename(
                columns={
                    column:
                        f"{column}_w2"
                }
            )
        )


analytic_base = (
    customer_features_for_merge
    .merge(
        customer_rfmp[
            rfmp_add_columns
        ],
        on="customer_id",
        how="left",
        validate="one_to_one"
    )
    .merge(
        b_days_valid,
        on="customer_id",
        how="left",
        validate="one_to_one"
    )
)


# 하위 코드와의 호환을 위한 공식 Frequency 별칭
analytic_base["frequency"] = (
    analytic_base["frequency_days"]
)


analytic_base[
    "official_frequency_name"
] = "frequency_days"


analytic_base[
    "official_p_method"
] = p_method


save_sas(
    analytic_base,
    "w3_customer_analytic_base_py"
)


# ====================================================================
# 3.9-5. 자동 품질 점검
# ====================================================================

qa_rows = []


def add_qa(
    check_order,
    check_item,
    actual_value,
    expected_value,
    passed,
    detail,
    review_only=False
):

    if passed:

        status = "PASS"

    elif review_only:

        status = "REVIEW"

    else:

        status = "FAIL"

    qa_rows.append({

        "check_order":
            int(check_order),

        "check_item":
            str(check_item),

        "actual_value":
            str(actual_value),

        "expected_value":
            str(expected_value),

        "status":
            status,

        "detail":
            str(detail)

    })


input_customer_count = int(
    model_input["customer_id"].nunique()
)

rfmp_row_count = int(
    len(customer_rfmp)
)

rfmp_unique_customer_count = int(
    customer_rfmp[
        "customer_id"
    ].nunique()
)

missing_frequency_count = int(
    customer_rfmp[
        "frequency_days"
    ].isna().sum()
)

frequency_order_violation = int(
    (
        customer_rfmp["frequency_days"]
        > customer_rfmp["frequency_orders"]
    ).sum()
)

order_count_mismatch = int(
    (
        frequency_full[
            "order_count_match"
        ] == 0
    ).sum()
)

missing_p_count = int(
    customer_rfmp[
        "product_value_p"
    ].isna().sum()
)

missing_tier_count = int(
    customer_rfmp[
        "rfmp_tier"
    ].isna().sum()
)

tier_count = int(
    customer_rfmp[
        "rfmp_tier"
    ].nunique()
)

weight_sum = float(
    rfmp_weights[
        "final_weight"
    ].sum()
)

top5_row_count = int(
    len(top5)
)

joined_churn_count = int(
    analytic_base[
        "churn_probability_b_days"
    ].notna().sum()
)

expected_churn_count = int(
    len(b_days_valid)
)


add_qa(
    1,
    "Frequency 정책",
    "B_DAYS",
    "B_DAYS",
    True,
    "WBS 3.4에서 선택한 Frequency 정책을 적용했습니다."
)


add_qa(
    2,
    "RFMP 행 수",
    rfmp_row_count,
    input_customer_count,
    rfmp_row_count == input_customer_count,
    "입력 고객 수와 RFMP 고객 수가 같아야 합니다."
)


add_qa(
    3,
    "RFMP 고객ID 고유성",
    rfmp_unique_customer_count,
    rfmp_row_count,
    rfmp_unique_customer_count
        == rfmp_row_count,
    "고객 한 명당 RFMP 결과 한 행이어야 합니다."
)


add_qa(
    4,
    "frequency_days 결측",
    missing_frequency_count,
    0,
    missing_frequency_count == 0,
    "공식 Frequency에 결측이 없어야 합니다."
)


add_qa(
    5,
    "구매일 수가 주문 수보다 큰 고객",
    frequency_order_violation,
    0,
    frequency_order_violation == 0,
    "구매일 수는 주문 수보다 클 수 없습니다."
)


add_qa(
    6,
    "기존 Frequency와 재계산 주문 수 불일치",
    order_count_mismatch,
    0,
    order_count_mismatch == 0,
    "불일치가 있으면 기존 Frequency의 집계 범위를 확인합니다.",
    review_only=True
)


add_qa(
    7,
    "제품가치 P 결측",
    missing_p_count,
    0,
    missing_p_count == 0,
    "공식 P에 결측이 없어야 합니다."
)


add_qa(
    8,
    "RFMP 등급 결측",
    missing_tier_count,
    0,
    missing_tier_count == 0,
    "모든 고객에게 RFMP 등급이 있어야 합니다."
)


add_qa(
    9,
    "RFMP 등급 개수",
    tier_count,
    6,
    tier_count == 6,
    "VIP부터 Bronze까지 6개 등급이어야 합니다."
)


add_qa(
    10,
    "R/F/M/P 가중치 합",
    round(weight_sum, 10),
    1,
    np.isclose(
        weight_sum,
        1.0,
        atol=1e-10
    ),
    "최종 가중치 합은 1이어야 합니다."
)


add_qa(
    11,
    "대표 카테고리 행 수",
    top5_row_count,
    "1~30",
    (
        top5_row_count > 0
        and top5_row_count <= 30
    ),
    "6개 등급별 최대 5개 카테고리입니다."
)


add_qa(
    12,
    "B_DAYS VALID 예측결과 결합",
    joined_churn_count,
    expected_churn_count,
    joined_churn_count
        == expected_churn_count,
    "B_DAYS VALID 고객의 예측결과가 모두 결합되어야 합니다."
)


add_qa(
    13,
    "F와 P의 상관관계",
    round(new_fp_correlation, 4),
    "절대값 0.90 미만 권고",
    (
        pd.notna(new_fp_correlation)
        and abs(new_fp_correlation) < 0.90
    ),
    "상관이 지나치게 높으면 F와 P의 중복 반영을 검토합니다.",
    review_only=True
)


if tier_transition_created:

    transition_rate = float(
        tier_changed_count
        / len(tier_transition)
        * 100
    )

    add_qa(
        14,
        "기존 방식 대비 등급 변경률",
        round(transition_rate, 2),
        "해석 대상",
        True,
        "오류 기준이 아니라 변경 영향 확인용 지표입니다."
    )


qa_summary = (
    pd.DataFrame(qa_rows)
    .sort_values("check_order")
    .reset_index(drop=True)
)


save_sas(
    qa_summary,
    "w3_rfmp_qa_summary_py"
)


# ====================================================================
# 3.9-6. 산출물 목록
# ====================================================================

catalog_rows = [

    (
        "W3_FREQUENCY_FULL_PY",
        "고객",
        "전체기간 주문 수·구매일 수 및 일치 여부"
    ),

    (
        "W3_RFMP_CATEGORY_VALUE_PY",
        "제품카테고리",
        "주문 기준·구매일 기준 카테고리 가치"
    ),

    (
        "W3_CUSTOMER_CATEGORY_P_PY",
        "고객-제품카테고리",
        "두 P 계산방식의 고객별 카테고리 기여도"
    ),

    (
        "W3_RFMP_BASE_PY",
        "고객",
        "변경된 F와 P를 포함한 RFMP 기본 데이터"
    ),

    (
        "W3_RFMP_STANDARDIZED_PY",
        "고객",
        "지표별 K-means용 표준화 값"
    ),

    (
        "W3_RFMP_CLUSTERED_PY",
        "고객",
        "R/F/M/P별 1차원 K-means 결과"
    ),

    (
        "W3_RFMP_CLUSTER_CV_PY",
        "지표-군집",
        "군집별 평균·표준편차·CV"
    ),

    (
        "W3_RFMP_WEIGHTS_PY",
        "지표",
        "변경된 F와 P를 반영한 최종 가중치"
    ),

    (
        "W3_CUSTOMER_RFMP_PY",
        "고객",
        "RFMP 점수와 6개 고객등급"
    ),

    (
        "W3_RFMP_TIER_PROFILE_PY",
        "RFMP 등급",
        "등급별 평균 RFMP와 고객 수"
    ),

    (
        "W3_RFMP_CATEGORY_TOP5_PY",
        "등급-제품카테고리",
        "구매일 Lift 기준 대표 카테고리"
    ),

    (
        "W3_RFMP_METHOD_COMPARE_PY",
        "비교항목",
        "기존 방식과 변경 방식의 상관관계"
    ),

    (
        "W3_CUSTOMER_ANALYTIC_BASE_PY",
        "고객",
        "고객 특성·RFMP·B_DAYS 후보확률 결합"
    ),

    (
        "W3_RFMP_QA_SUMMARY_PY",
        "점검항목",
        "WBS 3.5~3.9 자동 품질 점검"
    )

]


if tier_transition_created:

    catalog_rows.append(
        (
            "W3_RFMP_TIER_TRANSITION_PY",
            "고객",
            "기존 RFMP 등급과 변경 등급 비교"
        )
    )


output_catalog = pd.DataFrame(
    catalog_rows,
    columns=[
        "table_name",
        "data_grain",
        "description"
    ]
)


save_sas(
    output_catalog,
    "w3_rfmp_output_catalog_py"
)


# ====================================================================
# 3.9-7. 주요 결과 출력
# ====================================================================

print("\n[3.9 계산방법 비교]")

print(
    method_compare
    .round(4)
    .to_string(index=False)
)


print("\n[3.9 자동 품질 점검]")

print(
    qa_summary.to_string(
        index=False
    )
)


print("\n[3.9 최종 고객 분석 테이블]")

print(
    f"행 수: {len(analytic_base):,}"
)

print(
    f"열 수: {len(analytic_base.columns):,}"
)

print(
    "B_DAYS VALID 예측결과 결합 고객: "
    f"{joined_churn_count:,}"
)


print(
    "\nWBS 3.5~3.9 작업이 완료되었습니다."
)
# ---- PROC PYTHON 끝 ------------------------------------------------------

# 7. 필수 산출물 생성 여부
_outs = ["w3_frequency_full_py", "w3_rfmp_category_value_py", "w3_customer_category_p_py",
         "w3_rfmp_base_py", "w3_rfmp_standardized_py", "w3_rfmp_clustered_py",
         "w3_rfmp_cluster_cv_py", "w3_rfmp_weights_py", "w3_customer_rfmp_py",
         "w3_rfmp_tier_profile_py", "w3_rfmp_category_top5_py", "w3_rfmp_method_compare_py",
         "w3_customer_analytic_base_py", "w3_rfmp_qa_summary_py", "w3_rfmp_output_catalog_py"]
if HAS_OLD_RFMP == 1:
    _outs.append("w3_rfmp_tier_transition_py")
OUTPUT_ERROR_COUNT = 0
for _t in _outs:
    if exists(_t):
        print(f"NOTE: 생성 완료 - crm.{_t}")
    else:
        print(f"ERROR: 생성 실패 - crm.{_t}")
        OUTPUT_ERROR_COUNT += 1
if OUTPUT_ERROR_COUNT > 0:
    abort(f"생성되지 않은 필수 산출물이 있습니다. 누락된 산출물 수 = {OUTPUT_ERROR_COUNT}")
print("NOTE: 모든 필수 산출물이 정상적으로 생성되었습니다.")

# 8. 주요 결과 출력
proc_print(load("w3_frequency_full_py"), "WBS 3.5 전체기간 Frequency 비교", obs=20, dec=2,
           var=["customer_id", "frequency_original", "frequency_orders", "frequency_days",
                "orders_per_purchase_day", "order_count_difference", "order_count_match"],
           png="r35_01_frequency_full")
proc_print(load("w3_rfmp_category_value_py"), "WBS 3.5 카테고리별 제품가치 비교", dec=2,
           var=["product_category", "category_order_count", "category_purchase_day_count",
                "category_avg_unit_price", "category_value_score_orders", "category_value_score_days",
                "category_value_score", "official_p_method"], png="r35_02_category_value")
proc_print(load("w3_rfmp_weights_py"), "WBS 3.6 R/F/M/P 최종 가중치", dec=6,
           var=["metric", "k", "weighted_cv", "raw_weight", "final_weight", "frequency_definition",
                "p_method"], png="r36_01_weights")
proc_freq(load("w3_customer_rfmp_py"), "rfmp_tier", "WBS 3.7 RFMP 등급별 고객 수", order="data",
          png="r37_01_freq_rfmp_tier")
proc_print(load("w3_rfmp_tier_profile_py"), "WBS 3.8 RFMP 등급 프로파일", dec=2,
           var=["tier_code", "rfmp_tier", "customer_count", "customer_pct", "avg_recency",
                "avg_frequency_days", "avg_frequency_orders", "avg_orders_per_day", "avg_monetary",
                "avg_product_value_p", "avg_rfmp_score", "min_rfmp_score", "max_rfmp_score"],
           png="r38_01_tier_profile")
proc_print(load("w3_rfmp_category_top5_py"), "WBS 3.8 등급별 대표 카테고리 Top 5", dec=3,
           var=["tier_code", "rfmp_tier", "category_rank", "product_category",
                "category_purchase_days", "category_orders", "category_customers", "category_sales",
                "lift", "ranking_basis"], png="r38_02_tier_top5")
proc_print(load("w3_rfmp_method_compare_py"), "WBS 3.9 기존 방식과 변경 방식 비교", dec=4,
           png="r39_01_method_compare")
if HAS_OLD_RFMP == 1:
    proc_freq_cross(load("w3_rfmp_tier_transition_py"), "old_rfmp_tier", "new_rfmp_tier",
                    "WBS 3.9 기존 등급과 변경 등급의 이동", png="r39_02_tier_transition")
proc_print(load("w3_rfmp_qa_summary_py"), "WBS 3.9 자동 품질 점검", png="r39_03_qa_summary")
proc_print(load("w3_rfmp_output_catalog_py"), "WBS 3.9 생성 산출물 목록")
proc_contents(load("w3_customer_analytic_base_py"), "WBS 3.9 최종 고객 분석 테이블 구조",
              png="r39_04_contents_analytic_base")
proc_print(load("w3_customer_analytic_base_py"), "WBS 3.9 최종 고객 분석 테이블 앞 10행", obs=10)

rc.note("WBS 3.5~3.9 전체 작업이 완료되었습니다.",
        "공식 Frequency = frequency_days",
        f"공식 P 계산방법 = {P_METHOD}",
        "기존 frequency_orders와 주문 기준 P는 비교용으로 보존했습니다.",
        "신규 고객 AUC와 확률 보정 문제는 아직 해결되지 않았습니다.")
