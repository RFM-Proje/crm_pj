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
 
 libname crm "/home/student/crm_db";


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
%let CRM_PATH=/home/student/crm_db;
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
  WBS 3.2. 이탈예측 피처 확장 및 기준 검토

  입력 테이블
    CRM.CLEAN_ONLINE   : 1주차에 만든 거래 상세 정제 테이블
    CRM.CLEAN_CUSTOMER : 1주차에 만든 고객정보 정제 테이블

  생성 테이블
    CRM.W3_CHURN_WINDOW_COMPARE : 30/60/90/120일 이탈률 비교
    CRM.W3_CHURN_SPLIT_V2       : 시간 순서대로 분리한 학습·검증 데이터
    CRM.W3_CHURN_FEATURE_PROFILE: 피처별 기술통계
    CRM.W3_CHURN_QA_SUMMARY     : 데이터 품질 점검 결과

  핵심 원칙
    1. 피처는 기준일 이전 거래만 사용합니다.
    2. 이탈 여부는 기준일 이후 90일 거래로 만듭니다.
    3. TRAIN과 VALID는 서로 다른 기준일을 사용합니다.
    4. 거래ID는 고객 간에 중복될 수 있으므로 order_key를 사용합니다.
    5. 중간 계산 테이블은 WORK에 만들고 최종 결과만 CRM에 저장합니다.
==========================================================*/

options validvarname=any;

/* 기존 3.1-A/B와 같은 라이브러리 경로입니다. */
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
    ds=crm.clean_customer,
    previous_step=Week 1-5 정제
);


/*==========================================================
  1. 이전 3.2 결과와 이번 실행의 임시 테이블 정리

  RAW_, STG_, CLEAN_, W2_ 및 3.1 결과는 삭제하지 않습니다.
==========================================================*/

proc datasets library=crm nolist nowarn;
    delete
        w3_churn_window_compare
        w3_churn_split_v2
        w3_churn_feature_profile
        w3_churn_qa_summary;
quit;

proc datasets library=work nolist nowarn;
    delete w3_:;
quit;


/*==========================================================
  2. 모델링에 사용할 유효 거래 행 준비

  이상 고액·대량구매 플래그는 삭제 조건으로 사용하지 않습니다.
  실제 오류로 보기 어려운 정상 대량구매일 수 있기 때문입니다.
==========================================================*/

data work.w3_valid_online;

    set crm.clean_online;

    /* 핵심정보가 있고 구매금액 계산이 가능한 정상 구매 행만 사용 */
    if flag_missing_core       = 0
       and flag_return         = 0
       and flag_zero_quantity  = 0
       and flag_invalid_price  = 0
       and flag_customer_unmatched = 0;

    length coupon_status_std $12;

    /* 쿠폰상태의 대소문자와 불필요한 공백을 통일 */
    coupon_status_std = upcase(compbl(strip(coupon_status)));

    /* 상품 행의 구매금액: 평균단가 × 수량 */
    line_amount = avg_price * quantity;

    label
        coupon_status_std = "표준화 쿠폰상태"
        line_amount       = "상품 행 구매금액";

run;


/* 전체 거래기간을 먼저 확인합니다. */
title "WBS 3.2-1. 모델링용 거래기간 확인";

proc sql;
    select
        min(transaction_date) format=yymmdd10. as first_date,
        max(transaction_date) format=yymmdd10. as last_date,
        max(transaction_date)-min(transaction_date)+1 as observed_days,
        count(*) as valid_line_count,
        count(distinct customer_id) as customer_count,
        count(distinct order_key) as order_count
    from work.w3_valid_online;
quit;

title;


/*==========================================================
  3. 이탈 기준 30/60/90/120일 비교

  동일한 기준일을 사용해야 윈도우 길이만 공정하게 비교할 수 있습니다.
  최장 120일도 데이터 안에 들어오도록 2019-06-30을 기준일로 둡니다.
==========================================================*/

%let WINDOW_CHECK_CUTOFF='30JUN2019'd;

%macro compare_window(days=);

    %local window_end;

    %let window_end=%sysfunc(
        intnx(day,&WINDOW_CHECK_CUTOFF.,&days.),
        date9.
    );

    /* 기준일 이전 구매 고객이 비교 대상입니다. */
    proc sql;

        create table work.w3_wc_base_&days. as
        select distinct customer_id
        from work.w3_valid_online
        where transaction_date <= &WINDOW_CHECK_CUTOFF.;

        /* 기준일 이후 해당 윈도우 안에 구매한 고객입니다. */
        create table work.w3_wc_active_&days. as
        select distinct customer_id
        from work.w3_valid_online
        where transaction_date > &WINDOW_CHECK_CUTOFF.
          and transaction_date <= "&window_end."d;

        /* 이후 구매가 없으면 이탈 고객으로 계산합니다. */
        create table work.w3_wc_summary_&days. as
        select
            &days. as window_days,
            &WINDOW_CHECK_CUTOFF. as cutoff_date format=yymmdd10.,
            "&window_end."d as window_end format=yymmdd10.,
            count(*) as total_customers,
            sum(case when b.customer_id is missing then 1 else 0 end)
                as churn_customers,
            calculated churn_customers / calculated total_customers
                as churn_rate format=percent8.2
        from work.w3_wc_base_&days. as a
        left join work.w3_wc_active_&days. as b
            on a.customer_id = b.customer_id;

    quit;

%mend;

%compare_window(days=30);
%compare_window(days=60);
%compare_window(days=90);
%compare_window(days=120);

data crm.w3_churn_window_compare;
    set
        work.w3_wc_summary_30
        work.w3_wc_summary_60
        work.w3_wc_summary_90
        work.w3_wc_summary_120;
run;

title "WBS 3.2-2. 이탈 라벨 윈도우별 이탈률";

proc print data=crm.w3_churn_window_compare noobs label;
run;

proc sgplot data=crm.w3_churn_window_compare;
    vbar window_days / response=churn_rate datalabel;
    xaxis label="이탈 라벨 윈도우(일)" type=discrete;
    yaxis label="이탈률" grid values=(0 to 1 by 0.1);
    format churn_rate percent8.1;
    title "30·60·90·120일 기준에 따른 이탈률 변화";
run;

title;


/*==========================================================
  4. 한 개 시점의 이탈예측 피처를 만드는 매크로

  TRAIN: 2019-06-30 이전 행동 → 이후 90일 이탈
  VALID: 2019-10-02 이전 행동 → 이후 90일 이탈

  같은 고객이 두 시점에 모두 나타날 수 있습니다.
  고객ID는 모델 입력변수로 사용하지 않으므로 고객 식별정보 자체가
  예측에 들어가는 누수는 발생하지 않습니다.
==========================================================*/

