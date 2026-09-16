/*============================================================
  Week 2-1. 주문 단위 분석 테이블 생성

  입력 테이블
  - CRM.CLEAN_ONLINE
  - 상품 하나당 한 행인 거래 상세 데이터

  출력 테이블
  - CRM.W2_ORDER_BASE
  - 주문 하나당 한 행인 분석용 데이터

  주요 원칙
  1. 주문 식별자는 transaction_id가 아니라 order_key를 사용합니다.
  2. 배송료는 상품 행마다 반복되므로 주문별로 한 번만 계산합니다.
  3. 쿠폰상태는 주문 안에서도 다를 수 있으므로 플래그로 요약합니다.
  4. 이상치 행은 삭제하지 않고 주문 단위 플래그로 보존합니다.
============================================================*/

options validvarname=any;


/*------------------------------------------------------------
  1. CRM 라이브러리 연결
------------------------------------------------------------*/

libname crm "/home/student/open";


/*------------------------------------------------------------
  2. 이전 실행 결과 삭제

  코드를 다시 실행할 때 기존 결과와 충돌하지 않도록
  이번 단계에서 생성하는 테이블만 삭제합니다.

  CLEAN_ONLINE 등 원본·정제 테이블은 삭제하지 않습니다.
------------------------------------------------------------*/

proc datasets library=work nolist nowarn;
    delete
        w2_line_base
        w2_unassigned_lines
        w2_order_agg
        w2_source_qa
        w2_order_qa;
quit;

proc datasets library=crm nolist nowarn;
    delete w2_order_base;
quit;


/*------------------------------------------------------------
  3. 상품 행 단위 계산변수 생성

  line_gross_amount
  = 상품 수량 × 상품 평균금액

  예:
  수량 3개 × 평균금액 10원 = 상품금액 30원
------------------------------------------------------------*/

data work.w2_line_base
     work.w2_unassigned_lines;

    set crm.clean_online;


    /* 상품 행별 할인 전 금액 */
    line_gross_amount = quantity * avg_price;


    /* 쿠폰상태별 상품 행 플래그 */
    line_coupon_used = (
        upcase(strip(coupon_status)) = "USED"
    );

    line_coupon_clicked = (
        upcase(strip(coupon_status)) = "CLICKED"
    );

    line_coupon_not_used = (
        upcase(strip(coupon_status)) = "NOT USED"
    );


    /*
      RFM 계산에서 제외해야 할 명확한 오류 플래그

      다음 중 하나라도 1이면 1로 표시합니다.
      - 핵심 변수 결측
      - 수량 음수
      - 수량 0
      - 평균금액 0 이하

      상위 1% 이상치는 여기에 포함하지 않습니다.
      대량구매일 가능성이 있으므로 그대로 보존합니다.
    */
    flag_line_excluded_rfm = max(
        flag_missing_core,
        flag_return,
        flag_zero_quantity,
        flag_invalid_price
    );


    format
        line_gross_amount comma18.2;


    label
        line_gross_amount =
            "상품 행별 할인 전 금액"

        line_coupon_used =
            "상품 행 쿠폰 사용"

        line_coupon_clicked =
            "상품 행 쿠폰 클릭"

        line_coupon_not_used =
            "상품 행 쿠폰 미사용"

        flag_line_excluded_rfm =
            "RFM 제외 대상 상품 행";


    /*
      order_key가 없으면 주문 단위로 묶을 수 없습니다.

      해당 행은 삭제하지 않고
      별도 WORK 테이블에 보관합니다.
    */
    if missing(order_key) then
        output work.w2_unassigned_lines;

    else
        output work.w2_line_base;

run;


/*------------------------------------------------------------
  4. 상품 행을 주문 단위로 집계

  하나의 order_key가 최종 테이블에서 한 행이 됩니다.
------------------------------------------------------------*/

proc sql;

    create table work.w2_order_agg as

    select
        /* 주문 식별정보 */
        order_key,
        customer_id,
        transaction_id,


        /* 동일 주문의 거래일자는 같아야 합니다. */
        min(transaction_date)
            as order_date
            format=yymmdd10.,


        /* 한 주문에 포함된 상품 행 개수 */
        count(*)
            as line_count,


        /* 한 주문의 서로 다른 제품 개수 */
        count(distinct product_id)
            as product_count,


        /* 한 주문의 서로 다른 카테고리 개수 */
        count(distinct product_category)
            as category_count,


        /* 주문 전체 수량 */
        sum(quantity)
            as order_quantity,


        /* 주문 상품금액: 수량 × 평균금액의 합계 */
        sum(line_gross_amount)
            as order_gross_amount
            format=comma18.2,


        /*
          배송료는 주문 내 상품 행마다 반복됩니다.
          주문별 최대값을 사용하여 한 번만 계산합니다.
        */
        coalesce(
            max(shipping_fee),
            0
        )
            as order_shipping_fee
            format=comma18.2,


        /* 할인 전 상품금액에 배송료를 한 번 더한 금액 */
        sum(line_gross_amount)
        + coalesce(
            max(shipping_fee),
            0
        )
            as order_gross_with_shipping
            format=comma18.2,


        /* 주문 안에 Used 행이 하나라도 있으면 1 */
        max(line_coupon_used)
            as coupon_used_order,


        /* 주문 안에 Clicked 행이 하나라도 있으면 1 */
        max(line_coupon_clicked)
            as coupon_clicked_order,


        /* 주문 안에 Not Used 행이 하나라도 있으면 1 */
        max(line_coupon_not_used)
            as coupon_not_used_order,


        /* 주문 내 쿠폰 사용 상품 행 개수 */
        sum(line_coupon_used)
            as coupon_used_line_count,


        /* 주문 안에서 발견된 쿠폰상태 종류 수 */
        count(distinct coupon_status)
            as coupon_status_count,


        /* 주문 안에서 발견된 거래일자 종류 수 */
        count(distinct transaction_date)
            as date_value_count,


        /* 주문 안에서 발견된 배송료 종류 수 */
        count(distinct shipping_fee)
            as shipping_value_count,


        /* RFM 제외 대상 상품 행 개수 */
        sum(flag_line_excluded_rfm)
            as excluded_rfm_line_count,


        /*
          주문 안에 명확한 오류 행이 하나라도 있으면 1

          다음 RFM 단계에서는 이 플래그가 0인 주문만
          분석 대상으로 사용할 수 있습니다.
        */
        max(flag_line_excluded_rfm)
            as flag_order_excluded_rfm,


        /* 상위 1% 수량 행이 포함된 주문 */
        max(flag_high_quantity)
            as flag_order_high_quantity,


        /* 상위 1% 가격 행이 포함된 주문 */
        max(flag_high_price)
            as flag_order_high_price,


        /* 상위 1% 배송료 행이 포함된 주문 */
        max(flag_high_shipping)
            as flag_order_high_shipping,


        /* 예상하지 않은 쿠폰상태가 포함된 주문 */
        max(flag_invalid_coupon)
            as flag_order_invalid_coupon,


        /* 고객정보가 연결되지 않은 주문 */
        max(flag_customer_unmatched)
            as flag_order_customer_unmatched,


        /* 할인정보가 연결되지 않은 주문 */
        max(flag_discount_unmatched)
            as flag_order_discount_unmatched,


        /* 세금정보가 연결되지 않은 주문 */
        max(flag_tax_unmatched)
            as flag_order_tax_unmatched,


        /* 마케팅정보가 연결되지 않은 주문 */
        max(flag_marketing_unmatched)
            as flag_order_marketing_unmatched,


        /* 검토 대상 상품 행 개수 */
        sum(flag_any_review)
            as review_line_count,


        /* 하나 이상의 검토 대상 행이 포함된 주문 */
        max(flag_any_review)
            as flag_order_any_review


    from work.w2_line_base

    group by
        order_key,
        customer_id,
        transaction_id;

