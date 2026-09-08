/*=============================================================
  STAGE 2. 고객 세분화 (K-Means 군집분석) + 분석방향 근거 EDA
  = week3_clustering.sas + eda_analysis_direction_justification.sas
  전제조건: STAGE 1 실행 완료 (proj.customer_features 존재)
  산출물: proj.customer_segments
=============================================================*/

/* ============================= PART A. K-Means 군집분석 (K=6) ============================= */

/* week2_수정.sas 실행 직후, 이어서 바로 돌리면 됨 */
proc means data=proj.customer_features skewness kurtosis;
    var Recency Frequency Monetary AvgOrderValue
        CouponUseRate AvgDiscountRate AvgShipping;
    title "수정된 AvgOrderValue/AvgShipping 기준 왜도·첨도 재확인";
run;
title;
/*=============================================================
  WEEK 3. 군집분석 (핵심 세분화 축) - AvgShipping 로그변환 반영
  입력: proj.customer_features (2주차 산출물, AvgOrderValue
        주문단위 재계산 반영된 버전)
  원칙: CCC는 PROC FASTCLUS 단독으로는 산출되지 않는 계층적
        군집(PROC CLUSTER) 통계량이므로, SAS 표준 방식인
        "예비 군집(FASTCLUS) → CCC 기반 K 결정(CLUSTER) →
        최종 군집(FASTCLUS)" 3단계로 진행한다
  산출물: proj.customer_segments (Cluster ID 부여된 최종 세그먼트)

  [이번 수정 사항 - AvgShipping, AvgOrderValue 로그변환 추가]
  기존: AvgShipping을 원값 그대로 군집 변수에 사용
        -> K=7 재확인 시 배송료 300~500대인 이상치 고객 2명이
        각자 단독 군집(고객수 1명)으로 분리되는 문제 발견.
        AvgShipping의 R-Square가 0.87로 다른 변수 대비 비정상적
        으로 높게 나와 군집화를 사실상 이 변수 하나가 지배함
  수정: Frequency/Monetary와 동일하게 log(1+x) 변환한
        AvgShipping_log를 군집 변수로 사용

  추가 확인: week2에서 AvgOrderValue를 주문단위로 재계산한 뒤
        왜도 재검증 결과 5.16으로 확인됨(1 이상). 동일한 이유로
        AvgOrderValue_log를 만들어 군집 변수로 사용

  ※ 두 변수 모두 4-2(군집별 원단위 평균표)에서는 로그값이 아닌
    원래 단위(AvgShipping, AvgOrderValue)를 그대로 표시함 -
    군집화 입력변수와 해석/발표용 표시변수는 다를 수 있음
=============================================================*/

libname proj "/home/student/open";


/* -------------------------------------------------------------
   0. 왜도 반영 - 로그변환
   [결정 근거] week2 보완 2번에서 확인한 Recency/Frequency/
   Monetary/AvgOrderValue 왜도가 절대값 1 이상으로 나온 변수는
   PROC STDIZE 단순 표준화만으로는 스케일이 여전히 치우쳐 있어
   K-Means 거리 계산을 왜곡할 수 있음. Frequency/Monetary는
   구조적으로 항상 오른쪽 꼬리(소수 고객이 매우 큼)이므로
   log1p(=log(1+x)) 변환을 기본 적용. 실제 왜도 확인 결과에
   따라 아래 VAR 목록은 조정 가능
------------------------------------------------------------- */
data proj.customer_features_log;
    set proj.customer_features;
    Frequency_log = log(1 + Frequency);
    Monetary_log  = log(1 + Monetary);

    /* [신규] AvgShipping도 극단적 왜도(이상치 1~2명이 300~500대
       배송료) -> 로그변환 없이 그대로 쓰면 K-Means가 이 값만
       보고 해당 고객을 단독 군집으로 분리시킴 (K=7 재확인 시
       실제로 확인된 현상: 1명짜리 군집 2개 발생, R-Square=0.87로
       다른 변수 대비 비정상적으로 군집을 지배) */
    AvgShipping_log = log(1 + AvgShipping);

    /* [신규] AvgOrderValue 재검증 결과 왜도 5.16으로 확인됨
       (주문단위 재계산 이후 값 기준). Frequency/Monetary/
       AvgShipping과 동일하게 로그변환 필요 */
    AvgOrderValue_log = log(1 + AvgOrderValue);
run;