%macro build_churn_snapshot(
    tag=,
    role=,
    cutoff=,
    label_end=,
    out=
);

    /*------------------------------------------------------
      4-1. 피처 구간과 라벨 구간 분리
    ------------------------------------------------------*/

    data work.w3_&tag._feature
         work.w3_&tag._label;

        set work.w3_valid_online;

        if transaction_date <= &cutoff. then
            output work.w3_&tag._feature;

        else if transaction_date > &cutoff.
            and transaction_date <= &label_end. then
            output work.w3_&tag._label;

    run;


    /*------------------------------------------------------
      4-2. 상품 행을 주문 단위로 압축

      order_key는 customer_id와 transaction_id를 결합한 키입니다.
      배송료는 한 주문 안에서 반복되므로 한 번만 반영합니다.
    ------------------------------------------------------*/

    proc sql;

        create table work.w3_&tag._orders as
        select
            customer_id,
            order_key,
            transaction_date,
            sum(line_amount) as order_amount,
            sum(quantity) as order_quantity,
            max(shipping_fee) as order_shipping,
            max(
                case
                    when coupon_status_std="USED" then 1
                    else 0
                end
            ) as order_coupon_used,
            max(
                case
                    when coupon_status_std in ("USED","CLICKED") then 1
                    else 0
                end
            ) as order_coupon_clicked
        from work.w3_&tag._feature
        group by
            customer_id,
            order_key,
            transaction_date;

    quit;


    /*------------------------------------------------------
      4-3. 고객별 기본 구매행동 피처
    ------------------------------------------------------*/

    proc sql;

        create table work.w3_&tag._core as
        select
            customer_id,
            min(transaction_date) as first_purchase_date format=yymmdd10.,
            max(transaction_date) as last_purchase_date format=yymmdd10.,
            &cutoff. - max(transaction_date) as recency,
            count(*) as frequency,
            sum(order_amount) as monetary,
            mean(order_amount) as avg_order_value,
            mean(order_shipping) as avg_shipping,
            mean(order_coupon_used) as coupon_usage_rate,
            mean(order_coupon_clicked) as coupon_click_rate,
            &cutoff. - min(transaction_date) + 1 as observation_days
        from work.w3_&tag._orders
        group by customer_id;

    quit;


    /*------------------------------------------------------
      4-4. 이용카테고리수와 주이용카테고리 집중도

      한 주문에 같은 카테고리 상품이 여러 개 있어도 한 번만 셉니다.
      집중도는 가장 많이 이용한 카테고리 주문수 ÷ 전체 카테고리 주문수입니다.
    ------------------------------------------------------*/

    proc sql;

        create table work.w3_&tag._cat_count as
        select
            customer_id,
            product_category,
            count(distinct order_key) as category_order_count
        from work.w3_&tag._feature
        group by customer_id, product_category;

        create table work.w3_&tag._cat_feature as
        select
            customer_id,
            count(*) as product_category_count,
            max(category_order_count) / sum(category_order_count)
                as category_concentration
        from work.w3_&tag._cat_count
        group by customer_id;

    quit;


    /*------------------------------------------------------
      4-5. 재구매 간격 평균과 표준편차

      같은 날 여러 번 주문한 경우 0일 간격이 반복되지 않도록
      고객별 고유 구매일만 사용합니다.
    ------------------------------------------------------*/

    proc sort
        data=work.w3_&tag._feature(
            keep=customer_id transaction_date
        )
        out=work.w3_&tag._dates
        nodupkey;
        by customer_id transaction_date;
    run;

    data work.w3_&tag._gaps;

        set work.w3_&tag._dates;
        by customer_id transaction_date;

        retain previous_date;

        if first.customer_id then do;
            previous_date = transaction_date;
            gap_days = .;
        end;

        else do;
            gap_days = transaction_date - previous_date;
            previous_date = transaction_date;

            if gap_days > 0 then output;
        end;

        keep customer_id gap_days;

    run;

    proc means
        data=work.w3_&tag._gaps
        noprint nway;

        class customer_id;
        var gap_days;

        output out=work.w3_&tag._gap_feature(
            drop=_type_ _freq_
        )
        mean=avg_days_between_orders
        std=std_days_between_orders;

    run;


    /*------------------------------------------------------
      4-6. 마지막 구매일의 쿠폰 사용 여부

      마지막 구매일에 주문이 여러 개라면 하나라도 Used이면 1입니다.
      정렬된 마지막 한 행을 임의로 고르는 오류를 피합니다.
    ------------------------------------------------------*/

    proc sql;

        create table work.w3_&tag._last_coupon as
        select
            a.customer_id,
            max(a.order_coupon_used) as last_coupon_used
        from work.w3_&tag._orders as a
        inner join work.w3_&tag._core as b
            on  a.customer_id = b.customer_id
            and a.transaction_date = b.last_purchase_date
        group by a.customer_id;

    quit;


    /*------------------------------------------------------
      4-7. 기준일 이후 구매 여부로 이탈 라벨 생성

      라벨 구간에 구매가 있으면 0, 구매가 없으면 1입니다.
    ------------------------------------------------------*/

    proc sql;

        create table work.w3_&tag._active as
        select distinct customer_id
        from work.w3_&tag._label;

        create table &out. as
        select
            a.*,
            coalesce(b.product_category_count,0)
                as product_category_count,
            coalesce(b.category_concentration,0)
                as category_concentration,
            coalesce(c.avg_days_between_orders,0)
                as avg_days_between_orders,
            coalesce(c.std_days_between_orders,0)
                as std_days_between_orders,
            coalesce(d.last_coupon_used,0)
                as last_coupon_used,
            e.gender,
            e.region,
            e.tenure,
            case
                when f.customer_id is missing then 1
                else 0
            end as churn_flag,
            "&role." as split_role length=5,
            &cutoff. as snapshot_cutoff format=yymmdd10.,
            &label_end. as label_end_date format=yymmdd10.
        from work.w3_&tag._core as a
        left join work.w3_&tag._cat_feature as b
            on a.customer_id = b.customer_id
        left join work.w3_&tag._gap_feature as c
            on a.customer_id = c.customer_id
        left join work.w3_&tag._last_coupon as d
            on a.customer_id = d.customer_id
        left join crm.clean_customer as e
            on a.customer_id = e.customer_id
        left join work.w3_&tag._active as f
            on a.customer_id = f.customer_id;

    quit;


    /*------------------------------------------------------
      4-8. 연환산 구매빈도와 CLV 대용지표 계산

      현재 데이터에는 미래 유지기간과 이익률이 없습니다.
      따라서 아래 값은 엄밀한 CLV가 아니라 비교용 CLV 대용지표입니다.
      관측기간이 너무 짧은 고객의 값이 폭증하지 않도록 최소 30일을 씁니다.
    ------------------------------------------------------*/

    data &out.;

        set &out.;

        if missing(tenure) then tenure = 0;

        annual_order_frequency =
            frequency / (max(observation_days,30) / 365.25);

        clv_proxy =
            avg_order_value
            * annual_order_frequency
            * (max(tenure,1) / 12);

        length snapshot_key $50;
        snapshot_key = catx("|",customer_id,split_role);

        label
            recency                 = "기준일 이후 미구매 경과일"
            frequency               = "기준일 이전 주문수"
            monetary                = "기준일 이전 총구매금액"
            avg_order_value         = "주문당 평균구매금액"
            avg_shipping            = "주문당 평균배송료"
            coupon_usage_rate       = "쿠폰 실제 사용 주문 비율"
            coupon_click_rate       = "쿠폰 클릭 또는 사용 주문 비율"
            product_category_count  = "이용카테고리수"
            category_concentration  = "주이용카테고리 집중도"
            avg_days_between_orders = "재구매 간격 평균"
            std_days_between_orders = "재구매 간격 표준편차"
            last_coupon_used        = "마지막 구매일 쿠폰 사용 여부"
            clv_proxy               = "CLV 대용지표"
            churn_flag              = "이후 90일 이탈 여부"
            split_role              = "시간 분리 역할";

    run;

%mend;


/*==========================================================
  5. 시간 순서가 다른 TRAIN과 VALID 스냅샷 생성

  TRAIN 라벨 구간: 2019-07-01 ~ 2019-09-28
  VALID 라벨 구간: 2019-10-03 ~ 2019-12-31
==========================================================*/

%build_churn_snapshot(
    tag=train,
    role=TRAIN,
    cutoff='30JUN2019'd,
    label_end='28SEP2019'd,
    out=work.w3_train_snapshot
);

%build_churn_snapshot(
    tag=valid,
    role=VALID,
    cutoff='02OCT2019'd,
    label_end='31DEC2019'd,
    out=work.w3_valid_snapshot
);


/* 두 스냅샷을 하나의 영구 테이블로 합칩니다. */
data crm.w3_churn_split_v2;
    set
        work.w3_train_snapshot
        work.w3_valid_snapshot;
run;


/*==========================================================
  6. 생성된 피처의 기술통계와 품질검사

  수치형 피처 14개
    기본 피처 8개 + 확장 피처 6개
  성별과 지역은 별도의 범주형 피처입니다.
==========================================================*/

ods output Summary=crm.w3_churn_feature_profile;

proc means
    data=crm.w3_churn_split_v2
    n nmiss mean std min p50 max
    stackodsoutput;

    class split_role;

    var
        recency
        frequency
        monetary
        avg_order_value
        avg_shipping
        coupon_usage_rate
        coupon_click_rate
        tenure
        product_category_count
        category_concentration
        avg_days_between_orders
        std_days_between_orders
        last_coupon_used
        clv_proxy;

run;

ods output close;


proc sql;

    create table crm.w3_churn_qa_summary as
    select
        split_role,
        count(*) as row_count,
        count(distinct customer_id) as customer_count,
        sum(missing(customer_id)) as missing_customer_id,
        sum(missing(churn_flag)) as missing_churn_flag,
        sum(last_purchase_date > snapshot_cutoff)
            as future_feature_date_count,
        mean(churn_flag) as churn_rate format=percent8.2
    from crm.w3_churn_split_v2
    group by split_role;

quit;


title "WBS 3.2-3. TRAIN·VALID 고객수와 이탈률";

proc print data=crm.w3_churn_qa_summary noobs label;
run;

proc freq data=crm.w3_churn_split_v2;
    tables split_role*churn_flag / missing norow nocol;
    title "시간 분리 역할별 이탈 라벨 분포";
run;

title;


