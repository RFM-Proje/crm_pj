/*==========================================================
  같은 날 여러 거래ID로 산 고객이 얼마나 되는지 확인

  구분
    n_lines  : 상품 행 수
    n_orders : 서로 다른 거래(order_key) 수    <- 지금 Frequency 로 쓰는 값
    n_days   : 서로 다른 구매일 수             <- 같은 날은 1회로 센 값

  n_orders 가 n_days 보다 많으면 같은 날 여러 거래가 있다는 뜻입니다.

  출력
    1) 고객별 n_lines / n_orders / n_days / 하루당 거래 수 분포
    2) 같은 날 여러 거래가 있는 고객 비율, (고객, 날짜) 중 여러 거래인 비율
    3) n_orders - n_days 가 큰 고객 상위 20명
    4) USER_1358 (재활성화 명단 1위였던 고객)의 구매 패턴
==========================================================*/

options validvarname=any;

%let CRM_PATH = /home/student/crm_db;
libname crm "&CRM_PATH.";


%macro require_table(ds=);

    %if %sysfunc(exist(&ds.)) = 0 %then %do;
        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %abort cancel;
    %end;

    %else %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;

%mend require_table;

%require_table(ds=crm.clean_online);
%require_table(ds=crm.w3_customer_rfmp_py);


/* 3.2 와 같은 유효 거래 조건 */
proc sql;

    create table work.valid_lines as

    select
        customer_id,
        order_key,
        transaction_date

    from crm.clean_online

    where flag_missing_core = 0
      and flag_return = 0
      and flag_zero_quantity = 0
      and flag_invalid_price = 0
      and flag_customer_unmatched = 0;


    create table work.cust_counts as

    select
        customer_id,
        count(*) as n_lines,
        count(distinct order_key) as n_orders,
        count(distinct transaction_date) as n_days,
        calculated n_orders / calculated n_days as orders_per_day format=8.2,
        calculated n_orders - calculated n_days as extra_orders

    from work.valid_lines

    group by customer_id;


    create table work.day_orders as

    select
        customer_id,
        transaction_date,
        count(distinct order_key) as orders_that_day

    from work.valid_lines

    group by customer_id, transaction_date;

quit;


title "1. 고객별 상품 행 / 거래 / 구매일 수 분포";

proc means data=work.cust_counts n mean median p90 p99 max maxdec=2;
    var n_lines n_orders n_days orders_per_day extra_orders;
run;


title "2-1. 같은 날 여러 거래가 있는 고객 비율";

proc sql;

    select
        count(*) as customers,
        sum(n_orders > n_days) as customers_with_multi_order_days,
        mean(n_orders > n_days) as share format=percent8.2,
        sum(n_orders) as total_orders,
        sum(n_days) as total_purchase_days,
        calculated total_orders / calculated total_purchase_days
            as orders_per_purchase_day format=8.2

    from work.cust_counts;

quit;


title "2-2. (고객, 날짜) 중 여러 거래가 있는 비율";

proc sql;

    select
        count(*) as customer_days,
        sum(orders_that_day > 1) as multi_order_days,
        mean(orders_that_day > 1) as share format=percent8.2,
        max(orders_that_day) as max_orders_in_one_day

    from work.day_orders;

quit;


title "3. n_orders - n_days 가 큰 고객 상위 20명 (rfmp 등급 포함)";

proc sql outobs=20;

    select
        a.customer_id,
        a.n_orders,
        a.n_days,
        a.extra_orders,
        a.orders_per_day,
        b.rfmp_tier,
        b.frequency as frequency_in_rfmp,
        b.recency

    from work.cust_counts as a

    inner join crm.w3_customer_rfmp_py as b
        on a.customer_id = b.customer_id

    order by a.extra_orders descending;

quit;


title "4-1. USER_1358 요약";

proc sql;

    select
        a.customer_id,
        a.n_lines,
        a.n_orders,
        a.n_days,
        b.rfmp_tier,
        b.frequency as frequency_in_rfmp,
        b.monetary,
        b.recency

    from work.cust_counts as a

    inner join crm.w3_customer_rfmp_py as b
        on a.customer_id = b.customer_id

    where a.customer_id = 'USER_1358';

quit;


title "4-2. USER_1358 날짜별 거래 수 (앞 30일)";

proc sql outobs=30;

    select
        transaction_date format=yymmdd10.,
        orders_that_day

    from work.day_orders

    where customer_id = 'USER_1358'

    order by transaction_date;

quit;

title;

/*====================================================================
  WBS 5f. Frequency / P 를 "구매일 수" 기준으로 다시 세면 무엇이 바뀌는가
  파일명: WBS_5f_Frequency_By_Days_Sensitivity.sas

  배경
    check_same_day_orders.sas 결과: 같은 날 여러 거래ID가 있는 고객이 90%,
    (고객, 날짜)의 80%가 여러 거래. 고객당 거래 수 중위 11, 구매일 수 중위 1.5.
    지금 Frequency 는 거래 수라서, 하루에 큰 장바구니로 산 고객의 F 가 크게 부풀 수 있음.

  이 코드가 하는 일
    1. 구매일 수(같은 날은 1회) 기준으로 Frequency 와 P 를 다시 계산
         P(구매일 기준) = 카테고리별 구매일 수 x 카테고리 점수 의 합
         (카테고리 점수는 기존 CRM.W3_RFMP_CATEGORY_VALUE_PY 를 그대로 사용)
    2. 기존과 같은 방법(백분위 점수, 같은 가중치, 6분위)으로 등급을 다시 산출
    3. 등급 이동, 구매일 수가 1일뿐인 고객 비율, 거래 수는 큰데 구매일 수는 작은 고객
    4. 상태(최근 구매 / 장기 미구매 / 신규·1일 구매), 충성 후보, 재활성화 P1 명단이
       기존 대비 얼마나 달라지는지

  재현 확인
    기존 저장값(Frequency, P, rfmp_score, rfmp_tier)을 이 코드의 방식으로 다시 만들어
    일치하는지 먼저 출력합니다. 일치하지 않으면 결과 해석 전에 원인을 확인하십시오.

  입력: CRM.CLEAN_ONLINE, CRM.W3_CUSTOMER_RFMP_PY, CRM.W3_RFMP_WEIGHTS_PY,
        CRM.W3_RFMP_CATEGORY_VALUE_PY
====================================================================*/

