/*=============================================================
  STAGE 3. 행동 패턴 탐지 + 코호트/연관분석
  = week4_changepoint_screening.sas + week5_cohort_association.sas
  (week5 원본 최상단의 디버그용 잔여 코드 - sashelp.class 산점도 -
   는 파이프라인과 무관해 병합 시 제외함)
  전제조건: STAGE 1, STAGE 2 실행 완료
  (proj.sales_with_disc, proj.mkt_raw, proj.customer_segments 필요)
  산출물: proj.daily_agg_final, proj.cp_*, proj.cohort_retention,
          proj.assoc_rules_manual, proj.cluster_category_top5
=============================================================*/

/* ============================= PART A. 일별 지표 변화점(급변구간) 탐지 ============================= */
/*=============================================================
  WEEK 4. 일별 지표 스크리닝 및 변화점(급변 구간) 탐지
  - 목적: 문제정의 단계에서 "언제 갑자기 꺾이는가"를 데이터로 찾기
  - 전제조건: 이 스크립트를 돌리기 전, 같은 세션에서
              week1_data_cleaning.sas 와
              week2_rfm_derived_수정.sas 가 먼저 실행되어
              proj.sales_with_disc, proj.shipping_per_order,
              proj.mkt_raw 가 이미 존재해야 함
              (proc datasets library=proj; run; 으로 확인 가능)

  [이전 버전 대비 수정 사항]
  1) 원본 CSV를 다시 import하지 않음 → week1에서 이미 정제된
     proj.sales_with_disc, week2에서 이미 임포트된 proj.mkt_raw를
     그대로 재사용 (파이프라인 일관성 확보, 이상치 재유입 방지)
  2) libname 경로를 week1~3과 동일하게 "/home/student/open"으로 통일
  3) 평균배송료를 sales_with_disc(line-item 단위)가 아니라
     week2에서 만든 shipping_per_order(주문 단위)로 계산
     → 다품목 주문의 배송료 중복 반영 문제 해결
=============================================================*/

libname proj "/home/student/open";

/* -------------------------------------------------------------
   0. PNG 저장 목적지 설정
   [주의] 반드시 아래쪽 proc sgplot/sgpanel 호출보다
          "먼저" 실행되어 있어야 함. 순서가 바뀌면
          그림은 정상적으로 그려지지만 SAS Studio 기본
          임시폴더(SASWORK)에 저장되고 plots 폴더는 비어있게 됨
------------------------------------------------------------- */
options dlcreatedir;
libname _tmp "/home/student/open/plots";
libname _tmp clear;

ods _all_ close;
ods listing gpath="/home/student/open/plots";
ods graphics / reset=all imagefmt=png width=1200px height=500px;


/* -------------------------------------------------------------
   1. 일별 집계 테이블 생성
      - 거래건수, 총수량, 총매출액, 평균단가, 쿠폰사용률,
        고유고객수는 sales_with_disc(line-item 단위) 기준
      - 평균배송료만 shipping_per_order(주문 단위) 기준으로 별도 계산
------------------------------------------------------------- */
proc sql;
    create table proj.daily_agg_core as
    select 거래날짜_num as 날짜 format=yymmdd10.,
           count(distinct 거래ID)                                    as 거래건수,
           sum(수량)                                                 as 총수량,
           sum(거래금액)                                             as 총매출액,
           mean(평균금액)                                            as 평균단가,
           mean(case when 쿠폰상태="Used" then 1 else 0 end)         as 쿠폰사용률,
           count(distinct 고객ID)                                    as 고유고객수
    from proj.sales_with_disc
    group by 거래날짜_num
    order by 거래날짜_num;
quit;

/* 주문 단위 배송료를 날짜별로 다시 집계하려면 거래날짜 정보가 필요 -
   sales_with_disc에서 거래ID당 거래날짜를 1건만 붙여서 사용 */
