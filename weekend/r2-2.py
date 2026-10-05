"""r2-2.sas -> Python 변환본 (Week 2-1 ~ Week 2-3)

  Week 2-1 : crm.clean_online(상품 행) -> crm.w2_order_base(주문 1건 = 1행)
  Week 2-2 : crm.w2_order_base -> crm.w2_rfm(고객 1명 = 1행, RFM 지표)
  Week 2-3 : RFM + 고객정보 + 할인 파생변수 -> crm.w2_customer_features, EDA
             (SAS 의 proc python 블록은 그대로 Python 코드로 옮기고
              SAS.pyplot(plt) 대신 rplots/ 에 PNG 로 저장)

경로 (SAS -> VSCode)
  libname crm "/home/student/crm_db" -> crm_pj/weekend/crm_db (*.pkl)

실행: python crm_pj/weekend/r2-2.py   (선행: r1-1.py, 후행: r3_viz.py)
"""

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

from rcommon import (PIPE_PLOT_DIR, delete, is_missing, load, proc_contents, proc_freq,
                     proc_freq_cross, proc_means, proc_print, save, title)

clean_online = load("clean_online")
clean_customer = load("clean_customer")


# ======================================================================
# Week 2-1. 주문 단위 분석 테이블 생성
# ======================================================================

delete("w2_order_base")

# 3. 상품 행 단위 계산변수
line = clean_online.copy()
line["line_gross_amount"] = line["quantity"] * line["avg_price"]
coupon_up = line["coupon_status"].str.strip().str.upper()
line["line_coupon_used"] = (coupon_up == "USED").astype(int)
line["line_coupon_clicked"] = (coupon_up == "CLICKED").astype(int)
line["line_coupon_not_used"] = (coupon_up == "NOT USED").astype(int)
# RFM 에서 제외할 명확한 오류 (상위 1% 이상치는 포함하지 않음)
line["flag_line_excluded_rfm"] = line[["flag_missing_core", "flag_return",
                                       "flag_zero_quantity", "flag_invalid_price"]].max(axis=1)

w2_unassigned_lines = line[line["order_key"].isna()]
w2_line_base = line[line["order_key"].notna()]

# 4. 상품 행 -> 주문 단위 집계
w2_order_agg = (
    w2_line_base.groupby(["order_key", "customer_id", "transaction_id"], as_index=False)
    .agg(
        order_date=("transaction_date", "min"),
        line_count=("order_key", "size"),
        product_count=("product_id", "nunique"),
        category_count=("product_category", "nunique"),
        order_quantity=("quantity", "sum"),
        order_gross_amount=("line_gross_amount", "sum"),
        _max_ship=("shipping_fee", "max"),
        coupon_used_order=("line_coupon_used", "max"),
        coupon_clicked_order=("line_coupon_clicked", "max"),
        coupon_not_used_order=("line_coupon_not_used", "max"),
        coupon_used_line_count=("line_coupon_used", "sum"),
        coupon_status_count=("coupon_status", "nunique"),
        date_value_count=("transaction_date", "nunique"),
        shipping_value_count=("shipping_fee", "nunique"),
        excluded_rfm_line_count=("flag_line_excluded_rfm", "sum"),
        flag_order_excluded_rfm=("flag_line_excluded_rfm", "max"),
        flag_order_high_quantity=("flag_high_quantity", "max"),
        flag_order_high_price=("flag_high_price", "max"),
        flag_order_high_shipping=("flag_high_shipping", "max"),
        flag_order_invalid_coupon=("flag_invalid_coupon", "max"),
        flag_order_customer_unmatched=("flag_customer_unmatched", "max"),
        flag_order_discount_unmatched=("flag_discount_unmatched", "max"),
        flag_order_tax_unmatched=("flag_tax_unmatched", "max"),
        flag_order_marketing_unmatched=("flag_marketing_unmatched", "max"),
        review_line_count=("flag_any_review", "sum"),
        flag_order_any_review=("flag_any_review", "max"),
    )
)
# 배송료는 상품 행마다 반복되므로 주문별 최대값 1회만 (coalesce(max, 0))
w2_order_agg["order_shipping_fee"] = w2_order_agg.pop("_max_ship").fillna(0)
w2_order_agg["order_gross_with_shipping"] = (w2_order_agg["order_gross_amount"]
                                             + w2_order_agg["order_shipping_fee"])

