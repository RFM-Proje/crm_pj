"""r1-1.sas (수정본) -> Python 변환본 (Week 1-1 ~ Week 1-5)

  Week 1-1 : CSV 5종 적재 -> crm.raw_*, 구조/행열개수/표본 확인
  Week 1-2 : 한글 변수명 -> 영문 표준화 (crm.stg_*), stg_online 에 order_key 생성
  Week 1-3 : STG 프로파일링 (결측/기술통계/빈도/날짜범위/중복/비정상값/거래키)
  Week 1-4 : 테이블 간 정합성 검사 17건 -> crm.qa_integrity_summary
  Week 1-5 : 정제 테이블(crm.clean_*) + 품질 플래그. 행은 삭제하지 않음

경로 (SAS -> VSCode)
  %let CSV_DIR=/home/student/J.H._Project/Dataset_csv -> crm_pj/open
  libname crm "/home/student/crm_db"                  -> crm_pj/weekend/crm_db (*.pkl)

실행 순서: r1-1.py -> r2-2.py -> r3-1.py -> r4-1.py -> r5_viz.py
SAS 결과창 모양의 표/그래프 PNG 는 crm_pj/weekend/rplots/sas/r11_*.png 로 저장된다.
"""

import pandas as pd

from rcommon import (CSV_DIR, delete, is_missing, load, note, pctl, proc_contents,
                     proc_freq, proc_means, proc_print, save)


# ======================================================================
# Week 1-1. CSV 파일 적재 및 데이터 구조 확인
# ======================================================================

# 3. 기존 RAW 데이터셋 삭제
delete("raw_customer", "raw_online", "raw_discount", "raw_marketing", "raw_tax")


# 4~8. proc import dbms=csv getnames=yes guessingrows=max (UTF-8)
def import_csv(filename):
    return pd.read_csv(CSV_DIR / filename, encoding="utf-8")


raw_customer = import_csv("Customer_info.csv")
raw_online = import_csv("Onlinesales_info.csv")
raw_discount = import_csv("Discount_info.csv")
raw_marketing = import_csv("Marketing_info.csv")
raw_tax = import_csv("Tax_info.csv")

# proc import 는 yyyy-mm-dd 문자열을 날짜형(YYMMDD10.)으로 읽는다
raw_online["거래날짜"] = pd.to_datetime(raw_online["거래날짜"])
raw_marketing["날짜"] = pd.to_datetime(raw_marketing["날짜"])

RAW = {
    "RAW_CUSTOMER": raw_customer,
    "RAW_ONLINE": raw_online,
    "RAW_DISCOUNT": raw_discount,
    "RAW_MARKETING": raw_marketing,
    "RAW_TAX": raw_tax,
}
for name, df in RAW.items():
    save(df, name.lower())

# 10. PROC CONTENTS 로 5개 테이블 구조 확인
proc_contents(raw_customer, "1. Customer_info 데이터 구조", png="r11_01_contents_raw_customer")
proc_contents(raw_online, "2. Onlinesales_info 데이터 구조", png="r11_01_contents_raw_online")
proc_contents(raw_discount, "3. Discount_info 데이터 구조", png="r11_01_contents_raw_discount")
proc_contents(raw_marketing, "4. Marketing_info 데이터 구조", png="r11_01_contents_raw_marketing")
proc_contents(raw_tax, "5. Tax_info 데이터 구조", png="r11_01_contents_raw_tax")

# 11. 적재 결과의 행·열 개수 확인 (dictionary.tables)
proc_print(
    pd.DataFrame([{"테이블명": k, "행 개수": len(v), "열 개수": v.shape[1]}
                  for k, v in sorted(RAW.items())]),
    "원본 테이블별 행 및 열 개수", png="r11_02_raw_table_size")

# 12. 각 테이블의 앞 5행 확인
proc_print(raw_customer, "Customer_info 표본", obs=5, png="r11_03_sample_customer")
proc_print(raw_online, "Onlinesales_info 표본", obs=5, png="r11_03_sample_online")
proc_print(raw_discount, "Discount_info 표본", obs=5, png="r11_03_sample_discount")
proc_print(raw_marketing, "Marketing_info 표본", obs=5, png="r11_03_sample_marketing")
proc_print(raw_tax, "Tax_info 표본", obs=5, png="r11_03_sample_tax")