quit;


/*------------------------------------------------------------
  5. 주문 월 변수를 만들고 영구 테이블로 저장

  order_month는 해당 월의 첫째 날을 값으로 가지며
  화면에는 YYYYMM 형식으로 표시됩니다.

  예:
  order_date  = 2019-03-15
  order_month = 201903
------------------------------------------------------------*/

data crm.w2_order_base;

    set work.w2_order_agg;

    order_month = intnx(
        "month",
        order_date,
        0,
        "beginning"
    );

    format
        order_date  yymmdd10.
        order_month yymmn6.
        order_gross_amount        comma18.2
        order_shipping_fee        comma18.2
        order_gross_with_shipping comma18.2;


    label
        order_key =
            "고객-거래 복합 주문키"

        customer_id =
            "고객ID"

        transaction_id =
            "거래ID"

        order_date =
            "주문일자"

        order_month =
            "주문월"

        line_count =
            "주문 내 상품 행 개수"

        product_count =
            "주문 내 제품 종류 수"

        category_count =
            "주문 내 카테고리 종류 수"

        order_quantity =
            "주문 전체 수량"

        order_gross_amount =
            "주문 할인 전 상품금액"

        order_shipping_fee =
            "주문 배송료"

        order_gross_with_shipping =
            "상품금액과 배송료 합계"

        coupon_used_order =
            "주문 내 쿠폰 사용 여부"

        coupon_clicked_order =
            "주문 내 쿠폰 클릭 여부"

        coupon_not_used_order =
            "주문 내 쿠폰 미사용 여부"

        coupon_used_line_count =
            "쿠폰 사용 상품 행 개수"

        coupon_status_count =
            "주문 내 쿠폰상태 종류 수"

        date_value_count =
            "주문 내 거래일자 종류 수"

        shipping_value_count =
            "주문 내 배송료 종류 수"

        excluded_rfm_line_count =
            "RFM 제외 대상 상품 행 개수"

        flag_order_excluded_rfm =
            "RFM 제외 대상 주문"

        flag_order_high_quantity =
            "고수량 행 포함 주문"

        flag_order_high_price =
            "고가격 행 포함 주문"

        flag_order_high_shipping =
            "고배송료 행 포함 주문"

        flag_order_invalid_coupon =
            "비정상 쿠폰상태 포함 주문"

        flag_order_customer_unmatched =
            "고객정보 미매칭 주문"

        flag_order_discount_unmatched =
            "할인정보 미매칭 주문"

        flag_order_tax_unmatched =
            "세금정보 미매칭 주문"

        flag_order_marketing_unmatched =
            "마케팅정보 미매칭 주문"

        review_line_count =
            "검토 대상 상품 행 개수"

        flag_order_any_review =
            "검토 대상 행 포함 주문";

run;


/*------------------------------------------------------------
  6. 고객ID, 주문일자 순으로 정렬
------------------------------------------------------------*/

proc sort data=crm.w2_order_base;

    by
        customer_id
        order_date
        order_key;

run;


/*============================================================
  7. 원본 거래 데이터 검산
============================================================*/

proc sql;

    create table work.w2_source_qa as

    select
        count(*)
            as source_line_rows
            label="CLEAN_ONLINE 상품 행 수",

        count(distinct order_key)
            as source_distinct_orders
            label="원본 고유 주문 수",

        count(distinct customer_id)
            as source_distinct_customers
            label="원본 고유 고객 수",

        sum(
            case
                when missing(order_key) then 1
                else 0
            end
        )
            as missing_order_key_rows
            label="주문키 결측 행",

        sum(
            case
                when flag_missing_core = 1
                  or flag_return = 1
                  or flag_zero_quantity = 1
                  or flag_invalid_price = 1
                then 1
                else 0
            end
        )
            as excluded_rfm_line_rows
            label="RFM 제외 대상 상품 행"

    from crm.clean_online;

quit;


title "Week 2-1 원본 거래 데이터 검산";

proc print
    data=work.w2_source_qa
    noobs
    label;
run;

title;


/*============================================================
  8. 주문 단위 테이블 검산
============================================================*/

proc sql;

    create table work.w2_order_qa as

    select
        count(*)
            as order_rows
            label="주문 단위 행 수",

        count(distinct order_key)
            as distinct_order_keys
            label="고유 주문키 수",

        count(*)
        - count(distinct order_key)
            as duplicate_order_keys
            label="중복 주문키 수",

        count(distinct customer_id)
            as distinct_customers
            label="고유 고객 수",

        min(order_date)
            as first_order_date
            format=yymmdd10.
            label="최초 주문일",

        max(order_date)
            as last_order_date
            format=yymmdd10.
            label="최종 주문일",

        sum(
            case
                when missing(order_key) then 1
                else 0
            end
        )
            as missing_order_keys
            label="주문키 결측",

        sum(
            case
                when date_value_count > 1 then 1
                else 0
            end
        )
            as multiple_date_orders
            label="복수 거래일자 주문",

        sum(
            case
                when shipping_value_count > 1 then 1
                else 0
            end
        )
            as multiple_shipping_orders
            label="복수 배송료 주문",

        sum(
            case
                when coupon_status_count > 1 then 1
                else 0
            end
        )
            as multiple_coupon_status_orders
            label="복수 쿠폰상태 주문",

        sum(
            case
                when flag_order_excluded_rfm = 1 then 1
                else 0
            end
        )
            as excluded_rfm_orders
            label="RFM 제외 대상 주문",

        sum(
            case
                when flag_order_any_review = 1 then 1
                else 0
            end
        )
            as review_orders
            label="검토 대상 주문"

    from crm.w2_order_base;

quit;


title "Week 2-1 주문 단위 테이블 검산";

proc print
    data=work.w2_order_qa
    noobs
    label;
run;

title;


/*============================================================
  9. 주문 단위 수치형 변수 요약
============================================================*/

title "Week 2-1 주문 단위 수치형 변수 요약";

proc means data=crm.w2_order_base
    n
    mean
    std
    min
    p25
    median
    p75
    p99
    max
    maxdec=2;

    var
        line_count
        product_count
        category_count
        order_quantity
        order_gross_amount
        order_shipping_fee
        order_gross_with_shipping;

run;

title;


/*============================================================
  10. 쿠폰상태 구성 확인
============================================================*/

title "Week 2-1 주문별 쿠폰 사용 및 상태 구성";

proc freq data=crm.w2_order_base;

    tables
        coupon_used_order
        coupon_status_count
        coupon_used_order * coupon_status_count
        / missing;

run;

title;


/*============================================================
  11. 최종 주문 단위 데이터 앞 10행 확인
============================================================*/

title "CRM.W2_ORDER_BASE 앞 10행";

proc print
    data=crm.w2_order_base(obs=10)
    label;

    var
        order_key
        customer_id
        transaction_id
        order_date
        order_month
        line_count
        product_count
        category_count
        order_quantity
        order_gross_amount
        order_shipping_fee
        order_gross_with_shipping
        coupon_used_order
        coupon_status_count
        flag_order_excluded_rfm
        flag_order_any_review;

run;

title;


/*============================================================
  12. 최종 테이블 구조 확인
============================================================*/

title "CRM.W2_ORDER_BASE 데이터 구조";