/* 고객ID는 역할 안에서 한 번만 나타나야 합니다. */
proc sql;

    create table work.w3_duplicate_snapshot as
    select
        split_role,
        customer_id,
        count(*) as duplicate_count
    from crm.w3_churn_split_v2
    group by split_role, customer_id
    having count(*) > 1;

    title "WBS 3.2-4. 역할 내부 고객ID 중복 검사";

    select count(*) as duplicated_snapshot_keys
    from work.w3_duplicate_snapshot;

quit;

title;


/*==========================================================
  7. 최종 결과 확인
==========================================================*/

title "WBS 3.2 최종 학습·검증 테이블 구조";

proc contents data=crm.w3_churn_split_v2 varnum;
run;

title "WBS 3.2 최종 데이터 앞 10행";

proc print data=crm.w3_churn_split_v2(obs=10) label;
    var
        snapshot_key
        customer_id
        split_role
        snapshot_cutoff
        label_end_date
        recency
        frequency
        monetary
        product_category_count
        category_concentration
        avg_days_between_orders
        last_coupon_used
        clv_proxy
        churn_flag;
run;

title;


/* 최종 테이블 네 개가 만들어졌는지 확인합니다. */
%macro check_outputs;

    %local missing_output;
    %let missing_output=0;

    %if %sysfunc(exist(crm.w3_churn_window_compare)) = 0
        %then %let missing_output=1;

    %if %sysfunc(exist(crm.w3_churn_split_v2)) = 0
        %then %let missing_output=1;

    %if %sysfunc(exist(crm.w3_churn_feature_profile)) = 0
        %then %let missing_output=1;

    %if %sysfunc(exist(crm.w3_churn_qa_summary)) = 0
        %then %let missing_output=1;

    %if &missing_output. = 0 %then %do;
        %put NOTE: WBS 3.2 결과 테이블 네 개가 모두 생성되었습니다.;
    %end;

    %else %do;
        %put ERROR: WBS 3.2 결과 테이블 중 생성되지 않은 것이 있습니다.;
        %abort cancel;
    %end;

%mend;

%check_outputs;

/*==========================================================
  WBS 3.2 완료
==========================================================*/

/*==========================================================
  WBS 3.3. 데이터 누수 방지 및 이탈예측 검증

  입력 테이블
    CRM.W3_CHURN_SPLIT_V2 : WBS 3.2에서 만든 시간 분리 데이터

  생성 테이블
    CRM.W3_CHURN_SCORED_V2     : 고객별 실제값·예측확률
    CRM.W3_CHURN_METRICS_V2    : TRAIN/VALID/MIXED 평가 결과
    CRM.W3_CHURN_IMPORTANCE_V2 : VALID 기준 순열 중요도
    CRM.W3_CHURN_CONFUSION_V2  : VALID 혼동행렬
    CRM.W3_CHURN_ROC_VALID     : VALID ROC 곡선 좌표
    CRM.W3_CHURN_MODEL_CONFIG  : 모델 설정 기록

  중요한 평가 원칙
    1. 전처리와 모델 학습은 TRAIN에만 적합합니다.
    2. 실제 성능은 시간상 뒤에 있는 VALID만으로 판단합니다.
    3. TRAIN+VALID 혼합 AUC는 비교용 착시 지표일 뿐입니다.
    4. 이전 문서의 AUC 0.6551을 목표값으로 강제하지 않습니다.
==========================================================*/

options validvarname=any;

%let CRM_PATH=/home/student/crm_db;
libname crm "&CRM_PATH.";


/*==========================================================
  0. 입력 테이블 확인
==========================================================*/

%if %sysfunc(exist(crm.w3_churn_split_v2)) = 0 %then %do;
    %put ERROR: CRM.W3_CHURN_SPLIT_V2 테이블이 없습니다.;
    %put ERROR: WBS 3.2 코드를 먼저 정상 실행하십시오.;
    %abort cancel;
%end;

%else %do;
    %put NOTE: CRM.W3_CHURN_SPLIT_V2 테이블을 확인했습니다.;
%end;


/* 이전 3.3 결과만 삭제합니다. */
proc datasets library=crm nolist nowarn;
    delete
        w3_churn_scored_v2
        w3_churn_metrics_v2
        w3_churn_importance_v2
        w3_churn_confusion_v2
        w3_churn_roc_valid
        w3_churn_model_config;
quit;


/*==========================================================
  1. 모델링 전 SAS 단계 누수 점검
==========================================================*/

title "WBS 3.3-1. 피처에 미래 거래일이 포함되었는지 확인";

proc sql;
    select
        split_role,
        count(*) as row_count,
        sum(last_purchase_date > snapshot_cutoff)
            as future_feature_date_count,
        min(snapshot_cutoff) format=yymmdd10. as snapshot_cutoff,
        max(label_end_date) format=yymmdd10. as label_end_date
    from crm.w3_churn_split_v2
    group by split_role;
quit;

title;


/*==========================================================
  2. Python에서 Gradient Boosting 모델 학습 및 평가

  수치형 피처 14개와 범주형 피처 2개를 사용합니다.
  결측 대체와 범주형 인코딩도 TRAIN에서만 학습됩니다.
==========================================================*/

proc python;
submit;

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
#   avg_shipping, coupon_usage_rate, coupon_click_rate, tenure
#
# 확장 수치형 6개
#   product_category_count, category_concentration,
#   avg_days_between_orders, std_days_between_orders,
#   last_coupon_used, clv_proxy
# ---------------------------------------------------------

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

endsubmit;
quit;


/*==========================================================
  3. SAS 결과표와 시각화
==========================================================*/

title "WBS 3.3-2. 이탈예측 평가 결과";

proc print data=crm.w3_churn_metrics_v2 noobs label;
    format
        churn_rate percent8.2
        roc_auc pr_auc accuracy balanced_accuracy
        precision recall f1_score 8.4;
run;

title "WBS 3.3-3. VALID 혼동행렬";

proc print data=crm.w3_churn_confusion_v2 noobs label;
run;

title "WBS 3.3-4. VALID 순열 중요도";

proc print data=crm.w3_churn_importance_v2(obs=16) noobs label;
    var
        importance_rank
        feature_name
        importance_mean
        importance_std;
run;

title "WBS 3.3-5. VALID ROC 곡선";

proc sgplot data=crm.w3_churn_roc_valid;
    series
        x=false_positive_rate
        y=true_positive_rate
        / lineattrs=(color=blue thickness=2);

    lineparm
        x=0 y=0 slope=1
        / lineattrs=(color=gray pattern=dash);

    xaxis label="False Positive Rate" min=0 max=1 grid;
    yaxis label="True Positive Rate" min=0 max=1 grid;
run;

title;


/*==========================================================
  4. 결과 테이블 생성 여부 확인
==========================================================*/

%macro check_outputs;

    %local missing_output;
    %let missing_output=0;

    %if %sysfunc(exist(crm.w3_churn_scored_v2)) = 0
        %then %let missing_output=1;

    %if %sysfunc(exist(crm.w3_churn_metrics_v2)) = 0
        %then %let missing_output=1;

    %if %sysfunc(exist(crm.w3_churn_importance_v2)) = 0
        %then %let missing_output=1;

    %if %sysfunc(exist(crm.w3_churn_confusion_v2)) = 0
        %then %let missing_output=1;

    %if %sysfunc(exist(crm.w3_churn_roc_valid)) = 0
        %then %let missing_output=1;

    %if %sysfunc(exist(crm.w3_churn_model_config)) = 0
        %then %let missing_output=1;

    %if &missing_output. = 0 %then %do;
        %put NOTE: WBS 3.3 결과 테이블 여섯 개가 모두 생성되었습니다.;
    %end;

    %else %do;
        %put ERROR: WBS 3.3 결과 테이블 중 생성되지 않은 것이 있습니다.;
        %abort cancel;
    %end;

%mend;

%check_outputs;

/*==========================================================
  WBS 3.3 완료
==========================================================*/

/*==========================================================
  WBS 3.4. 중간산출물 정리체계 수립 및 실행

  목적
    1. WBS 3.1-A부터 3.3까지의 필수 산출물을 목록으로 관리합니다.
    2. 필수 테이블의 존재 여부와 행·열 개수를 확인합니다.
    3. 중간 계산용 WORK.W3_ 테이블을 삭제합니다.
    4. RAW_, STG_, CLEAN_, W2_ 및 최종 W3_ 테이블은 삭제하지 않습니다.

  생성 테이블
    CRM.W3_FINAL_QA       : 필수 산출물 존재 여부
    CRM.W3_CLEANUP_LOG    : 정리 실행 기록
    CRM.W3_OUTPUT_CATALOG : CRM의 W3_ 테이블 목록

  주의
    현재 3.1~3.3 코드는 중간 계산을 WORK에 저장하도록 설계했습니다.
    따라서 CRM 라이브러리에서는 임의의 테이블을 삭제하지 않습니다.
==========================================================*/