# 5. 주문 월(해당 월 1일) 추가, 6. 고객ID/주문일/주문키 순 정렬
ORDER_COLS = ["order_key", "customer_id", "transaction_id", "order_date", "line_count",
              "product_count", "category_count", "order_quantity", "order_gross_amount",
              "order_shipping_fee", "order_gross_with_shipping", "coupon_used_order",
              "coupon_clicked_order", "coupon_not_used_order", "coupon_used_line_count",
              "coupon_status_count", "date_value_count", "shipping_value_count",
              "excluded_rfm_line_count", "flag_order_excluded_rfm", "flag_order_high_quantity",
              "flag_order_high_price", "flag_order_high_shipping", "flag_order_invalid_coupon",
              "flag_order_customer_unmatched", "flag_order_discount_unmatched",
              "flag_order_tax_unmatched", "flag_order_marketing_unmatched",
              "review_line_count", "flag_order_any_review"]
w2_order_base = w2_order_agg[ORDER_COLS].copy()
w2_order_base["order_month"] = w2_order_base["order_date"].dt.to_period("M").dt.to_timestamp()
w2_order_base = w2_order_base.sort_values(["customer_id", "order_date", "order_key"],
                                          ignore_index=True)
save(w2_order_base, "w2_order_base")

ORDER_LABELS = {
    "order_key": "고객-거래 복합 주문키", "customer_id": "고객ID", "transaction_id": "거래ID",
    "order_date": "주문일자", "order_month": "주문월", "line_count": "주문 내 상품 행 개수",
    "product_count": "주문 내 제품 종류 수", "category_count": "주문 내 카테고리 종류 수",
    "order_quantity": "주문 전체 수량", "order_gross_amount": "주문 할인 전 상품금액",
    "order_shipping_fee": "주문 배송료", "order_gross_with_shipping": "상품금액과 배송료 합계",
    "coupon_used_order": "주문 내 쿠폰 사용 여부", "coupon_clicked_order": "주문 내 쿠폰 클릭 여부",
    "coupon_not_used_order": "주문 내 쿠폰 미사용 여부",
    "coupon_used_line_count": "쿠폰 사용 상품 행 개수",
    "coupon_status_count": "주문 내 쿠폰상태 종류 수", "date_value_count": "주문 내 거래일자 종류 수",
    "shipping_value_count": "주문 내 배송료 종류 수",
    "excluded_rfm_line_count": "RFM 제외 대상 상품 행 개수",
    "flag_order_excluded_rfm": "RFM 제외 대상 주문", "flag_order_high_quantity": "고수량 행 포함 주문",
    "flag_order_high_price": "고가격 행 포함 주문", "flag_order_high_shipping": "고배송료 행 포함 주문",
    "flag_order_invalid_coupon": "비정상 쿠폰상태 포함 주문",
    "flag_order_customer_unmatched": "고객정보 미매칭 주문",
    "flag_order_discount_unmatched": "할인정보 미매칭 주문",
    "flag_order_tax_unmatched": "세금정보 미매칭 주문",
    "flag_order_marketing_unmatched": "마케팅정보 미매칭 주문",
    "review_line_count": "검토 대상 상품 행 개수", "flag_order_any_review": "검토 대상 행 포함 주문",
}
ORDER_FORMATS = {c: "COMMA18.2" for c in ("order_gross_amount", "order_shipping_fee",
                                          "order_gross_with_shipping")}
ORDER_FORMATS["order_month"] = "YYMMN6."

# 7. 원본 거래 데이터 검산
proc_print(pd.DataFrame([{
    "CLEAN_ONLINE 상품 행 수": len(clean_online),
    "원본 고유 주문 수": clean_online["order_key"].nunique(),
    "원본 고유 고객 수": clean_online["customer_id"].nunique(),
    "주문키 결측 행": int(clean_online["order_key"].isna().sum()),
    "RFM 제외 대상 상품 행": int(line["flag_line_excluded_rfm"].sum())}]),
    "Week 2-1 원본 거래 데이터 검산", png="r22_01_source_qa")

