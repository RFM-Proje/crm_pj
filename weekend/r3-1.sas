 /*==========================================================
   3.1-A. RFM 원본·로그 변환·표준화 데이터 준비
 
   입력 테이블:
     CRM.W2_CUSTOMER_FEATURES
 
   생성 테이블:
     CRM.W3_MODEL_INPUT   : 고객별 RFM 및 표준화 변수
     CRM.W3_RFM_PROFILE   : RFM 기술통계와 왜도
     CRM.W3_SCALER_STATS  : 표준화에 사용한 평균과 표준편차
	유의사항
	이 단계의 frequency는 기존 주문 수 기준의 초기 Frequency이다.
	공식 Frequency는 3.2-A~3.4에서 비교·선택하며,
	3.5~3.9에서 frequency_days로 재산정한다.
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
  3.1-B. 기존 주문 수 기반 RFM 군집 수(K) 참고 비교

  [목표]
    3.1-A에서 만든 초기 RFM을 이용하여 RAW와 LOG_FM의
    군집 품질을 비교하고, 당시 검토한 K=4의 특성을 확인한다.

  [핵심 질문]
    로그변환을 적용한 초기 RFM이 원본 RFM보다 안정적이며,
    K=4가 참고 후보로 검토할 만한 군집 구조를 보이는가?

  [수행 범위]
    1. RAW RFM과 LOG_FM RFM을 비교한다.
    2. K=2~8의 군집 품질과 최소 군집 크기를 확인한다.
    3. 서로 다른 초기값에서 군집 결과가 유지되는지 확인한다.
    4. LOG_FM·K=4는 초기 참고 후보로만 표시한다.

  [이번 단계에서 하지 않는 작업]
    - frequency_days와 frequency_orders의 성능 비교
    - 공식 Frequency 정의 선택
    - 공식 RFMP 군집 수와 가중치 결정
    - 고객 RFMP 등급 산정

  [해석 유의사항]
    - 이 단계의 Frequency는 기존 주문 수 기준의 초기 값이다.
    - LOG_FM·K=4는 공식 결정이 아니라 초기 참고 후보이다.
    - 공식 Frequency는 3.2-A~3.4에서 비교·선택한다.
    - 공식 RFMP는 3.5~3.9에서 frequency_days를 사용하여
      지표별 군집 수와 가중치를 다시 계산한다.
    - CRM.W3_K_EVAL은 후속 공식 코드의 입력 테이블이 아니다.

  [입력 테이블]
    CRM.W3_MODEL_INPUT

  [주요 산출물]
    CRM.W3_K_EVAL : 초기 RFM의 K=2~8 참고 평가 결과
==========================================================*/


/*----------------------------------------------------------
  0. 기본 설정 및 CRM 라이브러리 연결
----------------------------------------------------------*/

options validvarname=any;

/* 프로젝트에서 사용하는 CRM 경로이다. */
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


/* 새 결과는 WORK에서 먼저 검증한 후 CRM에 저장한다. */
proc datasets library=work nolist nowarn;
    delete w3_k_eval_new;
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

endsubmit;
quit;


/*----------------------------------------------------------
  3. 임시 결과 검증 후 CRM 테이블 교체
----------------------------------------------------------*/

%global K_EVAL_ROWS K_EVAL_KEYS K_EVAL_MISSING;

proc sql noprint;

    select
        count(*),
        count(distinct catx("|", model_version, put(k, 8.))),
        sum(
            missing(model_version)
            or missing(k)
            or missing(inertia)
            or missing(silhouette)
            or missing(davies_bouldin)
            or missing(stability_ari)
            or missing(min_cluster_n)
        )
    into
        :K_EVAL_ROWS trimmed,
        :K_EVAL_KEYS trimmed,
        :K_EVAL_MISSING trimmed
    from work.w3_k_eval_new;

quit;


%macro validate_and_save;

    /* RAW와 LOG_FM 각각 K=2~8이므로 정상 행 수는 14개이다. */
    %if &K_EVAL_ROWS. ne 14 %then %do;
        %put ERROR: W3_K_EVAL 임시 결과의 행 수가 14개가 아닙니다.;
        %abort cancel;
    %end;

    %if &K_EVAL_KEYS. ne 14 %then %do;
        %put ERROR: model_version과 K 조합이 중복되었습니다.;
        %abort cancel;
    %end;

    %if &K_EVAL_MISSING. ne 0 %then %do;
        %put ERROR: 핵심 군집 평가 지표에 결측값이 있습니다.;
        %abort cancel;
    %end;

    data crm.w3_k_eval;
        set work.w3_k_eval_new;
    run;

    %put NOTE: CRM.W3_K_EVAL을 검증 후 저장했습니다.;

%mend;

%validate_and_save;


/*----------------------------------------------------------
  4. SAS 결과 확인
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


/* 초기 참고 후보 행을 별도로 확인한다. */
title "3.1-B 초기 참고 후보: LOG_FM, K=4";

proc print
    data=crm.w3_k_eval(
        where=(initial_reference_candidate=1)
    )
    noobs;
run;

title;


/*----------------------------------------------------------
  5. 최종 완료 메시지
----------------------------------------------------------*/

data _null_;
    put "NOTE: ================================================";
    put "NOTE: 3.1-B 초기 RFM K 참고 비교가 완료되었습니다.";
    put "NOTE: 생성 테이블: CRM.W3_K_EVAL";
    put "NOTE: LOG_FM·K=4는 초기 참고 후보이며 공식 선택이 아닙니다.";
    put "NOTE: 공식 RFMP 군집 수는 3.5~3.9 결과를 사용합니다.";
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