proc contents
    data=crm.w2_order_base
    varnum;

run;

title;

/*============================================================
  Week 2-2. 고객별 RFM 지표 생성

  입력 테이블
  - CRM.W2_ORDER_BASE
  - 주문 한 건당 한 행

  출력 테이블
  - CRM.W2_RFM
  - 고객 한 명당 한 행

  RFM 정의
  - Recency   : 마지막 구매 이후 경과일
  - Frequency : 서로 다른 주문 횟수
  - Monetary  : 고객의 누적 상품 구매금액
============================================================*/

options validvarname=any;


/*------------------------------------------------------------
  1. CRM 라이브러리 연결

  SAS 세션을 다시 시작하면 라이브러리 할당이 사라지므로
  프로그램을 실행할 때마다 LIBNAME 문장을 실행합니다.
------------------------------------------------------------*/

libname crm "/home/student/open";


/* 라이브러리 할당 결과를 로그에서 확인 */
libname crm list;


/*------------------------------------------------------------
  2. 이전 실행 결과 삭제

  코드를 다시 실행해도 충돌하지 않도록
  이번 단계에서 생성하는 테이블만 삭제합니다.
------------------------------------------------------------*/

proc datasets library=work nolist nowarn;

    delete
        w2_rfm_agg
        w2_rfm_qa
        w2_rfm_reconciliation;

quit;


proc datasets library=crm nolist nowarn;

    delete w2_rfm;

quit;


/*------------------------------------------------------------
  3. RFM 분석 기준일 계산

  분석 기준일
  = 전체 유효 주문의 마지막 날짜 + 1일

  현재 데이터가 2019-12-31까지 존재한다면
  기준일은 2020-01-01이 됩니다.
------------------------------------------------------------*/

/* 매크로 변수 초기화 */
%let RFM_REFERENCE_DATE=.;
%let RFM_REFERENCE_DATE_TEXT=;


/* 유효 주문의 마지막 날짜 다음 날을 기준일로 저장 */
proc sql noprint;

    select
        max(order_date) + 1,

        put(
            max(order_date) + 1,
            yymmdd10.
        )

    into
        :RFM_REFERENCE_DATE trimmed,
        :RFM_REFERENCE_DATE_TEXT trimmed

    from crm.w2_order_base

    where coalesce(
        flag_order_excluded_rfm,
        1
    ) = 0;

quit;


/* 계산된 기준일을 SAS 로그에 출력 */
%put NOTE: ==============================================;
%put NOTE: RFM 분석 기준일 = &RFM_REFERENCE_DATE_TEXT;
%put NOTE: RFM 기준일 SAS 숫자값 = &RFM_REFERENCE_DATE;
%put NOTE: ==============================================;


/*------------------------------------------------------------
  4. 주문 데이터를 고객 단위로 집계

  다음 주문만 RFM 계산에 사용합니다.
  - flag_order_excluded_rfm = 0

  상위 1% 이상치는 제외하지 않습니다.
------------------------------------------------------------*/

proc sql;

    create table work.w2_rfm_agg as

    select
        /* 고객 식별자 */
        customer_id,


        /* 고객의 최초 구매일 */
        min(order_date)
            as first_purchase_date
            format=yymmdd10.,


        /* 고객의 마지막 구매일 */
        max(order_date)
            as last_purchase_date
            format=yymmdd10.,


        /*
          Recency

          기준일에서 마지막 구매일을 뺀 값입니다.
          값이 작을수록 최근에 구매한 고객입니다.
        */
        &RFM_REFERENCE_DATE
        - max(order_date)
            as recency,


        /*
          Frequency

          고객별 서로 다른 주문키 개수입니다.
          상품 행 개수가 아니라 실제 주문 횟수입니다.
        */
        count(distinct order_key)
            as frequency,


        /*
          Monetary

          배송료와 할인액을 제외한
          고객의 누적 상품 구매금액입니다.
        */
        sum(order_gross_amount)
            as monetary
            format=comma18.2,


        /* 배송료를 포함한 누적 금액 */
        sum(order_gross_with_shipping)
            as monetary_with_shipping
            format=comma18.2,


        /* 고객이 부담한 배송료 합계 */
        sum(order_shipping_fee)
            as total_shipping_fee
            format=comma18.2,


        /* 전체 구매 수량 */
        sum(order_quantity)
            as total_quantity,


        /* 실제 구매가 발생한 날짜 수 */
        count(distinct order_date)
            as purchase_day_count,


        /* 주문당 평균 상품 구매금액 */
        mean(order_gross_amount)
            as avg_order_value
            format=comma18.2,


        /* 주문당 평균 구매 수량 */
        mean(order_quantity)
            as avg_quantity_per_order
            format=comma12.2,


        /* 주문당 평균 제품 종류 수 */
        mean(product_count)
            as avg_products_per_order
            format=comma12.2,


        /* 주문당 평균 카테고리 종류 수 */
        mean(category_count)
            as avg_categories_per_order
            format=comma12.2,


        /*
          쿠폰 사용 주문 수

          주문 안에 Used 상태가 하나라도 있으면
          해당 주문을 쿠폰 사용 주문으로 계산합니다.
        */
        sum(
            case
                when coupon_used_order = 1 then 1
                else 0
            end
        )
            as coupon_used_orders,


        /*
          쿠폰을 클릭했지만 사용하지 않은 주문 수

          Used가 없고 Clicked만 있는 주문을 계산합니다.
        */
        sum(
            case
                when coupon_used_order = 0
                 and coupon_clicked_order = 1
                then 1
                else 0
            end
        )
            as coupon_clicked_only_orders,


        /*
          쿠폰을 사용하거나 클릭하지 않은 주문 수

          Used와 Clicked가 모두 없고
          Not Used만 있는 주문을 계산합니다.
        */
        sum(
            case
                when coupon_used_order = 0
                 and coupon_clicked_order = 0
                 and coupon_not_used_order = 1
                then 1
                else 0
            end
        )
            as coupon_not_used_only_orders,


        /* 예상하지 않은 쿠폰상태가 포함된 주문 수 */
        sum(
            case
                when flag_order_invalid_coupon = 1 then 1
                else 0
            end
        )
            as invalid_coupon_orders,


        /* 상위 1% 수량이 포함된 주문 수 */
        sum(
            case
                when flag_order_high_quantity = 1 then 1
                else 0
            end
        )
            as high_quantity_orders,


        /* 상위 1% 가격이 포함된 주문 수 */
        sum(
            case
                when flag_order_high_price = 1 then 1
                else 0
            end
        )
            as high_price_orders,


        /* 상위 1% 배송료가 포함된 주문 수 */
        sum(
            case
                when flag_order_high_shipping = 1 then 1
                else 0
            end
        )
            as high_shipping_orders,


        /* 할인정보가 연결되지 않은 주문 수 */
        sum(
            case
                when flag_order_discount_unmatched = 1 then 1
                else 0
            end
        )
            as discount_unmatched_orders,


        /* 하나 이상의 검토 플래그가 있는 주문 수 */
        sum(
            case
                when flag_order_any_review = 1 then 1
                else 0
            end
        )
            as review_order_count


    from crm.w2_order_base


    /*
      명확한 오류가 포함되지 않은 주문만
      RFM 계산에 사용합니다.

      결측 플래그는 유효한 주문으로 간주하지 않습니다.
    */
    where coalesce(
        flag_order_excluded_rfm,
        1
    ) = 0


    /* 고객 한 명당 한 행으로 집계 */
    group by customer_id;