# 13. 적재 완료 메시지
note("CSV 파일 5종 적재 및 구조 확인이 완료되었습니다.",
     "생성된 데이터셋:", "CRM.RAW_CUSTOMER", "CRM.RAW_ONLINE",
     "CRM.RAW_DISCOUNT", "CRM.RAW_MARKETING", "CRM.RAW_TAX")


# ======================================================================
# Week 1-2. 한글 변수명을 영문 변수명으로 표준화 (RAW 는 수정하지 않음)
# ======================================================================

LABELS = {
    # customer
    "customer_id": "고객ID", "gender": "성별", "region": "고객지역", "tenure": "가입기간",
    # online
    "order_key": "고객-거래 복합키", "transaction_id": "거래ID", "transaction_date": "거래날짜",
    "product_id": "제품ID", "product_category": "제품카테고리", "quantity": "수량",
    "avg_price": "평균금액", "shipping_fee": "배송료", "coupon_status": "쿠폰상태",
    # discount / marketing / tax
    "discount_month": "할인 적용 월", "coupon_code": "쿠폰코드", "discount_pct": "할인율",
    "marketing_date": "마케팅 날짜", "offline_cost": "오프라인 마케팅 비용",
    "online_cost": "온라인 마케팅 비용", "gst_rate": "GST 세율",
}


def make_order_key(df):
    """고객ID|거래ID 복합키 (둘 중 하나라도 결측이면 결측)"""
    ok = ~is_missing(df["customer_id"]) & ~is_missing(df["transaction_id"])
    key = df["customer_id"].astype("string") + "|" + df["transaction_id"].astype("string")
    return key.where(ok)


# 1. Customer_info
stg_customer = raw_customer.rename(columns={
    "고객ID": "customer_id", "성별": "gender", "고객지역": "region", "가입기간": "tenure"})

# 2. Onlinesales_info (order_key 를 맨 앞에 생성)
stg_online = raw_online.rename(columns={
    "고객ID": "customer_id", "거래ID": "transaction_id", "거래날짜": "transaction_date",
    "제품ID": "product_id", "제품카테고리": "product_category", "수량": "quantity",
    "평균금액": "avg_price", "배송료": "shipping_fee", "쿠폰상태": "coupon_status"})
stg_online.insert(0, "order_key", make_order_key(stg_online))

# 3. Discount_info
stg_discount = raw_discount.rename(columns={
    "월": "discount_month", "제품카테고리": "product_category",
    "쿠폰코드": "coupon_code", "할인율": "discount_pct"})

# 4. Marketing_info
stg_marketing = raw_marketing.rename(columns={
    "날짜": "marketing_date", "오프라인비용": "offline_cost", "온라인비용": "online_cost"})

# 5. Tax_info
stg_tax = raw_tax.rename(columns={"제품카테고리": "product_category", "GST": "gst_rate"})

STG = {
    "STG_CUSTOMER": stg_customer,
    "STG_ONLINE": stg_online,
    "STG_DISCOUNT": stg_discount,
    "STG_MARKETING": stg_marketing,
    "STG_TAX": stg_tax,
}
for name, df in STG.items():
    save(df, name.lower())

# 6. 생성된 STG 테이블의 구조 확인
for i, (name, df) in enumerate(STG.items(), start=1):
    proc_contents(df, f"{i}. {name} 구조", labels=LABELS, png=f"r11_04_contents_{name.lower()}")

# 7. RAW 와 STG 의 행 개수 비교
proc_print(pd.DataFrame([
    {"table_name": n.replace("RAW_", ""), "raw_rows": len(RAW[n]),
     "stg_rows": len(STG[n.replace("RAW_", "STG_")])} for n in RAW]),
    "RAW와 STG 행 개수 비교", png="r11_05_raw_vs_stg_rows")

# 8. 영문 변수명과 order_key 생성 결과 확인
proc_print(stg_customer, "STG_CUSTOMER 표본", obs=5)
proc_print(stg_online, "STG_ONLINE 표본 및 복합키 확인", obs=5, png="r11_06_stg_online_sample")


# ======================================================================
# Week 1-3. STG 테이블 데이터 프로파일링
# ======================================================================

