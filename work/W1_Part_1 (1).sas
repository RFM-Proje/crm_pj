/*==========================================================
  Week 1-1. CSV 파일 적재 및 데이터 구조 확인

  CSV 저장 경로:
  /home/student/J.H._Project/M6_DATA/DATASET_CSV
==========================================================*/


/*----------------------------------------------------------
  0. 기본 옵션
----------------------------------------------------------*/

/* 한글 변수명 등 다양한 변수명을 허용 */
options validvarname=any;


/*----------------------------------------------------------
  1. CSV 파일 및 SAS 라이브러리 경로 설정
----------------------------------------------------------*/

/* CSV 파일 5개가 저장된 폴더 */
%let CSV_DIR=/home/student/open;

/* 정제 전·후 SAS 데이터셋을 저장할 영구 라이브러리 */

libname crm "/home/student/open";


/*----------------------------------------------------------
  2. UTF-8 CSV 파일 연결

  첨부된 CSV 파일은 UTF-8 형식이므로
  한글 깨짐 방지를 위해 인코딩을 명시하겠다.
----------------------------------------------------------*/

filename csvcust
    "&CSV_DIR./Customer_info.csv"
    encoding="utf-8"
    lrecl=1048576;

filename csvonlin
    "&CSV_DIR./Onlinesales_info.csv"
    encoding="utf-8"
    lrecl=1048576;

filename csvdisc
    "&CSV_DIR./Discount_info.csv"
    encoding="utf-8"
    lrecl=1048576;

filename csvmkt
    "&CSV_DIR./Marketing_info.csv"
    encoding="utf-8"
    lrecl=1048576;

filename csvtax
    "&CSV_DIR./Tax_info.csv"
    encoding="utf-8"
    lrecl=1048576;


/*----------------------------------------------------------
  3. 기존 RAW 데이터셋 삭제

  이전 Excel 적재 결과가 남아 있으면 새 CSV 적재 결과와
  혼동될 수 있으므로 아래 5개 테이블만 삭제하겠다.
----------------------------------------------------------*/

proc datasets library=crm nolist;
    delete raw_customer
           raw_online
           raw_discount
           raw_marketing
           raw_tax;
quit;


/*----------------------------------------------------------
  4. Customer_info.csv 가져오기
----------------------------------------------------------*/

proc import
    datafile=csvcust
    out=crm.raw_customer
    dbms=csv
    replace;

    /* 첫 번째 행을 변수명으로 사용 */
    getnames=yes;

    /* 전체 행을 검사하여 변수 자료형과 길이를 추정 */
    guessingrows=max;
run;


/*----------------------------------------------------------
  5. Onlinesales_info.csv 가져오기
----------------------------------------------------------*/

proc import
    datafile=csvonlin
    out=crm.raw_online
    dbms=csv
    replace;

    getnames=yes;
    guessingrows=max;

    /*
      CSV에는 시트가 없으므로 SHEET 문장은 사용할 수 없음.

      Excel 파일을 사용할 때의 참고 문장:
      sheet="Onlinesales_info";
    */
run;


/*----------------------------------------------------------
  6. Discount_info.csv 가져오기
----------------------------------------------------------*/

proc import
    datafile=csvdisc
    out=crm.raw_discount
    dbms=csv
    replace;

    getnames=yes;
    guessingrows=max;
run;


/*----------------------------------------------------------
  7. Marketing_info.csv 가져오기
----------------------------------------------------------*/

proc import
    datafile=csvmkt
    out=crm.raw_marketing
    dbms=csv
    replace;

    getnames=yes;
    guessingrows=max;
run;


/*----------------------------------------------------------
  8. Tax_info.csv 가져오기
----------------------------------------------------------*/

proc import
    datafile=csvtax
    out=crm.raw_tax
    dbms=csv
    replace;

    getnames=yes;
    guessingrows=max;
run;


/*----------------------------------------------------------
  9. CSV 파일 연결 해제
----------------------------------------------------------*/

filename csvcust clear;
filename csvonlin clear;
filename csvdisc clear;
filename csvmkt clear;
filename csvtax clear;


/*==========================================================
  10. PROC CONTENTS로 5개 테이블 구조 확인
==========================================================*/

title "1. Customer_info 데이터 구조";

proc contents
    data=crm.raw_customer
    varnum;
run;


title "2. Onlinesales_info 데이터 구조";

proc contents
    data=crm.raw_online
    varnum;
run;


title "3. Discount_info 데이터 구조";

proc contents
    data=crm.raw_discount
    varnum;
run;


title "4. Marketing_info 데이터 구조";

proc contents
    data=crm.raw_marketing
    varnum;
run;


title "5. Tax_info 데이터 구조";

proc contents
    data=crm.raw_tax
    varnum;
run;

title;


/*==========================================================
  11. 적재 결과의 행·열 개수 확인
==========================================================*/

title "원본 테이블별 행 및 열 개수";

proc sql;
    select
        memname label="테이블명",
        nobs    label="행 개수",
        nvar    label="열 개수"
    from dictionary.tables
    where libname="CRM"
      and memname in (
          "RAW_CUSTOMER",
          "RAW_ONLINE",
          "RAW_DISCOUNT",
          "RAW_MARKETING",
          "RAW_TAX"
      )
    order by memname;
quit;

title;


/*==========================================================
  12. 각 테이블의 앞 5행 확인
==========================================================*/

title "Customer_info 표본";

proc print
    data=crm.raw_customer(obs=5);
run;


title "Onlinesales_info 표본";

proc print
    data=crm.raw_online(obs=5);
run;


title "Discount_info 표본";

proc print
    data=crm.raw_discount(obs=5);
run;


title "Marketing_info 표본";

proc print
    data=crm.raw_marketing(obs=5);
run;


title "Tax_info 표본";

proc print
    data=crm.raw_tax(obs=5);
run;

title;


/*==========================================================
  13. 적재 완료 확인 메시지
==========================================================*/

data _null_;
    put "======================================================";
    put "NOTE: CSV 파일 5종 적재 및 구조 확인이 완료되었습니다.";
    put "NOTE: 생성된 데이터셋:";
    put "NOTE: CRM.RAW_CUSTOMER";
    put "NOTE: CRM.RAW_ONLINE";
    put "NOTE: CRM.RAW_DISCOUNT";
    put "NOTE: CRM.RAW_MARKETING";
    put "NOTE: CRM.RAW_TAX";
    put "======================================================";
run;

/*==========================================================
  Week 1-2. 한글 변수명을 영문 변수명으로 표준화

  원칙
  1. CRM.RAW_ 테이블은 수정하지 않음
  2. CRM.STG_ 테이블을 새로 생성
  3. 변수명만 영문으로 변경
  4. 거래 테이블에는 고객ID+거래ID 복합키 생성
==========================================================*/

options validvarname=any;

/* 이전 단계에서 이미 실행했다면 중복 실행해도 문제없음 */
libname crm "/home/student/open";


/*----------------------------------------------------------
  1. Customer_info 변수명 표준화
----------------------------------------------------------*/

data crm.stg_customer;

    set crm.raw_customer(
        rename=(
            '고객ID'n   = customer_id
            '성별'n     = gender
            '고객지역'n = region
            '가입기간'n = tenure
        )
    );

    /* 영문 변수명에 한글 설명 추가 */
    label
        customer_id = "고객ID"
        gender      = "성별"
        region      = "고객지역"
        tenure      = "가입기간";
run;


/*----------------------------------------------------------
  2. Onlinesales_info 변수명 표준화
----------------------------------------------------------*/

