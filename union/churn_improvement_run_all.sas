/*=============================================================
  churn_improvement_run_all.sas  [단일 파일 - 한 번 실행으로 끝]

  이 파일 하나만 실행하면:
  1) 분석 스크립트를 디스크에 씀
  2) 끝날 때까지 그 자리에서 기다림 (백그라운드 X, 상태체크 파일 X)
  3) 끝나자마자 로그 전체 + 결과표를 SAS 로그/출력창에 바로 보여줌

  데이터 규모(1211명, 3윈도우x2피처셋=6조합)면 정상적으로는 1~2분 안에
  끝나야 하므로, 최대 10분(timeout=600초) 기다리고 그래도 안 끝나면
  강제 종료 + 그때까지의 로그를 보여줌.

  전제조건: proj.sales_with_disc, proj.customer_segments 존재
============================================================= */

libname proj "/home/student/open";

/* -------------------------------------------------------------
   1. 분석 스크립트를 디스크에 씀
------------------------------------------------------------- */
data _null_;
    infile datalines4 truncover;
    file "/home/student/open/churn_improvement.py";
    input;
    put _infile_;
datalines4;
import sys
import site

_user_site = site.getusersitepackages()
if _user_site not in sys.path:
    sys.path.insert(0, _user_site)

import pandas as pd
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.font_manager as fm
from xgboost import XGBClassifier
from sklearn.model_selection import StratifiedKFold
from sklearn.metrics import roc_auc_score

for _fname in ["NanumGothic", "Malgun Gothic", "AppleGothic", "DejaVu Sans"]:
    if any(_fname.lower() in f.name.lower() for f in fm.fontManager.ttflist):
        plt.rcParams["font.family"] = _fname
        break
plt.rcParams["axes.unicode_minus"] = False

print("numpy 버전:", np.__version__, flush=True)
print("pandas 버전:", pd.__version__, flush=True)

# -------------------------------------------------------------
# 1. 원본 정제 거래데이터 + 고객 인구통계 로드
# -------------------------------------------------------------
sales = pd.read_sas("/home/student/open/sales_with_disc.sas7bdat", encoding="utf-8")
seg = pd.read_sas("/home/student/open/customer_segments.sas7bdat", encoding="utf-8")

# bytes 컬럼 디코딩 (SAS 문자열이 bytes로 들어오는 경우 처리)
def decode_col(df, col):
    if df[col].dtype == object and len(df) > 0 and isinstance(df[col].dropna().iloc[0], bytes):
        df[col] = df[col].str.decode("utf-8").str.strip()
    return df

for c in ["고객ID", "쿠폰상태", "제품카테고리"]:
    if c in sales.columns:
        sales = decode_col(sales, c)
for c in ["고객ID", "성별", "고객지역"]:
    if c in seg.columns:
        seg = decode_col(seg, c)

# [수정] read_sas가 SAS 날짜 포맷 컬럼을 환경에 따라 이미 datetime64로
# 변환해서 주는 경우도 있고, 순수 숫자(1960-01-01 기준 일수)로 주는 경우도
# 있어서 두 경우를 모두 처리하도록 분기 처리
if not pd.api.types.is_datetime64_any_dtype(sales["거래날짜_num"]):
    sales["거래날짜_num"] = pd.to_datetime(sales["거래날짜_num"], unit="D", origin="1960-01-01")
cutoff = pd.Timestamp("2019-10-02")
print(f"cutoff = {cutoff.date()}", flush=True)

feat_period = sales[sales["거래날짜_num"] <= cutoff].copy()
label_pool = sales[sales["거래날짜_num"] > cutoff].copy()

# 주문(거래ID) 단위 압축 - 배송료/금액 중복 방지
order_dedup = feat_period.drop_duplicates(subset=["고객ID", "거래ID", "거래날짜_num"])[
    ["고객ID", "거래ID", "거래날짜_num", "배송료"]
].drop_duplicates()
order_total = feat_period.groupby(["고객ID", "거래ID"], as_index=False).agg(
    주문총액=("거래금액", "sum")
)

