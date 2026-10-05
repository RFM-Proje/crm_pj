"""대시보드 2기 데이터 준비 - weekend/crm_db 의 분석 결과(r1-1 ~ r6-1)를 고객 360 · 여정 · 캠페인 뷰로 묶는다.

개인정보 처리 원칙(시연용): 분석은 익명 customer_id 로 수행했고, 화면에서만 가명(name)을 매핑한다.
가명은 data/names.csv 에서 고정 시드로 배정하며 실제 인물과 무관하다.
"""

import csv
import sys
import time as _time
from pathlib import Path

import numpy as np
import pandas as pd

WEB_DIR = Path(__file__).resolve().parent
WEEKEND_DIR = WEB_DIR.parent / "weekend"
sys.path.insert(0, str(WEEKEND_DIR))
from rcommon import load  # noqa: E402

TIERS = ["VIP", "Diamond", "Platinum", "Gold", "Silver", "Bronze"]
GUARD_TIERS = ["VIP", "Diamond", "Platinum", "Gold"]     # 이 등급 × 이탈 위험 High = 고가치 위험 고객 (규칙 2·3 기준과 동일)
RISKS = ["High", "Medium", "Low"]
# 혜택 수준별 방어 성공률 가정 (자동 알림 < 소액 혜택 < 개별 대응)
DEFAULT_MARGIN = 0.30


def _names(n):
    with (WEB_DIR / "data" / "names.csv").open(encoding="utf-8-sig") as f:
        names = [r["name"] for r in csv.DictReader(f)]
    rng = np.random.default_rng(2026)
    return list(rng.permutation(names)[:n])


SOURCE_TABLES = ["w4_44_final_roster", "w4_41_model_metrics", "w6_customer",
                 "w5_customer_360", "w6_purchase_day", "w5_line_net", "w6_monthly_kpi", "w6_conv_base", "w6_uplift",
                 "w6_mkt_regression",
                 # 2기 추가: 여정·코호트·LTV/CAC·매장 성격·실험 기준값
                 "w5_cohort_retention", "w6_ltv_margin", "clean_online", "w6_conv_segments",
                 "w4_41_valid_scored"]
OBS_END = pd.Timestamp("2019-12-31")   # 데이터 마지막 날
OBS_H = 180                             # 두 번째 구매 타이밍은 첫 구매 후 180일 이상 관측된 고객만 사용 (늦게 들어온 고객의 중도절단 방지)
TRIGGERS = (7, 30)                      # 2기 신규 온보딩 트리거: 첫 구매 후 D+7, D+30
Z_SUM = 2.8016                          # 양측 5% + 검정력 80% 의 z 합 (1.96 + 0.8416)
_LAST = {"stamp": None, "data": None}


def _stamp():
    """원천 테이블 수정 시각. 파이프라인이 다시 돌아 파일이 바뀌면 값이 달라진다 (없는 파일이 있으면 None = 아직 생성 중)"""
    from rcommon import CRM_DIR
    paths = [CRM_DIR / f"{t}.pkl" for t in SOURCE_TABLES]
    if not all(x.exists() for x in paths):
        return None
    return max(x.stat().st_mtime for x in paths)


def build():
    """crm_db 가 바뀌면 자동으로 다시 계산 (서버 재시작 불필요).
    파이프라인 실행 도중(테이블 삭제·재생성 중)이거나 새 데이터를 읽다 실패하면 직전 정상 결과를 계속 보여 준다."""
    stamp = _stamp()
    if _LAST["data"] is not None and (stamp is None or stamp == _LAST["stamp"]
                                       or _time.time() - stamp < 20):     # 마지막 쓰기 후 20초 동안은 파이프라인 진행 중으로 본다
        return _LAST["data"]
    if _LAST["data"] is not None and stamp == _LAST.get("failed"):
        return _LAST["data"]           # 같은 상태로 이미 실패했으면 다시 시도하지 않음 (요청마다 느려지는 것 방지)
    try:
        data = _build()
    except Exception:
        _LAST["failed"] = stamp
        if _LAST["data"] is not None:
            return _LAST["data"]
        raise
    _LAST.update(stamp=stamp, data=data)
    return data


