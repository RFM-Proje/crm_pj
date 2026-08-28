/****************************************************************
 0. 환경 설정, NOEXEC 리셋 및 그래프 저장 경로 지정
****************************************************************/
options validvarname=any; /* 한글 컬럼명 허용 */
options nosyntaxcheck;   /* 에러 발생 시 이후 구문 중단 방지 */
goptions reset=all gunit=pct htitle=3 ftitle="NanumGothic";

/* plots 디렉토리 생성 및 이미지 저장 경로 지정 */
%sysfunc(dcreate(plots, /home/student/open));

ods listing gpath="/home/student/open/plots";
ods graphics on / imagefmt=png imagename="EDA_Graph" reset=index height=600px width=800px;


/****************************************************************
 1. CSV 파일 불러오기 (PROC IMPORT)
****************************************************************/
proc import datafile="/home/student/open/Customer_info.csv" out=Customer_info dbms=csv replace; getnames=yes; run;
proc import datafile="/home/student/open/Discount_info.csv" out=Discount_info dbms=csv replace; getnames=yes; run;
proc import datafile="/home/student/open/Marketing_info.csv" out=Marketing_info dbms=csv replace; getnames=yes; run;
proc import datafile="/home/student/open/Onlinesales_info.csv" out=Onlinesales_info dbms=csv replace; getnames=yes; run;
proc import datafile="/home/student/open/Tax_info.csv" out=Tax_info dbms=csv replace; getnames=yes; run;


/****************************************************************
 2. 데이터 병합 (PROC SQL)
****************************************************************/
proc sql;
    create table merged_data as
    select 
        a.'고객ID'n,
        a.'거래ID'n,
        a.'거래날짜'n as '거래일자'n format=yymmdd10.,
        month(a.'거래날짜'n) as '월'n,
        put(a.'거래날짜'n, monname3.) as '월_영문'n,
        a.'제품ID'n,
        a.'제품카테고리'n,
        a.'수량'n,
        a.'평균금액'n,
        (a.'수량'n * a.'평균금액'n) as '총매출'n,
        a.'배송료'n,
        a.'쿠폰상태'n,
        b.'성별'n,
        b.'고객지역'n,
        b.'가입기간'n,
        c.'쿠폰코드'n,
        c.'할인율'n,
        d.'GST'n,
        e.'오프라인비용'n,
        e.'온라인비용'n,
        (e.'오프라인비용'n + e.'온라인비용'n) as '총마케팅비용'n
    from Onlinesales_info a
    left join Customer_info b  on a.'고객ID'n = b.'고객ID'n
    left join Discount_info c  on put(a.'거래날짜'n, monname3.) = c.'월'n 
                              and a.'제품카테고리'n = c.'제품카테고리'n
    left join Tax_info d       on a.'제품카테고리'n = d.'제품카테고리'n
    left join Marketing_info e on a.'거래날짜'n = e.'날짜'n;
quit;


/****************************************************************
 3. EDA 그래프 10종 생성 및 자동 저장 (/home/student/open/plots)
****************************************************************/

/* [그래프 1] 월별 총매출액 및 마케팅비용 추이 (이중 꺾은선 차트) */
proc sql;
    create table monthly_summary as
    select '월'n, sum('총매출'n) as '월총매출'n, sum('총마케팅비용'n) as '월마케팅비용'n
    from merged_data group by '월'n;
quit;

proc sgplot data=monthly_summary;
    title "1. 월별 매출액 vs 마케팅 비용 추이";
    series x='월'n y='월총매출'n / markers lineattrs=(thickness=3 color=blue) legendlabel="총매출 ($)";
    series x='월'n y='월마케팅비용'n / y2axis markers lineattrs=(thickness=3 color=orange) legendlabel="마케팅비용 ($)";
    xaxis integer values=(1 to 12);
    yaxis label="총매출 ($)"; 
    y2axis label="마케팅비용 ($)";
run;

/* [그래프 2] 상위 10개 제품 카테고리별 매출 (가로 막대) */
proc sql outobs=10;
    create table top_categories as
    select '제품카테고리'n, sum('총매출'n) as '카테고리총매출'n
    from merged_data group by '제품카테고리'n order by '카테고리총매출'n desc;
quit;

proc sgplot data=top_categories;
    title "2. 상위 10개 제품 카테고리별 총매출";
    hbar '제품카테고리'n / response='카테고리총매출'n categoryorder=respdesc datalabel;
    xaxis label="총매출 ($)"; yaxis label="제품 카테고리";
run;

/* [그래프 3] 고객 지역별 및 성별 매출 현황 (누적 막대) */
proc sgplot data=merged_data;
    title "3. 고객 지역 및 성별 총매출 현황";
    vbar '고객지역'n / response='총매출'n group='성별'n groupdisplay=stack;
    yaxis label="총매출 ($)"; xaxis label="고객 지역";
