"""r6-1. 분석 기준 교정 - 구매일 단위, GST 제외 매출, 두 번째 구매 전환 모델, 마케팅 효과 검정, 마진 시나리오

왜 다시 계산하는가 (r5-1 점검 결과)
  1) '주문'이 실제 결제 단위가 아니다: 고객 1명이 하루 평균 8.3건, 구매일의 80%에 2건 이상.
     -> 모든 행동 지표를 '구매일(고객 × 날짜)' 단위로 다시 계산한다.
  2) 90일 이탈 기준은 기본 이탈률이 76%라 판별이 어렵다.
     -> 목표를 '첫 구매 후 90일 안에 다른 날 다시 구매(두 번째 구매 전환)'로 바꾼다.
  3) CAC = 마케팅비 ÷ 신규 고객은 마케팅비가 신규를 만든다는 전제가 필요하다.
     -> 일별·주별 마케팅비와 성과의 관계를 먼저 검정한다.
  4) 원가가 없어 이익을 모른다 -> GST 제외 매출에 마진 20/30/40% 시나리오를 적용한다.
  5) 쿠폰은 비교군(미발송)이 없어 효과를 판단할 수 없다 -> 모델 변수와 실행 수단에서 제외한다.
     (실제 할인된 금액은 매출에서 계속 차감한다)

가정
  - 평균금액(avg_price)은 GST 포함 소비자가로 본다. 회사 귀속 매출 = 순매출 ÷ (1 + GST). 보수적 가정.
  - 배송료는 고객이 내는 비용이며 매출에 포함하지 않는다.

입력: w5_line_net, w2_order_base, clean_tax, clean_marketing, clean_customer (r1-1 ~ r5-1)
산출 (crm_db, 표 이미지는 만들지 않음):
  w6_purchase_day     구매일(고객 × 날짜) 1행: 주문 수, 상품 행, 카테고리 수, 순매출, GST 제외 매출
  w6_customer         고객 1행: 구매일 수, 첫/마지막 구매일, GST 제외 매출
  w6_monthly_kpi      월별: 구매일 수, 활성·신규 고객, GST 제외 매출, 구매일당 매출, blended CAC, ROAS
  w6_conv_base        두 번째 구매 전환 분석 대상(첫 구매 ≤ 2019-10-02) 고객 1행: 첫 구매일 피처 + 라벨
  w6_conv_metrics     로지스틱·GBM의 TRAIN/VALID 성능
  w6_conv_scored      VALID 고객별 예측 전환확률
  w6_conv_decile      VALID 예측 10분위별 실제 전환율
  w6_conv_coef        로지스틱 표준화 계수
  w6_conv_segments    첫 구매 특성별 전환율(설명용)
  w6_mkt_lag          마케팅비 시차 0~14일 vs 매출·신규·구매일 상관과 p값
  w6_mkt_regression   요일·추세를 통제한 회귀 (Newey-West 표준오차)
  w6_ltv_margin       코호트별 이익 기준 LTV/CAC (마진 20/30/40%)
  w6_uplift           두 번째 구매 전환율 +3/+5/+10%p 시나리오의 추가 매출·이익
"""

import numpy as np
import pandas as pd
from scipy import stats
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import average_precision_score, brier_score_loss, roc_auc_score
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler

from rcommon import load, save, title

SEED = 2026
WINDOW = 90
LABEL_CUTOFF = pd.Timestamp("2019-10-02")     # 첫 구매가 이 날 이전이어야 90일 관찰 가능
TRAIN_END = pd.Timestamp("2019-06-30")        # 첫 구매일 기준 시간 분리
MARGINS = (0.2, 0.3, 0.4)

ln = load("w5_line_net")
ob = load("w2_order_base")
tax = load("clean_tax")[["product_category", "gst_rate"]]
mk = load("clean_marketing")
cust = load("clean_customer")

# ======================================================================
# 1. 구매일 단위 테이블 (GST 제외 매출 포함)
# ======================================================================
ln = ln.merge(tax, on="product_category", how="left")
assert ln["gst_rate"].notna().all(), "GST 세율이 연결되지 않은 카테고리가 있습니다."
ln["revenue_ex_gst"] = ln["net_amount"] / (1 + ln["gst_rate"])
ln["gst_amount"] = ln["net_amount"] - ln["revenue_ex_gst"]