quit;


/*------------------------------------------------------------
  5. 고객 파생변수 생성 및 영구 테이블 저장
------------------------------------------------------------*/

data crm.w2_rfm;

    set work.w2_rfm_agg;


    /*
      고객 활동기간

      최초 구매일부터 마지막 구매일까지의 기간입니다.
      한 번만 구매한 고객은 0일입니다.
    */
    active_days =
        last_purchase_date - first_purchase_date;


    /*
      최초 구매 이후 관찰기간

      최초 구매일부터 분석 기준일까지의 기간입니다.
    */
    customer_observation_days =
        &RFM_REFERENCE_DATE - first_purchase_date;


    /*
      평균 주문 간격

      주문이 두 번 이상인 고객만 계산합니다.
      주문이 한 번이면 주문 간격을 계산할 수 없습니다.
    */
    if frequency > 1 then

        avg_days_between_orders =
            active_days / (frequency - 1);

    else
        call missing(avg_days_between_orders);


    /* 두 번 이상 주문한 고객이면 재구매 고객으로 표시 */
    repeat_customer_flag = (
        frequency >= 2
    );


    /*
      주문 중 쿠폰을 사용한 주문의 비율

      예:
      전체 주문 10회, 쿠폰 사용 주문 4회
      → 쿠폰 활용률 40%
    */
    if frequency > 0 then do;

        coupon_usage_rate =
            coupon_used_orders / frequency;

        review_order_rate =
            review_order_count / frequency;

    end;

    else do;

        call missing(coupon_usage_rate);
        call missing(review_order_rate);

    end;


    /*
      쿠폰 행동 세 가지가 전체 주문 수와 맞는지 검사합니다.

      정상이라면 다음 세 값의 합계가 Frequency와 같습니다.
      - 쿠폰 사용
      - 클릭만 함
      - 사용하지 않음
    */
    coupon_classified_orders =
        sum(
            coupon_used_orders,
            coupon_clicked_only_orders,
            coupon_not_used_only_orders
        );


    coupon_unclassified_orders =
        frequency - coupon_classified_orders;


    /* 분석 기준일을 각 고객 행에도 저장 */
    rfm_reference_date = &RFM_REFERENCE_DATE;


    format
        first_purchase_date       yymmdd10.
        last_purchase_date        yymmdd10.
        rfm_reference_date        yymmdd10.
        monetary                  comma18.2
        monetary_with_shipping    comma18.2
        total_shipping_fee        comma18.2
        avg_order_value           comma18.2
        avg_quantity_per_order    comma12.2
        avg_products_per_order    comma12.2
        avg_categories_per_order  comma12.2
        avg_days_between_orders   comma12.2
        coupon_usage_rate         percent8.2
        review_order_rate         percent8.2;


    label
        customer_id =
            "고객ID"

        first_purchase_date =
            "최초 구매일"

        last_purchase_date =
            "마지막 구매일"

        rfm_reference_date =
            "RFM 분석 기준일"

        recency =
            "최근 구매 후 경과일"

        frequency =
            "총 주문 횟수"

        monetary =
            "누적 상품 구매금액"

        monetary_with_shipping =
            "배송료 포함 누적금액"

        total_shipping_fee =
            "누적 배송료"

        total_quantity =
            "전체 구매 수량"

        purchase_day_count =
            "구매 발생 날짜 수"

        avg_order_value =
            "주문당 평균 상품금액"

        avg_quantity_per_order =
            "주문당 평균 수량"

        avg_products_per_order =
            "주문당 평균 제품 종류 수"

        avg_categories_per_order =
            "주문당 평균 카테고리 종류 수"

        active_days =
            "최초 구매일부터 마지막 구매일까지 기간"

        customer_observation_days =
            "최초 구매일부터 기준일까지 기간"

        avg_days_between_orders =
            "평균 주문 간격"

        repeat_customer_flag =
            "재구매 고객 여부"

        coupon_used_orders =
            "쿠폰 사용 주문 수"

        coupon_clicked_only_orders =
            "쿠폰 클릭 후 미사용 주문 수"

        coupon_not_used_only_orders =
            "쿠폰 미사용 주문 수"

        invalid_coupon_orders =
            "비정상 쿠폰상태 주문 수"

        coupon_usage_rate =
            "쿠폰 사용 주문 비율"

        coupon_classified_orders =
            "쿠폰행동 분류 완료 주문 수"

        coupon_unclassified_orders =
            "쿠폰행동 미분류 주문 수"

        high_quantity_orders =
            "고수량 주문 수"

        high_price_orders =
            "고가격 주문 수"

        high_shipping_orders =
            "고배송료 주문 수"

        discount_unmatched_orders =
            "할인정보 미매칭 주문 수"

        review_order_count =
            "검토 대상 주문 수"

        review_order_rate =
            "검토 대상 주문 비율";

run;


/*------------------------------------------------------------
  6. 고객ID 순으로 정렬
------------------------------------------------------------*/

proc sort data=crm.w2_rfm;

    by customer_id;

run;


/*============================================================
  7. 고객 단위 RFM 테이블 검산
============================================================*/

proc sql;

    create table work.w2_rfm_qa as

    select
        count(*)
            as customer_rows
            label="고객 단위 행 수",

        count(distinct customer_id)
            as distinct_customers
            label="고유 고객 수",

        count(*)
        - count(distinct customer_id)
            as duplicate_customer_ids
            label="중복 고객ID 수",

        sum(
            case
                when missing(customer_id) then 1
                else 0
            end
        )
            as missing_customer_ids
            label="고객ID 결측",

        sum(
            case
                when missing(recency) then 1
                else 0
            end
        )
            as missing_recency
            label="Recency 결측",

        sum(
            case
                when missing(frequency) then 1
                else 0
            end
        )
            as missing_frequency
            label="Frequency 결측",

        sum(
            case
                when missing(monetary) then 1
                else 0
            end
        )
            as missing_monetary
            label="Monetary 결측",

        sum(
            case
                when recency < 0 then 1
                else 0
            end
        )
            as invalid_recency
            label="음수 Recency",

        sum(
            case
                when frequency <= 0 then 1
                else 0
            end
        )
            as invalid_frequency
            label="0 이하 Frequency",

        sum(
            case
                when monetary <= 0 then 1
                else 0
            end
        )
            as invalid_monetary
            label="0 이하 Monetary",

        sum(
            case
                when coupon_usage_rate < 0
                  or coupon_usage_rate > 1
                then 1
                else 0
            end
        )
            as invalid_coupon_rate
            label="쿠폰 활용률 범위 위반",

        sum(
            case
                when coupon_unclassified_orders ne 0
                then 1
                else 0
            end
        )
            as cust_with_unclassified_orders
            label="쿠폰 미분류 주문 보유 고객"

    from crm.w2_rfm;

quit;


title "Week 2-2 고객 단위 RFM 검산";

proc print
    data=work.w2_rfm_qa
    noobs
    label;

run;

title;


/*============================================================
  8. 주문 테이블과 RFM 테이블 합계 일치 확인

  다음 두 차이는 0이어야 합니다.
  - Frequency 차이
  - Monetary 차이
============================================================*/