/*==========================================================
  WBS 3.4. Frequency 공식 후보 확정 및 산출물 정리

  [목표]
    1. WBS 3.2-A와 3.3-A의 비교 결과를 다시 검증합니다.
    2. B_DAYS를 Frequency 잠정 공식 후보로 기록합니다.
    3. 이후 3.5가 사용할 분석 원칙을 한 행의 정책 테이블로 남깁니다.
    4. WBS 3.1~3.3-A의 주요 산출물을 목록으로 관리합니다.
    5. WORK의 임시 테이블만 정리합니다.

  [수행 범위]
    - 기존 주문 수: frequency_orders
    - 잠정 공식 후보: frequency_days
    - A·B·C 비교 결과와 부트스트랩 신뢰구간 재확인
    - 신규 고객 성능과 확률 과소추정 문제는 REVIEW로 보존
    - CRM 영구 테이블은 임의로 삭제하지 않음

  [해석 유의사항]
    - B_DAYS 채택은 아직 최종 RFMP를 생성했다는 뜻이 아닙니다.
    - 3.2-A의 frequency_days는 시점별 이탈모형 피처입니다.
    - RFMP용 전체기간 frequency_days는 3.5에서 다시 계산합니다.
    - frequency_orders는 삭제하지 않고 주문 강도 참고변수로 보존합니다.
    - 신규 VALID 고객의 낮은 AUC 문제는 아직 해결되지 않았습니다.
    - 예측확률 과소추정 문제도 아직 해결되지 않았습니다.

  [입력 테이블]
    CRM.W3_MODEL_INPUT
    CRM.W3_FREQ_ABC_INPUT
    CRM.W3_FREQ_ABC_QA
    CRM.W3_FREQ_ABC_METRICS
    CRM.W3_FREQ_ABC_TOPK
    CRM.W3_FREQ_ABC_AUC_DIFF
    CRM.W3_FREQ_ABC_SCORED
    CRM.W3_FREQ_ABC_COEF
    CRM.W3_FREQ_ABC_DECISION

  [주요 산출물]
    CRM.W3_FREQUENCY_POLICY  : Frequency 후보와 적용 원칙
    CRM.W3_FREQUENCY_GATE_QA : 후보 확정 전 검증 결과
    CRM.W3_FINAL_QA          : 주요 산출물 존재 여부
    CRM.W3_CLEANUP_LOG       : WORK 임시 테이블 정리 기록
    CRM.W3_OUTPUT_CATALOG    : CRM의 W3_ 영구 테이블 목록

  [이번 수정]
    - '3 퍼센트포인트' 표기의 기호를 SAS가 매크로 호출로 오인한 경고를 제거합니다.
    - 해당 문자열만 작은따옴표로 감싸며 계산식과 판정 기준은 유지합니다.
==========================================================*/

options validvarname=any validmemname=extend;

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


/*==========================================================
  1. 이번 단계의 필수 입력 테이블 확인
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
    ds=crm.w3_model_input,
    previous_step=WBS 3.1-A
);

%require_table(
    ds=crm.w3_freq_abc_input,
    previous_step=WBS 3.2-A
);

%require_table(
    ds=crm.w3_freq_abc_qa,
    previous_step=WBS 3.2-A
);

%require_table(
    ds=crm.w3_freq_abc_metrics,
    previous_step=WBS 3.3-A
);

%require_table(
    ds=crm.w3_freq_abc_topk,
    previous_step=WBS 3.3-A
);

%require_table(
    ds=crm.w3_freq_abc_auc_diff,
    previous_step=WBS 3.3-A
);

%require_table(
    ds=crm.w3_freq_abc_scored,
    previous_step=WBS 3.3-A
);

%require_table(
    ds=crm.w3_freq_abc_coef,
    previous_step=WBS 3.3-A
);

%require_table(
    ds=crm.w3_freq_abc_decision,
    previous_step=WBS 3.3-A
);


/*==========================================================
  2. 이전 3.4 결과만 삭제

  3.1~3.3-A의 기존 분석 결과는 삭제하지 않습니다.
==========================================================*/

proc datasets library=crm nolist nowarn;
    delete
        w3_frequency_policy
        w3_frequency_gate_qa
        w3_final_qa
        w3_cleanup_log
        w3_output_catalog;
quit;


/*==========================================================
  3. 3.2-A Frequency 피처 품질 확인
==========================================================*/

proc sql noprint;

    /* 3.2-A QA에서 발견된 전체 문제 건수 */
    select
        sum(missing_frequency_orders)
        + sum(missing_frequency_days)
        + sum(invalid_days_over_orders)
        + sum(original_frequency_mismatch)
    into :freq_qa_issue_count trimmed
    from crm.w3_freq_abc_qa;

    /* 역할 안에서 동일 고객이 두 번 이상 나타나는지 확인 */
    create table work.w3_34_duplicate_customer as
    select
        split_role,
        customer_id,
        count(*) as duplicate_count
    from crm.w3_freq_abc_input
    group by
        split_role,
        customer_id
    having count(*) > 1;

    select count(*)
    into :freq_duplicate_count trimmed
    from work.w3_34_duplicate_customer;

quit;


/*==========================================================
  4. A·B·C 핵심 평가값을 매크로 변수로 저장
==========================================================*/

proc sql noprint;

    /* A안 VALID 결과 */
    select
        roc_auc,
        pr_auc,
        brier_score,
        log_loss,
        mean_probability,
        calibration_gap
    into
        :a_valid_auc trimmed,
        :a_valid_pr_auc trimmed,
        :a_valid_brier trimmed,
        :a_valid_logloss trimmed,
        :a_mean_probability trimmed,
        :a_calibration_gap trimmed
    from crm.w3_freq_abc_metrics
    where model_variant="A_ORDERS"
      and dataset_role="VALID";

    /* B안 VALID 결과 */
    select
        roc_auc,
        pr_auc,
        brier_score,
        log_loss,
        mean_probability,
        calibration_gap
    into
        :b_valid_auc trimmed,
        :b_valid_pr_auc trimmed,
        :b_valid_brier trimmed,
        :b_valid_logloss trimmed,
        :b_mean_probability trimmed,
        :b_calibration_gap trimmed
    from crm.w3_freq_abc_metrics
    where model_variant="B_DAYS"
      and dataset_role="VALID";

    /* C안 VALID 결과 */
    select
        roc_auc,
        pr_auc,
        brier_score,
        log_loss,
        mean_probability,
        calibration_gap
    into
        :c_valid_auc trimmed,
        :c_valid_pr_auc trimmed,
        :c_valid_brier trimmed,
        :c_valid_logloss trimmed,
        :c_mean_probability trimmed,
        :c_calibration_gap trimmed
    from crm.w3_freq_abc_metrics
    where model_variant="C_BOTH"
      and dataset_role="VALID";

    /* 신규 VALID 고객의 AUC */
    select roc_auc
    into :a_new_auc trimmed
    from crm.w3_freq_abc_metrics
    where model_variant="A_ORDERS"
      and dataset_role="VALID_NEW";

    select roc_auc
    into :b_new_auc trimmed
    from crm.w3_freq_abc_metrics
    where model_variant="B_DAYS"
      and dataset_role="VALID_NEW";

    select roc_auc
    into :c_new_auc trimmed
    from crm.w3_freq_abc_metrics
    where model_variant="C_BOTH"
      and dataset_role="VALID_NEW";

    /* B안과 A안의 AUC 차이 */
    select
        auc_difference,
        ci_low,
        ci_high
    into
        :ba_auc_diff trimmed,
        :ba_ci_low trimmed,
        :ba_ci_high trimmed
    from crm.w3_freq_abc_auc_diff
    where candidate_model="B_DAYS"
      and reference_model="A_ORDERS";

    /* C안과 A안의 AUC 차이 */
    select
        auc_difference,
        ci_low,
        ci_high
    into
        :ca_auc_diff trimmed,
        :ca_ci_low trimmed,
        :ca_ci_high trimmed
    from crm.w3_freq_abc_auc_diff
    where candidate_model="C_BOTH"
      and reference_model="A_ORDERS";

    /* C안과 B안의 AUC 차이 */
    select
        auc_difference,
        ci_low,
        ci_high
    into
        :cb_auc_diff trimmed,
        :cb_ci_low trimmed,
        :cb_ci_high trimmed
    from crm.w3_freq_abc_auc_diff
    where candidate_model="C_BOTH"
      and reference_model="B_DAYS";

    /* 기존 자동 권고 결과 */
    select
        strip(decision_code),
        strip(selected_model)
    into
        :abc_decision_code trimmed,
        :abc_selected_model trimmed
    from crm.w3_freq_abc_decision;