options validvarname=any;

%let CRM_PATH      = /home/student/crm_db;
libname crm "&CRM_PATH.";

%let DORMANT_DAYS  = 180;
%let NEW_CUTOFF    = 2019-10-02;


%macro require_table(ds=);

    %if %sysfunc(exist(&ds.)) = 0 %then %do;
        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %abort cancel;
    %end;

    %else %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;

%mend require_table;

%require_table(ds=crm.clean_online);
%require_table(ds=crm.w3_customer_rfmp_py);
%require_table(ds=crm.w3_rfmp_weights_py);
%require_table(ds=crm.w3_rfmp_category_value_py);


proc datasets library=crm nolist nowarn;
    delete
        w5f_summary
        w5f_tier_move
        w5f_customer_compare
        w5f_top_drops
        w5f_days_distribution;
quit;


proc python restart;
submit;

import os

os.environ["OMP_NUM_THREADS"] = "1"
os.environ["OPENBLAS_NUM_THREADS"] = "1"
os.environ["MKL_NUM_THREADS"] = "1"

import warnings

warnings.filterwarnings("ignore")

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt


# --------------------------------------------------------------------
# 0. 설정과 공통 함수
# --------------------------------------------------------------------

OUT_DIR = str(SAS.symget("CRM_PATH")).strip()
DORMANT_DAYS = int(float(str(SAS.symget("DORMANT_DAYS")).strip()))
NEW_CUTOFF = pd.Timestamp(str(SAS.symget("NEW_CUTOFF")).strip())

TIER_ORDER = ["Bronze", "Silver", "Gold", "Platinum", "Diamond", "VIP"]
TIER_RANK = {name: number + 1 for number, name in enumerate(TIER_ORDER)}


def lower_columns(frame):
    frame = frame.copy()
    frame.columns = [str(column).strip().lower() for column in frame.columns]
    return frame


def save_sas(frame, table_name):
    output = frame.reset_index(drop=True).copy()
    for column in output.columns:
        if output[column].dtype == object:
            output[column] = output[column].astype(str)
    SAS.df2sd(output, dataset=f"crm.{table_name}")


def sas_date_to_datetime(series):
    if pd.api.types.is_datetime64_any_dtype(series):
        return pd.to_datetime(series)
    numeric = pd.to_numeric(series, errors="coerce")
    if numeric.notna().mean() >= 0.90:
        return pd.to_datetime(numeric, unit="D", origin="1960-01-01", errors="coerce")
    return pd.to_datetime(series, errors="coerce")


def pct_rank(series):
    return series.rank(method="average", ascending=True, pct=True) * 100


def assign_tiers(frame, score_column):
    """3.7 과 같은 방법: 고객ID 순으로 정렬한 뒤 동점은 순서대로 풀어 6분위."""
    ordered = frame[["customer_id", score_column]].sort_values("customer_id").reset_index(drop=True)
    order = ordered[score_column].rank(method="first", ascending=True)
    ordered["tier"] = pd.qcut(order, q=6, labels=TIER_ORDER).astype(str)
    return frame[["customer_id"]].merge(ordered[["customer_id", "tier"]], on="customer_id", how="left")["tier"].to_numpy()


def draw_and_save(figure_name):
    path = os.path.join(OUT_DIR, figure_name)
    try:
        plt.savefig(path, dpi=150, bbox_inches="tight")
    except Exception as error:
        print(f"그림 파일 저장 실패({figure_name}): {error}")
    SAS.pyplot(plt)
    plt.close("all")


print("=" * 72)
print("WBS 5f. 구매일 수 기준 Frequency / P 민감도")
print("=" * 72)


# --------------------------------------------------------------------
# 1. 데이터 준비
# --------------------------------------------------------------------

base = lower_columns(SAS.sd2df("crm.w3_customer_rfmp_py"))

required_base = [
    "customer_id", "recency", "frequency", "monetary", "product_value_p",
    "r_score", "f_score", "m_score", "p_score", "rfmp_score", "rfmp_tier"
]

missing = [column for column in required_base if column not in base.columns]

if missing:
    raise ValueError("W3_CUSTOMER_RFMP_PY 에 필요한 변수가 없습니다: " + ", ".join(missing))

base = base[required_base].copy()
base["customer_id"] = base["customer_id"].astype(str).str.strip()
base["rfmp_tier"] = base["rfmp_tier"].astype(str).str.strip()

weights_table = lower_columns(SAS.sd2df("crm.w3_rfmp_weights_py"))
weights = {
    str(metric).strip().upper(): float(weight)
    for metric, weight in zip(weights_table["metric"], weights_table["final_weight"])
}

if set(weights) != {"R", "F", "M", "P"}:
    raise ValueError("가중치 표에 R/F/M/P 가 모두 있어야 합니다: " + str(weights))