proc sql;
    create table proj.shipping_daily as
    select 거래날짜_num as 날짜 format=yymmdd10.,
           mean(배송료) as 평균배송료
    from (
        select distinct 거래ID, 거래날짜_num, 배송료
        from proj.sales_with_disc
    )
    group by 거래날짜_num
    order by 거래날짜_num;
quit;

/* 일별 지표 + 배송료 + 마케팅비 병합 */
proc sql;
    create table proj.daily_agg as
    select a.*,
           b.평균배송료,
           c.오프라인비용,
           c.온라인비용,
           c.오프라인비용 + c.온라인비용 as 총마케팅비
    from proj.daily_agg_core as a
    left join proj.shipping_daily as b
        on a.날짜 = b.날짜
    left join proj.mkt_raw as c
        on a.날짜 = c.날짜
    order by a.날짜;
quit;


/* -------------------------------------------------------------
   2. 7일 이동평균 계산 (base SAS, DATA step + array 사용)
   [핵심 버그 수정 - 진짜 원인 발견]
   buf1~buf7(이동평균 계산용 임시 버퍼)을 drop하지 않아서
   proj.daily_agg에 그대로 남아있었음. 이 매크로가 지표마다
   반복 호출되는 구조라, 두 번째 호출부터는 "set proj.daily_agg"
   시점에 직전 지표가 남긴 buf1~buf7 값을 그대로 물려받아 이동
   평균 계산이 오염됨(예: 거래건수의 MA7에 총매출액 버퍼 값이
   섞여 들어감). "drop i;" -> "drop i buf1-buf7;"로 수정하여
   매 호출마다 버퍼가 확실히 초기화되도록 함. 지금까지 그래프가
   지표마다 다른 스케일로 깨져 보였던 근본 원인이 바로 이것임
   (ODS/캐시 문제가 아니었음)
------------------------------------------------------------- */
%macro add_rolling_mean(var=);
    data proj.daily_agg_tmp;
        set proj.daily_agg;
        retain buf1-buf7 0;
        array buf{7} buf1-buf7;
        do i = 1 to 6;
            buf{i} = buf{i+1};
        end;
        buf{7} = &var.;

        if _n_ >= 7 then do;
            &var._MA7 = mean(of buf1-buf7);
        end;
        drop i buf1-buf7;
    run;

    data proj.daily_agg;
        set proj.daily_agg_tmp;
    run;
%mend;

%add_rolling_mean(var=총매출액);
%add_rolling_mean(var=거래건수);
%add_rolling_mean(var=평균단가);
%add_rolling_mean(var=평균배송료);
%add_rolling_mean(var=쿠폰사용률);
%add_rolling_mean(var=고유고객수);
%add_rolling_mean(var=총마케팅비);

data proj.daily_agg_final;
    set proj.daily_agg;
run;


/* -------------------------------------------------------------
   3. 급변 구간(변화점 후보) 자동 탐지
      - 이동평균의 전일대비 차분(diff)을 표준화(z-score)해서
      - |z| > 2 인 지점을 "급변 후보"로 플래그
------------------------------------------------------------- */
%macro flag_changepoints(var=);
    data _tmp;
        set proj.daily_agg_final;
        diff_&var. = dif(&var._MA7);
    run;

    proc means data=_tmp noprint;
        var diff_&var.;
        output out=_stat mean=diff_mean std=diff_std;
    run;

    data proj.cp_&var.;
        if _n_ = 1 then set _stat;
        set _tmp;
        if diff_std > 0 then z_&var. = (diff_&var. - diff_mean) / diff_std;
        else z_&var. = .;
        if abs(z_&var.) > 2 then 변화점후보 = 1;
        else 변화점후보 = 0;
        keep 날짜 &var. &var._MA7 z_&var. 변화점후보;
    run;

    proc print data=proj.cp_&var.(where=(변화점후보=1));
        title "변화점 후보 - &var.";
        var 날짜 &var. z_&var.;
    run;
    title;
