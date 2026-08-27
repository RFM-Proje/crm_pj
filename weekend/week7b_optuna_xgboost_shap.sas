/*=============================================================
  WEEK 7b. Optuna 기반 XGBoost 튜닝 + SHAP 해석 (PROC PYTHON 실행판)

  SAS Studio에서 다른 week*.sas 파일들과 동일하게 바로 실행 가능.
  내부적으로는 PROC PYTHON으로 Python 코드(pandas/optuna/xgboost/shap)를
  그대로 감싼 것 - Python 문법 자체는 바뀐 것 없음.

  사전 설치 필요 (SAS Studio 터미널 또는 PROC PYTHON에서):
    pip install optuna xgboost shap pandas scikit-learn matplotlib

  산출물: /home/student/open/ 밑에 shap_*.png 4개 저장됨
=============================================================*/

proc python;
submit;
"""
Optuna 기반 XGBoost 하이퍼파라미터 튜닝
- SAS week6d가 만든 proj.churn_split_v2 (.sas7bdat)를 pandas로 직접 로드
- SAS에서 이미 나눈 TRAIN/VALID 분할(구분 컬럼)을 그대로 재사용 -> 공정 비교
- 목표: SAS GRADBOOST 결과(AUC 0.8803)를 넘어서는 조합을 찾을 수 있는지 확인

사전 설치 필요 (안 되어 있으면):
    pip install optuna xgboost pandas scikit-learn

[주의] 파일 경로는 이전 로그에서 확인된 패턴
(/home/student/open/customer_segments.sas7bdat 등)을 따라
/home/student/open/churn_split_v2.sas7bdat 로 가정했습니다.
실제 경로가 다르면 DATA_PATH만 수정하면 됩니다.
"""

import pandas as pd
import numpy as np
import optuna
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from xgboost import XGBClassifier
from sklearn.metrics import roc_auc_score

DATA_PATH = "/home/student/open/churn_split_v2.sas7bdat"

# -------------------------------------------------------------
# 1. 데이터 로드
# -------------------------------------------------------------
df = pd.read_sas(DATA_PATH, encoding="utf-8")

print("전체 데이터 shape:", df.shape)
print(df["구분"].value_counts())
print(df["이탈여부"].value_counts(normalize=True))

# -------------------------------------------------------------
# 2. 범주형 변수 인코딩 (성별, 고객지역 -> 원핫)
#    SAS GRADBOOST는 level=nominal로 알아서 처리했지만
#    XGBoost는 숫자 인코딩이 필요함
# -------------------------------------------------------------
df = pd.get_dummies(df, columns=["성별", "고객지역"], drop_first=True)

# -------------------------------------------------------------
# 3. SAS에서 만든 TRAIN/VALID 분할 그대로 재사용
# -------------------------------------------------------------
train = df[df["구분"] == b"TRAIN"] if df["구분"].dtype == object and isinstance(df["구분"].iloc[0], bytes) else df[df["구분"] == "TRAIN"]
valid = df[df["구분"] == b"VALID"] if df["구분"].dtype == object and isinstance(df["구분"].iloc[0], bytes) else df[df["구분"] == "VALID"]

exclude_cols = ["고객ID", "이탈여부", "구분"]
feature_cols = [c for c in df.columns if c not in exclude_cols]

X_train, y_train = train[feature_cols], train["이탈여부"]
X_valid, y_valid = valid[feature_cols], valid["이탈여부"]

print("TRAIN:", X_train.shape, "VALID:", X_valid.shape)

# -------------------------------------------------------------
# 4. Optuna 목적함수 - VALID AUC 최대화
# -------------------------------------------------------------
def objective(trial):
    params = {
        "n_estimators": trial.suggest_int("n_estimators", 50, 300),
        "max_depth": trial.suggest_int("max_depth", 2, 8),
        "learning_rate": trial.suggest_float("learning_rate", 0.01, 0.3, log=True),
        "subsample": trial.suggest_float("subsample", 0.5, 1.0),
        "colsample_bytree": trial.suggest_float("colsample_bytree", 0.5, 1.0),
        "reg_alpha": trial.suggest_float("reg_alpha", 0.0, 5.0),
        "reg_lambda": trial.suggest_float("reg_lambda", 0.0, 5.0),
        "random_state": 2026,
        "eval_metric": "logloss",
        "use_label_encoder": False,
    }
    model = XGBClassifier(**params)
    model.fit(X_train, y_train)
    preds = model.predict_proba(X_valid)[:, 1]
    return roc_auc_score(y_valid, preds)


