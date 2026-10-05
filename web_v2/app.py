"""CP (CRM Pioneer) 이커머스 고객 진단 대시보드 2기 - Flask, 로컬호스트 전용

1기(web/)와 같은 데이터로 AARRR 진단 · 여정 퍼널 · 캠페인 플레이북 · 실험 설계를 보여 주는 버전.
실행:  python crm_pj/web_v2/app.py   ->  http://127.0.0.1:5001 (1기는 5000 그대로, 두 창을 나란히 비교)
선행:  weekend/r1-1.py ~ r6-1.py 를 한 번 실행해 crm_db 가 있어야 한다.
"""

import io

from flask import Flask, Response, jsonify, redirect, render_template, request, url_for

from data_prep import DEFAULT_MARGIN, OBS_H, RISKS, TIERS, TRIGGERS, build

app = Flask(__name__)
app.config["TEMPLATES_AUTO_RELOAD"] = True   # 템플릿 수정이 재시작 없이 반영

TIER_LABEL = {"VIP": "VIP", "Diamond": "Diamond", "Platinum": "Platinum", "Gold": "Gold", "Silver": "Silver", "Bronze": "Bronze"}


@app.template_filter("money")
def money(v, digits=0):
    return f"${v:,.{digits}f}"


@app.template_filter("pct")
def pct(v, digits=0):
    return f"{v * 100:.{digits}f}%"


@app.template_filter("num")
def num(v):
    return f"{v:,.0f}"


def qlink(endpoint="actions", **changes):
    """현재 필터(request.args)를 유지하면서 일부만 바꾼 링크"""
    params = {k: v for k, v in request.args.items() if v}
    for k, v in changes.items():
        if v:
            params[k] = v
        else:
            params.pop(k, None)
    return url_for(endpoint, **params)


@app.context_processor
def inject():
    return {"S": build()["summary"], "qlink": qlink}


@app.route("/")
def splash():
    return render_template("splash.html")


@app.route("/overview")
def overview():
    b = build()
    return render_template("overview.html", active="overview", matrix=b["matrix"], risks=RISKS, rules=b["rules"],
                           J=b["journey"], V=b["vanity"])


@app.route("/journey")
def journey():
    b = build()
    return render_template("journey.html", active="journey", J=b["journey"], triggers=TRIGGERS, obs_h=OBS_H)



def _find(q):
    df = build()["df"]
    q = (q or "").strip()
    if not q:
        return None
    hit = df[(df["customer_id"].str.upper() == q.upper()) | (df["name"] == q)]
    if hit.empty:
        hit = df[df["name"].str.contains(q, regex=False) | df["customer_id"].str.contains(q.upper(), regex=False)]
    return hit.iloc[0] if len(hit) else None


@app.route("/api/names")
def api_names():
    """검색 자동완성 목록 (가명·ID·등급) - 화면 표시용 가명만, 분석 데이터는 포함하지 않음"""
    df = build()["df"].sort_values("value_risk_priority_rank")
    return jsonify([{"n": n, "id": i, "t": t} for n, i, t in zip(df["name"], df["customer_id"], df["rfmp_tier"])])


@app.route("/customer")
def customer():
    b = build()
    df = b["df"]
    q = request.args.get("q")
    row = _find(q) if q else df.sort_values("value_risk_priority_rank").iloc[0]
    if row is None:
        return render_template("customer.html", active="customer", c=None, q=q)
    return render_template("customer.html", active="customer", c=row, q=q,
                           margin=DEFAULT_MARGIN)


# 캠페인 필터 (실행 플랜과 같은 이름). 연말 재주문·주기 경보는 다른 캠페인과 겹쳐서 받는 고객
CAMPAIGNS = [("onboard", "신규 온보딩"), ("winback", "고가치 고객 윈백"), ("auto", "자동 재방문 알림"), ("keep", "관계 유지"),
             ("season", "연말 재주문"), ("alert", "주기 경보 확인")]


def _queue(camp=None, tier=None, risk=None):
    df = build()["df"]
    if camp == "season":
        df = df[df["bulk"] == 1].assign(campaign="연말 재주문", next_send="10월 마지막 주 · 담당자 이름의 이메일")
    elif camp == "alert":
        df = df[df["signal_conflict"] == 1].assign(campaign="주기 경보 확인", next_send="지금 · 담당자 확인")
    elif camp:
        df = df[df["campaign"] == dict(CAMPAIGNS)[camp]]
    if tier:
        df = df[df["rfmp_tier"] == tier]
    if risk:
        df = df[df["relative_risk_grade"] == risk]
    return df.sort_values(["value_risk_priority_rank"])