# 1. 테이블별 변수 결측치
def missing_row(df):
    row = {"total_rows": len(df)}
    row.update({f"{c}_missing": int(is_missing(df[c]).sum()) for c in df.columns})
    return pd.DataFrame([row])


proc_print(missing_row(stg_customer), "STG_CUSTOMER - 변수별 결측치", png="r11_07_missing_customer")
proc_print(missing_row(stg_online), "STG_ONLINE - 변수별 결측치", png="r11_07_missing_online")
proc_print(missing_row(stg_discount), "STG_DISCOUNT - 변수별 결측치", png="r11_07_missing_discount")
proc_print(missing_row(stg_marketing), "STG_MARKETING - 변수별 결측치", png="r11_07_missing_marketing")
proc_print(missing_row(stg_tax), "STG_TAX - 변수별 결측치", png="r11_07_missing_tax")

# 2. 수치형 변수 기술통계 (n nmiss mean std min p1 q1 median q3 p99 max)
PROFILE_STATS = ("n", "nmiss", "mean", "std", "min", "p1", "q1", "median", "q3", "p99", "max")
proc_means(stg_customer, ["tenure"], PROFILE_STATS, "STG_CUSTOMER - 가입기간 기술통계",
           LABELS, png="r11_08_means_customer")
proc_means(stg_online, ["quantity", "avg_price", "shipping_fee"], PROFILE_STATS,
           "STG_ONLINE - 거래 수치형 변수 기술통계", LABELS, png="r11_08_means_online")
proc_means(stg_discount, ["discount_pct"], PROFILE_STATS, "STG_DISCOUNT - 할인율 기술통계",
           LABELS, png="r11_08_means_discount")
proc_means(stg_marketing, ["offline_cost", "online_cost"], PROFILE_STATS,
           "STG_MARKETING - 마케팅 비용 기술통계", LABELS, png="r11_08_means_marketing")
proc_means(stg_tax, ["gst_rate"], PROFILE_STATS, "STG_TAX - GST 세율 기술통계",
           LABELS, maxdec=4, png="r11_08_means_tax")

# 3. 범주형 변수 빈도 (order=freq, missing)
for v in ("gender", "region", "tenure"):
    proc_freq(stg_customer, v, "STG_CUSTOMER - 범주형 변수 빈도", png=f"r11_09_freq_customer_{v}")
for v in ("product_category", "coupon_status"):
    proc_freq(stg_online, v, "STG_ONLINE - 범주형 변수 빈도", png=f"r11_09_freq_online_{v}")
for v in ("discount_month", "product_category", "coupon_code"):
    proc_freq(stg_discount, v, "STG_DISCOUNT - 범주형 변수 빈도", png=f"r11_09_freq_discount_{v}")
proc_freq(stg_tax, "product_category", "STG_TAX - 제품카테고리 빈도", png="r11_09_freq_tax_product_category")

# 4. 날짜 범위 확인
proc_print(pd.DataFrame([{"최초 거래일": stg_online["transaction_date"].min(),
                          "최종 거래일": stg_online["transaction_date"].max()}]),
           "STG_ONLINE - 거래 날짜 범위", png="r11_10_date_range_online")
proc_print(pd.DataFrame([{"최초 마케팅일": stg_marketing["marketing_date"].min(),
                          "최종 마케팅일": stg_marketing["marketing_date"].max()}]),
           "STG_MARKETING - 마케팅 날짜 범위", png="r11_10_date_range_marketing")

# 5. 완전히 동일한 중복 행 (proc sort nodupkey by _all_ dupout=)
dup = {name: df[df.duplicated(keep="first")] for name, df in STG.items()}
proc_print(pd.DataFrame([{"table_name": n, "중복 행 개수": len(d)} for n, d in dup.items()]),
           "테이블별 완전 중복 행 개수", png="r11_11_duplicate_rows")

# 6. 명백한 비정상값 후보
q, p, sf = stg_online["quantity"], stg_online["avg_price"], stg_online["shipping_fee"]
proc_print(pd.DataFrame([{
    "전체 행": len(stg_online), "수량 음수": int((q < 0).sum()), "수량 0": int((q == 0).sum()),
    "평균금액 0 이하": int((p <= 0).sum()), "배송료 음수": int((sf < 0).sum())}]),
    "STG_ONLINE - 비정상값 후보", png="r11_12_invalid_online")