quit;


/*==========================================================
  5. B안 후보 확정 전 핵심 조건 확인

  조건
    1. Frequency QA 오류 0건
    2. 역할 내부 중복 고객 0건
    3. 자동 권고가 B_DAYS
    4. B안 VALID AUC가 A안보다 높음
    5. B-A AUC 차이 신뢰구간 하한이 0보다 큼
    6. B안 Brier Score가 A안보다 낮거나 같음
==========================================================*/

%macro validate_b_candidate;

    %if &freq_qa_issue_count. > 0 %then %do;
        %put ERROR: WBS 3.2-A Frequency QA에서 문제가 발견되었습니다.;
        %put ERROR: 문제 건수 = &freq_qa_issue_count.;
        %abort cancel;
    %end;

    %if &freq_duplicate_count. > 0 %then %do;
        %put ERROR: 역할 내부에 중복 고객ID가 있습니다.;
        %put ERROR: 중복 고객 건수 = &freq_duplicate_count.;
        %abort cancel;
    %end;

    %if %sysfunc(upcase(%superq(abc_selected_model)))
        ne B_DAYS %then %do;
        %put ERROR: WBS 3.3-A의 선택 결과가 B_DAYS가 아닙니다.;
        %put ERROR: 현재 선택 결과 = &abc_selected_model.;
        %abort cancel;
    %end;

    %if %sysevalf(&b_valid_auc. <= &a_valid_auc.) %then %do;
        %put ERROR: B_DAYS의 VALID AUC가 A_ORDERS보다 높지 않습니다.;
        %abort cancel;
    %end;

    %if %sysevalf(&ba_ci_low. <= 0) %then %do;
        %put ERROR: B-A AUC 차이의 신뢰구간 하한이 0보다 크지 않습니다.;
        %abort cancel;
    %end;

    %if %sysevalf(&b_valid_brier. > &a_valid_brier.) %then %do;
        %put ERROR: B_DAYS의 Brier Score가 A_ORDERS보다 높습니다.;
        %abort cancel;
    %end;

    %put NOTE: B_DAYS 잠정 공식 후보의 핵심 검증 조건을 통과했습니다.;

%mend;

%validate_b_candidate;


/*==========================================================
  6. Frequency 후보 확정 정책 테이블 생성

  이 테이블은 이후 코드에서 어떤 정의를 채택했는지 보여줍니다.
  실제 RFMP Frequency 값은 다음 3.5에서 전체기간 기준으로 계산합니다.
==========================================================*/

data crm.w3_frequency_policy;

    length
        decision_status               $40
        selected_option               $20
        official_frequency_variable   $32
        official_frequency_definition $150
        reference_frequency_variable  $32
        reference_frequency_usage     $150
        modeling_rule                 $200
        rfmp_rule                      $200
        unresolved_issue_1            $200
        unresolved_issue_2            $200
        decision_basis                $300;

    policy_id = 1;
    decision_date = today();
    format decision_date yymmdd10.;

    decision_status =
        "PROVISIONAL_OFFICIAL_CANDIDATE";

    selected_option =
        "B_DAYS";

    official_frequency_variable =
        "frequency_days";

    official_frequency_definition =
        "해당 기준일까지 구매가 발생한 서로 다른 날짜 수";

    reference_frequency_variable =
        "frequency_orders";

    reference_frequency_usage =
        "기존 값을 삭제하지 않고 주문 강도와 데이터 점검용으로 보존";

    modeling_rule =
        "이탈모형 공식 후보는 frequency_days 단독 사용. "
        || "frequency_orders 동시 투입은 현재 채택하지 않음";

    rfmp_rule =
        "3.5에서 RFMP 기준일까지의 frequency_days를 새로 계산. "
        || "3.2-A 스냅샷 값을 그대로 사용하지 않음";

    unresolved_issue_1 =
        "신규 VALID 고객 AUC가 약 0.55로 낮아 별도 신규고객 전략 필요";

    unresolved_issue_2 =
        "평균 예측확률이 실제 이탈률보다 낮아 확률 보정 문제 미해결";

    decision_basis =
        "B_DAYS가 A_ORDERS보다 VALID ROC-AUC, Brier Score, "
        || "Log Loss에서 개선. C_BOTH는 B_DAYS보다 추가 개선 없음";

    a_valid_auc = &a_valid_auc.;
    b_valid_auc = &b_valid_auc.;
    c_valid_auc = &c_valid_auc.;

    b_minus_a_auc = &ba_auc_diff.;
    b_minus_a_ci_low = &ba_ci_low.;
    b_minus_a_ci_high = &ba_ci_high.;

    a_valid_brier = &a_valid_brier.;
    b_valid_brier = &b_valid_brier.;

    a_valid_logloss = &a_valid_logloss.;
    b_valid_logloss = &b_valid_logloss.;

    b_new_valid_auc = &b_new_auc.;
    b_calibration_gap = &b_calibration_gap.;

    /* 아직 해결하지 못한 사항임을 표시합니다. */
    new_customer_issue_resolved = 0;
    calibration_issue_resolved = 0;
    team_review_required = 1;

    label
        decision_status =
            "Frequency 후보 상태"
        selected_option =
            "선택된 비교안"
        official_frequency_variable =
            "잠정 공식 Frequency 변수"
        reference_frequency_variable =
            "보존할 기존 변수"
        b_minus_a_auc =
            "B-A VALID AUC 차이"
        b_new_valid_auc =
            "B안 신규 VALID AUC"
        b_calibration_gap =
            "B안 평균확률 오차";