category_score = lower_columns(SAS.sd2df("crm.w3_rfmp_category_value_py"))
category_score["product_category"] = category_score["product_category"].astype(str).str.strip()
category_score = category_score[["product_category", "category_value_score"]]

online = lower_columns(SAS.sd2df("crm.clean_online"))

flags = ["flag_missing_core", "flag_return", "flag_zero_quantity", "flag_invalid_price", "flag_customer_unmatched"]

for column in flags:
    online[column] = pd.to_numeric(online[column], errors="coerce")

valid = online[
    (online["flag_missing_core"] == 0) & (online["flag_return"] == 0)
    & (online["flag_zero_quantity"] == 0) & (online["flag_invalid_price"] == 0)
    & (online["flag_customer_unmatched"] == 0)
].copy()

valid["customer_id"] = valid["customer_id"].astype(str).str.strip()
valid["order_key"] = valid["order_key"].astype(str).str.strip()
valid["product_category"] = valid["product_category"].fillna("UNKNOWN").astype(str).str.strip()
valid["transaction_date"] = sas_date_to_datetime(valid["transaction_date"])

print(f"유효 거래 행 {len(valid):,}, 고객 {valid['customer_id'].nunique():,}")


# --------------------------------------------------------------------
# 2. 고객별 거래 수 / 구매일 수, 카테고리별 P
# --------------------------------------------------------------------

per_customer = valid.groupby("customer_id").agg(
    n_lines=("order_key", "size"),
    n_orders=("order_key", "nunique"),
    n_days=("transaction_date", "nunique"),
    first_purchase_date=("transaction_date", "min")
).reset_index()

per_cat = valid.groupby(["customer_id", "product_category"]).agg(
    orders=("order_key", "nunique"),
    days=("transaction_date", "nunique")
).reset_index().merge(category_score, on="product_category", how="left")

if per_cat["category_value_score"].isna().any():
    raise ValueError("카테고리 점수가 없는 카테고리가 있습니다. CRM.W3_RFMP_CATEGORY_VALUE_PY 를 확인하십시오.")

per_cat["p_orders"] = per_cat["orders"] * per_cat["category_value_score"]
per_cat["p_days"] = per_cat["days"] * per_cat["category_value_score"]

p_table = per_cat.groupby("customer_id").agg(
    p_orders=("p_orders", "sum"),
    p_days=("p_days", "sum")
).reset_index()

cust = (
    base
    .merge(per_customer, on="customer_id", how="left", validate="one_to_one")
    .merge(p_table, on="customer_id", how="left", validate="one_to_one")
)

if cust[["n_orders", "n_days", "p_days"]].isna().any().any():
    raise ValueError("일부 고객의 거래 정보를 찾지 못했습니다.")

cust["orders_per_day"] = cust["n_orders"] / cust["n_days"]
n_customers = len(cust)


# --------------------------------------------------------------------
# 3. 재현 확인: 기존 저장값을 같은 방법으로 다시 만들 수 있는가
# --------------------------------------------------------------------

freq_diff = int((cust["frequency"] != cust["n_orders"]).sum())
p_diff = float(np.max(np.abs(cust["product_value_p"] - cust["p_orders"])))

rebuilt_score = (
    weights["R"] * cust["r_score"] + weights["F"] * cust["f_score"]
    + weights["M"] * cust["m_score"] + weights["P"] * cust["p_score"]
)

score_diff = float(np.max(np.abs(rebuilt_score - cust["rfmp_score"])))

cust["tier_rebuilt"] = assign_tiers(cust, "rfmp_score")
tier_match = float((cust["tier_rebuilt"] == cust["rfmp_tier"]).mean())

f_score_check = float(np.max(np.abs(pct_rank(cust["frequency"]) - cust["f_score"])))
p_score_check = float(np.max(np.abs(pct_rank(cust["product_value_p"]) - cust["p_score"])))

print("\n[재현 확인]")
print(f"Frequency 가 거래 수와 다른 고객 수: {freq_diff}")
print(f"P 를 거래 수 기준으로 다시 만든 값과의 최대 차이: {p_diff:.6f}")
print(f"f_score 재계산 최대 차이: {f_score_check:.6f}, p_score 재계산 최대 차이: {p_score_check:.6f}")
print(f"가중치로 rfmp_score 를 다시 만든 최대 차이: {score_diff:.6f}")
print(f"저장된 등급과 다시 만든 등급의 일치율: {100 * tier_match:.2f} pct")

reproduced = (freq_diff == 0 and p_diff < 1e-6 and score_diff < 1e-6 and tier_match > 0.999)

if not reproduced:
    print("주의: 기존 값을 완전히 재현하지 못했습니다. 아래 비교는 재현 차이를 함께 포함합니다.")


# --------------------------------------------------------------------
# 4. 구매일 수 기준으로 F, P 를 다시 만들고 등급 재산출
# --------------------------------------------------------------------

cust["f_score_days"] = pct_rank(cust["n_days"])
cust["p_score_days"] = pct_rank(cust["p_days"])

cust["rfmp_score_days"] = (
    weights["R"] * cust["r_score"] + weights["F"] * cust["f_score_days"]
    + weights["M"] * cust["m_score"] + weights["P"] * cust["p_score_days"]
)

cust["tier_days"] = assign_tiers(cust, "rfmp_score_days")

cust["tier_old_rank"] = cust["rfmp_tier"].map(TIER_RANK).astype(int)
cust["tier_new_rank"] = cust["tier_days"].map(TIER_RANK).astype(int)
cust["tier_change"] = cust["tier_new_rank"] - cust["tier_old_rank"]