%mend;

%flag_changepoints(var=총매출액);
%flag_changepoints(var=거래건수);
%flag_changepoints(var=평균단가);
%flag_changepoints(var=평균배송료);
%flag_changepoints(var=쿠폰사용률);
%flag_changepoints(var=고유고객수);
%flag_changepoints(var=총마케팅비);


/* -------------------------------------------------------------
   4. 시각화 - 지표별 일별 값 + 7일 이동평균 + 변화점 표시
   [참고] 그동안 그림이 지표마다 뒤섞여 보였던 진짜 원인은
   2번 섹션의 buf1-buf7 누수 버그였음(이미 수정 완료). 파일명이나
   ODS 방식 자체는 문제가 아니었으므로, 이번엔 보기 편하도록
   지표명 그대로 파일명으로 사용함
------------------------------------------------------------- */

/* --- 총매출액 --- */
ods _all_ close;
ods listing gpath="/home/student/open/plots";
ods graphics / reset=all imagefmt=png imagename="총매출액";
proc sgplot data=proj.cp_총매출액;
    series x=날짜 y=총매출액 / lineattrs=(color=lightblue thickness=1) legendlabel="일별 값";
    series x=날짜 y=총매출액_MA7 / lineattrs=(color=orange thickness=2) legendlabel="7일 이동평균";
    scatter x=날짜 y=총매출액 / group=변화점후보
                                markerattrs=(symbol=circlefilled size=8)
                                filledoutlinedmarkers
                                legendlabel="변화점 후보";
    xaxis label="날짜" grid;
    yaxis label="총매출액" grid;
    title "총매출액 일별 추이 및 변화점 후보";
run;
title;
ods listing close;
ods html5;

/* --- 거래건수 --- */
ods _all_ close;
ods listing gpath="/home/student/open/plots";
ods graphics / reset=all imagefmt=png imagename="거래건수";
proc sgplot data=proj.cp_거래건수;
    series x=날짜 y=거래건수 / lineattrs=(color=lightblue thickness=1) legendlabel="일별 값";
    series x=날짜 y=거래건수_MA7 / lineattrs=(color=orange thickness=2) legendlabel="7일 이동평균";
    scatter x=날짜 y=거래건수 / group=변화점후보
                                markerattrs=(symbol=circlefilled size=8)
                                filledoutlinedmarkers
                                legendlabel="변화점 후보";
    xaxis label="날짜" grid;
    yaxis label="거래건수" grid;
    title "거래건수 일별 추이 및 변화점 후보";
run;
title;
ods listing close;
ods html5;

/* --- 평균단가 --- */
ods _all_ close;
ods listing gpath="/home/student/open/plots";
ods graphics / reset=all imagefmt=png imagename="평균단가";
proc sgplot data=proj.cp_평균단가;
    series x=날짜 y=평균단가 / lineattrs=(color=lightblue thickness=1) legendlabel="일별 값";
    series x=날짜 y=평균단가_MA7 / lineattrs=(color=orange thickness=2) legendlabel="7일 이동평균";
    scatter x=날짜 y=평균단가 / group=변화점후보
                                markerattrs=(symbol=circlefilled size=8)
                                filledoutlinedmarkers
                                legendlabel="변화점 후보";
    xaxis label="날짜" grid;
    yaxis label="평균단가" grid;
    title "평균단가 일별 추이 및 변화점 후보";
run;
title;
ods listing close;
ods html5;

/* --- 평균배송료 --- */
ods _all_ close;
ods listing gpath="/home/student/open/plots";
ods graphics / reset=all imagefmt=png imagename="평균배송료";
proc sgplot data=proj.cp_평균배송료;
    series x=날짜 y=평균배송료 / lineattrs=(color=lightblue thickness=1) legendlabel="일별 값";
    series x=날짜 y=평균배송료_MA7 / lineattrs=(color=orange thickness=2) legendlabel="7일 이동평균";
    scatter x=날짜 y=평균배송료 / group=변화점후보
                                  markerattrs=(symbol=circlefilled size=8)
                                  filledoutlinedmarkers
                                  legendlabel="변화점 후보";
    xaxis label="날짜" grid;
    yaxis label="평균배송료" grid;
    title "평균배송료 일별 추이 및 변화점 후보";