study = optuna.create_study(
    direction="maximize",
    sampler=optuna.samplers.TPESampler(seed=2026),
)
study.optimize(objective, n_trials=100)

print("\n===== 튜닝 결과 =====")
print("Best AUC (Optuna/XGBoost):", study.best_value)
print("SAS GRADBOOST(시점분리) AUC: 0.8803  <- 비교 기준")
print("Best params:", study.best_params)

# -------------------------------------------------------------
# 5. 최적 모델로 최종 확인 + 변수중요도
# -------------------------------------------------------------
best_model = XGBClassifier(**study.best_params, random_state=2026, eval_metric="logloss")
best_model.fit(X_train, y_train)
final_auc = roc_auc_score(y_valid, best_model.predict_proba(X_valid)[:, 1])
print("최종 검증 AUC:", final_auc)

importance = pd.Series(best_model.feature_importances_, index=feature_cols).sort_values(ascending=False)
print("\n변수 중요도:\n", importance)

# -------------------------------------------------------------
# 6. XAI - SHAP 해석
# (M6 Day7 자료 Session 5 참고, 우리 프로젝트 데이터에 맞게 적용)
#
# 왜 필요한가: feature_importances_는 "얼마나 중요한지" 순위만 알려줌
# (SAS PDP로도 일부 확인했지만), SHAP은 "각 고객 개별로 어떤 변수가
# 이탈확률을 얼마나/어느 방향으로 밀어올렸는지"까지 분해해서 보여줌.
# 사전 설치 필요 시: pip install shap
# -------------------------------------------------------------
import shap

explainer = shap.TreeExplainer(best_model)
shap_values = explainer.shap_values(X_valid)

# 6-1. 글로벌 해석 - 변수별 영향 방향 + 크기 (summary plot)
shap.summary_plot(shap_values, X_valid, show=False)
plt.tight_layout()
plt.savefig("/home/student/open/plots/shap_summary.png", dpi=120)
plt.close()

# 6-2. 변수 중요도 막대그래프 (SHAP 기준 - feature_importances_와 비교용)
shap.summary_plot(shap_values, X_valid, plot_type="bar", show=False)
plt.tight_layout()
plt.savefig("/home/student/open/plots/shap_bar.png", dpi=120)
plt.close()

# 6-3. 개별 고객 해석 - 이탈확률이 가장 높은 고객 1명 (마케팅 액션 근거로 활용 가능)
valid_probs = best_model.predict_proba(X_valid)[:, 1]
high_risk_pos = int(np.argmax(valid_probs))
print(f"\n최고 위험 고객 이탈확률: {valid_probs[high_risk_pos]:.4f}")

shap.force_plot(
    explainer.expected_value, shap_values[high_risk_pos],
    X_valid.iloc[high_risk_pos], matplotlib=True, show=False
)
plt.savefig("/home/student/open/plots/shap_force_top_risk_customer.png", dpi=120)
plt.close()

# 6-4. 의존성 plot - Recency (SAS PDP에서도 1위 변수였음, 방향성 교차검증 목적)
shap.dependence_plot("Recency", shap_values, X_valid, show=False)
plt.tight_layout()
plt.savefig("/home/student/open/plots/shap_dependence_recency.png", dpi=120)
plt.close()

print("\nSHAP 분석 완료 - 아래 파일 생성됨:")
print("  shap_summary.png (글로벌 해석)")
print("  shap_bar.png (변수 중요도)")
print("  shap_force_top_risk_customer.png (최고위험 고객 1명 해석)")
print("  shap_dependence_recency.png (Recency 방향성 - SAS PDP와 비교용)")

endsubmit;
quit;