# --------------------------------------------------------------------
# 5. 상태, 충성 후보, 재활성화 P1 비교
# --------------------------------------------------------------------

cust["is_new"] = (cust["first_purchase_date"] > NEW_CUTOFF)

cust["state_old"] = np.where(
    cust["is_new"] | (cust["frequency"] == 1), "NEW_OR_ONE",
    np.where(cust["recency"] >= DORMANT_DAYS, "DORMANT", "ACTIVE")
)

cust["state_new"] = np.where(
    cust["is_new"] | (cust["n_days"] == 1), "NEW_OR_ONE",
    np.where(cust["recency"] >= DORMANT_DAYS, "DORMANT", "ACTIVE")
)

loyal_old = cust["rfmp_tier"].isin(["VIP", "Diamond"]) & (cust["state_old"] == "ACTIVE")
loyal_new = cust["tier_days"].isin(["VIP", "Diamond"]) & (cust["state_new"] == "ACTIVE")

p1_old = cust["rfmp_tier"].isin(["VIP", "Diamond", "Platinum"]) & (cust["state_old"] == "DORMANT")
p1_new = cust["tier_days"].isin(["VIP", "Diamond", "Platinum"]) & (cust["state_new"] == "DORMANT")

summary_rows = []


def add_summary(metric, old_value, new_value, overlap=np.nan, note=""):
    summary_rows.append({
        "metric": metric,
        "old_orders_based": float(old_value) if old_value is not None else np.nan,
        "new_days_based": float(new_value) if new_value is not None else np.nan,
        "overlap": float(overlap),
        "note": note
    })


add_summary("고객 수", n_customers, n_customers)
add_summary("구매일 수가 1일뿐인 고객", (cust["frequency"] == 1).sum(), (cust["n_days"] == 1).sum(), np.nan, "old 는 거래 수 1회, new 는 구매일 1일")
add_summary("등급 유지 고객", n_customers, (cust["tier_change"] == 0).sum(), np.nan, "new 는 등급이 그대로인 고객 수")
add_summary("등급이 오른 고객", 0, (cust["tier_change"] > 0).sum())
add_summary("등급이 내려간 고객", 0, (cust["tier_change"] < 0).sum())
add_summary("2단계 이상 이동한 고객", 0, (cust["tier_change"].abs() >= 2).sum())
add_summary("VIP", (cust["rfmp_tier"] == "VIP").sum(), (cust["tier_days"] == "VIP").sum(),
            ((cust["rfmp_tier"] == "VIP") & (cust["tier_days"] == "VIP")).sum(), "overlap = 두 방식 모두 VIP")
add_summary("VIP + Diamond", cust["rfmp_tier"].isin(["VIP", "Diamond"]).sum(), cust["tier_days"].isin(["VIP", "Diamond"]).sum(),
            (cust["rfmp_tier"].isin(["VIP", "Diamond"]) & cust["tier_days"].isin(["VIP", "Diamond"])).sum())
add_summary("상태 최근 구매", (cust["state_old"] == "ACTIVE").sum(), (cust["state_new"] == "ACTIVE").sum(),
            ((cust["state_old"] == "ACTIVE") & (cust["state_new"] == "ACTIVE")).sum())
add_summary("상태 장기 미구매", (cust["state_old"] == "DORMANT").sum(), (cust["state_new"] == "DORMANT").sum(),
            ((cust["state_old"] == "DORMANT") & (cust["state_new"] == "DORMANT")).sum())
add_summary("상태 신규·1회(일) 구매", (cust["state_old"] == "NEW_OR_ONE").sum(), (cust["state_new"] == "NEW_OR_ONE").sum(),
            ((cust["state_old"] == "NEW_OR_ONE") & (cust["state_new"] == "NEW_OR_ONE")).sum())
add_summary("충성 후보 (VIP/Diamond x 최근 구매)", loyal_old.sum(), loyal_new.sum(), (loyal_old & loyal_new).sum())
add_summary("재활성화 P1 (VIP/Diamond/Platinum x 장기 미구매)", p1_old.sum(), p1_new.sum(), (p1_old & p1_new).sum())

summary = pd.DataFrame(summary_rows)

save_sas(summary, "w5f_summary")


tier_move = (
    pd.crosstab(cust["rfmp_tier"], cust["tier_days"])
    .reindex(index=TIER_ORDER, columns=TIER_ORDER)
    .fillna(0).astype(int)
)

tier_move_long = tier_move.stack().reset_index()
tier_move_long.columns = ["old_tier", "new_tier", "customers"]

save_sas(tier_move_long, "w5f_tier_move")

compare_out = cust[[
    "customer_id", "n_lines", "n_orders", "n_days", "orders_per_day", "recency", "monetary",
    "rfmp_tier", "tier_days", "tier_change", "f_score", "f_score_days", "p_score", "p_score_days",
    "state_old", "state_new"
]].rename(columns={"rfmp_tier": "tier_old", "tier_days": "tier_new", "f_score": "f_score_old",
                   "p_score": "p_score_old"})

save_sas(compare_out, "w5f_customer_compare")

top_drops = compare_out.sort_values(["tier_change", "n_orders"], ascending=[True, False]).head(30)

save_sas(top_drops, "w5f_top_drops")

bins = [0, 1, 2, 3, 4, 5, 10, np.inf]
bin_names = ["1", "2", "3", "4", "5", "6-10", "11+"]

days_bin = pd.cut(cust["n_days"], bins=[0, 1, 2, 3, 4, 5, 10, np.inf], labels=bin_names)
days_dist = days_bin.value_counts().reindex(bin_names).fillna(0).astype(int).reset_index()
days_dist.columns = ["purchase_days", "customers"]
days_dist["pct"] = 100.0 * days_dist["customers"] / n_customers