/* -------------------------------------------------------------
   1. PROC STDIZE - RFM 및 파생변수 표준화
   [존재 이유] K-Means는 유클리드 거리를 기반으로 하므로,
   단위가 다른 변수(원 단위 Monetary vs 비율 CouponUseRate)를
   그대로 두면 값이 큰 변수가 거리 계산을 지배함. METHOD=STD로
   평균0/표준편차1로 맞춰 모든 변수의 기여도를 동등하게 함
------------------------------------------------------------- */
proc stdize data=proj.customer_features_log out=proj.customer_features_std method=std;
    var Recency Frequency_log Monetary_log AvgOrderValue_log
        CouponUseRate AvgDiscountRate AvgShipping_log;
run;


/* -------------------------------------------------------------
   2단계. 예비 군집 (Preliminary Clustering)
   [존재 이유] 고객 수가 많을 경우 PROC CLUSTER(계층적 군집)를
   전체 데이터에 바로 돌리면 계산량이 과도함. SAS 권장 방식대로
   먼저 FASTCLUS로 다수(예: 50개)의 예비 군집으로 압축한 뒤,
   그 압축된 군집 평균에 대해 계층적 군집을 수행한다
------------------------------------------------------------- */
proc fastclus data=proj.customer_features_std maxclusters=50 maxiter=100
              out=proj.prelim_out mean=proj.prelim_mean noprint;
    var Recency Frequency_log Monetary_log AvgOrderValue_log
        CouponUseRate AvgDiscountRate AvgShipping_log;
run;


/* -------------------------------------------------------------
   2단계. PROC CLUSTER - CCC/Pseudo-F/Pseudo-T² 기반 최적 K 결정
   [존재 이유] 예비 군집 평균(prelim_mean)에 Ward's method로
   계층적 군집을 수행하면서, 각 군집수(NCL)별 CCC/PSF/PST2를
   산출. PROC FASTCLUS의 MEAN= 출력 데이터셋에는 _FREQ_,
   _RMSSTD_ 변수가 이미 자동으로 포함되어 있고, PROC CLUSTER는
   이를 자동으로 인식해서 통계량 계산에 반영함(SAS 공식 문서/
   예제 방식). 따라서 FREQ 문을 별도로 명시하지 않는다 -
   명시적 FREQ 문을 쓰면 CCC/PSF/PST2 통계량 자체가 산출되지
   않는 오류(컬럼 자체가 생성 안 됨)가 발생할 수 있음
   ※ ODS output ClusterHistory 테이블의 실제 컬럼명은
     CCC / PSF / PST2 임 (PseudoF, PseudoT2 아님 - SAS 공식 명칭)
------------------------------------------------------------- */
proc cluster data=proj.prelim_mean method=ward ccc pseudo out=proj.cluster_tree;
    var Recency Frequency_log Monetary_log AvgOrderValue_log
        CouponUseRate AvgDiscountRate AvgShipping_log;
    ods output ClusterHistory=proj.cluster_stats;
run;

/* CCC/PseudoF 추이를 눈으로 확인 - 그래프상 CCC가 급격히
   꺾이는 지점(피크) 또는 PseudoF가 국소 최대인 지점이 후보 K
   ※ proc contents로 실제 확인된 컬럼명: CubicClusCrit(=CCC),
     PseudoF(=PSF), PseudoTSq(=PST2) */
proc sql;
    select NumberOfClusters, CubicClusCrit, PseudoF, PseudoTSq
    from proj.cluster_stats
    where NumberOfClusters between 2 and 10
    order by NumberOfClusters;
    title "2. 군집수(K)별 CCC / PseudoF / PseudoTSq (K=2~10)";
quit;
title;

proc sgplot data=proj.cluster_stats;
    where NumberOfClusters between 2 and 15;
    series x=NumberOfClusters y=CubicClusCrit;
    xaxis label="군집 수(K)";
    yaxis label="CCC (Cubic Clustering Criterion)";
    title "2-1. K별 CCC 추이 (피크 지점이 최적 K 후보)";
run;
title;

proc sgplot data=proj.cluster_stats;
    where NumberOfClusters between 2 and 15;
    series x=NumberOfClusters y=PseudoF;
    xaxis label="군집 수(K)";
    yaxis label="Pseudo F Statistic";
    title "2-2. K별 PseudoF 추이 (국소 최대 지점이 최적 K 후보)";
run;
title;