ship = (ob[ob["flag_order_excluded_rfm"] == 0].groupby(["customer_id", "order_date"])["order_shipping_fee"].sum()
        .rename("shipping_fee"))
pdays = (ln.groupby(["customer_id", "transaction_date"])
         .agg(orders=("order_key", "nunique"), lines=("order_key", "size"),
              categories=("product_category", "nunique"), gross=("gross_amount", "sum"),
              discount=("discount_amount", "sum"), net=("net_amount", "sum"),
              revenue_ex_gst=("revenue_ex_gst", "sum"), gst=("gst_amount", "sum"))
         .reset_index().rename(columns={"transaction_date": "purchase_date"}))
pdays = pdays.merge(ship.reset_index().rename(columns={"order_date": "purchase_date"}),
                    on=["customer_id", "purchase_date"], how="left")
pdays["month"] = pdays["purchase_date"].dt.to_period("M").dt.to_timestamp()
pdays = pdays.sort_values(["customer_id", "purchase_date"], ignore_index=True)
pdays["day_no"] = pdays.groupby("customer_id").cumcount() + 1
save(pdays, "w6_purchase_day")

cu = pdays.groupby("customer_id").agg(purchase_days=("purchase_date", "size"),
                                      first_day=("purchase_date", "min"), last_day=("purchase_date", "max"),
                                      orders=("orders", "sum"), revenue_ex_gst=("revenue_ex_gst", "sum"),
                                      net=("net", "sum"), gst=("gst", "sum")).reset_index()
cu["revenue_per_day"] = cu["revenue_ex_gst"] / cu["purchase_days"]
save(cu, "w6_customer")

# ======================================================================
# 2. 월별 KPI (구매일 단위)
# ======================================================================
spend = (mk.assign(month=mk["marketing_date"].dt.to_period("M").dt.to_timestamp(),
                   spend=mk["offline_cost"] + mk["online_cost"]).groupby("month")["spend"].sum())
m = pdays.groupby("month").agg(purchase_days=("purchase_date", "size"), orders=("orders", "sum"),
                               active=("customer_id", "nunique"), net=("net", "sum"),
                               revenue_ex_gst=("revenue_ex_gst", "sum"))
m["new"] = cu["first_day"].dt.to_period("M").dt.to_timestamp().value_counts().reindex(m.index).fillna(0)
m["returning"] = m["active"] - m["new"]
m["days_per_active"] = m["purchase_days"] / m["active"]
m["orders_per_day"] = m["orders"] / m["purchase_days"]
m["revenue_per_day"] = m["revenue_ex_gst"] / m["purchase_days"]
m["arpu_ex_gst"] = m["revenue_ex_gst"] / m["active"]
m["marketing_cost"] = spend
m["blended_cac"] = m["marketing_cost"] / m["new"]
m["roas_ex_gst"] = m["revenue_ex_gst"] / m["marketing_cost"]
w6_monthly_kpi = m.reset_index()
save(w6_monthly_kpi, "w6_monthly_kpi")

# ======================================================================
# 3. 두 번째 구매 전환 분석 대상과 첫 구매일 피처
# ======================================================================
first = pdays[pdays["day_no"] == 1].set_index("customer_id")
later = pdays[pdays["day_no"] > 1].merge(first["purchase_date"].rename("first_day"),
                                        left_on="customer_id", right_index=True)
later["gap"] = (later["purchase_date"] - later["first_day"]).dt.days
second_gap = later.groupby("customer_id")["gap"].min()
rev90 = later[later["gap"] <= WINDOW].groupby("customer_id")["revenue_ex_gst"].sum()

# 첫 구매일 대표 카테고리(금액 1위, 상위 6개 외는 Other)
fd_lines = ln.merge(first["purchase_date"].rename("fd"), left_on="customer_id", right_index=True)
fd_lines = fd_lines[fd_lines["transaction_date"] == fd_lines["fd"]]
entry = (fd_lines.groupby(["customer_id", "product_category"])["net_amount"].sum().reset_index()
         .sort_values(["customer_id", "net_amount", "product_category"], ascending=[True, False, True])
         .drop_duplicates("customer_id").set_index("customer_id")["product_category"])