def _build():
    roster = load("w4_44_final_roster")
    cu6 = load("w6_customer")
    c360 = load("w5_customer_360")
    pdays = load("w6_purchase_day")
    lines = load("w5_line_net")
    k6 = load("w6_monthly_kpi")
    cb6 = load("w6_conv_base")
    up6 = load("w6_uplift")
    reg6 = load("w6_mkt_regression")

    df = (roster[["customer_id", "rfmp_tier", "tier_code", "rfmp_score", "rfmp_value_percentile", "value_priority_rank",
                  "relative_risk_grade", "relative_risk_percentile", "risk_priority_rank", "value_risk_priority_rank",
                  "customer_maturity_group", "top_category", "action_rule_id", "action_code", "action_name",
                  "action_channel", "incentive_level", "action_reason", "flag_value_top100", "flag_risk_top100",
                  "queue_membership"]]
          .merge(cu6[["customer_id", "purchase_days", "first_day", "last_day", "revenue_ex_gst", "orders"]], on="customer_id")
          .merge(c360[["customer_id", "recency", "gender", "region", "tenure"]], on="customer_id"))
    df = df.sort_values("customer_id", ignore_index=True)
    df.insert(1, "name", _names(len(df)))

    # 매출 기여 순위
    df["revenue_rank"] = df["revenue_ex_gst"].rank(ascending=False, method="first").astype(int)
    df["revenue_top_pct"] = df["revenue_rank"] / len(df)
    df["revenue_share"] = df["revenue_ex_gst"] / df["revenue_ex_gst"].sum()

    # 구매 주기: 서로 다른 구매일 간 평균 간격 vs 마지막 구매 후 경과일
    gaps = pdays.sort_values(["customer_id", "purchase_date"]).groupby("customer_id")["purchase_date"].diff().dt.days
    df["avg_gap_days"] = df["customer_id"].map(gaps.groupby(pdays["customer_id"]).mean())
    # 구매 주기 경보: 평소 재방문 간격의 3배 이상 오지 않음 (구매일 3일 이상 고객만)
    df["cycle_ratio"] = df["recency"] / df["avg_gap_days"]
    df["cycle_alert"] = ((df["purchase_days"] >= 3) & (df["cycle_ratio"] >= 3)).astype(int)
    # 모형 순위(Low/Medium)와 구매 주기 신호가 어긋나는 고객 -> 담당자 확인 대상
    df["signal_conflict"] = ((df["cycle_alert"] == 1) & (df["relative_risk_grade"] != "High")).astype(int)

    rv = reg6.set_index(["target", "spec", "term"])
    summary = {
        "customers": len(df),
        "revenue_ex_gst": float(df["revenue_ex_gst"].sum()),
        "net_revenue": float(k6["net"].sum()),
        "purchase_days": int(k6["purchase_days"].sum()),
        "marketing": float(k6["marketing_cost"].sum()),
        "conv90": float(cb6["converted_90d"].mean()),
        "conv_n": len(cb6),
        "vip_dia_share": float(df.loc[df["rfmp_tier"].isin(["VIP", "Diamond"]), "revenue_ex_gst"].sum() / df["revenue_ex_gst"].sum()),
        "high_n": int((df["relative_risk_grade"] == "High").sum()),
        "high_rev": float(df.loc[df["relative_risk_grade"] == "High", "revenue_ex_gst"].sum()),
        "value_top100": int(df["flag_value_top100"].sum()),
        "risk_top100": int(df["flag_risk_top100"].sum()),
        "overlap100": int(((df["flag_value_top100"] == 1) & (df["flag_risk_top100"] == 1)).sum()),
        "auc_new": float(load("w4_41_model_metrics").set_index("evaluation_scope").loc["VALID_NEW", "roc_auc"]),
        "guard_n": int((df["rfmp_tier"].isin(GUARD_TIERS) & (df["relative_risk_grade"] == "High")).sum()),
        "new_n": int((df["customer_maturity_group"] == "NEW_LT90").sum()),
        "est_n": int((df["customer_maturity_group"] != "NEW_LT90").sum()),
        "p_new": float(rv.loc[("new_customers", "요일·추세 통제", "spend_same_day"), "p_value"]),
        "mroas": float(rv.loc[("revenue", "요일·추세 통제", "spend_same_day"), "coef_per_1000"] / 1000),
        "avg_roas": float(k6["revenue_ex_gst"].sum() / k6["marketing_cost"].sum()),
        "value_per_convert": float(up6["value_per_convert_90d"].iloc[0]),
        "annual_new": int(up6["annual_new_customers"].iloc[0]),
        # 1년 시범(월 유입의 절반씩 두 집단)에서 우연과 구분되는 최소 전환율 상승폭 (양측 5%, 검정력 80%)
        "mde12": float(2.8016 * np.sqrt(2 * cb6["converted_90d"].mean() * (1 - cb6["converted_90d"].mean())
                                        / (up6["annual_new_customers"].iloc[0] / 2))),
        "blended_cac": float(k6["marketing_cost"].sum() / k6["new"].sum()),
        "arpu": float(df["revenue_ex_gst"].sum() / len(df)),
        "conflict_n": int(df["signal_conflict"].sum()),
        "conflict_rev": float(df.loc[df["signal_conflict"] == 1, "revenue_ex_gst"].sum()),
    }
    mx_n = df.pivot_table(index="rfmp_tier", columns="relative_risk_grade", values="customer_id", aggfunc="count",
                          fill_value=0).reindex(index=TIERS, columns=RISKS, fill_value=0)
    mx_r = df.pivot_table(index="rfmp_tier", columns="relative_risk_grade", values="revenue_ex_gst", aggfunc="sum",
                          fill_value=0).reindex(index=TIERS, columns=RISKS, fill_value=0)
    matrix = [{"tier": t, "cells": [{"risk": r, "n": int(mx_n.loc[t, r]), "rev": float(mx_r.loc[t, r])} for r in RISKS]}
              for t in TIERS]
    rules = (df.groupby(["action_rule_id", "action_code", "action_name", "action_channel", "incentive_level"])
             .agg(n=("customer_id", "size"), rev=("revenue_ex_gst", "sum")).reset_index()
             .sort_values("action_rule_id").to_dict("records"))
    summary["top20_share"] = float(df["revenue_ex_gst"].nlargest(int(len(df) * 0.2)).sum() / df["revenue_ex_gst"].sum())
    summary["one_time"] = float((df["purchase_days"] == 1).mean())
    _g = df["rfmp_tier"].isin(GUARD_TIERS) & (df["relative_risk_grade"] == "High")
    summary["guard_new"] = int((_g & (df["customer_maturity_group"] == "NEW_LT90")).sum())   # 규칙 1(신규 보호)이 먼저 적용된 고객
    summary["guard_rev"] = float(df.loc[_g, "revenue_ex_gst"].sum())
    summary["guard_one"] = float((df.loc[_g, "purchase_days"] == 1).mean())         # 고가치 위험 고객: 한 번만 산 비율
    summary["guard_recency"] = float(df.loc[_g, "recency"].median())
    # 2기: 고객별 여정 단계와 다음 트리거 (Customer 360 표시용)
    df["journey_stage"] = np.select([df["purchase_days"] == 1, df["purchase_days"] == 2],
                                    ["1회 구매 · 두 번째 구매 대기", "2회 구매 · 정착 중"], "3회 이상 · 반복 구매")

    journey = _journey(pdays, load("w5_cohort_retention"))
    unit = _unit_econ(load("w6_ltv_margin"))
    experiments = _experiments(df, summary)
    store = _store(lines, pdays, k6)
    df["bulk"] = df["customer_id"].isin(store.pop("bulk_ids")).astype(int)
    df[["campaign", "campaign_stage", "next_send"]] = df.apply(_campaign, axis=1, result_type="expand")
    summary["guard_bulk"] = float(df.loc[_g, "bulk"].mean())
    _w = df["action_rule_id"].isin([2, 3])                                             # 고가치 고객 윈백 캠페인 대상 = 고가치 위험 고객 중 신규 제외
    summary["wb_one"] = float((df.loc[_w, "purchase_days"] == 1).mean())
    summary["wb_bulk"] = float(df.loc[_w, "bulk"].mean())
    summary.update(m1_ret=journey["m1"], m3_ret=journey["m3"], ltv_cac_m5=unit["m5_profit"],
                   ltv_cac_jan=unit["jan_profit"], ltv_cac_jan_rev=unit["jan_rev"], m0_share=unit["jan_m0_share"],
                   payback=unit["payback"], d30_unconv=journey["unconv"][TRIGGERS[1]],
                   lines=len(lines), coupon_clicked=int((lines["coupon_status"] == "Clicked").sum()))
    seg = load("w6_conv_segments")
    entry = seg[seg["dimension"] == seg["dimension"].unique()[3]].set_index("level")["conversion"]   # 첫 구매 대표 카테고리
    summary.update(entry_best=float(entry["Nest-USA"]), entry_apparel=float(entry["Apparel"]))
    # Vanity vs Actionable: 월 매출(크기만 보여 줌) vs 첫 구매 카테고리별 90일 두 번째 구매율(무엇을 권할지 알려 줌)
    # 첫 구매 '월'별 비교는 쓰지 않는다: 자주 사는 단골의 2019년 첫 구매가 연초에 몰려 연초 코호트가 높게 나오는 착시
    ent = seg[(seg["dimension"] == seg["dimension"].unique()[3]) & (seg["customers"] >= 30)]          # 표본 30명 이상 카테고리
    ent = ent.sort_values("conversion", ascending=False)
    vanity = {"labels": [f"{m.month}월" for m in k6["month"]],
              "rev": (k6["revenue_ex_gst"] / 1e3).round(0).tolist(),
              "conv": [{"m": r.level, "rate": round(float(r.conversion), 4), "n": int(r.customers),
                        "ci": round(float(r.ci_half), 4)} for r in ent.itertuples()]}
    top = int(np.argmax(vanity["rev"]))                       # 월 매출이 가장 높았던 달
    vanity.update(rev_top_m=vanity["labels"][top], rev_top=vanity["rev"][top])
    # 마케팅비의 효율 (마진 가정 없음): 평균 하루 마케팅비만큼 더 쓴 날 늘어난 매출 · 첫 구매 (요일·추세 통제 회귀)
    spend_day = float(k6["marketing_cost"].sum() / 365)
    rr = rv.loc[("revenue", "요일·추세 통제", "spend_same_day")]
    summary.update(mkt_ratio=float(k6["marketing_cost"].sum() / k6["revenue_ex_gst"].sum()), spend_day=spend_day,
                   rev_per_day=float(rr["coef_per_1000"] / 1000 * spend_day),
                   rev_per_day_ci=float(1.96 * rr["se"] / 1000 * spend_day))
    return {"df": df, "summary": summary, "matrix": matrix, "rules": rules,
            "journey": journey, "unit": unit, "experiments": experiments, "store": store, "vanity": vanity}