@app.route("/actions")
def actions():
    a = request.args
    rows = _queue(a.get("c"), a.get("tier"), a.get("risk"))
    return render_template("actions.html", active="actions", rows=rows.head(300), total=len(rows), args=a,
                           tiers=TIERS, risks=RISKS, campaigns=CAMPAIGNS)


@app.route("/export.csv")
def export():
    a = request.args
    rows = _queue(a.get("c"), a.get("tier"), a.get("risk"))
    rows = rows.assign(list_rank=range(1, len(rows) + 1))
    cols = {"list_rank": "순위", "name": "가명", "customer_id": "고객ID", "rfmp_tier": "RFMP 등급", "relative_risk_grade": "이탈 위험",
            "value_risk_priority_rank": "전체 가치위험 순위", "campaign": "캠페인", "next_send": "다음 발송",
            "top_category": "대표 카테고리", "bulk": "대량 주문", "revenue_ex_gst": "2019년 매출 GST 제외"}
    buf = io.StringIO()
    rows[list(cols)].rename(columns=cols).round(2).to_csv(buf, index=False)
    name = f"cp_action_{a.get('c') or 'all'}.csv"
    return Response("\ufeff" + buf.getvalue(), mimetype="text/csv",
                    headers={"Content-Disposition": f"attachment; filename={name}"})


@app.route("/simulator")
def simulator():
    """실행 플랜: 매장 성격 → 캠페인 플레이북 → 실험 설계 → LTV/CAC (1기의 ROI 시뮬레이터는 가정값 의존이 커서 제외)"""
    b = build()
    return render_template("simulator.html", active="simulator", exps=b["experiments"], store=b["store"],
                           rules=b["rules"], margin=DEFAULT_MARGIN, triggers=TRIGGERS)


@app.route("/report")
@app.route("/story")
def report():
    """예전 주소(진단 리포트·발표 스토리)는 Executive 요약으로 이동"""
    return redirect(url_for("overview"))


@app.route("/home")
def home():
    return redirect(url_for("overview"))


def _free_port(start=5001, tries=20):
    """start 부터 비어 있는 포트를 찾는다 (이미 켜진 서버와 충돌 방지)"""
    import socket
    for port in range(start, start + tries):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            if s.connect_ex(("127.0.0.1", port)) != 0:
                return port
    raise SystemExit(f"{start}~{start + tries - 1} 포트가 모두 사용 중입니다.")


def _lan_ip():
    """현재 네트워크에서 이 PC의 IP (장소가 바뀌면 자동으로 바뀐 IP를 찾는다)"""
    import socket
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except OSError:
        return None


def _open_browser(url):
    import os
    import webbrowser
    chrome = [r"C:\Program Files\Google\Chrome\Application\chrome.exe",
              r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
              os.path.expandvars(r"%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe")]
    for path in chrome:
        if os.path.exists(path):
            webbrowser.register("cp_chrome", None, webbrowser.BackgroundBrowser(path))
            webbrowser.get("cp_chrome").open(url)
            return
    webbrowser.open(url)


if __name__ == "__main__":
    import os
    import threading

    # use_reloader: app.py·data_prep.py 를 고치면 서버가 스스로 다시 켜진다 (예전 코드로 도는 서버 때문에 생기는 500 오류 방지)
    # 재시작된 자식 프로세스(WERKZEUG_RUN_MAIN)는 같은 포트를 쓰고, 안내 문구·브라우저 열기는 처음 한 번만 한다
    child = os.environ.get("WERKZEUG_RUN_MAIN") == "true"
    port = int(os.environ.get("CP2_PORT") or _free_port())
    os.environ["CP2_PORT"] = str(port)
    if child:
        try:
            build()      # 미리 계산 (파이프라인 실행 중이라 아직 못 읽으면 첫 요청 때 다시 시도)
        except Exception as e:
            print(f" 데이터 준비 대기 중: {e}")
    else:
        local, lan = f"http://127.0.0.1:{port}", _lan_ip()
        print("=" * 60)
        print(f" CP 대시보드 2기  ->  {local}   (1기: python crm_pj/web/app.py)")
        if lan:
            print(f" 같은 와이파이의 다른 기기  ->  http://{lan}:{port}")
        print(" 코드를 고치면 자동으로 다시 시작됩니다 · 종료: 이 창에서 Ctrl+C")
        print("=" * 60)
        threading.Timer(3.0, _open_browser, args=(local,)).start()
    # 0.0.0.0: 127.0.0.1 과 현재 IP 모두에서 접속 가능 (장소·IP가 바뀌어도 수정 불필요)
    app.run(host="0.0.0.0", port=port, debug=False, use_reloader=True,
            extra_files=[os.path.join(os.path.dirname(os.path.abspath(__file__)), "data_prep.py")])