run;
title;
ods listing close;
ods html5;

/* --- 쿠폰사용률 --- */
ods _all_ close;
ods listing gpath="/home/student/open/plots";
ods graphics / reset=all imagefmt=png imagename="쿠폰사용률";
proc sgplot data=proj.cp_쿠폰사용률;
    series x=날짜 y=쿠폰사용률 / lineattrs=(color=lightblue thickness=1) legendlabel="일별 값";
    series x=날짜 y=쿠폰사용률_MA7 / lineattrs=(color=orange thickness=2) legendlabel="7일 이동평균";
    scatter x=날짜 y=쿠폰사용률 / group=변화점후보
                                  markerattrs=(symbol=circlefilled size=8)
                                  filledoutlinedmarkers
                                  legendlabel="변화점 후보";
    xaxis label="날짜" grid;
    yaxis label="쿠폰사용률" grid;
    title "쿠폰사용률 일별 추이 및 변화점 후보";
run;
title;
ods listing close;
ods html5;

/* --- 고유고객수 --- */
ods _all_ close;
ods listing gpath="/home/student/open/plots";
ods graphics / reset=all imagefmt=png imagename="고유고객수";
proc sgplot data=proj.cp_고유고객수;
    series x=날짜 y=고유고객수 / lineattrs=(color=lightblue thickness=1) legendlabel="일별 값";
    series x=날짜 y=고유고객수_MA7 / lineattrs=(color=orange thickness=2) legendlabel="7일 이동평균";
    scatter x=날짜 y=고유고객수 / group=변화점후보
                                  markerattrs=(symbol=circlefilled size=8)
                                  filledoutlinedmarkers
                                  legendlabel="변화점 후보";
    xaxis label="날짜" grid;
    yaxis label="고유고객수" grid;
    title "고유고객수 일별 추이 및 변화점 후보";
run;
title;
ods listing close;
ods html5;

/* --- 총마케팅비 --- */
ods _all_ close;
ods listing gpath="/home/student/open/plots";
ods graphics / reset=all imagefmt=png imagename="총마케팅비";
proc sgplot data=proj.cp_총마케팅비;
    series x=날짜 y=총마케팅비 / lineattrs=(color=lightblue thickness=1) legendlabel="일별 값";
    series x=날짜 y=총마케팅비_MA7 / lineattrs=(color=orange thickness=2) legendlabel="7일 이동평균";
    scatter x=날짜 y=총마케팅비 / group=변화점후보
                                  markerattrs=(symbol=circlefilled size=8)
                                  filledoutlinedmarkers
                                  legendlabel="변화점 후보";
    xaxis label="날짜" grid;
    yaxis label="총마케팅비" grid;
    title "총마케팅비 일별 추이 및 변화점 후보";
run;
title;
ods listing close;
ods html5;


/* -------------------------------------------------------------
   6. ODS 목적지 원복 - 결과 탭에서 다시 보이게 복구
------------------------------------------------------------- */
ods listing close;
ods html5;