BULK_QTY = 100     # 하루 수량 합이 이 이상이면 단체·대량 주문으로 본다 (상위 약 15% 구매일)


def _store(lines, pdays, k6):
    """매장 성격 (실행 플랜 화면): 무엇을 파는 곳이고, 누가 사고, 언제 몰리며, 할인이 통하는가"""
    clean = load("clean_online")
    first = pdays.groupby("customer_id")["purchase_date"].min()
    f = lines[lines["transaction_date"] == lines["customer_id"].map(first)]
    nest_rev = lines.loc[lines["product_category"].str.startswith("Nest"), "net_amount"].sum() / lines["net_amount"].sum()
    day_qty = clean.groupby(["customer_id", "transaction_date"])["quantity"].sum()
    bulk = day_qty[day_qty >= BULK_QTY].index.get_level_values(0).unique()
    m = k6.set_index(k6["month"].dt.month)["revenue_ex_gst"]
    big = lines.groupby("product_category").filter(lambda g: len(g) >= 1000)
    used = big.groupby("product_category")["coupon_status"].apply(lambda x: (x == "Used").mean())
    basket = lines.groupby("coupon_status")["gross_amount"].mean()      # 할인 전 금액으로 비교 (할인 후면 쿠폰 쪽이 당연히 낮음)
    return {"bulk_ids": set(bulk), "nest_rev": float(nest_rev), "nest_first": float(f.loc[f["product_category"].str.startswith("Nest"), "customer_id"].nunique() / len(first)),
            "bulk_n": int(len(bulk)), "bulk_share": float(len(bulk) / len(first)),
            "bulk_rev": float(lines.loc[lines["customer_id"].isin(bulk), "net_amount"].sum() / lines["net_amount"].sum()),
            "q4_lift": float(m[[11, 12]].mean() / m[range(1, 11)].mean() - 1),
            "used_min": float(used.min()), "used_max": float(used.max()),
            "basket_used": float(basket["Used"]), "basket_not": float(basket["Not Used"])}


