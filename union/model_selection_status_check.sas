/* =============================================================
   백그라운드로 던진 model_selection.py의 진행상황/완료여부 확인
   - 분석을 다시 실행하는 게 아니라, 이미 돌고 있는(또는 끝난)
     로그 파일과 완료 플래그 파일만 읽는 코드
   - 몇 분 간격으로 이 파일만 다시 실행해서 확인하면 됨
============================================================= */
proc python;
submit;
import os

log_path = "/home/student/open/model_selection_progress.log"
done_flag = "/home/student/open/model_selection_DONE.flag"
png_path = "/home/student/open/plots/model_selection.png"

if os.path.exists(done_flag):
    print("===== 완료됨! =====")
else:
    print("===== 아직 진행 중 (완료 플래그 없음) =====")

if os.path.exists(png_path):
    mtime = os.path.getmtime(png_path)
    import datetime
    print(f"PNG 파일 존재함 - 생성시각: {datetime.datetime.fromtimestamp(mtime)}")
else:
    print("PNG 파일 아직 없음")

print("\n===== 현재까지의 로그 =====")
if os.path.exists(log_path):
    with open(log_path) as f:
        print(f.read())
else:
    print("로그 파일이 아직 없습니다 (실행이 시작 안 됐거나 경로 문제).")
endsubmit;
run;