/* ============================= PART B. 코호트 리텐션 + 연관분석(Apriori 방식) + 군집별 Top5 카테고리 ============================= */
/*=============================================================
  WEEK 5. 코호트 · 연관분석 (보조 인사이트)
  입력: proj.sales_with_disc (2주차), proj.customer_segments (3주차)
  산출물:
    1) 코호트 리텐션 히트맵 (첫구매월 기준)
    2) 전체 연관 규칙 (카테고리 조합, 지지도/신뢰도/향상도)
    3) 군집별 상위 구매 카테고리 Top5 (풀 교차분석 지양)

  [코호트 기준 관련 참고]
  Customer_info에 실제 가입일(캘린더 날짜)이 없고 가입기간(누적
  개월수)만 존재함. 따라서 "가입월" 대신 고객의 첫구매월을
  코호트 기준(Acquisition Cohort)으로 사용함 - 이커머스
  리텐션 분석에서 통상적으로 쓰이는 대안 방식

  [실행 전 필수 확인 - K=6 반영 여부]
  PART 3(군집별 Top5)는 proj.customer_segments를 그대로 참조함.
  이 파일 실행 전, 반드시 최신 K=6 기준으로 확정된
  week3_clustering_수정.sas를 먼저(재)실행해서 customer_segments가
  K=6 결과로 갱신되어 있는지 확인할 것. 코드 자체는 K값과 무관하게
  Cluster_ID 컬럼만 참조하므로 수정 불필요, 실행 순서만 주의
=============================================================*/

libname proj "/home/student/open";


/* =================================================================
   PART 1. 코호트 리텐션 히트맵
================================================================= */

/* -------------------------------------------------------------
   1-1. 고객별 첫구매월 = 코호트월 산출
------------------------------------------------------------- */
proc sql;
    create table proj.cohort_base as
    select 고객ID,
           intnx('month', min(거래날짜_num), 0) as 코호트월 format=yymmn6.
    from proj.sales_with_disc
    group by 고객ID;
quit;

/* -------------------------------------------------------------
   1-2. 고객x월 단위 활동(구매) 여부 테이블
------------------------------------------------------------- */
proc sql;
    create table proj.monthly_activity as
    select distinct 고객ID,
           intnx('month', 거래날짜_num, 0) as 활동월 format=yymmn6.
    from proj.sales_with_disc;
quit;

/* -------------------------------------------------------------
   1-3. 코호트월 대비 경과개월(Period) 계산
------------------------------------------------------------- */
proc sql;
    create table proj.cohort_activity as
    select a.고객ID,
           b.코호트월,
           a.활동월,
           intck('month', b.코호트월, a.활동월) as 경과개월
    from proj.monthly_activity as a
    inner join proj.cohort_base as b
        on a.고객ID = b.고객ID;
quit;

/* -------------------------------------------------------------
   1-4. 코호트 크기(월별 최초 유입 고객수) 산출
------------------------------------------------------------- */
proc sql;
    create table proj.cohort_size as
    select 코호트월,
           count(*) as 코호트고객수
    from proj.cohort_base
    group by 코호트월;
quit;

/* -------------------------------------------------------------
   1-5. 코호트월 x 경과개월 별 잔존 고객수 -> 리텐션율(%)
------------------------------------------------------------- */
proc sql;
    create table proj.cohort_retention_raw as
    select a.코호트월,
           a.경과개월,
           count(distinct a.고객ID) as 잔존고객수,
           b.코호트고객수,
           calculated 잔존고객수 / b.코호트고객수 * 100 as 리텐션율
    from proj.cohort_activity as a
    inner join proj.cohort_size as b
        on a.코호트월 = b.코호트월
    group by a.코호트월, a.경과개월, b.코호트고객수
    order by a.코호트월, a.경과개월;
quit;

/* -------------------------------------------------------------
   1-5-1. [수정] 활동이 아예 없었던 (코호트월, 경과개월) 조합은
   cohort_retention_raw에 행 자체가 없어서 히트맵에서 빈칸으로
   보임 -> "0%"와 "결측"이 구분 안 되는 문제.
   전체 (코호트월 x 가능한 경과개월) 격자를 만들고 활동 없는
   조합은 리텐션율 0으로 명시적으로 채움
------------------------------------------------------------- */
proc sql noprint;
    select max(경과개월) into :max_period
    from proj.cohort_retention_raw;
quit;

