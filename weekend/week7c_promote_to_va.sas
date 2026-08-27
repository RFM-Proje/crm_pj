/*=============================================================
  week7 최종등급 결과를 SAS VA용 CAS 테이블로 승격(promote)

  전제조건: week7_final_tier_design.sas 실행 완료로
            proj.customer_final_tier 존재해야 함.

  PROMOTE의 의미: 이 CAS 세션이 끝나도 테이블이 계속 메모리에 남아서
  SAS VA(별도 세션)에서 데이터소스로 바로 잡을 수 있게 됨.
  (일반 CAS 세션 스코프 테이블은 세션 끝나면 사라져서 VA에서 안 보임)
=============================================================*/

libname proj "/home/student/open";

%if %sysfunc(sessfound(mysession)) = 0 %then %do;
    cas mysession;
%end;
libname mycas cas caslib="casuser";

/* 최종등급 테이블 승격 */
proc casutil;
    load data=proj.customer_final_tier
         outcaslib="casuser"
         casout="customer_final_tier"
         promote;
run;

/* 참고용 - 이탈확률/변수까지 포함된 상세 테이블도 승격 (VA에서 산점도/히스토그램용) */
proc casutil;
    load data=proj.churn_split_v2
         outcaslib="casuser"
         casout="churn_split_v2"
         promote;
run;

/* 승격 확인 */
proc casutil;
    list tables incaslib="casuser";
run;

/* [주의] VA에서 데이터 탐색기(Explorer) 열었을 때 casuser 캐스립 밑에
   CUSTOMER_FINAL_TIER, CHURN_SPLIT_V2 두 테이블이 보이면 성공.
   세션 종료해도 사라지지 않음 (promote 했으므로). */