proc_print(pd.DataFrame([{"전체 행": len(stg_customer),
                          "가입기간 음수": int((stg_customer["tenure"] < 0).sum())}]),
           "STG_CUSTOMER - 비정상값 후보")
dp = stg_discount["discount_pct"]
proc_print(pd.DataFrame([{"전체 행": len(stg_discount),
                          "할인율 범위 위반": int(((dp < 0) | (dp > 100)).sum())}]),
           "STG_DISCOUNT - 비정상값 후보")
proc_print(pd.DataFrame([{"전체 행": len(stg_marketing),
                          "오프라인비용 음수": int((stg_marketing["offline_cost"] < 0).sum()),
                          "온라인비용 음수": int((stg_marketing["online_cost"] < 0).sum())}]),
           "STG_MARKETING - 비정상값 후보")
g = stg_tax["gst_rate"]
proc_print(pd.DataFrame([{"전체 행": len(stg_tax), "GST 범위 위반": int(((g < 0) | (g > 1)).sum())}]),
           "STG_TAX - 비정상값 후보")

# 7. 거래키 구조
proc_print(pd.DataFrame([{
    "전체 거래 상세 행": len(stg_online),
    "고객 수": stg_online["customer_id"].nunique(),
    "거래ID 수": stg_online["transaction_id"].nunique(),
    "고객-거래 복합키 수": stg_online["order_key"].nunique(),
    "복합키 결측 행": int(stg_online["order_key"].isna().sum())}]),
    "STG_ONLINE - 거래키 현황", png="r11_13_key_structure")

reused_transaction_ids = (
    stg_online[~is_missing(stg_online["transaction_id"])]
    .groupby("transaction_id")["customer_id"].nunique()
    .rename("customer_count").reset_index()
    .query("customer_count > 1")
)
proc_print(pd.DataFrame([{"여러 고객에게 사용된 거래ID 수": len(reused_transaction_ids)}]),
           "여러 고객에게 사용된 거래ID 개수")
proc_print(reused_transaction_ids, "여러 고객에게 사용된 거래ID 표본", obs=10)

note("STG 테이블 5종의 프로파일링이 완료되었습니다.",
     "CRM.STG_ 테이블은 수정되지 않았습니다.")


# ======================================================================
# Week 1-4. 테이블 간 데이터 정합성 검사
# ======================================================================

def not_in(left, right):
    return ~left.isin(right.dropna())


# 1. 기준정보 기본키 중복
qa_dup_customer_id = stg_customer.groupby("customer_id").size().loc[lambda s: s > 1]
qa_dup_tax_category = stg_tax.groupby("product_category").size().loc[lambda s: s > 1]
qa_dup_marketing_date = stg_marketing.groupby("marketing_date").size().loc[lambda s: s > 1]
qa_dup_discount_key = (stg_discount.groupby(["discount_month", "product_category"]).size()
                       .loc[lambda s: s > 1])

# 2~5. 참조 무결성 (not exists)
qa_online_customer_missing = (stg_online[not_in(stg_online["customer_id"], stg_customer["customer_id"])]
                              .groupby("customer_id").size())
qa_online_tax_missing = (stg_online[not_in(stg_online["product_category"], stg_tax["product_category"])]
                         .groupby("product_category").size())
qa_online_discount_missing = (
    stg_online[not_in(stg_online["product_category"], stg_discount["product_category"])]
    .groupby("product_category").size().rename("transaction_rows")
    .sort_values(ascending=False).reset_index())
qa_discount_tax_missing = (
    stg_discount[not_in(stg_discount["product_category"], stg_tax["product_category"])]
    .groupby("product_category").size().rename("discount_rows")
    .sort_values(ascending=False).reset_index())

# 6. 거래일 <-> 마케팅일
sales_dates = pd.Series(stg_online["transaction_date"].unique())
mkt_dates = pd.Series(stg_marketing["marketing_date"].unique())
qa_sales_date_missing_mkt = sales_dates[not_in(sales_dates, mkt_dates)].sort_values()
qa_mkt_date_no_sales = mkt_dates[not_in(mkt_dates, sales_dates)].sort_values()

# 7. 여러 고객에게 사용된 거래ID (정보성)
qa_transaction_id_reuse = reused_transaction_ids.sort_values(
    ["customer_count", "transaction_id"], ascending=[False, True])