data crm.stg_online;

    /* 고객ID와 거래ID를 합친 복합키의 최대 길이 */
    length order_key $50;

    set crm.raw_online(
        rename=(
            '고객ID'n       = customer_id
            '거래ID'n       = transaction_id
            '거래날짜'n     = transaction_date
            '제품ID'n       = product_id
            '제품카테고리'n = product_category
            '수량'n         = quantity
            '평균금액'n     = avg_price
            '배송료'n       = shipping_fee
            '쿠폰상태'n     = coupon_status
        )
    );

    /*
      거래ID가 여러 고객에게 중복될 수 있으므로
      고객ID와 거래ID를 결합한 주문 고유키 생성
    */
    if not missing(customer_id)
       and not missing(transaction_id) then
        order_key = catx(
            "|",
            customer_id,
            transaction_id
        );
    else
        call missing(order_key);

    label
        order_key        = "고객-거래 복합키"
        customer_id      = "고객ID"
        transaction_id   = "거래ID"
        transaction_date = "거래날짜"
        product_id       = "제품ID"
        product_category = "제품카테고리"
        quantity         = "수량"
        avg_price        = "평균금액"
        shipping_fee     = "배송료"
        coupon_status    = "쿠폰상태";
run;


/*----------------------------------------------------------
  3. Discount_info 변수명 표준화
----------------------------------------------------------*/

data crm.stg_discount;

    set crm.raw_discount(
        rename=(
            '월'n           = discount_month
            '제품카테고리'n = product_category
            '쿠폰코드'n     = coupon_code
            '할인율'n       = discount_pct
        )
    );

    label
        discount_month  = "할인 적용 월"
        product_category = "제품카테고리"
        coupon_code      = "쿠폰코드"
        discount_pct     = "할인율";
run;


/*----------------------------------------------------------
  4. Marketing_info 변수명 표준화
----------------------------------------------------------*/

data crm.stg_marketing;

    set crm.raw_marketing(
        rename=(
            '날짜'n       = marketing_date
            '오프라인비용'n = offline_cost
            '온라인비용'n   = online_cost
        )
    );

    label
        marketing_date = "마케팅 날짜"
        offline_cost   = "오프라인 마케팅 비용"
        online_cost    = "온라인 마케팅 비용";
run;


/*----------------------------------------------------------
  5. Tax_info 변수명 표준화
----------------------------------------------------------*/

data crm.stg_tax;

    set crm.raw_tax(
        rename=(
            '제품카테고리'n = product_category
            'GST'n          = gst_rate
        )
    );

    label
        product_category = "제품카테고리"
        gst_rate         = "GST 세율";
run;


/*==========================================================
  6. 생성된 STG 테이블의 구조 확인
==========================================================*/

title "1. STG_CUSTOMER 구조";

proc contents data=crm.stg_customer varnum;
run;


title "2. STG_ONLINE 구조";

proc contents data=crm.stg_online varnum;
run;


title "3. STG_DISCOUNT 구조";

proc contents data=crm.stg_discount varnum;
run;


title "4. STG_MARKETING 구조";

proc contents data=crm.stg_marketing varnum;
run;


title "5. STG_TAX 구조";

proc contents data=crm.stg_tax varnum;
run;

title;


/*==========================================================
  7. RAW와 STG의 행 개수가 같은지 검증
==========================================================*/

title "RAW와 STG 행 개수 비교";

proc sql;

    select
        "CUSTOMER" as table_name length=15,
        (select count(*) from crm.raw_customer) as raw_rows,
        (select count(*) from crm.stg_customer) as stg_rows
    from sashelp.class(obs=1)

    union all

    select
        "ONLINE",
        (select count(*) from crm.raw_online),
        (select count(*) from crm.stg_online)
    from sashelp.class(obs=1)

    union all

    select
        "DISCOUNT",
        (select count(*) from crm.raw_discount),
        (select count(*) from crm.stg_discount)
    from sashelp.class(obs=1)

    union all

    select
        "MARKETING",
        (select count(*) from crm.raw_marketing),
        (select count(*) from crm.stg_marketing)
    from sashelp.class(obs=1)

    union all

    select
        "TAX",
        (select count(*) from crm.raw_tax),
        (select count(*) from crm.stg_tax)
    from sashelp.class(obs=1);

quit;

title;


/*==========================================================
  8. 영문 변수명과 order_key 생성 결과 확인
==========================================================*/

title "STG_CUSTOMER 표본";

proc print data=crm.stg_customer(obs=5);
run;


title "STG_ONLINE 표본 및 복합키 확인";

proc print data=crm.stg_online(obs=5);
    var order_key
        customer_id
        transaction_id
        transaction_date
        product_id
        product_category
        quantity
        avg_price
        shipping_fee
        coupon_status;
run;

title;

/*==========================================================
  Week 1-3. STG 테이블 데이터 프로파일링 - 전체 수정본

  목적
  1. 결측치 확인
  2. 수치형 변수 분포 확인
  3. 범주형 변수 빈도 확인
  4. 날짜 범위 확인
  5. 완전 중복 행 확인
  6. 명백한 비정상값 확인
  7. 거래키 구조 확인

  주의:
  - CRM.STG_ 테이블은 수정하지 않음
  - 중복 확인 결과만 WORK 라이브러리에 임시 저장
==========================================================*/

options validvarname=any;

libname crm "/home/student/open";


/*==========================================================
  1. 테이블별 변수 결측치 확인
==========================================================*/


/*----------------------------------------------------------
  1-1. STG_CUSTOMER 결측치
----------------------------------------------------------*/

title "STG_CUSTOMER - 변수별 결측치";

proc sql;
    select
        count(*) as total_rows
            label="전체 행",

        sum(missing(customer_id))
            as customer_id_missing
            label="customer_id 결측",

        sum(missing(gender))
            as gender_missing
            label="gender 결측",

        sum(missing(region))
            as region_missing
            label="region 결측",

        sum(missing(tenure))
            as tenure_missing
            label="tenure 결측"

    from crm.stg_customer;
quit;


/*----------------------------------------------------------
  1-2. STG_ONLINE 결측치
----------------------------------------------------------*/

title "STG_ONLINE - 변수별 결측치";

proc sql;
    select
        count(*) as total_rows
            label="전체 행",

        sum(missing(order_key))
            as order_key_missing
            label="order_key 결측",

        sum(missing(customer_id))
            as customer_id_missing
            label="customer_id 결측",

        sum(missing(transaction_id))
            as transaction_id_missing
            label="transaction_id 결측",

        sum(missing(transaction_date))
            as transaction_date_missing
            label="transaction_date 결측",

        sum(missing(product_id))
            as product_id_missing
            label="product_id 결측",

        sum(missing(product_category))
            as product_category_missing
            label="product_category 결측",

        sum(missing(quantity))
            as quantity_missing
            label="quantity 결측",

        sum(missing(avg_price))
            as avg_price_missing
            label="avg_price 결측",

        sum(missing(shipping_fee))
            as shipping_fee_missing
            label="shipping_fee 결측",

        sum(missing(coupon_status))
            as coupon_status_missing
            label="coupon_status 결측"

    from crm.stg_online;
quit;


/*----------------------------------------------------------
  1-3. STG_DISCOUNT 결측치
----------------------------------------------------------*/

title "STG_DISCOUNT - 변수별 결측치";

proc sql;
    select
        count(*) as total_rows
            label="전체 행",

        sum(missing(discount_month))
            as discount_month_missing
            label="discount_month 결측",

        sum(missing(product_category))
            as product_category_missing
            label="product_category 결측",

        sum(missing(coupon_code))
            as coupon_code_missing
            label="coupon_code 결측",

        sum(missing(discount_pct))
            as discount_pct_missing
            label="discount_pct 결측"

    from crm.stg_discount;
quit;