proc sql;

    create table work.w2_rfm_reconciliation as

    select
        /* 주문 테이블의 유효 주문 수 */
        (
            select count(*)

            from crm.w2_order_base

            where coalesce(
                flag_order_excluded_rfm,
                1
            ) = 0
        )
            as valid_order_rows
            label="유효 주문 수",


        /* RFM 테이블의 Frequency 합계 */
        (
            select sum(frequency)

            from crm.w2_rfm
        )
            as total_frequency
            label="Frequency 합계",


        /* 두 주문 수의 차이 */
        (
            select sum(frequency)
            from crm.w2_rfm
        )
        -
        (
            select count(*)
            from crm.w2_order_base
            where coalesce(
                flag_order_excluded_rfm,
                1
            ) = 0
        )
            as frequency_difference
            label="Frequency 차이",


        /* 주문 테이블의 상품금액 합계 */
        (
            select sum(order_gross_amount)

            from crm.w2_order_base

            where coalesce(
                flag_order_excluded_rfm,
                1
            ) = 0
        )
            as valid_order_monetary
            format=comma18.2
            label="주문 테이블 금액 합계",


        /* 고객 RFM 테이블의 Monetary 합계 */
        (
            select sum(monetary)

            from crm.w2_rfm
        )
            as total_rfm_monetary
            format=comma18.2
            label="RFM Monetary 합계",


        /* 두 금액의 차이 */
        (
            select sum(monetary)
            from crm.w2_rfm
        )
        -
        (
            select sum(order_gross_amount)
            from crm.w2_order_base
            where coalesce(
                flag_order_excluded_rfm,
                1
            ) = 0
        )
            as monetary_difference
            format=comma18.2
            label="Monetary 차이"

    from sashelp.class(obs=1);

quit;


title "Week 2-2 주문 데이터와 RFM 합계 비교";

proc print
    data=work.w2_rfm_reconciliation
    noobs
    label;

run;

title;


/*============================================================
  9. RFM 기초통계 확인
============================================================*/

title "Week 2-2 RFM 기초통계";

proc means data=crm.w2_rfm
    n
    nmiss
    mean
    std
    min
    p1
    p25
    median
    p75
    p99
    max
    maxdec=2;

    var
        recency
        frequency
        monetary
        avg_order_value
        total_quantity
        active_days
        avg_days_between_orders
        coupon_usage_rate;

run;

title;


/*============================================================
  10. 재구매 고객 분포 확인
============================================================*/

title "Week 2-2 재구매 고객 여부";

proc freq data=crm.w2_rfm;

    tables
        repeat_customer_flag
        / missing;

run;

title;


/*============================================================
  11. 최종 RFM 데이터 앞 10행 확인
============================================================*/

title "CRM.W2_RFM 앞 10행";

proc print
    data=crm.w2_rfm(obs=10)
    label;

    var
        customer_id
        first_purchase_date
        last_purchase_date
        rfm_reference_date
        recency
        frequency
        monetary
        avg_order_value
        total_quantity
        active_days
        avg_days_between_orders
        coupon_used_orders
        coupon_usage_rate
        repeat_customer_flag
        review_order_count;

run;

title;


/*============================================================
  12. 최종 RFM 테이블 구조 확인
============================================================*/

title "CRM.W2_RFM 데이터 구조";

proc contents
    data=crm.w2_rfm
    varnum;

run;

title;

/*============================================================
  Week 2-3. 고객정보 및 할인 파생변수 결합과 EDA

  입력 테이블
  - CRM.W2_RFM
  - CRM.W2_ORDER_BASE
  - CRM.CLEAN_CUSTOMER
  - CRM.CLEAN_ONLINE

  출력 테이블
  - CRM.W2_CUSTOMER_FEATURES

  분석 단위
  - 고객 한 명당 한 행
============================================================*/

options validvarname=any;


/*------------------------------------------------------------
  1. CRM 라이브러리 연결
------------------------------------------------------------*/

libname crm "/home/student/open";


/* 라이브러리 할당 결과를 로그에서 확인 */
libname crm list;


/*------------------------------------------------------------
  2. 이전 실행 결과 삭제

  이번 단계에서 생성하는 테이블만 삭제합니다.
  기존 RFM과 정제 테이블은 삭제하지 않습니다.
------------------------------------------------------------*/

proc datasets library=work nolist nowarn;

    delete
        w2_discount_lines
        w2_discount_calc
        w2_discount_customer
        w2_customer_joined
        w2_customer_qa
        w2_customer_recon;

quit;


proc datasets library=crm nolist nowarn;

    delete w2_customer_features;

quit;


/*============================================================
  3. 유효 주문에 포함된 상품 행 가져오기

  W2_ORDER_BASE에서 RFM 제외 대상이 아닌 주문만 선택한 후,
  해당 주문의 상품 상세 행을 CLEAN_ONLINE에서 가져옵니다.
============================================================*/

proc sql;

    create table work.w2_discount_lines as

    select
        o.customer_id,
        o.order_key,
        o.product_id,
        o.product_category,
        o.quantity,
        o.avg_price,
        o.coupon_status,
        o.offered_discount_pct,
        o.flag_discount_unmatched

    from crm.clean_online as o

    inner join crm.w2_order_base as b

        on o.order_key = b.order_key

    where coalesce(
        b.flag_order_excluded_rfm,
        1
    ) = 0;

quit;


/*============================================================
  4. 상품 행별 쿠폰 및 할인 계산

  실제 최종 결제금액이 없으므로 할인액은 다음 조건에서
  추정값으로 계산합니다.

  1. coupon_status가 Used
  2. 할인정보가 정상적으로 연결됨
  3. 할인율이 0~100 범위에 있음
============================================================*/

data work.w2_discount_calc;

    set work.w2_discount_lines;


    /* 상품 행의 할인 전 금액 */
    line_gross_amount =
        quantity * avg_price;


    /* 해당 상품 행에서 쿠폰을 사용했는지 확인 */
    coupon_used_line = (
        upcase(strip(coupon_status)) = "USED"
    );


    /* 할인 계산 관련 플래그 초기화 */
    discount_matched_used   = 0;
    discount_unmatched_used = 0;


    /*
      쿠폰 사용 행 중 할인정보가 정상적으로 연결된 경우
    */
    if coupon_used_line = 1 then do;

        if flag_discount_unmatched = 0
           and not missing(offered_discount_pct)
           and offered_discount_pct >= 0
           and offered_discount_pct <= 100
        then
            discount_matched_used = 1;

        else
            discount_unmatched_used = 1;

    end;


    /* 쿠폰 사용 상품의 할인 전 금액 */
    if coupon_used_line = 1 then

        coupon_used_gross_amount =
            line_gross_amount;

    else
        coupon_used_gross_amount = 0;


    /*
      할인정보가 정상적으로 연결된 쿠폰 사용 행의 금액

      가중평균 할인율을 계산할 때 분모로 사용합니다.
    */
    if discount_matched_used = 1 then

        matched_used_gross_amount =
            line_gross_amount;

    else
        matched_used_gross_amount = 0;


    /*
      확인 가능한 할인액 추정값

      할인율이 10이라면 10%이므로 100으로 나눕니다.
    */
    if discount_matched_used = 1 then

        known_discount_amount =
            line_gross_amount
            * offered_discount_pct
            / 100;

    else
        known_discount_amount = 0;


    format
        line_gross_amount
        coupon_used_gross_amount
        matched_used_gross_amount
        known_discount_amount
        comma18.2;


    label
        line_gross_amount =
            "상품 행 할인 전 금액"

        coupon_used_line =
            "쿠폰 사용 상품 행"

        discount_matched_used =
            "할인정보 연결 쿠폰 사용 행"

        discount_unmatched_used =
            "할인정보 미연결 쿠폰 사용 행"

        coupon_used_gross_amount =
            "쿠폰 사용 상품 할인 전 금액"

        matched_used_gross_amount =
            "할인정보 연결 쿠폰 사용 금액"

        known_discount_amount =
            "확인 가능한 추정 할인액";