/* 0~max_period까지의 경과개월 시퀀스 테이블 */
data proj.period_seq;
    do 경과개월 = 0 to &max_period.;
        output;
    end;
run;

/* 코호트월 x 경과개월 전체 격자 (cross join) */
proc sql;
    create table proj.cohort_grid as
    select a.코호트월, b.경과개월
    from (select distinct 코호트월 from proj.cohort_base) as a
    cross join proj.period_seq as b;
quit;

proc sql;
    create table proj.cohort_retention as
    select g.코호트월,
           g.경과개월,
           coalesce(r.잔존고객수, 0) as 잔존고객수,
           s.코호트고객수,
           /* [중요] 코호트월+경과개월이 데이터 관측 종료 시점(2019-12)을
              넘어가면 "0%"가 아니라 "아직 관찰 불가능"임 - 이 둘을
              섞으면 늦게 들어온 코호트가 실제보다 리텐션이 나쁜 것처럼
              왜곡되어 보임(우측 절단 문제) */
           case when intnx('month', g.코호트월, g.경과개월) <= "31DEC2019"d
                then 1 else 0 end as 관측가능,
           case when intnx('month', g.코호트월, g.경과개월) <= "31DEC2019"d
                then coalesce(r.리텐션율, 0)
                else .
           end as 리텐션율
    from proj.cohort_grid as g
    inner join proj.cohort_size as s
        on g.코호트월 = s.코호트월
    left join proj.cohort_retention_raw as r
        on g.코호트월 = r.코호트월 and g.경과개월 = r.경과개월
    order by g.코호트월, g.경과개월;
quit;

/* -------------------------------------------------------------
   1-6. 리텐션 히트맵 시각화
   x=경과개월(0,1,2...), y=코호트월, 색상=리텐션율(%)
   [수정] 관측 불가능 구간(늦게 들어온 코호트의 미래 시점)은
   결측(.)이라 자동으로 빈칸 처리됨 - 진짜 0%(파란색 계열 중
   가장 옅은 색)와 구분됨
------------------------------------------------------------- */
proc sgplot data=proj.cohort_retention;
    heatmapparm x=경과개월 y=코호트월 colorresponse=리텐션율 /
        colormodel=(cxf0f0f0 cx4393c3 cx2166ac);
    xaxis label="경과개월(코호트월 이후)" integer;
    yaxis label="코호트월(첫구매월)" discreteorder=data reverse;
    title "코호트 리텐션 히트맵 (첫구매월 기준, 단위: %)";
    footnote "빈칸 = 관측기간 부족으로 아직 확인 불가능한 구간 (0퍼센트와는 다름)";
run;
title;
footnote;

/* 숫자로도 확인 - 발표자료용 표. 관측가능 컬럼으로 0퍼센트와
   관측불가를 명확히 구분해서 표시 */
proc print data=proj.cohort_retention;
    var 코호트월 경과개월 코호트고객수 잔존고객수 리텐션율 관측가능;
    title "코호트 리텐션 표 (숫자, 관측가능=0이면 아직 확인 불가능한 구간)";
run;
title;


/* =================================================================
   PART 2. 연관분석 - 전체 규칙
================================================================= */

/* -------------------------------------------------------------
   2-0. 주문(거래ID) x 제품카테고리 - 중복 제거된 basket 테이블
   [존재 이유] sales_with_disc는 제품ID 단위라 같은 카테고리
   상품을 여러 개 담으면 중복 행이 생김. 연관분석은 "그 주문에
   해당 카테고리가 있었는가(0/1)"만 필요하므로 distinct 처리
------------------------------------------------------------- */
proc sql;
    create table proj.basket as
    select distinct 거래ID, 제품카테고리
    from proj.sales_with_disc;
quit;

proc sql noprint;
    select count(distinct 거래ID) into :total_orders
    from proj.basket;
quit;
%put 전체 주문수 = &total_orders;


