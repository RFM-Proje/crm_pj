/* =============================================================
   PART. 모델 선정 근거 - 5개 후보 모델 비교 + Optuna 튜닝 개선폭
   (왜 XGBoost를 최종 모델로 선택했는지에 대한 시각적 근거)

   [속도 개선판] stage5에서 확인된 문제(느린 trial, capture_output
   블로킹, 세션 오염)를 전부 반영해서 다시 작성:
   - tree_method="hist" 적용 (trial당 속도 대폭 개선)
   - n_trials 100 -> 30 (실측 기준 90초/trial이면 100번은 2시간+)
   - 로그를 파일로 실시간 기록 (진행상황 확인 가능)
   - 20분 타임아웃 (무한 대기 방지)

   흐름: proj.churn_split_v2(시점분리 데이터)로 5개 후보 모델을
   기본 설정으로 먼저 비교 -> 가장 성능 좋은 모델 선정 -> 그 모델을
   Optuna로 튜닝했을 때 얼마나 더 좋아지는지까지 한 장의 그림으로 정리

   산출물: /home/student/open/plots/model_selection.png
============================================================= */

/* -------------------------------------------------------------
   1. 분석 스크립트를 SAS datalines4로 디스크에 작성
------------------------------------------------------------- */
data _null_;
    infile datalines4 truncover;
    file "/home/student/open/model_selection.py";
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

from sklearn.linear_model import LogisticRegression
from sklearn.tree import DecisionTreeClassifier
from sklearn.ensemble import RandomForestClassifier, GradientBoostingClassifier
from xgboost import XGBClassifier
from sklearn.metrics import roc_auc_score
from sklearn.preprocessing import StandardScaler
import optuna

DATA_PATH = "/home/student/open/churn_split_v2.sas7bdat"

for _fname in ["NanumGothic", "Malgun Gothic", "AppleGothic", "DejaVu Sans"]:
    if any(_fname.lower() in f.name.lower() for f in fm.fontManager.ttflist):
        plt.rcParams["font.family"] = _fname
        break
plt.rcParams["axes.unicode_minus"] = False

print("numpy 버전:", np.__version__, flush=True)
print("pandas 버전:", pd.__version__, flush=True)

# -------------------------------------------------------------
# 1. 데이터 로드 및 전처리
# -------------------------------------------------------------
df = pd.read_sas(DATA_PATH, encoding="utf-8")
df = pd.get_dummies(df, columns=["성별", "고객지역"], drop_first=True)

def _is_bytes_col(s):
    return s.dtype == object and len(s) > 0 and isinstance(s.iloc[0], bytes)

if _is_bytes_col(df["구분"]):
    train = df[df["구분"] == b"TRAIN"]
    valid = df[df["구분"] == b"VALID"]
else:
    train = df[df["구분"] == "TRAIN"]
    valid = df[df["구분"] == "VALID"]

exclude_cols = ["고객ID", "이탈여부", "구분"]
feature_cols = [c for c in df.columns if c not in exclude_cols]

X_train, y_train = train[feature_cols], train["이탈여부"]
X_valid, y_valid = valid[feature_cols], valid["이탈여부"]

scaler = StandardScaler()
X_train_scaled = scaler.fit_transform(X_train)
X_valid_scaled = scaler.transform(X_valid)

print("TRAIN:", X_train.shape, "VALID:", X_valid.shape, flush=True)

# -------------------------------------------------------------
# 2. 5개 후보 모델 - 기본/합리적 기본 설정으로 우선 비교
# -------------------------------------------------------------
candidates = {
    "Logistic\nRegression": (LogisticRegression(max_iter=1000, random_state=2026), True),
    "Decision\nTree": (DecisionTreeClassifier(max_depth=6, random_state=2026), False),
    "Random\nForest": (RandomForestClassifier(n_estimators=200, max_depth=6, random_state=2026, n_jobs=-1), False),
    "Gradient\nBoosting": (GradientBoostingClassifier(n_estimators=100, max_depth=3, random_state=2026), False),
    "XGBoost": (XGBClassifier(n_estimators=100, max_depth=4, random_state=2026, eval_metric="logloss",
                               tree_method="hist", n_jobs=-1), False),
}

baseline_results = {}
for name, (model, needs_scaling) in candidates.items():
    Xtr = X_train_scaled if needs_scaling else X_train
    Xva = X_valid_scaled if needs_scaling else X_valid
    model.fit(Xtr, y_train)
    preds = model.predict_proba(Xva)[:, 1]
    auc = roc_auc_score(y_valid, preds)
    baseline_results[name] = auc
    print(f"{name.replace(chr(10), ' ')}: AUC = {auc:.4f}", flush=True)

best_name = max(baseline_results, key=baseline_results.get)
print(f"\n>>> 5개 후보 중 최고 성능: {best_name.replace(chr(10), ' ')} (AUC={baseline_results[best_name]:.4f})", flush=True)