save_sas(days_dist, "w5f_days_distribution")

print("\n[구매일 수 분포]")
print(days_dist.round(1).to_string(index=False))
print("\n[요약]")
print(summary.round(1).to_string(index=False))


# --------------------------------------------------------------------
# 6. 그림
# --------------------------------------------------------------------

fig, axes = plt.subplots(1, 2, figsize=(15, 5.6), gridspec_kw={"width_ratios": [1, 1.25]})

axes[0].bar(days_dist["purchase_days"], days_dist["customers"], color="tab:blue")

for index, row in days_dist.iterrows():
    axes[0].text(index, row["customers"] + 8, f"{int(row['customers'])}", ha="center")

axes[0].set_xlabel("Number of distinct purchase days in 2019")
axes[0].set_ylabel("Customers")
axes[0].set_title("Customers by number of purchase days")
axes[0].grid(axis="y", alpha=0.3)

grid = tier_move.reindex(index=TIER_ORDER[::-1]).to_numpy(dtype=float)
image = axes[1].imshow(grid, cmap="Blues", aspect="auto")

axes[1].set_xticks(range(6))
axes[1].set_xticklabels(TIER_ORDER, rotation=25, ha="right")
axes[1].set_yticks(range(6))
axes[1].set_yticklabels(TIER_ORDER[::-1])
axes[1].set_xlabel("New tier (days-based frequency and P)")
axes[1].set_ylabel("Current tier (orders-based)")

for row_number in range(6):
    for column_number in range(6):
        value = grid[row_number, column_number]
        axes[1].text(column_number, row_number, f"{int(value)}", ha="center", va="center",
                     color="white" if value > grid.max() * 0.6 else "black")

axes[1].set_title("Tier movement")
fig.colorbar(image, ax=axes[1])

plt.tight_layout()
draw_and_save("w5f_frequency_by_days.png")

print("\nWBS 5f 가 끝났습니다.")

endsubmit;
quit;


%macro check_outputs;

    %local missing_count;
    %let missing_count = 0;

    %if %sysfunc(exist(crm.w5f_summary))           = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5f_tier_move))         = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5f_customer_compare))  = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5f_top_drops))         = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5f_days_distribution)) = 0 %then %let missing_count = %eval(&missing_count. + 1);

    %if &missing_count. > 0 %then
        %put ERROR: WBS 5f 산출물 &missing_count.개가 생성되지 않았습니다. 위쪽 PROC PYTHON 로그를 확인하십시오.;
    %else
        %put NOTE: WBS 5f 산출물 5개를 확인했습니다.;

%mend check_outputs;

%check_outputs;


title "WBS 5f-1. 구매일 수 분포";

proc print data=crm.w5f_days_distribution noobs;
    format pct 8.1;
run;


title "WBS 5f-2. 기존(거래 수 기준) vs 새(구매일 수 기준) 요약";

proc print data=crm.w5f_summary noobs;
    format old_orders_based new_days_based overlap comma10.0;
run;


title "WBS 5f-3. 등급 이동 (행 = 기존, 열 = 새)";

proc freq data=crm.w5f_tier_move;
    tables old_tier * new_tier / norow nocol nopercent nocum;
    weight customers;
run;


title "WBS 5f-4. 등급이 가장 많이 내려간 고객 30명";

proc print data=crm.w5f_top_drops noobs;
    var customer_id n_orders n_days orders_per_day recency monetary tier_old tier_new tier_change state_old state_new;
    format monetary comma14.0 orders_per_day 8.1;
run;

title;


/*====================================================================
  WBS 5g. 거래 수 vs 구매일 수: 어느 쪽이 "다시 살 고객"을 더 잘 고르는가
  파일명: WBS_5g_Count_Metric_Comparison.sas

  질문
    Frequency 를 거래ID 수로 세는 것과 구매일 수로 세는 것 중
    어느 쪽이 다음 90일에 실제로 다시 산 고객을 더 잘 찾아내는가?

  판단 방식 (고객 수로 셈)
    1) 각 기준으로 고객을 정렬해 "상위 k명" 을 고릅니다 (k = 100, 200, 300 ...)
    2) 그 k명 중 다음 90일에 실제로 산 고객이 몇 명인지 셉니다
    3) 두 기준의 인원 차이와, 그 차이가 우연이 아닌지(95% 구간)를 함께 봅니다

    비교 기준
      거래 수            (지금 Frequency 방식)
      구매일 수          (같은 날은 1회)
      하루 평균 거래 수  (몰아서 산 정도)
      최근 구매순        (Recency 가 작은 순, 참고용)
      무작위             (아무렇게나 k명을 골랐을 때의 기대 인원)

    동점 처리: 구매일 수는 값이 같은 고객이 많으므로 동점은 무작위로 풀고
    여러 번 반복한 평균을 씁니다 (N_DRAWS).

  시점: CRM.W3_CHURN_SPLIT_V2 의 두 스냅샷 (TRAIN 6/30, VALID 10/02)
        각 시점 이전 거래만으로 계산하고, 그 뒤 90일 구매 여부를 결과로 사용

  해석 유의사항
    - 두 시점은 같은 고객이 많이 겹쳐 독립된 두 번의 검증은 아닙니다.
    - AUC(종합 점수)도 참고용 표(5g-5)로 함께 냄
    - 구간 판정은 차이의 95% 신뢰구간이 0 을 포함하는지로 함
      (고객을 다시 뽑는 부트스트랩, N_BOOT 회)

  입력: CRM.CLEAN_ONLINE, CRM.W3_CHURN_SPLIT_V2
====================================================================*/