/* -------------------------------------------------------------
   2-1. [옵션 A] PROC ASSOC 시도 (진짜 Apriori 알고리즘, 3개 이상
   조합까지 지원 - maxitems=3으로 설정)
   [주의] PROC ASSOC은 SAS Enterprise Miner 라이선스가 필요한
   프로시저입니다. 사용 중인 SAS Studio(OnDemand for Academics 등)에는
   보통 포함되어 있지 않아 아래 코드가 "PROCEDURE ASSOC not
   found" 에러로 실패할 수 있습니다. 에러가 나면 2-2(옵션 B,
   PROC SQL 수동 계산 - 2개 조합까지만)로 넘어가거나, 3개 이상
   조합까지 필요하면 별도 제공된 수동 Apriori 구현 코드를 쓰세요.
------------------------------------------------------------- */
proc dmdb data=proj.basket dmdbcat=proj.basket_dmdb;
    id 거래ID;
    class 제품카테고리;
run;

proc assoc data=proj.basket dmdbcat=proj.basket_dmdb
           out=proj.assoc_rules
           pctsup=1
           items=3;
    target 제품카테고리;
    id 거래ID;
run;

/* [확인용] 실제 컬럼명을 로그에 직접 출력 (Results 탭 HTML이 아니라
   텍스트 로그에서 바로 확인 가능하도록 dictionary.columns 사용) */
proc sql noprint;
    select name into :rule_vars separated by ', '
    from dictionary.columns
    where libname="PROJ" and memname="ASSOC_RULES";
quit;
%put NOTE: [확인용] proj.assoc_rules 실제 컬럼 목록 = &rule_vars;

proc contents data=proj.assoc_rules varnum;
    title "[확인용] proj.assoc_rules 실제 컬럼명";
run;
title;

proc print data=proj.assoc_rules(obs=10);
    title "[확인용] proj.assoc_rules 미리보기 (정렬 전)";
run;
title;

/* [확인용] 컬럼명을 확인하기 전까지는 정렬 없이 그대로 출력.
   위 %put 로그의 &rule_vars. 목록을 보고, 향상도(lift)에 해당하는
   실제 컬럼명을 확인한 뒤 이 자리에 "by descending <실제컬럼명>;"으로
   바꿔서 정렬하면 됨 */
proc print data=proj.assoc_rules;
    title "PROC ASSOC 연관규칙 전체 58건 (정렬 전 - 컬럼명 확인 후 정렬 예정)";
run;
title;


/* -------------------------------------------------------------
   2-2. [옵션 B] PROC SQL 수동 연관분석 (기본 사용 권장)
   지지도(Support), 신뢰도(Confidence), 향상도(Lift) 직접 계산
   A -> B : A를 산 주문 중 B도 같이 산 비율
------------------------------------------------------------- */

/* 카테고리별 단일 지지도 */
proc sql;
    create table proj.support_single as
    select 제품카테고리,
           count(distinct 거래ID) as 주문수,
           calculated 주문수 / &total_orders as 지지도
    from proj.basket
    group by 제품카테고리;
quit;

/* 카테고리 쌍(A,B) 동시 등장 주문수 - 자기조인, A<B로 중복 방지 */
proc sql;
    create table proj.pair_count as
    select a.제품카테고리 as 카테고리A,
           b.제품카테고리 as 카테고리B,
           count(distinct a.거래ID) as 동시주문수
    from proj.basket as a
    inner join proj.basket as b
        on a.거래ID = b.거래ID and a.제품카테고리 < b.제품카테고리
    group by a.제품카테고리, b.제품카테고리;
quit;