/* -------------------------------------------------------------
   ※ 여기서 그래프/표를 보고 최적 K를 확정한다 (예: K=4)
   팀 논의 후 아래 매크로변수를 실제 값으로 수정할 것
------------------------------------------------------------- */
%let optimal_k = 6;   /* 최종 확정 (2026.08.19)
                          - AvgOrderValue_log, AvgShipping_log 반영 후
                            K=4,5,6 비교 실행
                          - K=4: 통계 근소 우위, 심플하나 세그먼트 단순
                          - K=5: 쿠폰의존 세그먼트(CouponUseRate 0.69) 발견
                          - K=6: CCC(48.69)·전체R²(0.506) 3개 후보 중 최고,
                            쿠폰의존 세그먼트 + "이탈위험 고객군"(305명,
                            20.8%, Recency 250.8일로 최고인데 Frequency/
                            Monetary는 상위권) 신규 발견 - 다음 주차
                            이탈예측(PROC GRADBOOST)과 스토리 연결됨
                          -> K=6 최종 채택 */


/* -------------------------------------------------------------
   3단계. 최종 PROC FASTCLUS - 전체 고객 대상 K-Means 확정
   [존재 이유] 2단계는 예비 군집(50개) 기준의 근사치이므로,
   확정된 K로 전체 표준화 데이터에 대해 다시 K-Means를 수행해야
   실제 개별 고객 단위의 정확한 군집 배정(Cluster ID)이 나옴
------------------------------------------------------------- */
proc fastclus data=proj.customer_features_std maxclusters=&optimal_k maxiter=100
              out=proj.customer_clustered;
    var Recency Frequency_log Monetary_log AvgOrderValue_log
        CouponUseRate AvgDiscountRate AvgShipping_log;
    title "3. 최종 K-Means 군집화 (K=&optimal_k)";
run;
title;


/* -------------------------------------------------------------
   4. 군집별 특성 프로파일링
   [존재 이유] Cluster ID만으로는 각 군집이 어떤 성격의
   고객군인지 알 수 없으므로, 원 단위(표준화 이전) RFM 값과
   인구통계 분포를 군집별로 비교해 세그먼트 이름을 붙일 근거를
   마련해야 함
------------------------------------------------------------- */

/* 4-1. Cluster ID를 원본(비표준화) 고객 특성 테이블에 병합 */
proc sql;
    create table proj.customer_segments as
    select a.*, b.cluster as Cluster_ID
    from proj.customer_features as a
    left join proj.customer_clustered as b
        on a.고객ID = b.고객ID;
quit;

/* 4-2. 군집별 R/F/M 평균 (원 단위 - 해석 용이)
   [주의] 여기서는 군집화에 실제 쓰인 AvgShipping_log가 아니라
   원래 단위인 AvgShipping을 그대로 보여줌 - "군집7 평균배송료가
   몇 원이다"처럼 발표할 때 로그값이 아니라 실제 원 단위가
   필요하기 때문 (군집화 입력변수와 해석용 표시변수는 다를 수 있음) */
proc means data=proj.customer_segments mean std n;
    class Cluster_ID;
    var Recency Frequency Monetary AvgOrderValue
        CouponUseRate AvgDiscountRate AvgShipping;
    title "4-2. 군집별 RFM 및 파생변수 평균 (원 단위)";
run;
title;

/* 4-3. 군집별 지역/성별 분포 */
proc freq data=proj.customer_segments;
    tables Cluster_ID * (성별 고객지역) / nocol nopercent;
    title "4-3. 군집별 성별/지역 분포";
run;
title;

/* 4-4. 군집 크기(고객수) 및 비중 */
proc sql;
    select Cluster_ID,
           count(*) as 고객수,
           count(*) / (select count(*) from proj.customer_segments) * 100 as 비중_pct
    from proj.customer_segments
    group by Cluster_ID
    order by Cluster_ID;
    title "4-4. 군집별 고객수 및 비중";
quit;
title;


/* -------------------------------------------------------------
   5. 최종 산출물 확인
   proj.customer_segments = 이후 모든 분석(코호트, 연관분석,
   이탈예측, 대시보드)의 기준이 되는 세그먼트 테이블
------------------------------------------------------------- */
proc contents data=proj.customer_segments varnum;
    title "5. 최종 세그먼트 테이블(customer_segments) 구조";
run;
title;