/*----------------------------------------------------------
  1-4. STG_MARKETING 결측치
----------------------------------------------------------*/

title "STG_MARKETING - 변수별 결측치";

proc sql;
    select
        count(*) as total_rows
            label="전체 행",

        sum(missing(marketing_date))
            as marketing_date_missing
            label="marketing_date 결측",

        sum(missing(offline_cost))
            as offline_cost_missing
            label="offline_cost 결측",

        sum(missing(online_cost))
            as online_cost_missing
            label="online_cost 결측"

    from crm.stg_marketing;
quit;


/*----------------------------------------------------------
  1-5. STG_TAX 결측치
----------------------------------------------------------*/

title "STG_TAX - 변수별 결측치";

proc sql;
    select
        count(*) as total_rows
            label="전체 행",

        sum(missing(product_category))
            as product_category_missing
            label="product_category 결측",

        sum(missing(gst_rate))
            as gst_rate_missing
            label="gst_rate 결측"

    from crm.stg_tax;
quit;

title;


/*==========================================================
  2. 수치형 변수 기술통계
==========================================================*/


/* 고객 가입기간 */
title "STG_CUSTOMER - 가입기간 기술통계";

proc means data=crm.stg_customer
    n nmiss mean std min p1 q1 median q3 p99 max
    maxdec=2;

    var tenure;
run;


/* 거래 수치형 변수 */
title "STG_ONLINE - 거래 수치형 변수 기술통계";

proc means data=crm.stg_online
    n nmiss mean std min p1 q1 median q3 p99 max
    maxdec=2;

    var
        quantity
        avg_price
        shipping_fee;
run;


/* 할인율 */
title "STG_DISCOUNT - 할인율 기술통계";

proc means data=crm.stg_discount
    n nmiss mean std min p1 q1 median q3 p99 max
    maxdec=2;

    var discount_pct;
run;


/* 마케팅 비용 */
title "STG_MARKETING - 마케팅 비용 기술통계";

proc means data=crm.stg_marketing
    n nmiss mean std min p1 q1 median q3 p99 max
    maxdec=2;

    var
        offline_cost
        online_cost;
run;


/* GST 세율 */
title "STG_TAX - GST 세율 기술통계";

proc means data=crm.stg_tax
    n nmiss mean std min p1 q1 median q3 p99 max
    maxdec=4;

    var gst_rate;
run;

title;


/*==========================================================
  3. 범주형 변수 빈도 확인

  고객ID·거래ID·제품ID처럼 값의 종류가 많은
  식별자 변수는 출력량이 많으므로 제외했음.
==========================================================*/


/* 고객 특성 */
title "STG_CUSTOMER - 범주형 변수 빈도";

proc freq data=crm.stg_customer order=freq;
    tables
        gender
        region
        tenure
        / missing;
run;


/* 거래 특성 */
title "STG_ONLINE - 범주형 변수 빈도";

proc freq data=crm.stg_online order=freq;
    tables
        product_category
        coupon_status
        / missing;
run;


/* 할인정보 */
title "STG_DISCOUNT - 범주형 변수 빈도";

proc freq data=crm.stg_discount order=freq;
    tables
        discount_month
        product_category
        coupon_code
        / missing;
run;


/* 세금정보 */
title "STG_TAX - 제품카테고리 빈도";

proc freq data=crm.stg_tax order=freq;
    tables product_category / missing;
run;

title;


/*==========================================================
  4. 날짜 범위 확인
==========================================================*/

title "STG_ONLINE - 거래 날짜 범위";

proc sql;
    select
        min(transaction_date)
            as first_transaction_date
            format=yymmdd10.
            label="최초 거래일",

        max(transaction_date)
            as last_transaction_date
            format=yymmdd10.
            label="최종 거래일"

    from crm.stg_online;
quit;


title "STG_MARKETING - 마케팅 날짜 범위";

proc sql;
    select
        min(marketing_date)
            as first_marketing_date
            format=yymmdd10.
            label="최초 마케팅일",

        max(marketing_date)
            as last_marketing_date
            format=yymmdd10.
            label="최종 마케팅일"

    from crm.stg_marketing;
quit;

title;


/*==========================================================
  5. 완전히 동일한 중복 행 확인

  - 모든 변수의 값이 같은 행을 중복으로 판단
  - STG 테이블은 변경하지 않음
  - 중복 행은 WORK.DUP_ 테이블에 저장
==========================================================*/


/* 고객정보 중복 */
proc sort
    data=crm.stg_customer
    out=work.unique_customer
    dupout=work.dup_customer
    nodupkey;

    by _all_;
run;


/* 거래정보 중복 */
proc sort
    data=crm.stg_online
    out=work.unique_online
    dupout=work.dup_online
    nodupkey;

    by _all_;
run;


/* 할인정보 중복 */
proc sort
    data=crm.stg_discount
    out=work.unique_discount
    dupout=work.dup_discount
    nodupkey;

    by _all_;
run;


/* 마케팅정보 중복 */
proc sort
    data=crm.stg_marketing
    out=work.unique_marketing
    dupout=work.dup_marketing
    nodupkey;

    by _all_;
run;


/* 세금정보 중복 */
proc sort
    data=crm.stg_tax
    out=work.unique_tax
    dupout=work.dup_tax
    nodupkey;

    by _all_;
run;


/* 테이블별 중복 행 개수 */
title "테이블별 완전 중복 행 개수";

proc sql;

    select
        "STG_CUSTOMER" as table_name length=20,
        count(*) as duplicate_rows
            label="중복 행 개수"
    from work.dup_customer

    union all

    select
        "STG_ONLINE",
        count(*)
    from work.dup_online

    union all

    select
        "STG_DISCOUNT",
        count(*)
    from work.dup_discount

    union all

    select
        "STG_MARKETING",
        count(*)
    from work.dup_marketing

    union all

    select
        "STG_TAX",
        count(*)
    from work.dup_tax;

quit;

title;


/* 중복 확인용 UNIQUE 임시 테이블만 삭제 */
proc datasets library=work nolist;
    delete
        unique_customer
        unique_online
        unique_discount
        unique_marketing
        unique_tax;
quit;


/*==========================================================
  6. 명백한 비정상값 후보 확인

  높은 값은 곧바로 오류로 판단하지 않음. 
  여기서는 음수나 허용 범위 위반만 확인하고
  이상치 판단은 추후 Week2 이후에 진행
==========================================================*/


/*----------------------------------------------------------
  6-1. 온라인 거래
----------------------------------------------------------*/

title "STG_ONLINE - 비정상값 후보";

proc sql;
    select
        count(*) as total_rows
            label="전체 행",

        sum(
            case
                when quantity < 0 then 1
                else 0
            end
        ) as negative_quantity
            label="수량 음수",

        sum(
            case
                when quantity = 0 then 1
                else 0
            end
        ) as zero_quantity
            label="수량 0",

        sum(
            case
                when avg_price <= 0 then 1
                else 0
            end
        ) as invalid_avg_price
            label="평균금액 0 이하",

        sum(
            case
                when shipping_fee < 0 then 1
                else 0
            end
        ) as negative_shipping_fee
            label="배송료 음수"

    from crm.stg_online;
quit;


/*----------------------------------------------------------
  6-2. 고객정보
----------------------------------------------------------*/

title "STG_CUSTOMER - 비정상값 후보";

proc sql;
    select
        count(*) as total_rows
            label="전체 행",

        sum(
            case
                when tenure < 0 then 1
                else 0
            end
        ) as negative_tenure
            label="가입기간 음수"

    from crm.stg_customer;
quit;


/*----------------------------------------------------------
  6-3. 할인정보
----------------------------------------------------------*/

title "STG_DISCOUNT - 비정상값 후보";