options validvarname=any;

%let CRM_PATH  = /home/student/crm_db;
libname crm "&CRM_PATH.";

%let SEED      = 2026;
%let K_LIST    = 100 200 300 400 500;
%let N_DRAWS   = 200;
%let N_BOOT    = 300;


%macro require_table(ds=);

    %if %sysfunc(exist(&ds.)) = 0 %then %do;
        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %abort cancel;
    %end;

    %else %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;

%mend require_table;

%require_table(ds=crm.clean_online);
%require_table(ds=crm.w3_churn_split_v2);


proc datasets library=crm nolist nowarn;
    delete
        w5g_check
        w5g_topk_hits
        w5g_topk_diff
        w5g_group_counts
        w5g_auc;
quit;


proc python restart;
submit;

import os

os.environ["OMP_NUM_THREADS"] = "1"
os.environ["OPENBLAS_NUM_THREADS"] = "1"
os.environ["MKL_NUM_THREADS"] = "1"

import warnings

warnings.filterwarnings("ignore")

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

from sklearn.metrics import roc_auc_score


# --------------------------------------------------------------------
# 0. 설정과 공통 함수
# --------------------------------------------------------------------

OUT_DIR = str(SAS.symget("CRM_PATH")).strip()
SEED = int(float(str(SAS.symget("SEED")).strip()))
K_LIST = [int(v) for v in str(SAS.symget("K_LIST")).split()]
N_DRAWS = int(float(str(SAS.symget("N_DRAWS")).strip()))
N_BOOT = int(float(str(SAS.symget("N_BOOT")).strip()))

METRICS = {
    "orders": "거래 수",
    "days": "구매일 수",
    "orders_per_day": "하루 평균 거래 수",
    "recency": "최근 구매순"
}


def lower_columns(frame):
    frame = frame.copy()
    frame.columns = [str(column).strip().lower() for column in frame.columns]
    return frame


def save_sas(frame, table_name):
    output = frame.reset_index(drop=True).copy()
    for column in output.columns:
        if output[column].dtype == object:
            output[column] = output[column].astype(str)
    SAS.df2sd(output, dataset=f"crm.{table_name}")


def sas_date_to_datetime(series):
    if pd.api.types.is_datetime64_any_dtype(series):
        return pd.to_datetime(series)
    numeric = pd.to_numeric(series, errors="coerce")
    if numeric.notna().mean() >= 0.90:
        return pd.to_datetime(numeric, unit="D", origin="1960-01-01", errors="coerce")
    return pd.to_datetime(series, errors="coerce")


def cumulative_hits(score, outcome, rng):
    """score 가 큰 고객부터 세었을 때 앞에서 k명 중 실제로 산 고객 수(누적). 동점은 무작위."""
    tie_break = rng.random_sample(len(score))
    order = np.lexsort((tie_break, -score))
    return np.cumsum(outcome[order])


def average_cumulative(score, outcome, rng, draws):
    total = np.zeros(len(score))
    for _ in range(draws):
        total += cumulative_hits(score, outcome, rng)
    return total / draws


print("=" * 72)
print("WBS 5g. 거래 수 vs 구매일 수 (고객 수 기준 비교)")
print("=" * 72)


# --------------------------------------------------------------------
# 1. 데이터 준비: 각 스냅샷 이전 거래만으로 고객별 거래 수 / 구매일 수
# --------------------------------------------------------------------

online = lower_columns(SAS.sd2df("crm.clean_online"))
split = lower_columns(SAS.sd2df("crm.w3_churn_split_v2"))

flags = ["flag_missing_core", "flag_return", "flag_zero_quantity", "flag_invalid_price", "flag_customer_unmatched"]

for column in flags:
    online[column] = pd.to_numeric(online[column], errors="coerce")

valid = online[
    (online["flag_missing_core"] == 0) & (online["flag_return"] == 0)
    & (online["flag_zero_quantity"] == 0) & (online["flag_invalid_price"] == 0)
    & (online["flag_customer_unmatched"] == 0)
][["customer_id", "order_key", "transaction_date"]].copy()

valid["customer_id"] = valid["customer_id"].astype(str).str.strip()
valid["order_key"] = valid["order_key"].astype(str).str.strip()
valid["transaction_date"] = sas_date_to_datetime(valid["transaction_date"])

split["split_role"] = split["split_role"].astype(str).str.strip().str.upper()
split["customer_id"] = split["customer_id"].astype(str).str.strip()
split["snapshot_cutoff"] = sas_date_to_datetime(split["snapshot_cutoff"])

for column in ["recency", "frequency", "churn_flag"]:
    split[column] = pd.to_numeric(split[column], errors="coerce")

snapshots = {}
check_rows = []

for role in ["TRAIN", "VALID"]:

    part = split[split["split_role"] == role].copy()
    cutoff = part["snapshot_cutoff"].iloc[0]

    before = valid[valid["transaction_date"] <= cutoff]

    counts = before.groupby("customer_id").agg(
        n_orders=("order_key", "nunique"),
        n_days=("transaction_date", "nunique")
    ).reset_index()

    merged = part.merge(counts, on="customer_id", how="left", validate="one_to_one")

    if merged[["n_orders", "n_days"]].isna().any().any():
        raise ValueError(f"{role}: 스냅샷 이전 거래를 찾지 못한 고객이 있습니다.")

    merged["purchased_next90"] = (1 - merged["churn_flag"]).astype(int)
    merged["orders_per_day"] = merged["n_orders"] / merged["n_days"]

    mismatch = int((merged["n_orders"] != merged["frequency"]).sum())

    check_rows.append({
        "snapshot": role,
        "customers": int(len(merged)),
        "purchased_next90": int(merged["purchased_next90"].sum()),
        "purchase_rate": float(merged["purchased_next90"].mean()),
        "orders_mismatch_vs_split": mismatch,
        "days_median": float(merged["n_days"].median()),
        "orders_median": float(merged["n_orders"].median()),
        "one_day_customers": int((merged["n_days"] == 1).sum())
    })

    snapshots[role] = merged

