LIBNAME shop '/home/student/shop_db';

/* =========================================
   실습 6 - 주문금액 효과크기 / APA 보고
   그래프 생성 차단 버전
   ========================================= */

%LET TODAY = %SYSFUNC(TODAY(), YYMMDDN8.);


/* ★ 중요: 대용량 TTEST 그래프 생성 금지 */
ODS GRAPHICS OFF;


/* PDF 출력 시작 */
ODS PDF FILE="/home/student/apa_&TODAY..pdf"
    STYLE=JOURNAL;

TITLE "평균 주문금액 검정 - APA";


/* ① 기술통계 */
PROC MEANS DATA=shop.orders
    N MEAN STD MAXDEC=2;

    VAR total_amount;
    WHERE status='paid';

RUN;


/* ② 1-Sample t-test */
PROC TTEST DATA=shop.orders H0=50000;

    VAR total_amount;
    WHERE status='paid';

RUN;


/* ③ Cohen's d */
PROC SQL;

    SELECT
        (MEAN(total_amount) - 50000)
        / STD(total_amount)
        AS d FORMAT=8.3

    FROM shop.orders

    WHERE status='paid';

QUIT;


/* 제목 해제 */
TITLE;


/* PDF 기록 종료 */
ODS PDF CLOSE;


/* 이후 다른 실습에서 그래프가 필요할 수 있으므로 다시 켬 */
ODS GRAPHICS ON;