CAMPAIGN = {1: ("신규 온보딩", "Activation"), 2: ("고가치 고객 윈백", "Revenue"), 3: ("고가치 고객 윈백", "Revenue"),
            4: ("자동 재방문 알림", "Retention"), 5: ("자동 재방문 알림", "Retention"), 6: ("자동 재방문 알림", "Retention"),
            7: ("관계 유지", "유지")}


def _campaign(r):
    """고객이 받을 캠페인과 다음 발송 시점 (데이터 마지막 날 2019-12-31 기준, 실행 플랜 화면과 같은 규칙)"""
    name, stage = CAMPAIGN[r["action_rule_id"]]
    t1, t2 = TRIGGERS
    if r["action_rule_id"] == 1:                                   # 온보딩: 첫 구매일 기준 D+7, D+30
        since = r["recency"] + (r["last_day"] - r["first_day"]).days      # 첫 구매 후 경과일 (recency 와 같은 기준일)
        nxt = (f"D+{t1} · {t1 - since}일 후" if since < t1 else f"D+{t2} · {t2 - since}일 후" if since < t2
               else f"D+{t2} 발송 완료 · 이후 자동 재방문 알림으로")
    elif r["action_rule_id"] == 2:
        nxt = "지금 · 담당자 연락"
    elif r["action_rule_id"] == 3:
        nxt = "지금 · 담당자 이름의 이메일"
    elif r["action_rule_id"] in (4, 5, 6):                         # 평소 구매 간격의 1.5배가 지나면
        gap = r["avg_gap_days"]
        if pd.isna(gap) or r["purchase_days"] < 3:                 # 구매 주기는 간격이 2번 이상일 때만 의미 (Customer 360 과 같은 기준)
            nxt = f"지금 · 마지막 구매 후 {r['recency']}일째"
        else:
            left = int(round(1.5 * gap - r["recency"]))
            nxt = f"지금 · 평소 간격 {gap:.0f}일의 1.5배 지남" if left <= 0 else f"{left}일 후 · 평소 간격 {gap:.0f}일의 1.5배"
    else:
        nxt = "다음 달 뉴스레터"
    return name, stage, nxt