run;


/*============================================================
  5. 할인 관련 변수를 고객 단위로 집계
============================================================*/

proc sql;

    create table work.w2_discount_customer as

    select
        customer_id,


        /* RFM에 사용된 유효 상품 행 개수 */
        count(*)
            as valid_line_count,


        /* 서로 다른 제품 종류 수 */
        count(distinct product_id)
            as unique_product_count,


        /* 서로 다른 카테고리 종류 수 */
        count(distinct product_category)
            as product_category_count,


        /* 쿠폰을 사용한 상품 행 개수 */
        sum(coupon_used_line)
            as coupon_used_lines,


        /* 할인정보가 연결된 쿠폰 사용 행 개수 */
        sum(discount_matched_used)
            as discount_matched_used_lines,


        /* 할인정보가 연결되지 않은 쿠폰 사용 행 개수 */
        sum(discount_unmatched_used)
            as discount_unmatched_used_lines,


        /* 쿠폰을 사용한 상품의 할인 전 금액 */
        sum(coupon_used_gross_amount)
            as coupon_used_gross_amount
            format=comma18.2,


        /* 할인정보가 연결된 쿠폰 사용 상품금액 */
        sum(matched_used_gross_amount)
            as matched_used_gross_amount
            format=comma18.2,


        /* 확인 가능한 추정 할인액 */
        sum(known_discount_amount)
            as known_discount_amount
            format=comma18.2,


        /*
          단순 평균 할인율

          상품금액의 크기를 고려하지 않고
          할인율 자체의 평균을 계산합니다.
        */
        mean(
            case
                when discount_matched_used = 1
                then offered_discount_pct
                else .
            end
        )
            as avg_applied_discount_pct
            format=8.2


    from work.w2_discount_calc

    group by customer_id;

quit;


/*============================================================
  6. RFM, 고객정보, 할인 파생변수 결합

  W2_RFM을 기준으로 LEFT JOIN하므로
  RFM 고객은 모두 유지됩니다.
============================================================*/

proc sql;

    create table work.w2_customer_joined as

    select
        /* 기존 RFM 변수 전체 */
        r.*,


        /* Customer_info의 고객 특성 */
        c.gender,
        c.region,
        c.tenure,


        /* 고객별 상품 및 할인 집계 */
        coalesce(
            d.valid_line_count,
            0
        )
            as valid_line_count,

        coalesce(
            d.unique_product_count,
            0
        )
            as unique_product_count,

        coalesce(
            d.product_category_count,
            0
        )
            as product_category_count,

        coalesce(
            d.coupon_used_lines,
            0
        )
            as coupon_used_lines,

        coalesce(
            d.discount_matched_used_lines,
            0
        )
            as discount_matched_used_lines,

        coalesce(
            d.discount_unmatched_used_lines,
            0
        )
            as discount_unmatched_used_lines,

        coalesce(
            d.coupon_used_gross_amount,
            0
        )
            as coupon_used_gross_amount,

        coalesce(
            d.matched_used_gross_amount,
            0
        )
            as matched_used_gross_amount,

        coalesce(
            d.known_discount_amount,
            0
        )
            as known_discount_amount,

        d.avg_applied_discount_pct,


        /* 고객정보 결합 실패 여부 */
        case
            when missing(c.customer_id) then 1
            else 0
        end
            as flag_customer_info_unmatched,


        /* 할인 파생변수 결합 실패 여부 */
        case
            when missing(d.customer_id) then 1
            else 0
        end
            as flag_discount_feat_missing


    from crm.w2_rfm as r

    left join crm.clean_customer as c

        on r.customer_id = c.customer_id

    left join work.w2_discount_customer as d

        on r.customer_id = d.customer_id;

quit;


/*============================================================
  7. 최종 고객 파생변수 생성
============================================================*/

data crm.w2_customer_features;

    set work.w2_customer_joined;


    /*--------------------------------------------------------
      가입기간을 고려한 주문 및 구매금액
    --------------------------------------------------------*/

    if not missing(tenure)
       and tenure > 0
    then do;

        /* 가입기간 1개월당 주문 횟수 */
        orders_per_tenure_month =
            frequency / tenure;

        /* 가입기간 1개월당 상품 구매금액 */
        monetary_per_tenure_month =
            monetary / tenure;

    end;

    else do;

        call missing(orders_per_tenure_month);
        call missing(monetary_per_tenure_month);

    end;


    /*--------------------------------------------------------
      상품 행 기준 쿠폰 사용 비율
    --------------------------------------------------------*/

    if valid_line_count > 0 then

        coupon_used_line_rate =
            coupon_used_lines
            / valid_line_count;

    else
        call missing(coupon_used_line_rate);


    /*--------------------------------------------------------
      쿠폰 사용 행의 할인정보 연결률
    --------------------------------------------------------*/

    if coupon_used_lines > 0 then

        discount_match_rate =
            discount_matched_used_lines
            / coupon_used_lines;

    else
        call missing(discount_match_rate);


    /*--------------------------------------------------------
      상품금액을 고려한 가중평균 할인율

      총 할인액 ÷ 할인정보가 연결된 쿠폰 사용 상품금액
    --------------------------------------------------------*/

    if matched_used_gross_amount > 0 then

        weighted_discount_rate =
            known_discount_amount
            / matched_used_gross_amount;

    else
        call missing(weighted_discount_rate);


    /*--------------------------------------------------------
      쿠폰 사용 상품이 전체 구매금액에서 차지하는 비율
    --------------------------------------------------------*/

    if monetary > 0 then

        coupon_used_sales_share =
            coupon_used_gross_amount
            / monetary;

    else
        call missing(coupon_used_sales_share);


    /*--------------------------------------------------------
      확인 가능한 할인액만 차감한 금액

      할인정보 미연결 행의 할인액은 알 수 없으므로
      실제 최종 결제금액과는 다를 수 있습니다.
    --------------------------------------------------------*/

    gross_less_known_discount =
        monetary - known_discount_amount;


    /*
      할인정보 미연결 상태에서 쿠폰을 사용한 상품 행이
      하나라도 있으면 할인액 불확실 고객으로 표시합니다.
    */
    flag_discount_uncertain = (
        discount_unmatched_used_lines > 0
    );


    format
        monetary_per_tenure_month
        coupon_used_gross_amount
        matched_used_gross_amount
        known_discount_amount
        gross_less_known_discount
            comma18.2

        orders_per_tenure_month
            comma12.2

        coupon_usage_rate
        coupon_used_line_rate
        discount_match_rate
        weighted_discount_rate
        coupon_used_sales_share
        review_order_rate
            percent8.2

        avg_applied_discount_pct
            8.2;


    label
        gender =
            "성별"

        region =
            "고객지역"

        tenure =
            "가입기간"

        valid_line_count =
            "유효 상품 행 개수"

        unique_product_count =
            "구매한 제품 종류 수"

        product_category_count =
            "구매한 카테고리 종류 수"

        coupon_used_lines =
            "쿠폰 사용 상품 행 수"

        discount_matched_used_lines =
            "할인정보 연결 쿠폰 사용 행 수"

        discount_unmatched_used_lines =
            "할인정보 미연결 쿠폰 사용 행 수"

        coupon_used_gross_amount =
            "쿠폰 사용 상품 할인 전 금액"

        matched_used_gross_amount =
            "할인정보 연결 쿠폰 사용 금액"

        known_discount_amount =
            "확인 가능한 추정 할인액"

        avg_applied_discount_pct =
            "적용 할인율 단순평균(%)"

        orders_per_tenure_month =
            "가입기간 월당 주문 횟수"

        monetary_per_tenure_month =
            "가입기간 월당 구매금액"

        coupon_used_line_rate =
            "상품 행 기준 쿠폰 사용률"

        discount_match_rate =
            "쿠폰 사용 행 할인정보 연결률"

        weighted_discount_rate =
            "상품금액 가중평균 할인율"

        coupon_used_sales_share =
            "쿠폰 사용 상품금액 비중"

        gross_less_known_discount =
            "확인된 할인액 차감 상품금액"

        flag_customer_info_unmatched =
            "고객정보 미매칭"

        flag_discount_feat_missing =
            "할인 파생변수 미매칭"

        flag_discount_uncertain =
            "할인액 불확실 고객";

