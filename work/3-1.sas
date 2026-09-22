 /*==========================================================
   3.1-A. RFM 원본·로그 변환·표준화 데이터 준비
 
   입력 테이블:
     CRM.W2_CUSTOMER_FEATURES
 
   생성 테이블:
     CRM.W3_MODEL_INPUT   : 고객별 RFM 및 표준화 변수
     CRM.W3_RFM_PROFILE   : RFM 기술통계와 왜도
     CRM.W3_SCALER_STATS  : 표준화에 사용한 평균과 표준편차
 ==========================================================*/
 
 
 /*----------------------------------------------------------
   0. 기본 설정 및 CRM 라이브러리 연결
 ----------------------------------------------------------*/
 
 options validvarname=any;
 
 libname crm "/home/student/crm_db1";


/*----------------------------------------------------------
  1. 입력 테이블 존재 여부 확인
----------------------------------------------------------*/

%macro check_w3_input;

    %if %sysfunc(exist(crm.w2_customer_features)) = 0 %then %do;

        %put ERROR: CRM.W2_CUSTOMER_FEATURES 테이블이 없습니다.;
        %put ERROR: 2-3 단계가 완료되었는지 확인하십시오.;

        %abort cancel;

    %end;
    %else %do;

        %put NOTE: CRM.W2_CUSTOMER_FEATURES 테이블을 확인했습니다.;

    %end;

%mend;

%check_w3_input;


/*----------------------------------------------------------
  2. 기존 3.1-A 결과가 있으면 삭제

  코드를 다시 실행할 때 같은 이름의 테이블 때문에
  저장이 방해받지 않도록 처리합니다.
----------------------------------------------------------*/

%macro drop_if_exists(member=);

    %if %sysfunc(exist(crm.&member.)) %then %do;

        proc datasets library=crm nolist;
            delete &member.;
        quit;

        %put NOTE: 기존 CRM.&member. 테이블을 삭제했습니다.;

    %end;

%mend;

%drop_if_exists(member=w3_model_input);
%drop_if_exists(member=w3_rfm_profile);
%drop_if_exists(member=w3_scaler_stats);


/*----------------------------------------------------------
  3. 입력 테이블 구조 확인
----------------------------------------------------------*/

title "3.1-A 입력 테이블 구조 확인";

proc contents
    data=crm.w2_customer_features
    varnum;
run;

title;


/*----------------------------------------------------------
  4. Python으로 RFM 데이터 검증 및 변환
----------------------------------------------------------*/

proc python;
submit;

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

endsubmit;
quit;
/*----------------------------------------------------------
  5. Python 결과 테이블 생성 여부 확인
----------------------------------------------------------*/

%macro check_w3_outputs;

    %if %sysfunc(exist(crm.w3_model_input))
        and %sysfunc(exist(crm.w3_rfm_profile))
        and %sysfunc(exist(crm.w3_scaler_stats))
    %then %do;

        %put NOTE: 3.1-A 결과 테이블 3개가 모두 생성되었습니다.;

    %end;
    %else %do;

        %put ERROR: 3.1-A 결과 테이블이 정상적으로 생성되지 않았습니다.;
        %put ERROR: 위쪽 PROC PYTHON 로그를 먼저 확인하십시오.;

        %abort cancel;

    %end;

%mend;

%check_w3_outputs;
/*----------------------------------------------------------
  4. 생성된 테이블 구조 확인
----------------------------------------------------------*/

title "3.1-A 군집분석 입력 테이블 구조";

proc contents
    data=crm.w3_model_input
    varnum;
run;

title;


/*----------------------------------------------------------
  5. 고객 수, 중복, 결측값 확인
----------------------------------------------------------*/

title "3.1-A 데이터 품질 최종 확인";

proc sql;

    select
        count(*) as total_customer_count,
        count(distinct customer_id) as unique_customer_count,

        sum(
            missing(recency)
            or missing(frequency)
            or missing(monetary)
        ) as rfm_missing_rows,

        sum(
            missing(z_recency_raw)
            or missing(z_frequency_raw)
            or missing(z_monetary_raw)
        ) as raw_missing_rows,

        sum(
            missing(z_recency_logfm)
            or missing(z_frequency_log)
            or missing(z_monetary_log)
        ) as logfm_missing_rows

    from crm.w3_model_input;