def _journey(pdays, ret):
    """여정·퍼널 화면: 두 번째 구매 타이밍, 구매 단계별 전환, 월별 코호트 리텐션"""
    p = pdays.sort_values(["customer_id", "purchase_date"]).copy()
    p["k"] = p.groupby("customer_id").cumcount() + 1
    first = p.loc[p["k"] == 1].set_index("customer_id")["purchase_date"]
    p["d"] = (p["purchase_date"] - p["customer_id"].map(first)).dt.days
    obs = (OBS_END - first).dt.days                                   # 고객별 관측 가능 일수
    sec = p.loc[p["k"] == 2].set_index("customer_id")["d"].reindex(first.index)   # 두 번째 구매까지 일수 (없으면 NaN)
    elig = obs >= OBS_H
    s = sec[elig]
    curve = [round(float((s <= d).mean()), 4) for d in range(OBS_H + 1)]       # 누적 2회 구매 전환율
    weekly = []                                                       # 주별 재구매 확률 (그 주 시작까지 안 온 고객 중)
    for w in range(17):
        d = 7 * w
        at = (obs >= d + 7) & ~(sec <= d)
        weekly.append(round(float(((sec > d) & (sec <= d + 7))[at].mean()), 4))
    unconv = {d: round(float(1 - (s <= d).mean()), 4) for d in (1, 7, 30, 60, 90)}
    next30 = {}
    for d in (7, 30, 60, 90):                                          # D일까지 안 온 고객이 이후 30일 안에 올 확률
        at = (obs >= d + 30) & ~(sec <= d)
        next30[d] = round(float(((sec > d) & (sec <= d + 30))[at].mean()), 4)
    within = p.loc[p["d"] <= OBS_H].groupby("customer_id").size().reindex(first.index)[elig]
    steps = [int((within >= k).sum()) for k in range(1, 6)]
    # 다음 날(D+1) 이어서 산 고객 vs 시간을 두고 다시 온 고객: 이후 행동 비교
    third = p.loc[p["k"] == 3].set_index("customer_id")["d"].reindex(first.index)
    d1 = elig & (sec <= 1)
    late = elig & (sec > 1) & (sec <= OBS_H)
    back = set(p.loc[(p["d"] > 7) & (p["d"] <= OBS_H), "customer_id"])
    d1_return = float(np.mean([i in back for i in d1[d1].index]))
    third90 = lambda m: float(((third - sec)[m] <= 90).mean())

    ret = ret.copy()
    ret["m"] = pd.to_datetime(ret["cohort_month"]).dt.month
    ret = ret[ret["m"] + ret["age"] <= 12]                             # 관측 가능한 칸만 (12월 이후는 데이터 없음)
    size = ret.groupby("m")["cohort_size"].first()
    grid = ret.pivot(index="m", columns="age", values="retention_rate")
    cohorts = [{"label": f"{m}월", "size": int(size[m]),
                "cells": [None if pd.isna(grid.loc[m].get(a)) else round(float(grid.loc[m, a]), 4) for a in range(12)]}
               for m in grid.index]
    wavg = lambda a: float(np.average(grid[a].dropna(), weights=size[grid[a].dropna().index]))
    return {"n": int(elig.sum()), "curve": curve, "weekly": weekly, "unconv": unconv, "next30": next30,
            "d1": round(float((s <= 1).mean()), 4), "c30": curve[30], "c90": curve[90], "c180": curve[OBS_H],
            "steps": steps, "d1_return": d1_return, "d1_third": third90(d1), "late_third": third90(late), "step_rate": [None] + [steps[i] / steps[i - 1] for i in range(1, 5)],
            "cohorts": cohorts, "m1": wavg(1), "m3": wavg(3)}