run;


/*==========================================================
  7. Frequency 후보 확정 QA 테이블 생성

  PASS   : 후보 확정 조건을 통과
  REVIEW : 후속 단계에서 계속 검토해야 하는 사항
==========================================================*/

data crm.w3_frequency_gate_qa;

    length
        check_item      $80
        actual_value    $100
        expected_value  $100
        status          $8
        interpretation  $220;

    /* 1. Frequency 피처 QA */
    check_order = 1;
    check_item =
        "3.2-A Frequency 품질 오류";
    actual_value =
        strip(put(&freq_qa_issue_count., best12.));
    expected_value =
        "0";

    if &freq_qa_issue_count. = 0
        then status = "PASS";
    else status = "FAIL";

    interpretation =
        "결측·역전·기존 Frequency 불일치가 없어야 함";
    output;

    /* 2. 역할 내부 고객 중복 */
    check_order = 2;
    check_item =
        "TRAIN·VALID 역할 내부 중복 고객";
    actual_value =
        strip(put(&freq_duplicate_count., best12.));
    expected_value =
        "0";

    if &freq_duplicate_count. = 0
        then status = "PASS";
    else status = "FAIL";

    interpretation =
        "각 역할에서 고객 한 명은 한 행만 가져야 함";
    output;

    /* 3. 자동 선택 결과 */
    check_order = 3;
    check_item =
        "3.3-A 잠정 선택 모형";
    actual_value =
        "&abc_selected_model.";
    expected_value =
        "B_DAYS";

    if upcase(strip("&abc_selected_model.")) = "B_DAYS"
        then status = "PASS";
    else status = "FAIL";

    interpretation =
        "사전 판정 규칙의 선택 결과와 팀의 잠정 결정이 일치해야 함";
    output;

    /* 4. B안 VALID AUC 개선 */
    check_order = 4;
    check_item =
        "B_DAYS와 A_ORDERS VALID AUC";
    actual_value = cats(
        "A=",
        put(&a_valid_auc., 8.5),
        ", B=",
        put(&b_valid_auc., 8.5)
    );
    expected_value =
        "B > A";

    if &b_valid_auc. > &a_valid_auc.
        then status = "PASS";
    else status = "FAIL";

    interpretation =
        "구매일 수가 주문 수보다 전체 VALID 순위 구분력이 높아야 함";
    output;

    /* 5. B-A AUC 차이 신뢰구간 */
    check_order = 5;
    check_item =
        "B-A AUC 차이 95% 신뢰구간";
    actual_value = cats(
        "[",
        put(&ba_ci_low., 8.5),
        ", ",
        put(&ba_ci_high., 8.5),
        "]"
    );
    expected_value =
        "신뢰구간 하한 > 0";

    if &ba_ci_low. > 0
        then status = "PASS";
    else status = "FAIL";

    interpretation =
        "VALID에서 관측된 개선이 단순 표본 변동일 가능성을 점검";
    output;

    /* 6. Brier Score */
    check_order = 6;
    check_item =
        "B_DAYS와 A_ORDERS Brier Score";
    actual_value = cats(
        "A=",
        put(&a_valid_brier., 8.5),
        ", B=",
        put(&b_valid_brier., 8.5)
    );
    expected_value =
        "B <= A";

    if &b_valid_brier. <= &a_valid_brier.
        then status = "PASS";
    else status = "FAIL";

    interpretation =
        "낮을수록 고객별 예측확률 오차가 작음";
    output;

    /* 7. C안 추가 효과 */
    check_order = 7;
    check_item =
        "C_BOTH의 B_DAYS 대비 추가 효과";
    actual_value = cats(
        "차이=",
        put(&cb_auc_diff., 8.5),
        ", CI=[",
        put(&cb_ci_low., 8.5),
        ", ",
        put(&cb_ci_high., 8.5),
        "]"
    );
    expected_value =
        "추가 개선이 확인되지 않음";

    if &cb_ci_low. <= 0
       and &cb_ci_high. >= 0
        then status = "PASS";
    else status = "REVIEW";

    interpretation =
        "C안의 추가 개선이 없으면 더 단순한 B안을 우선";
    output;

    /* 8. 신규 VALID 성능 */
    check_order = 8;
    check_item =
        "B_DAYS 신규 VALID ROC-AUC";
    actual_value =
        strip(put(&b_new_auc., 8.5));
    expected_value =
        "후속 단계에서 별도 검토";
    status =
        "REVIEW";
    interpretation =
        "신규 고객에서는 구분력이 낮아 기존 고객과 분리 운영 필요";
    output;

    /* 9. 평균확률 과소추정 */
    check_order = 9;
    check_item =
        "B_DAYS 평균 예측확률 오차";
    actual_value =
        strip(
            put(
                &b_calibration_gap.,
                percent9.2
            )
        );

    /*
      중요 수정:
      큰따옴표 안의 퍼센트포인트 기호를 SAS가 매크로 호출로 해석했습니다.
      작은따옴표를 사용하면 % 문자가 일반 문자로 처리됩니다.
    */
    expected_value =
        '절대값 3%p 이내 또는 후속 보정';

    if abs(&b_calibration_gap.) <= 0.03
        then status = "PASS";
    else status = "REVIEW";

    interpretation =
        "현재 B안은 순위 비교에 사용하고 절대확률 해석은 보류";
    output;

run;


/*==========================================================
  8. Frequency 정책과 QA 출력
==========================================================*/

title "WBS 3.4-1. Frequency 잠정 공식 후보 정책";

proc print data=crm.w3_frequency_policy noobs label;
    var
        decision_date
        decision_status
        selected_option
        official_frequency_variable
        official_frequency_definition
        reference_frequency_variable
        reference_frequency_usage
        modeling_rule
        rfmp_rule
        unresolved_issue_1
        unresolved_issue_2;
run;

title "WBS 3.4-2. Frequency 후보 확정 QA";

proc print data=crm.w3_frequency_gate_qa noobs label;
    var
        check_order
        check_item
        actual_value
        expected_value
        status
        interpretation;
run;

title;


/*==========================================================
  9. WBS 3.1~3.4 주요 산출물 목록 정의

  현재 단계에 꼭 필요한 비교 산출물과 기존 공식 산출물을 함께 확인합니다.
==========================================================*/

data work.w3_required_outputs;

    length
        wbs_step       $10
        table_name     $32
        table_purpose  $180;

    infile datalines
        dlm="|"
        dsd
        truncover;

    input
        wbs_step      :$10.
        table_name    :$32.
        table_purpose :$180.;