proc sql;
    select
        count(*) as total_rows
            label="전체 행",

        sum(
            case
                when discount_pct < 0
                  or discount_pct > 100
                then 1
                else 0
            end
        ) as invalid_discount_pct
            label="할인율 범위 위반"

    from crm.stg_discount;
quit;


/*----------------------------------------------------------
  6-4. 마케팅정보
----------------------------------------------------------*/

title "STG_MARKETING - 비정상값 후보";

proc sql;
    select
        count(*) as total_rows
            label="전체 행",

        sum(
            case
                when offline_cost < 0 then 1
                else 0
            end
        ) as negative_offline_cost
            label="오프라인비용 음수",

        sum(
            case
                when online_cost < 0 then 1
                else 0
            end
        ) as negative_online_cost
            label="온라인비용 음수"

    from crm.stg_marketing;
quit;


/*----------------------------------------------------------
  6-5. 세금정보
----------------------------------------------------------*/

title "STG_TAX - 비정상값 후보";

proc sql;
    select
        count(*) as total_rows
            label="전체 행",

        sum(
            case
                when gst_rate < 0
                  or gst_rate > 1
                then 1
                else 0
            end
        ) as invalid_gst_rate
            label="GST 범위 위반"

    from crm.stg_tax;
quit;

title;


/*==========================================================
  7. 거래키 구조 확인
==========================================================*/


/* 거래 행·고객·거래ID·복합키 개수 비교 */
title "STG_ONLINE - 거래키 현황";

proc sql;
    select
        count(*) as total_rows
            label="전체 거래 상세 행",

        count(distinct customer_id)
            as distinct_customers
            label="고객 수",

        count(distinct transaction_id)
            as distinct_transaction_ids
            label="거래ID 수",

        count(distinct order_key)
            as distinct_order_keys
            label="고객-거래 복합키 수",

        sum(
            case
                when missing(order_key) then 1
                else 0
            end
        ) as missing_order_keys
            label="복합키 결측 행"

    from crm.stg_online;
quit;


/* 여러 고객에게 사용된 거래ID 목록 생성 */
proc sql;
    create table work.reused_transaction_ids as
    select
        transaction_id,
        count(distinct customer_id)
            as customer_count
            label="해당 거래ID의 고객 수"

    from crm.stg_online

    where not missing(transaction_id)

    group by transaction_id

    having calculated customer_count > 1;
quit;


/* 여러 고객에게 사용된 거래ID 개수 */
title "여러 고객에게 사용된 거래ID 개수";

proc sql;
    select
        count(*) as reused_transaction_id_count
            label="여러 고객에게 사용된 거래ID 수"

    from work.reused_transaction_ids;
quit;


/* 사례 10개 확인 */
title "여러 고객에게 사용된 거래ID 표본";

proc print
    data=work.reused_transaction_ids(obs=10)
    noobs;
run;

title;


/*==========================================================
  8. 프로파일링 완료 메시지
==========================================================*/

data _null_;
    put "======================================================";
    put "NOTE: STG 테이블 5종의 프로파일링이 완료되었습니다.";
    put "NOTE: CRM.STG_ 테이블은 수정되지 않았습니다.";
    put "NOTE: WORK.DUP_ 테이블에는 완전 중복 행이 저장됩니다.";
    put "NOTE: WORK.REUSED_TRANSACTION_IDS에는";
    put "NOTE: 여러 고객에게 사용된 거래ID가 저장됩니다.";
    put "======================================================";
run;

/*==========================================================
  Week 1-4. 테이블 간 데이터 정합성 검사

  검사 대상
  1. 기준정보 테이블의 기본키 중복
  2. 거래 고객ID와 고객정보 연결 여부
  3. 제품카테고리와 세금정보 연결 여부
  4. 제품카테고리와 할인정보 연결 여부
  5. 거래일과 마케팅 날짜 연결 여부
  6. 거래ID 및 복합키의 내부 일관성
  7. 코드값 유효성

  주의
  - CRM.STG_ 테이블은 수정하지 않음
  - 검사 상세 결과는 WORK.QA_ 테이블에 저장
  - 검사 요약은 CRM.QA_INTEGRITY_SUMMARY에 저장
==========================================================*/

options validvarname=any;

libname crm "/home/student/open";


/*==========================================================
  0. 이전 실행에서 생성된 WORK 검사 테이블 정리

  NOWARN 옵션을 사용하여 테이블이 없어도 경고가
  발생하지 않도록 처리할 것임.
==========================================================*/

proc datasets library=work nolist nowarn;
    delete
        qa_dup_customer_id
        qa_dup_tax_category
        qa_dup_marketing_date
        qa_dup_discount_key
        qa_online_customer_missing
        qa_online_tax_missing
        qa_online_discount_missing
        qa_discount_tax_missing
        qa_sales_date_missing_mkt
        qa_mkt_date_no_sales
        qa_transaction_id_reuse
        qa_order_date_conflict
        qa_product_category_conflict
        qa_invalid_coupon_status
        qa_invalid_discount_month
        qa_integrity_counts;
quit;


/*==========================================================
  1. 기준정보 테이블의 기본키 중복 검사
==========================================================*/

proc sql;

    /* 고객정보: customer_id 중복 확인 */
    create table work.qa_dup_customer_id as
    select
        customer_id,
        count(*) as row_count
            label="행 개수"
    from crm.stg_customer
    group by customer_id
    having count(*) > 1;


    /* 세금정보: product_category 중복 확인 */
    create table work.qa_dup_tax_category as
    select
        product_category,
        count(*) as row_count
            label="행 개수"
    from crm.stg_tax
    group by product_category
    having count(*) > 1;


    /* 마케팅정보: marketing_date 중복 확인 */
    create table work.qa_dup_marketing_date as
    select
        marketing_date format=yymmdd10.,
        count(*) as row_count
            label="행 개수"
    from crm.stg_marketing
    group by marketing_date
    having count(*) > 1;


    /*
      할인정보는 월과 제품카테고리의 조합을
      할인 조회용 키로 사용
    */
    create table work.qa_dup_discount_key as
    select
        discount_month,
        product_category,
        count(*) as row_count
            label="행 개수"
    from crm.stg_discount
    group by
        discount_month,
        product_category
    having count(*) > 1;

quit;


/*==========================================================
  2. 거래 고객ID가 고객정보에 존재하는지 확인
==========================================================*/

proc sql;

    create table work.qa_online_customer_missing as
    select
        o.customer_id,
        count(*) as transaction_rows
            label="거래 상세 행 수"

    from crm.stg_online as o

    where not exists (
        select 1
        from crm.stg_customer as c
        where o.customer_id = c.customer_id
    )

    group by o.customer_id;

quit;


/*==========================================================
  3. 거래 제품카테고리가 세금정보에 존재하는지 확인
==========================================================*/

proc sql;

    create table work.qa_online_tax_missing as
    select
        o.product_category,
        count(*) as transaction_rows
            label="거래 상세 행 수"

    from crm.stg_online as o

    where not exists (
        select 1
        from crm.stg_tax as t
        where o.product_category = t.product_category
    )

    group by o.product_category;

quit;


/*==========================================================
  4. 거래 제품카테고리가 할인정보에 존재하는지 확인

  할인정보에 없는 제품카테고리는 거래 오류가 아니라
  할인정보를 연결할 수 없는 카테고리임에 유의
==========================================================*/

proc sql;

    create table work.qa_online_discount_missing as
    select
        o.product_category,
        count(*) as transaction_rows
            label="거래 상세 행 수"

    from crm.stg_online as o

    where not exists (
        select 1
        from crm.stg_discount as d
        where o.product_category = d.product_category
    )

    group by o.product_category

    order by transaction_rows descending;