# 8. 같은 order_key 에 여러 거래날짜
qa_order_date_conflict = (stg_online.dropna(subset=["order_key"])
                          .groupby("order_key")["transaction_date"].nunique().loc[lambda s: s > 1])

# 9. 하나의 제품ID 가 여러 카테고리
qa_product_category_conflict = (stg_online[~is_missing(stg_online["product_id"])]
                                .groupby("product_id")["product_category"].nunique()
                                .loc[lambda s: s > 1])

# 10. 쿠폰상태 코드값
cs = stg_online["coupon_status"]
qa_invalid_coupon_status = stg_online[is_missing(cs) | ~cs.str.strip().str.upper()
                                      .isin(["CLICKED", "USED", "NOT USED"])]

# 11. 할인 월 코드값
MONTHS = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
dm = stg_discount["discount_month"]
qa_invalid_discount_month = stg_discount[is_missing(dm) | ~dm.str.strip().str.upper().isin(MONTHS)]

# 12. 정합성 검사 결과 집계
checks = [
    (1, "Customer ID duplicate", len(qa_dup_customer_id)),
    (2, "Tax category duplicate", len(qa_dup_tax_category)),
    (3, "Marketing date duplicate", len(qa_dup_marketing_date)),
    (4, "Discount month-category duplicate", len(qa_dup_discount_key)),
    (5, "Online customer missing from customer table", len(qa_online_customer_missing)),
    (6, "Online category missing from tax table", len(qa_online_tax_missing)),
    (7, "Online category missing from discount table", len(qa_online_discount_missing)),
    (8, "Online rows without discount category", int(qa_online_discount_missing["transaction_rows"].sum())),
    (9, "Discount category missing from tax table", len(qa_discount_tax_missing)),
    (10, "Discount rows without tax category", int(qa_discount_tax_missing["discount_rows"].sum())),
    (11, "Sales date missing from marketing table", len(qa_sales_date_missing_mkt)),
    (12, "Marketing date without sales", len(qa_mkt_date_no_sales)),
    (13, "Transaction ID used by multiple customers", len(qa_transaction_id_reuse)),
    (14, "Order key linked to multiple dates", len(qa_order_date_conflict)),
    (15, "Product ID linked to multiple categories", len(qa_product_category_conflict)),
    (16, "Invalid coupon status", qa_invalid_coupon_status["coupon_status"].nunique(dropna=False)
     if len(qa_invalid_coupon_status) else 0),
    (17, "Invalid discount month", qa_invalid_discount_month["discount_month"].nunique(dropna=False)
     if len(qa_invalid_discount_month) else 0),
]
qa_integrity_counts = pd.DataFrame(checks, columns=["check_no", "check_name", "issue_count"])

# 13. 검사 상태와 해석 추가
CHECK_TYPE = {**dict.fromkeys([1, 2, 3, 4], "KEY"), **dict.fromkeys([5, 6, 7, 8, 9, 10], "REFERENCE"),
              **dict.fromkeys([11, 12], "DATE"), **dict.fromkeys([13, 14, 15], "MAPPING"),
              **dict.fromkeys([16, 17], "DOMAIN")}
CHECK_NOTE = {
    1: "고객정보의 customer_id는 중복되면 안 됩니다.",
    2: "세금정보의 제품카테고리는 중복되면 안 됩니다.",
    3: "마케팅정보는 날짜별 한 행이어야 합니다.",
    4: "할인 월과 제품카테고리 조합은 한 행이어야 합니다.",
    5: "거래 고객ID가 고객정보에 존재하는지 확인합니다.",
    6: "거래 카테고리가 세금정보에 존재하는지 확인합니다.",
    7: "할인정보가 없는 온라인 제품카테고리 수입니다.",
    8: "할인정보를 연결할 수 없는 온라인 거래 상세 행 수입니다.",
    9: "세금정보에 없는 할인 제품카테고리 수입니다.",
    10: "세금정보를 연결할 수 없는 할인정보 행 수입니다.",
    11: "마케팅비용을 연결할 수 없는 거래일 수입니다.",
    12: "거래가 없는 마케팅 날짜 수입니다.",
    13: "거래ID만 고유키로 사용할 수 없으므로 order_key를 사용합니다.",
    14: "하나의 주문은 하나의 거래날짜에 대응해야 합니다.",
    15: "하나의 제품ID는 하나의 카테고리에 대응해야 합니다.",
    16: "허용되지 않은 쿠폰상태 값이 있는지 확인합니다.",
    17: "Jan부터 Dec 이외의 월 코드가 있는지 확인합니다.",
}
qa_integrity_summary = qa_integrity_counts.assign(
    check_type=qa_integrity_counts["check_no"].map(CHECK_TYPE),
    status=[("INFO" if n == 13 else "PASS" if c == 0 else "REVIEW")
            for n, c in zip(qa_integrity_counts["check_no"], qa_integrity_counts["issue_count"])],
    note=qa_integrity_counts["check_no"].map(CHECK_NOTE),
)[["check_no", "check_type", "check_name", "issue_count", "status", "note"]].sort_values("check_no")
save(qa_integrity_summary, "qa_integrity_summary")