datalines;
3.1-A|W3_MODEL_INPUT|RFM 원본·로그·표준화 고객 데이터
3.1-A|W3_RFM_PROFILE|RFM 기술통계와 왜도
3.1-A|W3_SCALER_STATS|RFM 표준화 기준값
3.1-B|W3_K_EVAL|RFM K 후보별 군집 품질 비교
3.2|W3_CHURN_WINDOW_COMPARE|30·60·90·120일 이탈률 비교
3.2|W3_CHURN_SPLIT_V2|시간 순서대로 분리된 이탈예측 피처
3.2|W3_CHURN_FEATURE_PROFILE|이탈예측 피처별 기술통계
3.2|W3_CHURN_QA_SUMMARY|시간 분리 데이터 품질 요약
3.3|W3_CHURN_SCORED_V2|고객별 실제 이탈값과 예측확률
3.3|W3_CHURN_METRICS_V2|TRAIN·VALID·혼합 평가 결과
3.3|W3_CHURN_IMPORTANCE_V2|VALID 순열 중요도
3.3|W3_CHURN_CONFUSION_V2|VALID 혼동행렬
3.3|W3_CHURN_ROC_VALID|VALID ROC 곡선 좌표
3.3|W3_CHURN_MODEL_CONFIG|이탈예측 모델 설정 기록
3.2-A|W3_FREQ_ABC_INPUT|A·B·C Frequency 비교 입력 데이터
3.2-A|W3_FREQ_ABC_QA|A·B·C Frequency 비교 입력 QA
3.3-A|W3_FREQ_ABC_METRICS|A·B·C 모형 성능 비교
3.3-A|W3_FREQ_ABC_TOPK|A·B·C 상위 고객 적중 비교
3.3-A|W3_FREQ_ABC_AUC_DIFF|AUC 차이와 신뢰구간
3.3-A|W3_FREQ_ABC_SCORED|고객별 A·B·C 예측결과
3.3-A|W3_FREQ_ABC_COEF|A·B·C 모형 계수
3.3-A|W3_FREQ_ABC_DECISION|Frequency 후보 자동 권고
3.4|W3_FREQUENCY_POLICY|Frequency 잠정 공식 후보와 적용 원칙
3.4|W3_FREQUENCY_GATE_QA|Frequency 후보 확정 검증 결과
;
run;


/*==========================================================
  10. 주요 산출물 존재 여부와 크기 확인
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

        b.crdate
            as created_at
            format=datetime19.,

        b.modate
            as modified_at
            format=datetime19.

    from work.w3_required_outputs as a

    left join dictionary.tables as b
      on  b.libname = "CRM"
      and b.memtype = "DATA"
      and b.memname = upcase(a.table_name)

    order by
        a.wbs_step,
        a.table_name;

quit;

title "WBS 3.4-3. 주요 산출물 존재 여부";

proc print data=crm.w3_final_qa noobs label;
    var
        wbs_step
        table_name
        table_purpose
        exists_flag
        row_count
        column_count
        created_at
        modified_at;
run;

title;

/* 누락된 산출물 개수 */
proc sql noprint;

    select
        sum(exists_flag=0)
    into :missing_output_count trimmed
    from crm.w3_final_qa;

quit;

%put NOTE: 주요 산출물 중 누락된 테이블 수 = &missing_output_count.;


/*==========================================================
  11. WORK 임시 테이블 개수 확인 및 정리 기록
==========================================================*/

proc sql noprint;

    select count(*)
    into :work_w3_count trimmed
    from dictionary.tables
    where libname="WORK"
      and memtype="DATA"
      and upcase(memname) like "W3\_%" escape "\";

    select count(*)
    into :work_fabc_count trimmed
    from dictionary.tables
    where libname="WORK"
      and memtype="DATA"
      and upcase(memname) like "FABC\_%" escape "\";

quit;

data crm.w3_cleanup_log;

    length
        cleanup_scope  $30
        cleanup_action $180;

    cleanup_datetime = datetime();
    format cleanup_datetime datetime19.;

    cleanup_scope =
        "WORK.W3_";
    temporary_table_count =
        &work_w3_count.;
    cleanup_action =
        "WORK의 W3_ 임시 테이블 삭제. CRM 영구 테이블은 보존";
    output;

    cleanup_scope =
        "WORK.FABC_";
    temporary_table_count =
        &work_fabc_count.;
    cleanup_action =
        "WORK의 FABC_ 임시 테이블 삭제. CRM 영구 테이블은 보존";
    output;

run;


/*==========================================================
  12. CRM 라이브러리의 W3_ 영구 테이블 목록 저장
==========================================================*/

proc sql;

    create table crm.w3_output_catalog as
    select
        memname as table_name,
        nobs as row_count,
        nvar as column_count,

        crdate
            as created_at
            format=datetime19.,

        modate
            as modified_at
            format=datetime19.

    from dictionary.tables
    where libname="CRM"
      and memtype="DATA"
      and upcase(memname) like "W3\_%" escape "\"
    order by memname;

quit;

title "WBS 3.4-4. CRM W3_ 영구 산출물 목록";

proc print data=crm.w3_output_catalog noobs label;
run;

title;


/*==========================================================
  13. WORK 임시 테이블 삭제

  현재 SAS 세션의 임시 테이블만 삭제합니다.
  CRM의 영구 테이블에는 영향을 주지 않습니다.
==========================================================*/

proc datasets library=work nolist nowarn;
    delete
        w3_:
        fabc_:;
quit;

/* 삭제 결과 확인 */
proc sql;

    title "WBS 3.4-5. 정리 후 WORK 임시 테이블 확인";

    select
        count(*) as remaining_work_tables
    from dictionary.tables
    where libname="WORK"
      and memtype="DATA"
      and (
          upcase(memname) like "W3\_%" escape "\"
          or
          upcase(memname) like "FABC\_%" escape "\"
      );

quit;

title;


/*==========================================================
  14. 3.4 최종 메시지
==========================================================*/

data _null_;

    if &missing_output_count. = 0 then do;
        put "NOTE: WBS 3.1부터 3.4까지의 주요 산출물이 모두 존재합니다.";
        put "NOTE: B_DAYS가 Frequency 잠정 공식 후보로 기록되었습니다.";
        put "NOTE: 기존 frequency_orders는 삭제하지 않고 보존합니다.";
        put "NOTE: WBS 3.4의 WORK 임시 테이블 정리가 완료되었습니다.";
        put "NOTE: 다음 3.5에서 RFMP용 전체기간 frequency_days를 계산하십시오.";
    end;

    else do;
        put "WARNING: 일부 기존 산출물이 존재하지 않습니다.";
        put "WARNING: CRM.W3_FINAL_QA에서 EXISTS_FLAG=0인 행을 확인하십시오.";
        put "NOTE: Frequency 후보 정책과 비교 결과는 별도로 보존되었습니다.";
    end;