run;

/* [그래프 4] 쿠폰 사용 상태 분포 */
proc sgplot data=merged_data;
    title "4. 쿠폰 상태별 이용 분포";
    vbar '쿠폰상태'n / categoryorder=respdesc datalabel;
    xaxis label="쿠폰 상태"; yaxis label="건수";
run;

/* [그래프 5] 변수 간 상관관계 차트 (PROC CORR + PROC SGPLOT 대체 구문) */
proc corr data=merged_data outp=corr_matrix noprint;
    var '수량'n '평균금액'n '배송료'n '총매출'n '가입기간'n 'GST'n '온라인비용'n '오프라인비용'n;
run;

data corr_long;
    set corr_matrix(where=(_TYPE_='CORR'));
    length Var1 Var2 $30;
    Var1 = _NAME_;
    array vars[*] '수량'n '평균금액'n '배송료'n '총매출'n '가입기간'n 'GST'n '온라인비용'n '오프라인비용'n;
    array var_names[8] $30 _temporary_ ('수량', '평균금액', '배송료', '총매출', '가입기간', 'GST', '온라인비용', '오프라인비용');
    do i = 1 to dim(vars);
        Var2 = var_names[i];
        Corr_Value = round(vars[i], 0.01);
        output;
    end;
    keep Var1 Var2 Corr_Value;
run;

proc sgplot data=corr_long;
    title "5. 주요 지표 간 상관계수 (Correlation Plot)";
    scatter x=Var1 y=Var2 / markerchar=Corr_Value markercharattrs=(size=11pt weight=bold);
    xaxis label="변수 1"; yaxis label="변수 2";
run;

/* [그래프 6] 가입기간(개월) vs 고객별 총매출 (산점도) */
proc sql;
    create table customer_summary as
    select '고객ID'n, max('가입기간'n) as '가입기간'n, sum('총매출'n) as '인당총매출'n
    from merged_data group by '고객ID'n;
quit;

proc sgplot data=customer_summary;
    title "6. 가입기간별 고객 인당 총매출 분포";
    scatter x='가입기간'n y='인당총매출'n / markerattrs=(symbol=CircleFilled color=purple);
    xaxis label="가입기간 (개월)"; yaxis label="인당 총매출 ($)";
run;

/* [그래프 7] 할인율별 쿠폰 사용 상태 분포 (누적 막대) */
proc sgplot data=merged_data;
    where '할인율'n is not null;
    title "7. 할인율(%)에 따른 쿠폰 상태 분포";
    vbar '할인율'n / group='쿠폰상태'n groupdisplay=stack;
    xaxis label="할인율 (%)"; yaxis label="주문 건수";
run;

/* [그래프 8] 월별 평균 배송비 추이 (꺾은선) */
proc sql;
    create table monthly_shipping as
    select '월'n, mean('배송료'n) as '평균배송료'n
    from merged_data group by '월'n;
quit;

proc sgplot data=monthly_shipping;
    title "8. 월별 평균 배송료 추이 ($)";
    series x='월'n y='평균배송료'n / markers lineattrs=(thickness=2 color=crimson);
    xaxis integer values=(1 to 12) label="월"; 
    yaxis label="평균 배송료 ($)";
run;

/* [그래프 9] 상위 3개 지역의 월별 매출 추이 (다중 꺾은선) */
proc sql;
    create table top3_region_monthly as
    select '월'n, '고객지역'n, sum('총매출'n) as '지역월매출'n
    from merged_data
    where '고객지역'n in ('California', 'Chicago', 'New York')
    group by '월'n, '고객지역'n;
quit;

proc sgplot data=top3_region_monthly;
    title "9. 상위 3개 지역의 월별 매출 추이";
    series x='월'n y='지역월매출'n / group='고객지역'n markers lineattrs=(thickness=2);
    xaxis integer values=(1 to 12) label="월"; 
    yaxis label="월 매출액 ($)";
run;

/* [그래프 10] 카테고리별 세율(GST) 및 총매출 현황 */
proc sql outobs=8;
    create table category_gst as
    select '제품카테고리'n, 'GST'n, sum('총매출'n) as '카테고리매출'n
    from merged_data
    group by '제품카테고리'n, 'GST'n
    order by '카테고리매출'n desc;
quit;

proc sgplot data=category_gst;
    title "10. 상위 카테고리별 매출 및 GST 세율";
    vbar '제품카테고리'n / response='카테고리매출'n group='GST'n datalabel;
    xaxis label="제품 카테고리"; yaxis label="총매출 ($)";
run;

/* ODS 닫기 */
ods graphics off;