# 8. 주문 단위 테이블 검산
ob = w2_order_base
proc_print(pd.DataFrame([{
    "주문 단위 행 수": len(ob),
    "고유 주문키 수": ob["order_key"].nunique(),
    "중복 주문키 수": len(ob) - ob["order_key"].nunique(),
    "고유 고객 수": ob["customer_id"].nunique(),
    "최초 주문일": ob["order_date"].min(),
    "최종 주문일": ob["order_date"].max(),
    "주문키 결측": int(ob["order_key"].isna().sum()),
    "복수 거래일자 주문": int((ob["date_value_count"] > 1).sum()),
    "복수 배송료 주문": int((ob["shipping_value_count"] > 1).sum()),
    "복수 쿠폰상태 주문": int((ob["coupon_status_count"] > 1).sum()),
    "RFM 제외 대상 주문": int((ob["flag_order_excluded_rfm"] == 1).sum()),
    "검토 대상 주문": int((ob["flag_order_any_review"] == 1).sum())}]),
    "Week 2-1 주문 단위 테이블 검산", png="r22_02_order_qa")

# 9. 주문 단위 수치형 변수 요약
proc_means(ob, ["line_count", "product_count", "category_count", "order_quantity",
                "order_gross_amount", "order_shipping_fee", "order_gross_with_shipping"],
           ("n", "mean", "std", "min", "p25", "median", "p75", "p99", "max"),
           "Week 2-1 주문 단위 수치형 변수 요약", ORDER_LABELS, png="r22_03_means_order")

# 10. 쿠폰상태 구성
proc_freq(ob, "coupon_used_order", "Week 2-1 주문별 쿠폰 사용 및 상태 구성", order="internal",
          png="r22_04_freq_coupon_used_order")
proc_freq(ob, "coupon_status_count", "Week 2-1 주문별 쿠폰 사용 및 상태 구성", order="internal",
          png="r22_04_freq_coupon_status_count")
proc_freq_cross(ob, "coupon_used_order", "coupon_status_count",
                "coupon_used_order * coupon_status_count", png="r22_04_cross_coupon")

# 11. 앞 10행, 12. 구조
proc_print(ob, "CRM.W2_ORDER_BASE 앞 10행", obs=10,
           var=["order_key", "customer_id", "transaction_id", "order_date", "order_month",
                "line_count", "product_count", "category_count", "order_quantity",
                "order_gross_amount", "order_shipping_fee", "order_gross_with_shipping",
                "coupon_used_order", "coupon_status_count", "flag_order_excluded_rfm",
                "flag_order_any_review"], png="r22_05_order_base_head")
proc_contents(ob, "CRM.W2_ORDER_BASE 데이터 구조", ORDER_LABELS, ORDER_FORMATS,
              png="r22_06_contents_order_base")


# ======================================================================
# Week 2-2. 고객별 RFM 지표 생성
# ======================================================================

delete("w2_rfm")

valid = ob[ob["flag_order_excluded_rfm"].fillna(1) == 0].copy()

# 3. RFM 분석 기준일 = 유효 주문 마지막 날짜 + 1일
RFM_REFERENCE_DATE = valid["order_date"].max() + pd.Timedelta(days=1)
print("NOTE: ==============================================")
print(f"NOTE: RFM 분석 기준일 = {RFM_REFERENCE_DATE:%Y-%m-%d}")
print("NOTE: ==============================================")

# 4. 주문 -> 고객 단위 집계
valid["_clicked_only"] = ((valid["coupon_used_order"] == 0)
                          & (valid["coupon_clicked_order"] == 1)).astype(int)
valid["_not_used_only"] = ((valid["coupon_used_order"] == 0) & (valid["coupon_clicked_order"] == 0)
                           & (valid["coupon_not_used_order"] == 1)).astype(int)
w2_rfm = valid.groupby("customer_id", as_index=False).agg(
    first_purchase_date=("order_date", "min"),
    last_purchase_date=("order_date", "max"),
    frequency=("order_key", "nunique"),
    monetary=("order_gross_amount", "sum"),
    monetary_with_shipping=("order_gross_with_shipping", "sum"),
    total_shipping_fee=("order_shipping_fee", "sum"),
    total_quantity=("order_quantity", "sum"),
    purchase_day_count=("order_date", "nunique"),
    avg_order_value=("order_gross_amount", "mean"),
    avg_quantity_per_order=("order_quantity", "mean"),
    avg_products_per_order=("product_count", "mean"),
    avg_categories_per_order=("category_count", "mean"),
    coupon_used_orders=("coupon_used_order", "sum"),
    coupon_clicked_only_orders=("_clicked_only", "sum"),
    coupon_not_used_only_orders=("_not_used_only", "sum"),
    invalid_coupon_orders=("flag_order_invalid_coupon", "sum"),
    high_quantity_orders=("flag_order_high_quantity", "sum"),
    high_price_orders=("flag_order_high_price", "sum"),
    high_shipping_orders=("flag_order_high_shipping", "sum"),
    discount_unmatched_orders=("flag_order_discount_unmatched", "sum"),
    review_order_count=("flag_order_any_review", "sum"),
)
w2_rfm.insert(3, "recency", (RFM_REFERENCE_DATE - w2_rfm["last_purchase_date"]).dt.days)