run;


/*==========================================================
  15. 3.4 결과 테이블 생성 여부 확인
==========================================================*/

%macro check_outputs;

    %local missing_output;
    %let missing_output=0;

    %if %sysfunc(exist(crm.w3_frequency_policy)) = 0
        %then %let missing_output=1;

    %if %sysfunc(exist(crm.w3_frequency_gate_qa)) = 0
        %then %let missing_output=1;

    %if %sysfunc(exist(crm.w3_final_qa)) = 0
        %then %let missing_output=1;

    %if %sysfunc(exist(crm.w3_cleanup_log)) = 0
        %then %let missing_output=1;

    %if %sysfunc(exist(crm.w3_output_catalog)) = 0
        %then %let missing_output=1;

    %if &missing_output. = 0 %then %do;
        %put NOTE: WBS 3.4 결과 테이블 다섯 개가 모두 생성되었습니다.;
    %end;

    %else %do;
        %put ERROR: WBS 3.4 결과 테이블 중 생성되지 않은 것이 있습니다.;
        %abort cancel;
    %end;

%mend;

%check_outputs;


/*==========================================================
  WBS 3.4 완료

  확정된 다음 작업 원칙
    1. Frequency 잠정 공식 후보는 frequency_days입니다.
    2. frequency_orders는 주문 강도 참고변수로 보존합니다.
    3. 3.5에서 전체 RFMP 분석기간 기준 frequency_days를 계산합니다.
    4. 기존 3.2-A 스냅샷 값을 RFMP에 그대로 사용하지 않습니다.
    5. 신규 고객과 확률 보정 문제는 별도 과제로 유지합니다.
==========================================================*/


/*====================================================================
  파일명: new_WBS_3_5_TO_3_9_PROC_PYTHON.sas

  WBS 3.5~3.9
  구매일 수 기준 RFM-P 재산출 및 최종 고객 분석 테이블 생성

  [목표]
    1. 전체 분석기간의 frequency_days를 새로 계산합니다.
    2. frequency_days를 RFMP의 공식 Frequency 후보로 사용합니다.
    3. 기존 frequency_orders는 비교·점검용으로 보존합니다.
    4. P도 주문 건수 기준과 구매일 기준으로 각각 계산합니다.
    5. 변경된 F와 P를 사용해 가중치와 RFMP 등급을 다시 계산합니다.
    6. 기존 RFMP 결과와 변경된 결과를 비교할 수 있게 보존합니다.
    7. 최종 고객 분석 테이블과 품질 점검표를 생성합니다.

  [수행 범위]
    3.5 전체기간 Frequency 및 제품가치 P 계산
    3.6 지표별 K-means 및 CV 기반 가중치 재계산
    3.7 RFMP 점수와 6개 고객등급 재산출
    3.8 등급별 프로파일과 대표 카테고리 산출
    3.9 고객 분석 테이블, 변경 비교표 및 QA 생성

  [해석 유의사항]
    - frequency_days는 구매가 발생한 서로 다른 날짜 수입니다.
    - frequency_orders는 기존 주문 건수이며 삭제하지 않습니다.
    - 3.2-A의 시점별 frequency_days를 그대로 사용하지 않습니다.
    - RFMP 분석기간 전체를 대상으로 frequency_days를 다시 계산합니다.
    - 구매일 기준 P는 분석 논리를 일관되게 만들기 위한 수정안입니다.
    - P 계산방법의 우월성이 별도로 입증된 것은 아니므로 주문 건수
      기준 P도 함께 보존합니다.
    - RFMP 등급은 고객가치의 상대적 구분이며 절대 가치 기준이 아닙니다.
    - 신규 고객의 낮은 AUC와 예측확률 과소추정 문제는 해결하지 않습니다.
    - 이 두 문제는 이후 이탈모형 검토 단계에서 계속 관리합니다.

  [입력 테이블]
    CRM.CLEAN_ONLINE
    CRM.W2_CUSTOMER_FEATURES
    CRM.W3_MODEL_INPUT
    CRM.W3_FREQUENCY_POLICY
    CRM.W3_FREQ_ABC_SCORED

  [주요 산출물]
    CRM.W3_FREQUENCY_FULL_PY
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
    CRM.W3_RFMP_METHOD_COMPARE_PY
    CRM.W3_RFMP_TIER_TRANSITION_PY
    CRM.W3_CUSTOMER_ANALYTIC_BASE_PY
    CRM.W3_RFMP_QA_SUMMARY_PY
    CRM.W3_RFMP_OUTPUT_CATALOG_PY

  [이번 수정]
    - 누락되었던 3.5~3.9 생성 본문 전체를 복원합니다.
    - 중첩된 공개 코드의 조건문을 매크로 내부로 옮깁니다.
    - HAS_OLD_RFMP를 산출물 검증 전에 반드시 정의합니다.
    - 산출물 생성 후 검증과 선택 출력도 매크로 내부에서 실행합니다.
====================================================================*/


/*====================================================================
  0. 기본 설정
====================================================================*/

options validvarname=any validmemname=extend;

/* 실제 CRM 라이브러리 경로 */
%let CRM_PATH=/home/student/crm_db;
libname crm "&CRM_PATH.";

/*
  P 계산방법

  DAYS   : 구매일 수 기준 P를 공식 P로 사용
  ORDERS : 주문 건수 기준 P를 공식 P로 사용

  현재 기본값은 DAYS입니다.
*/
%let P_METHOD=DAYS;


/*====================================================================
  1. CRM 라이브러리 연결 확인

  실행 중단이 필요한 조건문은 매크로 내부에서 실행합니다.
====================================================================*/

%macro check_crm_library;

    %if %sysfunc(libref(crm)) ne 0 %then %do;

        %put ERROR: CRM 라이브러리가 연결되지 않았습니다.;
        %put ERROR: 경로를 확인하십시오 - &CRM_PATH.;
        %abort cancel;

    %end;

    %else %do;

        %put NOTE: CRM 라이브러리가 연결되었습니다.;
        %put NOTE: CRM 경로 = &CRM_PATH.;

    %end;

%mend;

%check_crm_library;


/*====================================================================
  2. 필수 입력 테이블 확인
====================================================================*/