options validvarname=any;

%let CRM_PATH=/home/student/crm_db;
libname crm "&CRM_PATH.";


/*==========================================================
  0. CRM 라이브러리 연결 확인
==========================================================*/

%if %sysfunc(libref(crm)) ne 0 %then %do;
    %put ERROR: CRM 라이브러리가 정상적으로 연결되지 않았습니다.;
    %abort cancel;
%end;

%else %do;
    %put NOTE: CRM 라이브러리가 정상적으로 연결되었습니다.;
%end;


/* 이전 3.4 보고서만 다시 만듭니다. */
proc datasets library=crm nolist nowarn;
    delete
        w3_final_qa
        w3_cleanup_log
        w3_output_catalog;
quit;


/*==========================================================
  1. WBS 3.1-A~3.3 필수 산출물 목록

  앞으로 3.5~3.9 결과가 만들어지면 이 표에 같은 형식으로 추가합니다.
==========================================================*/

data work.w3_required_outputs;

    length
        wbs_step $8
        table_name $32
        table_purpose $120;

    wbs_step="3.1-A";
    table_name="W3_MODEL_INPUT";
    table_purpose="RFM 원본·로그·표준화 고객 데이터";
    output;

    wbs_step="3.1-A";
    table_name="W3_RFM_PROFILE";
    table_purpose="RFM 기술통계와 왜도";
    output;

    wbs_step="3.1-A";
    table_name="W3_SCALER_STATS";
    table_purpose="RFM 표준화 기준값";
    output;

    wbs_step="3.1-B";
    table_name="W3_K_EVAL";
    table_purpose="RFM K 후보별 군집 품질 비교";
    output;

    wbs_step="3.2";
    table_name="W3_CHURN_WINDOW_COMPARE";
    table_purpose="30·60·90·120일 이탈률 비교";
    output;

    wbs_step="3.2";
    table_name="W3_CHURN_SPLIT_V2";
    table_purpose="시간 순서대로 분리된 이탈예측 피처";
    output;

    wbs_step="3.2";
    table_name="W3_CHURN_FEATURE_PROFILE";
    table_purpose="이탈예측 피처별 기술통계";
    output;

    wbs_step="3.2";
    table_name="W3_CHURN_QA_SUMMARY";
    table_purpose="시간 분리 데이터 품질 요약";
    output;

    wbs_step="3.3";
    table_name="W3_CHURN_SCORED_V2";
    table_purpose="고객별 실제 이탈값과 예측확률";
    output;

    wbs_step="3.3";
    table_name="W3_CHURN_METRICS_V2";
    table_purpose="TRAIN·VALID·혼합 평가 결과";
    output;

    wbs_step="3.3";
    table_name="W3_CHURN_IMPORTANCE_V2";
    table_purpose="VALID 순열 중요도";
    output;

    wbs_step="3.3";
    table_name="W3_CHURN_CONFUSION_V2";
    table_purpose="VALID 혼동행렬";
    output;

    wbs_step="3.3";
    table_name="W3_CHURN_ROC_VALID";
    table_purpose="VALID ROC 곡선 좌표";
    output;

    wbs_step="3.3";
    table_name="W3_CHURN_MODEL_CONFIG";
    table_purpose="이탈예측 모델 설정 기록";
    output;

run;


/*==========================================================
  2. 필수 산출물 존재 여부와 크기 확인
==========================================================*/

proc sql;

    create table crm.w3_final_qa as
    select
        a.wbs_step,
        a.table_name,
        a.table_purpose,
        case
            when b.memname is not missing then 1
            else 0
        end as exists_flag,
        b.nobs as row_count,
        b.nvar as column_count,
        b.crdate as created_at format=datetime19.,
        b.modate as modified_at format=datetime19.
    from work.w3_required_outputs as a
    left join dictionary.tables as b
        on  b.libname="CRM"
        and b.memtype="DATA"
        and b.memname=upcase(a.table_name)
    order by a.wbs_step, a.table_name;

quit;


title "WBS 3.4-1. 필수 산출물 존재 여부";

proc print data=crm.w3_final_qa noobs label;
run;

title;


/* 누락된 필수 산출물 개수를 매크로 변수에 저장합니다. */
proc sql noprint;
    select sum(exists_flag=0)
    into :missing_output_count trimmed
    from crm.w3_final_qa;
quit;

%put NOTE: 누락된 필수 산출물 개수 = &missing_output_count.;


/*==========================================================
  3. 데이터 내용의 핵심 일관성 확인
==========================================================*/

title "WBS 3.4-2. 3.1 RFM 고객키 점검";

proc sql;
    select
        count(*) as total_rows,
        count(distinct customer_id) as unique_customers,
        calculated total_rows-calculated unique_customers
            as duplicate_rows
    from crm.w3_model_input;
quit;

title "WBS 3.4-3. 3.2 시간 분리 데이터 점검";

proc sql;
    select
        split_role,
        count(*) as row_count,
        count(distinct customer_id) as unique_customers,
        sum(last_purchase_date > snapshot_cutoff)
            as future_feature_date_count,
        mean(churn_flag) as churn_rate format=percent8.2
    from crm.w3_churn_split_v2
    group by split_role;
quit;

title "WBS 3.4-4. 3.3 공식 VALID 성능 확인";

proc print
    data=crm.w3_churn_metrics_v2(
        where=(dataset_role="VALID")
    )
    noobs label;
run;

title;


/*==========================================================
  4. 정리 대상인 WORK.W3_ 임시 테이블 개수 확인
==========================================================*/

proc sql noprint;

    select count(*)
    into :work_w3_count trimmed
    from dictionary.tables
    where libname="WORK"
      and memtype="DATA"
      and upcase(memname) like "W3\_%" escape "\";

quit;

%put NOTE: 삭제 전 WORK.W3_ 임시 테이블 개수 = &work_w3_count.;


/* 정리 실행 기록을 영구 테이블로 남깁니다. */
data crm.w3_cleanup_log;

    length cleanup_scope $30 cleanup_action $120;

    cleanup_datetime = datetime();
    format cleanup_datetime datetime19.;

    cleanup_scope = "WORK.W3_";
    temporary_table_count = &work_w3_count.;
    cleanup_action =
        "WORK의 W3_ 중간 테이블 삭제. CRM 영구 테이블은 보존";

run;


/*==========================================================
  5. CRM 라이브러리의 W3_ 영구 테이블 목록 저장
==========================================================*/

proc sql;

    create table crm.w3_output_catalog as
    select
        memname as table_name,
        nobs as row_count,
        nvar as column_count,
        crdate as created_at format=datetime19.,
        modate as modified_at format=datetime19.
    from dictionary.tables
    where libname="CRM"
      and memtype="DATA"
      and upcase(memname) like "W3\_%" escape "\"
    order by memname;

quit;


title "WBS 3.4-5. CRM W3_ 영구 산출물 목록";

proc print data=crm.w3_output_catalog noobs label;
run;

title;


/*==========================================================
  6. WORK의 W3_ 중간 테이블 실제 삭제

  WORK는 현재 SAS 세션의 임시 공간입니다.
  CRM의 영구 결과에는 영향을 주지 않습니다.
==========================================================*/

proc datasets library=work nolist nowarn;
    delete w3_:;
quit;


/* 삭제가 완료되었는지 다시 확인합니다. */
proc sql;

    title "WBS 3.4-6. 정리 후 WORK.W3_ 테이블 개수";

    select count(*) as remaining_work_w3_tables
    from dictionary.tables
    where libname="WORK"
      and memtype="DATA"
      and upcase(memname) like "W3\_%" escape "\";

quit;

title;


/*==========================================================
  7. 최종 상태 메시지
==========================================================*/

data _null_;

    if &missing_output_count. = 0 then do;
        put "NOTE: WBS 3.1-A부터 3.3까지의 필수 산출물이 모두 존재합니다.";
        put "NOTE: WBS 3.4 중간산출물 정리가 완료되었습니다.";
    end;

    else do;
        put "WARNING: 누락된 필수 산출물이 있습니다.";
        put "WARNING: CRM.W3_FINAL_QA에서 EXISTS_FLAG=0인 행을 확인하십시오.";
    end;

run;

/*==========================================================
  WBS 3.4 완료
==========================================================*/