# 5. 고객 파생변수
w2_rfm["active_days"] = (w2_rfm["last_purchase_date"] - w2_rfm["first_purchase_date"]).dt.days
w2_rfm["customer_observation_days"] = (RFM_REFERENCE_DATE - w2_rfm["first_purchase_date"]).dt.days
w2_rfm["avg_days_between_orders"] = (w2_rfm["active_days"] / (w2_rfm["frequency"] - 1)).where(
    w2_rfm["frequency"] > 1)
w2_rfm["repeat_customer_flag"] = (w2_rfm["frequency"] >= 2).astype(int)
w2_rfm["coupon_usage_rate"] = w2_rfm["coupon_used_orders"] / w2_rfm["frequency"]
w2_rfm["review_order_rate"] = w2_rfm["review_order_count"] / w2_rfm["frequency"]
w2_rfm["coupon_classified_orders"] = w2_rfm[["coupon_used_orders", "coupon_clicked_only_orders",
                                             "coupon_not_used_only_orders"]].sum(axis=1)
w2_rfm["coupon_unclassified_orders"] = w2_rfm["frequency"] - w2_rfm["coupon_classified_orders"]
w2_rfm["rfm_reference_date"] = RFM_REFERENCE_DATE

# 6. 고객ID 순 정렬
w2_rfm = w2_rfm.sort_values("customer_id", ignore_index=True)
save(w2_rfm, "w2_rfm")

RFM_LABELS = {
    "customer_id": "고객ID", "first_purchase_date": "최초 구매일", "last_purchase_date": "마지막 구매일",
    "rfm_reference_date": "RFM 분석 기준일", "recency": "최근 구매 후 경과일",
    "frequency": "총 주문 횟수", "monetary": "누적 상품 구매금액",
    "monetary_with_shipping": "배송료 포함 누적금액", "total_shipping_fee": "누적 배송료",
    "total_quantity": "전체 구매 수량", "purchase_day_count": "구매 발생 날짜 수",
    "avg_order_value": "주문당 평균 상품금액", "avg_quantity_per_order": "주문당 평균 수량",
    "avg_products_per_order": "주문당 평균 제품 종류 수",
    "avg_categories_per_order": "주문당 평균 카테고리 종류 수",
    "active_days": "최초~마지막 구매 기간", "customer_observation_days": "최초 구매~기준일 기간",
    "avg_days_between_orders": "평균 주문 간격", "repeat_customer_flag": "재구매 고객 여부",
    "coupon_used_orders": "쿠폰 사용 주문 수", "coupon_clicked_only_orders": "쿠폰 클릭 후 미사용 주문 수",
    "coupon_not_used_only_orders": "쿠폰 미사용 주문 수", "invalid_coupon_orders": "비정상 쿠폰상태 주문 수",
    "coupon_usage_rate": "쿠폰 사용 주문 비율", "coupon_classified_orders": "쿠폰행동 분류 완료 주문 수",
    "coupon_unclassified_orders": "쿠폰행동 미분류 주문 수", "high_quantity_orders": "고수량 주문 수",
    "high_price_orders": "고가격 주문 수", "high_shipping_orders": "고배송료 주문 수",
    "discount_unmatched_orders": "할인정보 미매칭 주문 수", "review_order_count": "검토 대상 주문 수",
    "review_order_rate": "검토 대상 주문 비율",
}
RFM_FORMATS = {
    **{c: "YYMMDD10." for c in ("first_purchase_date", "last_purchase_date", "rfm_reference_date")},
    **{c: "COMMA18.2" for c in ("monetary", "monetary_with_shipping", "total_shipping_fee",
                                "avg_order_value")},
    **{c: "COMMA12.2" for c in ("avg_quantity_per_order", "avg_products_per_order",
                                "avg_categories_per_order", "avg_days_between_orders")},
    "coupon_usage_rate": "PERCENT8.2", "review_order_rate": "PERCENT8.2",
}