def _unit_econ(ltv):
    """LTV/CAC: 매출 기준(vanity) vs 이익 기준(actionable), 마진은 기본 가정값"""
    t = ltv[np.isclose(ltv["margin"], DEFAULT_MARGIN)].copy()
    t["month"] = pd.to_datetime(t["cohort_month"]).dt.month
    t["rev_ltv_cac"] = t["ltv_revenue_ex_gst"] / t["blended_cac"]
    rows = []
    for m, g in t.groupby("month"):
        g = g.drop_duplicates("age").set_index("age")      # 관찰 끝이 M5·M2 와 같은 달이면 같은 행이 두 번 있음
        end = g.index.max()
        cross = [a for a in sorted(g.index) if g.loc[a, "profit_ltv_cac"] >= 1]
        rows.append({"label": f"{m}월", "size": int(g["cohort_size"].iloc[0]), "cac": float(g["blended_cac"].iloc[0]),
                     "m0": float(g.loc[0, "profit_ltv_cac"]),
                     "m5": float(g.loc[5, "profit_ltv_cac"]) if 5 in g.index else None,
                     "end": float(g.loc[end, "profit_ltv_cac"]), "end_age": int(end),
                     "end_rev": float(g.loc[end, "rev_ltv_cac"]), "payback": cross[0] if cross else None})
    m5 = [r for r in rows if r["m5"] is not None]
    jan = rows[0]
    jan_m0 = t[(t["month"] == 1) & (t["age"] == 0)]["ltv_profit"].iloc[0]
    jan_end = t[(t["month"] == 1) & (t["age"] == jan["end_age"])]["ltv_profit"].iloc[0]
    paid = [r["payback"] for r in rows if r["payback"] is not None]
    return {"rows": rows, "m5_profit": float(np.average([r["m5"] for r in m5], weights=[r["size"] for r in m5])),
            "jan_profit": jan["end"], "jan_rev": jan["end_rev"], "jan_age": jan["end_age"],
            "jan_m0_share": float(jan_m0 / jan_end), "payback": int(min(paid)) if paid else None,
            "paid_n": len(paid), "cohort_n": len(rows)}


def _mde(p, n_arm):
    return Z_SUM * np.sqrt(2 * p * (1 - p) / n_arm)