quit;


/*==========================================================
  5. 할인정보 제품카테고리가 세금정보에 존재하는지 확인
==========================================================*/

proc sql;

    create table work.qa_discount_tax_missing as
    select
        d.product_category,
        count(*) as discount_rows
            label="할인정보 행 수"

    from crm.stg_discount as d

    where not exists (
        select 1
        from crm.stg_tax as t
        where d.product_category = t.product_category
    )

    group by d.product_category

    order by discount_rows descending;

quit;


/*==========================================================
  6. 거래 날짜와 마케팅 날짜의 상호 포함 여부 확인
==========================================================*/


/* 거래는 있지만 마케팅정보가 없는 날짜 */
proc sql;

    create table work.qa_sales_date_missing_mkt as
    select distinct
        o.transaction_date format=yymmdd10.
            label="마케팅정보가 없는 거래일"

    from crm.stg_online as o

    where not exists (
        select 1
        from crm.stg_marketing as m
        where o.transaction_date = m.marketing_date
    )

    order by transaction_date;

quit;


/* 마케팅정보는 있지만 거래가 없는 날짜 */
proc sql;

    create table work.qa_mkt_date_no_sales as
    select distinct
        m.marketing_date format=yymmdd10.
            label="거래가 없는 마케팅일"

    from crm.stg_marketing as m

    where not exists (
        select 1
        from crm.stg_online as o
        where m.marketing_date = o.transaction_date
    )

    order by marketing_date;

quit;


/*==========================================================
  7. 거래ID가 여러 고객에게 사용됐는지 확인

  이 검사 결과는 오류가 아니라 정보성 검사에 해당함.
  거래ID가 여러 고객에게 사용되므로 분석에서는
  order_key를 주문 식별자로 사용해야 할 필요가 있음.
==========================================================*/

proc sql;

    create table work.qa_transaction_id_reuse as
    select
        transaction_id,
        count(distinct customer_id) as customer_count
            label="고객 수"

    from crm.stg_online

    where not missing(transaction_id)

    group by transaction_id

    having calculated customer_count > 1

    order by customer_count descending,
             transaction_id;

quit;


/*==========================================================
  8. 같은 order_key에 여러 거래날짜가 연결되는지 확인

  하나의 주문은 반드시 하나의 거래날짜에 대응해야 함.
==========================================================*/

proc sql;

    create table work.qa_order_date_conflict as
    select
        order_key,
        count(distinct transaction_date) as date_count
            label="서로 다른 거래날짜 수",

        min(transaction_date) as first_date
            format=yymmdd10.
            label="최초 날짜",

        max(transaction_date) as last_date
            format=yymmdd10.
            label="최종 날짜"

    from crm.stg_online

    where not missing(order_key)

    group by order_key

    having calculated date_count > 1;

quit;


/*==========================================================
  9. 하나의 제품ID가 여러 카테고리에 연결되는지 확인
==========================================================*/

proc sql;

    create table work.qa_product_category_conflict as
    select
        product_id,
        count(distinct product_category) as category_count
            label="서로 다른 카테고리 수"

    from crm.stg_online

    where not missing(product_id)

    group by product_id

    having calculated category_count > 1;

quit;


/*==========================================================
  10. 쿠폰상태 코드값 유효성 확인

  현재 데이터에서 허용되는 값
  - Clicked
  - Used
  - Not Used
==========================================================*/

proc sql;

    create table work.qa_invalid_coupon_status as
    select
        coupon_status,
        count(*) as row_count
            label="행 개수"

    from crm.stg_online

    where missing(coupon_status)
       or upcase(strip(coupon_status)) not in (
            "CLICKED",
            "USED",
            "NOT USED"
       )

    group by coupon_status;

quit;


/*==========================================================
  11. 할인 월 코드값 유효성 확인
==========================================================*/

proc sql;

    create table work.qa_invalid_discount_month as
    select
        discount_month,
        count(*) as row_count
            label="행 개수"

    from crm.stg_discount

    where missing(discount_month)
       or upcase(strip(discount_month)) not in (
            "JAN", "FEB", "MAR", "APR",
            "MAY", "JUN", "JUL", "AUG",
            "SEP", "OCT", "NOV", "DEC"
       )

    group by discount_month;

quit;


/*==========================================================
  12. 정합성 검사 결과 집계
==========================================================*/

proc sql;

    create table work.qa_integrity_counts as

    select
        1 as check_no,
        "Customer ID duplicate" as check_name length=100,
        count(*) as issue_count
    from work.qa_dup_customer_id

    union all

    select
        2,
        "Tax category duplicate",
        count(*)
    from work.qa_dup_tax_category

    union all

    select
        3,
        "Marketing date duplicate",
        count(*)
    from work.qa_dup_marketing_date

    union all

    select
        4,
        "Discount month-category duplicate",
        count(*)
    from work.qa_dup_discount_key

    union all

    select
        5,
        "Online customer missing from customer table",
        count(*)
    from work.qa_online_customer_missing

    union all

    select
        6,
        "Online category missing from tax table",
        count(*)
    from work.qa_online_tax_missing

    union all

    select
        7,
        "Online category missing from discount table",
        count(*)
    from work.qa_online_discount_missing

    union all

    select
        8,
        "Online rows without discount category",
        coalesce(sum(transaction_rows), 0)
    from work.qa_online_discount_missing

    union all

    select
        9,
        "Discount category missing from tax table",
        count(*)
    from work.qa_discount_tax_missing

    union all

    select
        10,
        "Discount rows without tax category",
        coalesce(sum(discount_rows), 0)
    from work.qa_discount_tax_missing

    union all

    select
        11,
        "Sales date missing from marketing table",
        count(*)
    from work.qa_sales_date_missing_mkt

    union all

    select
        12,
        "Marketing date without sales",
        count(*)
    from work.qa_mkt_date_no_sales

    union all

    select
        13,
        "Transaction ID used by multiple customers",
        count(*)
    from work.qa_transaction_id_reuse

    union all

    select
        14,
        "Order key linked to multiple dates",
        count(*)
    from work.qa_order_date_conflict

    union all

    select
        15,
        "Product ID linked to multiple categories",
        count(*)
    from work.qa_product_category_conflict

    union all

    select
        16,
        "Invalid coupon status",
        count(*)
    from work.qa_invalid_coupon_status

    union all

    select
        17,
        "Invalid discount month",
        count(*)
    from work.qa_invalid_discount_month;

quit;


/*==========================================================
  13. 검사 상태와 해석 추가

  PASS   : 문제 후보 0건
  REVIEW : 확인이 필요한 항목 존재
  INFO   : 오류가 아닌 구조적 참고사항
==========================================================*/

