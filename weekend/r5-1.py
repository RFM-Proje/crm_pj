"""r5-1. 이커머스 핵심 지표 산출 (ARPU · LTV · CAC 외) + 1~4주차 결과 통합 조인

입력 (crm_db)
  clean_online, clean_marketing, clean_customer        (r1-1)
  w2_order_base, w2_customer_features                   (r2-2)
  w3_customer_rfmp_py                                   (r3-1: RFMP 6등급)
  w4_41_current_scored, w4_42_customer_action          (r4-1: 상대위험·실행규칙)

산출 (crm_db, SAS 결과창 스타일 표는 rplots/sas/r51_*.png)
  w5_line_net        : 상품 행별 할인 전 금액, 추정 쿠폰할인액, 순매출
  w5_monthly_kpi     : 월별 GMV·순매출·주문·활성/신규/재방문 고객·ARPU·AOV·CAC·ROAS
  w5_cohort_retention: 첫 구매월 코호트 x 경과월 재구매 고객 비율
  w5_cohort_ltv      : 코호트 x 경과월 누적 순매출/획득고객 (관측 불가 구간은 결측)
  w5_cohort_unit_econ: 코호트별 CAC, M0/M2/M5/관측말 LTV, LTV/CAC, 손익분기 마진율
  w5_customer_360    : 고객 1명 = 1행 통합 테이블 (RFM·쿠폰·RFMP 등급·상대위험·실행규칙·
                       대표/첫구매 카테고리·인구통계)
  w5_entry_category  : 첫 구매 카테고리별 재구매율·고객가치
  w5_category_affinity: 카테고리 교차구매 lift (고객 단위, 상위 10개 카테고리)

지표 정의
  GMV(할인 전 매출) = Σ 수량 × 평균금액
  추정 쿠폰할인액   = 쿠폰 Used 이고 할인정보가 연결된 행의 GMV × 할인율 (2-3주차와 같은 규칙)
  순매출            = GMV − 추정 쿠폰할인액  (배송료·세금 제외, 원가 정보가 없어 이익이 아닌 매출 기준)
  ARPU(월)          = 월 순매출 / 월 활성(구매) 고객 수
  AOV               = 월 순매출 / 월 주문 수
  CAC(월)           = 월 마케팅비(온라인+오프라인) / 그 달 첫 구매 고객 수
  코호트 LTV(m)     = 코호트가 첫 구매 후 m개월까지 만든 누적 순매출 / 코호트 고객 수
  LTV/CAC           = 코호트 LTV / 그 코호트 달의 CAC  (업계 관행 기준선 3.0, 단 이익 기준)
  손익분기 마진율   = CAC / LTV  (원가가 없어 이익 LTV 를 못 구하므로, 매출의 몇 %가 이익으로
                      남아야 마케팅비를 회수하는지로 표현. 낮을수록 건강)
  ROAS              = 월 순매출 / 월 마케팅비

실행: python crm_pj/weekend/r5-1.py   (선행: r1-1 ~ r4-1)
"""

import numpy as np
import pandas as pd

from rcommon import load, proc_print, save, title

co = load("clean_online")
mk = load("clean_marketing")
cust = load("clean_customer")
cf = load("w2_customer_features")
rfmp = load("w3_customer_rfmp_py")
scored = load("w4_41_current_scored")
action = load("w4_42_customer_action")

# ----------------------------------------------------------------------
# 1. 상품 행 순매출 (RFM 제외 대상 행은 2주차와 같이 제외)
# ----------------------------------------------------------------------
excluded = co[["flag_missing_core", "flag_return", "flag_zero_quantity", "flag_invalid_price"]].max(axis=1)
ln = co[excluded == 0].copy()
ln["gross_amount"] = ln["quantity"] * ln["avg_price"]
_used = (ln["coupon_status"] == "Used") & (ln["flag_discount_unmatched"] == 0) & \
        ln["offered_discount_pct"].between(0, 100)
ln["discount_amount"] = np.where(_used, ln["gross_amount"] * ln["offered_discount_pct"] / 100, 0.0)
ln["net_amount"] = ln["gross_amount"] - ln["discount_amount"]
ln["month"] = ln["transaction_date"].dt.to_period("M").dt.to_timestamp()
w5_line_net = ln[["order_key", "customer_id", "transaction_date", "month", "product_category",
                  "coupon_status", "gross_amount", "discount_amount", "net_amount"]]
save(w5_line_net, "w5_line_net")

first_month = ln.groupby("customer_id")["month"].min().rename("cohort_month")

# ----------------------------------------------------------------------
# 2. 월별 KPI
# ----------------------------------------------------------------------
m = ln.groupby("month").agg(gmv=("gross_amount", "sum"), discount=("discount_amount", "sum"),
                            net_revenue=("net_amount", "sum"), orders=("order_key", "nunique"),
                            active_customers=("customer_id", "nunique"))
