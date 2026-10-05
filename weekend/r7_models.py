"""r7. 이탈 예측 모델 비교 (SAS Model Studio 의 Model Comparison 노드 방식)

사용 모델(기준):  로지스틱 회귀  - r4-1 (4.1) 의 B_DAYS 기준모형 (기본 변수, 튜닝 없음 · 쿠폰 변수 제외)
비교 모델 3개:    의사결정나무 (SAS PROC HPSPLIT 대응)
                  랜덤 포레스트 (SAS PROC FOREST 대응)
                  그래디언트 부스팅 (SAS PROC GRADBOOST 대응)

비교 축
  1) 하이퍼파라미터: 튜닝 전(고정값) vs 튜닝 후 - TRAIN 안에서만 5겹 층화 교차검증(GridSearchCV, AUC)
     VALID 는 튜닝·선택에 쓰지 않고 마지막 평가에만 사용 (SAS Model Studio 의 Autotune 과 같은 원칙)
  2) 변수: 기본(r4-1 과 동일) vs 확장 (기준일 이전 거래만으로 새로 만든 변수 추가) - 개수는 아래 목록에서 계산

검증 항목: VALID ROC AUC, KS, ASE(Brier), 오분류율, 상위 10% 리프트, TRAIN-VALID 차이(과적합),
          기준 모델 대비 AUC 차이의 부트스트랩 95% 신뢰구간(1,000회)
챔피언: 튜닝 후 모델 중 'TRAIN 교차검증 AUC' 가 가장 높은 후보를 고르고(VALID 를 보고 고르지 않음),
        그 후보가 VALID 에서 기준 모델보다 유의하게(신뢰구간 하한 > 0) 나을 때만 교체. 아니면 기준 로지스틱 유지.

입력: crm.w3_freq_abc_input (r3-1), crm.clean_online (r1-1)
출력: crm.w7_model_fit / w7_model_roc / w7_model_lift / w7_model_importance / w7_model_auc_diff / w7_model_features
"""

import numpy as np
import pandas as pd
# 병렬은 스레드만 사용 (프로세스 병렬은 Windows·OneDrive 환경에서 작업자 프로세스가 죽는 문제가 있었음)
from sklearn.base import clone
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import GradientBoostingClassifier, RandomForestClassifier
from sklearn.impute import SimpleImputer
from sklearn.inspection import permutation_importance
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import brier_score_loss, roc_auc_score, roc_curve
from sklearn.model_selection import GridSearchCV, StratifiedKFold
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler
from sklearn.tree import DecisionTreeClassifier

from rcommon import LogSkewed, load, save

SEED = 20260710
BASE_NUM = ["recency", "monetary", "avg_order_value", "avg_shipping", "tenure", "product_category_count",
            "category_concentration", "avg_days_between_orders", "std_days_between_orders", "frequency_days"]  # r4-1 과 동일 (쿠폰 제외)
EXT_NUM = ["observation_days", "orders_per_purchase_day", "days_last30", "days_last90", "rev_last90_share",
           "recency_cycle_ratio", "one_timer", "lines_per_day", "nest_usa_share", "weekend_share", "avg_offered_discount"]
CAT = ["gender", "region"]
FS_BASE, FS_EXT = f"기본 {len(BASE_NUM) + len(CAT)}개", f"확장 {len(BASE_NUM) + len(EXT_NUM) + len(CAT)}개"
FEATURE_SETS = {FS_BASE: BASE_NUM, FS_EXT: BASE_NUM + EXT_NUM}
LABEL = {"recency": "최근 구매 경과일", "monetary": "구매 금액", "avg_order_value": "주문당 금액",
         "avg_shipping": "평균 배송료", "coupon_usage_rate": "쿠폰 사용률", "coupon_click_rate": "쿠폰 클릭률",
         "tenure": "가입기간", "product_category_count": "카테고리 수", "category_concentration": "카테고리 집중도",
         "avg_days_between_orders": "평균 구매 간격", "std_days_between_orders": "구매 간격 편차",
         "last_coupon_used": "최근 쿠폰 사용", "frequency_days": "구매일 수", "gender": "성별", "region": "지역",
         "observation_days": "첫 구매 후 경과일", "orders_per_purchase_day": "구매일당 주문 수",
         "days_last30": "최근 30일 구매일 수", "days_last90": "최근 90일 구매일 수",
         "rev_last90_share": "최근 90일 매출 비중", "recency_cycle_ratio": "경과일 ÷ 평소 간격",
         "one_timer": "1회 구매 여부", "lines_per_day": "구매일당 상품 수", "nest_usa_share": "Nest-USA 매출 비중",
         "weekend_share": "주말 구매 비중", "avg_offered_discount": "평균 제공 할인율"}