# -------------------------------------------------------------
# 2. 기본 RFM류 피처 (기존과 동일)
# -------------------------------------------------------------
base_rfm = feat_period.groupby("고객ID").agg(
    Recency=("거래날짜_num", lambda s: (cutoff - s.max()).days),
    Frequency=("거래ID", "nunique"),
).reset_index()

monetary = order_total.groupby("고객ID", as_index=False).agg(
    Monetary=("주문총액", "sum"), AvgOrderValue=("주문총액", "mean")
)
shipping = order_dedup.groupby("고객ID", as_index=False).agg(AvgShipping=("배송료", "mean"))
coupon = feat_period.groupby("고객ID").apply(
    lambda g: pd.Series({
        "CouponUseRate": (g["쿠폰상태"] == "Used").mean(),
        "CouponClickRate": g["쿠폰상태"].isin(["Used", "Clicked"]).mean(),
    })
).reset_index()

features = base_rfm.merge(monetary, on="고객ID").merge(shipping, on="고객ID").merge(coupon, on="고객ID")

# -------------------------------------------------------------
# 3. [신규] 트렌드 피처 - cutoff 직전 30일(최근) vs 그 이전(과거) 비교
# -------------------------------------------------------------
recent_start = cutoff - pd.Timedelta(days=30)
recent = feat_period[feat_period["거래날짜_num"] > recent_start]
prior = feat_period[feat_period["거래날짜_num"] <= recent_start]

recent_agg = recent.groupby("고객ID").agg(recent_freq=("거래ID", "nunique"),
                                           recent_amt=("거래금액", "sum")).reset_index()
prior_agg = prior.groupby("고객ID").agg(prior_freq=("거래ID", "nunique"),
                                         prior_amt=("거래금액", "sum")).reset_index()

trend = features[["고객ID"]].merge(recent_agg, on="고객ID", how="left").merge(prior_agg, on="고객ID", how="left")
trend[["recent_freq", "recent_amt", "prior_freq", "prior_amt"]] = trend[
    ["recent_freq", "recent_amt", "prior_freq", "prior_amt"]
].fillna(0)
# prior 기간(수 개월) 대비 recent 기간(30일)은 절대량이 작으므로, "비율"보다
# "최근 30일 동안의 활동이 있었는지 + 그 활동량"을 그대로 피처로 사용
trend["recent_freq"] = trend["recent_freq"]
trend["recent_amt"] = trend["recent_amt"]
# prior 기간을 30일 단위로 정규화해서 recent와 같은 스케일로 비교 가능하게 함
prior_days = (recent_start - feat_period["거래날짜_num"].min()).days
prior_days = max(prior_days, 1)
trend["prior_freq_per30d"] = trend["prior_freq"] / (prior_days / 30.0)
trend["freq_trend_ratio"] = (trend["recent_freq"] + 0.5) / (trend["prior_freq_per30d"] + 0.5)

features = features.merge(
    trend[["고객ID", "recent_freq", "recent_amt", "freq_trend_ratio"]], on="고객ID"
)

# -------------------------------------------------------------
# 4. 인구통계 병합
# -------------------------------------------------------------
demo = seg[["고객ID", "성별", "고객지역", "가입기간"]].drop_duplicates(subset=["고객ID"])
features = features.merge(demo, on="고객ID", how="left")
features = pd.get_dummies(features, columns=["성별", "고객지역"], drop_first=True)