top_cats = entry.value_counts().head(6).index
entry = entry.where(entry.isin(top_cats), "Other")

daily_spend = (mk.assign(spend=mk["offline_cost"] + mk["online_cost"]).set_index("marketing_date")["spend"])
spend7 = daily_spend.rolling(7, min_periods=1).sum()

cb = first[["purchase_date", "orders", "lines", "categories", "net", "revenue_ex_gst", "discount", "gross",
            "shipping_fee"]].copy()
cb.columns = ["first_day", "first_orders", "first_lines", "first_categories", "first_net",
              "first_revenue_ex_gst", "first_discount", "first_gross", "first_shipping"]
cb = cb[cb["first_day"] <= LABEL_CUTOFF].copy()
cb["first_discount_rate"] = (cb["first_discount"] / cb["first_gross"]).fillna(0)
cb["log_first_revenue"] = np.log1p(cb["first_revenue_ex_gst"])
cb["log_first_lines"] = np.log1p(cb["first_lines"])
cb["entry_category"] = entry.reindex(cb.index)
cb["first_month"] = cb["first_day"].dt.month
cb["first_weekday"] = cb["first_day"].dt.dayofweek.map(dict(enumerate("월화수목금토일")))
cb["spend_7d_before"] = spend7.reindex(cb["first_day"]).to_numpy()
cb = cb.join(cust.set_index("customer_id")[["gender", "region", "tenure"]])
cb["second_gap"] = second_gap.reindex(cb.index)
cb["converted_90d"] = (cb["second_gap"] <= WINDOW).astype(int)
cb["revenue_next_90d"] = rev90.reindex(cb.index).fillna(0)
cb["split"] = np.where(cb["first_day"] <= TRAIN_END, "TRAIN", "VALID")
cb = cb.reset_index()
save(cb, "w6_conv_base")

# ======================================================================
# 4. 두 번째 구매 전환 모델 (쿠폰 변수 제외, 첫 구매일 정보만 사용)
# ======================================================================
NUM = ["log_first_revenue", "log_first_lines", "first_categories", "first_orders", "first_discount_rate",
       "first_shipping", "tenure", "spend_7d_before"]
CAT = ["entry_category", "gender", "region", "first_weekday"]
tr, va = cb[cb["split"] == "TRAIN"], cb[cb["split"] == "VALID"]
pre = ColumnTransformer([("num", StandardScaler(), NUM),
                         ("cat", OneHotEncoder(handle_unknown="ignore"), CAT)])