quit;

title;


/*----------------------------------------------------------
  6. 고객ID 중복 여부 확인
----------------------------------------------------------*/

proc sql;

    create table work.w3_duplicate_id as

    select
        customer_id,
        count(*) as duplicate_count

    from crm.w3_model_input

    group by customer_id

    having count(*) > 1;

quit;


title "고객ID 중복 검사 결과";

proc sql;

    select
        count(*) as duplicated_customer_ids

    from work.w3_duplicate_id;

quit;

title;


/*----------------------------------------------------------
  7. 원본 및 로그 변환 변수의 기술통계
----------------------------------------------------------*/

title "원본 및 로그 변환 RFM 기술통계";

proc means
    data=crm.w3_model_input
    n nmiss mean std min p1 q1 median q3 p99 max
    maxdec=3;

    var
        recency
        frequency
        monetary
        log_frequency
        log_monetary;

run;

title;


/*----------------------------------------------------------
  8. 표준화 변수 확인
----------------------------------------------------------*/

title "표준화 변수 평균과 표준편차 확인";

proc means
    data=crm.w3_model_input
    n nmiss mean std min max
    maxdec=6;

    var
        z_recency_raw
        z_frequency_raw
        z_monetary_raw
        z_recency_logfm
        z_frequency_log
        z_monetary_log;

run;

title;


/*----------------------------------------------------------
  9. 표준화 기준값 출력
----------------------------------------------------------*/

title "표준화에 사용한 평균과 표준편차";

proc print
    data=crm.w3_scaler_stats
    noobs;
run;

title;


/*----------------------------------------------------------
  10. 최종 데이터 앞 10행 확인
----------------------------------------------------------*/

title "3.1-A 최종 군집분석 입력 데이터 표본";

proc print
    data=crm.w3_model_input(obs=10)
    noobs;

    var
        customer_id
        recency
        frequency
        monetary
        log_frequency
        log_monetary
        z_recency_raw
        z_frequency_raw
        z_monetary_raw
        z_recency_logfm
        z_frequency_log
        z_monetary_log;

run;

title;


/*==========================================================
  3.1-A. RFM 원본·로그 변환·표준화 데이터 준비 완료
==========================================================*/


/*==========================================================
  3.1-B. RFM 군집 수(K) 비교 및 후보 선정

  입력 테이블:
    CRM.W3_MODEL_INPUT

  생성 테이블:
    CRM.W3_K_EVAL

  목적:
    1) 3.1-A에서 만든 RAW RFM과 LOG_FM RFM을 함께 비교합니다.
    2) K=2~8의 군집 품질과 최소 군집 크기를 확인합니다.
    3) 실루엣 점수 하나만 따라가지 않고 안정성과 해석 가능성도 봅니다.

  현재 데이터의 기본 권고안:
    LOG_FM 버전, K=4

  주의:
    이 단계는 3.1-A 결과를 수정하거나 삭제하지 않습니다.
==========================================================*/


/*----------------------------------------------------------
  0. 기본 설정 및 CRM 라이브러리 연결
----------------------------------------------------------*/

options validvarname=any;

/* 3.1-A에서 사용한 실제 경로입니다. 경로가 다르면 이 한 줄만 수정합니다. */
%let CRM_PATH=/home/student/crm_db1;
libname crm "&CRM_PATH.";


/*----------------------------------------------------------
  1. 입력 테이블 확인
----------------------------------------------------------*/

%macro check_input;

    %if %sysfunc(exist(crm.w3_model_input)) = 0 %then %do;
        %put ERROR: CRM.W3_MODEL_INPUT 테이블이 없습니다.;
        %put ERROR: 먼저 3.1-A 코드를 정상 실행하십시오.;
        %abort cancel;
    %end;

    %else %do;
        %put NOTE: CRM.W3_MODEL_INPUT 테이블을 확인했습니다.;
    %end;