m["new_customers"] = first_month.value_counts().reindex(m.index).fillna(0).astype(int)
m["returning_customers"] = m["active_customers"] - m["new_customers"]
m["cumulative_customers"] = m["new_customers"].cumsum()
m["return_rate_of_base"] = m["returning_customers"] / m["cumulative_customers"].shift(1)
m["marketing_cost"] = (mk.assign(month=mk["marketing_date"].dt.to_period("M").dt.to_timestamp())
                       .groupby("month").apply(lambda g: (g["offline_cost"] + g["online_cost"]).sum(),
                                               include_groups=False))
m["online_cost"] = mk.groupby(mk["marketing_date"].dt.to_period("M").dt.to_timestamp())["online_cost"].sum()
m["arpu"] = m["net_revenue"] / m["active_customers"]
m["aov"] = m["net_revenue"] / m["orders"]
m["orders_per_customer"] = m["orders"] / m["active_customers"]
m["cac"] = m["marketing_cost"] / m["new_customers"]
m["roas"] = m["net_revenue"] / m["marketing_cost"]
m["discount_rate"] = m["discount"] / m["gmv"]
w5_monthly_kpi = m.reset_index()
save(w5_monthly_kpi, "w5_monthly_kpi")

# ----------------------------------------------------------------------
# 3. 코호트 리텐션과 LTV (관측할 수 없는 경과월은 결측으로 둔다)
# ----------------------------------------------------------------------
last_month = ln["month"].max()
ln["cohort_month"] = ln["customer_id"].map(first_month)
ln["age"] = ((ln["month"].dt.year - ln["cohort_month"].dt.year) * 12
             + (ln["month"].dt.month - ln["cohort_month"].dt.month))
cohort_size = first_month.value_counts().sort_index()
max_age = {c: (last_month.year - c.year) * 12 + (last_month.month - c.month) for c in cohort_size.index}

act = ln.groupby(["cohort_month", "age"])["customer_id"].nunique().unstack()
ret = act.div(cohort_size, axis=0)
rev = ln.groupby(["cohort_month", "age"])["net_amount"].sum().unstack().fillna(0).cumsum(axis=1)
ltv = rev.div(cohort_size, axis=0)
for c in ltv.index:
    ltv.loc[c, ltv.columns > max_age[c]] = np.nan
    ret.loc[c, ret.columns > max_age[c]] = np.nan
    ret.loc[c, ret.columns <= max_age[c]] = ret.loc[c, ret.columns <= max_age[c]].fillna(0)


w5_cohort_retention = ret.stack(future_stack=True).rename("retention_rate").reset_index()
w5_cohort_retention["cohort_size"] = w5_cohort_retention["cohort_month"].map(cohort_size)
save(w5_cohort_retention, "w5_cohort_retention")
w5_cohort_ltv = ltv.stack(future_stack=True).rename("cumulative_ltv").reset_index()
save(w5_cohort_ltv, "w5_cohort_ltv")

cac = m["cac"]
ue = pd.DataFrame({"cohort_size": cohort_size, "cac": cac.reindex(cohort_size.index),
                   "observed_months": pd.Series(max_age) + 1})
ue["ltv_m0"] = ltv[0]
ue["ltv_m2"] = ltv[2]
ue["ltv_m5"] = ltv[5]
ue["ltv_observed_end"] = [ltv.loc[c, max_age[c]] for c in ue.index]
ue["ltv_cac_m0"] = ue["ltv_m0"] / ue["cac"]
ue["ltv_cac_m5"] = ue["ltv_m5"] / ue["cac"]
ue["ltv_cac_observed_end"] = ue["ltv_observed_end"] / ue["cac"]
ue["breakeven_margin_m0"] = ue["cac"] / ue["ltv_m0"]
ue["breakeven_margin_observed"] = ue["cac"] / ue["ltv_observed_end"]
ue["m0_share_of_observed_ltv"] = ue["ltv_m0"] / ue["ltv_observed_end"]
w5_cohort_unit_econ = ue.reset_index().rename(columns={"index": "cohort_month"})
save(w5_cohort_unit_econ, "w5_cohort_unit_econ")

# ----------------------------------------------------------------------
# 4. 고객 360 통합 테이블 (1~4주차 결과 조인)
# ----------------------------------------------------------------------
cust_net = ln.groupby("customer_id").agg(gmv=("gross_amount", "sum"), discount=("discount_amount", "sum"),
                                         net_revenue=("net_amount", "sum"))
# 첫 구매 카테고리: 첫 구매일에 금액이 가장 큰 카테고리
_first_day = ln.merge(ln.groupby("customer_id")["transaction_date"].min().rename("_fd"),
                      left_on="customer_id", right_index=True)
_first_day = _first_day[_first_day["transaction_date"] == _first_day["_fd"]]
entry_category = (_first_day.groupby(["customer_id", "product_category"])["gross_amount"].sum()
                  .reset_index().sort_values(["customer_id", "gross_amount", "product_category"],
                                             ascending=[True, False, True])
                  .drop_duplicates("customer_id").set_index("customer_id")["product_category"]
                  .rename("entry_category"))

