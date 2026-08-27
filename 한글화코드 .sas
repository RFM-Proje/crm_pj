/*=============================================================
  koreanize-matplotlib 설치 (PROC PYTHON 안에서 pip install 실행)

  sys.executable을 써서 현재 SAS PROC PYTHON이 쓰는 Python 인터프리터에
  정확히 설치되도록 함 (그냥 'pip'만 쓰면 다른 파이썬 환경에 깔릴 수 있음)
=============================================================*/

proc python;
submit;
import sys
import subprocess

result = subprocess.run(
    [sys.executable, "-m", "pip", "install", "koreanize-matplotlib"],
    capture_output=True, text=True
)

print(result.stdout)
if result.returncode != 0:
    print("설치 실패, 에러 내용:")
    print(result.stderr)
else:
    print("설치 성공")
endsubmit;
quit;