data crm.qa_integrity_summary;

    length
        check_type $16
        status     $8
        note       $200;

    set work.qa_integrity_counts;


    /* 검사 종류 구분 */
    if check_no in (1, 2, 3, 4) then
        check_type = "KEY";

    else if check_no in (5, 6, 7, 8, 9, 10) then
        check_type = "REFERENCE";

    else if check_no in (11, 12) then
        check_type = "DATE";

    else if check_no in (13, 14, 15) then
        check_type = "MAPPING";

    else if check_no in (16, 17) then
        check_type = "DOMAIN";


    /* 상태 판정 */
    if check_no = 13 then
        status = "INFO";

    else if issue_count = 0 then
        status = "PASS";

    else
        status = "REVIEW";


    /* 검사 결과 해석 */
    select (check_no);

        when (1)
            note = "고객정보의 customer_id는 중복되면 안 됩니다.";

        when (2)
            note = "세금정보의 제품카테고리는 중복되면 안 됩니다.";

        when (3)
            note = "마케팅정보는 날짜별 한 행이어야 합니다.";

        when (4)
            note = "할인 월과 제품카테고리 조합은 한 행이어야 합니다.";

        when (5)
            note = "거래 고객ID가 고객정보에 존재하는지 확인합니다.";

        when (6)
            note = "거래 카테고리가 세금정보에 존재하는지 확인합니다.";

        when (7)
            note = "할인정보가 없는 온라인 제품카테고리 수입니다.";

        when (8)
            note = "할인정보를 연결할 수 없는 온라인 거래 상세 행 수입니다.";

        when (9)
            note = "세금정보에 없는 할인 제품카테고리 수입니다.";

        when (10)
            note = "세금정보를 연결할 수 없는 할인정보 행 수입니다.";

        when (11)
            note = "마케팅비용을 연결할 수 없는 거래일 수입니다.";

        when (12)
            note = "거래가 없는 마케팅 날짜 수입니다.";

        when (13)
            note = "거래ID만 고유키로 사용할 수 없으므로 order_key를 사용합니다.";

        when (14)
            note = "하나의 주문은 하나의 거래날짜에 대응해야 합니다.";

        when (15)
            note = "하나의 제품ID는 하나의 카테고리에 대응해야 합니다.";

        when (16)
            note = "허용되지 않은 쿠폰상태 값이 있는지 확인합니다.";

        when (17)
            note = "Jan부터 Dec 이외의 월 코드가 있는지 확인합니다.";

        otherwise
            note = "검사 결과를 확인하십시오.";

    end;


    label
        check_no   = "검사 번호"
        check_type = "검사 유형"
        check_name = "검사 항목"
        issue_count = "문제 후보 수"
        status     = "상태"
        note       = "해석";

run;


/* 검사 번호 순으로 정렬 */
proc sort data=crm.qa_integrity_summary;
    by check_no;
run;


/*==========================================================
  14. 전체 정합성 검사 요약 출력
==========================================================*/

title "4단계 테이블 간 정합성 검사 요약";

proc print
    data=crm.qa_integrity_summary
    noobs
    label;

    var
        check_no
        check_type
        check_name
        issue_count
        status
        note;
run;

title;


/*==========================================================
  15. 주요 테이블 관계 규모 확인
==========================================================*/

title "온라인 거래 테이블의 주요 관계 규모";

proc sql;
    select
        count(*) as detail_rows
            label="거래 상세 행 수",

        count(distinct customer_id) as customer_count
            label="거래 고객 수",

        count(distinct transaction_id) as transaction_id_count
            label="거래ID 수",

        count(distinct order_key) as order_count
            label="복합 주문키 수",

        count(distinct product_id) as product_count
            label="제품 수",

        count(distinct product_category) as category_count
            label="제품카테고리 수"

    from crm.stg_online;
quit;

title;


/*==========================================================
  16. REVIEW 및 INFO 상세 결과 출력
==========================================================*/


/* 할인정보에 없는 온라인 카테고리 */
title "할인정보에 없는 온라인 제품카테고리";

proc print
    data=work.qa_online_discount_missing
    noobs
    label;
run;


/* 세금정보에 없는 할인 카테고리 */
title "세금정보에 없는 할인 제품카테고리";

proc print
    data=work.qa_discount_tax_missing
    noobs
    label;
run;


/* 여러 고객에게 사용된 거래ID 표본 */
title "여러 고객에게 사용된 거래ID 표본 10개";

proc print
    data=work.qa_transaction_id_reuse(obs=10)
    noobs
    label;
run;

title;


/*==========================================================
  17. 정합성 검사 완료 메시지
==========================================================*/

data _null_;
    put "======================================================";
    put "NOTE: 4단계 테이블 간 정합성 검사가 완료되었습니다.";
    put "NOTE: CRM.STG_ 원본 테이블은 수정되지 않았습니다.";
    put "NOTE: 전체 요약은 CRM.QA_INTEGRITY_SUMMARY에 저장되었습니다.";
    put "NOTE: 상세 검사 결과는 WORK.QA_ 테이블에 저장되었습니다.";
    put "======================================================";
run;

/*==========================================================
  Week 1-5. 정제 테이블 생성 및 품질 플래그 추가

  기본 원칙
  1. RAW_와 STG_ 테이블은 수정하지 않음
  2. CLEAN_ 테이블을 새로 생성
  3. 이상치와 반품 데이터는 삭제하지 않음
  4. 문제가 의심되는 행에 0/1 플래그를 추가
  5. 모든 결합은 LEFT JOIN으로 수행
==========================================================*/

options validvarname=any;

libname crm "/home/student/open";


/*==========================================================
  0. 이전 실행 결과 정리

  CLEAN_ 테이블과 이번 단계의 임시 테이블만 삭제.
  RAW_와 STG_ 테이블은 삭제하지 않고 진행함.
==========================================================*/

proc datasets library=work nolist nowarn;
    delete
        online_standardized
        online_enriched
        p99_thresholds;
quit;

proc datasets library=crm nolist nowarn;
    delete
        clean_customer
        clean_online
        clean_discount
        clean_marketing
        clean_tax
        qa_outlier_thresholds
        qa_flag_summary;
quit;


/*==========================================================
  1. 기준정보 CLEAN 테이블 생성

  문자값의 앞뒤 공백과 대소문자 정리를 수행
==========================================================*/


/*----------------------------------------------------------
  1-1. 고객정보 정제
----------------------------------------------------------*/

data crm.clean_customer;

    set crm.stg_customer;

    /* 고객ID는 영문 대문자로 통일 */
    customer_id = upcase(strip(customer_id));

    /* 문자형 변수의 앞뒤 공백 제거 */
    gender = strip(gender);
    region = strip(region);

    label
        customer_id = "표준화된 고객ID"
        gender      = "성별"
        region      = "고객지역"
        tenure      = "가입기간";

run;


/*----------------------------------------------------------
  1-2. 할인정보 정제
----------------------------------------------------------*/

data crm.clean_discount;

    set crm.stg_discount;

    /* 월 표기를 Jan, Feb 등의 형식으로 통일 */
    discount_month = propcase(strip(discount_month));

    /* 카테고리의 앞뒤 공백 제거 */
    product_category = strip(product_category);

    /* 쿠폰코드는 영문 대문자로 통일 */
    coupon_code = upcase(strip(coupon_code));

    label
        discount_month  = "할인 적용 월"
        product_category = "제품카테고리"
        coupon_code      = "쿠폰코드"
        discount_pct     = "할인율";

run;


/*----------------------------------------------------------
  1-3. 마케팅정보 정제
----------------------------------------------------------*/

data crm.clean_marketing;

    set crm.stg_marketing;

    label
        marketing_date = "마케팅 날짜"
        offline_cost   = "오프라인 마케팅 비용"
        online_cost    = "온라인 마케팅 비용";

run;


/*----------------------------------------------------------
  1-4. 세금정보 정제
----------------------------------------------------------*/

data crm.clean_tax;

    set crm.stg_tax;

    product_category = strip(product_category);

    label
        product_category = "제품카테고리"
        gst_rate         = "GST 세율";

run;


/*==========================================================
  2. 온라인 거래 문자값 표준화

  STG_ONLINE은 수정하지 않고 WORK에 임시 테이블을 만듦.
==========================================================*/