# 7. 고객 단위 RFM 검산
r = w2_rfm
proc_print(pd.DataFrame([{
    "고객 단위 행 수": len(r), "고유 고객 수": r["customer_id"].nunique(),
    "중복 고객ID 수": len(r) - r["customer_id"].nunique(),
    "고객ID 결측": int(is_missing(r["customer_id"]).sum()),
    "Recency 결측": int(r["recency"].isna().sum()), "Frequency 결측": int(r["frequency"].isna().sum()),
    "Monetary 결측": int(r["monetary"].isna().sum()), "음수 Recency": int((r["recency"] < 0).sum()),
    "0 이하 Frequency": int((r["frequency"] <= 0).sum()),
    "0 이하 Monetary": int((r["monetary"] <= 0).sum()),
    "쿠폰 활용률 범위 위반": int(((r["coupon_usage_rate"] < 0) | (r["coupon_usage_rate"] > 1)).sum()),
    "쿠폰 미분류 주문 보유 고객": int((r["coupon_unclassified_orders"] != 0).sum())}]),
    "Week 2-2 고객 단위 RFM 검산", png="r22_07_rfm_qa")

# 8. 주문 테이블과 RFM 합계 일치 (차이는 0 이어야 함)
proc_print(pd.DataFrame([{
    "유효 주문 수": len(valid), "Frequency 합계": int(r["frequency"].sum()),
    "Frequency 차이": int(r["frequency"].sum() - len(valid)),
    "주문 테이블 금액 합계": valid["order_gross_amount"].sum(),
    "RFM Monetary 합계": r["monetary"].sum(),
    "Monetary 차이": round(r["monetary"].sum() - valid["order_gross_amount"].sum(), 6)}]),
    "Week 2-2 주문 데이터와 RFM 합계 비교", png="r22_08_rfm_reconciliation")

# 9. RFM 기초통계
FULL_STATS = ("n", "nmiss", "mean", "std", "min", "p1", "p25", "median", "p75", "p99", "max")
proc_means(r, ["recency", "frequency", "monetary", "avg_order_value", "total_quantity",
               "active_days", "avg_days_between_orders", "coupon_usage_rate"],
           FULL_STATS, "Week 2-2 RFM 기초통계", RFM_LABELS, png="r22_09_means_rfm")

# 10. 재구매 고객 분포
proc_freq(r, "repeat_customer_flag", "Week 2-2 재구매 고객 여부", order="internal",
          png="r22_10_freq_repeat_customer")

# 11. 앞 10행, 12. 구조
proc_print(r, "CRM.W2_RFM 앞 10행", obs=10,
           var=["customer_id", "first_purchase_date", "last_purchase_date", "rfm_reference_date",
                "recency", "frequency", "monetary", "avg_order_value", "total_quantity",
                "active_days", "avg_days_between_orders", "coupon_used_orders",
                "coupon_usage_rate", "repeat_customer_flag", "review_order_count"],
           png="r22_11_rfm_head")
proc_contents(r, "CRM.W2_RFM 데이터 구조", RFM_LABELS, RFM_FORMATS, png="r22_12_contents_rfm")


# ======================================================================
# Week 2-3. 고객정보 및 할인 파생변수 결합과 EDA
# ======================================================================

delete("w2_customer_features")

# 3. 유효 주문에 포함된 상품 행 (inner join)
valid_keys = ob.loc[ob["flag_order_excluded_rfm"].fillna(1) == 0, ["order_key"]]
w2_discount_lines = clean_online.merge(valid_keys, on="order_key", how="inner")[
    ["customer_id", "order_key", "product_id", "product_category", "quantity", "avg_price",
     "coupon_status", "offered_discount_pct", "flag_discount_unmatched"]]

# 4. 상품 행별 쿠폰 및 할인 계산 (추정 할인액)
dc = w2_discount_lines.copy()
dc["line_gross_amount"] = dc["quantity"] * dc["avg_price"]
dc["coupon_used_line"] = (dc["coupon_status"].str.strip().str.upper() == "USED").astype(int)
pct_ok = (dc["flag_discount_unmatched"] == 0) & dc["offered_discount_pct"].between(0, 100)
dc["discount_matched_used"] = ((dc["coupon_used_line"] == 1) & pct_ok).astype(int)
dc["discount_unmatched_used"] = ((dc["coupon_used_line"] == 1) & ~pct_ok).astype(int)
dc["coupon_used_gross_amount"] = dc["line_gross_amount"].where(dc["coupon_used_line"] == 1, 0)
dc["matched_used_gross_amount"] = dc["line_gross_amount"].where(dc["discount_matched_used"] == 1, 0)
dc["known_discount_amount"] = (dc["line_gross_amount"] * dc["offered_discount_pct"] / 100).where(
    dc["discount_matched_used"] == 1, 0)