check = pd.DataFrame(check_rows)

save_sas(check, "w5g_check")

print("\n[데이터 확인]")
print(check.round(3).to_string(index=False))

if int(check["orders_mismatch_vs_split"].sum()) > 0:
    print("주의: 거래 수가 W3_CHURN_SPLIT_V2 의 frequency 와 다른 고객이 있습니다. 필터 조건을 확인하십시오.")


# --------------------------------------------------------------------
# 2. 상위 k명 중 실제 재구매 고객 수
# --------------------------------------------------------------------

rng = np.random.RandomState(SEED)

hits_rows = []
diff_rows = []
curves = {}

for role, data in snapshots.items():

    n = len(data)
    outcome = data["purchased_next90"].to_numpy(dtype=float)
    base_rate = float(outcome.mean())

    scores = {
        "orders": data["n_orders"].to_numpy(dtype=float),
        "days": data["n_days"].to_numpy(dtype=float),
        "orders_per_day": data["orders_per_day"].to_numpy(dtype=float),
        "recency": -data["recency"].to_numpy(dtype=float)
    }

    cum = {name: average_cumulative(score, outcome, rng, N_DRAWS) for name, score in scores.items()}
    curves[role] = cum

    valid_ks = [k for k in K_LIST if k <= n]

    for k in valid_ks:
        row = {"snapshot": role, "k": k, "random_hits": float(k * base_rate)}
        for name in scores:
            row[f"{name}_hits"] = float(cum[name][k - 1])
            row[f"{name}_rate"] = float(cum[name][k - 1] / k)
        hits_rows.append(row)

    # 부트스트랩: 고객을 다시 뽑았을 때 (구매일 수 - 거래 수) 의 인원 차이 분포
    boot = {k: [] for k in valid_ks}

    for _ in range(N_BOOT):
        idx = rng.randint(0, n, size=n)
        sample_outcome = outcome[idx]
        cum_orders = cumulative_hits(scores["orders"][idx], sample_outcome, rng)
        cum_days = cumulative_hits(scores["days"][idx], sample_outcome, rng)
        for k in valid_ks:
            boot[k].append(cum_days[k - 1] - cum_orders[k - 1])

    for k in valid_ks:
        diff = float(cum["days"][k - 1] - cum["orders"][k - 1])
        low, high = np.percentile(boot[k], [2.5, 97.5])

        if low > 0:
            reading = "구매일 수가 더 많이 맞힘"
        elif high < 0:
            reading = "거래 수가 더 많이 맞힘"
        else:
            reading = "차이를 확정할 수 없음 (비슷함)"

        diff_rows.append({
            "snapshot": role,
            "k": k,
            "hits_orders": float(cum["orders"][k - 1]),
            "hits_days": float(cum["days"][k - 1]),
            "diff_customers_days_minus_orders": diff,
            "diff_ci_low": float(low),
            "diff_ci_high": float(high),
            "diff_pct_of_k": float(100.0 * diff / k),
            "reading": reading
        })

topk_hits = pd.DataFrame(hits_rows)
topk_diff = pd.DataFrame(diff_rows)

save_sas(topk_hits, "w5g_topk_hits")
save_sas(topk_diff, "w5g_topk_diff")

print("\n[상위 k명 중 실제로 다시 산 고객 수]")
print(topk_hits[["snapshot", "k", "random_hits", "orders_hits", "days_hits", "orders_per_day_hits", "recency_hits"]].round(1).to_string(index=False))
print("\n[구매일 수 - 거래 수 (고객 수 차이)]")
print(topk_diff.round(1).to_string(index=False))


# --------------------------------------------------------------------
# 3. 구간별 고객 수 표
# --------------------------------------------------------------------

group_rows = []

for role, data in snapshots.items():

    days_group = pd.cut(data["n_days"], bins=[0, 1, 2, 3, np.inf], labels=["1일", "2일", "3일", "4일 이상"])
    orders_group = pd.qcut(data["n_orders"].rank(method="first"), 3, labels=["거래 수 하위 1/3", "거래 수 중간 1/3", "거래 수 상위 1/3"])
    opd_group = pd.qcut(data["orders_per_day"].rank(method="first"), 3, labels=["하루 거래 수 하위 1/3", "하루 거래 수 중간 1/3", "하루 거래 수 상위 1/3"])

    for basis, grouping in [("구매일 수", days_group), ("거래 수", orders_group), ("하루 평균 거래 수", opd_group)]:
        for label in grouping.cat.categories:
            mask = (grouping == label).to_numpy()
            n_group = int(mask.sum())
            hit = int(data.loc[mask, "purchased_next90"].sum())
            group_rows.append({
                "snapshot": role,
                "basis": basis,
                "group": str(label),
                "customers": n_group,
                "purchased_next90": hit,
                "purchase_rate": float(hit / n_group) if n_group else np.nan
            })

group_counts = pd.DataFrame(group_rows)

save_sas(group_counts, "w5g_group_counts")