# 14. 전체 정합성 검사 요약 출력
proc_print(qa_integrity_summary.rename(columns={
    "check_no": "검사 번호", "check_type": "검사 유형", "check_name": "검사 항목",
    "issue_count": "문제 후보 수", "status": "상태", "note": "해석"}),
    "4단계 테이블 간 정합성 검사 요약", png="r11_14_integrity_summary")

# 15. 주요 테이블 관계 규모
proc_print(pd.DataFrame([{
    "거래 상세 행 수": len(stg_online),
    "거래 고객 수": stg_online["customer_id"].nunique(),
    "거래ID 수": stg_online["transaction_id"].nunique(),
    "복합 주문키 수": stg_online["order_key"].nunique(),
    "제품 수": stg_online["product_id"].nunique(),
    "제품카테고리 수": stg_online["product_category"].nunique()}]),
    "온라인 거래 테이블의 주요 관계 규모", png="r11_15_relation_scale")

# 16. REVIEW 및 INFO 상세 결과
proc_print(qa_online_discount_missing, "할인정보에 없는 온라인 제품카테고리",
           png="r11_16_online_discount_missing")
proc_print(qa_discount_tax_missing, "세금정보에 없는 할인 제품카테고리")
proc_print(qa_transaction_id_reuse, "여러 고객에게 사용된 거래ID 표본 10개", obs=10)

note("4단계 테이블 간 정합성 검사가 완료되었습니다.",
     "전체 요약은 CRM.QA_INTEGRITY_SUMMARY에 저장되었습니다.")


# ======================================================================
# Week 1-5. 정제 테이블 생성 및 품질 플래그 추가
# ======================================================================

# 0. 이전 실행 결과 정리
delete("clean_customer", "clean_online", "clean_discount", "clean_marketing", "clean_tax",
       "qa_outlier_thresholds", "qa_flag_summary")

# 1-1. 고객정보: 고객ID 대문자, 문자 공백 제거
clean_customer = stg_customer.assign(
    customer_id=stg_customer["customer_id"].str.strip().str.upper(),
    gender=stg_customer["gender"].str.strip(),
    region=stg_customer["region"].str.strip(),
)
# 1-2. 할인정보: 월 propcase, 쿠폰코드 대문자
clean_discount = stg_discount.assign(
    discount_month=stg_discount["discount_month"].str.strip().str.capitalize(),
    product_category=stg_discount["product_category"].str.strip(),
    coupon_code=stg_discount["coupon_code"].str.strip().str.upper(),
)
# 1-3. 마케팅정보 / 1-4. 세금정보
clean_marketing = stg_marketing.copy()
clean_tax = stg_tax.assign(product_category=stg_tax["product_category"].str.strip())

# 2. 온라인 거래 문자값 표준화 (order_key 재생성, transaction_month 생성)
COUPON_MAP = {"CLICKED": "Clicked", "USED": "Used", "NOT USED": "Not Used"}
online_standardized = stg_online.drop(columns="order_key").assign(
    customer_id=lambda d: d["customer_id"].str.strip().str.upper(),
    transaction_id=lambda d: d["transaction_id"].str.strip(),
    product_id=lambda d: d["product_id"].str.strip(),
    product_category=lambda d: d["product_category"].str.strip(),
    coupon_status=lambda d: d["coupon_status"].str.strip().str.upper().map(COUPON_MAP)
    .fillna(d["coupon_status"].str.strip()),
)
online_standardized.insert(0, "order_key", make_order_key(online_standardized))
online_standardized["transaction_month"] = online_standardized["transaction_date"].dt.strftime("%b")

