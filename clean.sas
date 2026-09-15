/*=============================================================
  cleanup_tables.sas - proj 라이브러리 정리

  삭제는 되돌릴 수 없습니다. 먼저 PART A(목록 확인)만 실행해서
  삭제 대상이 맞는지 눈으로 확인하시고, 이상 없으면 PART B(실제
  삭제) 코드 블록 앞뒤의 주석 기호를 지우고 실행하세요.

  분류 기준:
  - KEEP(보존) = 다른 stage/분석에서 재사용되거나, 그 자체로 최종
    산출물(보고서/모델 결과/추천 결과)인 테이블
  - DROP(삭제 후보) = 계산 도중에만 쓰이고 최종 테이블에 흡수된
    뒤로는 다시 참조되지 않는 중간 산출물, 진단용 1회성 테이블

  이 분류는 지금까지 만든 stage1~7 코드를 기준으로 판단한 것이라,
  혹시 직접 추가로 참조하신 테이블이 DROP 목록에 있다면 아래
  drop_list에서 그 이름만 빼고 실행하시면 됩니다.
=============================================================*/

libname proj "/home/student/open";

%let drop_list =
    CP_거래건수 CP_고유고객수 CP_총마케팅비 CP_총매출액 CP_쿠폰사용률
    CP_평균단가 CP_평균배송료
    PRELIM_MEAN PRELIM_OUT CLUSTER_TREE
    CUSTOMER_FEATURES_LOG CUSTOMER_FEATURES_STD CUSTOMER_CLUSTERED
    CUSTOMER_NO_PURCHASE
    SALES_EXCLUDED SALES_MONTH
    MKT_SORTED MKT_DATE_CNT
    PRICE_PCTL SHIPPING_PCTL SHIPPING_PER_ORDER SHIPPING_DAILY
    SHIPPING_OUTLIER_CANDIDATES
    DAILY_AGG DAILY_AGG_CORE DAILY_AGG_TMP
    COHORT_BASE COHORT_GRID COHORT_SIZE COHORT_RETENTION_RAW COHORT_ACTIVITY
    MONTHLY_ACTIVITY COUPON_RATE_CHECK
    PERIOD_SEQ PAIR_COUNT SUPPORT_SINGLE BASKET
    CLUSTER_CATEGORY
    ORDER_TOTAL RFM_BASE RFM_CORE
    AVG_ORDER_VALUE AVG_SHIPPING
;

/* ============================= PART A. 삭제 대상 목록 확인 (안전 - 아무것도 안 지움) ============================= */

data work.drop_names;
    length 이름 $32;
    do i = 1 to countw("&drop_list");
        이름 = upcase(scan("&drop_list", i));
        output;
    end;
    keep 이름;
run;

proc sql;
    create table work.drop_check as
    select a.memname as 테이블명, a.nobs as 행수, a.nvar as 열수
    from dictionary.tables as a
    where a.libname = "PROJ"
      and upcase(a.memname) in (select 이름 from work.drop_names)
    order by a.memname;
quit;

proc print data=work.drop_check noobs;
    title "A-1. 실제로 존재하며 삭제될 테이블 목록 (drop_list 중 존재하는 것만 - 나머지는 이미 없는 이름이라 자동 제외됨)";
run;
title;

proc sql noprint;
    select count(*) into :ndrop from work.drop_check;
quit;
%put NOTE: 삭제 대상으로 확인된 테이블 수 = &ndrop / drop_list에 적은 전체 후보 수 = %sysfunc(countw(&drop_list));

/* PART A 결과(위 표)가 예상과 맞는지 확인한 뒤에만 아래 PART B로 진행하세요 */


/* ============================= PART B. 실제 삭제 (되돌릴 수 없음) =============================
   아래 두 줄 앞뒤의 별표-슬래시 주석 기호를 지우고 실행하면 실제로 삭제됩니다.

proc datasets library=proj nolist;
    delete &drop_list;
quit;

   ============================================================================================= */

%put NOTE: PART B는 기본적으로 주석 처리되어 있어 아무것도 삭제되지 않았습니다.;
%put NOTE: 위 A-1 표를 확인하신 뒤, PART B 블록의 주석을 해제하고 다시 실행하세요.;