def _need(p, uplift):
    return int(np.ceil(Z_SUM ** 2 * 2 * p * (1 - p) / uplift ** 2))


def _experiments(df, S):
    """실행 규칙별 실험 설계 카드: 가설 · 사업 지표 · 가드레일 · 표본과 검출 가능 효과(MDE)"""
    # 기존 고객 기준값: 이탈 모형 검증 시점(10/2 점수 → 10/3~12/31 관측)의 같은 위험 등급 기존 고객 실제 재구매율.
    # 현재 명단(연말 점수)으로 4분기 재구매율을 재면 "최근 안 산 고객"을 골랐으니 0%에 가까운 순환 논리가 된다.
    v = load("w4_41_valid_scored")
    v = v[v["customer_maturity_group"] != "NEW_LT90"].copy()
    v["grade"] = np.select([v["relative_risk_percentile"] >= 2 / 3, v["relative_risk_percentile"] >= 1 / 3], ["High", "Medium"], "Low")
    rep = 1 - v.groupby("grade")["actual_churn_flag"].mean()
    vn = v["grade"].value_counts()

    def base(g):
        mix = g["relative_risk_grade"].value_counts(normalize=True)
        return float(sum(mix[k] * rep[k] for k in mix.index)), int(sum(vn[k] for k in mix.index))

    progs = [
        {"key": "onboard", "name": "신규 온보딩", "stage": "Activation", "rules": [1], "color": "var(--mint)",
         "hyp": f"첫 구매 후 D+{TRIGGERS[0]}·D+{TRIGGERS[1]} 추천 알림을 받으면 90일 안에 두 번째로 구매하는 비율이 오른다",
         "metric": "90일 두 번째 구매율", "guard": "수신 거부율 · 할인 비용 · 첫 구매 객단가",
         "channel": "앱 푸시·이메일 (국내 적용 시 친구톡: 광고성, 수신 동의 고객)", "timing": f"D+{TRIGGERS[0]}, D+{TRIGGERS[1]}"},
        {"key": "guard", "name": "고가치 고객 윈백", "stage": "Revenue", "rules": [2, 3], "color": "var(--guard)",
         "hyp": "처음에 크게 사고 오래 돌아오지 않은 고객에게 담당자가 재주문·전담 상담을 제안하면 90일 재구매율이 오른다",
         "metric": "90일 재구매율 · 재구매 매출", "guard": "혜택 비용 대비 이익 · 연락 거부",
         "channel": "담당자 연락 + 이메일 (국내 적용 시 주문 안내는 알림톡: 정보성)", "timing": "위험 등급 변경 즉시"},
        {"key": "auto", "name": "자동 재방문 알림", "stage": "Retention", "rules": [4, 5, 6], "color": "var(--accent)",
         "hyp": "대표 카테고리 신상품·인기 상품 자동 알림이 90일 재구매율을 높인다",
         "metric": "90일 재구매율", "guard": "수신 거부율 · 앱 삭제",
         "channel": "앱 푸시·이메일 자동 발송 (국내 적용 시 앱 푸시·친구톡)", "timing": "평소 구매 주기 1.5배 경과 시"},
    ]
    for pr in progs:
        g = df[df["action_rule_id"].isin(pr["rules"])]
        pr["n"] = int(len(g))
        if pr["key"] == "onboard":                          # 신규는 유입 흐름: 1년 유입을 반반 나눔
            pr["base"], pr["base_note"] = S["conv90"], f"2019년 첫 구매 고객 {S['conv_n']:,}명의 90일 전환율"
            pr["n_arm"], pr["n_note"] = S["annual_new"] // 2, "1년 유입의 절반씩"
        else:
            b, bn = base(g)
            grades = "·".join(sorted(g["relative_risk_grade"].unique(), key=RISKS.index))
            pr["base"], pr["base_note"] = b, f"10/2 기준 {grades} 위험 기존 고객 {bn}명이 이후 90일에 재구매한 비율"
            pr["n_arm"], pr["n_note"] = pr["n"] // 2, "현재 대상의 절반씩"
        pr["mde"] = float(_mde(pr["base"], pr["n_arm"]))
        pr["need5"] = _need(pr["base"], 0.05)
    return progs