run;


/*------------------------------------------------------------
  8. 고객ID 순으로 정렬
------------------------------------------------------------*/

proc sort data=crm.w2_customer_features;

    by customer_id;

run;


/*============================================================
  9. 최종 고객 테이블 검산

  요청한 짧은 변수명
  cust_with_unclassified_orders를 사용합니다.
============================================================*/

proc sql;

    create table work.w2_customer_qa as

    select
        count(*)
            as customer_rows
            label="고객 단위 행 수",

        count(distinct customer_id)
            as distinct_customers
            label="고유 고객 수",

        count(*)
        - count(distinct customer_id)
            as duplicate_customer_ids
            label="중복 고객ID 수",

        sum(
            case
                when missing(customer_id) then 1
                else 0
            end
        )
            as missing_customer_ids
            label="고객ID 결측",

        sum(
            case
                when missing(gender) then 1
                else 0
            end
        )
            as missing_gender
            label="성별 결측",

        sum(
            case
                when missing(region) then 1
                else 0
            end
        )
            as missing_region
            label="지역 결측",

        sum(
            case
                when missing(tenure) then 1
                else 0
            end
        )
            as missing_tenure
            label="가입기간 결측",

        sum(
            case
                when tenure <= 0 then 1
                else 0
            end
        )
            as invalid_tenure
            label="0 이하 가입기간",

        sum(
            case
                when flag_customer_info_unmatched = 1
                then 1
                else 0
            end
        )
            as customer_info_unmatched
            label="고객정보 미매칭",

        sum(
            case
                when flag_discount_feat_missing = 1
                then 1
                else 0
            end
        )
            as discount_feat_missing
            label="할인 파생변수 미매칭",

        sum(
            case
                when coupon_unclassified_orders ne 0
                then 1
                else 0
            end
        )
            as cust_with_unclassified_orders
            label="쿠폰 미분류 주문 보유 고객",

        sum(
            case
                when coupon_usage_rate < 0
                  or coupon_usage_rate > 1
                then 1
                else 0
            end
        )
            as invalid_order_coupon_rate
            label="주문 기준 쿠폰율 오류",

        sum(
            case
                when coupon_used_line_rate < 0
                  or coupon_used_line_rate > 1
                then 1
                else 0
            end
        )
            as invalid_line_coupon_rate
            label="상품 행 기준 쿠폰율 오류",

        sum(
            case
                when discount_match_rate < 0
                  or discount_match_rate > 1
                then 1
                else 0
            end
        )
            as invalid_discount_match_rate
            label="할인정보 연결률 오류",

        sum(
            case
                when weighted_discount_rate < 0
                  or weighted_discount_rate > 1
                then 1
                else 0
            end
        )
            as invalid_weighted_discount
            label="가중평균 할인율 오류",

        sum(
            case
                when flag_discount_uncertain = 1
                then 1
                else 0
            end
        )
            as discount_uncertain_customers
            label="할인액 불확실 고객"

    from crm.w2_customer_features;

quit;


title "Week 2-3 고객 파생변수 검산";

proc print
    data=work.w2_customer_qa
    noobs
    label;

run;

title;


/*============================================================
  10. W2_RFM과 최종 고객 테이블 일치 확인

  고객 수와 Monetary 합계가 그대로 유지되어야 합니다.
============================================================*/

proc sql;

    create table work.w2_customer_recon as

    select
        /* 기존 RFM 고객 수 */
        (
            select count(*)
            from crm.w2_rfm
        )
            as rfm_customer_rows
            label="RFM 고객 수",


        /* 최종 고객 테이블 고객 수 */
        (
            select count(*)
            from crm.w2_customer_features
        )
            as feature_customer_rows
            label="최종 고객 수",


        /* 두 테이블의 고객 수 차이 */
        (
            select count(*)
            from crm.w2_customer_features
        )
        -
        (
            select count(*)
            from crm.w2_rfm
        )
            as customer_row_difference
            label="고객 수 차이",


        /* 기존 RFM Monetary 합계 */
        (
            select sum(monetary)
            from crm.w2_rfm
        )
            as rfm_monetary
            format=comma18.2
            label="RFM Monetary 합계",


        /* 최종 테이블 Monetary 합계 */
        (
            select sum(monetary)
            from crm.w2_customer_features
        )
            as feature_monetary
            format=comma18.2
            label="최종 Monetary 합계",


        /* Monetary 차이 */
        (
            select sum(monetary)
            from crm.w2_customer_features
        )
        -
        (
            select sum(monetary)
            from crm.w2_rfm
        )
            as monetary_difference
            format=comma18.2
            label="Monetary 차이"

    from sashelp.class(obs=1);

quit;


title "Week 2-3 RFM과 최종 테이블 일치 확인";

proc print
    data=work.w2_customer_recon
    noobs
    label;

run;

title;


/*============================================================
  11. 고객 특성별 빈도 확인
============================================================*/

title "Week 2-3 성별 분포";

proc freq data=crm.w2_customer_features;

    tables gender / missing;

run;


title "Week 2-3 지역별 분포";

proc freq data=crm.w2_customer_features;

    tables region / missing;

run;


title "Week 2-3 성별과 지역 교차분포";

proc freq data=crm.w2_customer_features;

    tables gender * region
        / missing norow nocol;

run;

title;


/*============================================================
  12. 주요 수치형 변수 기초통계
============================================================*/

title "Week 2-3 고객 파생변수 기초통계";

proc means data=crm.w2_customer_features
    n
    nmiss
    mean
    std
    min
    p1
    p25
    median
    p75
    p99
    max
    maxdec=2;

    var
        recency
        frequency
        monetary
        tenure
        avg_order_value
        orders_per_tenure_month
        monetary_per_tenure_month
        unique_product_count
        product_category_count
        coupon_usage_rate
        coupon_used_line_rate
        discount_match_rate
        weighted_discount_rate
        coupon_used_sales_share
        known_discount_amount;

run;

title;


/*============================================================
  13. 최종 테이블 앞 10행 확인
============================================================*/

title "CRM.W2_CUSTOMER_FEATURES 앞 10행";

proc print
    data=crm.w2_customer_features(obs=10)
    label;

    var
        customer_id
        gender
        region
        tenure
        recency
        frequency
        monetary
        avg_order_value
        unique_product_count
        product_category_count
        coupon_used_orders
        coupon_usage_rate
        coupon_used_lines
        coupon_used_line_rate
        avg_applied_discount_pct
        weighted_discount_rate
        known_discount_amount
        flag_discount_uncertain;

run;

title;


/*============================================================
  14. 최종 테이블 구조 확인
============================================================*/

title "CRM.W2_CUSTOMER_FEATURES 데이터 구조";