MODELS = {  # 이름: (SAS 대응, 튜닝 전 분류기, 튜닝 격자, 스케일링)
    "로지스틱 회귀": ("PROC LOGISTIC",
                LogisticRegression(C=1.0, solver="liblinear", max_iter=3000, random_state=SEED),
                {"clf__C": [0.01, 0.03, 0.1, 0.3, 1, 3, 10], "clf__l1_ratio": [0.0, 1.0]}, True),
    "의사결정나무": ("PROC HPSPLIT",
                DecisionTreeClassifier(max_depth=5, min_samples_leaf=30, random_state=SEED),
                {"clf__max_depth": [2, 3, 4, 5, 6, 8], "clf__min_samples_leaf": [10, 20, 40, 80]}, False),
    "랜덤 포레스트": ("PROC FOREST",
                RandomForestClassifier(n_estimators=300, max_depth=6, min_samples_leaf=20, random_state=SEED, n_jobs=-1),
                {"clf__max_depth": [3, 5, 7, None], "clf__min_samples_leaf": [5, 10, 20, 40],
                 "clf__max_features": ["sqrt", 0.5]}, False),
    "그래디언트 부스팅": ("PROC GRADBOOST",
                  GradientBoostingClassifier(n_estimators=150, learning_rate=0.05, max_depth=3, subsample=0.8,
                                             random_state=SEED),
                  {"clf__n_estimators": [50, 100, 200], "clf__learning_rate": [0.03, 0.1], "clf__max_depth": [2, 3],
                   "clf__min_samples_leaf": [20, 50], "clf__subsample": [0.8]}, False),
}
BASE_KEY = ("로지스틱 회귀", FS_BASE, "튜닝 전")      # r4-1 에서 실제로 쓴 모델


def extended_features(d, online):
    """각 스냅샷 기준일(snapshot_cutoff) 이전 거래만으로 새 변수 계산 - 미래 정보 누수 없음"""
    o = online[(online["quantity"] > 0)].copy()
    o["rev"] = o["quantity"] * o["avg_price"]
    out = []
    for cutoff, g in d.groupby("snapshot_cutoff"):
        t = o[o["transaction_date"] <= cutoff]
        t = t[t["customer_id"].isin(g["customer_id"])]
        day = t.groupby(["customer_id", "transaction_date"]).agg(rev=("rev", "sum"), lines=("rev", "size")).reset_index()
        age = (cutoff - day["transaction_date"]).dt.days
        f = pd.DataFrame({
            "days_last30": day[age < 30].groupby("customer_id").size(),
            "days_last90": day[age < 90].groupby("customer_id").size(),
            "rev_last90_share": day[age < 90].groupby("customer_id")["rev"].sum() / day.groupby("customer_id")["rev"].sum(),
            "lines_per_day": day.groupby("customer_id")["lines"].mean(),
            "weekend_share": (day["transaction_date"].dt.dayofweek >= 5).groupby(day["customer_id"]).mean(),
            "nest_usa_share": t[t["product_category"] == "Nest-USA"].groupby("customer_id")["rev"].sum()
            / t.groupby("customer_id")["rev"].sum(),
            "avg_offered_discount": t.groupby("customer_id")["offered_discount_pct"].mean(),
        })
        f["snapshot_cutoff"] = cutoff
        out.append(f.rename_axis("customer_id").reset_index())
    f = pd.concat(out, ignore_index=True)
    d = d.merge(f, on=["customer_id", "snapshot_cutoff"], how="left")
    for c in ["days_last30", "days_last90", "rev_last90_share", "nest_usa_share"]:
        d[c] = d[c].fillna(0)
    d["one_timer"] = (d["frequency_days"] <= 1).astype(int)
    d["recency_cycle_ratio"] = d["recency"] / d["avg_days_between_orders"].where(d["avg_days_between_orders"] > 0)
    return d