%mend;

%check_input;


/* 이전 3.1-B 결과만 삭제합니다. */
proc datasets library=crm nolist nowarn;
    delete w3_k_eval;
quit;


/*----------------------------------------------------------
  2. Python으로 K=2~8 평가
----------------------------------------------------------*/

proc python;
submit;

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
print("3.1-B. RFM 군집 수(K) 비교 및 후보 선정")
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
            "recommended": int(
                model_version == "LOG_FM" and k == 4
            )
        }

        rows.append(row)
        previous_inertia = final_model.inertia_


k_eval = pd.DataFrame(rows)


# ---------------------------------------------------------
# 2-4. 평가 결과 저장
# ---------------------------------------------------------

SAS.df2sd(
    k_eval,
    dataset="crm.w3_k_eval"
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

print("\n[기본 권고안]")
print("LOG_FM 버전의 K=4를 3-3 기본값으로 사용합니다.")
print("이유: 왜도가 큰 F/M의 영향을 완화하면서, 네 가지 행동유형을")
print("구분할 수 있고 최소 군집도 지나치게 작아지지 않기 때문입니다.")


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
    axis.axvline(
        4,
        color="red",
        linestyle="--",
        linewidth=1
    )
    axis.grid(alpha=0.25)
    axis.legend()

plt.suptitle(
    "RFM K Selection: RAW vs LOG_FM",
    fontsize=14
)

plt.tight_layout(
    rect=[0, 0, 1, 0.96]
)

SAS.pyplot(plt)
plt.close()

print("\n3.1-B 작업이 정상적으로 완료되었습니다.")

endsubmit;
quit;


/*----------------------------------------------------------
  3. SAS 결과 확인
----------------------------------------------------------*/

title "3.1-B. RFM 군집 수(K) 평가 결과";

proc print data=crm.w3_k_eval noobs;
    format
        inertia comma14.2
        inertia_drop_pct 8.2
        silhouette 8.4
        calinski_harabasz comma12.2
        davies_bouldin 8.4
        min_cluster_pct 8.2
        stability_ari 8.4;
run;

title;


/* 권고안 행을 별도로 확인합니다. */
title "3.1-B 기본 권고안: LOG_FM, K=4";

proc print
    data=crm.w3_k_eval(
        where=(recommended=1)
    )
    noobs;
run;

title;


/*----------------------------------------------------------
  4. 최종 완료 메시지
----------------------------------------------------------*/

data _null_;
    put "NOTE: ================================================";
    put "NOTE: 3.1-B RFM K 비교가 완료되었습니다.";
    put "NOTE: 생성 테이블: CRM.W3_K_EVAL";
    put "NOTE: 3-3 기본 설정: LOG_FM, K=4";
    put "NOTE: ================================================";
run;


/*==========================================================
  WBS 3.2-A. Frequency 정의 비교용 피처 생성

  [목표]
    기존 주문 수와 구매일 수를 같은 고객·같은 기준일에서 계산합니다.
    이후 A·B·C 모형이 동일한 조건에서 비교되도록 입력 테이블을 만듭니다.

  [수행 범위]
    1. 기존 Frequency와 같은 주문 수를 frequency_orders로 생성
    2. 서로 다른 구매일 수를 frequency_days로 생성
    3. 하루 평균 주문 수를 참고 변수로 생성
    4. 기존 3.2의 TRAIN·VALID 피처와 이탈 라벨을 그대로 유지
    5. TRAIN에 없고 VALID에 처음 나타난 고객을 표시
    6. 두 Frequency의 정합성을 QA로 점검

  [해석 유의사항]
    - frequency_orders는 주문·거래 발생 강도입니다.
    - frequency_days는 구매가 발생한 서로 다른 날짜 수입니다.
    - 이 파일은 비교용 테이블만 생성합니다.
    - 기존 CRM.W3_CHURN_SPLIT_V2는 수정하지 않습니다.
    - 아직 공식 Frequency나 RFMP 등급을 변경하지 않습니다.

  [입력 테이블]
    CRM.CLEAN_ONLINE
    CRM.W3_CHURN_SPLIT_V2

  [주요 산출물]
    CRM.W3_FREQ_ABC_INPUT : A·B·C 모형 비교용 고객 피처
    CRM.W3_FREQ_ABC_QA    : 데이터 품질 점검 결과
==========================================================*/

options validvarname=any validmemname=extend;

%let CRM_PATH=/home/student/crm_db;
libname crm "&CRM_PATH.";


/*==========================================================
  0. 입력 테이블 확인
==========================================================*/

%macro require_table(ds=, previous_step=);

    %if %sysfunc(exist(&ds.)) = 0 %then %do;
        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %put ERROR: &previous_step. 단계를 먼저 정상 실행하십시오.;
        %abort cancel;
    %end;

    %else %do;
        %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;
    %end;

%mend;

%require_table(
    ds=crm.clean_online,
    previous_step=Week 1-5 정제
);

%require_table(
    ds=crm.w3_churn_split_v2,
    previous_step=WBS 3.2
);


/*==========================================================
  1. 이전 비교 결과만 정리

  기존 W3_CHURN_SPLIT_V2 및 다른 공식 테이블은 삭제하지 않습니다.
==========================================================*/

proc datasets library=crm nolist nowarn;
    delete
        w3_freq_abc_input
        w3_freq_abc_qa;
quit;

proc datasets library=work nolist nowarn;
    delete fabc_:;
quit;


/*==========================================================
  2. 기존 3.2와 같은 조건으로 유효 거래 준비

  고액·대량구매 플래그는 실제 거래일 수 있으므로 제외하지 않습니다.
==========================================================*/

data work.fabc_valid_lines;

    set crm.clean_online;

    if flag_missing_core          = 0
       and flag_return            = 0
       and flag_zero_quantity     = 0
       and flag_invalid_price     = 0
       and flag_customer_unmatched = 0;

    /* Frequency 계산에 필요한 핵심값을 한 번 더 확인합니다. */
    if not missing(customer_id)
       and not missing(order_key)
       and not missing(transaction_date);

    keep
        customer_id
        order_key
        transaction_date;

run;


/*==========================================================
  3. 상품 행을 주문 단위로 압축

  고객ID·주문키·거래일이 같은 행은 하나의 주문으로 처리합니다.
  이는 기존 3.2의 주문 단위 압축과 같은 기준입니다.
==========================================================*/

proc sql;

    create table work.fabc_orders as
    select distinct
        customer_id,
        order_key,
        transaction_date
    from work.fabc_valid_lines;

quit;


/*==========================================================
  4. 기준일별 Frequency 생성

  TRAIN 기준일: 2019-06-30
  VALID 기준일: 2019-10-02
==========================================================*/

%macro build_frequency(
    role=,
    cutoff=,
    out=
);

    proc sql;

        create table &out. as
        select
            customer_id,

            "&role." as split_role length=5,

            /* 기존 Frequency와 같은 주문 단위 행 수 */
            count(*) as frequency_orders,

            /* 서로 다른 날짜에 구매한 일수 */
            count(distinct transaction_date)
                as frequency_days,

            /* 참고값: 구매일 하루당 평균 주문 수 */
            case
                when calculated frequency_days > 0
                then calculated frequency_orders
                     / calculated frequency_days
                else .
            end as orders_per_purchase_day

        from work.fabc_orders

        where transaction_date <= &cutoff.

        group by customer_id;

    quit;

%mend;

%build_frequency(
    role=TRAIN,
    cutoff='30JUN2019'd,
    out=work.fabc_train_frequency
);

%build_frequency(
    role=VALID,
    cutoff='02OCT2019'd,
    out=work.fabc_valid_frequency
);


data work.fabc_frequency;

    set
        work.fabc_train_frequency
        work.fabc_valid_frequency;

run;


/*==========================================================
  5. TRAIN에 없던 신규 VALID 고객 확인

  동일 고객이 TRAIN과 VALID에 모두 있을 수 있습니다.
  TRAIN에 없고 VALID에만 나타난 고객은 별도로 표시합니다.
==========================================================*/

proc sql;

    create table work.fabc_train_customers as
    select distinct customer_id
    from crm.w3_churn_split_v2
    where upcase(strip(split_role)) = "TRAIN";

quit;


/*==========================================================
  6. 기존 3.2 피처에 Frequency 두 종류 결합

  기존 frequency도 비교 확인용으로 그대로 보존합니다.
==========================================================*/

proc sql;

    create table crm.w3_freq_abc_input as
    select
        a.*,

        /* 기존 3.2 Frequency를 비교용 이름으로 한 번 더 보존 */
        a.frequency as frequency_original,

        b.frequency_orders,
        b.frequency_days,
        b.orders_per_purchase_day,

        case
            when upcase(strip(a.split_role)) = "VALID"
                 and c.customer_id is missing
            then 1
            else 0
        end as is_new_valid_customer

    from crm.w3_churn_split_v2 as a

    left join work.fabc_frequency as b
      on  a.customer_id = b.customer_id
      and upcase(strip(a.split_role))
          = upcase(strip(b.split_role))

    left join work.fabc_train_customers as c
      on a.customer_id = c.customer_id;

quit;


/* 변수 설명을 붙입니다. */
data crm.w3_freq_abc_input;

    set crm.w3_freq_abc_input;

    label
        frequency_original       = "기존 3.2 주문수"
        frequency_orders         = "기준일 이전 주문수"
        frequency_days           = "기준일 이전 고유 구매일수"
        orders_per_purchase_day  = "구매일 하루당 평균 주문수"
        is_new_valid_customer    = "TRAIN에 없던 신규 VALID 고객";

run;


/*==========================================================
  7. 역할 내부 고객 중복 확인
==========================================================*/

proc sql;

    create table work.fabc_duplicate_customer as
    select
        split_role,
        customer_id,
        count(*) as duplicate_count
    from crm.w3_freq_abc_input
    group by split_role, customer_id
    having count(*) > 1;

quit;


/*==========================================================
  8. QA 요약 테이블 생성
==========================================================*/

proc sql;

    create table crm.w3_freq_abc_qa as
    select
        split_role,

        count(*) as row_count,

        count(distinct customer_id)
            as customer_count,

        sum(missing(frequency_orders))
            as missing_frequency_orders,

        sum(missing(frequency_days))
            as missing_frequency_days,

        sum(frequency_days > frequency_orders)
            as invalid_days_over_orders,

        sum(
            not missing(frequency_original)
            and not missing(frequency_orders)
            and frequency_original ne frequency_orders
        ) as original_frequency_mismatch,

        sum(is_new_valid_customer)
            as new_valid_customer_count,

        mean(frequency_orders)
            as avg_frequency_orders,

        mean(frequency_days)
            as avg_frequency_days,

        median(frequency_orders)
            as median_frequency_orders,

        median(frequency_days)
            as median_frequency_days,

        max(frequency_orders)
            as max_frequency_orders,

        max(frequency_days)
            as max_frequency_days

    from crm.w3_freq_abc_input

    group by split_role;

quit;


/*==========================================================
  9. QA 오류 건수 저장
==========================================================*/

proc sql noprint;

    select count(*)
        into :FABC_DUPLICATE_COUNT trimmed
    from work.fabc_duplicate_customer;

    select
        sum(missing(frequency_orders)),
        sum(missing(frequency_days)),
        sum(frequency_days > frequency_orders),
        sum(
            not missing(frequency_original)
            and not missing(frequency_orders)
            and frequency_original ne frequency_orders
        )

        into
            :FABC_MISSING_ORDERS trimmed,
            :FABC_MISSING_DAYS trimmed,
            :FABC_INVALID_RELATION trimmed,
            :FABC_OLD_MISMATCH trimmed

    from crm.w3_freq_abc_input;

quit;


/*==========================================================
  10. QA 결과 출력
==========================================================*/

title "WBS 3.2-A-1. Frequency 정의 비교 QA";

proc print data=crm.w3_freq_abc_qa noobs label;

    format
        avg_frequency_orders
        avg_frequency_days
        median_frequency_orders
        median_frequency_days
        max_frequency_orders
        max_frequency_days 12.2;

run;


title "WBS 3.2-A-2. Frequency 분포";

proc means
    data=crm.w3_freq_abc_input
    n nmiss mean std min p25 median p75 p90 p95 p99 max;

    class split_role;

    var
        frequency_orders
        frequency_days
        orders_per_purchase_day;

run;


title "WBS 3.2-A-3. 신규 VALID 고객 수";

proc freq data=crm.w3_freq_abc_input;

    tables
        split_role*is_new_valid_customer
        / missing norow nocol;

run;


/* USER_1358이 각 시점에서 어떻게 계산되는지 직접 확인합니다. */
title "WBS 3.2-A-4. USER_1358 Frequency 확인";

proc print
    data=crm.w3_freq_abc_input(
        where=(upcase(strip(customer_id))="USER_1358")
    )
    noobs label;

    var
        customer_id
        split_role
        snapshot_cutoff
        frequency_original
        frequency_orders
        frequency_days
        orders_per_purchase_day
        churn_flag;

    format
        snapshot_cutoff yymmdd10.
        orders_per_purchase_day 12.2;

run;

title;


/*==========================================================
  11. 핵심 QA 판정

  오류가 있으면 다음 모델 비교로 넘어가지 않습니다.
==========================================================*/

%macro validate_frequency_output;

    %if &FABC_DUPLICATE_COUNT. > 0 %then %do;
        %put ERROR: 역할 내부에 중복 고객ID가 있습니다.;
        %abort cancel;
    %end;

    %if &FABC_MISSING_ORDERS. > 0 %then %do;
        %put ERROR: frequency_orders에 결측값이 있습니다.;
        %abort cancel;
    %end;

    %if &FABC_MISSING_DAYS. > 0 %then %do;
        %put ERROR: frequency_days에 결측값이 있습니다.;
        %abort cancel;
    %end;

    %if &FABC_INVALID_RELATION. > 0 %then %do;
        %put ERROR: 구매일 수가 주문 수보다 큰 고객이 있습니다.;
        %abort cancel;
    %end;

    %if &FABC_OLD_MISMATCH. > 0 %then %do;
        %put ERROR: 기존 frequency와 frequency_orders가 일치하지 않습니다.;
        %put ERROR: 기존 3.2와 이번 코드의 거래 필터를 확인하십시오.;
        %abort cancel;
    %end;

    %put NOTE: Frequency 비교용 입력 테이블의 핵심 QA를 통과했습니다.;

%mend;

%validate_frequency_output;


/*==========================================================
  12. 최종 테이블 확인
==========================================================*/

title "WBS 3.2-A 최종 입력 테이블 구조";

proc contents data=crm.w3_freq_abc_input varnum;
run;


title "WBS 3.2-A 최종 입력 데이터 앞 10행";

proc print data=crm.w3_freq_abc_input(obs=10) noobs label;

    var
        snapshot_key
        customer_id
        split_role
        snapshot_cutoff
        churn_flag
        frequency_original
        frequency_orders
        frequency_days
        orders_per_purchase_day
        is_new_valid_customer;

run;

title;


/*==========================================================
  13. 산출물 생성 여부 확인
==========================================================*/

%macro check_outputs;

    %local missing_output;
    %let missing_output=0;

    %if %sysfunc(exist(crm.w3_freq_abc_input)) = 0
        %then %let missing_output=1;

    %if %sysfunc(exist(crm.w3_freq_abc_qa)) = 0
        %then %let missing_output=1;

    %if &missing_output. = 0 %then %do;
        %put NOTE: WBS 3.2-A 결과 테이블 두 개가 모두 생성되었습니다.;
    %end;

    %else %do;
        %put ERROR: WBS 3.2-A 결과 테이블 중 생성되지 않은 것이 있습니다.;
        %abort cancel;
    %end;

%mend;

%check_outputs;


/*==========================================================
  WBS 3.2-A 완료

  다음 실행 파일:
    WBS_3_3A_FREQUENCY_ABC_COMPARE.sas
==========================================================*/	


/*==========================================================
  WBS 3.3-A. Frequency A·B·C 모형 비교

  [목표]
    Frequency 정의만 다르게 한 세 개의 로지스틱 회귀모형을
    동일한 TRAIN·VALID 조건에서 비교합니다.

  [비교 모형]
    A_ORDERS : 공통 피처 + 주문 수
    B_DAYS   : 공통 피처 + 구매일 수
    C_BOTH   : 공통 피처 + 주문 수 + 구매일 수

  [수행 범위]
    1. 같은 TRAIN 데이터로 세 모형을 학습
    2. 같은 VALID 데이터로 성능 평가
    3. TRAIN에 없던 신규 VALID 고객도 별도 평가
    4. VALID 상위 100명·200명의 실제 이탈 고객 수 비교
    5. VALID AUC 차이의 부트스트랩 신뢰구간 계산
    6. 사전에 정한 규칙으로 잠정 권고안 출력

  [해석 유의사항]
    - 이 코드는 Frequency 정의를 비교하는 진단 실험입니다.
    - 기존 WBS 3.3 공식모형을 교체하지 않습니다.
    - 기존 clv_proxy는 주문 수를 사용하므로 공정한 비교에서 제외합니다.
    - P와 RFMP 점수도 이번 비교에는 사용하지 않습니다.
    - 최종 선택은 VALID 결과를 우선합니다.
    - 신규 VALID 결과는 보조 검증으로 사용합니다.
    - 자동 권고는 팀 검토를 대신하지 않습니다.

  [입력 테이블]
    CRM.W3_FREQ_ABC_INPUT

  [주요 산출물]
    CRM.W3_FREQ_ABC_METRICS  : 모형별 성능
    CRM.W3_FREQ_ABC_TOPK     : 상위 100·200명 성과
    CRM.W3_FREQ_ABC_AUC_DIFF : VALID AUC 차이와 신뢰구간
    CRM.W3_FREQ_ABC_SCORED   : 고객별 모형 예측확률
    CRM.W3_FREQ_ABC_COEF     : 표준화 로지스틱 회귀계수
    CRM.W3_FREQ_ABC_DECISION : 잠정 권고안
==========================================================*/

options validvarname=any validmemname=extend;

%let CRM_PATH=/home/student/crm_db;
libname crm "&CRM_PATH.";


/*==========================================================
  0. 입력 테이블 확인
==========================================================*/

%if %sysfunc(exist(crm.w3_freq_abc_input)) = 0 %then %do;

    %put ERROR: CRM.W3_FREQ_ABC_INPUT 테이블이 없습니다.;
    %put ERROR: WBS 3.2-A를 먼저 정상 실행하십시오.;
    %abort cancel;

%end;

%else %do;

    %put NOTE: CRM.W3_FREQ_ABC_INPUT 테이블을 확인했습니다.;

%end;


/*==========================================================
  1. 이전 A·B·C 비교 결과만 정리
==========================================================*/

proc datasets library=crm nolist nowarn;

    delete
        w3_freq_abc_metrics
        w3_freq_abc_topk
        w3_freq_abc_auc_diff
        w3_freq_abc_scored
        w3_freq_abc_coef
        w3_freq_abc_decision;

quit;


/*==========================================================
  2. 모델링 전 SAS 단계 점검
==========================================================*/

title "WBS 3.3-A-1. 비교용 입력 데이터 확인";

proc sql;

    select
        split_role,
        count(*) as row_count,
        count(distinct customer_id) as customer_count,
        mean(churn_flag) as churn_rate format=percent8.2,
        sum(is_new_valid_customer) as new_valid_customer_count,
        sum(last_purchase_date > snapshot_cutoff)
            as future_feature_date_count,
        sum(missing(frequency_orders))
            as missing_frequency_orders,
        sum(missing(frequency_days))
            as missing_frequency_days
    from crm.w3_freq_abc_input
    group by split_role;

quit;

title;


/*==========================================================
  3. Python에서 A·B·C 로지스틱 회귀 비교
==========================================================*/

proc python;
submit;

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

common_numeric_features = [
    "recency",
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
    "last_coupon_used"
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

endsubmit;
quit;


/*==========================================================
  4. SAS 결과표 출력
==========================================================*/

title "WBS 3.3-A-2. A·B·C 모형별 성능";

proc print data=crm.w3_freq_abc_metrics noobs label;

    format
        churn_rate
        mean_probability
        calibration_gap percent9.2

        roc_auc
        pr_auc
        brier_score
        log_loss
        accuracy
        balanced_accuracy
        precision
        recall
        f1_score 10.5;

run;


title "WBS 3.3-A-3. VALID 상위 100명·200명 성과";

proc print data=crm.w3_freq_abc_topk noobs label;

    format
        precision_at_k
        recall_at_k
        lift_at_k 10.4;

run;


title "WBS 3.3-A-4. VALID AUC 차이와 신뢰구간";

proc print data=crm.w3_freq_abc_auc_diff noobs label;

    format
        auc_difference
        ci_low
        ci_high 10.5;

run;


title "WBS 3.3-A-5. 잠정 권고안";

proc print data=crm.w3_freq_abc_decision noobs label;

    format
        a_valid_auc
        b_valid_auc
        c_valid_auc 10.5;

run;


/* Frequency 계수만 따로 확인합니다. */
title "WBS 3.3-A-6. Frequency 관련 표준화 회귀계수";

proc print
    data=crm.w3_freq_abc_coef(
        where=(
            index(
                upcase(feature_name),
                "FREQUENCY"
            ) > 0
        )
    )
    noobs label;

    var
        model_variant
        feature_name
        coefficient
        abs_coefficient
        importance_rank;

    format
        coefficient
        abs_coefficient 12.5;

run;

title;


/*==========================================================
  5. VALID ROC-AUC 비교 그래프
==========================================================*/

title "WBS 3.3-A-7. VALID ROC-AUC 비교";

proc sgplot
    data=crm.w3_freq_abc_metrics(
        where=(dataset_role="VALID")
    );

    vbar model_variant
        / response=roc_auc
          datalabel
          categoryorder=respdesc;

    yaxis
        label="VALID ROC-AUC"
        min=0.5
        max=1
        grid;

    xaxis
        label="Frequency 모형";

run;

title;


/*==========================================================
  6. 산출물 생성 여부 확인
==========================================================*/

%macro check_outputs;

    %local missing_output;
    %let missing_output=0;

    %if %sysfunc(exist(crm.w3_freq_abc_metrics)) = 0
        %then %let missing_output=1;

    %if %sysfunc(exist(crm.w3_freq_abc_topk)) = 0
        %then %let missing_output=1;

    %if %sysfunc(exist(crm.w3_freq_abc_auc_diff)) = 0
        %then %let missing_output=1;

    %if %sysfunc(exist(crm.w3_freq_abc_scored)) = 0
        %then %let missing_output=1;

    %if %sysfunc(exist(crm.w3_freq_abc_coef)) = 0
        %then %let missing_output=1;

    %if %sysfunc(exist(crm.w3_freq_abc_decision)) = 0
        %then %let missing_output=1;

    %if &missing_output. = 0 %then %do;

        %put NOTE: WBS 3.3-A 결과 테이블 여섯 개가 모두 생성되었습니다.;

    %end;

    %else %do;

        %put ERROR: WBS 3.3-A 결과 테이블 중 생성되지 않은 것이 있습니다.;
        %abort cancel;

    %end;

%mend;

%check_outputs;


/*==========================================================
  WBS 3.3-A 완료

  다음 판단 순서
    1. CRM.W3_FREQ_ABC_METRICS의 VALID 결과 확인
    2. CRM.W3_FREQ_ABC_AUC_DIFF의 신뢰구간 확인
    3. CRM.W3_FREQ_ABC_TOPK의 상위 고객 성과 확인
    4. CRM.W3_FREQ_ABC_DECISION의 잠정 권고 확인
    5. 결과 확인 전에는 공식 3.5~4.4를 수정하지 않음
==========================================================*/