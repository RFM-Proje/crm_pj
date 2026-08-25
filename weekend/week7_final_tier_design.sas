/*=============================================================
  WEEK 7. 최종 등급 설계 및 실행 전략

  전제조건: week6d(수정판, proj.churn_scored_v2 저장 포함) 실행 완료 필요.
            proj.customer_segments (K=6 군집), proj.cluster_category_top5
            (5주차 연관분석 산출물) 존재해야 함.

  설계: 군집(Who) + 이탈위험등급(When) + 대표 연관구매카테고리(What)를
  결합해 최종 고객 등급을 만들고, 등급별 실행전략을 매핑함.

  [주의] proj.cluster_category_top5의 정확한 컬럼 구조를 모르는 상태로
  작성함. 아래 "0-2. 진단" 스텝 결과 보고 조정 필요할 가능성 높음.
=============================================================*/

libname proj "/home/student/open";


/* -------------------------------------------------------------
   0-1. [확인용] 필요한 원천 테이블들 존재/구조 확인
------------------------------------------------------------- */
proc contents data=proj.customer_segments varnum;
    title "0-1a. [확인용] customer_segments 구조 - Cluster_ID/고객ID 있는지";
run;
title;

proc contents data=proj.churn_scored_v2 varnum;
    title "0-1b. [확인용] churn_scored_v2 구조 - 고객ID/이탈확률 컬럼명 확인";
run;
title;


/* -------------------------------------------------------------
   0-2. [확인용] cluster_category_top5 구조 - What 차원 소스
------------------------------------------------------------- */
proc contents data=proj.cluster_category_top5 varnum;
    title "0-2a. [확인용] cluster_category_top5 컬럼 구조";
run;
title;

proc print data=proj.cluster_category_top5(obs=30);
    title "0-2b. [확인용] cluster_category_top5 내용 미리보기 - Cluster별 순서/랭킹 확인용";
run;
title;


/* -------------------------------------------------------------
   1. 이탈확률 컬럼 자동탐지 (매번 반복되는 패턴이라 매크로 재사용)
------------------------------------------------------------- */
%macro find_prob_var(dsn=, outvar=);
    %global &outvar;
    proc contents data=&dsn out=work._cols_&outvar(keep=name) noprint;
    run;
    proc sql noprint;
        select name into :&outvar trimmed
        from work._cols_&outvar
        where upcase(name) like 'P\_%1' escape '\';
    quit;
    %put NOTE: [find_prob_var] &dsn 에서 찾은 예측확률 컬럼 = %superq(&outvar);
%mend find_prob_var;

%find_prob_var(dsn=proj.churn_scored_v2, outvar=churn_pvar);


/* -------------------------------------------------------------
   2. Who + When 결합 - 군집 + 이탈위험등급(3분위)
------------------------------------------------------------- */
proc rank data=proj.churn_scored_v2 groups=3 out=work.churn_ranked;
    var &churn_pvar;
    ranks 이탈위험순위;
run;

data work.churn_ranked;
    set work.churn_ranked;
    length 이탈위험등급 $6;
    if 이탈위험순위 = 0 then 이탈위험등급 = "Low";
    else if 이탈위험순위 = 1 then 이탈위험등급 = "Medium";
    else if 이탈위험순위 = 2 then 이탈위험등급 = "High";
run;

proc sql;
    create table work.who_when as
    select a.고객ID, a.Cluster_ID, b.&churn_pvar as 이탈확률, b.이탈위험등급
    from proj.customer_segments as a
    inner join work.churn_ranked as b
      on a.고객ID = b.고객ID;
quit;

/* 군집 라벨 포맷 - 3주차 프로파일링 결과 기준 */
proc format;
    value clusterf
        1 = "배송이슈"
        2 = "이탈위험군"
        3 = "저관여"
        4 = "쿠폰의존"
        5 = "핵심고객"
        6 = "일반고객";
quit;


/* -------------------------------------------------------------
   3. What 차원 결합 - 군집별 대표(1순위) 연관구매 카테고리
   [가정] cluster_category_top5가 이미 군집별 순위 순서대로 정렬되어
   저장되어 있다고 가정 (PROC SORT는 stable이라 동순위 내 원래 순서 유지됨).
   실제로 안 맞으면 0-2 진단 결과 보고 수정.
------------------------------------------------------------- */
proc sort data=proj.cluster_category_top5 out=work.cat_sorted;
    by Cluster_ID;
