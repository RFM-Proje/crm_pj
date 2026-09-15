/*=============================================================
  run_all_to_pdf.sas - 전체 파이프라인 결과를 PDF 한 장에 모으기

  [경고 1] 이 파일은 stage1~6 + churn_improvement + model_selection을
  처음부터 전부 다시 실행합니다. GRADBOOST, SHAP, Optuna 튜닝 등
  무거운 단계가 섞여있어 전체 실행에 수십 분~1시간 이상 걸릴 수
  있습니다. 자리를 비울 수 있을 때 실행하는 걸 추천합니다.

  [경고 2 - 경로 확인 필수] 아래 %include 경로는 로그에 찍혔던
  "/home/student/abcdefg/union/" 기준으로 가정해뒀습니다. 실제
  파일 위치가 다르면 &base_path 값을 실제 폴더로 수정하세요.

  [참고] 각 파일 안의 PROC PYTHON print() 출력(fold 진행상황,
  trial 로그 등)은 ODS 대상이 아니라서 PDF에는 안 찍힙니다.
  그 뒤에 이어지는 proc print / proc sgplot 결과(요약표, 차트,
  변수중요도, AUC 등)만 PDF에 담깁니다.

  [원치 않는 단계가 있으면] 해당 title3/%include 두 줄을 SAS 주석
  기호로 통째로 감싸면 그 단계만 빼고 나머지는 그대로 PDF에 들어갑니다.

  산출물: /home/student/open/pdf_logs/00_전체결과.pdf
=============================================================*/

options dlcreatedir;
libname _pdflib "/home/student/open/pdf_logs";
libname _pdflib clear;

%let base_path = /home/student/abcdefg/union;

ods pdf file="/home/student/open/pdf_logs/00_전체결과.pdf" style=journal startpage=yes;
ods noproctitle;
ods graphics on;

title "CRM Insight Hub - 전체 파이프라인 결과";
title2 "생성일시: %sysfunc(datetime(), datetime20.)";

title3 "===== STAGE 1. 데이터 전처리 =====";
%include "&base_path./stage1_data_prep.sas";

title3 "===== STAGE 2. 고객 세분화(군집) =====";
%include "&base_path./stage2_segmentation.sas";

title3 "===== STAGE 3. 행동/연관분석 =====";
%include "&base_path./stage3_behavior_association.sas";

title3 "===== STAGE 4. 이탈예측 (확장 피처 + 시점분리 검증) =====";
%include "&base_path./stage4_churn_prediction.sas";

title3 "===== STAGE 5. 최종 등급 설계 + SHAP + VA 배포 =====";
%include "&base_path./stage5_final_tier_deployment.sas";

title3 "===== STAGE 6. 행동 심층분석 (ARPPU/마케팅/성별/요일/쿠폰) =====";
%include "&base_path./stage6_behavior_deepdive.sas";

title3 "===== 이탈예측 개선 실험 (기본/트렌드/확장 피처 비교) =====";
%include "&base_path./churn_improvement_launch.sas";

title3 "===== 모델 선정 근거 (5개 모델 비교 + Optuna 튜닝) =====";
%include "&base_path./model_selection_evidence.sas";

title;
title2;
title3;
ods graphics off;
ods pdf close;

%put NOTE: 전체 결과 PDF 생성 완료 - /home/student/open/pdf_logs/00_전체결과.pdf;