/* A->B, B->A 양방향 규칙으로 펼치고 지지도/신뢰도/향상도 계산 */
proc sql;
    create table proj.assoc_rules_manual as
    select 카테고리A as 선행, 카테고리B as 후행,
           동시주문수,
           동시주문수 / &total_orders as 지지도_AB,
           s1.지지도 as 지지도_A,
           s2.지지도 as 지지도_B,
           (동시주문수 / &total_orders) / s1.지지도 as 신뢰도,
           ((동시주문수 / &total_orders) / s1.지지도) / s2.지지도 as 향상도
    from proj.pair_count as p
    inner join proj.support_single as s1 on p.카테고리A = s1.제품카테고리
    inner join proj.support_single as s2 on p.카테고리B = s2.제품카테고리

    outer union corr

    select 카테고리B as 선행, 카테고리A as 후행,
           동시주문수,
           동시주문수 / &total_orders as 지지도_AB,
           s2.지지도 as 지지도_A,
           s1.지지도 as 지지도_B,
           (동시주문수 / &total_orders) / s2.지지도 as 신뢰도,
           ((동시주문수 / &total_orders) / s2.지지도) / s1.지지도 as 향상도
    from proj.pair_count as p
    inner join proj.support_single as s1 on p.카테고리A = s1.제품카테고리
    inner join proj.support_single as s2 on p.카테고리B = s2.제품카테고리;
quit;

proc sort data=proj.assoc_rules_manual;
    by descending 향상도;
run;

/* [수정] 지지도 필터 없는 표를 먼저 보여주면 희귀 조합의 극단적
   향상도가 상위권을 오염시켜 첫인상이 왜곡될 수 있음 -> 필터링된
   (지지도 1% 이상) 안정적인 표를 먼저 보여주는 순서로 변경 */
proc print data=proj.assoc_rules_manual(where=(지지도_AB >= 0.01) obs=20);
    var 선행 후행 동시주문수 지지도_AB 신뢰도 향상도;
    title "연관규칙 상위 20개 (지지도 1% 이상, 향상도 기준) - 기본 확인용";
run;
title;

/* 참고용 - 필터 없는 전체 결과 (희귀 조합 포함, 해석 시 주의) */
proc print data=proj.assoc_rules_manual(obs=20);
    var 선행 후행 동시주문수 지지도_AB 신뢰도 향상도;
    title "참고: 연관규칙 상위 20개 (향상도 기준, 최소 지지도 필터 없음 - 희귀 조합 포함 주의)";
run;
title;


/* =================================================================
   PART 3. 군집별 상위 구매 카테고리 Top5
   [존재 이유] 8개 군집 x 20개 카테고리 풀 교차표는 정보량이
   과해서 발표자료에 부적합. 군집 성격 해석에 필요한 "이 군집이
   특히 많이 사는 카테고리"만 Top5로 압축
================================================================= */

/* 군집 x 카테고리 별 구매건수 집계 */
proc sql;
    create table proj.cluster_category as
    select b.Cluster_ID,
           a.제품카테고리,
           count(distinct a.거래ID) as 구매건수
    from proj.sales_with_disc as a
    inner join proj.customer_segments as b
        on a.고객ID = b.고객ID
    group by b.Cluster_ID, a.제품카테고리
    order by b.Cluster_ID, 구매건수 descending;
quit;

/* 군집 내 순위 부여 후 Top5만 추출 */
data proj.cluster_category_top5;
    set proj.cluster_category;
    by Cluster_ID descending 구매건수;
    retain 순위;
    if first.Cluster_ID then 순위 = 1;
    else 순위 + 1;
    if 순위 <= 5;
run;

proc print data=proj.cluster_category_top5;
    var Cluster_ID 순위 제품카테고리 구매건수;
    title "군집별 상위 구매 카테고리 Top5";
run;
title;

/* 발표용 시각화 - 군집별 Top5 막대그래프 */
proc sgpanel data=proj.cluster_category_top5;
    panelby Cluster_ID / columns=2 rows=4 novarname;
    hbar 제품카테고리 / response=구매건수 categoryorder=respdesc;
    rowaxis label="";
    colaxis label="구매건수";
    title "군집별 상위 구매 카테고리 Top5";
run;
title;