dc["_applied_pct"] = dc["offered_discount_pct"].where(dc["discount_matched_used"] == 1)

# 5. 고객 단위 집계
w2_discount_customer = dc.groupby("customer_id", as_index=False).agg(
    valid_line_count=("order_key", "size"),
    unique_product_count=("product_id", "nunique"),
    product_category_count=("product_category", "nunique"),
    coupon_used_lines=("coupon_used_line", "sum"),
    discount_matched_used_lines=("discount_matched_used", "sum"),
    discount_unmatched_used_lines=("discount_unmatched_used", "sum"),
    coupon_used_gross_amount=("coupon_used_gross_amount", "sum"),
    matched_used_gross_amount=("matched_used_gross_amount", "sum"),
    known_discount_amount=("known_discount_amount", "sum"),
    avg_applied_discount_pct=("_applied_pct", "mean"),
)

# 6. RFM + 고객정보 + 할인 파생변수 LEFT JOIN
cust = clean_customer[["customer_id", "gender", "region", "tenure"]].assign(_c=1)
disc = w2_discount_customer.assign(_d=1)
cf = w2_rfm.merge(cust, on="customer_id", how="left").merge(disc, on="customer_id", how="left")
for c in ["valid_line_count", "unique_product_count", "product_category_count", "coupon_used_lines",
          "discount_matched_used_lines", "discount_unmatched_used_lines", "coupon_used_gross_amount",
          "matched_used_gross_amount", "known_discount_amount"]:
    cf[c] = cf[c].fillna(0)
cf["flag_customer_info_unmatched"] = cf.pop("_c").isna().astype(int)
cf["flag_discount_feat_missing"] = cf.pop("_d").isna().astype(int)

# 7. 최종 고객 파생변수
tenure_ok = cf["tenure"].notna() & (cf["tenure"] > 0)
cf["orders_per_tenure_month"] = (cf["frequency"] / cf["tenure"]).where(tenure_ok)
cf["monetary_per_tenure_month"] = (cf["monetary"] / cf["tenure"]).where(tenure_ok)
cf["coupon_used_line_rate"] = (cf["coupon_used_lines"] / cf["valid_line_count"]).where(
    cf["valid_line_count"] > 0)
cf["discount_match_rate"] = (cf["discount_matched_used_lines"] / cf["coupon_used_lines"]).where(
    cf["coupon_used_lines"] > 0)
cf["weighted_discount_rate"] = (cf["known_discount_amount"] / cf["matched_used_gross_amount"]).where(
    cf["matched_used_gross_amount"] > 0)
cf["coupon_used_sales_share"] = (cf["coupon_used_gross_amount"] / cf["monetary"]).where(
    cf["monetary"] > 0)
cf["gross_less_known_discount"] = cf["monetary"] - cf["known_discount_amount"]
cf["flag_discount_uncertain"] = (cf["discount_unmatched_used_lines"] > 0).astype(int)

# 8. 고객ID 순 정렬
w2_customer_features = cf.sort_values("customer_id", ignore_index=True)
save(w2_customer_features, "w2_customer_features")

FEAT_LABELS = {
    **RFM_LABELS, "gender": "성별", "region": "고객지역", "tenure": "가입기간",
    "valid_line_count": "유효 상품 행 개수", "unique_product_count": "구매한 제품 종류 수",
    "product_category_count": "구매한 카테고리 종류 수", "coupon_used_lines": "쿠폰 사용 상품 행 수",
    "discount_matched_used_lines": "할인정보 연결 쿠폰 사용 행 수",
    "discount_unmatched_used_lines": "할인정보 미연결 쿠폰 사용 행 수",
    "coupon_used_gross_amount": "쿠폰 사용 상품 할인 전 금액",
    "matched_used_gross_amount": "할인정보 연결 쿠폰 사용 금액",
    "known_discount_amount": "확인 가능한 추정 할인액",
    "avg_applied_discount_pct": "적용 할인율 단순평균(%)",
    "orders_per_tenure_month": "가입기간 월당 주문 횟수",
    "monetary_per_tenure_month": "가입기간 월당 구매금액",
    "coupon_used_line_rate": "상품 행 기준 쿠폰 사용률",
    "discount_match_rate": "쿠폰 사용 행 할인정보 연결률",
    "weighted_discount_rate": "상품금액 가중평균 할인율",
    "coupon_used_sales_share": "쿠폰 사용 상품금액 비중",
    "gross_less_known_discount": "확인된 할인액 차감 상품금액",
    "flag_customer_info_unmatched": "고객정보 미매칭",
    "flag_discount_feat_missing": "할인 파생변수 미매칭", "flag_discount_uncertain": "할인액 불확실 고객",
}