/* ============================= PART B. 분석방향 근거 EDA (군집 분리도 등 검증) ============================= */
/*=============================================================
  EDA. 분석 방향 근거 - "왜 RFM → K-Means → 연관분석 → 이탈예측
  파이프라인인가"를 데이터로 뒷받침하는 사전 점검용 EDA

  전제조건: week1_data_cleaning_merged.sas, week2_rfm_derived_merged.sas,
  week3_clustering.sas 실행 후 proj.sales_with_disc, proj.customer_features,
  proj.customer_segments 가 존재해야 함

  이 스크립트가 확인하는 것:
  1) 고객이 실제로 균일하지 않은가? (균일하면 세그멘테이션 자체가 불필요)
  2) RFM 세 지표가 서로 겹치지 않고 각자 다른 정보를 주는가?
     (겹치면 굳이 3개 다 쓸 필요 없이 1~2개로 충분)
  3) 군집(K=6)이 실제로 구분되는 그룹인가? (겹치면 군집화 무의미)
  4) 주문에 상품이 여러 개 담기는 경우가 충분한가? (아니면 Apriori
     연관분석을 해도 유의미한 규칙이 안 나올 수 있음)
  5) 이탈 고객군이 매출에서 차지하는 비중은 얼마나 되는가?
     (작으면 이탈예측에 자원을 쓸 사업적 이유가 약해짐)
  6) 월별 매출에 뚜렷한 계절성/추세가 있는가? (있으면 "이탈"을
     계절 요인과 혼동하지 않도록 라벨 윈도우 설계에 반영 필요)
=============================================================*/

libname proj "/home/student/open";


/* -------------------------------------------------------------
   1. 고객 동질성 여부 - RFM 변수의 변동계수(CV = std/mean)
   [근거로 쓰는 방법] CV가 낮으면(예: <0.3) 고객들이 서로 비슷해
   세그멘테이션 실익이 적다는 신호. CV가 크면(예: >1) 고객 간
   차이가 크다는 뜻이라 세분화가 의미를 가짐
------------------------------------------------------------- */
proc means data=proj.customer_features n mean std min max;
    var Recency Frequency Monetary AvgOrderValue AvgShipping;
    output out=work.cv_check mean= std= / autoname;
    title "1-1. RFM/파생변수 기초통계 - 변동계수(CV) 계산용";
run;
title;

data work.cv_result;
    set work.cv_check;
    Recency_CV      = Recency_StdDev / Recency_Mean;
    Frequency_CV    = Frequency_StdDev / Frequency_Mean;
    Monetary_CV     = Monetary_StdDev / Monetary_Mean;
    AvgOrderValue_CV= AvgOrderValue_StdDev / AvgOrderValue_Mean;
    AvgShipping_CV  = AvgShipping_StdDev / AvgShipping_Mean;
    keep Recency_CV Frequency_CV Monetary_CV AvgOrderValue_CV AvgShipping_CV;
run;

proc print data=work.cv_result noobs;
    title "1-2. 변수별 변동계수(CV=표준편차/평균) - 0.3 미만이면 세그멘테이션 실익 낮음";
run;
title;


/* -------------------------------------------------------------
   2. RFM 세 지표 간 독립성 - 상관관계가 너무 높으면 중복 정보
   [근거로 쓰는 방법] |상관계수| > 0.8인 쌍이 있으면 그 두 지표는
   사실상 같은 정보를 담고 있다는 뜻 -> 군집 변수에서 하나를
   빼거나 가중치 조정을 고려해야 함
------------------------------------------------------------- */
proc corr data=proj.customer_features noprint outp=work.corr_out;
    var Recency Frequency Monetary;
run;

proc print data=work.corr_out(where=(_type_="CORR"));
    title "2-1. Recency-Frequency-Monetary 상관행렬 - 0.8 넘는 쌍 있는지 확인";
run;
title;


/* -------------------------------------------------------------
   3. 군집(K=6) 분리도 확인 - 군집별 RFM 평균이 실제로 다른가
   [근거로 쓰는 방법] 군집별 박스플롯이 서로 겹치지 않고 뚜렷이
   구분되면 K=6 군집화가 유의미하다는 근거. 대부분 겹치면 군집
   수나 변수 선택을 재검토해야 함
------------------------------------------------------------- */
proc means data=proj.customer_segments mean std n;
    class Cluster_ID;
    var Recency Frequency Monetary AvgShipping;
    title "3-1. 군집별 RFM 평균/표준편차 - 군집 간 차이가 표준편차보다 뚜렷한지 확인";
run;
title;

proc sgplot data=proj.customer_segments;
    vbox Monetary / category=Cluster_ID;
    xaxis label="군집(Cluster_ID)";
    yaxis label="Monetary";
    title "3-2. 군집별 Monetary 분포 - 박스가 서로 겹치지 않을수록 군집 분리가 뚜렷함";
run;
title;