%macro require_table(ds=, previous_step=);

    %if %sysfunc(exist(&ds.)) = 0 %then %do;

        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %put ERROR: &previous_step. 단계를 먼저 확인하십시오.;
        %abort cancel;

    %end;

    %else %do;

        %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;

    %end;

%mend;


%require_table(
    ds=crm.clean_online,
    previous_step=Week 1 데이터 정제
);

%require_table(
    ds=crm.w2_customer_features,
    previous_step=Week 2 고객 특성 생성
);

%require_table(
    ds=crm.w3_model_input,
    previous_step=WBS 3.1 RFM 데이터 준비
);

%require_table(
    ds=crm.w3_frequency_policy,
    previous_step=WBS 3.4 Frequency 후보 확정
);

%require_table(
    ds=crm.w3_freq_abc_scored,
    previous_step=WBS 3.3 A·B·C 비교
);


/*====================================================================
  3. WBS 3.4 정책 확인

  선택된 방법이 B_DAYS이고 공식 변수가 frequency_days인지 확인합니다.
====================================================================*/

proc sql noprint;

    select
        strip(selected_option),
        strip(official_frequency_variable)
    into
        :SELECTED_OPTION trimmed,
        :OFFICIAL_FREQUENCY trimmed
    from crm.w3_frequency_policy
    where policy_id=1;

quit;


%put NOTE: 선택된 Frequency 방법 = &SELECTED_OPTION.;
%put NOTE: 공식 Frequency 변수 = &OFFICIAL_FREQUENCY.;


%macro validate_method_policy;

    %if %upcase(%superq(SELECTED_OPTION)) ne B_DAYS %then %do;

        %put ERROR: WBS 3.4에서 B_DAYS가 선택되지 않았습니다.;
        %put ERROR: 현재 선택값 = &SELECTED_OPTION.;
        %abort cancel;

    %end;

    %if %upcase(%superq(OFFICIAL_FREQUENCY)) ne FREQUENCY_DAYS %then %do;

        %put ERROR: 공식 Frequency 변수가 frequency_days가 아닙니다.;
        %put ERROR: 현재 변수 = &OFFICIAL_FREQUENCY.;
        %abort cancel;

    %end;

    %if %upcase(%superq(P_METHOD)) ne DAYS
        and %upcase(%superq(P_METHOD)) ne ORDERS %then %do;

        %put ERROR: P_METHOD는 DAYS 또는 ORDERS만 가능합니다.;
        %abort cancel;

    %end;

    %put NOTE: WBS 3.4 정책과 P_METHOD 설정을 확인했습니다.;

%mend;

%validate_method_policy;


/*====================================================================
  4. 기존 RFMP 결과 보존

  기존 주문 건수 기반 RFMP 결과가 있으면 최초 1회만 복사합니다.
  이미 백업이 있으면 덮어쓰지 않습니다.

  중첩 조건문은 공개 코드에서 실행하지 않고 매크로 안에서 실행합니다.
====================================================================*/

/* 테이블이 없거나 열 수 없으면 행 수를 0으로 반환합니다. */
%macro get_nobs(ds=, out=);

    %global &out.;
    %local dsid close_rc;
    %let &out.=0;

    %if %sysfunc(exist(&ds.)) %then %do;

        %let dsid=%sysfunc(open(&ds., i));

        %if &dsid. > 0 %then %do;

            %let &out.=%sysfunc(attrn(&dsid., nobs));
            %let close_rc=%sysfunc(close(&dsid.));

        %end;

    %end;

%mend;


%get_nobs(
    ds=crm.w3_customer_rfmp_py,
    out=CURRENT_RFMP_NOBS
);

%get_nobs(
    ds=crm.w3_customer_rfmp_orders_ref,
    out=OLD_RFMP_REF_NOBS
);

%get_nobs(
    ds=crm.w3_rfmp_weights_py,
    out=CURRENT_WEIGHT_NOBS
);

%get_nobs(
    ds=crm.w3_rfmp_weights_orders_ref,
    out=OLD_WEIGHT_REF_NOBS
);


%macro preserve_old_rfmp;

    /*
      백업이 없거나 0행이고 기존 RFMP 본문이 존재할 때 다시 만듭니다.
      이전 실패 실행에서 생긴 0행 백업도 여기서 복구됩니다.
    */
    %if &CURRENT_RFMP_NOBS. > 0
        and &OLD_RFMP_REF_NOBS. = 0 %then %do;

        data crm.w3_customer_rfmp_orders_ref;
            set crm.w3_customer_rfmp_py;
        run;

        %put NOTE: 기존 RFMP 고객 결과를 비교용으로 보존했습니다.;

    %end;

    %else %if &OLD_RFMP_REF_NOBS. > 0 %then %do;

        %put NOTE: 기존 RFMP 고객 비교자료가 이미 존재합니다.;

    %end;

    %else %do;

        %put NOTE: 비교할 기존 RFMP 고객 결과가 없습니다.;

    %end;


    %if &CURRENT_WEIGHT_NOBS. > 0
        and &OLD_WEIGHT_REF_NOBS. = 0 %then %do;

        data crm.w3_rfmp_weights_orders_ref;
            set crm.w3_rfmp_weights_py;
        run;

        %put NOTE: 기존 RFMP 가중치를 비교용으로 보존했습니다.;

    %end;

    %else %if &OLD_WEIGHT_REF_NOBS. > 0 %then %do;

        %put NOTE: 기존 RFMP 가중치 비교자료가 이미 존재합니다.;

    %end;

    %else %do;

        %put NOTE: 비교할 기존 RFMP 가중치가 없습니다.;

    %end;

%mend;

%preserve_old_rfmp;


/* 복사 후 행 수를 다시 확인합니다. */
%get_nobs(
    ds=crm.w3_customer_rfmp_orders_ref,
    out=OLD_RFMP_REF_NOBS
);

%get_nobs(
    ds=crm.w3_rfmp_weights_orders_ref,
    out=OLD_WEIGHT_REF_NOBS
);


/* 기존 RFMP 백업의 유효 여부를 Python과 검증 매크로에 전달합니다. */
%global HAS_OLD_RFMP;
%let HAS_OLD_RFMP=0;

%macro set_old_rfmp_flag;

    %if &OLD_RFMP_REF_NOBS. > 0 %then
        %let HAS_OLD_RFMP=1;

%mend;

%set_old_rfmp_flag;

%put NOTE: 기존 RFMP 비교자료 존재 여부 = &HAS_OLD_RFMP.;


/*====================================================================
  5. 이전 실행 결과 삭제

  비교용 ORDERS_REF 테이블은 삭제하지 않습니다.
====================================================================*/