# 9. 최종 고객 테이블 검산
f = w2_customer_features


def out_of_01(s):
    return int(((s < 0) | (s > 1)).sum())


proc_print(pd.DataFrame([{
    "고객 단위 행 수": len(f), "고유 고객 수": f["customer_id"].nunique(),
    "중복 고객ID 수": len(f) - f["customer_id"].nunique(),
    "고객ID 결측": int(is_missing(f["customer_id"]).sum()),
    "성별 결측": int(is_missing(f["gender"]).sum()), "지역 결측": int(is_missing(f["region"]).sum()),
    "가입기간 결측": int(f["tenure"].isna().sum()), "0 이하 가입기간": int((f["tenure"] <= 0).sum()),
    "고객정보 미매칭": int(f["flag_customer_info_unmatched"].sum()),
    "할인 파생변수 미매칭": int(f["flag_discount_feat_missing"].sum()),
    "쿠폰 미분류 주문 보유 고객": int((f["coupon_unclassified_orders"] != 0).sum()),
    "주문 기준 쿠폰율 오류": out_of_01(f["coupon_usage_rate"]),
    "상품 행 기준 쿠폰율 오류": out_of_01(f["coupon_used_line_rate"]),
    "할인정보 연결률 오류": out_of_01(f["discount_match_rate"]),
    "가중평균 할인율 오류": out_of_01(f["weighted_discount_rate"]),
    "할인액 불확실 고객": int(f["flag_discount_uncertain"].sum())}]).T.reset_index()
    .set_axis(["검산 항목", "값"], axis=1),
    "Week 2-3 고객 파생변수 검산", png="r22_13_feature_qa")

# 10. W2_RFM 과 최종 고객 테이블 일치
proc_print(pd.DataFrame([{
    "RFM 고객 수": len(w2_rfm), "최종 고객 수": len(f), "고객 수 차이": len(f) - len(w2_rfm),
    "RFM Monetary 합계": w2_rfm["monetary"].sum(), "최종 Monetary 합계": f["monetary"].sum(),
    "Monetary 차이": round(f["monetary"].sum() - w2_rfm["monetary"].sum(), 6)}]),
    "Week 2-3 RFM과 최종 테이블 일치 확인", png="r22_14_feature_reconciliation")

# 11. 고객 특성별 빈도
proc_freq(f, "gender", "Week 2-3 성별 분포", order="internal", png="r22_15_freq_gender")
proc_freq(f, "region", "Week 2-3 지역별 분포", order="internal", png="r22_15_freq_region")
proc_freq_cross(f, "gender", "region", "Week 2-3 성별과 지역 교차분포", png="r22_15_cross_gender_region")

# 12. 주요 수치형 변수 기초통계
FEAT_VARS = ["recency", "frequency", "monetary", "tenure", "avg_order_value",
             "orders_per_tenure_month", "monetary_per_tenure_month", "unique_product_count",
             "product_category_count", "coupon_usage_rate", "coupon_used_line_rate",
             "discount_match_rate", "weighted_discount_rate", "coupon_used_sales_share",
             "known_discount_amount"]
proc_means(f, FEAT_VARS, FULL_STATS, "Week 2-3 고객 파생변수 기초통계", FEAT_LABELS,
           png="r22_16_means_features")

# 13. 앞 10행, 14. 구조
proc_print(f, "CRM.W2_CUSTOMER_FEATURES 앞 10행", obs=10,
           var=["customer_id", "gender", "region", "tenure", "recency", "frequency", "monetary",
                "avg_order_value", "unique_product_count", "product_category_count",
                "coupon_used_orders", "coupon_usage_rate", "coupon_used_lines",
                "coupon_used_line_rate", "avg_applied_discount_pct", "weighted_discount_rate",
                "known_discount_amount", "flag_discount_uncertain"])