data work.online_standardized;

    /*기존 order_key는 표준화 전 고객ID로 만들어졌으므로,
      삭제한 후 다시 생성한다.*/
    set crm.stg_online(drop=order_key);

    length
        order_key        $50
        transaction_month $3;

    /* 주요 문자형 변수의 공백과 대소문자 정리 */
    customer_id      = upcase(strip(customer_id));
    transaction_id   = strip(transaction_id);
    product_id       = strip(product_id);
    product_category = strip(product_category);

    /*
      쿠폰상태를 다음 3가지 형태로 통일
      Clicked / Used / Not Used
    */
    select (upcase(strip(coupon_status)));

        when ("CLICKED")
            coupon_status = "Clicked";

        when ("USED")
            coupon_status = "Used";

        when ("NOT USED")
            coupon_status = "Not Used";

        otherwise
            coupon_status = strip(coupon_status);

    end;


    /* 고객ID와 거래ID를 결합한 주문키 재생성 */
    if not missing(customer_id)
       and not missing(transaction_id) then
        order_key = catx(
            "|",
            customer_id,
            transaction_id
        );

    else
        call missing(order_key);


    /* 거래날짜에서 Jan, Feb 형태의 월 변수 생성 */
    if not missing(transaction_date) then
        transaction_month =
            propcase(
                put(transaction_date, monname3.)
            );

    else
        call missing(transaction_month);


    label
        order_key         = "고객-거래 복합키"
        transaction_month = "거래 월";

run;


/*==========================================================
  3. 99백분위수 기준 계산

  높은 값은 오류로 단정하지 않고 검토 대상으로 표시.
==========================================================*/

proc means
    data=work.online_standardized
    noprint;

    var
        quantity
        avg_price
        shipping_fee;

    output
        out=work.p99_thresholds(
            drop=_type_ _freq_
        )

        p99=
            p99_quantity
            p99_avg_price
            p99_shipping_fee;

run;


/* 99백분위수 기준을 영구 테이블로 저장 */
data crm.qa_outlier_thresholds;

    set work.p99_thresholds;

    length
        variable_name $32
        description   $100;

    variable_name = "quantity";
    description   = "수량 상위 1% 검토 기준";
    p99_value     = p99_quantity;
    output;

    variable_name = "avg_price";
    description   = "평균금액 상위 1% 검토 기준";
    p99_value     = p99_avg_price;
    output;

    variable_name = "shipping_fee";
    description   = "배송료 상위 1% 검토 기준";
    p99_value     = p99_shipping_fee;
    output;

    keep
        variable_name
        description
        p99_value;

    label
        variable_name = "변수명"
        description   = "설명"
        p99_value     = "99백분위수 기준값";

run;


/* 계산된 기준값 확인 */
title "이상치 검토용 99백분위수 기준";

proc print
    data=crm.qa_outlier_thresholds
    noobs
    label;
run;

title;


/*==========================================================
  4. 온라인 거래와 기준정보 결합

  LEFT JOIN을 사용하므로 매칭되지 않는 거래도 유지됨.

  결합 기준
  - 고객정보: customer_id
  - 할인정보: transaction_month + product_category
  - 세금정보: product_category
  - 마케팅정보: transaction_date
==========================================================*/

proc sql;

    create table work.online_enriched as

    select
        /* 온라인 거래 원본 변수 */
        o.order_key,
        o.customer_id,
        o.transaction_id,
        o.transaction_date,
        o.transaction_month,
        o.product_id,
        o.product_category,
        o.quantity,
        o.avg_price,
        o.shipping_fee,
        o.coupon_status,

        /* 고객정보 */
        c.gender,
        c.region,
        c.tenure,

        /* 해당 월·카테고리에 제공된 쿠폰정보 */
        d.coupon_code as offered_coupon_code
            label="제공 쿠폰코드",

        d.discount_pct as offered_discount_pct
            label="제공 할인율",

        /* 세금정보 */
        t.gst_rate,

        /* 날짜별 마케팅비용 */
        m.offline_cost,
        m.online_cost,

        /* 고객정보 미매칭 플래그 */
        case
            when missing(c.customer_id) then 1
            else 0
        end as flag_customer_unmatched,

        /* 할인정보 미매칭 플래그 */
        case
            when missing(d.product_category) then 1
            else 0
        end as flag_discount_unmatched,

        /* 세금정보 미매칭 플래그 */
        case
            when missing(t.product_category) then 1
            else 0
        end as flag_tax_unmatched,

        /* 마케팅정보 미매칭 플래그 */
        case
            when missing(m.marketing_date) then 1
            else 0
        end as flag_marketing_unmatched

    from work.online_standardized as o

    left join crm.clean_customer as c
        on o.customer_id = c.customer_id

    left join crm.clean_discount as d
        on  o.product_category = d.product_category
        and upcase(o.transaction_month)
            = upcase(d.discount_month)

    left join crm.clean_tax as t
        on o.product_category = t.product_category

    left join crm.clean_marketing as m
        on o.transaction_date = m.marketing_date;

quit;


/*==========================================================
  5. 정제 플래그를 추가하여 CLEAN_ONLINE 생성
==========================================================*/

data crm.clean_online;

    /*
      첫 번째 행을 처리할 때 99백분위수 기준값을 가져올 예정.
      기준값은 모든 거래 행에 동일하게 적용됨.
    */
    if _n_ = 1 then
        set work.p99_thresholds;

    set work.online_enriched;


    /*------------------------------------------------------
      5-1. 핵심 변수 결측 플래그

      다음 변수 중 하나라도 결측이면 1
      - 주문키, 고객ID, 거래ID, 거래날짜
      - 제품ID, 제품카테고리, 수량, 평균금액
    ------------------------------------------------------*/

    flag_missing_core = max(
        missing(order_key),
        missing(customer_id),
        missing(transaction_id),
        missing(transaction_date),
        missing(product_id),
        missing(product_category),
        missing(quantity),
        missing(avg_price)
    );


    /*------------------------------------------------------
      5-2. 수량 관련 플래그
    ------------------------------------------------------*/

    /* 수량이 음수이면 반품 후보 */
    flag_return = (
        not missing(quantity)
        and quantity < 0
    );

    /* 수량이 0이면 비정상 거래 후보 */
    flag_zero_quantity = (
        not missing(quantity)
        and quantity = 0
    );

    /*
      수량이 99백분위수를 초과하면 대량구매 검토 대상
      해당 행은 삭제하지 않음
    */
    flag_high_quantity = (
        not missing(quantity)
        and not missing(p99_quantity)
        and quantity > p99_quantity
    );


    /*------------------------------------------------------
      5-3. 평균금액 관련 플래그
    ------------------------------------------------------*/

    /* 평균금액이 0 이하이면 비정상 가격 후보 */
    flag_invalid_price = (
        not missing(avg_price)
        and avg_price <= 0
    );

    /*
      평균금액이 99백분위수를 초과하면 고액거래 검토 대상
      해당 행은 삭제하지 않음
    */
    flag_high_price = (
        not missing(avg_price)
        and not missing(p99_avg_price)
        and avg_price > p99_avg_price
    );


    /*------------------------------------------------------
      5-4. 배송료 관련 플래그
    ------------------------------------------------------*/

    /*
      배송료가 99백분위수를 초과하면
      높은 배송료 검토 대상으로 표시
    */
    flag_high_shipping = (
        not missing(shipping_fee)
        and not missing(p99_shipping_fee)
        and shipping_fee > p99_shipping_fee
    );


    /*------------------------------------------------------
      5-5. 쿠폰상태 유효성 플래그
    ------------------------------------------------------*/

    flag_invalid_coupon = (
        missing(coupon_status)
        or upcase(strip(coupon_status)) not in (
            "CLICKED",
            "USED",
            "NOT USED"
        )
    );


    /*------------------------------------------------------
      5-6. 전체 검토 필요 여부

      아래 플래그 중 하나라도 1이면 검토 대상으로 표시합니다.
      flag_any_review가 1이어도 행을 삭제하지 않습니다.
    ------------------------------------------------------*/

    flag_any_review = max(
        flag_missing_core,
        flag_return,
        flag_zero_quantity,
        flag_high_quantity,
        flag_invalid_price,
        flag_high_price,
        flag_high_shipping,
        flag_invalid_coupon,
        flag_customer_unmatched,
        flag_discount_unmatched,
        flag_tax_unmatched,
        flag_marketing_unmatched
    );


    /* 플래그와 파생변수에 설명 추가 */
    label
        flag_missing_core =
            "핵심 변수 결측"

        flag_return =
            "수량 음수·반품 후보"

        flag_zero_quantity =
            "수량 0"

        flag_high_quantity =
            "수량 99백분위수 초과"

        flag_invalid_price =
            "평균금액 0 이하"

        flag_high_price =
            "평균금액 99백분위수 초과"

        flag_high_shipping =
            "배송료 99백분위수 초과"

        flag_invalid_coupon =
            "예상하지 않은 쿠폰상태"

        flag_customer_unmatched =
            "고객정보 미매칭"

        flag_discount_unmatched =
            "할인정보 미매칭"

        flag_tax_unmatched =
            "세금정보 미매칭"

        flag_marketing_unmatched =
            "마케팅정보 미매칭"

        flag_any_review =
            "하나 이상의 검토 플래그 존재";


    /*
      기준값은 별도의 QA_OUTLIER_THRESHOLDS에 저장했으므로
      거래 테이블에서는 제거합니다.
    */
    drop
        p99_quantity
        p99_avg_price
        p99_shipping_fee;