# --------------------------------------------------------------------
# 3-2. 참고: AUC (전체 고객을 줄 세웠을 때의 종합 점수)
#   0.5 = 무작위, 1.0 = 완벽. 값이 클수록 다시 살 고객을 앞에 세움.
#   위 그림의 곡선이 전체적으로 높을수록 AUC 도 큼.
# --------------------------------------------------------------------

auc_rows = []

for role, data in snapshots.items():

    y = data["purchased_next90"].to_numpy()
    n = len(data)

    values = {
        "orders": data["n_orders"].to_numpy(dtype=float),
        "days": data["n_days"].to_numpy(dtype=float),
        "orders_per_day": data["orders_per_day"].to_numpy(dtype=float),
        "recency": -data["recency"].to_numpy(dtype=float)
    }

    aucs = {name: float(roc_auc_score(y, score)) for name, score in values.items()}

    boot_diff = []

    for _ in range(N_BOOT):
        idx = rng.randint(0, n, size=n)
        y_boot = y[idx]

        if y_boot.min() == y_boot.max():
            continue

        boot_diff.append(
            roc_auc_score(y_boot, values["days"][idx]) - roc_auc_score(y_boot, values["orders"][idx])
        )

    low, high = np.percentile(boot_diff, [2.5, 97.5])
    diff = aucs["days"] - aucs["orders"]

    if low > 0:
        reading = "구매일 수가 더 좋음"
    elif high < 0:
        reading = "거래 수가 더 좋음"
    else:
        reading = "차이를 확정할 수 없음 (비슷함)"

    auc_rows.append({
        "snapshot": role,
        "customers": int(n),
        "auc_orders": aucs["orders"],
        "auc_days": aucs["days"],
        "auc_orders_per_day": aucs["orders_per_day"],
        "auc_recency": aucs["recency"],
        "auc_diff_days_minus_orders": float(diff),
        "diff_ci_low": float(low),
        "diff_ci_high": float(high),
        "reading": reading
    })

auc_table = pd.DataFrame(auc_rows)

save_sas(auc_table, "w5g_auc")

print("\n[AUC]")
print(auc_table.round(4).to_string(index=False))


# --------------------------------------------------------------------
# 4. 그림: k 에 따른 실제 재구매 고객 수
# --------------------------------------------------------------------

fig, axes = plt.subplots(1, 2, figsize=(15, 5.4))

styles = {
    "orders": ("Orders count", "tab:blue", "-"),
    "days": ("Purchase days", "tab:orange", "-"),
    "orders_per_day": ("Orders per purchase day", "tab:green", "--"),
    "recency": ("Most recent first (reference)", "tab:red", ":")
}

for axis, role in zip(axes, ["TRAIN", "VALID"]):
    n = len(snapshots[role])
    base_rate = snapshots[role]["purchased_next90"].mean()
    ks = np.arange(25, min(n, 700) + 1, 25)

    for name, (label, color, line) in styles.items():
        axis.plot(ks, curves[role][name][ks - 1], label=label, color=color, linestyle=line)

    axis.plot(ks, ks * base_rate, label="Random pick", color="gray", linestyle="-.")
    axis.set_xlabel("Top k customers picked")
    axis.set_ylabel("Customers who actually bought in next 90 days")
    axis.set_title(f"{role}: hits among top k")
    axis.grid(alpha=0.3)
    axis.legend(fontsize=8)

plt.tight_layout()

path = os.path.join(OUT_DIR, "w5g_count_metric_comparison.png")

try:
    plt.savefig(path, dpi=150, bbox_inches="tight")
except Exception as error:
    print(f"그림 파일 저장 실패: {error}")

SAS.pyplot(plt)
plt.close("all")

print("\nWBS 5g 가 끝났습니다.")

endsubmit;
quit;


%macro check_outputs;

    %local missing_count;
    %let missing_count = 0;

    %if %sysfunc(exist(crm.w5g_check))        = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5g_topk_hits))    = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5g_topk_diff))    = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5g_group_counts)) = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5g_auc))          = 0 %then %let missing_count = %eval(&missing_count. + 1);

    %if &missing_count. > 0 %then
        %put ERROR: WBS 5g 산출물 &missing_count.개가 생성되지 않았습니다. 위쪽 PROC PYTHON 로그를 확인하십시오.;
    %else
        %put NOTE: WBS 5g 산출물 5개를 확인했습니다.;

%mend check_outputs;

%check_outputs;


title "WBS 5g-1. 데이터 확인 (거래 수가 기존 frequency 와 같은지 포함)";

proc print data=crm.w5g_check noobs;
    format purchase_rate 8.3 days_median orders_median 8.1;
run;


title "WBS 5g-2. 상위 k명 중 실제로 다음 90일에 산 고객 수";

proc print data=crm.w5g_topk_hits noobs;
    var snapshot k random_hits orders_hits days_hits orders_per_day_hits recency_hits;
    format random_hits orders_hits days_hits orders_per_day_hits recency_hits 8.1;
run;


title "WBS 5g-3. 구매일 수 - 거래 수 (고객 수 차이와 95% 구간)";

proc print data=crm.w5g_topk_diff noobs;
    format hits_orders hits_days diff_customers_days_minus_orders diff_ci_low diff_ci_high diff_pct_of_k 8.1;
run;


title "WBS 5g-4. 구간별 고객 수와 재구매 고객 수";

proc print data=crm.w5g_group_counts noobs;
    format purchase_rate 8.3;
run;


title "WBS 5g-5. 참고: AUC (거래 수 vs 구매일 수)";

proc print data=crm.w5g_auc noobs;
    format auc_orders auc_days auc_orders_per_day auc_recency auc_diff_days_minus_orders diff_ci_low diff_ci_high 8.4;
run;

title;
