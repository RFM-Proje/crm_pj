/*==========================================================================
  run_all.sas
  r1-1 → r2-2 → r3-1 → r4-1 을 순서대로 한 번에 실행하고
  파일별 결과를 PDF 4개로 저장합니다.

  [사용법]
    1. 아래 CODE_DIR 에 4개 .sas 파일이 들어 있는 폴더 경로를 적습니다.
    2. 이 파일 전체를 실행(F3)합니다.

  [코드를 수정했을 때]
    - r1-1 ~ r4-1 안의 코드를 고쳐도 이 파일은 다시 만들 필요가 없습니다.
      %include 가 실행할 때마다 그 시점의 파일 내용을 읽기 때문입니다.
    - 파일 이름이나 폴더 위치가 바뀔 때만 이 파일의 경로를 고치면 됩니다.

  [PDF]
    /home/student/abcdefg/r1-1_result.pdf
    /home/student/abcdefg/r2-2_result.pdf
    /home/student/abcdefg/r3-1_result.pdf
    /home/student/abcdefg/r4-1_result.pdf
    - 표, PROC SGPLOT 그래프, PROC PYTHON 의 SAS.pyplot 그래프가 들어갑니다.
    - PROC PYTHON 의 print() 결과와 %put 메시지는 PDF가 아니라 LOG에 남습니다.
    - 같은 이름의 PDF가 있으면 새 결과로 덮어씁니다.
==========================================================================*/


/*--------------------------------------------------------------------------
  0. 경로 설정 (여기만 수정)
--------------------------------------------------------------------------*/

/* 4개 .sas 파일이 저장된 폴더 : */
%let CODE_DIR=/home/student/abcdefg/work;

/* PDF 저장 폴더 (상위 폴더 + 폴더 이름) */
%let PDF_PARENT=/home/student;
%let PDF_NAME=abcdefg;
%let PDF_DIR=&PDF_PARENT./&PDF_NAME.;


/*--------------------------------------------------------------------------
  1. 이전 실행에서 열린 채 남은 PDF 닫기

  중간 파일에서 %abort cancel 로 실행이 멈추면 PDF가 열린 채로
  남을 수 있으므로 시작할 때 먼저 닫습니다.
--------------------------------------------------------------------------*/

ods pdf close;


/*--------------------------------------------------------------------------
  2. PDF 폴더가 없으면 만들기
--------------------------------------------------------------------------*/

/* 이미 있으면 아무것도 하지 않습니다. */
%let DCREATE_RC=%sysfunc(dcreate(&PDF_NAME., &PDF_PARENT.));

%put NOTE: PDF 저장 폴더 = &PDF_DIR.;


/*--------------------------------------------------------------------------
  3. 4개 코드 파일이 모두 있는지 먼저 확인
--------------------------------------------------------------------------*/

%macro check_code_files;

    %local file_list i one_file missing_count;
    %let file_list=r1-1 r2-2 r3-1 r4-1;
    %let missing_count=0;

    %do i=1 %to 4;
        %let one_file=%scan(&file_list., &i., %str( ));

        %if %sysfunc(fileexist(&CODE_DIR./&one_file..sas))=0 %then %do;
            %put ERROR: &CODE_DIR./&one_file..sas 파일이 없습니다.;
            %let missing_count=%eval(&missing_count. + 1);
        %end;
        %else %do;
            %put NOTE: &one_file..sas 파일을 확인했습니다.;
        %end;
    %end;

    %if &missing_count. > 0 %then %do;
        %put ERROR: CODE_DIR 경로 또는 파일 이름을 확인하십시오.;
        %abort cancel;
    %end;

%mend;

%check_code_files;


/*--------------------------------------------------------------------------
  4. PDF 공통 옵션

  가로 방향이 넓은 PROC PRINT 표를 담기에 유리합니다.
  각 파일이 자체 title 문을 쓰므로, 파일 구분 문구는 ods text 로
  PDF 첫머리에만 넣습니다.
--------------------------------------------------------------------------*/

options orientation=landscape nodate nonumber;
ods graphics on;


/*==========================================================================
  5. r1-1 실행 → r1-1_result.pdf
==========================================================================*/

ods pdf
    file="&PDF_DIR./r1-1_result.pdf"
    style=journal
    bookmarkgen=yes;

ods text="r1-1 : Week 1 CSV 적재 · 표준화 · 정합성 · 정제";

%include "&CODE_DIR./r1-1.sas";

ods pdf close;

%put NOTE: r1-1 실행 및 PDF 저장 완료;


/*==========================================================================
  6. r2-2 실행 → r2-2_result.pdf
==========================================================================*/

ods pdf
    file="&PDF_DIR./r2-2_result.pdf"
    style=journal
    bookmarkgen=yes;

ods text="r2-2 : Week 2 주문 단위 · RFM · 고객 피처 · EDA";

%include "&CODE_DIR./r2-2.sas";

ods pdf close;

%put NOTE: r2-2 실행 및 PDF 저장 완료;


/*==========================================================================
  7. r3-1 실행 → r3-1_result.pdf
==========================================================================*/

ods pdf
    file="&PDF_DIR./r3-1_result.pdf"
    style=journal
    bookmarkgen=yes;

ods text="r3-1 : Week 3 군집 · 이탈모형 · Frequency 실험 · RFMP";

%include "&CODE_DIR./r3-1.sas";

ods pdf close;

%put NOTE: r3-1 실행 및 PDF 저장 완료;


/*==========================================================================
  8. r4-1 실행 → r4-1_result.pdf
==========================================================================*/

ods pdf
    file="&PDF_DIR./r4-1_result.pdf"
    style=journal
    bookmarkgen=yes;

ods text="r4-1 : Week 4 상대위험 · 실행규칙 · 안정성 · 운영 대기열";

%include "&CODE_DIR./r4-1.sas";

ods pdf close;

%put NOTE: r4-1 실행 및 PDF 저장 완료;


/*==========================================================================
  9. 완료 메시지
==========================================================================*/

options orientation=portrait;

%put NOTE: ======================================================;
%put NOTE: 4개 파일 실행과 PDF 4개 저장이 끝났습니다.;
%put NOTE: 저장 위치 = &PDF_DIR.;
%put NOTE: ======================================================;