proc sgplot data=proj.customer_segments;
    vbox Recency / category=Cluster_ID;
    xaxis label="군집(Cluster_ID)";
    yaxis label="Recency";
    title "3-3. 군집별 Recency 분포 - 이탈위험 군집이 실제로 구분되는지 확인";
run;
title;


/* -------------------------------------------------------------
   4. 연관분석(Apriori) 타당성 - 주문(장바구니)당 평균 상품 카테고리 수
   [근거로 쓰는 방법] 평균이 1에 가까우면(대부분 단일 품목 구매)
   장바구니 간 동반구매 규칙 자체가 나오기 어려움. 1보다 뚜렷이
   크면 연관분석이 의미 있는 규칙을 찾을 여지가 있다는 근거
------------------------------------------------------------- */
proc sql;
    create table work.basket_size as
    select 거래ID, count(distinct 제품카테고리) as 카테고리수
    from proj.sales_with_disc
    group by 거래ID;
quit;

proc means data=work.basket_size n mean std min max;
    var 카테고리수;
    title "4-1. 주문(장바구니)당 평균 상품 카테고리 수 - 1에 가까우면 연관분석 실익 낮음";
run;
title;

proc freq data=work.basket_size;
    tables 카테고리수 / nocum;
    title "4-2. 장바구니 크기(카테고리 수) 분포 - 2개 이상 담긴 주문 비중 확인";
run;
title;


/* -------------------------------------------------------------
   5. 이탈 위험군의 매출 비중 - 이탈예측에 자원을 쓸 사업적 근거
   [근거로 쓰는 방법] Cluster_ID=2(이탈위험 세그먼트로 추정되는
   군집)가 전체 Monetary에서 차지하는 비중을 확인. 비중이 작으면
   "막아도 임팩트가 작은 고객군"이라 우선순위 재검토 필요
------------------------------------------------------------- */
proc sql;
    select Cluster_ID,
           sum(Monetary) as 군집총매출,
           sum(Monetary) / (select sum(Monetary) from proj.customer_segments) * 100 as 매출비중_pct,
           count(*) as 고객수,
           count(*) / (select count(*) from proj.customer_segments) * 100 as 고객수비중_pct
    from proj.customer_segments
    group by Cluster_ID
    order by Cluster_ID;
    title "5-1. 군집별 매출 비중 vs 고객수 비중 - 매출비중이 고객수비중보다 크게 낮은 군집이 '지켜야 할 우량 이탈위험군' 후보";
quit;
title;


/* -------------------------------------------------------------
   6. 월별 매출 계절성/추세 확인
   [근거로 쓰는 방법] 월별 매출이 뚜렷한 상승/하락 추세나 특정
   월에 튀는 패턴(예: 프로모션 시즌)을 보이면, "이탈"을 판단할 때
   그 계절 효과와 진짜 이탈을 구분해야 함 -> 라벨 윈도우를 특정
   시즌에 걸치지 않게 잡는 근거가 됨 (week4 변화점 탐지와 연결)
------------------------------------------------------------- */
proc sql;
    create table work.monthly_sales as
    select put(거래날짜_num, yymmn6.) as 년월,
           sum(거래금액) as 월매출
    from proj.sales_with_disc
    group by calculated 년월
    order by calculated 년월;
quit;

proc sgplot data=work.monthly_sales;
    series x=년월 y=월매출 / markers lineattrs=(thickness=2);
    xaxis label="년월" fitpolicy=thin;
    yaxis label="월매출";
    title "6-1. 월별 매출 추이 - 특정 시즌에 튀는 구간이 있는지 확인 (라벨 윈도우 설계 참고용)";
run;
title;


/* -------------------------------------------------------------
   7. 요약 - 이 EDA 결과를 발표/보고서에 쓸 때 확인할 체크리스트
   (주석 - 실행되는 코드 아님)
   [ ] 1번: RFM 변수 CV가 충분히 커서(예: Monetary CV > 0.5) 세그멘테이션 근거가 되는가
   [ ] 2번: Recency-Frequency-Monetary 상관계수가 0.8 미만이라 3개를 다 쓸 근거가 있는가
   [ ] 3번: 군집별 박스플롯이 눈에 띄게 구분되는가
   [ ] 4번: 장바구니 평균 카테고리 수가 1보다 충분히 큰가 (아니면 연관분석 결과 해석에 유의)
   [ ] 5번: 이탈위험 군집의 매출 비중이 무시할 수 없는 수준인가
   [ ] 6번: 월별 매출에 뚜렷한 계절성이 있어 라벨 윈도우 설계 시 고려했는가
------------------------------------------------------------- */