# 3. 99 백분위수 기준 (proc means p99)
p99 = {v: pctl(online_standardized[v], 99) for v in ("quantity", "avg_price", "shipping_fee")}
qa_outlier_thresholds = pd.DataFrame({
    "variable_name": ["quantity", "avg_price", "shipping_fee"],
    "description": ["수량 상위 1% 검토 기준", "평균금액 상위 1% 검토 기준", "배송료 상위 1% 검토 기준"],
    "p99_value": [p99["quantity"], p99["avg_price"], p99["shipping_fee"]],
})
save(qa_outlier_thresholds, "qa_outlier_thresholds")
proc_print(qa_outlier_thresholds.rename(columns={
    "variable_name": "변수명", "description": "설명", "p99_value": "99백분위수 기준값"}),
    "이상치 검토용 99백분위수 기준", png="r11_17_outlier_thresholds")

# 4. 온라인 거래와 기준정보 LEFT JOIN
cust_j = clean_customer[["customer_id", "gender", "region", "tenure"]].assign(_c=1)
disc_j = (clean_discount[["discount_month", "product_category", "coupon_code", "discount_pct"]]
          .rename(columns={"coupon_code": "offered_coupon_code", "discount_pct": "offered_discount_pct"})
          .assign(_month_up=lambda d: d["discount_month"].str.upper(), _d=1)
          .drop(columns="discount_month"))
tax_j = clean_tax[["product_category", "gst_rate"]].assign(_t=1)
mkt_j = clean_marketing.rename(columns={"marketing_date": "transaction_date"}).assign(_m=1)

online_enriched = (
    online_standardized.assign(_month_up=online_standardized["transaction_month"].str.upper())
    .merge(cust_j, on="customer_id", how="left")
    .merge(disc_j, on=["product_category", "_month_up"], how="left")
    .merge(tax_j, on="product_category", how="left")
    .merge(mkt_j, on="transaction_date", how="left")
)
for flag, marker in [("flag_customer_unmatched", "_c"), ("flag_discount_unmatched", "_d"),
                     ("flag_tax_unmatched", "_t"), ("flag_marketing_unmatched", "_m")]:
    online_enriched[flag] = online_enriched[marker].isna().astype(int)
online_enriched = online_enriched.drop(columns=["_month_up", "_c", "_d", "_t", "_m"])

# 5. 품질 플래그 추가하여 CLEAN_ONLINE 생성
co = online_enriched
co["flag_missing_core"] = pd.concat(
    [is_missing(co[c]) for c in ["order_key", "customer_id", "transaction_id", "transaction_date",
                                 "product_id", "product_category", "quantity", "avg_price"]],
    axis=1).any(axis=1).astype(int)
co["flag_return"] = (co["quantity"] < 0).astype(int)
co["flag_zero_quantity"] = (co["quantity"] == 0).astype(int)
co["flag_high_quantity"] = (co["quantity"] > p99["quantity"]).astype(int)
co["flag_invalid_price"] = (co["avg_price"] <= 0).astype(int)
co["flag_high_price"] = (co["avg_price"] > p99["avg_price"]).astype(int)
co["flag_high_shipping"] = (co["shipping_fee"] > p99["shipping_fee"]).astype(int)
co["flag_invalid_coupon"] = (is_missing(co["coupon_status"])
                             | ~co["coupon_status"].str.strip().str.upper()
                             .isin(["CLICKED", "USED", "NOT USED"])).astype(int)
REVIEW_FLAGS = ["flag_missing_core", "flag_return", "flag_zero_quantity", "flag_high_quantity",
                "flag_invalid_price", "flag_high_price", "flag_high_shipping", "flag_invalid_coupon",
                "flag_customer_unmatched", "flag_discount_unmatched", "flag_tax_unmatched",
                "flag_marketing_unmatched"]
co["flag_any_review"] = co[REVIEW_FLAGS].max(axis=1)
clean_online = co

for name, df in [("clean_customer", clean_customer), ("clean_online", clean_online),
                 ("clean_discount", clean_discount), ("clean_marketing", clean_marketing),
                 ("clean_tax", clean_tax)]:
    save(df, name)

