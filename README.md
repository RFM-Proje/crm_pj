# CRM Pioneer · 이커머스 고객 진단 대시보드

한정된 마케팅 예산으로 누구를, 어떻게 다시 오게 할 것인가

## 프로젝트 목적

2019년 한 해 동안의 온라인 쇼핑몰 거래 데이터로 고객의 가치와 이탈 위험을 매기고, 고객 여정 단계마다 무엇을 보낼지 정해 바로 실행할 수 있는 명단까지 만듭니다.

## 왜 하는가

- 마케팅비는 연 173만 달러로 매출의 44%였지만, 평균 하루 마케팅비만큼 더 쓴 날 늘어난 매출은 그보다 작았고 첫 구매 고객도 늘지 않았습니다.
- 첫 구매 고객 중 90일 안에 두 번째로 산 고객은 37.1%뿐이라, 가장 크게 새는 곳은 두 번째 구매였습니다.
- 그래서 넓게 쓰는 대신 이미 산 고객의 두 번째 구매를 만드는 쪽으로 예산을 옮기고, 효과는 보류군 대비 재구매율로 확인합니다.

## 웹 대시보드

![Action Queue](docs/action_queue.png)

| 화면 | 내용 |
|---|---|
| Executive 요약 | AARRR 다섯 단계 진단, 가치 × 위험 매트릭스, 운영 규칙 |
| 여정·퍼널 | 구매 단계 퍼널, 주별 두 번째 구매 확률, 월별 코호트 |
| 실행 플랜 | 캠페인 플레이북, 보류군 실험 설계 |
| Action Queue | 캠페인·등급·위험 필터, 우선순위 명단, 발송용 CSV |
| Customer 360 | 고객 한 명의 등급·위험·여정 단계, 추천 캠페인과 다음 발송 |

## 실행 방법

Python 3.12에서 확인했습니다.

```bash
git clone -b py https://github.com/RFM-Proje/crm_pj.git
cd crm_pj
pip install -r requirements.txt
```

원천 CSV 5개를 `open/` 폴더에 넣습니다.

```
open/
├── Customer_info.csv
├── Discount_info.csv
├── Marketing_info.csv
├── Onlinesales_info.csv
└── Tax_info.csv
```

분석 파이프라인을 순서대로 한 번 실행합니다. 결과는 `weekend/crm_db/`에 저장되며 약 2~3분 걸립니다.

```bash
cd weekend
python r1-1.py   # 데이터 정제
python r2-2.py   # 구매일 단위 집계 · RFM 파생 변수
python r3-1.py   # RFMP 가치 등급 · K-Means 가중치
python r4-1.py   # 이탈 예측 모델 · 실행 규칙 · 최종 명단
python r5-1.py   # 고객 360 · 코호트
python r6-1.py   # 두 번째 구매 · 마케팅 효율 · 실험 기준값
cd ..
```

대시보드를 켭니다.

```bash
python web_v2/app.py
```

브라우저에서 `http://127.0.0.1:5001`이 열립니다. 포트가 사용 중이면 5002, 5003 순서로 비어 있는 포트를 씁니다.

## 폴더 구조

```
crm_pj/
├── open/        원천 데이터
├── weekend/     분석 파이프라인 (r*.py, SAS 원본 r*.sas)
├── web_v2/      Flask 웹 대시보드
└── docs/        README 이미지
```

## 팀

| 이름 | 역할 |
|---|---|
| 박준홍 | 총괄 · 분석 설계, RFMP 가중치, 이탈 예측 모형 설계 |
| 이대한 | 데이터 정제 · 검증, 모델 비교 실험, 시각화 · 웹 대시보드 |
