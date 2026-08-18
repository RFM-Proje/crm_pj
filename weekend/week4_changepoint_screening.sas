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
        drop i;
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
------------------------------------------------------------- */
%macro plot_metric(var=);
    ods graphics / imagename="&var." imagefmt=png;
    proc sgplot data=proj.cp_&var.;
        series x=날짜 y=&var. / lineattrs=(color=lightblue thickness=1) legendlabel="일별 값";
        series x=날짜 y=&var._MA7 / lineattrs=(color=orange thickness=2) legendlabel="7일 이동평균";
        scatter x=날짜 y=&var. / group=변화점후보
                                  markerattrs=(symbol=circlefilled size=8)
                                  filledoutlinedmarkers
                                  legendlabel="변화점 후보";
        xaxis label="날짜" grid;
        yaxis label="&var." grid;
        title "&var. 일별 추이 및 변화점 후보";
    run;
    title;
%mend;

%plot_metric(var=총매출액);
%plot_metric(var=거래건수);
%plot_metric(var=평균단가);
%plot_metric(var=평균배송료);
%plot_metric(var=쿠폰사용률);
%plot_metric(var=고유고객수);
%plot_metric(var=총마케팅비);


/* -------------------------------------------------------------
   5. (선택) 여러 지표를 한번에 스크리닝 - PROC SGPANEL
------------------------------------------------------------- */
proc sql;
    create table proj.daily_long as
    select 날짜, "총매출액" as 지표, 총매출액 as 값 from proj.daily_agg_final
    outer union corr
    select 날짜, "거래건수" as 지표, 거래건수 as 값 from proj.daily_agg_final
    outer union corr
    select 날짜, "평균단가" as 지표, 평균단가 as 값 from proj.daily_agg_final
    outer union corr
    select 날짜, "평균배송료" as 지표, 평균배송료 as 값 from proj.daily_agg_final
    outer union corr
    select 날짜, "쿠폰사용률" as 지표, 쿠폰사용률 as 값 from proj.daily_agg_final
    outer union corr
    select 날짜, "고유고객수" as 지표, 고유고객수 as 값 from proj.daily_agg_final
    outer union corr
    select 날짜, "총마케팅비" as 지표, 총마케팅비 as 값 from proj.daily_agg_final;
quit;

ods graphics / imagename="daily_screening_panel" imagefmt=png;
proc sgpanel data=proj.daily_long;
    panelby 지표 / columns=2 rows=4 novarname;
    series x=날짜 y=값;
    rowaxis label="";
    colaxis label="날짜" grid;
    title "지표별 일별 추이 한눈에 스크리닝";
run;
title;


/* -------------------------------------------------------------
   6. ODS 목적지 원복 - 결과 탭에서 다시 보이게 복구
------------------------------------------------------------- */
ods listing close;
ods html5;