run;


/*==========================================================
  6. STG와 CLEAN의 행 개수 비교

- CLEAN_ONLINE의 행 개수가 늘었다면
  기준정보 테이블의 결합키 중복을 의심할 필요가 있음.
- 먼저 행 개수를 임시 테이블에 저장한 뒤
  두 번째 SQL에서 차이를 계산.
==========================================================*/

/* 이전 임시 결과가 있어도 경고 없이 삭제 */
proc datasets library=work nolist nowarn;
    delete row_count_base;
quit;


/* STG와 CLEAN의 행 개수를 먼저 저장 */
proc sql;

    create table work.row_count_base as

    select
        "CUSTOMER" as table_name length=15,
        (select count(*) from crm.stg_customer)
            as stg_rows,
        (select count(*) from crm.clean_customer)
            as clean_rows

    from sashelp.class(obs=1)

    union all

    select
        "ONLINE",
        (select count(*) from crm.stg_online),
        (select count(*) from crm.clean_online)

    from sashelp.class(obs=1)

    union all

    select
        "DISCOUNT",
        (select count(*) from crm.stg_discount),
        (select count(*) from crm.clean_discount)

    from sashelp.class(obs=1)

    union all

    select
        "MARKETING",
        (select count(*) from crm.stg_marketing),
        (select count(*) from crm.clean_marketing)

    from sashelp.class(obs=1)

    union all

    select
        "TAX",
        (select count(*) from crm.stg_tax),
        (select count(*) from crm.clean_tax)

    from sashelp.class(obs=1);

quit;


/* 저장된 행 개수를 이용하여 차이 계산 */
title "STG와 CLEAN 행 개수 비교";

proc sql;

    select
        table_name
            label="테이블명",

        stg_rows
            label="STG 행 개수",

        clean_rows
            label="CLEAN 행 개수",

        clean_rows - stg_rows
            as row_difference
            label="행 개수 차이"

    from work.row_count_base

    order by table_name;

quit;

title;


/* 확인이 끝난 임시 테이블 삭제 */
proc datasets library=work nolist nowarn;
    delete row_count_base;
quit;


/*==========================================================
  7. 플래그별 건수 집계
==========================================================*/

proc sql;

    create table crm.qa_flag_summary as

    select
        count(*) as total_rows
            label="전체 거래 상세 행",

        sum(flag_missing_core)
            as missing_core_count
            label="핵심 변수 결측",

        sum(flag_return)
            as return_count
            label="반품 후보",

        sum(flag_zero_quantity)
            as zero_quantity_count
            label="수량 0",

        sum(flag_high_quantity)
            as high_quantity_count
            label="수량 상위 1% 초과",

        sum(flag_invalid_price)
            as invalid_price_count
            label="평균금액 0 이하",

        sum(flag_high_price)
            as high_price_count
            label="평균금액 상위 1% 초과",

        sum(flag_high_shipping)
            as high_shipping_count
            label="배송료 상위 1% 초과",

        sum(flag_invalid_coupon)
            as invalid_coupon_count
            label="잘못된 쿠폰상태",

        sum(flag_customer_unmatched)
            as customer_unmatched_count
            label="고객정보 미매칭",

        sum(flag_discount_unmatched)
            as discount_unmatched_count
            label="할인정보 미매칭",

        sum(flag_tax_unmatched)
            as tax_unmatched_count
            label="세금정보 미매칭",

        sum(flag_marketing_unmatched)
            as marketing_unmatched_count
            label="마케팅정보 미매칭",

        sum(flag_any_review)
            as any_review_count
            label="검토 대상 행"

    from crm.clean_online;

quit;


/* 플래그 요약 출력 */
title "CLEAN_ONLINE 품질 플래그 요약";

proc print
    data=crm.qa_flag_summary
    noobs
    label;
run;

title;


/*==========================================================
  8. 할인정보 미매칭 카테고리 확인
==========================================================*/

title "할인정보가 연결되지 않은 제품카테고리";

proc freq data=crm.clean_online order=freq;

    where flag_discount_unmatched = 1;

    tables product_category / missing;

run;

title;


/*==========================================================
  9. 검토 대상 표본 확인
==========================================================*/

title "하나 이상의 플래그가 있는 거래 표본 20개";

proc print
    data=crm.clean_online(obs=20)
    label;

    where flag_any_review = 1;

    var
        order_key
        transaction_date
        product_category
        quantity
        avg_price
        shipping_fee
        coupon_status
        flag_missing_core
        flag_return
        flag_zero_quantity
        flag_high_quantity
        flag_invalid_price
        flag_high_price
        flag_high_shipping
        flag_invalid_coupon
        flag_discount_unmatched
        flag_tax_unmatched;

    format transaction_date yymmdd10.;

run;

title;


/*==========================================================
  10. 최종 정제 테이블 구조 확인
==========================================================*/

title "최종 CLEAN_ONLINE 데이터 구조";

proc contents
    data=crm.clean_online
    varnum;
run;

title;


/*==========================================================
  11. CLEAN_ONLINE 앞 10행 확인
==========================================================*/

title "최종 CLEAN_ONLINE 앞 10행";

proc print
    data=crm.clean_online(obs=10)
    label;

    format transaction_date yymmdd10.;

run;

title;


/*==========================================================
  12. 5단계 완료 메시지
==========================================================*/

data _null_;

    put "======================================================";
    put "NOTE: 5단계 정제 테이블 생성이 완료되었습니다.";
    put "NOTE: RAW_ 및 STG_ 테이블은 수정되지 않았습니다.";
    put "NOTE: 이상치와 반품 후보 행은 삭제하지 않았습니다.";
    put "NOTE: 최종 거래 테이블: CRM.CLEAN_ONLINE";
    put "NOTE: 고객 테이블: CRM.CLEAN_CUSTOMER";
    put "NOTE: 할인 테이블: CRM.CLEAN_DISCOUNT";
    put "NOTE: 마케팅 테이블: CRM.CLEAN_MARKETING";
    put "NOTE: 세금 테이블: CRM.CLEAN_TAX";
    put "NOTE: 이상치 기준: CRM.QA_OUTLIER_THRESHOLDS";
    put "NOTE: 플래그 요약: CRM.QA_FLAG_SUMMARY";
    put "======================================================";

run;
quit;