# [수정] 원래 줄 끝 백슬래시(\) 연속 방식이 SAS datalines4를 거치면서
# 뒤에 눈에 안 보이는 공백이 붙어 "SyntaxError: unexpected character after
# line continuation character"를 일으켰음. 백슬래시 대신 괄호로 묶는 방식은
# 줄 끝에 공백이 남아도 문법 오류가 나지 않으므로 이 방식이 훨씬 안전함.
feature_cols_base = (
    ["Recency", "Frequency", "Monetary", "AvgOrderValue", "AvgShipping",
     "CouponUseRate", "CouponClickRate", "가입기간"]
    + [c for c in features.columns if c.startswith("성별_") or c.startswith("고객지역_")]
)
feature_cols_trend = feature_cols_base + ["recent_freq", "recent_amt", "freq_trend_ratio"]

print(f"기본 피처 {len(feature_cols_base)}개, 트렌드 포함 피처 {len(feature_cols_trend)}개", flush=True)
print(f"cutoff 이전 거래 고객수: {len(features)}", flush=True)

# -------------------------------------------------------------
# 5. 라벨 윈도우 30/60/90일 각각 생성 + 5-fold CV로 조합별 AUC 비교
# -------------------------------------------------------------
def make_label(window_days):
    label_end = cutoff + pd.Timedelta(days=window_days)
    active = set(label_pool[label_pool["거래날짜_num"] <= label_end]["고객ID"].unique())
    return features["고객ID"].apply(lambda x: 0 if x in active else 1)

results = []
cv = StratifiedKFold(n_splits=5, shuffle=True, random_state=2026)

for window in [30, 60, 90]:
    y = make_label(window)
    churn_rate = y.mean()
    print(f"\n===== 윈도우 {window}일 (이탈률 {churn_rate:.2%}) =====", flush=True)

    for feat_name, cols in [("기본", feature_cols_base), ("기본+트렌드", feature_cols_trend)]:
        X = features[cols].fillna(0)
        aucs = []
        n_pos = y.sum()
        n_neg = len(y) - n_pos
        spw = n_neg / n_pos if n_pos > 0 else 1.0

        for fold_i, (train_idx, valid_idx) in enumerate(cv.split(X, y), start=1):
            X_tr, X_va = X.iloc[train_idx], X.iloc[valid_idx]
            y_tr, y_va = y.iloc[train_idx], y.iloc[valid_idx]
            model = XGBClassifier(
                n_estimators=100, max_depth=4, learning_rate=0.1,
                random_state=2026, eval_metric="logloss",
                tree_method="hist",
                # [수정] n_jobs=-1은 컨테이너 환경(SAS Viya 컴퓨트 서버)에서
                # 실제 할당된 코어 수가 아니라 호스트 전체 코어 수를 읽어와
                # 과도한 스레드를 띄우다 서로 경합하며 사실상 멈춘 것처럼
                # 보이는 문제를 일으킬 수 있음. 작은 고정값으로 변경.
                n_jobs=2,
                scale_pos_weight=spw,
            )
            model.fit(X_tr, y_tr)
            preds = model.predict_proba(X_va)[:, 1]
            aucs.append(roc_auc_score(y_va, preds))
            print(f"    fold {fold_i}/5 완료 (AUC={aucs[-1]:.4f})", flush=True)

        mean_auc, std_auc = np.mean(aucs), np.std(aucs)
        print(f"  [{feat_name}] CV AUC = {mean_auc:.4f} ± {std_auc:.4f}  (scale_pos_weight={spw:.2f})", flush=True)
        results.append({
            "윈도우": window, "이탈률": churn_rate, "피처셋": feat_name,
            "CV_AUC_평균": mean_auc, "CV_AUC_표준편차": std_auc,
        })

results_df = pd.DataFrame(results)
results_df.to_csv("/home/student/open/churn_improvement_results.csv", index=False, encoding="utf-8-sig")
print("\n===== 전체 결과 =====", flush=True)
print(results_df.to_string(index=False), flush=True)

# -------------------------------------------------------------
# 6. 시각화 - 윈도우 x 피처셋 조합별 CV AUC (오차막대 포함)
# -------------------------------------------------------------
fig, ax = plt.subplots(figsize=(9, 5.5))
windows = [30, 60, 90]
width = 0.35
x = np.arange(len(windows))