proc datasets library=crm nolist nowarn;

    delete
        w3_frequency_full_py
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
        w3_rfmp_method_compare_py
        w3_rfmp_tier_transition_py
        w3_customer_analytic_base_py
        w3_rfmp_qa_summary_py
        w3_rfmp_output_catalog_py;

quit;


/*====================================================================
  6. WBS 3.5~3.9 PROC PYTHON 통합 실행
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

endsubmit;
quit;


/*====================================================================
  7. 필수 산출물 생성 여부 확인

  누락 개수 계산, 선택 산출물 확인, 실행 중단을 하나의 매크로 안에서
  처리하여 공개 코드의 매크로 조건문 제약을 피합니다.
====================================================================*/

%global OUTPUT_ERROR_COUNT;
%let OUTPUT_ERROR_COUNT=0;


%macro check_output(ds=);

    %if %sysfunc(exist(&ds.)) %then %do;

        %put NOTE: 생성 완료 - &ds.;

    %end;

    %else %do;

        %put ERROR: 생성 실패 - &ds.;

        %let OUTPUT_ERROR_COUNT=
            %eval(&OUTPUT_ERROR_COUNT. + 1);

    %end;

%mend;


%macro verify_all_outputs;

    %check_output(ds=crm.w3_frequency_full_py);
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
    %check_output(ds=crm.w3_rfmp_method_compare_py);
    %check_output(ds=crm.w3_customer_analytic_base_py);
    %check_output(ds=crm.w3_rfmp_qa_summary_py);
    %check_output(ds=crm.w3_rfmp_output_catalog_py);

    /* 기존 RFMP 백업이 있을 때만 등급 이동표를 확인합니다. */
    %if &HAS_OLD_RFMP. = 1 %then %do;

        %check_output(
            ds=crm.w3_rfmp_tier_transition_py
        );

    %end;

    %if &OUTPUT_ERROR_COUNT. > 0 %then %do;

        %put ERROR: 생성되지 않은 필수 산출물이 있습니다.;
        %put ERROR: 누락된 산출물 수 = &OUTPUT_ERROR_COUNT.;
        %abort cancel;

    %end;

    %else %do;

        %put NOTE: 모든 필수 산출물이 정상적으로 생성되었습니다.;

    %end;

%mend;

%verify_all_outputs;


/*====================================================================
  8. 주요 결과 출력
====================================================================*/

title "WBS 3.5 전체기간 Frequency 비교";

proc print
    data=crm.w3_frequency_full_py(obs=20)
    noobs
    label;

    var
        customer_id
        frequency_original
        frequency_orders
        frequency_days
        orders_per_purchase_day
        order_count_difference
        order_count_match;

    format
        orders_per_purchase_day 10.2
        order_count_difference 10.0;

run;


title "WBS 3.5 카테고리별 제품가치 비교";

proc print
    data=crm.w3_rfmp_category_value_py
    noobs
    label;

    var
        product_category
        category_order_count
        category_purchase_day_count
        category_avg_unit_price
        category_value_score_orders
        category_value_score_days
        category_value_score
        official_p_method;

    format
        category_avg_unit_price comma14.2;

run;


title "WBS 3.6 R/F/M/P 최종 가중치";

proc print
    data=crm.w3_rfmp_weights_py
    noobs
    label;

    var
        metric
        k
        weighted_cv
        raw_weight
        final_weight
        frequency_definition
        p_method;

    format
        weighted_cv 10.6
        raw_weight 10.6
        final_weight percent8.2;

run;


title "WBS 3.7 RFMP 등급별 고객 수";

proc freq
    data=crm.w3_customer_rfmp_py
    order=data;

    tables rfmp_tier / missing;

run;


title "WBS 3.8 RFMP 등급 프로파일";

proc print
    data=crm.w3_rfmp_tier_profile_py
    noobs
    label;

    var
        tier_code
        rfmp_tier
        customer_count
        customer_pct
        avg_recency
        avg_frequency_days
        avg_frequency_orders
        avg_orders_per_day
        avg_monetary
        avg_product_value_p
        avg_rfmp_score
        min_rfmp_score
        max_rfmp_score;

    format
        customer_pct 8.2
        avg_recency 10.2
        avg_frequency_days 10.2
        avg_frequency_orders 10.2
        avg_orders_per_day 10.2
        avg_monetary comma16.2
        avg_product_value_p comma16.2
        avg_rfmp_score 10.2
        min_rfmp_score 10.2
        max_rfmp_score 10.2;

run;


title "WBS 3.8 등급별 대표 카테고리 Top 5";

proc print
    data=crm.w3_rfmp_category_top5_py
    noobs
    label;

    var
        tier_code
        rfmp_tier
        category_rank
        product_category
        category_purchase_days
        category_orders
        category_customers
        category_sales
        lift
        ranking_basis;

    format
        category_sales comma16.2
        lift 8.3;

run;


title "WBS 3.9 기존 방식과 변경 방식 비교";

proc print
    data=crm.w3_rfmp_method_compare_py
    noobs
    label;

    format value 12.4;

run;


%macro print_tier_transition;

    %if &HAS_OLD_RFMP. = 1 %then %do;

        title "WBS 3.9 기존 등급과 변경 등급의 이동";

        proc freq
            data=crm.w3_rfmp_tier_transition_py;

            tables
                old_rfmp_tier * new_rfmp_tier
                / missing norow nocol;

        run;

    %end;

%mend;

%print_tier_transition;


title "WBS 3.9 자동 품질 점검";

proc print
    data=crm.w3_rfmp_qa_summary_py
    noobs
    label;

run;


title "WBS 3.9 생성 산출물 목록";

proc print
    data=crm.w3_rfmp_output_catalog_py
    noobs
    label;

run;


title "WBS 3.9 최종 고객 분석 테이블 구조";

proc contents
    data=crm.w3_customer_analytic_base_py
    varnum;

run;


title "WBS 3.9 최종 고객 분석 테이블 앞 10행";

proc print
    data=crm.w3_customer_analytic_base_py(obs=10)
    noobs;

run;


title;


/*====================================================================
  9. 실행 완료 메시지
====================================================================*/

%put NOTE: ==========================================================;
%put NOTE: WBS 3.5~3.9 전체 작업이 완료되었습니다.;
%put NOTE: 공식 Frequency = frequency_days;
%put NOTE: 공식 P 계산방법 = &P_METHOD.;
%put NOTE: 기존 frequency_orders와 주문 기준 P는 비교용으로 보존했습니다.;
%put NOTE: 신규 고객 AUC와 확률 보정 문제는 아직 해결되지 않았습니다.;
%put NOTE: ==========================================================;
