/*=============================================================
  churn_improvement_status_check.sas
  churn_improvement_launch.sas 를 실행한 뒤, 몇 분 간격으로
  이 파일만 따로 실행해서 진행상황/완료 여부를 확인하세요.
  (분석을 다시 돌리는 게 아니라 로그 파일만 읽습니다.)
============================================================= */

libname proj "/home/student/open";

proc python;
submit;
import os

log_path = "/home/student/open/churn_improvement_progress.log"
done_flag = "/home/student/open/churn_improvement_DONE.flag"

if os.path.exists(done_flag):
    print("===== 완료됨 (DONE.flag 존재) =====")
else:
    print("===== 아직 실행 중이거나, 아직 시작 안 됐거나, 중간에 죽었을 수 있음 =====")

if os.path.exists(log_path):
    print("\n----- 로그 파일 마지막 60줄 -----")
    with open(log_path) as f:
        lines = f.readlines()
    print("".join(lines[-60:]))
else:
    print("로그 파일이 아직 없습니다 - launch.sas의 PART 2가 실행됐는지 확인하세요.")
endsubmit;
run;

/* 완료됐다면 결과표를 SAS 데이터셋으로 불러와서 바로 확인 */
%macro show_results_if_done;
    %if %sysfunc(fileexist(/home/student/open/churn_improvement_DONE.flag)) %then %do;
        proc import datafile="/home/student/open/churn_improvement_results.csv"
            out=work.churn_improvement_results
            dbms=csv replace;
            guessingrows=20;
        run;

        proc print data=work.churn_improvement_results noobs;
            title "이탈예측 개선 실험 - 윈도우 x 피처셋 조합별 5-fold CV AUC";
        run;
        title;
    %end;
    %else %do;
        %put NOTE: 아직 완료되지 않아 결과표를 불러오지 않았습니다. 잠시 후 다시 실행하세요.;
    %end;
%mend show_results_if_done;

%show_results_if_done;