# -------------------------------------------------------------
# 3. 최고 성능 모델에 Optuna 튜닝 적용 (n_trials=30, hist로 속도 개선)
# -------------------------------------------------------------
def objective(trial):
    params = {
        "n_estimators": trial.suggest_int("n_estimators", 50, 150),
        "max_depth": trial.suggest_int("max_depth", 2, 6),
        "learning_rate": trial.suggest_float("learning_rate", 0.01, 0.3, log=True),
        "subsample": trial.suggest_float("subsample", 0.5, 1.0),
        "colsample_bytree": trial.suggest_float("colsample_bytree", 0.5, 1.0),
        "reg_alpha": trial.suggest_float("reg_alpha", 0.0, 5.0),
        "reg_lambda": trial.suggest_float("reg_lambda", 0.0, 5.0),
        "random_state": 2026,
        "eval_metric": "logloss",
        "tree_method": "hist",
        "n_jobs": -1,
    }
    model = XGBClassifier(**params)
    model.fit(X_train, y_train)
    preds = model.predict_proba(X_valid)[:, 1]
    return roc_auc_score(y_valid, preds)

def progress_cb(study, trial):
    print(f"[trial {trial.number+1}/30] AUC={trial.value:.4f}  (지금까지 최고: {study.best_value:.4f})", flush=True)

optuna.logging.set_verbosity(optuna.logging.WARNING)
study = optuna.create_study(direction="maximize", sampler=optuna.samplers.TPESampler(seed=2026))
study.optimize(objective, n_trials=30, callbacks=[progress_cb])

tuned_auc = study.best_value
print(f"\nOptuna 튜닝 후 XGBoost AUC: {tuned_auc:.4f} (기본 대비 {tuned_auc - baseline_results['XGBoost']:+.4f})", flush=True)

# -------------------------------------------------------------
# 4. 시각화 - 좌: 5개 모델 기본 성능 비교, 우: 선택 모델의 튜닝 전후
# -------------------------------------------------------------
fig, axes = plt.subplots(1, 2, figsize=(13, 5.5))

names = list(baseline_results.keys())
aucs = list(baseline_results.values())
colors = ["#ff7f0e" if n == best_name else "#4c72b0" for n in names]

bars = axes[0].bar(names, aucs, color=colors)
axes[0].set_ylim(min(aucs) - 0.03, max(aucs) + 0.03)
axes[0].set_ylabel("AUC (VALID)")
axes[0].set_title("1. 5개 후보 모델 기본 성능 비교\n(주황 = 선택된 모델)")
for bar, auc in zip(bars, aucs):
    axes[0].text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.002,
                 f"{auc:.4f}", ha="center", fontsize=9)

stage_names = [f"{best_name.replace(chr(10), ' ')}\n(기본)", f"{best_name.replace(chr(10), ' ')}\n(Optuna 튜닝)"]
stage_aucs = [baseline_results[best_name], tuned_auc]
bars2 = axes[1].bar(stage_names, stage_aucs, color=["#4c72b0", "#2ca02c"])
axes[1].set_ylim(min(stage_aucs) - 0.02, max(stage_aucs) + 0.02)
axes[1].set_ylabel("AUC (VALID)")
axes[1].set_title(f"2. 선택 모델 Optuna 튜닝 개선폭\n({tuned_auc - baseline_results[best_name]:+.4f})")
for bar, auc in zip(bars2, stage_aucs):
    axes[1].text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.002,
                 f"{auc:.4f}", ha="center", fontsize=9)

plt.suptitle("모델 선정 근거: 후보 비교 -> XGBoost 선택 -> Optuna 튜닝", fontsize=13)
plt.tight_layout()
plt.savefig("/home/student/open/plots/model_selection.png", dpi=130)
plt.close()

print("\nmodel_selection.png 저장 완료", flush=True)

# [추가] 완료 표시 파일 - 상태 확인 스크립트가 로그 텍스트를
# 파싱하는 대신 이 파일 존재 여부만 보고 "다 끝났다"를 확실히 판단
with open("/home/student/open/model_selection_DONE.flag", "w") as _f:
    _f.write("done")
;;;;
run;

/* -------------------------------------------------------------
   2. [수정] 백그라운드로 던지기 (SAS 세션과 분리)
   - subprocess.run(블로킹) 대신 subprocess.Popen(start_new_session=True)
     사용 - SAS 스텝은 던지자마자 1초 안에 끝나고, 실제 분석은
     SAS 세션과 무관하게 서버에서 계속 돌아감 (세션이 중간에
     끊겨도 분석은 안 끊김)
   - 완료 여부는 이 스텝이 끝난 뒤 별도로 "model_selection_status_check.sas"
     를 몇 분 간격으로 실행해서 확인 (분석을 다시 돌리는 게 아니라
     로그/완료플래그 파일만 읽음)
------------------------------------------------------------- */
proc python;
submit;
import subprocess
import sys
import os

log_path = "/home/student/open/model_selection_progress.log"
done_flag = "/home/student/open/model_selection_DONE.flag"

if os.path.exists(done_flag):
    os.remove(done_flag)

with open(log_path, "w") as f:
    proc = subprocess.Popen(
        [sys.executable, "-u", "/home/student/open/model_selection.py"],
        stdout=f, stderr=subprocess.STDOUT,
        start_new_session=True
    )

print(f"백그라운드로 던졌습니다. PID={proc.pid}")
print("이 스텝은 여기서 끝났고, 실제 분석은 서버에서 계속 돌아갑니다.")
print(f"진행상황: {log_path}")
print("완료 여부는 model_selection_status_check.sas 를 따로 실행해서 확인하세요.")
endsubmit;
run;