def pipe(clf, num, scale):
    steps = [("imp", SimpleImputer(strategy="median"))] + ([("sc", StandardScaler())] if scale else [])
    pre = ColumnTransformer([("num", Pipeline(steps), num),
                             ("cat", Pipeline([("imp", SimpleImputer(strategy="most_frequent")),
                                               ("oh", OneHotEncoder(handle_unknown="ignore"))]), CAT)])
    return Pipeline([("log", LogSkewed()), ("pre", pre), ("clf", clf)])   # r4-1 과 같은 log1p 변환


def ks(y, p):
    fpr, tpr, _ = roc_curve(y, p)
    return float(np.max(tpr - fpr))


def lift_at(y, p, q):
    k = max(1, int(round(len(y) * q)))
    return float(np.mean(y[np.argsort(-p, kind="stable")[:k]]) / np.mean(y))


def main():
    d = load("w3_freq_abc_input").copy()
    d = extended_features(d, load("clean_online"))
    allnum = BASE_NUM + EXT_NUM
    d[allnum] = d[allnum].apply(pd.to_numeric, errors="coerce").replace([np.inf, -np.inf], np.nan)
    for c in CAT:
        d[c] = d[c].fillna("UNKNOWN").astype(str)
    tr, va = d[d["split_role"].str.upper() == "TRAIN"], d[d["split_role"].str.upper() == "VALID"]
    yt, yv = tr["churn_flag"].to_numpy(int), va["churn_flag"].to_numpy(int)
    print(f"TRAIN {len(tr):,} (이탈 {yt.mean():.1%}) / VALID {len(va):,} (이탈 {yv.mean():.1%})")
    cv = StratifiedKFold(5, shuffle=True, random_state=SEED)

    fit, roc, lift, imp, prob, fitted = [], [], [], [], {}, {}
    for fs, num in FEATURE_SETS.items():
        Xt, Xv = tr[num + CAT], va[num + CAT]
        for name, (proc, clf, grid, scale) in MODELS.items():
            for tuned in ("튜닝 전", "튜닝 후"):
                base = pipe(clone(clf), num, scale)
                if tuned == "튜닝 후":
                    gs = GridSearchCV(base, grid, scoring="roc_auc", cv=cv, n_jobs=1).fit(Xt, yt)
                    m, cv_auc = gs.best_estimator_, gs.best_score_
                    params = ", ".join(f"{k.replace('clf__', '')}={v}" for k, v in gs.best_params_.items()).replace(
                        "l1_ratio=0.0", "penalty=L2").replace("l1_ratio=1.0", "penalty=L1")
                else:
                    from sklearn.model_selection import cross_val_score
                    cv_auc = cross_val_score(base, Xt, yt, scoring="roc_auc", cv=cv, n_jobs=1).mean()
                    m, params = base.fit(Xt, yt), "고정값"
                pt, pv = m.predict_proba(Xt)[:, 1], m.predict_proba(Xv)[:, 1]
                key = (name, fs, tuned)
                prob[key], fitted[key] = pv, (m, Xv)
                fit.append({"model": name, "feature_set": fs, "tuning": tuned, "sas_proc": proc, "params": params,
                            "n_features": len(num) + len(CAT), "cv_auc": cv_auc,
                            "train_auc": roc_auc_score(yt, pt), "valid_auc": roc_auc_score(yv, pv),
                            "valid_ks": ks(yv, pv), "valid_ase": brier_score_loss(yv, pv),
                            "valid_misclass": float(np.mean((pv >= 0.5) != yv)),
                            "lift_top10": lift_at(yv, pv, 0.1), "lift_top20": lift_at(yv, pv, 0.2)})
                fpr, tpr, _ = roc_curve(yv, pv)
                roc.append(pd.DataFrame({"model": name, "feature_set": fs, "tuning": tuned, "fpr": fpr, "tpr": tpr}))
                order = np.argsort(-pv, kind="stable")
                lift.append(pd.DataFrame({"model": name, "feature_set": fs, "tuning": tuned,
                                          "depth": np.arange(1, len(yv) + 1) / len(yv),
                                          "cum_lift": np.cumsum(yv[order]) / np.arange(1, len(yv) + 1) / yv.mean()}))
                r = fit[-1]
                print(f"  {fs} {name:<9} {tuned}  CV {r['cv_auc']:.3f}  TRAIN {r['train_auc']:.3f}  "
                      f"VALID {r['valid_auc']:.3f}  [{params}]")
    fit = pd.DataFrame(fit)
    fit["overfit_gap"] = fit["train_auc"] - fit["valid_auc"]

    # 기준 모델 대비 VALID AUC 차이 - 같은 부트스트랩 표본으로 두 모델을 함께 평가
    rng = np.random.default_rng(SEED)
    idx = [b for b in (rng.integers(0, len(yv), len(yv)) for _ in range(1000)) if yv[b].min() != yv[b].max()]
    base_auc = np.array([roc_auc_score(yv[b], prob[BASE_KEY][b]) for b in idx])
    diff = []
    for key, pv in prob.items():
        if key == BASE_KEY:
            continue
        ds = np.array([roc_auc_score(yv[b], pv[b]) for b in idx]) - base_auc
        diff.append({"model": key[0], "feature_set": key[1], "tuning": key[2], "auc_diff": float(ds.mean()),
                     "ci_low": float(np.percentile(ds, 2.5)), "ci_high": float(np.percentile(ds, 97.5)),
                     "p_better": float(np.mean(ds > 0))})
    diff = pd.DataFrame(diff)

    # 챔피언: 튜닝 후 모델 중 TRAIN CV AUC 최고 후보 -> VALID 에서 기준보다 유의하게 나으면 교체
    tuned = fit[fit["tuning"] == "튜닝 후"]
    cand = tuned.loc[tuned["cv_auc"].idxmax()]
    cd = diff[(diff["model"] == cand["model"]) & (diff["feature_set"] == cand["feature_set"]) & (diff["tuning"] == "튜닝 후")].iloc[0]
    champ = (cand["model"], cand["feature_set"], "튜닝 후") if cd["ci_low"] > 0 else BASE_KEY
    fit["candidate"] = ((fit["model"] == cand["model"]) & (fit["feature_set"] == cand["feature_set"])
                        & (fit["tuning"] == "튜닝 후")).astype(int)
    fit["champion"] = [int((m, f, t) == champ) for m, f, t in zip(fit["model"], fit["feature_set"], fit["tuning"])]
    fit["baseline"] = [int((m, f, t) == BASE_KEY) for m, f, t in zip(fit["model"], fit["feature_set"], fit["tuning"])]
    print(f"\nCV 최고 후보: {cand['model']} / {cand['feature_set']} (CV {cand['cv_auc']:.3f}, VALID {cand['valid_auc']:.3f}, "
          f"기준 대비 {cd['auc_diff']:+.3f} [{cd['ci_low']:+.3f}, {cd['ci_high']:+.3f}])")
    print("챔피언:", champ)

    # 변수 중요도: 튜닝 후 + 확장 변수 모델 4개 (순열 중요도, VALID AUC 감소량)
    for name in MODELS:
        m, Xv = fitted[(name, FS_EXT, "튜닝 후")]
        pi = permutation_importance(m, Xv, yv, scoring="roc_auc", n_repeats=15, random_state=SEED, n_jobs=1)
        imp.append(pd.DataFrame({"model": name, "feature": list(Xv.columns), "label": [LABEL[c] for c in Xv.columns],
                                 "importance": pi.importances_mean, "is_new": [c in EXT_NUM for c in Xv.columns]}))

    save(fit, "w7_model_fit")
    save(pd.concat(roc, ignore_index=True), "w7_model_roc")
    save(pd.concat(lift, ignore_index=True), "w7_model_lift")
    save(pd.concat(imp, ignore_index=True), "w7_model_importance")
    save(diff, "w7_model_auc_diff")
    save(pd.DataFrame({"feature": EXT_NUM, "label": [LABEL[c] for c in EXT_NUM]}), "w7_model_features")


if __name__ == "__main__":
    main()