# 6. STG 와 CLEAN 행 개수 비교 (CLEAN_ONLINE 이 늘었다면 결합키 중복 의심)
CLEAN = {"CUSTOMER": clean_customer, "ONLINE": clean_online, "DISCOUNT": clean_discount,
         "MARKETING": clean_marketing, "TAX": clean_tax}
proc_print(pd.DataFrame([
    {"테이블명": k, "STG 행 개수": len(STG[f"STG_{k}"]), "CLEAN 행 개수": len(v),
     "행 개수 차이": len(v) - len(STG[f"STG_{k}"])} for k, v in sorted(CLEAN.items())]),
    "STG와 CLEAN 행 개수 비교", png="r11_18_stg_vs_clean_rows")

# 7. 플래그별 건수 집계
FLAG_LABEL = {
    "flag_missing_core": "핵심 변수 결측", "flag_return": "반품 후보", "flag_zero_quantity": "수량 0",
    "flag_high_quantity": "수량 상위 1% 초과", "flag_invalid_price": "평균금액 0 이하",
    "flag_high_price": "평균금액 상위 1% 초과", "flag_high_shipping": "배송료 상위 1% 초과",
    "flag_invalid_coupon": "잘못된 쿠폰상태", "flag_customer_unmatched": "고객정보 미매칭",
    "flag_discount_unmatched": "할인정보 미매칭", "flag_tax_unmatched": "세금정보 미매칭",
    "flag_marketing_unmatched": "마케팅정보 미매칭", "flag_any_review": "검토 대상 행",
}
qa_flag_summary = pd.DataFrame([{"전체 거래 상세 행": len(clean_online),
                                 **{lab: int(clean_online[f].sum()) for f, lab in FLAG_LABEL.items()}}])
save(qa_flag_summary, "qa_flag_summary")
proc_print(qa_flag_summary, "CLEAN_ONLINE 품질 플래그 요약")
# 가로로 긴 요약표는 세로로 돌려 PNG 로 저장
proc_print(qa_flag_summary.T.reset_index().set_axis(["플래그", "건수"], axis=1),
           "CLEAN_ONLINE 품질 플래그 요약 (세로)", png="r11_19_flag_summary")

# 8. 할인정보 미매칭 카테고리
proc_freq(clean_online[clean_online["flag_discount_unmatched"] == 1], "product_category",
          "할인정보가 연결되지 않은 제품카테고리", png="r11_20_freq_discount_unmatched")

# 9. 검토 대상 표본 20개
proc_print(clean_online[clean_online["flag_any_review"] == 1], "하나 이상의 플래그가 있는 거래 표본 20개",
           obs=20, var=["order_key", "transaction_date", "product_category", "quantity", "avg_price",
                        "shipping_fee", "coupon_status", "flag_missing_core", "flag_return",
                        "flag_zero_quantity", "flag_high_quantity", "flag_invalid_price",
                        "flag_high_price", "flag_high_shipping", "flag_invalid_coupon",
                        "flag_discount_unmatched", "flag_tax_unmatched"])

# 10. 최종 정제 테이블 구조
proc_contents(clean_online, "최종 CLEAN_ONLINE 데이터 구조",
              labels={**LABELS, **FLAG_LABEL, "transaction_month": "거래 월",
                      "offered_coupon_code": "제공 쿠폰코드", "offered_discount_pct": "제공 할인율"},
              png="r11_21_contents_clean_online")

# 11. CLEAN_ONLINE 앞 10행
proc_print(clean_online, "최종 CLEAN_ONLINE 앞 10행", obs=10)

# 12. 완료 메시지
note("5단계 정제 테이블 생성이 완료되었습니다.",
     "RAW_ 및 STG_ 테이블은 수정되지 않았습니다.",
     "이상치와 반품 후보 행은 삭제하지 않았습니다.",
     "최종 거래 테이블: CRM.CLEAN_ONLINE",
     "고객/할인/마케팅/세금: CRM.CLEAN_CUSTOMER / DISCOUNT / MARKETING / TAX",
     "이상치 기준: CRM.QA_OUTLIER_THRESHOLDS, 플래그 요약: CRM.QA_FLAG_SUMMARY")

assert len(load("clean_online")) == len(stg_online), "CLEAN_ONLINE 행 수가 STG 와 달라졌습니다(결합키 중복)."