models = {
    "LOGISTIC": Pipeline([("pre", pre), ("clf", LogisticRegression(max_iter=2000, C=0.5))]),
    "GBM": Pipeline([("pre", pre), ("clf", GradientBoostingClassifier(
        n_estimators=150, learning_rate=0.03, max_depth=2, subsample=0.8, random_state=SEED))]),
}
rows, scored = [], va[["customer_id", "first_day", "converted_90d", "revenue_next_90d", "entry_category"]].copy()
for name, mdl in models.items():
    mdl.fit(tr[NUM + CAT], tr["converted_90d"])
    for role, d in (("TRAIN", tr), ("VALID", va)):
        p = mdl.predict_proba(d[NUM + CAT])[:, 1]
        y = d["converted_90d"]
        top = np.argsort(-p)[: max(1, len(p) // 5)]
        rows.append({"model": name, "dataset_role": role, "customers": len(d), "conversion_rate": y.mean(),
                     "mean_probability": p.mean(), "roc_auc": roc_auc_score(y, p),
                     "pr_auc": average_precision_score(y, p), "brier": brier_score_loss(y, p),
                     "top20_conversion": y.to_numpy()[top].mean(),
                     "top20_lift": y.to_numpy()[top].mean() / y.mean()})
        if role == "VALID":
            scored[f"p_{name.lower()}"] = p
# 진단: 시간 분할이 아닌 층화 5겹 교차검증(전체 대상). 시간 분할 결과가 분할 우연 때문인지 확인만 하며
# 공식 성능은 시간 분할 VALID 이다.
from sklearn.model_selection import StratifiedKFold, cross_val_predict  # noqa: E402

cv = StratifiedKFold(5, shuffle=True, random_state=SEED)
for name, mdl in models.items():
    p = cross_val_predict(mdl, cb[NUM + CAT], cb["converted_90d"], cv=cv, method="predict_proba")[:, 1]
    y = cb["converted_90d"]
    top = np.argsort(-p)[: len(p) // 5]
    rows.append({"model": name, "dataset_role": "CV5_DIAGNOSTIC", "customers": len(cb), "conversion_rate": y.mean(),
                 "mean_probability": p.mean(), "roc_auc": roc_auc_score(y, p),
                 "pr_auc": average_precision_score(y, p), "brier": brier_score_loss(y, p),
                 "top20_conversion": y.to_numpy()[top].mean(), "top20_lift": y.to_numpy()[top].mean() / y.mean()})
w6_conv_metrics = pd.DataFrame(rows)
save(w6_conv_metrics, "w6_conv_metrics")

best = w6_conv_metrics[w6_conv_metrics["dataset_role"] == "VALID"].sort_values("roc_auc").iloc[-1]["model"]
scored["p_best"] = scored[f"p_{best.lower()}"]
scored["best_model"] = best
scored["decile"] = pd.qcut(scored["p_best"].rank(method="first", ascending=False), 10, labels=range(1, 11))
save(scored, "w6_conv_scored")
w6_conv_decile = (scored.groupby("decile", observed=True)
                  .agg(customers=("customer_id", "size"), predicted=("p_best", "mean"),
                       actual=("converted_90d", "mean"), revenue_next_90d=("revenue_next_90d", "mean"))
                  .reset_index())
save(w6_conv_decile, "w6_conv_decile")

lg = models["LOGISTIC"]
names = lg.named_steps["pre"].get_feature_names_out()
coef = pd.DataFrame({"feature": [n.split("__", 1)[1] for n in names],
                     "coefficient": lg.named_steps["clf"].coef_[0]})
coef["abs"] = coef["coefficient"].abs()
w6_conv_coef = coef.sort_values("abs", ascending=False, ignore_index=True)
save(w6_conv_coef, "w6_conv_coef")

# 설명용: 첫 구매 특성별 전환율 (전체 대상 고객)
seg = []
cb["first_lines_band"] = pd.cut(cb["first_lines"], [0, 2, 5, 10, 20, 1e9], labels=["1~2", "3~5", "6~10", "11~20", "21+"])
cb["first_categories_band"] = pd.cut(cb["first_categories"], [0, 1, 2, 3, 5, 99], labels=["1", "2", "3", "4~5", "6+"])
cb["first_revenue_band"] = pd.qcut(cb["first_revenue_ex_gst"], 5, labels=["하위 20%", "20~40%", "40~60%", "60~80%", "상위 20%"])
for dim, lab in [("first_lines_band", "첫 구매 상품 행 수"), ("first_categories_band", "첫 구매 카테고리 수"),
                 ("first_revenue_band", "첫 구매 금액 5분위"), ("entry_category", "첫 구매 대표 카테고리"),
                 ("first_month", "첫 구매 월"), ("region", "지역")]:
    g = cb.groupby(dim, observed=True)["converted_90d"].agg(["mean", "size"]).reset_index()
    for r in g.itertuples(index=False):
        n, p = r[2], r[1]
        seg.append({"dimension": lab, "level": str(r[0]), "customers": n, "conversion": p,
                    "ci_half": 1.96 * np.sqrt(p * (1 - p) / n)})
w6_conv_segments = pd.DataFrame(seg)
save(w6_conv_segments, "w6_conv_segments")

# ======================================================================
# 5. 마케팅비 효과 검정
# ======================================================================
days = pd.date_range("2019-01-01", "2019-12-31")
dd = pd.DataFrame(index=days)
dd["spend"] = daily_spend.reindex(days).fillna(0)
dd["online"] = mk.set_index("marketing_date")["online_cost"].reindex(days).fillna(0)
dd["offline"] = mk.set_index("marketing_date")["offline_cost"].reindex(days).fillna(0)
dd["revenue"] = pdays.groupby("purchase_date")["revenue_ex_gst"].sum().reindex(days).fillna(0)
dd["purchase_days"] = pdays.groupby("purchase_date").size().reindex(days).fillna(0)
dd["new_customers"] = cu.groupby("first_day").size().reindex(days).fillna(0)
dd["returning_days"] = dd["purchase_days"] - dd["new_customers"]

lag_rows = []
for target in ("revenue", "new_customers", "returning_days"):
    for driver in ("spend", "online", "offline"):
        for lag in range(0, 15):
            x = dd[driver].shift(lag)
            ok = x.notna()
            r, p = stats.pearsonr(x[ok], dd.loc[ok, target])
            lag_rows.append({"target": target, "driver": driver, "lag_days": lag, "corr": r, "p_value": p})
w6_mkt_lag = pd.DataFrame(lag_rows)
save(w6_mkt_lag, "w6_mkt_lag")


def ols_newey_west(y, X, lags=7):
    X = np.column_stack([np.ones(len(X)), X])
    beta, *_ = np.linalg.lstsq(X, y, rcond=None)
    e = y - X @ beta
    XtX_inv = np.linalg.inv(X.T @ X)
    S = (X * e[:, None]).T @ (X * e[:, None])
    for L in range(1, lags + 1):
        w = 1 - L / (lags + 1)
        G = (X[L:] * e[L:, None]).T @ (X[:-L] * e[:-L, None])
        S += w * (G + G.T)
    se = np.sqrt(np.diag(XtX_inv @ S @ XtX_inv))
    r2 = 1 - (e @ e) / ((y - y.mean()) @ (y - y.mean()))
    return beta, se, r2


reg_rows = []
wd = pd.get_dummies(dd.index.dayofweek, prefix="wd", drop_first=True).to_numpy(float)
trend = np.arange(len(dd)) / len(dd)
for target in ("revenue", "new_customers", "returning_days"):
    y = dd[target].to_numpy(float)
    sp = dd["spend"].to_numpy(float) / 1000
    sp7 = dd["spend"].rolling(7, min_periods=1).mean().shift(1).bfill().to_numpy(float) / 1000
    for spec, X, names in [
        ("단순", np.column_stack([sp]), ["spend_same_day"]),
        ("요일·추세 통제", np.column_stack([sp, wd, trend]), ["spend_same_day"]),
        ("요일·추세 + 직전 7일 평균", np.column_stack([sp, sp7, wd, trend]), ["spend_same_day", "spend_prev7_avg"]),
    ]:
        beta, se, r2 = ols_newey_west(y, X)
        for i, nm in enumerate(names, start=1):
            t = beta[i] / se[i]
            reg_rows.append({"target": target, "spec": spec, "term": nm, "coef_per_1000": beta[i],
                             "se": se[i], "t": t, "p_value": 2 * (1 - stats.t.cdf(abs(t), len(y) - X.shape[1] - 1)),
                             "r2": r2, "target_mean": y.mean()})
# 주 단위(요일 효과 제거)
wk = dd.resample("W-SUN").sum()[dd.resample("W-SUN").size() == 7]   # 7일이 다 있는 주만 (1월 첫 주 6일·12월 마지막 주 2일 제외)
for target in ("revenue", "new_customers", "returning_days"):
    r, p = stats.pearsonr(wk["spend"], wk[target])
    reg_rows.append({"target": target, "spec": "주 단위 상관", "term": "weekly_spend", "coef_per_1000": np.nan,
                     "se": np.nan, "t": np.nan, "p_value": p, "r2": r ** 2, "target_mean": wk[target].mean(),
                     "corr": r})
w6_mkt_regression = pd.DataFrame(reg_rows)
save(w6_mkt_regression, "w6_mkt_regression")
save(dd.reset_index().rename(columns={"index": "date"}), "w6_daily")

# ======================================================================
# 6. 이익 기준 LTV/CAC (마진 시나리오)
# ======================================================================
cohort = cu.set_index("customer_id")["first_day"].dt.to_period("M").dt.to_timestamp()
pdays["cohort"] = pdays["customer_id"].map(cohort)
pdays["age"] = ((pdays["month"].dt.year - pdays["cohort"].dt.year) * 12
                + pdays["month"].dt.month - pdays["cohort"].dt.month)
size = cohort.value_counts().sort_index()
last = pdays["month"].max()
cum = pdays.groupby(["cohort", "age"])["revenue_ex_gst"].sum().unstack().fillna(0).cumsum(axis=1)
ltv = cum.div(size, axis=0)
lt_rows = []
for c in ltv.index:
    obs = (last.year - c.year) * 12 + last.month - c.month
    for margin in MARGINS:
        for horizon, a in (("M0", 0), ("M2", 2), ("M5", 5), ("관찰말", obs)):
            if a > obs:
                continue
            rev = ltv.loc[c, a]
            lt_rows.append({"cohort_month": c, "cohort_size": size[c], "margin": margin, "horizon": horizon,
                            "age": a, "ltv_revenue_ex_gst": rev, "ltv_profit": rev * margin,
                            "blended_cac": m.loc[c, "blended_cac"],
                            "profit_ltv_cac": rev * margin / m.loc[c, "blended_cac"]})
w6_ltv_margin = pd.DataFrame(lt_rows)
save(w6_ltv_margin, "w6_ltv_margin")

# ======================================================================
# 7. 두 번째 구매 전환율 개선 시나리오
# ======================================================================
conv_rate = cb["converted_90d"].mean()
value_per_convert = cb.loc[cb["converted_90d"] == 1, "revenue_next_90d"].mean()
annual_new = len(cu)
up = []
for pp in (0.03, 0.05, 0.10):
    extra = annual_new * pp
    rev = extra * value_per_convert
    for margin in MARGINS:
        up.append({"uplift_pp": pp, "extra_converters": extra, "value_per_convert_90d": value_per_convert,
                   "extra_revenue_ex_gst": rev, "margin": margin, "extra_profit": rev * margin,
                   "base_conversion": conv_rate, "annual_new_customers": annual_new,
                   "annual_marketing": m["marketing_cost"].sum()})
w6_uplift = pd.DataFrame(up)
save(w6_uplift, "w6_uplift")

# ======================================================================
# 8. 콘솔 요약
# ======================================================================
title("r6-1 요약")
print(f"구매일 {len(pdays):,}일 · 고객 {len(cu):,}명 · 구매일당 주문 {pdays['orders'].mean():.2f}건 "
      f"· 2건 이상인 구매일 {(pdays['orders'] > 1).mean():.1%}")
print(f"GST 제외 연매출 {cu['revenue_ex_gst'].sum():,.0f} (순매출 {cu['net'].sum():,.0f}, GST {cu['gst'].sum():,.0f})")
print(f"전환 대상 {len(cb):,}명 (TRAIN {len(tr)}, VALID {len(va)}) · 90일 내 두 번째 구매 전환율 {conv_rate:.1%}")
print(w6_conv_metrics.round(3).to_string(index=False))
print("\n최고 모델:", best)
print(w6_conv_decile.round(3).to_string(index=False))
print("\n로지스틱 계수 상위 10")
print(w6_conv_coef.head(10).round(3).to_string(index=False))
print("\n마케팅 회귀 (Newey-West)")
print(w6_mkt_regression.round(4).to_string(index=False))
lagsum = w6_mkt_lag[w6_mkt_lag["driver"] == "spend"]
print(f"\n시차 0~14일 상관 범위: 매출 {lagsum.loc[lagsum.target == 'revenue', 'corr'].min():.3f}~"
      f"{lagsum.loc[lagsum.target == 'revenue', 'corr'].max():.3f}, 신규 {lagsum.loc[lagsum.target == 'new_customers', 'corr'].min():.3f}~"
      f"{lagsum.loc[lagsum.target == 'new_customers', 'corr'].max():.3f}")
print("\n이익 LTV/CAC (관찰말)")
print(w6_ltv_margin[w6_ltv_margin["horizon"] == "관찰말"].pivot(index="cohort_month", columns="margin",
                                                               values="profit_ltv_cac").round(2).to_string())
print("\n전환 개선 시나리오")
print(w6_uplift.round(1).to_string(index=False))