base_means = [results_df[(results_df["윈도우"] == w) & (results_df["피처셋"] == "기본")]["CV_AUC_평균"].values[0] for w in windows]
base_stds = [results_df[(results_df["윈도우"] == w) & (results_df["피처셋"] == "기본")]["CV_AUC_표준편차"].values[0] for w in windows]
trend_means = [results_df[(results_df["윈도우"] == w) & (results_df["피처셋"] == "기본+트렌드")]["CV_AUC_평균"].values[0] for w in windows]
trend_stds = [results_df[(results_df["윈도우"] == w) & (results_df["피처셋"] == "기본+트렌드")]["CV_AUC_표준편차"].values[0] for w in windows]

ax.bar(x - width/2, base_means, width, yerr=base_stds, capsize=4, label="기본 피처", color="#4c72b0")
ax.bar(x + width/2, trend_means, width, yerr=trend_stds, capsize=4, label="기본+트렌드 피처", color="#2ca02c")
ax.set_xticks(x)
ax.set_xticklabels([f"{w}일" for w in windows])
ax.set_ylabel("5-fold CV AUC (평균 ± 표준편차)")
ax.set_xlabel("이탈 라벨 윈도우")
ax.set_title("이탈예측 개선 실험: 윈도우 x 피처셋 조합별 CV 성능")
ax.legend()
ax.axhline(0.5, color="gray", linestyle="--", linewidth=1, label="랜덤 기준선(0.5)")
plt.tight_layout()
plt.savefig("/home/student/open/plots/churn_improvement.png", dpi=130)
plt.close()

print("\nchurn_improvement.png 저장 완료", flush=True)

with open("/home/student/open/churn_improvement_DONE.flag", "w") as f:
    f.write("done")

;;;;
run;

/* -------------------------------------------------------------
   2. 끝날 때까지 기다렸다가 결과 보여주기 (한 스텝)
------------------------------------------------------------- */
proc python;
submit;
import subprocess
import sys
import os

script_path = "/home/student/open/churn_improvement.py"
done_flag = "/home/student/open/churn_improvement_DONE.flag"

if os.path.exists(done_flag):
    os.remove(done_flag)

print("실행 시작 - 끝날 때까지 이 자리에서 기다립니다 (최대 10분)...")

try:
    result = subprocess.run(
        [sys.executable, "-u", script_path],
        capture_output=True, text=True, timeout=600,
    )
    print("\n===== 실행 완료 (returncode:", result.returncode, ") =====\n")
    print(result.stdout)
    if result.returncode != 0:
        print("----- 에러 출력 -----")
        print(result.stderr)
except subprocess.TimeoutExpired as e:
    print("\n!!! 10분 초과 - 강제 종료함 !!!")
    if e.stdout:
        print(e.stdout.decode() if isinstance(e.stdout, bytes) else e.stdout)
    if e.stderr:
        print(e.stderr.decode() if isinstance(e.stderr, bytes) else e.stderr)
endsubmit;
run;

/* -------------------------------------------------------------
   3. 완료됐으면 결과표를 바로 SAS에서 표로 출력
------------------------------------------------------------- */
%macro show_results_if_done;
    %if %sysfunc(fileexist(/home/student/open/churn_improvement_DONE.flag)) %then %do;
        proc import datafile="/home/student/open/churn_improvement_results.csv"
            out=work.churn_improvement_results
            dbms=csv replace;
            guessingrows=20;
        run;

        proc print data=work.churn_improvement_results noobs;
            title "이탈예측 개선 실험 - 윈도우 x 피처셋 조합별 5-fold CV AUC";
        run;
        title;
    %end;
    %else %do;
        %put WARNING: DONE.flag가 없습니다 - 위 로그를 보고 어디서 실패/타임아웃됐는지 확인하세요.;
    %end;
%mend show_results_if_done;

%show_results_if_done;