/*====================================================================
  WBS 3.5~3.9. RFM-P 세분화 및 최종 고객 분석 테이블 생성

  실행 환경:
    PROC PYTHON을 지원하는 기존 SAS Studio

  기존 입력 테이블:
    CRM.CLEAN_ONLINE          : 정제된 거래 상세
    CRM.W2_CUSTOMER_FEATURES  : 고객 단위 특성
    CRM.W3_MODEL_INPUT        : 3.1-A에서 만든 RFM 변환 데이터
    CRM.W3_CHURN_SCORED_V2    : 3.3 결과, 있으면 3.9에서 결합

  이번 Python 버전의 주요 산출물:
    CRM.W3_RFMP_CATEGORY_VALUE_PY
    CRM.W3_CUSTOMER_CATEGORY_P_PY
    CRM.W3_RFMP_BASE_PY
    CRM.W3_RFMP_STANDARDIZED_PY
    CRM.W3_RFMP_CLUSTERED_PY
    CRM.W3_RFMP_CLUSTER_CV_PY
    CRM.W3_RFMP_WEIGHTS_PY
    CRM.W3_CUSTOMER_RFMP_PY
    CRM.W3_RFMP_TIER_PROFILE_PY
    CRM.W3_RFMP_CATEGORY_TOP5_PY
    CRM.W3_CUSTOMER_ANALYTIC_BASE_PY
    CRM.W3_RFMP_QA_SUMMARY_PY
    CRM.W3_RFMP_OUTPUT_CATALOG_PY

  중요:
    기존 SAS 전용 결과와 동시에 보존하기 위해 Python 결과에는
    _PY 접미사를 붙입니다. 따라서 기존 결과를 덮어쓰지 않습니다.
====================================================================*/


/*====================================================================
  0. 기본 설정 및 CRM 라이브러리 연결
====================================================================*/

options validvarname=any;

/* 3.1~3.4에서 사용한 경로와 같습니다. */
%let CRM_PATH=/home/student/crm_db;
libname crm "&CRM_PATH.";


/*====================================================================
  1. 필수 입력 테이블 확인
====================================================================*/

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
    ds=crm.w2_customer_features,
    previous_step=Week 2-3 고객 특성 생성
);

%require_table(
    ds=crm.w3_model_input,
    previous_step=WBS 3.1-A RFM 데이터 준비
);


/* 3.3 이탈예측 결과는 선택 입력입니다. */
%let HAS_CHURN=0;

%if %sysfunc(exist(crm.w3_churn_scored_v2)) %then %do;
    %let HAS_CHURN=1;
    %put NOTE: CRM.W3_CHURN_SCORED_V2를 확인했습니다. 3.9에서 결합합니다.;
%end;
%else %do;
    %put NOTE: CRM.W3_CHURN_SCORED_V2가 없어도 3.5~3.8은 실행됩니다.;
%end;


/*====================================================================
  2. 이전 Python 버전 결과 삭제

  SAS 전용 결과에는 _PY가 없으므로 삭제되지 않습니다.
====================================================================*/

proc datasets library=crm nolist nowarn;
    delete
        w3_rfmp_category_value_py
        w3_customer_category_p_py
        w3_rfmp_base_py
        w3_rfmp_standardized_py
        w3_rfmp_clustered_py
        w3_rfmp_cluster_cv_py
        w3_rfmp_weights_py
        w3_customer_rfmp_py
        w3_rfmp_tier_profile_py
        w3_rfmp_category_top5_py
        w3_customer_analytic_base_py
        w3_rfmp_qa_summary_py
        w3_rfmp_output_catalog_py;
quit;


/*====================================================================
  3.5~3.9. PROC PYTHON 통합 실행
====================================================================*/

proc python;
submit;

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

from sklearn.cluster import KMeans
from sklearn.preprocessing import StandardScaler


# ====================================================================
# 공통 함수
# ====================================================================

def normalize_columns(frame):
    """변수명의 앞뒤 공백을 없애고 소문자로 통일합니다."""
    result = frame.copy()
    result.columns = [
        str(column).strip().lower()
        for column in result.columns
    ]
    return result


def require_columns(frame, columns, table_name):
    """필수 변수가 없으면 뒤에서 애매한 오류가 나기 전에 중단합니다."""
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
    """고객ID를 문자열로 바꾸고 불필요한 공백을 제거합니다."""
    return series.astype(str).str.strip()


def save_sas(frame, table_name):
    """DataFrame의 인덱스를 제거하고 CRM 라이브러리에 저장합니다."""
    output = frame.reset_index(drop=True).copy()

    # category 자료형은 SAS 전송 전에 일반 문자열로 바꿉니다.
    for column in output.select_dtypes(include=["category"]).columns:
        output[column] = output[column].astype(str)

    SAS.df2sd(
        output,
        dataset=f"crm.{table_name}"
    )


print("=" * 78)
print("WBS 3.5~3.9. PROC PYTHON RFM-P 통합 분석")
print("=" * 78)


# ====================================================================
# 3.5. 제품가치 P 계산
#
# 정의:
#   1) 카테고리 가치 = 고유 주문횟수 x 수량가중 평균단가
#   2) 카테고리 가치를 낮은 순서부터 1~20점으로 변환
#   3) 고객 P = 고객의 카테고리별 주문횟수 x 카테고리 점수의 합
#
# 개선한 이유:
#   거래ID는 고객 간에 반복될 수 있으므로 order_key를 사용합니다.
#   상품 행 개수 대신 고유 주문횟수를 사용하여 중복 상품 행의 영향을
#   줄이고, 평균단가는 총 상품매출/총 수량으로 계산합니다.
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


