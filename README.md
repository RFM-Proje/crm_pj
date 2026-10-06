<img width="960" height="364" alt="git-flow-demo-light" src="https://github.com/user-attachments/assets/c406ee8e-656f-48a8-935d-919d44799966" />

# 📊 CRM Insight Hub
### 고객가치(RFM-P) × 이탈 위험으로 "누구부터, 무엇을 보낼지" 정하고, 두 번째 구매를 만드는 CRM 분석 · 운영 대시보드

[![SAS](https://img.shields.io/badge/SAS-Viya-1B7F9C?style=for-the-badge&logo=sas&logoColor=white)](https://www.sas.com/)
[![Python](https://img.shields.io/badge/Python-3.12-3776AB?style=for-the-badge&logo=python&logoColor=white)](https://www.python.org/)
[![scikit-learn](https://img.shields.io/badge/scikit--learn-F7931E?style=for-the-badge&logo=scikitlearn&logoColor=white)](https://scikit-learn.org/)
[![pandas](https://img.shields.io/badge/pandas-150458?style=for-the-badge&logo=pandas&logoColor=white)](https://pandas.pydata.org/)
[![Flask](https://img.shields.io/badge/Flask-000000?style=for-the-badge&logo=flask&logoColor=white)](https://flask.palletsprojects.com/)
[![Chart.js](https://img.shields.io/badge/Chart.js-FF6384?style=for-the-badge&logo=chartdotjs&logoColor=white)](https://www.chartjs.org/)

[![Data](https://img.shields.io/badge/Data-DACON_이커머스_2019-0C4DA2?style=flat-square)](https://dacon.io/)
[![Branch](https://img.shields.io/badge/code-py_branch-6E40C9?style=flat-square&logo=github)](https://github.com/RFM-Proje/crm_pj/tree/py)
[![License](https://img.shields.io/badge/license-MIT-lightgrey?style=flat-square)](LICENSE)

<a href="https://rfm-proje.github.io/crm_pj/git-flow-detailed-rendered.html">
  <img src="./git-flow-demo-light.gif" alt="CRM Insight Hub Git Flow" width="900">
</a>

👆 **[인터랙티브 Git Flow 열기](https://rfm-proje.github.io/crm_pj/git-flow-detailed-rendered.html)** — 커밋을 누르면 단계별 작업 내용과 산출 테이블을 볼 수 있습니다.

---

## ⚡ 30초 요약

| | 내용 |
| --- | --- |
| **문제** | 마케팅비가 매출의 44%인데, 평균 하루 마케팅비 $4,749를 더 쓴 날 매출은 +$2,705만 달러 뿐이고 첫 구매 고객은 늘지 않음 |
| **데이터** | DACON 이커머스 5개 테이블 (고객 · 온라인 거래 · 할인 · 마케팅 · 세금), 2019년 1년치, 고객 1,468명 |
| **방법** | ① 정제 · 품질 플래그 → ② 구매일 단위 RFM → ③ 시점분리 이탈 모형 + **RFM-P** 6등급 → ④ 가치 × 위험 → ⑤ 두 번째 구매 · 마케팅 효과 검정 → ⑥ 웹 대시보드 |
| **핵심 결정** | 세는 단위를 주문이 아닌 **구매한 날**로 — 재구매율 91% → 50%, 이탈 예측력 AUC 0.664 → **0.674** |
| **목표 변경** | 떠날 고객 골라내기에는 한계 → **첫 구매 후 90일 안 두 번째 구매율(37.1%)** 을 북극성 지표로 |
| **결과물** | 여정 단계별 캠페인 4개와 우선순위 명단, 보류군 실험 설계, **웹 대시보드 5화면** |
| **정직한 한계** | 첫 구매 정보로 두 번째 구매 예측(`converted_90d`) AUC 0.54 → 예측 대신 행동 목표로, 효과는 보류군으로 확인 |
| **재현** | SAS: `work/r_all.sas` · Python: `weekend/r1-1.py ~ r6-1.py` → `python web_v2/app.py` |



<a name="overview"></a>

## 1. 📝 프로젝트 개요 및 기획 배경

**"한정된 마케팅 예산으로, 누구를 어떻게 다시 오게 할 것인가?"**

데이터를 처음 봤을 때 마케팅비는 연 173만 달러, 매출의 44%를 365일 매일 쓰고 있었고, 매출은 상위 20% 고객이 61%를 만들고 있었습니다. 넓게 쓰는 대신 떠날 고객을 골라 집중하면 낫지 않을까 하는 가설에서 출발했습니다.

SAS Viya로 설계한 파이프라인을 Python으로 옮겨 **고객가치(RFM-P)** 와 **이탈 위험**을 따로 측정해 결합했습니다. 분석 기준을 다시 점검하면서 떠날 고객을 골라내는 것만으로는 효과가 작다는 것을 확인했고, 목표를 **두 번째 구매 만들기**로 바꿨습니다.

- 이탈 라벨의 **정보 누출(leakage)** 을 발견하고 시점분리 방식으로 재설계
- 세는 단위를 **구매한 날**로 바로잡고, 모델 4종을 16가지 조합으로 비교
- 문제 제기는 가정값(마진 등)이 아닌 **관측된 숫자로만**
- 예측이 어려운 곳은 모델 대신 **운영 정책과 보류군 실험**으로


<a name="results"></a>

## 2. 📈 결과: 웹 대시보드

![Action Queue](스크린샷%202026-10-05%20193356.png)

<a name="run"></a>

## 3. 🚀 실행 방법

```bash
git clone -b py https://github.com/RFM-Proje/crm_pj.git
cd crm_pj
pip install -r requirements.txt

# open/ 폴더에 DACON CSV 5종을 넣은 뒤 분석 파이프라인 실행 (약 2~3분)
cd weekend
for f in r1-1 r2-2 r3-1 r4-1 r5-1 r6-1; do python $f.py; done
cd ..

python web_v2/app.py
```