proc contents
    data=crm.w2_customer_features
    varnum;

run;

title;


/*============================================================
  15. PROC PYTHON을 이용한 고객 단위 EDA

  아래 분석은 최종 SAS 테이블을 Pandas DataFrame으로
  불러와 기초통계와 분포를 확인합니다.

  SAS 데이터셋은 변경하지 않습니다.
============================================================*/

proc python;
submit;

import pandas as pd
import numpy as np
import matplotlib.pyplot as plt


#------------------------------------------------------------
# 15-1. SAS 데이터셋을 Pandas DataFrame으로 변환
#------------------------------------------------------------

df = SAS.sd2df("crm.w2_customer_features")


print("=" * 70)
print("Week 2-3 고객 단위 EDA")
print("=" * 70)

print("\n데이터 크기:")
print(df.shape)

print("\n변수 목록:")
print(df.columns.tolist())

print("\n앞 5행:")
print(df.head().to_string())


#------------------------------------------------------------
# 15-2. 주요 숫자형 변수의 자료형 정리
#------------------------------------------------------------

numeric_cols = [
    "recency",
    "frequency",
    "monetary",
    "tenure",
    "avg_order_value",
    "orders_per_tenure_month",
    "monetary_per_tenure_month",
    "unique_product_count",
    "product_category_count",
    "coupon_usage_rate",
    "coupon_used_line_rate",
    "discount_match_rate",
    "weighted_discount_rate",
    "coupon_used_sales_share",
    "known_discount_amount"
]

for col in numeric_cols:

    if col in df.columns:

        df[col] = pd.to_numeric(
            df[col],
            errors="coerce"
        )


#------------------------------------------------------------
# 15-3. 결측값 확인
#------------------------------------------------------------

missing_summary = pd.DataFrame({
    "missing_count": df.isna().sum(),
    "missing_rate_pct": (
        df.isna().mean() * 100
    ).round(2)
})

missing_summary = missing_summary[
    missing_summary["missing_count"] > 0
]


print("\n결측값이 존재하는 변수:")

if len(missing_summary) == 0:

    print("결측값이 없습니다.")

else:

    print(missing_summary.to_string())


#------------------------------------------------------------
# 15-4. 주요 수치형 변수 기초통계
#------------------------------------------------------------

eda_cols = [
    col
    for col in numeric_cols
    if col in df.columns
]

print("\n주요 수치형 변수 기초통계:")

print(
    df[eda_cols]
    .describe()
    .T
    .round(2)
    .to_string()
)


#------------------------------------------------------------
# 15-5. RFM 변수의 왜도 확인
#
# 왜도가 양수이고 크면 오른쪽으로 긴 분포입니다.
#------------------------------------------------------------

rfm_cols = [
    "recency",
    "frequency",
    "monetary"
]

print("\nRFM 변수 왜도:")

print(
    df[rfm_cols]
    .skew()
    .round(3)
    .to_string()
)


#------------------------------------------------------------
# 15-6. 지역별 고객 특성 요약
#------------------------------------------------------------

region_summary = (
    df.groupby(
        "region",
        dropna=False
    )
    .agg(
        customers=("customer_id", "nunique"),
        avg_recency=("recency", "mean"),
        avg_frequency=("frequency", "mean"),
        avg_monetary=("monetary", "mean"),
        avg_coupon_rate=("coupon_usage_rate", "mean")
    )
    .sort_values(
        "customers",
        ascending=False
    )
    .round(2)
)

print("\n지역별 고객 특성:")

print(region_summary.to_string())


#------------------------------------------------------------
# 15-7. 성별 고객 특성 요약
#------------------------------------------------------------

gender_summary = (
    df.groupby(
        "gender",
        dropna=False
    )
    .agg(
        customers=("customer_id", "nunique"),
        avg_recency=("recency", "mean"),
        avg_frequency=("frequency", "mean"),
        avg_monetary=("monetary", "mean"),
        avg_coupon_rate=("coupon_usage_rate", "mean")
    )
    .round(2)
)

print("\n성별 고객 특성:")

print(gender_summary.to_string())


#------------------------------------------------------------
# 15-8. RFM 분포 그래프
#------------------------------------------------------------

fig, axes = plt.subplots(
    1,
    3,
    figsize=(15, 4)
)


axes[0].hist(
    df["recency"].dropna(),
    bins=30,
    color="steelblue",
    edgecolor="white"
)

axes[0].set_title("Recency Distribution")
axes[0].set_xlabel("Recency")
axes[0].set_ylabel("Customers")


axes[1].hist(
    df["frequency"].dropna(),
    bins=30,
    color="darkorange",
    edgecolor="white"
)

axes[1].set_title("Frequency Distribution")
axes[1].set_xlabel("Frequency")
axes[1].set_ylabel("Customers")


axes[2].hist(
    df["monetary"].dropna(),
    bins=30,
    color="seagreen",
    edgecolor="white"
)

axes[2].set_title("Monetary Distribution")
axes[2].set_xlabel("Monetary")
axes[2].set_ylabel("Customers")


plt.tight_layout()

SAS.pyplot(plt)

plt.close(fig)


#------------------------------------------------------------
# 15-9. Frequency와 Monetary 로그변환 비교
#
# 실제 데이터를 바꾸지 않고 그래프에서만 변환합니다.
#------------------------------------------------------------

frequency_log = np.log1p(
    df["frequency"].clip(lower=0)
)

monetary_log = np.log1p(
    df["monetary"].clip(lower=0)
)


fig, axes = plt.subplots(
    1,
    2,
    figsize=(11, 4)
)


axes[0].hist(
    frequency_log.dropna(),
    bins=30,
    color="darkorange",
    edgecolor="white"
)

axes[0].set_title("Log Frequency Distribution")
axes[0].set_xlabel("log(1 + Frequency)")
axes[0].set_ylabel("Customers")


axes[1].hist(
    monetary_log.dropna(),
    bins=30,
    color="seagreen",
    edgecolor="white"
)

axes[1].set_title("Log Monetary Distribution")
axes[1].set_xlabel("log(1 + Monetary)")
axes[1].set_ylabel("Customers")


plt.tight_layout()

SAS.pyplot(plt)

plt.close(fig)


#------------------------------------------------------------
# 15-10. 주요 변수 상관관계
#------------------------------------------------------------

corr_cols = [
    "recency",
    "frequency",
    "monetary",
    "tenure",
    "coupon_usage_rate",
    "unique_product_count"
]

corr = (
    df[corr_cols]
    .corr()
    .round(2)
)


print("\n주요 변수 상관계수:")

print(corr.to_string())


fig, ax = plt.subplots(
    figsize=(8, 6)
)


image = ax.imshow(
    corr,
    cmap="coolwarm",
    vmin=-1,
    vmax=1
)


ax.set_xticks(
    range(len(corr.columns))
)

ax.set_xticklabels(
    corr.columns,
    rotation=45,
    ha="right"
)

ax.set_yticks(
    range(len(corr.index))
)

ax.set_yticklabels(
    corr.index
)


for row in range(len(corr.index)):

    for col in range(len(corr.columns)):

        ax.text(
            col,
            row,
            f"{corr.iloc[row, col]:.2f}",
            ha="center",
            va="center",
            color="black"
        )


ax.set_title("Customer Feature Correlation")

fig.colorbar(
    image,
    ax=ax
)

plt.tight_layout()

SAS.pyplot(plt)

plt.close(fig)


print("\nWeek 2-3 Python EDA가 완료되었습니다.")

endsubmit;
quit;