proc python;
submit;
import subprocess
import sys
import site

# pandas도 --user로 최신 설치 -> conda의 구버전 pandas보다 우선순위 높아져서
# numpy 2.x와도 충돌 없이 최신 조합으로 쓸 수 있음
print("===== pandas, numpy 최신으로 설치 =====")
result = subprocess.run(
    [sys.executable, "-m", "pip", "install", "--user", "--upgrade",
     "pandas", "numpy"],
    capture_output=True, text=True
)
print(result.stdout[-800:])
if result.returncode != 0:
    print("!!! 설치 실패 !!!")
    print(result.stderr[-1000:])
else:
    print("설치 완료")

# 이 세션에서 이미 캐시된 구버전 모듈 전부 제거
for name in list(sys.modules.keys()):
    if name == "numpy" or name.startswith("numpy.") \
       or name == "scipy" or name.startswith("scipy.") \
       or name == "pandas" or name.startswith("pandas."):
        del sys.modules[name]

# user site-packages 경로를 맨 앞에 확실히 배치
user_site = site.getusersitepackages()
if user_site in sys.path:
    sys.path.remove(user_site)
sys.path.insert(0, user_site)

# 재확인 - 버전과 실제 로드 경로까지 확인
print("\n===== 설치 확인 =====")
import numpy
print("numpy 버전:", numpy.__version__, "| 경로:", numpy.__file__)

import pandas
print("pandas 버전:", pandas.__version__, "| 경로:", pandas.__file__)

for pkg in ["optuna", "shap"]:
    try:
        __import__(pkg)
        print(f"{pkg}: OK")
    except Exception as e:
        print(f"{pkg}: 여전히 실패 - {type(e).__name__}: {e}")
endsubmit;
run;