required_online = [
    "customer_id",
    "order_key",
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


# 고객ID와 문자 변수의 불필요한 공백을 제거합니다.
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

model_input["customer_id"] = clean_customer_id(
    model_input["customer_id"]
)

customer_features["customer_id"] = clean_customer_id(
    customer_features["customer_id"]
)


# 계산에 필요한 숫자형 변수를 확실하게 숫자로 변환합니다.
for column in [
    "quantity",
    "avg_price",
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

for column in ["recency", "frequency", "monetary"]:
    model_input[column] = pd.to_numeric(
        model_input[column],
        errors="coerce"
    )


# 정제 단계에서 오류로 판단한 행만 분석에서 제외합니다.
# 대량구매·고액구매 플래그는 실제 거래일 수 있으므로 제외하지 않습니다.
valid_mask = (
    online["flag_missing_core"].eq(0)
    & online["flag_return"].eq(0)
    & online["flag_zero_quantity"].eq(0)
    & online["flag_invalid_price"].eq(0)
    & online["flag_customer_unmatched"].eq(0)
)

valid_online = online.loc[valid_mask].copy()

valid_online["line_amount"] = (
    valid_online["quantity"]
    * valid_online["avg_price"]
)

if len(valid_online) == 0:
    raise ValueError(
        "3.5 계산에 사용할 유효 거래 행이 없습니다. "
        "Week 1 정제 플래그를 확인하십시오."
    )


# 카테고리별 주문횟수·수량·상품매출을 계산합니다.
category_value = (
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

category_value["category_avg_unit_price"] = (
    category_value["category_sales"]
    / category_value["category_quantity"].replace(0, np.nan)
)

category_value["category_value_raw"] = (
    category_value["category_order_count"]
    * category_value["category_avg_unit_price"]
)


# 카테고리 개수가 20개가 아니어도 1~20점 범위가 유지됩니다.
# 같은 원시가치에는 같은 백분위 점수가 부여됩니다.
category_value["category_value_score"] = (
    np.ceil(
        category_value["category_value_raw"]
        .rank(method="average", pct=True)
        * 20
    )
    .clip(1, 20)
    .astype(int)
)

category_value = category_value.sort_values(
    ["category_value_score", "category_value_raw"],
    ascending=[True, True]
).reset_index(drop=True)


# 고객별·카테고리별 고유 주문횟수를 계산합니다.
customer_category_p = (
    valid_online
    .groupby(
        ["customer_id", "product_category"],
        as_index=False,
        dropna=False
    )
    .agg(
        customer_category_orders=("order_key", "nunique")
    )
    .merge(
        category_value[
            ["product_category", "category_value_score"]
        ],
        on="product_category",
        how="left",
        validate="many_to_one"
    )
)

customer_category_p["category_p_contribution"] = (
    customer_category_p["customer_category_orders"]
    * customer_category_p["category_value_score"]
)

customer_p = (
    customer_category_p
    .groupby("customer_id", as_index=False)
    .agg(
        product_value_p=("category_p_contribution", "sum"),
        p_category_count=("product_category", "nunique")
    )
)


# 3.1-A의 RFM에 P를 결합합니다.
rfmp_base = (
    model_input[required_rfm]
    .merge(
        customer_p,
        on="customer_id",
        how="left",
        validate="one_to_one"
    )
)

rfmp_base["product_value_p"] = (
    rfmp_base["product_value_p"].fillna(0)
)

rfmp_base["p_category_count"] = (
    rfmp_base["p_category_count"].fillna(0)
)


# RFM-P 필수값과 고객ID의 고유성을 확인합니다.
rfmp_numeric = [
    "recency",
    "frequency",
    "monetary",
    "product_value_p"
]

if rfmp_base["customer_id"].duplicated().any():
    raise ValueError(
        "CRM.W3_MODEL_INPUT에 중복 고객ID가 있습니다."
    )

if rfmp_base[rfmp_numeric].isna().any().any():
    raise ValueError(
        "RFM-P 필수 변수에 결측값이 있습니다."
    )

if not np.isfinite(
    rfmp_base[rfmp_numeric].to_numpy(dtype=float)
).all():
    raise ValueError(
        "RFM-P 필수 변수에 무한대 값이 있습니다."
    )

if (rfmp_base["recency"] < 0).any():
    raise ValueError("Recency에 음수가 있습니다.")

if (rfmp_base["frequency"] <= 0).any():
    raise ValueError("Frequency에 0 이하 값이 있습니다.")

if (rfmp_base["monetary"] < 0).any():
    raise ValueError("Monetary에 음수가 있습니다.")


# 오른쪽 꼬리가 긴 F/M/P는 log(1+x)로 완화합니다.
# Recency는 원래 단위를 유지합니다.
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
print(f"유효 거래 행: {len(valid_online):,}")
print(f"카테고리 수: {len(category_value):,}")
print(f"RFM-P 고객 수: {len(rfmp_base):,}")

print("\n[카테고리 가치 점수]")
print(
    category_value[
        [
            "product_category",
            "category_order_count",
            "category_avg_unit_price",
            "category_value_raw",
            "category_value_score"
        ]
    ]
    .round(2)
    .to_string(index=False)
)


# ====================================================================
# 3.6. R/F/M/P 1차원 K-means와 CV 기반 가중치 계산
#
# 고정 군집 수:
#   R=3, F=4, M=2, P=4
#
# 3.1-B와의 관계:
#   3.1-B는 RFM 세 변수를 함께 넣은 전체 고객군 K를 비교한 단계입니다.
#   여기서는 각 지표의 일관성을 측정해 가중치를 만들기 위해 지표별로
#   1차원 K-means를 따로 수행합니다. 두 분석은 목적이 다릅니다.
#
# CV 가중치:
#   군집별 CV = 표준편차 / 평균
#   지표별 CV는 군집 크기로 가중평균합니다.
#   CV가 작을수록 일관성이 높으므로 1/CV를 원시가중치로 사용합니다.
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


# Recency가 0이어도 CV 분모가 0이 되지 않도록 1을 더합니다.
rfmp_base["recency_cv_value"] = (
    rfmp_base["recency"] + 1
)

rfmp_standardized = rfmp_base[
    [
        "customer_id",
        "recency",
        "frequency",
        "monetary",
        "product_value_p"
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
    z_values = scaler.fit_transform(input_values).ravel()

    model = KMeans(
        n_clusters=k,
        random_state=2026,
        n_init=50,
        max_iter=500
    )

    raw_cluster = model.fit_predict(
        z_values.reshape(-1, 1)
    )


    # sklearn 군집번호는 임의이므로 중심값이 낮은 군집부터 1,2,...로 바꿉니다.
    center_order = np.argsort(
        model.cluster_centers_.ravel()
    )

    cluster_map = {
        int(raw_number): int(order + 1)
        for order, raw_number in enumerate(center_order)
    }

    ordered_cluster = np.array(
        [cluster_map[int(value)] for value in raw_cluster],
        dtype=int
    )

    metric_lower = metric.lower()

    rfmp_standardized[
        f"z_{metric_lower}"
    ] = z_values

    rfmp_clustered[
        f"{metric_lower}_cluster"
    ] = ordered_cluster


    # 군집별 CV를 원래 고객 행 기준으로 계산합니다.
    cv_values = rfmp_base[cv_column].to_numpy(dtype=float)

    for cluster_number in range(1, k + 1):

        cluster_values = cv_values[
            ordered_cluster == cluster_number
        ]

        cluster_n = int(len(cluster_values))
        mean_value = float(np.mean(cluster_values))

        if cluster_n > 1:
            std_value = float(
                np.std(cluster_values, ddof=1)
            )
        else:
            std_value = 0.0

        if np.isclose(mean_value, 0.0):
            cv_value = np.nan
        else:
            cv_value = float(std_value / abs(mean_value))

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


cluster_cv = pd.DataFrame(cluster_cv_rows)

weight_rows = []

for metric in ["R", "F", "M", "P"]:

    part = cluster_cv.loc[
        (cluster_cv["metric"] == metric)
        & cluster_cv["cv"].notna()
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
        "k": int(metric_configs[metric]["k"]),
        "weighted_cv": weighted_cv,
        "raw_weight": float(1.0 / weighted_cv)
    })


rfmp_weights = pd.DataFrame(weight_rows)

rfmp_weights["final_weight"] = (
    rfmp_weights["raw_weight"]
    / rfmp_weights["raw_weight"].sum()
)


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


print("\n[3.6 지표별 CV와 최종 가중치]")
print(
    rfmp_weights.round(6).to_string(index=False)
)


# 1차원 군집 결과를 그래프로 확인합니다.
fig, axes = plt.subplots(
    2,
    2,
    figsize=(13, 8)
)

for ax, metric in zip(axes.ravel(), ["R", "F", "M", "P"]):

    config = metric_configs[metric]
    original_column = config["original"]
    cluster_column = f"{metric.lower()}_cluster"

    for cluster_number in sorted(
        rfmp_clustered[cluster_column].unique()
    ):

        values = rfmp_clustered.loc[
            rfmp_clustered[cluster_column] == cluster_number,
            original_column
        ]

        ax.hist(
            values,
            bins=25,
            alpha=0.55,
            label=f"Cluster {cluster_number}"
        )

    ax.set_title(
        f"{metric} 1D K-Means (K={config['k']})"
    )
    ax.set_xlabel(original_column)
    ax.set_ylabel("Customers")
    ax.legend(fontsize=8)

plt.tight_layout()
SAS.pyplot(plt)
plt.close(fig)


# ====================================================================
# 3.7. RFMP 점수 계산 및 6개 고객등급 부여
#
# 이상치 한 건이 전체 Min-Max 범위를 지배하지 않도록 백분위 점수를
# 사용합니다. R은 작을수록 좋고 F/M/P는 클수록 좋습니다.
#
# 최종 등급:
#   VIP / Diamond / Platinum / Gold / Silver / Bronze
# ====================================================================

weight_map = dict(
    zip(
        rfmp_weights["metric"],
        rfmp_weights["final_weight"]
    )
)


# 고객ID 순서로 먼저 정렬하여 동점 처리 결과도 재실행할 때 같게 만듭니다.
customer_rfmp = rfmp_clustered.sort_values(
    "customer_id"
).reset_index(drop=True).copy()


# Recency는 작을수록 높은 점수를 받습니다.
customer_rfmp["r_score"] = (
    customer_rfmp["recency"]
    .rank(
        method="average",
        ascending=False,
        pct=True
    )
    * 100
)

# F/M/P는 클수록 높은 점수를 받습니다.
customer_rfmp["f_score"] = (
    customer_rfmp["frequency"]
    .rank(method="average", ascending=True, pct=True)
    * 100
)

customer_rfmp["m_score"] = (
    customer_rfmp["monetary"]
    .rank(method="average", ascending=True, pct=True)
    * 100
)

customer_rfmp["p_score"] = (
    customer_rfmp["product_value_p"]
    .rank(method="average", ascending=True, pct=True)
    * 100
)


customer_rfmp["rfmp_score"] = (
    customer_rfmp["r_score"] * weight_map["R"]
    + customer_rfmp["f_score"] * weight_map["F"]
    + customer_rfmp["m_score"] * weight_map["M"]
    + customer_rfmp["p_score"] * weight_map["P"]
)


# qcut에 고객ID 순서 기반의 동점 해제 순위를 넣어 6개 집단을 만듭니다.
tier_labels_low_to_high = [
    "Bronze",
    "Silver",
    "Gold",
    "Platinum",
    "Diamond",
    "VIP"
]

score_order = customer_rfmp["rfmp_score"].rank(
    method="first",
    ascending=True
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

customer_rfmp = customer_rfmp.sort_values(
    ["tier_code", "rfmp_score"],
    ascending=[True, False]
).reset_index(drop=True)


save_sas(
    customer_rfmp,
    "w3_customer_rfmp_py"
)


print("\n[3.7 RFMP 등급별 고객 수]")
print(
    customer_rfmp
    .groupby(
        ["tier_code", "rfmp_tier"],
        as_index=False
    )
    .agg(customer_count=("customer_id", "nunique"))
    .sort_values("tier_code")
    .to_string(index=False)
)


# ====================================================================
# 3.8. 등급 프로파일과 대표 카테고리 Top 5
#
# 단순 구매건수만 사용하면 모든 등급에서 인기 카테고리가 반복될 수
# 있습니다. 따라서 등급 내부 비중을 전체 비중으로 나눈 Lift를 사용해
# 해당 등급에서 상대적으로 두드러지는 카테고리를 찾습니다.
# ====================================================================

tier_profile = (
    customer_rfmp
    .groupby(
        ["tier_code", "rfmp_tier"],
        as_index=False
    )
    .agg(
        customer_count=("customer_id", "nunique"),
        avg_recency=("recency", "mean"),
        avg_frequency=("frequency", "mean"),
        avg_monetary=("monetary", "mean"),
        avg_product_value_p=("product_value_p", "mean"),
        avg_rfmp_score=("rfmp_score", "mean"),
        min_rfmp_score=("rfmp_score", "min"),
        max_rfmp_score=("rfmp_score", "max")
    )
    .sort_values("tier_code")
)

tier_profile["customer_pct"] = (
    tier_profile["customer_count"]
    / tier_profile["customer_count"].sum()
    * 100
)


# 거래 행에 고객 등급을 붙입니다.
tier_transactions = valid_online.merge(
    customer_rfmp[
        ["customer_id", "tier_code", "rfmp_tier"]
    ],
    on="customer_id",
    how="inner",
    validate="many_to_one"
)


# 등급-카테고리 조합별 지표를 계산합니다.
tier_category = (
    tier_transactions
    .groupby(
        ["tier_code", "rfmp_tier", "product_category"],
        as_index=False,
        dropna=False
    )
    .agg(
        category_orders=("order_key", "nunique"),
        category_customers=("customer_id", "nunique"),
        category_sales=("line_amount", "sum")
    )
)


# 주문 한 건에 여러 카테고리가 있을 수 있으므로 분모도 동일한
# 카테고리-주문 발생건수의 합으로 계산합니다.
tier_totals = (
    tier_category
    .groupby(
        ["tier_code", "rfmp_tier"],
        as_index=False
    )
    .agg(
        tier_category_order_sum=("category_orders", "sum")
    )
)

overall_category = (
    tier_category
    .groupby("product_category", as_index=False)
    .agg(
        overall_category_orders=("category_orders", "sum")
    )
)

overall_order_sum = float(
    overall_category["overall_category_orders"].sum()
)

tier_category = (
    tier_category
    .merge(
        tier_totals,
        on=["tier_code", "rfmp_tier"],
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
    tier_category["category_orders"]
    / tier_category["tier_category_order_sum"]
)

tier_category["overall_category_share"] = (
    tier_category["overall_category_orders"]
    / overall_order_sum
)

tier_category["lift"] = (
    tier_category["tier_category_share"]
    / tier_category["overall_category_share"].replace(0, np.nan)
)


# 지나치게 적은 구매건수로 계산된 큰 Lift는 우연일 수 있습니다.
# 현재 데이터 규모를 고려해 등급 내 주문 5건 이상만 Top 5 후보로 둡니다.
top5_candidates = tier_category.loc[
    tier_category["category_orders"] >= 5
].copy()

top5 = (
    top5_candidates
    .sort_values(
        [
            "tier_code",
            "lift",
            "category_orders",
            "product_category"
        ],
        ascending=[True, False, False, True]
    )
    .copy()
)

top5["category_rank"] = (
    top5.groupby("tier_code").cumcount() + 1
)

top5 = top5.loc[
    top5["category_rank"] <= 5
].reset_index(drop=True)


save_sas(
    tier_profile,
    "w3_rfmp_tier_profile_py"
)

save_sas(
    top5,
    "w3_rfmp_category_top5_py"
)


print("\n[3.8 등급별 프로파일]")
print(
    tier_profile.round(2).to_string(index=False)
)

print("\n[3.8 등급별 대표 카테고리 Top 5: Lift 기준]")
print(
    top5[
        [
            "tier_code",
            "rfmp_tier",
            "category_rank",
            "product_category",
            "category_orders",
            "lift"
        ]
    ]
    .round(3)
    .to_string(index=False)
)


# RFMP 점수의 등급별 분포를 확인합니다.
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

fig, ax = plt.subplots(figsize=(10, 5))

ax.boxplot(
    box_values,
    labels=tier_order,
    showfliers=False
)

ax.set_title("RFMP Score by Customer Tier")
ax.set_xlabel("RFMP Tier")
ax.set_ylabel("RFMP Score")
ax.grid(axis="y", alpha=0.3)

plt.tight_layout()
SAS.pyplot(plt)
plt.close(fig)


# 등급별 대표 카테고리를 2열 x 3행으로 표시합니다.
fig, axes = plt.subplots(
    3,
    2,
    figsize=(14, 14)
)

for ax, tier in zip(axes.ravel(), tier_order):

    part = (
        top5.loc[top5["rfmp_tier"] == tier]
        .sort_values("lift", ascending=True)
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
    "Top 5 Distinctive Product Categories by RFMP Tier",
    y=1.01
)

plt.tight_layout()
SAS.pyplot(plt)
plt.close(fig)


# ====================================================================
# 3.9. 이탈예측 결과 결합, 최종 QA 및 산출물 목록 생성
#
# CRM.W3_CHURN_SCORED_V2가 있으면 VALID 결과만 고객 분석 테이블에
# 붙입니다. 이탈예측 테이블이 없어도 RFMP 결과와 QA는 저장됩니다.
# ====================================================================

# W2 고객 특성을 중심으로 RFMP 결과를 결합합니다.
rfmp_add_columns = [
    "customer_id",
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
    "rfmp_tier"
]

analytic_base = customer_features.merge(
    customer_rfmp[rfmp_add_columns],
    on="customer_id",
    how="left",
    validate="one_to_one"
)


has_churn = str(
    SAS.symget("HAS_CHURN")
).strip() == "1"

joined_churn_count = 0

if has_churn:

    churn = normalize_columns(
        SAS.sd2df("crm.w3_churn_scored_v2")
    )

    require_columns(
        churn,
        ["customer_id", "churn_probability"],
        "CRM.W3_CHURN_SCORED_V2"
    )

    churn["customer_id"] = clean_customer_id(
        churn["customer_id"]
    )

    if "split_role" in churn.columns:
        churn["split_role"] = (
            churn["split_role"]
            .astype(str)
            .str.strip()
            .str.upper()
        )

        churn_valid = churn.loc[
            churn["split_role"] == "VALID"
        ].copy()
    else:
        churn_valid = churn.copy()
        churn_valid["split_role"] = "VALID"

    churn_columns = [
        column
        for column in [
            "customer_id",
            "split_role",
            "actual_churn_flag",
            "churn_probability",
            "predicted_churn_flag"
        ]
        if column in churn_valid.columns
    ]

    churn_valid = (
        churn_valid[churn_columns]
        .sort_values("customer_id")
        .drop_duplicates(
            subset=["customer_id"],
            keep="last"
        )
    )

    analytic_base = analytic_base.merge(
        churn_valid,
        on="customer_id",
        how="left",
        validate="one_to_one"
    )

    joined_churn_count = int(
        analytic_base["churn_probability"]
        .notna()
        .sum()
    )

else:

    analytic_base["split_role"] = "NOT_AVAILABLE"
    analytic_base["actual_churn_flag"] = np.nan
    analytic_base["churn_probability"] = np.nan
    analytic_base["predicted_churn_flag"] = np.nan


save_sas(
    analytic_base,
    "w3_customer_analytic_base_py"
)


# ------------------------------
# 3.9-1. 자동 품질 점검표
# ------------------------------

qa_rows = []


def add_qa(check_item, actual_value, expected_value, passed, detail):
    qa_rows.append({
        "check_item": check_item,
        "actual_value": float(actual_value),
        "expected_value": float(expected_value),
        "status": "PASS" if passed else "REVIEW",
        "detail": detail
    })


input_customer_count = int(
    model_input["customer_id"].nunique()
)

rfmp_row_count = int(len(customer_rfmp))

rfmp_unique_customer_count = int(
    customer_rfmp["customer_id"].nunique()
)

missing_p_count = int(
    customer_rfmp["product_value_p"].isna().sum()
)

missing_tier_count = int(
    customer_rfmp["rfmp_tier"].isna().sum()
)

tier_count = int(
    customer_rfmp["rfmp_tier"].nunique()
)

weight_sum = float(
    rfmp_weights["final_weight"].sum()
)

top5_row_count = int(len(top5))


add_qa(
    "RFMP 행 수 = 입력 고객 수",
    rfmp_row_count,
    input_customer_count,
    rfmp_row_count == input_customer_count,
    "고객 한 명당 RFMP 결과 한 행이어야 합니다."
)

add_qa(
    "RFMP 고객ID 고유성",
    rfmp_unique_customer_count,
    rfmp_row_count,
    rfmp_unique_customer_count == rfmp_row_count,
    "중복 고객ID가 없어야 합니다."
)

add_qa(
    "제품가치 P 결측",
    missing_p_count,
    0,
    missing_p_count == 0,
    "P 결측은 0건이어야 합니다."
)

add_qa(
    "RFMP 등급 결측",
    missing_tier_count,
    0,
    missing_tier_count == 0,
    "모든 고객에게 등급이 있어야 합니다."
)

add_qa(
    "RFMP 등급 개수",
    tier_count,
    6,
    tier_count == 6,
    "VIP부터 Bronze까지 6개 등급이어야 합니다."
)

add_qa(
    "최종 가중치 합",
    weight_sum,
    1,
    np.isclose(weight_sum, 1.0, atol=1e-10),
    "R/F/M/P 가중치 합은 1이어야 합니다."
)

add_qa(
    "등급별 Top 5 최대 행 수",
    top5_row_count,
    30,
    top5_row_count > 0 and top5_row_count <= 30,
    "6개 등급 x 최대 5개이므로 1~30행이어야 합니다."
)

if has_churn:
    add_qa(
        "VALID 이탈확률 결합 건수",
        joined_churn_count,
        joined_churn_count,
        joined_churn_count > 0,
        "3.3의 VALID 이탈확률이 한 건 이상 결합되어야 합니다."
    )


qa_summary = pd.DataFrame(qa_rows)


# ------------------------------
# 3.9-2. 산출물 목록
# ------------------------------

catalog_rows = [
    (
        "W3_RFMP_CATEGORY_VALUE_PY",
        "제품카테고리",
        "카테고리별 구매가치 원시값과 1~20점"
    ),
    (
        "W3_CUSTOMER_CATEGORY_P_PY",
        "고객-제품카테고리",
        "고객의 카테고리별 주문횟수와 P 기여도"
    ),
    (
        "W3_RFMP_BASE_PY",
        "고객",
        "R/F/M/P 원본값과 로그 변환값"
    ),
    (
        "W3_RFMP_STANDARDIZED_PY",
        "고객",
        "R/F/M/P 군집용 표준화 값"
    ),
    (
        "W3_RFMP_CLUSTERED_PY",
        "고객",
        "지표별 1차원 K-means 군집 결과"
    ),
    (
        "W3_RFMP_CLUSTER_CV_PY",
        "지표-군집",
        "군집별 평균·표준편차·CV"
    ),
    (
        "W3_RFMP_WEIGHTS_PY",
        "지표",
        "CV 역수 방식의 R/F/M/P 최종 가중치"
    ),
    (
        "W3_CUSTOMER_RFMP_PY",
        "고객",
        "RFMP 점수와 6개 고객등급"
    ),
    (
        "W3_RFMP_TIER_PROFILE_PY",
        "RFMP 등급",
        "등급별 고객 수와 평균 R/F/M/P"
    ),
    (
        "W3_RFMP_CATEGORY_TOP5_PY",
        "RFMP 등급-제품카테고리",
        "Lift 기준 등급별 대표 카테고리 Top 5"
    ),
    (
        "W3_CUSTOMER_ANALYTIC_BASE_PY",
        "고객",
        "W2 특성·RFMP·선택적 이탈예측 통합 테이블"
    ),
    (
        "W3_RFMP_QA_SUMMARY_PY",
        "점검항목",
        "3.5~3.9 자동 품질 점검 결과"
    )
]

output_catalog = pd.DataFrame(
    catalog_rows,
    columns=[
        "table_name",
        "data_grain",
        "description"
    ]
)


save_sas(
    qa_summary,
    "w3_rfmp_qa_summary_py"
)

save_sas(
    output_catalog,
    "w3_rfmp_output_catalog_py"
)


print("\n[3.9 자동 품질 점검]")
print(qa_summary.to_string(index=False))

print("\n[3.9 최종 고객 분석 테이블]")
print(f"행 수: {len(analytic_base):,}")
print(f"열 수: {len(analytic_base.columns):,}")
print(f"VALID 이탈확률 결합 건수: {joined_churn_count:,}")


# P가 Frequency와 지나치게 비슷한지 참고용 상관계수를 출력합니다.
fp_correlation = float(
    customer_rfmp[["frequency", "product_value_p"]]
    .corr()
    .iloc[0, 1]
)

print(
    "\n참고: Frequency와 P의 상관계수 = "
    f"{fp_correlation:.4f}"
)

if abs(fp_correlation) >= 0.90:
    print(
        "주의: F와 P의 상관이 매우 높습니다. "
        "P가 독립적인 제품가치 정보를 충분히 추가하는지 "
        "다음 단계에서 검토해야 합니다."
    )


print("\nWBS 3.5~3.9 PROC PYTHON 분석이 완료되었습니다.")

endsubmit;
quit;


/*====================================================================
  4. Python 산출물 존재 여부 확인
====================================================================*/

%macro check_output(ds=);

    %if %sysfunc(exist(&ds.)) %then %do;
        %put NOTE: 생성 완료 - &ds.;
    %end;

    %else %do;
        %put ERROR: 생성 실패 - &ds.;
    %end;

%mend;

%check_output(ds=crm.w3_rfmp_category_value_py);
%check_output(ds=crm.w3_customer_category_p_py);
%check_output(ds=crm.w3_rfmp_base_py);
%check_output(ds=crm.w3_rfmp_standardized_py);
%check_output(ds=crm.w3_rfmp_clustered_py);
%check_output(ds=crm.w3_rfmp_cluster_cv_py);
%check_output(ds=crm.w3_rfmp_weights_py);
%check_output(ds=crm.w3_customer_rfmp_py);
%check_output(ds=crm.w3_rfmp_tier_profile_py);
%check_output(ds=crm.w3_rfmp_category_top5_py);
%check_output(ds=crm.w3_customer_analytic_base_py);
%check_output(ds=crm.w3_rfmp_qa_summary_py);
%check_output(ds=crm.w3_rfmp_output_catalog_py);


/*====================================================================
  5. 주요 결과 출력
====================================================================*/

title "WBS 3.5 카테고리별 제품가치 점수";
proc print data=crm.w3_rfmp_category_value_py noobs label;
    var
        product_category
        category_order_count
        category_avg_unit_price
        category_value_raw
        category_value_score;
    format
        category_avg_unit_price comma14.2
        category_value_raw comma16.2;
run;


title "WBS 3.6 R/F/M/P 최종 가중치";
proc print data=crm.w3_rfmp_weights_py noobs label;
    format
        weighted_cv 10.6
        raw_weight 10.6
        final_weight percent8.2;
run;


title "WBS 3.7 RFMP 등급별 고객 수";
proc freq data=crm.w3_customer_rfmp_py order=data;
    tables rfmp_tier / missing;
run;


title "WBS 3.8 RFMP 등급 프로파일";
proc print data=crm.w3_rfmp_tier_profile_py noobs label;
    format
        customer_pct 8.2
        avg_recency 10.2
        avg_frequency 10.2
        avg_monetary comma16.2
        avg_product_value_p comma14.2
        avg_rfmp_score 10.2
        min_rfmp_score 10.2
        max_rfmp_score 10.2;
run;


title "WBS 3.8 등급별 대표 카테고리 Top 5";
proc print data=crm.w3_rfmp_category_top5_py noobs label;
    var
        tier_code
        rfmp_tier
        category_rank
        product_category
        category_orders
        category_customers
        category_sales
        lift;
    format
        category_sales comma16.2
        lift 8.3;
run;


title "WBS 3.9 자동 품질 점검 결과";
proc print data=crm.w3_rfmp_qa_summary_py noobs label;
run;


title "WBS 3.9 생성 산출물 목록";
proc print data=crm.w3_rfmp_output_catalog_py noobs label;
run;


title "WBS 3.9 최종 고객 분석 테이블 구조";
proc contents data=crm.w3_customer_analytic_base_py varnum;
run;


title "WBS 3.9 최종 고객 분석 테이블 앞 10행";
proc print data=crm.w3_customer_analytic_base_py(obs=10) noobs;
run;

title;


%put NOTE: WBS 3.5~3.9 PROC PYTHON 전체 작업이 끝났습니다.;
%put NOTE: 기존 SAS 전용 결과와 Python _PY 결과를 모두 보존했습니다.;