c360 = (cf[["customer_id", "recency", "frequency", "monetary", "purchase_day_count", "avg_order_value",
            "coupon_usage_rate", "coupon_used_line_rate", "known_discount_amount", "first_purchase_date",
            "last_purchase_date", "active_days", "product_category_count"]]
        .rename(columns={"frequency": "frequency_orders"})
        .merge(cust[["customer_id", "gender", "region", "tenure"]], on="customer_id", how="left")
        .merge(cust_net, on="customer_id", how="left")
        .merge(first_month, left_on="customer_id", right_index=True, how="left")
        .merge(entry_category, left_on="customer_id", right_index=True, how="left")
        .merge(rfmp[["customer_id", "frequency_days", "product_value_p", "rfmp_score", "rfmp_tier",
                     "tier_code"]], on="customer_id", how="left")
        .merge(scored[["customer_id", "raw_churn_probability", "customer_maturity_group", "history_band"]],
               on="customer_id", how="left")
        .merge(action[["customer_id", "relative_risk_grade", "relative_risk_percentile", "risk_priority_rank",
                       "rfmp_value_percentile", "value_risk_score", "value_risk_priority_rank",
                       "top_category", "action_rule_id", "action_code", "action_name", "action_channel",
                       "incentive_level"]], on="customer_id", how="left"))
c360["repeat_day_flag"] = (c360["purchase_day_count"] >= 2).astype(int)
c360["months_active"] = (ln.groupby("customer_id")["month"].nunique()
                         .reindex(c360["customer_id"]).to_numpy())
w5_customer_360 = c360
save(w5_customer_360, "w5_customer_360")

# ----------------------------------------------------------------------
# 5. 첫 구매(엔트리) 카테고리별 재구매율
# ----------------------------------------------------------------------
w5_entry_category = (c360.groupby("entry_category")
                     .agg(customers=("customer_id", "size"),
                          repeat_day_rate=("repeat_day_flag", "mean"),
                          avg_net_revenue=("net_revenue", "mean"),
                          vip_diamond_share=("rfmp_tier", lambda s: s.isin(["VIP", "Diamond"]).mean()),
                          high_risk_share=("relative_risk_grade", lambda s: (s == "High").mean()))
                     .sort_values("customers", ascending=False).reset_index())
save(w5_entry_category, "w5_entry_category")

# ----------------------------------------------------------------------
# 6. 카테고리 교차구매 lift (고객 단위, 상위 10개 카테고리)
#    lift(A,B) = P(A와 B를 모두 산 고객) / (P(A) × P(B))   1보다 크면 함께 사는 경향
# ----------------------------------------------------------------------
top10 = ln.groupby("product_category")["customer_id"].nunique().nlargest(10).index
basket = (ln[ln["product_category"].isin(top10)].groupby(["customer_id", "product_category"]).size()
          .unstack(fill_value=0).gt(0).astype(int))[list(top10)]
n = len(c360)
p = basket.sum() / n
both = basket.T @ basket / n
lift = both / np.outer(p, p)
lift.index.name, lift.columns.name = "category_a", "category_b"
both.index.name, both.columns.name = "category_a", "category_b"
w5_category_affinity = lift.stack().rename("lift").reset_index()
w5_category_affinity["both_customers"] = (both.stack().to_numpy() * n).round().astype(int)
save(w5_category_affinity, "w5_category_affinity")

# ----------------------------------------------------------------------
# 7. SAS 결과창 스타일 확인 출력
# ----------------------------------------------------------------------
_kpi = w5_monthly_kpi.assign(month=w5_monthly_kpi["month"].dt.strftime("%Y-%m"))
proc_print(_kpi[["month", "gmv", "discount", "net_revenue", "orders", "active_customers", "new_customers",
                 "returning_customers", "arpu", "aov", "marketing_cost", "cac", "roas"]],
           "R5-1-1. 월별 이커머스 KPI (ARPU·AOV·CAC·ROAS)", dec=2, png="r51_01_monthly_kpi")
_ue = w5_cohort_unit_econ.assign(cohort_month=w5_cohort_unit_econ["cohort_month"].dt.strftime("%Y-%m"))
proc_print(_ue[["cohort_month", "cohort_size", "cac", "ltv_m0", "ltv_m2", "ltv_m5", "ltv_observed_end",
                "ltv_cac_m0", "ltv_cac_observed_end", "breakeven_margin_observed", "m0_share_of_observed_ltv"]],
           "R5-1-2. 코호트별 LTV · CAC · 손익분기 마진율", dec=2, png="r51_02_cohort_unit_econ")
proc_print(w5_entry_category, "R5-1-3. 첫 구매 카테고리별 재구매율과 고객가치", dec=3,
           png="r51_03_entry_category")

tot = w5_monthly_kpi[["net_revenue", "marketing_cost", "discount", "new_customers"]].sum()
title("R5-1 연간 요약")
print(f"연 순매출 {tot['net_revenue']:,.0f} / 연 마케팅비 {tot['marketing_cost']:,.0f} "
      f"/ 연 쿠폰할인 {tot['discount']:,.0f}")
print(f"연 ARPU(고객 1인당 순매출) {tot['net_revenue'] / n:,.0f} / 평균 CAC "
      f"{tot['marketing_cost'] / tot['new_customers']:,.0f} / 연 ROAS {tot['net_revenue'] / tot['marketing_cost']:.2f}")