proc_contents(f, "CRM.W2_CUSTOMER_FEATURES 데이터 구조", FEAT_LABELS, RFM_FORMATS,
              png="r22_17_contents_customer_features")


# ======================================================================
# 15. PROC PYTHON 블록 -> 고객 단위 EDA (SAS.sd2df -> load, SAS.pyplot -> savefig)
# ======================================================================

df = load("w2_customer_features")
title("Week 2-3 고객 단위 EDA")
print("\n데이터 크기:", df.shape)

# 15-3. 결측값
missing_summary = pd.DataFrame({"missing_count": df.isna().sum(),
                                "missing_rate_pct": (df.isna().mean() * 100).round(2)})
missing_summary = missing_summary[missing_summary["missing_count"] > 0]
print("\n결측값이 존재하는 변수:")
print("결측값이 없습니다." if missing_summary.empty else missing_summary.to_string())

# 15-4. 기초통계, 15-5. RFM 왜도
print("\n주요 수치형 변수 기초통계:")
print(df[FEAT_VARS].describe().T.round(2).to_string())
print("\nRFM 변수 왜도:")
print(df[["recency", "frequency", "monetary"]].skew().round(3).to_string())

# 15-6/7. 지역별·성별 고객 특성
for key, label in (("region", "지역별"), ("gender", "성별")):
    summary = (df.groupby(key, dropna=False)
               .agg(customers=("customer_id", "nunique"), avg_recency=("recency", "mean"),
                    avg_frequency=("frequency", "mean"), avg_monetary=("monetary", "mean"),
                    avg_coupon_rate=("coupon_usage_rate", "mean"))
               .sort_values("customers", ascending=False).round(2))
    proc_print(summary.reset_index(), f"{label} 고객 특성", png=f"r22_18_{key}_summary")


def save_eda(fig, name):
    PIPE_PLOT_DIR.mkdir(exist_ok=True)
    out = PIPE_PLOT_DIR / name
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)
    print(f"-> 그래프 저장: {out.name}")


# 15-8. RFM 분포
fig, axes = plt.subplots(1, 3, figsize=(15, 4))
for ax, col, color in zip(axes, ["recency", "frequency", "monetary"],
                          ["steelblue", "darkorange", "seagreen"]):
    ax.hist(df[col].dropna(), bins=30, color=color, edgecolor="white")
    ax.set_title(f"{col.capitalize()} Distribution")
    ax.set_xlabel(col.capitalize())
    ax.set_ylabel("Customers")
save_eda(fig, "r22_eda_1_rfm_distribution.png")

# 15-9. Frequency, Monetary 로그변환
fig, axes = plt.subplots(1, 2, figsize=(11, 4))
for ax, col, color in zip(axes, ["frequency", "monetary"], ["darkorange", "seagreen"]):
    ax.hist(np.log1p(df[col].clip(lower=0)).dropna(), bins=30, color=color, edgecolor="white")
    ax.set_title(f"Log {col.capitalize()} Distribution")
    ax.set_xlabel(f"log(1 + {col.capitalize()})")
    ax.set_ylabel("Customers")
save_eda(fig, "r22_eda_2_log_distribution.png")

# 15-10. 상관관계
corr_cols = ["recency", "frequency", "monetary", "tenure", "coupon_usage_rate", "unique_product_count"]
corr = df[corr_cols].corr().round(2)
print("\n주요 변수 상관계수:")
print(corr.to_string())
fig, ax = plt.subplots(figsize=(8, 6))
image = ax.imshow(corr, cmap="coolwarm", vmin=-1, vmax=1)
ax.set_xticks(range(len(corr.columns)))
ax.set_xticklabels(corr.columns, rotation=45, ha="right")
ax.set_yticks(range(len(corr.index)))
ax.set_yticklabels(corr.index)
for i in range(len(corr.index)):
    for j in range(len(corr.columns)):
        ax.text(j, i, f"{corr.iloc[i, j]:.2f}", ha="center", va="center", color="black")
ax.set_title("Customer Feature Correlation")
fig.colorbar(image, ax=ax)
save_eda(fig, "r22_eda_3_correlation.png")

print("\nWeek 2-3 Python EDA가 완료되었습니다.")