run;

data work.cat_top1;
    set work.cat_sorted;
    by Cluster_ID;
    if first.Cluster_ID;
run;


/* -------------------------------------------------------------
   4. 최종 결합 - Who + When + What
------------------------------------------------------------- */
proc sql;
    create table proj.customer_final_tier as
    select a.고객ID, a.Cluster_ID,
           put(a.Cluster_ID, clusterf.) as 군집라벨,
           a.이탈확률, a.이탈위험등급,
           b.제품카테고리 as 대표카테고리
    from work.who_when as a
    left join work.cat_top1 as b
      on a.Cluster_ID = b.Cluster_ID;
quit;

/* 최종 등급명 생성 - 군집라벨 + 이탈위험등급 조합 */
data proj.customer_final_tier;
    set proj.customer_final_tier;
    length 최종등급 $30;
    최종등급 = catx("_", 군집라벨, 이탈위험등급);
run;

proc freq data=proj.customer_final_tier;
    tables 최종등급 / nocum;
    title "4-1. 최종 등급별 고객 분포 (18개 셀 = 6군집 x 3위험등급)";
run;
title;


/* -------------------------------------------------------------
   5. 등급별 실행전략 매핑
------------------------------------------------------------- */
data work.action_plan;
    length 군집라벨 $10 이탈위험등급 $6 실행전략 $60;
    input 군집라벨 $ 이탈위험등급 $ 실행전략 $60.;
    datalines;
핵심고객 Low VIP전용혜택_유지관리
핵심고객 Medium VIP이탈방지_개인화프로모션
핵심고객 High VIP긴급리텐션_1대1컨택
이탈위험군 Low 관계재형성_뉴스레터
이탈위험군 Medium 윈백쿠폰_발송
이탈위험군 High 긴급윈백쿠폰_대폭할인
쿠폰의존 Low 쿠폰의존관리_정상가유도
쿠폰의존 Medium 쿠폰의존관리_정상가유도
쿠폰의존 High 쿠폰재발송_이탈방지
배송이슈 Low 배송이슈케어_정기모니터링
배송이슈 Medium 배송비할인_리텐션
배송이슈 High 배송비할인_긴급리텐션
저관여 Low 저관여활성화_추천상품노출
저관여 Medium 저관여활성화_추천상품노출
저관여 High 자연이탈_저비용대응
일반고객 Low 일반유지_정기프로모션
일반고객 Medium 일반유지_정기프로모션
일반고객 High 일반이탈방지_쿠폰발송
;
run;

proc sql;
    create table proj.tier_action_summary as
    select a.군집라벨, a.이탈위험등급, count(*) as 고객수, b.실행전략
    from proj.customer_final_tier as a
    left join work.action_plan as b
      on a.군집라벨 = b.군집라벨 and a.이탈위험등급 = b.이탈위험등급
    group by a.군집라벨, a.이탈위험등급, b.실행전략
    order by a.군집라벨, a.이탈위험등급;
quit;

proc print data=proj.tier_action_summary;
    title "5-1. 등급별 고객수 + 실행전략 매핑표";
run;
title;


/* -------------------------------------------------------------
   6. [초안] ROI 추정 - 매우 러프한 방향성 추정치
   [주의] 정확한 CAC 계산 소스를 못 찾아서, Marketing_info 총비용을
   전체 고객수로 나눈 단순 평균으로 근사함. 정밀한 값 아님 - 방향성
   참고용으로만 사용할 것.
------------------------------------------------------------- */
proc sql;
    title "6-1. [초안] 대략적 CAC 추정 - 총마케팅비 / 전체고객수";
    select sum(오프라인비용 + 온라인비용) as 총마케팅비,
           (select count(distinct 고객ID) from proj.customer_segments) as 전체고객수,
           calculated 총마케팅비 / calculated 전체고객수 as 대략적_CAC format=8.0
    from proj.mkt_raw;
quit;
title;

proc sql;
    title "6-2. 이탈위험군(High) 규모 - 리텐션 캠페인 대상 예상 규모";
    select 군집라벨, count(*) as 대상고객수, mean(이탈확률) as 평균이탈확률 format=6.4
    from proj.customer_final_tier
    where 이탈위험등급 = "High"
    group by 군집라벨
    order by calculated 대상고객수 desc;
quit;
title;
