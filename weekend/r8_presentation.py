"""r8. 발표 자료 - 한 장에 메시지 하나 (16:9 슬라이드)

웹 대시보드(운영 도구: 고객 명단·필터·시뮬레이션)와 달리, 발표 자료는 이야기 흐름만 보여 준다.
  장마다 [섹션 표시] + [핵심 문장 한 줄] + [그래프 또는 큰 숫자 1~2개] + [출처]

발표 흐름 (본편 18장 + 부록 8장)
  표지 · 목차 · 팀 소개 · 01 주제 선정(이유, 질문) · 02 초기 목표 · 03 문제제기(줄어드는 이유, 구매일 수별 이탈과 지켜야 할 고객)
  04 해결과정(세는 단위, 가치×위험, 모델 선택, 로그 변환) · 05 목표 변경 · 06 선택과 집중(Nest-USA)
  07 결론 · 08 제안·제언 · 클로징 · 부록(90일 기준 반박과 답 2장, 데이터, 개인 예측, 시도 1·2, 모델표, 마진)

선행: r1-1 ~ r6-1, r7_models.py (숫자는 모두 crm_db 에서 다시 계산)
출력: crm_pj/발표자료/  슬라이드 PNG + CP_발표자료.pdf
추가 장: python r8_presentation.py alert  ->  crm_pj/발표자료_주기경보/ 에 그 장만 저장
2기 덱: python r8_presentation.py v2  ->  crm_pj/발표자료_2기/ (웹 2기 기준: 6·10·16·26장 교체, 고가치 위험 고객 = VIP~Gold × 위험 High)
2기 추가 장: python r8_presentation.py v2_aarrr v2_vanity v2_journey v2_playbook  ->  crm_pj/발표자료_주기경보/
Git Flow 장: python r8_presentation.py gitflow  ->  crm_pj/발표자료/03b_gitflow_collaboration.png
실행: python r8_presentation.py
"""

import sys
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from matplotlib.backends.backend_pdf import PdfPages
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch
from scipy import stats

from rcommon import WEEKEND_DIR, load

OUT = WEEKEND_DIR.parent / "발표자료"
OUT.mkdir(exist_ok=True)
EXTRA_OUT = WEEKEND_DIR.parent / "발표자료_주기경보"  # 덱과 별도로 만든 장

# ---------------------------------------------------------------- 디자인 (웹 대시보드와 같은 파스텔 팔레트)
ACC, MINT, GUARD, LEMON, LILAC = "#5B7CFA", "#2DBE9F", "#E8704A", "#E9A825", "#8467EE"
INK, INK2, MUTED, GRAY, LINE, BAD = "#1F2533", "#5B6475", "#9AA1AF", "#CDD3DE", "#E6E9F2", "#E2566B"
SOFT = {ACC: "#EEF2FF", MINT: "#E4F8F3", GUARD: "#FFF1EB", LEMON: "#FFF7E2", LILAC: "#F4F0FF", GRAY: "#F3F5F9"}
plt.rcParams.update({"font.family": "Malgun Gothic", "axes.unicode_minus": False, "font.size": 13,
                     "axes.edgecolor": LINE, "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2,
                     "axes.spines.top": False, "axes.spines.right": False, "axes.spines.left": False,
                     "legend.frameon": False})
W, H = 13.333, 7.5
STATE = {"no": 0, "pdf": None}


def esc(t):
    return str(t).replace("$", r"\$")


def slide(sec, title, sub=None):
    """새 슬라이드: 왼쪽 위 섹션 표시, 핵심 문장(제목), 보조 문장"""
    sec = STATE.get("sec") or sec
    fig = plt.figure(figsize=(W, H), facecolor="white")
    fig.text(0.05, 0.915, sec, fontsize=13, color=ACC, fontweight="bold", va="center")
    size = 24 if str(sec).startswith("04") else 27            # 해결과정 장(7~12장)은 제목 크기를 하나로 맞춤
    fit_text(fig, fig.text(0.05, 0.85, esc(title), fontsize=size, color=INK, fontweight="bold", va="center"))
    if sub:
        fit_text(fig, fig.text(0.05, 0.785, esc(sub), fontsize=15, color=INK2, va="center"))
    return fig


def fit_text(fig, t, max_w=0.9):
    """글자가 슬라이드 폭(90%)을 넘으면 글자 크기를 줄인다"""
    r = fig.canvas.get_renderer()
    while t.get_window_extent(renderer=r).width / fig.bbox.width > max_w and t.get_fontsize() > 10:
        t.set_fontsize(t.get_fontsize() - 0.5)


def finish(fig, name, source=""):
    STATE["no"] += 1
    if source:
        fig.text(0.05, 0.035, esc("자료: " + source), fontsize=9.5, color=MUTED, va="center")
    if STATE.get("extra"):
        out = STATE.get("extra_out", EXTRA_OUT)
        fname = f"{name}.png"
        fig.savefig(out / fname, dpi=150, facecolor="white")
        plt.close(fig)
        print("->", out.name + "/" + fname)
        return
    fig.text(0.95, 0.035, str(STATE["no"]), fontsize=11, color=MUTED, va="center", ha="right")
    fname = f"{STATE['no']:02d}_{name}.png"
    fig.savefig(OUT / fname, dpi=150, facecolor="white")
    STATE["pdf"].savefig(fig, facecolor="white")
    plt.close(fig)
    print("->", fname)


def ax_at(fig, rect, grid="y"):
    ax = fig.add_axes(rect)
    ax.tick_params(length=0, labelsize=12)
    if grid:
        ax.grid(axis=grid, color=LINE, lw=0.8)
        ax.set_axisbelow(True)
    return ax


def board(fig, rect=(0.05, 0.08, 0.9, 0.66)):
    ax = fig.add_axes(rect)
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.axis("off")
    return ax


def card(ax, x, y, w, h, color=GRAY, fill=None, lw=1.6):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=0.02", linewidth=lw,
                                edgecolor=color, facecolor=fill or "white", transform=ax.transAxes))


def big(ax, x, y, value, label, color=INK, size=46, label_size=14, ha="left"):
    ax.text(x, y, esc(value), fontsize=size, fontweight="bold", color=color, ha=ha, va="bottom", transform=ax.transAxes)
    ax.text(x, y - 0.035, esc(label), fontsize=label_size, color=INK2, ha=ha, va="top", transform=ax.transAxes)


def arrow(ax, p, q, color=MUTED, lw=2.2):
    ax.add_patch(FancyArrowPatch(p, q, arrowstyle="-|>", mutation_scale=22, lw=lw, color=color, transform=ax.transAxes))


def pct(v, d=0):
    return f"{v * 100:.{d}f}%"


# ---------------------------------------------------------------- 데이터
raw = {t: load(f"raw_{t}") for t in ("customer", "online", "discount", "marketing", "tax")}
co = load("clean_online")
pdays = load("w6_purchase_day")
cu = load("w6_customer")
rfm = load("w2_rfm").set_index("customer_id")
abc = load("w3_freq_abc_metrics")
k6 = load("w6_monthly_kpi")
roster = load("w4_44_final_roster").merge(cu[["customer_id", "revenue_ex_gst"]], on="customer_id")
m41 = load("w4_41_model_metrics").set_index("evaluation_scope")
vs = load("w4_41_valid_scored").sort_values("risk_priority_rank")
abc_diff = load("w3_freq_abc_auc_diff").set_index("candidate_model")
fit = load("w7_model_fit").merge(load("w7_model_auc_diff"), on=["model", "feature_set", "tuning"], how="left")
reg = load("w6_mkt_regression").set_index(["target", "spec", "term"])
daily = load("w6_daily").set_index("date")
cb = load("w6_conv_base")
cm = load("w6_conv_metrics")
seg = load("w6_conv_segments")
dec = load("w6_conv_decile")
up = load("w6_uplift")

END = pd.Timestamp("2019-12-31")
RECENCY = (END - pd.to_datetime(cu["last_day"])).dt.days
TIERS = ["VIP", "Diamond", "Platinum", "Gold", "Silver", "Bronze"]
RISKS = ["High", "Medium", "Low"]
GUARD_TIERS = ["Diamond", "Platinum", "Gold"]                    # 1기 기준 (2기는 use_v2 에서 VIP 포함)
GUARD_LABEL, REMIND = "지켜야 할 고객", "7·30·60일"
GUARD_MASK = roster["rfmp_tier"].isin(GUARD_TIERS) & (roster["relative_risk_grade"] == "High")
GUARD_N, GUARD_REV = int(GUARD_MASK.sum()), roster.loc[GUARD_MASK, "revenue_ex_gst"].sum()
GUARD_NEW = int((GUARD_MASK & (roster["customer_maturity_group"] == "NEW_LT90")).sum())
RULE_N = roster["action_rule_id"].value_counts()
SHARE = cu["revenue_ex_gst"].sort_values(ascending=False).reset_index(drop=True)
TOP20 = SHARE.head(int(len(SHARE) * 0.2)).sum() / SHARE.sum()
WK = daily.resample("W-SUN").sum()[daily.resample("W-SUN").size() == 7]
P0 = cb["converted_90d"].mean()
NEW_PER_MONTH = len(cu) / 12  # 2019년 월평균 첫 구매 고객 · 2020년에도 같다고 가정
NEW_H1, NEW_H2 = k6["new"].iloc[:6].mean(), k6["new"].iloc[6:].mean()
MROAS = reg.loc[("revenue", "요일·추세 통제", "spend_same_day"), "coef_per_1000"] / 1000
P_NEW = reg.loc[("new_customers", "요일·추세 통제", "spend_same_day"), "p_value"]
AUC_CONV = cm.query("model=='LOGISTIC' and dataset_role=='VALID'")["roc_auc"].iloc[0]
Z = stats.norm.ppf(0.975) + stats.norm.ppf(0.80)
ORDERS, DAYS = co["order_key"].nunique(), len(pdays)
BASE = fit[fit["baseline"] == 1].iloc[0]


def mde_prop(n_per_arm, p=P0):
    return Z * np.sqrt(2 * p * (1 - p) / n_per_arm)


def weeks_needed(swing):
    diff = 2 * swing * WK["spend"].mean() * MROAS
    return 4 * (Z * WK["revenue"].std() / diff) ** 2


# ---------------------------------------------------------------- 2기: 웹 2기(web_v2/data_prep.py)와 같은 숫자
V2 = {}


def v2():
    """웹 2기 build() 결과 (AARRR · 여정 · 실험 설계 · 매장 성격). 처음 부를 때 한 번만 계산"""
    if not V2:
        sys.path.insert(0, str(WEEKEND_DIR.parent / "web_v2"))
        import data_prep as dp2
        V2.update(dp2.build())
    return V2


def use_v2():
    """2기 기준: 고가치 위험 고객 = VIP~Gold × 위험 High (규칙 2·3 대상과 같은 기준), 리마인드 D+7·D+30"""
    global GUARD_TIERS, GUARD_LABEL, REMIND, GUARD_MASK, GUARD_N, GUARD_REV, GUARD_NEW, GUARD_IDS, OUT
    GUARD_TIERS, GUARD_LABEL, REMIND = ["VIP", "Diamond", "Platinum", "Gold"], "고가치 위험 고객", "D+7·D+30"
    GUARD_MASK = roster["rfmp_tier"].isin(GUARD_TIERS) & (roster["relative_risk_grade"] == "High")
    GUARD_N, GUARD_REV = int(GUARD_MASK.sum()), roster.loc[GUARD_MASK, "revenue_ex_gst"].sum()
    GUARD_NEW = int((GUARD_MASK & (roster["customer_maturity_group"] == "NEW_LT90")).sum())
    GUARD_IDS = set(roster.loc[GUARD_MASK, "customer_id"])
    OUT = WEEKEND_DIR.parent / "발표자료_2기"
    OUT.mkdir(exist_ok=True)


# ====================================================================== 01 핵심 주제
def s_title():
    fig = plt.figure(figsize=(W, H), facecolor="white")
    ax = board(fig, (0, 0, 1, 1))
    ax.add_patch(FancyBboxPatch((0, 0), 1, 1, boxstyle="square,pad=0", facecolor="#F6F8FF", edgecolor="none",
                                transform=ax.transAxes, zorder=-2))
    for (x, y, r, c) in [(0.82, 0.78, 0.22, "#DCE4FF"), (0.9, 0.25, 0.16, "#DDF5EE"), (0.68, 0.12, 0.1, "#FFE6DC")]:
        ax.add_patch(plt.Circle((x, y), r, color=c, transform=ax.transAxes, zorder=-1))
    ax.text(0.07, 0.72, "Team CRM Pioneer", fontsize=17, color=ACC, fontweight="bold", transform=ax.transAxes)
    ax.text(0.07, 0.6, "한정된 마케팅 예산으로,", fontsize=40, color=INK, fontweight="bold", transform=ax.transAxes)
    ax.text(0.07, 0.49, "누구를 어떻게 지킬 것인가", fontsize=40, color=INK, fontweight="bold", transform=ax.transAxes)
    ax.text(0.07, 0.37, f"2019년 온라인 판매 데이터 · 고객 {len(cu):,}명 · 상품 거래 {len(co):,}건", fontsize=16, color=INK2,
            transform=ax.transAxes)
    STATE["no"] += 1
    fname = f"{STATE['no']:02d}_title.png"
    fig.savefig(OUT / fname, dpi=150, facecolor="white")
    STATE["pdf"].savefig(fig, facecolor="white")
    plt.close(fig)
    print("->", fname)



# ====================================================================== 02 데이터
def s_tables():
    fig = slide("02  데이터", "데이터: 거래 테이블 하나에 기준 정보 네 개를 붙였습니다", "결측·중복 0건 · 정합성 17개 항목 점검")
    ax = board(fig)
    card(ax, 0.36, 0.3, 0.28, 0.4, color=ACC, fill=SOFT[ACC], lw=2.4)
    ax.text(0.5, 0.58, "거래 상세", fontsize=24, fontweight="bold", color=INK, ha="center", transform=ax.transAxes)
    ax.text(0.5, 0.47, f"{len(raw['online']):,}행", fontsize=20, color=ACC, fontweight="bold", ha="center", transform=ax.transAxes)
    ax.text(0.5, 0.37, "상품 한 줄 = 한 행", fontsize=13, color=INK2, ha="center", transform=ax.transAxes)
    sides = [((0.03, 0.62), "고객 정보", f"{len(raw['customer']):,}명 · 성별 · 지역 · 가입기간", "고객ID", (0.33, 0.68), (0.36, 0.62)),
             ((0.03, 0.12), "일별 마케팅비", f"{len(raw['marketing']):,}일 · 온라인 · 오프라인", "날짜", (0.33, 0.24), (0.36, 0.38)),
             ((0.67, 0.62), "월별 쿠폰", f"{len(raw['discount']):,}행 · 카테고리별 할인율", "카테고리 + 월", (0.67, 0.68), (0.64, 0.62)),
             ((0.67, 0.12), "세금", f"{len(raw['tax']):,}행 · 카테고리별 GST", "카테고리", (0.67, 0.24), (0.64, 0.38))]
    for (x, y), t, d, key, p, q in sides:
        card(ax, x, y, 0.3, 0.26, color=GRAY)
        ax.text(x + 0.02, y + 0.17, t, fontsize=18, fontweight="bold", color=INK, transform=ax.transAxes)
        ax.text(x + 0.02, y + 0.095, d, fontsize=12.5, color=INK2, transform=ax.transAxes)
        ax.text(x + 0.02, y + 0.03, "연결 키: " + key, fontsize=12, color=ACC, fontweight="bold", transform=ax.transAxes)
        ax.add_patch(FancyArrowPatch(p, q, arrowstyle="<|-|>", mutation_scale=16, lw=1.8, color=MUTED, transform=ax.transAxes))
    finish(fig, "data_tables", "Onlinesales · Customer · Marketing · Discount · Tax CSV (r1-1)")


# ====================================================================== 03 초기 목표

# ====================================================================== 04 문제제기 1
# ====================================================================== 05 해결과정 1
# ====================================================================== 06 모델 검증
# ====================================================================== 07 목표 변경
# ====================================================================== 08 문제제기 2
def s_cannot_pick():
    fig = slide("08  문제제기 2", "북극성을 종속변수로 놓고 예측해도 누가 다시 올지 골라낼 수 없었습니다",
                f"종속변수 converted_90d = 첫 구매 후 90일 안 두 번째 구매 · 첫 구매 정보로 예측 · 10등분별 실제 재구매율 · AUC {AUC_CONV:.2f}")
    ax = ax_at(fig, [0.09, 0.14, 0.84, 0.56])
    x = np.arange(1, 11)
    avg = cb.loc[cb["split"] == "VALID", "converted_90d"].mean()
    ax.bar(x, dec["actual"], color="#B9C3D6", width=0.62)
    for xi, v in zip(x, dec["actual"]):
        ax.text(xi, v + 0.01, f"{v:.0%}", ha="center", fontsize=12.5, color=INK2)
    ax.axhline(avg, color=MINT, ls="--", lw=2)
    ax.text(10.45, avg, f" 검증 고객\n 평균 {avg:.0%}", color=MINT, fontsize=12.5, ha="left", va="center")
    ax.set_xlim(0.4, 11.4)
    ax.text(0.6, dec["actual"].max() * 1.12, "예측이 맞다면 왼쪽(1)이 높고 오른쪽(10)이 낮아야 하지만, 들쭉날쭉합니다",
            fontsize=13.5, color=INK)
    ax.set_xticks(x)
    ax.set_xticklabels([f"{i}" for i in x])
    ax.set_xlabel("예측 순위 10등분 (1 = 다시 살 것 같다고 가장 높게 예측한 10%)")
    ax.yaxis.set_major_formatter(plt.FuncFormatter(lambda v, _: f"{v:.0%}"))
    ax.set_ylim(0, dec["actual"].max() * 1.22)
    finish(fig, "cannot_pick_individuals", "w6_conv_decile, w6_conv_metrics (r6-1)")


# ====================================================================== 09 해결과정 2


# ====================================================================== 10 발견 정리
# ====================================================================== 11 제안·제언
def s_next_data():
    fd = pd.to_datetime(cu["first_day"])
    cut = pd.to_datetime(cb["first_day"]).max()
    excl = int((fd > cut).sum())
    fig = slide("11  제언", "제언: 다음에 필요한 데이터", "관찰 1년 · 고객 정보 3개 · 원가 없음")
    ax = board(fig)
    needs = [("채널·캠페인별 비용", "마케팅이 신규를 데려오는지\n채널별로 나눠 확인", LEMON),
             ("원가 · 반품", "가정한 마진이 아닌\n실제 이익과 고객 가치", GUARD),
             ("방문 · 장바구니 기록", "구매 전 행동으로\n누가 다시 올지 재도전", MINT)]
    for i, (t, d, c) in enumerate(needs):
        x = 0.02 + i * 0.33
        card(ax, x, 0.12, 0.3, 0.72, color=c, fill=SOFT[c], lw=2)
        ax.text(x + 0.03, 0.7, f"{i + 1}", fontsize=30, fontweight="bold", color=c, transform=ax.transAxes)
        ax.text(x + 0.03, 0.55, t, fontsize=20, fontweight="bold", color=INK, transform=ax.transAxes)
        ax.text(x + 0.03, 0.43, d, fontsize=15, color=INK2, va="top", linespacing=1.6, transform=ax.transAxes)
    finish(fig, "next_data", "r1-1 원천 테이블 구조, w6_conv_base")


def _end_slide(text):
    fig = plt.figure(figsize=(W, H), facecolor="white")
    ax = board(fig, (0, 0, 1, 1))
    ax.add_patch(FancyBboxPatch((0, 0), 1, 1, boxstyle="square,pad=0", facecolor="#F6F8FF", edgecolor="none",
                                transform=ax.transAxes, zorder=-2))
    ax.text(0.5, 0.55, text, fontsize=54, fontweight="bold", color=INK, ha="center", va="center",
            transform=ax.transAxes)
    ax.text(0.5, 0.42, "Team CRM Pioneer", fontsize=20, fontweight="bold", color=ACC, ha="center", va="center",
            transform=ax.transAxes)
    return fig


def s_closing():
    finish(_end_slide("모두 고생하셨습니다"), "closing")


def s_thanks():
    finish(_end_slide("감사합니다"), "thanks")


# ====================================================================== 부록
def a_model_table():
    tuned = fit[(fit["tuning"] == "튜닝 후")]
    rows = [BASE] + [r for _, r in tuned.sort_values(["feature_set", "model"]).iterrows()]
    fig = slide("부록 A1", "모델 비교 상세: 지금 모델보다 확실히 나은 조합은 없었습니다", "검증 고객 1,211명 · 95% 구간이 0을 포함하면 차이 없음")
    ax = board(fig, (0.05, 0.08, 0.9, 0.66))
    head = ["모델", "변수", "튜닝", "학습 AUC", "검증 AUC", "지금 모델 대비 (95% 구간)"]
    xs = [0.0, 0.2, 0.32, 0.43, 0.54, 0.65]
    for k, h in enumerate(head):
        ax.text(xs[k], 0.95, h, fontsize=13, fontweight="bold", color=INK2, transform=ax.transAxes)
    for i, r in enumerate(rows):
        y = 0.86 - i * 0.092
        if r["baseline"] == 1:
            ax.add_patch(FancyBboxPatch((-0.01, y - 0.035), 1.0, 0.075, boxstyle="square,pad=0", facecolor=SOFT[ACC],
                                        edgecolor="none", transform=ax.transAxes))
        if r["baseline"] == 1:
            diff, col = "기준 (사용 모델)", ACC
        else:
            sig = "확실히 낮음" if r["ci_high"] < 0 else ("확실히 높음" if r["ci_low"] > 0 else "차이 없음")
            diff, col = f"{r['auc_diff']:+.3f} ({r['ci_low']:+.3f}~{r['ci_high']:+.3f}) {sig}", BAD if r["ci_high"] < 0 else INK
        vals = [r["model"], r["feature_set"], r["tuning"], f"{r['train_auc']:.3f}", f"{r['valid_auc']:.3f}", diff]
        for k, v in enumerate(vals):
            ax.text(xs[k], y, v, fontsize=13, color=col if k == 5 else INK, va="center", transform=ax.transAxes)
    finish(fig, "appx_model_table", "w7_model_fit, w7_model_auc_diff (r7_models.py)")


def a_margin():
    ups = sorted(up["uplift_pp"].unique())
    fig = slide("부록 A3", "마진 가정이 바뀌면? 금액만 달라지고 판단 방향은 같습니다", "원가 데이터가 없어 마진 20·30·40%로 계산")
    ax = ax_at(fig, [0.09, 0.14, 0.84, 0.56])
    for k, (m, c) in enumerate([(0.2, "#C9D3FD"), (0.3, "#8EA5FB"), (0.4, ACC)]):
        vals = [up.query("uplift_pp==@u and margin==@m")["extra_profit"].iloc[0] / 1000 for u in ups]
        xx = np.arange(len(ups)) + (k - 1) * 0.26
        ax.bar(xx, vals, width=0.24, color=c, label=f"마진 {m:.0%}")
        for xi, v in zip(xx, vals):
            ax.text(xi, v + 1.5, f"${v:,.0f}K", ha="center", fontsize=12, color=INK2)
    ax.set_xticks(range(len(ups)))
    ax.set_xticklabels([f"전환율 +{u * 100:.0f}%p" for u in ups], fontsize=14)
    ax.set_yticks([])
    ax.legend(loc="upper left", fontsize=13)
    finish(fig, "appx_margin", "w6_uplift (r6-1)")


def a_log_transform():
    """로그 변환 전후: 같은 학습 데이터로 두 모델을 다시 적합해 비교"""
    from sklearn.compose import ColumnTransformer
    from sklearn.impute import SimpleImputer
    from sklearn.linear_model import LogisticRegression
    from sklearn.metrics import roc_auc_score
    from sklearn.pipeline import Pipeline
    from sklearn.preprocessing import OneHotEncoder, StandardScaler

    from rcommon import LogSkewed
    num = ["recency", "monetary", "avg_order_value", "avg_shipping", "tenure", "product_category_count",
           "category_concentration", "avg_days_between_orders", "std_days_between_orders", "frequency_days"]
    cat = ["gender", "region"]
    d = load("w3_freq_abc_input").copy()
    cs = load("w4_41_current_scored").copy()
    for X in (d, cs):
        for c in cat:
            X[c] = X[c].fillna("UNKNOWN").astype(str)
    tr, va = d[d["split_role"].str.upper() == "TRAIN"], d[d["split_role"].str.upper() == "VALID"]
    res = {}
    for name, use_log in (("변환 전", False), ("변환 후 (사용)", True)):
        pre = ColumnTransformer([("n", Pipeline([("i", SimpleImputer(strategy="median")), ("s", StandardScaler())]), num),
                                 ("c", Pipeline([("i", SimpleImputer(strategy="most_frequent")),
                                                 ("o", OneHotEncoder(handle_unknown="ignore"))]), cat)])
        steps = ([("log", LogSkewed())] if use_log else []) + [("p", pre), ("m", LogisticRegression(
            C=1.0, solver="liblinear", max_iter=2000, random_state=2026))]
        m = Pipeline(steps).fit(tr[num + cat], tr["churn_flag"])
        rank = pd.Series(m.predict_proba(cs[num + cat])[:, 1], index=cs["customer_id"]).rank(ascending=False)
        res[name] = (roc_auc_score(va["churn_flag"], m.predict_proba(va[num + cat])[:, 1]), int(rank["USER_1218"]))
    LOGRES.update(res)
    ex = cs.set_index("customer_id").loc["USER_1218"]
    fig = slide("", "해결 ⑤ 금액 하나가 위험 순위를 흔들던 문제, 로그 변환으로 고쳤습니다", f"첫 구매 18일 된 고객이 2일 동안 ${ex['monetary']:,.0f} 구매 → 위험 상위로 잘못 분류")
    ax = board(fig)
    for i, (name, (auc, rk)) in enumerate(res.items()):
        x = 0.04 + i * 0.48
        c = GRAY if i == 0 else MINT
        card(ax, x, 0.15, 0.42, 0.7, color=c, fill="white" if i == 0 else SOFT[MINT], lw=2)
        ax.text(x + 0.04, 0.74, name, fontsize=20, fontweight="bold", color=INK, transform=ax.transAxes)
        big(ax, x + 0.04, 0.45, f"{rk}위", "이 고객의 위험 순위 (1,468명 중)", BAD if i == 0 else MINT, size=50)
    arrow(ax, (0.465, 0.5), (0.515, 0.5), color=MINT, lw=3)
    finish(fig, "solution5_log_transform", "rcommon.LOG_FEATURES (구매 금액·주문당 금액·배송료·구매 간격·간격 편차)")


# ====================================================================== v2 공통 데이터
BINS, BLAB = [0, 1, 2, 3, 5, 10, 1000], ["1일", "2일", "3일", "4~5일", "6~10일", "11일+"]
_va = load("w3_freq_abc_input")
_va = _va[_va["split_role"].str.upper() == "VALID"].copy()
_va["b"] = pd.cut(_va["frequency_days"], BINS, labels=BLAB)
DAY_CHURN = _va.groupby("b", observed=False)["churn_flag"].agg(["mean", "size"])      # 구매일 수별 실제 90일 이탈률
GUARD_IDS = set(roster.loc[GUARD_MASK, "customer_id"])
LOGRES = {}                                                                            # 로그 변환 전후 결과 (a_log_transform 이 채움)


def _rf_best():
    t = fit[(fit["tuning"] == "튜닝 후") & (fit["model"] == "랜덤 포레스트")]
    return t.loc[t["valid_auc"].idxmax()]


def _return_after_inactive(days, horizon=90, first_only=False):
    """d일 동안 안 온 구매(안 돌아온 고객 포함) 중 이후 horizon 일 안에 다시 산 비율 - 생존편향 없는 분모"""
    p = pdays.sort_values(["customer_id", "purchase_date"])[["customer_id", "purchase_date"]].copy()
    p["gap"] = (p.groupby("customer_id")["purchase_date"].shift(-1) - p["purchase_date"]).dt.days
    if first_only:
        p = p.groupby("customer_id").head(1)
    e = p[(p["purchase_date"] + pd.Timedelta(days=days + horizon)) <= END]
    reached = e[e["gap"].isna() | (e["gap"] > days)]
    return reached["gap"].between(days + 1, days + horizon).mean(), len(reached)


# ====================================================================== 01 주제 선정

# ====================================================================== 03 문제제기
def s_problem():
    r = np.corrcoef(WK["spend"], WK["new_customers"])[0, 1]
    fig = slide("", "고객이 줄어드는 세 가지 이유: 신규 감소 · 재방문 부족 · 마케팅 효과 불분명")
    heads = [("① 처음 구매하는 고객이 줄었다", "그 달 첫 구매 고객 수"),
             ("② 온 고객은 돌아오지 않았다", "연말 기준 마지막 구매 후 지난 날수"),
             ("③ 마케팅비로는 신규가 늘지 않았다", f"{len(WK)}주 · 상관계수 {r:+.2f} (관계 없음) · 마케팅은 365일 매일 집행")]
    for (h, s), x in zip(heads, (0.05, 0.37, 0.69)):
        fig.text(x, 0.7, h, fontsize=15, fontweight="bold", color=INK)
        fig.text(x, 0.665, esc(s), fontsize=10.5, color=INK2)
    a1 = ax_at(fig, [0.06, 0.13, 0.26, 0.48])
    x = np.arange(12)
    a1.bar(x, k6["new"], color="#BFCBFD", width=0.65)
    for lo, hi, v in ((-0.4, 5.4, NEW_H1), (5.6, 11.4, NEW_H2)):
        a1.plot([lo, hi], [v, v], color=ACC, lw=2.5)
        a1.text((lo + hi) / 2, v + 8, f"월평균 {v:.0f}명", ha="center", fontsize=12, fontweight="bold", color=ACC,
                bbox=dict(facecolor="white", edgecolor="none", pad=1.5))
    a1.set_xticks([0, 3, 6, 9, 11])
    a1.set_xticklabels(["1월", "4월", "7월", "10월", "12월"])
    a1.set_ylim(0, k6["new"].max() * 1.22)
    a2 = ax_at(fig, [0.38, 0.13, 0.26, 0.48], grid=None)
    vals = [(RECENCY <= 90).mean(), ((RECENCY > 90) & (RECENCY <= 180)).mean(), (RECENCY > 180).mean()]
    cols_ = [MINT, LEMON, GUARD]
    a2.bar(range(3), vals, color=cols_, width=0.6)
    for i, v in enumerate(vals):
        a2.text(i, v + 0.015, f"{v:.0%}", ha="center", fontsize=16, fontweight="bold", color=cols_[i])
    a2.set_xticks(range(3))
    a2.set_xticklabels(["90일 이내", "91~180일", "180일 넘음"])
    a2.set_yticks([])
    a2.set_ylim(0, max(vals) * 1.3)
    a2.spines["bottom"].set_visible(True)
    a3 = ax_at(fig, [0.72, 0.13, 0.24, 0.48], grid="both")
    xs_, ys_ = WK["spend"] / 1000, WK["new_customers"]
    a3.scatter(xs_, ys_, s=40, color=LEMON, edgecolor="white", lw=1, zorder=3)
    b = np.polyfit(xs_, ys_, 1)
    xx = np.linspace(xs_.min(), xs_.max(), 20)
    a3.plot(xx, np.polyval(b, xx), color=INK2, ls="--", lw=1.8)
    a3.set_xlabel("그 주 마케팅비 ($K)")
    a3.set_ylabel("그 주 첫 구매 고객 (명)")
    finish(fig, "problem_why_decline", "w6_monthly_kpi, w6_customer, w6_daily 주 단위 합계 (r6-1)")


def s_problem_v2():
    """2기 6장: 고객 수는 줄지 않았고, 매출의 44% 인 마케팅비는 더 쓴 만큼 돌아오지 않았다 (마진 가정 없이 성립)"""
    S2 = v2()["summary"]
    D = S2["spend_day"]                                                  # 평균 하루 마케팅비 (연간 ÷ 365)
    act_h1, act_h2 = k6["active"].iloc[:6].mean(), k6["active"].iloc[6:].mean()
    fig = slide("", "문제는 고객 수가 아니라 마케팅비의 효율입니다",
                f"매출의 {S2['mkt_ratio']:.0%}를 마케팅에 썼지만, 더 쓴 만큼 돌아오지 않았습니다")
    heads = [("① 구매 고객 수는 줄지 않았다", "그 달 구매한 고객 수"),
             ("② 더 쓴 만큼 매출이 돌아오지 않았다", esc(f"평균 하루 마케팅비 ${D:,.0f}만큼 더 쓴 날 · 요일·추세 통제")),
             ("③ 첫 구매 고객도 늘지 않았다", esc(f"같은 날 하루 마케팅비 ${D:,.0f}만큼 더 썼을 때"))]
    for (h, sb), x in zip(heads, (0.05, 0.37, 0.69)):
        fig.text(x, 0.7, h, fontsize=15, fontweight="bold", color=INK)
        fit_text(fig, fig.text(x, 0.665, sb, fontsize=10.5, color=INK2), max_w=0.3)
    # ① 그 달 구매 고객 수
    a1 = ax_at(fig, [0.06, 0.13, 0.26, 0.48])
    x = np.arange(12)
    a1.bar(x, k6["active"], color="#BFCBFD", width=0.65)
    for lo, hi, v, tx in ((-0.4, 5.4, act_h1, 2.5), (5.6, 11.4, act_h2, 9.9)):
        a1.plot([lo, hi], [v, v], color=INK2, lw=1.8, ls="--")
        a1.text(tx, v + 12, f"월평균 {v:.0f}명", ha="center", fontsize=12, fontweight="bold", color=INK,
                bbox=dict(facecolor="white", edgecolor="none", pad=1.5))
    a1.set_xticks([0, 3, 6, 9, 11])
    a1.set_xticklabels(["1월", "4월", "7월", "10월", "12월"])
    a1.set_ylim(0, k6["active"].max() * 1.3)
    # ② 더 쓴 금액 vs 늘어난 매출 (95% 구간): 구간 전체가 더 쓴 금액보다 작으면 마진과 관계없이 돌아오지 않은 것
    a2 = ax_at(fig, [0.42, 0.18, 0.22, 0.4], grid="x")
    eff, ci = S2["rev_per_day"], S2["rev_per_day_ci"]
    a2.barh([1], [D], color="#D5DAE3", height=0.5)
    a2.barh([0], [eff], color=ACC, height=0.5)
    a2.errorbar([eff], [0], xerr=[[ci], [ci]], fmt="none", ecolor=INK, elinewidth=2, capsize=6)
    a2.axvline(D, color=INK2, lw=1.4, ls="--")
    a2.text(D, 1, esc(f"  ${D:,.0f}"), va="center", fontsize=12, fontweight="bold", color=INK2)
    a2.text(eff + ci, 0, esc(f"  +${eff:,.0f}"), va="center", fontsize=12, fontweight="bold", color=ACC)
    a2.set_yticks([1, 0])
    a2.set_yticklabels(["더 쓴 마케팅비", "늘어난 매출"], fontsize=12)
    a2.set_xlim(0, D * 1.45)
    a2.xaxis.set_major_formatter(plt.FuncFormatter(lambda v, _: esc(f"${v / 1000:,.0f}K")))
    a2.text(0.5, -0.24, f"구간 끝까지도 더 쓴 금액보다 작음 · p={reg.loc[('revenue', '요일·추세 통제', 'spend_same_day'), 'p_value']:.3f}",
            transform=a2.transAxes, fontsize=10.5, color=INK2, ha="center")
    # ③ 첫 구매 고객 변화 (95% 구간): 세 방식 모두 0 을 포함
    rows = [("같은 날 · 단순", reg.loc[("new_customers", "단순", "spend_same_day")]),
            ("같은 날 · 요일·추세 통제", reg.loc[("new_customers", "요일·추세 통제", "spend_same_day")]),
            ("직전 7일 평균 · 통제", reg.loc[("new_customers", "요일·추세 + 직전 7일 평균", "spend_prev7_avg")])]
    a3 = ax_at(fig, [0.80, 0.18, 0.16, 0.43], grid="x")
    ys = np.arange(len(rows))[::-1]
    k = D / 1000                                                         # 1,000달러당 계수 → 평균 하루 마케팅비당
    for y, (lab, r_) in zip(ys, rows):
        b, se = r_["coef_per_1000"] * k, r_["se"] * k
        a3.plot([b - 1.96 * se, b + 1.96 * se], [y, y], color=LEMON, lw=3, solid_capstyle="round")
        a3.scatter([b], [y], s=70, color=LEMON, edgecolor="white", lw=1.5, zorder=3)
        a3.text(b + 1.96 * se + 0.1, y, f"p={r_['p_value']:.2f}", va="center", fontsize=11, color=INK2)
    a3.axvline(0, color=INK2, lw=1.4, ls="--")
    a3.set_yticks(ys)
    a3.set_yticklabels([r[0] for r in rows], fontsize=11)
    a3.set_ylim(-0.6, len(rows) - 0.4)
    a3.set_xlim(-2.5, 4.2)
    a3.set_xlabel("첫 구매 고객 변화 (명)")
    a3.text(0.0, -0.22, f"하루 평균 첫 구매 {reg.loc[('new_customers', '단순', 'spend_same_day'), 'target_mean']:.1f}명 · 세 결과 모두 0 을 포함",
            transform=a3.transAxes, fontsize=10.5, color=INK2, ha="center")
    finish(fig, "problem_why_decline", "w6_monthly_kpi, w6_daily · w6_mkt_regression 일 단위 회귀 (r6-1) · 오차막대 = 95% 신뢰구간")


def s_segments():
    rates = DAY_CHURN["mean"]
    cur = roster[["customer_id", "rfmp_tier", "revenue_ex_gst"]].merge(cu[["customer_id", "purchase_days"]], on="customer_id")
    cur["b"] = pd.cut(cur["purchase_days"], BINS, labels=BLAB)
    cur["rate"] = cur["b"].map(rates).astype(float)
    cur["risk_rev"] = cur["revenue_ex_gst"] * cur["rate"]
    fig = slide("", f"구매한 날이 적을수록 떠납니다: 1일 {rates.iloc[0]:.0%} → 11일+ {rates.iloc[-1]:.0%}", "왼쪽 = 구매한 날 수별 90일 실제 이탈률 · 오른쪽 = 지금 고객에 적용한 추정")
    ax = ax_at(fig, [0.07, 0.14, 0.4, 0.52])
    x = np.arange(len(BLAB))
    v = rates.to_numpy()
    ax.bar(x, v, color=ACC, width=0.62)
    for i, (vv, n) in enumerate(zip(v, DAY_CHURN["size"])):
        ax.text(i, vv + 0.02, f"{vv:.0%}", ha="center", fontsize=14, fontweight="bold", color=INK)
        ax.text(i, 0.03, f"{n}명", ha="center", fontsize=10, color="white")
    ax.set_xticks(x)
    ax.set_xticklabels(BLAB)
    ax.set_xlabel("10월 2일까지 구매한 날 수")
    ax.yaxis.set_major_formatter(plt.FuncFormatter(lambda val, _: f"{val:.0%}"))
    ax.set_ylim(0, 1.05)
    b = board(fig, (0.53, 0.1, 0.43, 0.6))
    head = ["고객 집단", "고객", "1~2일만 산\n비율", "예상 이탈", "잃을 수 있는\n매출 (2019년)"]
    xs = [0.0, 0.42, 0.62, 0.8, 1.0]
    for k, h in enumerate(head):
        b.text(xs[k], 0.95, h, fontsize=11.5, fontweight="bold", color=INK2, ha="left" if k == 0 else "right", va="center",
               linespacing=1.2, transform=b.transAxes)
    groups = [(t, cur[cur["rfmp_tier"] == t]) for t in TIERS] + [("전체", cur)]
    for i, (name, sub) in enumerate(groups):
        y = 0.82 - i * 0.11
        if name == "전체":
            b.plot([0, 1], [y + 0.055, y + 0.055], color=LINE, lw=1.2, transform=b.transAxes)
        vals = [name, f"{len(sub):,}명", f"{(sub['purchase_days'] <= 2).mean():.0%}", f"{sub['rate'].sum():,.0f}명",
                f"${sub['risk_rev'].sum() / 1000:,.0f}K"]
        for k, val in enumerate(vals):
            b.text(xs[k], y, esc(val), fontsize=13, ha="left" if k == 0 else "right", va="center", color=INK,
                   transform=b.transAxes)
    finish(fig, "solution1b_churn_by_days", "w3_freq_abc_input VALID(실제 이탈), w4_44_final_roster, w6_customer · 예상 = 같은 구매일 수 고객의 실제 이탈률 적용")


# ====================================================================== 04 해결과정
def s_unit_compare():
    a = abc[abc["dataset_role"] == "VALID"].set_index("model_variant")["roc_auc"]
    c = cu.set_index("customer_id")
    top = rfm["frequency"].idxmax()
    o = pdays["orders"]
    fig = slide("", "해결 ① 세는 단위를 주문에서 구매한 날로 바꾸자 결과가 달라졌습니다", f"한 번의 결제가 여러 건으로 쪼개져, 구매한 날 하루에 주문이 평균 {o.mean():.1f}건")
    ax = board(fig)
    rows = [("재구매율 (2번 이상 산 고객)", f"{(rfm['frequency'] >= 2).mean():.0%}", f"{(c['purchase_days'] >= 2).mean():.0%}",
             "재구매가 절반으로 · 착시였음"),
            ("한 번만 산 고객", f"{(rfm['frequency'] == 1).mean():.0%}", f"{(c['purchase_days'] == 1).mean():.0%}",
             "고객 절반은 하루만 구매"),
            ("가장 많이 산 고객", f"{int(rfm.loc[top, 'frequency'])}회", f"{int(c.loc[top, 'purchase_days'])}일",
             "주문 수는 방문을 부풀림"),
            ("이탈 예측력 AUC", f"{a['A_ORDERS']:.3f}", f"{a['B_DAYS']:.3f}", "구매한 날 기준이 확실히 높음")]
    ax.text(0.33, 0.95, "주문으로 셌을 때", fontsize=15, color=INK2, ha="center", fontweight="bold", transform=ax.transAxes)
    ax.text(0.58, 0.95, "구매한 날로 셌을 때", fontsize=15, color=ACC, ha="center", fontweight="bold", transform=ax.transAxes)
    ax.text(0.7, 0.95, "의미", fontsize=15, color=INK2, fontweight="bold", transform=ax.transAxes)
    for i, (lab, before, after, mean) in enumerate(rows):
        y = 0.78 - i * 0.21
        card(ax, 0.0, y - 0.08, 1.0, 0.16, color=LINE, fill="white", lw=1.2)
        ax.text(0.02, y, lab, fontsize=16, fontweight="bold", color=INK, va="center", transform=ax.transAxes)
        ax.text(0.33, y, before, fontsize=26, color=MUTED, fontweight="bold", ha="center", va="center", transform=ax.transAxes)
        arrow(ax, (0.41, y), (0.49, y), color=ACC, lw=2.4)
        ax.text(0.58, y, after, fontsize=26, color=ACC, fontweight="bold", ha="center", va="center", transform=ax.transAxes)
        ax.text(0.7, y, mean, fontsize=14.5, color=INK2, va="center", transform=ax.transAxes)
    finish(fig, "solution1_unit", "w2_rfm(주문 기준), w6_customer(구매한 날 기준), w3_freq_abc_metrics VALID AUC (r3-1)")


def s_rfmp():
    w = load("w3_rfmp_weights_py").set_index("metric")
    cv = load("w3_rfmp_cluster_cv_py")
    r = load("w3_customer_rfmp_py")
    med = r.groupby("rfmp_tier").agg(n=("customer_id", "size"), rec=("recency", "median"),
                                    days=("frequency_days", "median"), mon=("monetary", "median")).reindex(TIERS)
    zero_cv = int(cv[(cv["metric"] == "F") & (cv["cv"] < 1e-6)]["cluster_n"].sum())
    fig = slide("", "해결 ② 가치 등급(RFMP): 네 지표를 점수로 바꿔 가중합한 뒤 6등분")
    ax = board(fig, (0.05, 0.47, 0.9, 0.26))
    steps = [("① 지표 4개", ["R 마지막 구매 후 지난 날", "F 구매한 날 수", "M 2019년 구매 금액",
                            "P 산 카테고리의 가치 합"], ACC),
             ("② 0~100점으로", ["지표마다 전체 고객 중 순위", "R은 최근일수록 높은 점수",
                              "단위가 달라도 같은 척도"], ACC),
             ("③ 군집 수 k 정하기", ["지표별로 K-Means를 k = 1~8 실행",
                                  "Elbow 값으로 지정", "R 3 · F 4 · M 2 · P 4"], LILAC),
             ("④ 6등분", ["점수 = Σ 점수 × 가중치", "점수 순서로 같은 인원씩",
                         f"VIP ~ Bronze, 등급당 약 {len(r) // 6}명"], MINT)]
    for i, (t, lines, c) in enumerate(steps):
        x = i * 0.255
        card(ax, x, 0.0, 0.235, 1.0, color=c, fill=SOFT[c], lw=1.6)
        ax.text(x + 0.015, 0.84, t, fontsize=15, fontweight="bold", color=INK, va="center", transform=ax.transAxes)
        for j, l in enumerate(lines):
            ax.text(x + 0.015, 0.62 - j * 0.16, l, fontsize=11.5, color=INK2, va="center", transform=ax.transAxes)
        if i < 3:
            arrow(ax, (x + 0.237, 0.5), (x + 0.253, 0.5), color=MUTED, lw=2)
    # 가중치 막대
    fig.text(0.06, 0.4, "가중치 = 군집 안 흩어짐(CV)이 작은 지표일수록 크게", fontsize=14, fontweight="bold", color=INK)
    a = ax_at(fig, [0.15, 0.1, 0.28, 0.26], grid="x")
    names = {"F": "F 구매한 날 수", "P": "P 제품 가치", "M": "M 구매 금액", "R": "R 최근성"}
    order = w["final_weight"].sort_values().index
    a.barh(range(len(order)), w.loc[order, "final_weight"], color=LILAC, height=0.6)
    for i, m in enumerate(order):
        a.text(w.loc[m, "final_weight"] + 0.01, i, f"{w.loc[m, 'final_weight']:.0%}  (k={int(w.loc[m, 'k'])})",
               va="center", fontsize=12, color=INK)
    a.set_yticks(range(len(order)))
    a.set_yticklabels([names[m] for m in order], fontsize=12)
    a.set_xlim(0, 0.8)
    a.set_xticks([])
    # 등급별 모습
    fig.text(0.53, 0.4, "④ 등급별 모습 (중앙값)", fontsize=14, fontweight="bold", color=INK)
    b = board(fig, (0.53, 0.09, 0.42, 0.28))
    head = ["등급", "고객", "구매한 날", "마지막 구매 후", "2019년 구매 금액"]
    xs = [0.0, 0.3, 0.5, 0.75, 1.0]
    for k, h in enumerate(head):
        b.text(xs[k], 0.95, h, fontsize=11, fontweight="bold", color=INK2, ha="left" if k == 0 else "right",
               va="center", transform=b.transAxes)
    for i, t in enumerate(TIERS):
        y = 0.8 - i * 0.145
        vals = [t, f"{int(med.loc[t, 'n'])}명", f"{med.loc[t, 'days']:g}일", f"{med.loc[t, 'rec']:.0f}일",
                f"${med.loc[t, 'mon']:,.0f}"]
        for k, v in enumerate(vals):
            b.text(xs[k], y, esc(v), fontsize=12, color=INK, ha="left" if k == 0 else "right", va="center",
                   transform=b.transAxes)
    finish(fig, "solution2_rfmp", f"w3_rfmp_weights_py, w3_rfmp_cluster_cv_py, w3_customer_rfmp_py (r3-1 3.5~3.7) · "
                                  f"가중치 계산에서 값이 모두 같은 군집(구매한 날 1일·2일, {zero_cv:,}명)은 흩어짐이 0이라 제외")


def s_value_risk():
    n = roster.pivot_table(index="rfmp_tier", columns="relative_risk_grade", values="customer_id", aggfunc="count",
                           fill_value=0).reindex(index=TIERS, columns=RISKS, fill_value=0)
    care = RULE_N.get(2, 0) + RULE_N.get(3, 0)
    auto = RULE_N.get(4, 0) + RULE_N.get(5, 0) + RULE_N.get(6, 0)
    v2mode = GUARD_LABEL != "지켜야 할 고객"
    fig = slide("", f"해결 ④ 가치 × 위험{':' if v2mode else '으로'} {GUARD_LABEL} {GUARD_N}명, "
                    + (f"담당자 대응은 {care}명만" if v2mode else f"비싼 대응은 {care}명만"))
    ax = board(fig, (0.14, 0.08, 0.42, 0.6))
    cw, ch = 1 / 3, 1 / 6
    for i, t in enumerate(TIERS):
        ax.text(-0.03, 1 - (i + 0.5) * ch, t, fontsize=13, color=INK2, ha="right", va="center", transform=ax.transAxes)
        for j, r in enumerate(RISKS):
            focus = t in GUARD_TIERS and r == "High"
            ax.add_patch(FancyBboxPatch((j * cw + 0.01, 1 - (i + 1) * ch + 0.01), cw - 0.02, ch - 0.02,
                                        boxstyle="round,pad=0,rounding_size=0.015", transform=ax.transAxes,
                                        facecolor=SOFT[GUARD] if focus else "#F4F6FB",
                                        edgecolor=GUARD if focus else "none", lw=2.4))
            ax.text(j * cw + cw / 2, 1 - (i + 0.5) * ch, f"{n.iat[i, j]}명", fontsize=15, ha="center", va="center",
                    fontweight="bold" if focus else "normal", color=GUARD if focus else INK2, transform=ax.transAxes)
    for j, r in enumerate(RISKS):
        ax.text(j * cw + cw / 2, 1.03, f"{r} 위험", fontsize=13, color=INK2, ha="center", transform=ax.transAxes)
    b = board(fig, (0.62, 0.08, 0.34, 0.62))
    b.text(0, 0.95, f"{GUARD_LABEL} · 2019년 매출", fontsize=14, color=INK2, transform=b.transAxes)
    b.text(0, 0.83, esc(f"{GUARD_N}명 · ${GUARD_REV / 1000:,.0f}K"), fontsize=26, fontweight="bold", color=GUARD,
           transform=b.transAxes)
    cards = ([("담당자가 직접", "기존 고객 · 재주문·전담 상담·개별 혜택", care, GUARD),
              ("신규 온보딩", f"90일 미만 신규 · {REMIND} 알림 · 혜택 없음", GUARD_NEW, MINT)] if v2mode else
             [("개별 관리", "기존 고객 · 개별 연락·맞춤 혜택", care, GUARD),
              ("반응 확인", "90일 미만 신규 · 비싼 혜택 없이", GUARD_NEW, MINT)])
    for k, (t, d, v, c) in enumerate(cards):
        y = 0.52 - k * 0.24
        card(b, 0, y, 1, 0.2, color=c, fill=SOFT[c], lw=1.8)
        b.text(0.05, y + 0.13, t, fontsize=16, fontweight="bold", color=INK, transform=b.transAxes)
        b.text(0.05, y + 0.05, d, fontsize=12, color=INK2, transform=b.transAxes)
        b.text(0.95, y + 0.1, f"{v}명", fontsize=22, fontweight="bold", color=c, ha="right", va="center", transform=b.transAxes)
    if v2mode:
        S2 = v2()["summary"]
        rest = (f"나머지 {len(roster) - GUARD_N:,}명: 신규 {RULE_N.get(1, 0) - GUARD_NEW}명 온보딩\n"
                f"{auto}명 자동 재방문 알림 · {RULE_N.get(7, 0)}명 관계 유지")
        note = f"{S2['guard_one']:.0%}가 한 번 크게 사고 돌아오지 않았고\n{S2['guard_bulk']:.0%}가 대량 주문 고객입니다"
        b.text(0, 0.2, rest, fontsize=11.5, color=INK2, va="top", linespacing=1.4, transform=b.transAxes)
        b.text(0, 0.06, note, fontsize=11.5, color=INK2, va="top", linespacing=1.4, transform=b.transAxes)
    else:
        b.text(0, 0.2, f"나머지 {len(roster) - GUARD_N:,}명: 신규 {RULE_N.get(1, 0) - GUARD_NEW}명 반응 확인\n"
                       f"{auto}명 자동 알림 · {RULE_N.get(7, 0)}명 지금처럼", fontsize=11.5, color=INK2, va="top", linespacing=1.4,
               transform=b.transAxes)
        b.text(0, 0.06, "효과 확인: 대상의 절반은 연락하지 않는\n보류군과 90일 재구매율 비교", fontsize=11.5, color=INK2, va="top",
               linespacing=1.4, transform=b.transAxes)
    finish(fig, "solution4_value_risk", "w4_44_final_roster, w4_42_customer_action 실행 규칙 7개 (r4-1)")


def s_models2():
    tuned = fit[fit["tuning"] == "튜닝 후"]
    best = tuned.loc[tuned.groupby("model")["valid_auc"].idxmax()].set_index("model")
    best.loc["로지스틱 회귀"] = BASE
    rf = _rf_best()
    coef = load("w4_41_coefficients").set_index("feature_name")["coefficient"]
    orr = lambda f: np.exp(coef[f])
    order = ["로지스틱 회귀", "의사결정나무", "랜덤 포레스트", "그래디언트 부스팅"]
    fig = slide("", "해결 ③ 모델 4종을 변수, 튜닝까지 16가지로 비교", f"모델을 바꿔도 예측력(AUC) {tuned['valid_auc'].min():.2f}~{tuned['valid_auc'].max():.2f} · 한계는 모델이 아니라 변수(데이터)")
    ax = ax_at(fig, [0.19, 0.14, 0.36, 0.52], grid="x")
    for i, m in enumerate(order):
        r = best.loc[m]
        sig_low = bool(r["ci_high"] < 0) if pd.notna(r["ci_high"]) else False
        c = BAD if sig_low else (ACC if m == "로지스틱 회귀" else LILAC)
        ax.scatter([r["valid_auc"]], [i], s=220, color=c, zorder=3)
        ax.text(r["valid_auc"] + 0.002, i, f"  {r['valid_auc']:.3f}" + ("  (확실히 낮음)" if sig_low else ""), va="center",
                fontsize=13, color=c)
    ax.axvline(BASE["valid_auc"], color=ACC, ls="--", lw=1.5)
    ax.set_yticks(range(len(order)))
    ax.set_yticklabels(["로지스틱 회귀\n(PROC LOGISTIC)", "의사결정나무\n(PROC HPSPLIT)", "랜덤 포레스트\n(PROC HPFOREST)",
                        "그래디언트 부스팅\n(PROC GRADBOOST)"], fontsize=13)
    for k, t in enumerate(ax.get_yticklabels()):                 # 사용 모델(로지스틱)만 파란 굵은 글씨
        t.set_color(ACC if k == 0 else INK2)
        t.set_fontweight("bold" if k == 0 else "normal")
    ax.set_ylim(len(order) - 0.4, -0.6)
    ax.set_xlim(0.63, 0.70)
    ax.set_xlabel("검증 고객 1,211명 기준 예측력 AUC (비교 모델은 튜닝 후 최고값)")
    b = board(fig, (0.6, 0.1, 0.36, 0.6))
    b.text(0, 0.96, "AUC가 조금 더 높은 랜덤 포레스트 대신\n로지스틱을 쓴 이유", fontsize=15, fontweight="bold", color=INK,
           va="top", linespacing=1.4, transform=b.transAxes)
    reasons = [("차이가 우연 수준", f"랜덤 포레스트 {rf['valid_auc']:.3f} vs 로지스틱 {BASE['valid_auc']:.3f}\n"
                                f"차이 {rf['auc_diff']:+.3f}, 95% 구간 {rf['ci_low']:+.3f}~{rf['ci_high']:+.3f} (0 포함)"),
               ("학습 데이터만 외우지 않음", f"학습-검증 AUC 차이: 로지스틱 {BASE['overfit_gap']:+.3f}\n"
                                      f"랜덤 포레스트 {rf['overfit_gap']:+.3f} (학습에서만 더 높음)"),
               ("판단 이유를 숫자로 설명할 수 있음", f"구매한 날 수가 많을수록 이탈 가능성 ×{orr('frequency_days'):.2f}\n"
                                           f"한 카테고리에만 몰릴수록 ×{orr('category_concentration'):.2f} (1표준편차당 오즈)")]
    for i, (t, d) in enumerate(reasons):
        y = 0.7 - i * 0.25
        card(b, 0, y - 0.17, 1, 0.22, color=ACC, fill=SOFT[ACC], lw=1.4)
        b.text(0.04, y, f"{i + 1}. {t}", fontsize=14, fontweight="bold", color=INK, va="center", transform=b.transAxes)
        b.text(0.04, y - 0.05, d, fontsize=11.5, color=INK2, va="top", linespacing=1.4, transform=b.transAxes)
    finish(fig, "solution3_model_choice", "w7_model_fit · w7_model_auc_diff (r7_models.py) · 부트스트랩 1,000회 95% 구간 · 실행은 scikit-learn, 괄호는 SAS 대응 프로시저")


# ====================================================================== 05 목표 변경
def s_goal_shift2():
    lift = vs["actual_churn_flag"].head(200).mean() / vs["actual_churn_flag"].mean()
    tuned = fit[fit["tuning"] == "튜닝 후"]
    a = abc[abc["dataset_role"] == "VALID"].set_index("model_variant")["roc_auc"]
    rk = [v[1] for v in LOGRES.values()] if LOGRES else [None, None]
    fig = slide("", "목표 변경: 떠날 고객 골라내기에서 두 번째 구매 만들기로",
                "넓게 쓰는 것도, 떠날 고객을 골라 붙잡는 것도 효과가 작았습니다")
    ax = board(fig)
    ax.text(0.0, 0.99, "개선 과정 → 결과", fontsize=14, fontweight="bold", color=INK2, va="top", transform=ax.transAxes)
    did = [("세는 단위 수정", f"AUC {a['A_ORDERS']:.3f} → {a['B_DAYS']:.3f}", MINT),
           ("모델 4종 · 16가지 조합", f"AUC {tuned['valid_auc'].min():.2f}~{tuned['valid_auc'].max():.2f}에서 멈춤", ACC),
           ("로그 변환", f"오분류 고객 {rk[0]}위 → {rk[1]}위", ACC)]
    for i, (t, r, c) in enumerate(did):
        x = i * 0.34
        card(ax, x, 0.64, 0.32, 0.25, color=c, fill=SOFT[c], lw=1.8)
        ax.text(x + 0.02, 0.82, t, fontsize=14, fontweight="bold", color=INK, transform=ax.transAxes)
        ax.text(x + 0.02, 0.69, r, fontsize=14, color=c, fontweight="bold", transform=ax.transAxes)
    ax.text(0.0, 0.56, "넓게 쓰기도, 골라내기도 한계", fontsize=14, fontweight="bold", color=INK2, va="top", transform=ax.transAxes)
    top200, avg = vs["actual_churn_flag"].head(200).mean(), vs["actual_churn_flag"].mean()
    lim = ["마케팅비를 더 써도\n첫 구매는 늘지 않음 · 6장",                      # 넓게 쓰기의 한계 (6장 되짚기)
           f"위험 상위 200명 이탈률 {top200:.0%}\n평균 {avg:.0%}",               # 골라내기의 한계
           f"종속변수 converted_90d로 예측\nAUC {AUC_CONV:.2f} · 동전 던지기 수준"]
    for i, t in enumerate(lim):
        x = i * 0.34
        card(ax, x, 0.28, 0.32, 0.2, color=BAD if i == 1 else GRAY, fill="#FDEDF0" if i == 1 else "#F4F6FB")
        ax.text(x + 0.02, 0.38, t, fontsize=13.5, color=INK, va="center", linespacing=1.4, transform=ax.transAxes)
    card(ax, 0.0, 0.02, 0.44, 0.18, color=GRAY, fill="#F4F6FB")
    ax.text(0.03, 0.11, "이전   떠날 고객을 예측해 골라 붙잡는다", fontsize=16, color=MUTED, va="center", transform=ax.transAxes)
    arrow(ax, (0.45, 0.11), (0.53, 0.11), color=ACC, lw=3)
    card(ax, 0.54, 0.02, 0.46, 0.18, color=ACC, fill=SOFT[ACC], lw=2.2)
    ax.text(0.565, 0.145, "이후   두 번째 구매를 만든다 (Nest-USA 중심)", fontsize=14, color=INK, fontweight="bold",
            va="center", transform=ax.transAxes)
    ax.text(0.565, 0.07, "가치 × 위험은 '누구부터'의 순서로만 사용", fontsize=12.5, color=INK2, va="center",
            transform=ax.transAxes)
    finish(fig, "goal_shift", "w3_freq_abc_metrics, w7_model_fit, w4_41_valid_scored, w6_mkt_regression, w6_conv_metrics")


# ====================================================================== 06 선택과 집중
def s_nest():
    from itertools import combinations
    c2 = co.assign(rev=co["quantity"] * co["avg_price"])
    cat = c2.groupby("product_category").agg(rev=("rev", "sum"), cust=("customer_id", "nunique"), lines=("rev", "size"))
    cat = cat.sort_values("rev", ascending=False)
    cat["rev_share"], cat["cust_share"] = cat["rev"] / cat["rev"].sum(), cat["cust"] / len(cu)
    entry = cb["entry_category"].value_counts(normalize=True)
    e = seg[(seg["dimension"] == "첫 구매 대표 카테고리") & (seg["customers"] >= 40)].sort_values("conversion")
    bk = c2.groupby(["customer_id", "transaction_date"])["product_category"].apply(set)
    cats = [x for x in cat.index if cat.loc[x, "lines"] > 300][:8]
    pr = {x: bk.apply(lambda s, x=x: x in s).mean() for x in cats}
    lifts = sorted(((bk.apply(lambda s, a_=a_, b_=b_: a_ in s and b_ in s).mean() / (pr[a_] * pr[b_]), a_, b_)
                    for a_, b_ in combinations(cats, 2)), reverse=True)
    med = float(np.median([l[0] for l in lifts]))
    nu = cat.loc["Nest-USA"]
    fig = slide("", f"선택과 집중: 고객의 {nu['cust_share']:.0%}가 산 Nest-USA를 중심에", f"Nest-USA = 매출의 {nu['rev_share']:.0%} · 첫 구매의 {entry['Nest-USA']:.0%} · 시작 고객 재구매율 1위")
    fig.text(0.06, 0.7, "카테고리별 매출 비중", fontsize=15, fontweight="bold", color=INK)
    ax = ax_at(fig, [0.17, 0.1, 0.3, 0.56], grid="x")
    t6 = cat.head(6)[::-1]
    ax.barh(range(6), t6["rev_share"], color=[ACC if i == 5 else "#C9D3FD" for i in range(6)], height=0.6)
    for i, (v, cs_) in enumerate(zip(t6["rev_share"], t6["cust_share"])):
        ax.text(v + 0.01, i, f"{v:.0%}  (고객 {cs_:.0%})", va="center", fontsize=12, color=ACC if i == 5 else INK2)
    ax.set_yticks(range(6))
    ax.set_yticklabels(t6.index, fontsize=13)
    ax.set_xlim(0, 0.85)
    ax.set_xticks([])
    fig.text(0.54, 0.7, "첫 구매 카테고리별 90일 재구매율", fontsize=15, fontweight="bold", color=INK)
    fig.text(0.54, 0.672, "( ) = 첫 구매 고객 수 · 막대 옆 = 그중 90일 안에 다시 산 비율 · 인원", fontsize=11, color=INK2)
    a2 = ax_at(fig, [0.66, 0.1, 0.3, 0.56], grid="x")
    y = np.arange(len(e))
    a2.barh(y, e["conversion"], color=[MINT if l == "Nest-USA" else GRAY for l in e["level"]], height=0.6)
    for yi, v, n in zip(y, e["conversion"], e["customers"]):
        a2.text(v + 0.01, yi, f"{v:.0%} · {round(v * n)}명", va="center", fontsize=13, fontweight="bold", color=INK2)
    a2.set_yticks(y)
    a2.set_yticklabels([f"{l} ({n}명)" for l, n in zip(e["level"], e["customers"])], fontsize=12)
    a2.set_xlim(0, 0.6)
    a2.set_xticks([])
    finish(fig, "focus_nest_usa", "clean_online, w6_conv_base, w6_conv_segments (r6-1) · 재구매율은 고객 40명 이상 카테고리")


# ====================================================================== 07 결론
def _pg(fn):
    return next(i for i, (_, f) in enumerate(PLAN, start=1) if f is fn)


def s_findings2():
    e = seg[seg["dimension"] == "첫 구매 대표 카테고리"].set_index("level")["conversion"]
    d = DAY_CHURN["mean"]
    fig = slide("", "결론: 두 번째·세 번째 구매로 이탈 가능성을 낮춥니다", f"구매한 날이 많을수록 남습니다 · 11일 이상 산 고객의 이탈률 {d.iloc[-1]:.0%}")
    ax = board(fig, (0.05, 0.08, 0.9, 0.66))
    items = [(f"{d.iloc[1]:.0%}~{d.iloc[0]:.0%}", "구매한 날이 1~2일인 고객이\n90일 안에 떠난 비율", GUARD),
             (f"{GUARD_N}명", f"가치가 높고 떠날 위험도 높은 고객\n2019년 매출 ${GUARD_REV / 1000:,.0f}K", LILAC),
             (f"{e['Nest-USA']:.0%}", "Nest-USA로 시작한 고객의\n90일 재구매율 (카테고리 1위)", MINT)]
    for i, (v, dsc, c) in enumerate(items):
        x = i * 0.34
        card(ax, x, 0.3, 0.32, 0.68, color=LINE, fill="white", lw=1.2)
        ax.add_patch(FancyBboxPatch((x, 0.3), 0.008, 0.68, boxstyle="square,pad=0", facecolor=c, edgecolor="none",
                                    transform=ax.transAxes))
        ax.text(x + 0.04, 0.72, v, fontsize=46, fontweight="bold", color=c, va="center", transform=ax.transAxes)
        ax.text(x + 0.04, 0.47, esc(dsc), fontsize=15, color=INK, va="center", linespacing=1.5, transform=ax.transAxes)
    card(ax, 0, 0.02, 1, 0.18, color=ACC, fill=SOFT[ACC], lw=2)
    ax.text(0.03, 0.11, f"→  구매한 날과 가치로 고객 {len(roster):,}명 각자의 할 일을 정했습니다",
            fontsize=17, fontweight="bold", color=INK, va="center", transform=ax.transAxes)
    finish(fig, "conclusion", "w3_freq_abc_input VALID, w4_44_final_roster, w6_conv_segments")



# ====================================================================== 부록: 90일 기준 반박과 답
def a_90_survivor():
    ds = [7, 14, 30, 60, 90, 120, 150]
    res = [_return_after_inactive(d) for d in ds]
    p90 = pdays.sort_values(["customer_id", "purchase_date"])[["customer_id", "purchase_date"]].copy()
    p90["gap"] = (p90.groupby("customer_id")["purchase_date"].shift(-1) - p90["purchase_date"]).dt.days
    e = p90[(p90["purchase_date"] + pd.Timedelta(days=120)) <= END]
    reached = e[e["gap"].isna() | (e["gap"] > 90)]
    late = reached["gap"].between(91, 120).mean()
    fig = slide("", "90일 기준 ①: 돌아오지 않은 고객까지 넣어도 결론은 같습니다", "반박: 다시 온 고객만 봤다(생존편향) · 120일로 늘리면 달라진다")
    ax = ax_at(fig, [0.07, 0.14, 0.52, 0.52])
    x = np.arange(len(ds))
    v = [r[0] for r in res]
    ax.bar(x, v, color=[GUARD if d == 90 else "#C9D3FD" for d in ds], width=0.62)
    for i, (vv, n) in enumerate(res):
        ax.text(i, vv + 0.01, f"{vv:.0%}", ha="center", fontsize=14, fontweight="bold", color=GUARD if ds[i] == 90 else INK2)
        ax.text(i, 0.015, f"{n:,}건", ha="center", fontsize=9.5, color="white" if ds[i] == 90 else INK2)
    ax.set_xticks(x)
    ax.set_xticklabels([f"{d}일" for d in ds])
    ax.set_xlabel("마지막 구매 후 이만큼 안 온 시점 (안 돌아온 고객 포함)")
    ax.set_ylabel("이후 90일 안에 다시 산 비율")
    ax.yaxis.set_major_formatter(plt.FuncFormatter(lambda val, _: f"{val:.0%}"))
    ax.set_ylim(0, 0.48)
    b = board(fig, (0.63, 0.1, 0.33, 0.6))
    answers = [("생존편향 → 분모를 바꿔 다시 계산",
                f"안 돌아온 고객까지 모두 넣어도, 90일째 안 온\n고객이 이후 90일 안에 돌아올 확률은 {res[4][0]:.0%}\n(10명 중 7명은 안 돌아옴)"),
               ("120일 → 서서히 줄 뿐, 절벽은 없음",
                f"90일째 안 온 고객 중 91~120일에 돌아온 비율 {late:.0%}\n90일은 '골든타임'이 아니라 판정 기준\n→ 그래서 연락은 90일 전(30·60일)에")]
    for i, (t, d) in enumerate(answers):
        y = 0.62 - i * 0.48
        card(b, 0, y - 0.04, 1, 0.42, color=MINT, fill=SOFT[MINT], lw=1.6)
        b.text(0.05, y + 0.31, t, fontsize=14, fontweight="bold", color=INK, transform=b.transAxes)
        b.text(0.05, y + 0.22, d, fontsize=12, color=INK2, va="top", linespacing=1.5, transform=b.transAxes)
    finish(fig, "appx_90days_survivorship", "w6_purchase_day · 각 시점 이후 90일을 끝까지 관찰할 수 있는 구매만 사용")


def a_90_robust():
    """카테고리 주기 · 마케팅 개입 · 기준 변경(60/120일) 민감도"""
    from scipy.stats import spearmanr
    from sklearn.compose import ColumnTransformer
    from sklearn.impute import SimpleImputer
    from sklearn.linear_model import LogisticRegression
    from sklearn.pipeline import Pipeline
    from sklearn.preprocessing import OneHotEncoder, StandardScaler

    from rcommon import LogSkewed
    c2 = co.assign(rev=co["quantity"] * co["avg_price"])
    top = (c2.groupby(["customer_id", "transaction_date", "product_category"])["rev"].sum().reset_index()
           .sort_values("rev").drop_duplicates(["customer_id", "transaction_date"], keep="last")
           .rename(columns={"transaction_date": "purchase_date"}))
    p = pdays.sort_values(["customer_id", "purchase_date"])[["customer_id", "purchase_date"]].copy()
    p["gap"] = (p.groupby("customer_id")["purchase_date"].shift(-1) - p["purchase_date"]).dt.days
    gaps = p.merge(top, on=["customer_id", "purchase_date"]).dropna(subset=["gap"])
    t = gaps.groupby("product_category")["gap"].agg(n="size", med="median", w90=lambda s: (s <= 90).mean())
    t = t[t["n"] >= 30].sort_values("n", ascending=False).head(6)
    # 기준 변경 민감도: 같은 모델을 60/90/120일 이탈 정의로 학습해 지금 고객 순위 비교
    num = ["recency", "monetary", "avg_order_value", "avg_shipping", "tenure", "product_category_count",
           "category_concentration", "avg_days_between_orders", "std_days_between_orders", "frequency_days"]
    cat_ = ["gender", "region"]
    d = load("w3_freq_abc_input").copy()
    cs = load("w4_41_current_scored").copy()
    for X in (d, cs):
        for c in cat_:
            X[c] = X[c].fillna("UNKNOWN").astype(str)
    tr = d[d["split_role"].str.upper() == "TRAIN"]
    cut = pd.Timestamp("2019-06-30")
    sc = {}
    for w in (60, 90, 120):
        came = pdays[(pdays["purchase_date"] > cut) & (pdays["purchase_date"] <= cut + pd.Timedelta(days=w))]["customer_id"]
        y = (~tr["customer_id"].isin(set(came))).astype(int)
        pre = ColumnTransformer([("n", Pipeline([("i", SimpleImputer(strategy="median")), ("s", StandardScaler())]), num),
                                 ("c", Pipeline([("i", SimpleImputer(strategy="most_frequent")),
                                                 ("o", OneHotEncoder(handle_unknown="ignore"))]), cat_)])
        m = Pipeline([("log", LogSkewed()), ("p", pre), ("m", LogisticRegression(C=1.0, solver="liblinear", max_iter=2000,
                                                                                   random_state=2026))]).fit(tr[num + cat_], y)
        sc[w] = pd.Series(m.predict_proba(cs[num + cat_])[:, 1], index=cs["customer_id"])
    tiers = roster.set_index("customer_id")["rfmp_tier"]

    def guard(s):
        hi = s.rank(ascending=False, pct=True) <= 1 / 3
        return {c for c in s.index[hi] if tiers[c] in GUARD_TIERS}
    g90 = guard(sc[90])
    sens = [(w, spearmanr(sc[90], sc[w])[0], len(guard(sc[w]) & g90), len(g90)) for w in (60, 120)]
    fig = slide("", "90일 기준 ②: 구매 주기 · 마케팅 · 기준 변경에도 결론은 같습니다", "반박: 카테고리마다 주기가 다르다 · 방치해서 안 왔다 · 90일 근거가 약하다")
    heads = [("주기가 긴 상품은 없었다", "주요 카테고리 재구매 간격 중앙값 · 90일 안 재구매 비율"),
             ("방치하지 않았다", "일별 마케팅비 - 365일 매일 집행"),
             ("기준을 바꿔도 같은 고객이 뽑힌다", "같은 모델을 60·120일 이탈 정의로 다시 학습")]
    for (h, s), x in zip(heads, (0.05, 0.37, 0.69)):
        fig.text(x, 0.7, h, fontsize=15, fontweight="bold", color=INK)
        fig.text(x, 0.665, s, fontsize=10.5, color=INK2)
    a1 = ax_at(fig, [0.13, 0.14, 0.2, 0.48], grid="x")
    yy = np.arange(len(t))[::-1]
    a1.barh(yy, t["med"], color=ACC, height=0.6)
    for yi, (m_, w90) in zip(yy, zip(t["med"], t["w90"])):
        a1.text(m_ + 1, yi, f"{m_:.0f}일 · {w90:.0%}", va="center", fontsize=11, color=INK2)
    a1.set_yticks(yy)
    a1.set_yticklabels(t.index, fontsize=11)
    a1.set_xlim(0, 110)
    a1.set_xlabel("재구매 간격 중앙값 (일)")
    a2 = ax_at(fig, [0.38, 0.14, 0.26, 0.48])
    a2.plot(daily.index, daily["spend"] / 1000, color=LEMON, lw=1.2)
    a2.set_ylim(0, daily["spend"].max() / 1000 * 1.15)
    a2.set_ylabel("일별 마케팅비 ($K)")
    a2.xaxis.set_major_formatter(plt.FuncFormatter(lambda val, _: ""))
    a2.text(0.02, 0.92, esc(f"0원인 날 {(daily['spend'] <= 0).sum()}일 · 하루 최소 ${daily['spend'].min():,.0f}"),
            transform=a2.transAxes, fontsize=11.5, color=INK, fontweight="bold")
    b = board(fig, (0.69, 0.12, 0.27, 0.52))
    b.text(0, 1.0, "90일 기준 결과와 비교", fontsize=12, color=INK2, va="top", transform=b.transAxes)
    for i, (w, rho, ov, tot) in enumerate(sens):
        y = 0.56 - i * 0.44
        card(b, 0, y - 0.04, 1, 0.36, color=MINT, fill=SOFT[MINT])
        b.text(0.05, y + 0.22, f"{w}일 기준", fontsize=15, fontweight="bold", color=INK, transform=b.transAxes)
        b.text(0.05, y + 0.1, f"위험 순위 상관 {rho:.2f}", fontsize=12.5, color=INK2, transform=b.transAxes)
        b.text(0.05, y + 0.0, f"{GUARD_LABEL} {tot}명 중 {ov}명 동일", fontsize=12.5, color=MINT, fontweight="bold",
               transform=b.transAxes)
    finish(fig, "appx_90days_robustness", "clean_online, w6_purchase_day, w6_daily, w3_freq_abc_input TRAIN(6월 30일 기준) · 상관 1 = 순위 동일")



# ====================================================================== 01 주제 선정 (주제 + 질문 세 가지)
def s_topic():
    mk, rv = k6["marketing_cost"].sum(), k6["revenue_ex_gst"].sum()
    fig = slide("", "왜 이 주제인가: 신규는 줄고, 매출은 소수에게 몰리고, 마케팅비는 크게 쓰고 있었습니다", "2019년 데이터를 처음 봤을 때 눈에 띈 세 가지")
    ax = board(fig)
    items = [("처음 구매하는 고객", f"{NEW_H1:.0f}→{NEW_H2:.0f}명", f"월평균, 상반기 → 하반기 ({NEW_H2 / NEW_H1 - 1:+.0%})", GUARD),
             ("매출 집중", f"{TOP20:.0%}", "2019년 매출 상위 20% 고객의 몫", LILAC),
             ("연 마케팅비", f"${mk / 1e6:.2f}M", f"매출의 {mk / rv:.0%} · 365일 매일 집행", LEMON)]
    for i, (t, v, d, c) in enumerate(items):
        x = 0.02 + i * 0.33
        card(ax, x, 0.44, 0.3, 0.52, color=c, fill=SOFT[c], lw=2)
        ax.text(x + 0.03, 0.86, t, fontsize=17, fontweight="bold", color=INK, transform=ax.transAxes)
        big(ax, x + 0.03, 0.58, v, d, c, size=36, label_size=13)
    card(ax, 0.02, 0.0, 0.96, 0.36, color=ACC, fill="white", lw=2.2)
    ax.text(0.05, 0.27, "그래서 주제   한정된 마케팅 예산으로, 누구를 어떻게 지킬 것인가", fontsize=19, fontweight="bold",
            color=INK, va="center", transform=ax.transAxes)
    qs = [("Q1", "누구를 지킬까", ACC), ("Q2", "무엇이 효과 있을까", LEMON), ("Q3", "누가 다시 올까", MINT)]
    for i, (q, t, c) in enumerate(qs):
        x = 0.05 + i * 0.31
        ax.add_patch(FancyBboxPatch((x, 0.05), 0.28, 0.11, boxstyle="round,pad=0,rounding_size=0.02", facecolor=SOFT[c],
                                    edgecolor="none", transform=ax.transAxes))
        ax.text(x + 0.02, 0.105, q, fontsize=15, fontweight="bold", color=c, va="center", transform=ax.transAxes)
        ax.text(x + 0.065, 0.105, t, fontsize=15, color=INK, va="center", transform=ax.transAxes)
    finish(fig, "topic_reason", "w6_monthly_kpi, w6_customer (r6-1)")


# ====================================================================== 02 초기 목표 (목표 + 이탈 정의 · 기간)
def s_initial_goal():
    gap = pdays.sort_values(["customer_id", "purchase_date"]).groupby("customer_id")["purchase_date"].diff().dt.days.dropna()
    fd = pd.to_datetime(cu["first_day"])
    n_tr, n_va = int((fd <= "2019-06-30").sum()), int((fd <= "2019-10-02").sum())
    fig = slide("", "초기 목표: 90일 안에 안 올 고객을 미리 골라 붙잡기", "이탈 = 기준일 이후 90일 동안 구매 없음 · 과거 시점에서 예측하고 실제 구매로 채점")
    ax = board(fig, (0.05, 0.53, 0.9, 0.19))
    steps = ["① 고객 가치 등급 매기기", "② 90일 안에 안 올 고객 예측", "③ 둘을 합쳐 대상 고르기"]
    for i, t in enumerate(steps):
        x = i * 0.34
        card(ax, x, 0.08, 0.3, 0.84, color=ACC, fill=SOFT[ACC], lw=1.6)
        ax.text(x + 0.15, 0.5, t, fontsize=16, fontweight="bold", color=INK, ha="center", va="center", transform=ax.transAxes)
        if i < 2:
            arrow(ax, (x + 0.305, 0.5), (x + 0.335, 0.5), lw=2.4)
    # 타임라인: 학습 · 검증 · 운영
    fig.text(0.05, 0.45, "기간 설정", fontsize=15, fontweight="bold", color=INK)
    a = ax_at(fig, [0.17, 0.12, 0.58, 0.3], grid=None)
    d0 = pd.Timestamp("2019-01-01")
    day = lambda s: (pd.Timestamp(s) - d0).days
    rows = [("학습", f"{n_tr:,}명", "2019-06-30", False), ("검증", f"{n_va:,}명", "2019-10-02", False),
            ("운영 점수", f"{len(cu):,}명", "2019-12-31", True)]
    for i, (name, n, cut, future) in enumerate(rows):
        y = 2 - i
        a.barh(y, day(cut), left=0, height=0.5, color="#C9D3FD")
        a.text(day(cut) / 2, y, "모델에 보여 준 기록", ha="center", va="center", fontsize=11, color=INK)
        if future:
            a.barh(y, 90, left=day(cut) + 1, height=0.5, color="white", edgecolor=GUARD, ls="--", lw=1.5)
            a.text(day(cut) + 46, y, "아직 모름", ha="center", va="center", fontsize=11, color=GUARD)
        else:
            a.barh(y, 90, left=day(cut) + 1, height=0.5, color=GUARD)
            a.text(day(cut) + 46, y, "90일 채점", ha="center", va="center", fontsize=11, color="white", fontweight="bold")
        t = pd.Timestamp(cut)
        a.text(day(cut), y + 0.36, f"{t.month}/{t.day}", ha="center", fontsize=10.5, color=INK2)
        a.text(-8, y, f"{name}  {n}", ha="right", va="center", fontsize=13, color=INK, fontweight="bold")
    ticks = ["2019-01-01", "2019-04-01", "2019-07-01", "2019-10-01", "2020-01-01", "2020-04-01"]
    a.set_xticks([day(t) for t in ticks])
    a.set_xticklabels(["1월", "4월", "7월", "10월", "20년 1월", "4월"])
    a.set_xlim(0, day("2020-04-01"))
    a.set_ylim(-0.6, 2.7)
    a.set_yticks([])
    a.spines["left"].set_visible(False)
    b = board(fig, (0.79, 0.12, 0.17, 0.33))
    card(b, 0, 0, 1, 1, color=GRAY, fill="#F6F8FB", lw=1.2)
    b.text(0.08, 0.86, "왜 90일인가", fontsize=14, fontweight="bold", color=INK, transform=b.transAxes)
    b.text(0.08, 0.72, f"다시 산 경우의 {(gap <= 90).mean():.0%}가\n90일 안에 돌아옴\n(간격 중앙값 {gap.median():.0f}일)",
           fontsize=11.5, color=INK2, va="top", linespacing=1.45, transform=b.transAxes)
    b.text(0.08, 0.36, f"10/3 이후 첫 구매\n{len(cu) - n_va}명은 검증 채점에서만\n제외 (운영 명단엔 포함)",
           fontsize=11.5, color=INK2, va="top", linespacing=1.45, transform=b.transAxes)
    finish(fig, "initial_goal_churn_definition", "w6_purchase_day, w6_customer · 60·120일 기준도 같은 결과 (부록 A2)")


# ====================================================================== 08 제안 (두 번째 구매 + Nest-USA로 연결, ROI 예시)
def _roi_case(m=0.30, sh=0.20, ch=20.0, sa=0.05, ca=2.0, n=100, upl=0.05, oc=5.0):
    """웹 So What? 화면과 같은 계산 (기본 가정)"""
    high = roster[roster["relative_risk_grade"] == "High"]
    a_cost, a_gain = len(high) * ch, (high["revenue_ex_gst"] * m * sh).sum()
    top = roster[roster["customer_maturity_group"] != "NEW_LT90"].sort_values("value_risk_priority_rank").head(n)
    rest = high[~high["customer_id"].isin(top["customer_id"])]
    b_cost = len(top) * ch + len(rest) * ca
    b_gain = (top["revenue_ex_gst"] * m * sh).sum() + (rest["revenue_ex_gst"] * m * sa).sum()
    o_cost = len(cu) * oc
    o_gain = len(cu) * upl * up["value_per_convert_90d"].iloc[0] * m
    return {"A": (len(high), a_cost, a_gain, a_gain - a_cost), "B": (f"{len(top)} + {len(rest)}", b_cost, b_gain, b_gain - b_cost),
            "O": (len(cu), o_cost, o_gain, o_gain - o_cost)}


def s_proposal2():
    r = roster.merge(cu[["customer_id", "purchase_days"]], on="customer_id")
    gm = r["rfmp_tier"].isin(["Diamond", "Platinum", "Gold"]) & (r["relative_risk_grade"] == "High")
    groups = [(gm, RULE_N.get(2, 0) + RULE_N.get(3, 0), f"지켜야 할 고객 {GUARD_N}명 → 개별 관리",
               f"개별 연락으로 두 번째 구매 제안 · Nest-USA 신상품·전용 혜택 (신규 {GUARD_NEW}명은 2단계)", GUARD),
              (r["action_rule_id"] == 1, RULE_N.get(1, 0), "신규는 두 번째 구매로",
               "첫 구매 후 7·30·60일 리마인드 + Nest-USA 추천 · 비싼 혜택 없음", MINT),
              (r["action_rule_id"].isin([4, 5, 6]), sum(RULE_N.get(k, 0) for k in (4, 5, 6)), "나머지는 자동 알림",
               "Nest-USA(대표 카테고리) 인기 상품 알림 · 비용 최소화", ACC)]
    fig = slide("", "제안: 우선순위는 가치 × 위험, 실행은 두 번째 구매 + Nest-USA", f"전체 {len(roster):,}명에게 7개 규칙 중 하나가 자동으로 정해지고, 웹 대시보드로 운영")
    ax = board(fig)
    ax.text(0, 0.99, "운영 3단계 · 대상은 이미 두 번째 구매 전 고객입니다", fontsize=14, fontweight="bold", color=INK2, va="top",
            transform=ax.transAxes)
    for i, (mask, n, t, dsc, c) in enumerate(groups):
        g = r[mask]
        y = 0.66 - i * 0.27
        card(ax, 0, y, 0.56, 0.23, color=c, fill=SOFT[c], lw=1.6)
        ax.text(0.025, y + 0.115, f"{i + 1}", fontsize=24, fontweight="bold", color=c, va="center", transform=ax.transAxes)
        ax.text(0.065, y + 0.175, t, fontsize=14.5, fontweight="bold", color=INK, va="center", transform=ax.transAxes)
        ax.text(0.065, y + 0.105, dsc, fontsize=11, color=INK2, va="center", transform=ax.transAxes)
        ax.text(0.065, y + 0.04, f"1~2일만 산 고객 {(g['purchase_days'] <= 2).mean():.0%} · 주력 카테고리 Nest-USA "
                                 f"{(g['top_category'] == 'Nest-USA').mean():.0%}", fontsize=11, color=c, fontweight="bold",
                va="center", transform=ax.transAxes)
        ax.text(0.545, y + 0.165, f"{n:,}명", fontsize=19, fontweight="bold", color=c, ha="right", va="center",
                transform=ax.transAxes)
    ax.text(0, 0.02, f"위험이 낮은 {RULE_N.get(7, 0):,}명은 지금처럼 유지 · 효과는 대상의 절반을 보류군으로 두고 90일 재구매율 비교",
            fontsize=11.5, color=INK2, transform=ax.transAxes)
    # ROI 예시
    roi = _roi_case()
    card(ax, 0.6, 0.12, 0.4, 0.87, color=LINE, fill="white", lw=1.4)
    ax.text(0.625, 0.92, "So What? 예시 · 웹 기본 가정", fontsize=14.5, fontweight="bold", color=INK, va="center",
            transform=ax.transAxes)
    ax.text(0.625, 0.84, esc("마진 30% · 개별 대응 성공률 20%, 1인 $20\n자동 알림 성공률 5%, 1인 $2 · 온보딩 +5%p, 1인 $5"),
            fontsize=10.5, color=INK2, va="center", linespacing=1.45, transform=ax.transAxes)
    rows = [("① High 위험 전원 개별 대응", f"{roi['A'][0]}명", *roi["A"][1:], INK2),
            ("② 대기열로 나눠 대응", f"{roi['B'][0]}명", *roi["B"][1:], ACC),
            ("신규 온보딩 (최대)", f"{roi['O'][0]:,}명", *roi["O"][1:], MINT)]
    ax.text(0.975, 0.72, "순이익", fontsize=11, color=MUTED, ha="right", transform=ax.transAxes)
    for i, (t, n, cost, gain, net, c) in enumerate(rows):
        y = 0.62 - i * 0.13
        ax.text(0.625, y + 0.02, t, fontsize=12, fontweight="bold", color=c, va="center", transform=ax.transAxes)
        ax.text(0.625, y - 0.035, esc(f"{n} · 비용 ${cost:,.0f} · 기대 이익 ${gain:,.0f}"), fontsize=10.5, color=MUTED, va="center",
                transform=ax.transAxes)
        ax.text(0.975, y, esc(f"${net:,.0f}"), fontsize=13, fontweight="bold", color=c, ha="right", va="center",
                transform=ax.transAxes)
    ratio_c, ratio_n = roi["B"][1] / roi["A"][1], roi["B"][3] / roi["A"][3]
    ax.text(0.625, 0.2, f"②는 ① 비용의 {ratio_c:.0%}로 순이익의 {ratio_n:.0%}를 얻습니다.\n"
                        "실제 성공률은 보류군 비교로 확인합니다.", fontsize=11.5, color=INK, va="center", linespacing=1.5,
            transform=ax.transAxes)
    finish(fig, "proposal", "w4_44_final_roster 실행 규칙 7개 (r4-1), w6_uplift · 웹 So What? 화면과 같은 계산 · 금액은 가정값에 따른 예시")


# ====================================================================== 부록: 시범 설계 (시도 1 + 시도 2)
def a_trials():
    months = np.arange(1, 37)
    mde = np.array([mde_prop(NEW_PER_MONTH * m / 2) for m in months]) * 100
    m12 = mde_prop(NEW_PER_MONTH * 6) * 100
    swings = [0.1, 0.2, 0.3, 0.5, 0.75, 1.0]
    wk = [weeks_needed(s) for s in swings]
    fig = slide("", f"시범 설계: 온보딩은 1년이면 +{m12:.0f}%p, 예산 교차는 ±50%로 약 {wk[3]:.0f}주", f"2020년에도 2019년처럼 매달 약 {NEW_PER_MONTH:.0f}명이 처음 구매한다고 가정")
    fig.text(0.06, 0.7, "시도 1 · 신규 전원 온보딩 (무작위 반반)", fontsize=15, fontweight="bold", color=INK)
    fig.text(0.06, 0.665, f"{REMIND} 리마인드 + Nest-USA 추천 · 우연과 구분되는 최소 재구매율 상승폭", fontsize=10.5, color=INK2)
    ax = ax_at(fig, [0.09, 0.14, 0.38, 0.48])
    ax.plot(months, mde, color=MINT, lw=3)
    for m in (12, 24):
        v = mde_prop(NEW_PER_MONTH * m / 2) * 100
        ax.scatter([m], [v], s=80, color=MINT, zorder=3)
        ax.text(m + 0.8, v + 0.8, f"{m}개월 +{v:.1f}%p", fontsize=12.5, color=INK)
    ax.set_xlabel("시범 기간 (개월)")
    ax.set_ylabel("%p")
    ax.set_ylim(0, 25)
    fig.text(0.54, 0.7, "시도 2 · 주별 마케팅 예산 교차", fontsize=15, fontweight="bold", color=INK)
    fig.text(0.54, 0.665, "주마다 예산을 무작위로 높게·낮게 · 효과 확인에 필요한 주 수", fontsize=10.5, color=INK2)
    a2 = ax_at(fig, [0.56, 0.14, 0.4, 0.48])
    a2.bar(range(6), np.minimum(wk, 300), color=[GUARD if w > 52 else MINT for w in wk], width=0.6)
    for i, w in enumerate(wk):
        a2.text(i, min(w, 300) + 6, "300주+" if w > 300 else f"{w:.0f}주", ha="center", fontsize=13, fontweight="bold",
                color=GUARD if w > 52 else MINT)
    a2.axhline(52, color=INK2, ls="--", lw=1.2)
    a2.text(5.4, 58, "1년", color=INK2, fontsize=12, ha="right")
    a2.set_xticks(range(6))
    a2.set_xticklabels([f"±{int(s * 100)}%" for s in swings])
    a2.set_xlabel("평소 예산 대비 높이고 낮추는 폭")
    a2.set_ylim(0, 340)
    finish(fig, "appx_trials", "w6_conv_base, w6_uplift, w6_daily, w6_mkt_regression (r6-1) · 필요 주 수 = 4 × (2.8 × 주간 표준편차 ÷ 기대 차이)²")


# ====================================================================== 부록: 회귀 계수
COEF_NAMES = {"frequency_days": "구매한 날 수", "avg_days_between_orders": "평균 구매 간격 (로그)",
              "category_concentration": "카테고리 집중도", "monetary": "구매 금액 (로그)",
              "product_category_count": "산 카테고리 수", "tenure": "첫 구매 후 지난 날", "recency": "마지막 구매 후 지난 날",
              "std_days_between_orders": "구매 간격 편차 (로그)", "avg_order_value": "주문당 금액 (로그)",
              "avg_shipping": "평균 배송료 (로그)"}


def a_coef():
    c = load("w4_41_coefficients").set_index("feature_name")["coefficient"]
    num = c[c.index.isin(COEF_NAMES)].sort_values()
    cat = c[~c.index.isin(COEF_NAMES)]
    orr = np.exp(num)
    fig = slide("", "모델 계수: 구매한 날 수와 구매 간격이 이탈 판단을 가장 크게 움직입니다", "1표준편차당 이탈 오즈 배수 · 1보다 작으면 덜 떠남, 크면 더 떠남")
    ax = ax_at(fig, [0.24, 0.12, 0.44, 0.58], grid="x")
    y = np.arange(len(orr))
    ax.barh(y, orr - 1, left=1, color=[MINT if v < 1 else GUARD for v in orr], height=0.6)
    for yi, v in zip(y, orr):
        ax.text(v + (0.015 if v >= 1 else -0.015), yi, f"×{v:.2f}", va="center", ha="left" if v >= 1 else "right",
                fontsize=12.5, color=INK, fontweight="bold")
    ax.axvline(1, color=INK2, lw=1.2)
    ax.set_yticks(y)
    ax.set_yticklabels([COEF_NAMES[k] for k in orr.index], fontsize=12.5)
    ax.set_xlim(0.5, 1.5)
    ax.set_xlabel("이탈 오즈 배수 (1표준편차당)")
    b = board(fig, (0.72, 0.12, 0.24, 0.58))
    card(b, 0, 0, 1, 1, color=GRAY, fill="#F6F8FB", lw=1.2)
    b.text(0.07, 0.92, "읽는 법", fontsize=14, fontweight="bold", color=INK, transform=b.transAxes)
    b.text(0.07, 0.84, f"구매한 날 수 ×{np.exp(c['frequency_days']):.2f}\n= 1표준편차 많으면\n이탈 오즈가 "
                       f"{1 - np.exp(c['frequency_days']):.0%} 줄어듦", fontsize=11.5, color=INK2, va="top", linespacing=1.45,
           transform=b.transAxes)
    b.text(0.07, 0.5, "지역·성별 (참고)", fontsize=12.5, fontweight="bold", color=INK, transform=b.transAxes)
    for i, (k, v) in enumerate(cat.sort_values().items()):
        b.text(0.07, 0.44 - i * 0.045, f"{k.split('_', 1)[1]}  ×{np.exp(v):.2f}", fontsize=10.5, color=INK2, transform=b.transAxes)
    b.text(0.07, 0.025, "연관일 뿐 인과가 아니라\n대응을 다르게 하지 않음", fontsize=10.5, color=MUTED, linespacing=1.4,
           transform=b.transAxes)
    finish(fig, "appx_coefficients", "w4_41_coefficients (r4-1) · 금액·간격 변수는 로그 변환 후 표준화 기준")


def a_cycle_alert():
    """주기 경보 백테스트: 10월 2일 시점으로 돌아가 경보를 계산하고 이후 90일 실제 이탈과 비교"""
    snap = pd.Timestamp("2019-10-02")
    pdy = pdays[pdays["purchase_date"] <= snap].sort_values(["customer_id", "purchase_date"])
    g = pdy.groupby("customer_id")["purchase_date"]
    f = pd.DataFrame({"days": g.size(), "gap": g.apply(lambda s: s.diff().dt.days.mean()), "last": g.max()})
    f["rec"] = (snap - f["last"]).dt.days
    x = vs.merge(f, left_on="customer_id", right_index=True)
    n = len(x)
    x["high"] = x["risk_priority_rank"] <= n / 3
    x["conf"] = (x["days"] >= 3) & (x["rec"] / x["gap"] >= 3) & ~x["high"]
    peer = x[~x["high"] & (x["days"] >= 3)]
    a, b = peer[peer["conf"]], peer[~peer["conf"]]
    p = stats.fisher_exact([[a["actual_churn_flag"].sum(), (1 - a["actual_churn_flag"]).sum()],
                            [b["actual_churn_flag"].sum(), (1 - b["actual_churn_flag"]).sum()]])[1]
    tot = x["actual_churn_flag"].sum()

    def rp(flag):
        tp = (flag & (x["actual_churn_flag"] == 1)).sum()
        return int(flag.sum()), tp / tot, tp / flag.sum()

    r1, r2 = rp(x["high"]), rp(x["high"] | x["conf"])
    caught = int((x["conf"] & (x["actual_churn_flag"] == 1)).sum())
    cur = roster.merge(cu[["customer_id", "purchase_days", "last_day"]], on="customer_id")
    pg = pdays.sort_values(["customer_id", "purchase_date"]).groupby("customer_id")["purchase_date"]
    cur["gap"] = cur["customer_id"].map(pg.apply(lambda s: s.diff().dt.days.mean()))
    cur["rec"] = (END - pd.to_datetime(cur["last_day"])).dt.days
    now = cur[(cur["purchase_days"] >= 3) & (cur["rec"] / cur["gap"] >= 3) & (cur["relative_risk_grade"] != "High")]

    fig = slide("", f"주기 경보: 모델이 놓친 이탈(FN)을 규칙으로 보완해 재현율 {r1[1]:.0%} → {r2[1]:.0%}", "10월 2일 시점에서 계산하고 이후 90일 실제 이탈로 확인")
    fig.text(0.06, 0.7, "모델이 '안전'하다고 본 단골 중 실제 90일 이탈률", fontsize=15, fontweight="bold", color=INK)
    fig.text(0.06, 0.665, "검증 고객 중 위험 Low·Medium이면서 구매한 날 3일 이상인 고객", fontsize=10.5, color=INK2)
    ax = ax_at(fig, [0.09, 0.14, 0.36, 0.48])
    vals = [b["actual_churn_flag"].mean(), a["actual_churn_flag"].mean()]
    ax.bar([0, 1], vals, color=[GRAY, GUARD], width=0.55)
    for i, (v, nn) in enumerate(zip(vals, [len(b), len(a)])):
        ax.text(i, v + 0.02, f"{v:.0%}", ha="center", fontsize=20, fontweight="bold", color=GUARD if i else INK2)
        ax.text(i, 0.04, f"{nn}명", ha="center", fontsize=12, color="white" if i else INK)
    ax.set_xticks([0, 1])
    ax.set_xticklabels(["경보 없음", "주기 경보"], fontsize=14)
    ax.yaxis.set_major_formatter(plt.FuncFormatter(lambda v, _: f"{v:.0%}"))
    ax.set_ylim(0, 1)
    ax.text(0.5, 0.9, f"차이 {vals[1] - vals[0]:+.0%}p · p={p:.2f}", ha="center", fontsize=13, color=INK)

    bd = board(fig, (0.52, 0.12, 0.44, 0.58))
    bd.text(0, 0.97, "검증 고객 1,211명 · 지켜야 할 대상에 경보 고객을 더하면", fontsize=14, fontweight="bold", color=INK,
            va="top", transform=bd.transAxes)
    head = ["", "대상", "재현율", "정밀도"]
    xs = [0.0, 0.55, 0.78, 1.0]
    for k, h in enumerate(head):
        bd.text(xs[k], 0.8, h, fontsize=12, color=MUTED, ha="right" if k else "left", transform=bd.transAxes)
    rows = [("모델 High만", r1, INK2), ("High + 주기 경보", r2, GUARD)]
    for i, (t, (nn, rc, pr), c) in enumerate(rows):
        y = 0.66 - i * 0.15
        card(bd, -0.02, y - 0.06, 1.04, 0.12, color=c if i else LINE, fill=SOFT[GUARD] if i else "white", lw=1.4)
        for k, v in enumerate([t, f"{nn}명", f"{rc:.1%}", f"{pr:.1%}"]):
            bd.text(xs[k], y, v, fontsize=14, fontweight="bold" if i else "normal", color=c, va="center",
                    ha="right" if k else "left", transform=bd.transAxes)
    bd.text(0, 0.3, f"모델이 놓친 실제 이탈 고객 {caught}명을 더 잡고(재현율 +{(r2[1] - r1[1]) * 100:.1f}%p),\n"
                    f"정밀도는 {r1[2]:.1%} → {r2[2]:.1%}로 조금 내려갑니다 (트레이드오프).",
            fontsize=12.5, color=INK, va="top", linespacing=1.6, transform=bd.transAxes)
    bd.text(0, 0.08, esc(f"지금(12월 31일) 경보 대상 {len(now)}명 · 2019년 매출 ${now['revenue_ex_gst'].sum() / 1000:,.0f}K "
                         f"· VIP·Diamond {now['rfmp_tier'].isin(['VIP', 'Diamond']).mean():.0%}\n→ 비싼 대응 전 담당자가 먼저 확인"),
            fontsize=11.5, color=INK2, va="top", linespacing=1.5, transform=bd.transAxes)
    finish(fig, "cycle_alert_fn_backtest", "w4_41_valid_scored, w6_purchase_day · 10월 2일 시점 재계산 · Fisher 정확 검정 · "
                                           "재현율 = 실제 이탈 고객 중 대상에 포함된 비율, 정밀도 = 대상 중 실제 이탈 비율")



def _alert_backtest():
    """10월 2일 시점: 모델 High 여부와 주기 경보 여부, 실제 이탈"""
    snap = pd.Timestamp("2019-10-02")
    pdy = pdays[pdays["purchase_date"] <= snap].sort_values(["customer_id", "purchase_date"])
    g = pdy.groupby("customer_id")["purchase_date"]
    f = pd.DataFrame({"days": g.size(), "gap": g.apply(lambda s: s.diff().dt.days.mean()), "last": g.max()})
    f["rec"] = (snap - f["last"]).dt.days
    x = vs.merge(f, left_on="customer_id", right_index=True)
    x["high"] = x["risk_priority_rank"] <= len(x) / 3
    x["conf"] = (x["days"] >= 3) & (x["rec"] / x["gap"] >= 3) & ~x["high"]
    return x


def a_confusion():
    x = _alert_backtest()
    y = x["actual_churn_flag"] == 1
    fig = slide("", "혼동행렬: 주기 경보를 더하면 놓친 이탈(FN)이 줄고 FP는 조금 늘어납니다", f"검증 고객 {len(x):,}명 · 실제 이탈 {int(y.sum())}명 ({y.mean():.0%})")
    for i, (title, pred, c) in enumerate([("모델 High만", x["high"], INK2),
                                          ("High + 주기 경보", x["high"] | x["conf"], GUARD)]):
        tp, fn = int((pred & y).sum()), int((~pred & y).sum())
        fp, tn = int((pred & ~y).sum()), int((~pred & ~y).sum())
        x0 = 0.08 + i * 0.47
        fig.text(x0, 0.69, title, fontsize=17, fontweight="bold", color=c)
        fig.text(x0, 0.655, f"대상 {tp + fp}명 · 재현율 {tp / (tp + fn):.1%} · 정밀도 {tp / (tp + fp):.1%}",
                 fontsize=12.5, color=INK2)
        ax = board(fig, (x0 + 0.07, 0.1, 0.33, 0.46))
        cells = [(tp, "TP", "이탈을 맞게 고름", GUARD), (fn, "FN", "이탈인데 놓침", BAD),
                 (fp, "FP", "남을 고객을 고름", LEMON), (tn, "TN", "남을 고객을 제외", MINT)]
        for k, (v, tag, d, cc) in enumerate(cells):
            r, col = divmod(k, 2)
            cx, cy = col * 0.5, 0.5 - r * 0.5
            strong = tag in ("TP", "TN")
            ax.add_patch(FancyBboxPatch((cx + 0.01, cy + 0.01), 0.48, 0.48, boxstyle="round,pad=0,rounding_size=0.02",
                                        facecolor=SOFT[cc] if cc in SOFT else "#FDECEF", edgecolor=cc,
                                        lw=1.6 if strong else 1.0, transform=ax.transAxes))
            ax.text(cx + 0.25, cy + 0.33, f"{v:,}명", fontsize=24, fontweight="bold", color=INK, ha="center",
                    va="center", transform=ax.transAxes)
            ax.text(cx + 0.25, cy + 0.17, f"{tag} · {d}", fontsize=11.5, color=INK2, ha="center", va="center",
                    transform=ax.transAxes)
        ax.text(0.25, 1.04, "대상으로 고름", fontsize=12.5, color=INK2, ha="center", transform=ax.transAxes)
        ax.text(0.75, 1.04, "고르지 않음", fontsize=12.5, color=INK2, ha="center", transform=ax.transAxes)
        ax.text(-0.04, 0.75, "실제 이탈", fontsize=12.5, color=INK2, ha="right", va="center", transform=ax.transAxes)
        ax.text(-0.04, 0.25, "실제 유지", fontsize=12.5, color=INK2, ha="right", va="center", transform=ax.transAxes)
    finish(fig, "confusion_matrix", "w4_41_valid_scored, w6_purchase_day · 재현율 = TP ÷ (TP + FN), 정밀도 = TP ÷ (TP + FP) · "
                                    "High = 위험 순위 상위 1/3")



# ====================================================================== 목차 · 팀 소개
AGENDA = [("01", "주제 선정", "왜 이 주제인가 · 붙잡은 질문 세 가지", ACC),
          ("02", "초기 목표", "떠날 고객을 미리 골라 붙잡자 · 이탈의 정의", ACC),
          ("03", "문제제기", "고객이 줄어드는 세 가지 이유", GUARD),
          ("04", "해결과정", "세는 단위 · RFMP · 가치×위험 · 모델 · 로그", GUARD),
          ("05", "목표 변경", "골라내기의 한계 → 두 번째 구매로", LILAC),
          ("06", "선택과 집중", "Nest-USA를 중심에", LILAC),
          ("07", "결론", "두 번째·세 번째 구매로 이탈 낮추기", MINT),
          ("08", "제안 · 제언", "운영 방법과 다음에 필요한 데이터", MINT)]


def _first_page(prefix):
    for i, (sec, _) in enumerate(PLAN, start=1):
        if sec and sec.startswith(prefix):
            return i
    return None


def s_agenda():
    fig = slide("", "목차")
    ax = board(fig, (0.05, 0.07, 0.9, 0.66))
    for k, (no, t, d, c) in enumerate(AGENDA):
        col, row = divmod(k, 4)
        x, y = col * 0.51, 0.77 - row * 0.25
        card(ax, x, y, 0.49, 0.2, color=LINE, fill="white", lw=1.2)
        ax.add_patch(FancyBboxPatch((x, y), 0.008, 0.2, boxstyle="square,pad=0", facecolor=c, edgecolor="none",
                                    transform=ax.transAxes))
        ax.text(x + 0.035, y + 0.1, no, fontsize=26, fontweight="bold", color=c, va="center", transform=ax.transAxes)
        ax.text(x + 0.11, y + 0.13, t, fontsize=18, fontweight="bold", color=INK, va="center", transform=ax.transAxes)
        ax.text(x + 0.11, y + 0.06, esc(d), fontsize=12.5, color=INK2, va="center", transform=ax.transAxes)
        pg = _first_page(no)
        if pg:
            ax.text(x + 0.47, y + 0.1, f"p.{pg}", fontsize=12, color=MUTED, ha="right", va="center", transform=ax.transAxes)
    finish(fig, "agenda")


TEAM = [("박준홍", "총괄 & 분석 설계", ACC,
         ["분석 모형 설계 · RFM 피처 설계", "RFMP 가중치 개발 · 고객가치 분석", "구매일 수 기반 Frequency 검증",
          "K-Means 군집 평가 · 가중치 산출", "이탈 예측 모형 설계 (A/B/C 비교)"]),
        ("이대한", "데이터 & 검증 · 시각화", MINT,
         ["데이터 수집·적재 · 정제·전처리", "Git 연동 · 모델 비교 실험 운영", "진단·검증 파이프라인 · 분석 품질 검증",
          "시각화 · 그래프 편집", "웹 대시보드 구현"])]


def s_team():
    fig = slide("", "팀 소개", "Team CRM Pioneer")
    ax = board(fig, (0.05, 0.07, 0.9, 0.66))
    for i, (name, role, c, tasks) in enumerate(TEAM):
        x, w = 0.04 + i * 0.48, 0.44
        card(ax, x, 0.04, w, 0.9, color=LINE, fill="white", lw=1.2)
        ax.add_patch(FancyBboxPatch((x, 0.915), w, 0.025, boxstyle="square,pad=0", facecolor=c, edgecolor="none",
                                    transform=ax.transAxes))
        ax.scatter([x + 0.075], [0.7], s=5200, color=c, transform=ax.transAxes, zorder=3)     # 정원 (축 비율과 무관)
        ax.text(x + 0.075, 0.7, name[:1], fontsize=30, fontweight="bold", color="white", ha="center", va="center",
                transform=ax.transAxes, zorder=4)
        ax.text(x + 0.16, 0.74, name, fontsize=26, fontweight="bold", color=INK, va="center", transform=ax.transAxes)
        ax.add_patch(FancyBboxPatch((x + 0.16, 0.615), 0.2, 0.06, boxstyle="round,pad=0,rounding_size=0.03",
                                    facecolor=SOFT[c], edgecolor=c, lw=1.2, transform=ax.transAxes))
        ax.text(x + 0.26, 0.645, role, fontsize=13, fontweight="bold", color=c, ha="center", va="center",
                transform=ax.transAxes)
        ax.plot([x + 0.04, x + w - 0.04], [0.53, 0.53], color=LINE, lw=1.2, transform=ax.transAxes)
        ax.text(x + 0.04, 0.47, "주 담당 업무", fontsize=12.5, color=MUTED, fontweight="bold", va="center",
                transform=ax.transAxes)
        for j, t in enumerate(tasks):
            yy = 0.39 - j * 0.075
            ax.scatter([x + 0.05], [yy], s=40, color=c, transform=ax.transAxes)
            ax.text(x + 0.07, yy, t, fontsize=14, color=INK, va="center", transform=ax.transAxes)
    finish(fig, "team")


# ====================================================================== 2기: 교체 장 (웹 2기 실행 플랜과 같은 숫자)
def _rn(*ids):
    return int(sum(RULE_N.get(k, 0) for k in ids))


def s_proposal_v2():
    d = v2()
    S2, E = d["summary"], {e["key"]: e for e in d["experiments"]}
    fig = slide("", "제안: 가치 × 위험으로 고르고, 여정 단계마다 두 번째 구매를 만듭니다",
                f"전체 {len(roster):,}명에게 기본 캠페인 하나 · 대량 주문 고객은 연말 재주문을 함께 · 성과는 보류군 대비 재구매율로")
    ax = board(fig)
    ax.text(0, 0.99, "여정 단계마다 캠페인 하나 · 한 고객에게 한 캠페인", fontsize=14, fontweight="bold", color=INK2, va="top",
            transform=ax.transAxes)
    rows = [("Activation · 신규 온보딩", f"첫 구매 후 {REMIND}: 첫 구매 카테고리 인기·신상품 알림 · 할인 없음", _rn(1), MINT),
            ("Revenue · 고가치 고객 윈백", f"담당자가 직접: 재주문·전담 상담·개별 혜택 · "
                                     f"한 번만 구매 {S2['wb_one']:.0%} · 대량 주문 {S2['wb_bulk']:.0%}", _rn(2, 3), GUARD),
            ("Retention · 자동 재방문 알림", "평소 구매 간격의 1.5배가 지나면 대표 카테고리 재입고·신상품 알림 · 할인 없음", _rn(4, 5, 6), ACC),
            ("유지 · 관계 유지", "위험이 낮은 고객 · 월 1회 뉴스레터 · 할인 없음", _rn(7), MUTED)]
    for i, (t, dsc, n, c) in enumerate(rows):
        y = 0.73 - i * 0.2
        card(ax, 0, y, 0.56, 0.17, color=c, fill=SOFT.get(c, "#F5F6F9"), lw=1.6)
        ax.text(0.025, y + 0.085, f"{i + 1}", fontsize=22, fontweight="bold", color=c, va="center", transform=ax.transAxes)
        ax.text(0.06, y + 0.115, t, fontsize=14, fontweight="bold", color=INK, va="center", transform=ax.transAxes)
        ax.text(0.06, y + 0.045, dsc, fontsize=10.5, color=INK2, va="center", transform=ax.transAxes)
        ax.text(0.545, y + 0.115, f"{n:,}명", fontsize=18, fontweight="bold", color=c, ha="right", va="center",
                transform=ax.transAxes)
    ax.text(0, 0.03, f"시즌 캠페인 · 대량 주문 고객 {d['store']['bulk_n']}명에게 10월 마지막 주 연말 재주문 이메일",
            fontsize=11.5, color=LILAC, fontweight="bold", transform=ax.transAxes)
    card(ax, 0.6, 0.3, 0.4, 0.69, color=LINE, fill="white", lw=1.4)
    ax.text(0.625, 0.92, "무엇으로 확인하나 · 보류군 대비 사업 지표", fontsize=14, fontweight="bold", color=INK, va="center",
            transform=ax.transAxes)
    ax.text(0.975, 0.83, "한 번에 가려낼 효과", fontsize=10.5, color=MUTED, ha="right", va="center", transform=ax.transAxes)
    for i, (k, c) in enumerate([("onboard", MINT), ("guard", GUARD), ("auto", ACC)]):
        e, y = E[k], 0.73 - i * 0.14
        ax.text(0.625, y + 0.02, e["name"], fontsize=12.5, fontweight="bold", color=c, va="center", transform=ax.transAxes)
        ax.text(0.625, y - 0.035, f"기준 {e['base']:.1%} · 한 집단 {e['n_arm']:,}명", fontsize=10.5, color=MUTED, va="center",
                transform=ax.transAxes)
        ax.text(0.975, y, f"+{e['mde'] * 100:.0f}%p 이상", fontsize=13, fontweight="bold", color=c, ha="right", va="center",
                transform=ax.transAxes)
    finish(fig, "proposal", "web_v2 실행 플랜 · w4_44_final_roster 실행 규칙 7개 · w4_41_valid_scored 기준값 · 양측 5% 검정력 80%")


def a_margin_v2():
    vpc = v2()["summary"]["value_per_convert"]
    ups, ms = [0.03, 0.05, 0.10], [(0.2, "#C9D3FD"), (0.3, "#8EA5FB"), (0.4, ACC)]
    fig = slide("", "마진 가정이 바뀌면 온보딩 1인당 예산 상한만 달라집니다",
                f"전환 고객 1명의 90일 매출 ${vpc:,.0f} × 전환율 상승폭 × 마진 · 원가 데이터가 없어 20·30·40%로 계산")
    ax = ax_at(fig, [0.09, 0.14, 0.84, 0.56])
    for k, (m, c) in enumerate(ms):
        xx = np.arange(len(ups)) + (k - 1) * 0.26
        vals = [u * vpc * m for u in ups]
        ax.bar(xx, vals, width=0.24, color=c, label=f"마진 {m:.0%}")
        for xi, u, v in zip(xx, ups, vals):
            web = u == 0.05 and m == 0.3
            ax.text(xi, v + 1.2, esc(f"${v:,.0f}"), ha="center", fontsize=13 if web else 12, color=GUARD if web else INK2,
                    fontweight="bold" if web else "normal")
    ax.set_xticks(range(len(ups)))
    ax.set_xticklabels([f"전환율 +{u * 100:.0f}%p" for u in ups], fontsize=14)
    ax.set_yticks([])
    ax.legend(loc="upper left", fontsize=13)
    ax.text(0.025, 0.66, "주황 = 웹 실행 플랜 기본값", transform=ax.transAxes, ha="left", va="top", fontsize=12, color=GUARD)
    finish(fig, "appx_margin", "w6_uplift (r6-1) · 1인당 상한 = 이 금액까지 써도 늘어난 이익과 같아짐")


# ====================================================================== 2기: 추가 장 (발표자료_주기경보)
def x_aarrr():
    S2 = v2()["summary"]
    fig = slide("", "AARRR로 보면 가장 크게 새는 곳은 두 번째 구매입니다",
                f"북극성 지표 = 첫 구매 후 90일 안 두 번째 구매율 {S2['conv90']:.1%} · CRM은 정착 → 유지 → 수익 → 추천을 맡습니다")
    ax = board(fig, (0.05, 0.1, 0.9, 0.6))
    st = [("A", "Acquisition · 획득", f"{S2['annual_new']:,}명", "2019년 첫 구매 고객",
           f"90일 두 번째 구매율\nNest-USA 시작 {S2['entry_best']:.0%}\nApparel 시작 {S2['entry_apparel']:.0%}", "퍼포먼스 영역", MUTED),
          ("A", "Activation · 정착", f"{S2['conv90']:.1%}", "첫 구매 후 90일 안\n두 번째 구매율",
           f"D+30까지는 {v2()['journey']['c30']:.1%}", "북극성 지표", BAD),
          ("R", "Retention · 유지", f"{S2['m1_ret']:.1%}", "첫 구매 다음 달\n재구매율", f"3개월째 {S2['m3_ret']:.1%}", "개선 대상", MINT),
          ("R", "Revenue · 수익", f"{S2['mkt_ratio']:.0%}", "매출 대비\n마케팅비",
           esc(f"평균 하루 마케팅비 ${S2['spend_day']:,.0f}를\n더 쓴 날 매출 +${S2['rev_per_day']:,.0f}"), "효율 낮음", ACC),
          ("R", "Referral · 추천", "—", "추천으로 들어온\n고객 비율", "추천 코드·공유 이벤트\n수집 필요", "측정 불가", GRAY)]
    w, gap = 0.188, 0.015
    for i, (l, name, val, dfn, cmp_, tag, c) in enumerate(st):
        x, leak = i * (w + gap), i == 1
        card(ax, x, 0.04, w, 0.92, color=BAD if leak else LINE, fill="#FDEDF0" if leak else "white", lw=2.4 if leak else 1.2)
        ax.add_patch(FancyBboxPatch((x + 0.015, 0.83), 0.03, 0.065, boxstyle="round,pad=0,rounding_size=0.008",
                                    facecolor=c, edgecolor="none", transform=ax.transAxes))
        ax.text(x + 0.03, 0.862, l, fontsize=13, fontweight="bold", color="white", ha="center", va="center", transform=ax.transAxes)
        ax.text(x + 0.055, 0.862, name, fontsize=11.5, color=INK2, va="center", transform=ax.transAxes)
        ax.text(x + 0.015, 0.68, esc(val), fontsize=30, fontweight="bold", color=MUTED if c == GRAY else INK, va="center",
                transform=ax.transAxes)
        ax.text(x + 0.015, 0.52, dfn, fontsize=12, color=INK, va="center", linespacing=1.4, transform=ax.transAxes)
        ax.text(x + 0.015, 0.33, cmp_, fontsize=10.5, color=INK2, va="center", linespacing=1.4, transform=ax.transAxes)
        ax.text(x + 0.015, 0.12, tag, fontsize=11.5, fontweight="bold", color=BAD if leak else (MUTED if c == GRAY else c),
                va="center", transform=ax.transAxes)
    finish(fig, "v2_1_aarrr", "web_v2 Executive 요약 · w6_conv_base, w5_cohort_retention, w6_ltv_margin, w6_conv_segments")


def x_vanity():
    d = v2()
    V = d["vanity"]
    best, low = V["conv"][0], V["conv"][-1]
    fig = slide("", "월 매출은 크기만 보여 주고, 첫 구매 카테고리는 할 일을 알려 줍니다",
                "Vanity = 커 보이지만 할 일을 알려 주지 않는 숫자 · Actionable = 바꾸면 결과가 달라지는 숫자")
    for x0, tag, title, c in [(0.07, "Vanity", "월 매출", MUTED), (0.55, "Actionable", "첫 구매 카테고리별 90일 두 번째 구매율", MINT)]:
        fig.text(x0, 0.7, tag, fontsize=12, fontweight="bold", color=c)
        fig.text(x0, 0.665, title, fontsize=15, fontweight="bold", color=INK)
    a1 = ax_at(fig, [0.08, 0.14, 0.38, 0.48])
    xs = np.arange(len(V["labels"]))
    a1.plot(xs, V["rev"], color="#B7BECC", lw=3)
    a1.fill_between(xs, V["rev"], color="#B7BECC", alpha=0.15)
    top = int(np.argmax(V["rev"]))
    a1.scatter([top], [V["rev"][top]], s=70, color=INK2, zorder=3)
    a1.text(top, V["rev"][top] + 25, esc(f"${V['rev'][top]:,.0f}K"), ha="center", fontsize=12, fontweight="bold", color=INK2)
    a1.set_xticks(xs[::2])
    a1.set_xticklabels(V["labels"][::2])
    a1.set_ylim(0, max(V["rev"]) * 1.25)
    a1.yaxis.set_major_formatter(plt.FuncFormatter(lambda v, _: esc(f"${v:,.0f}K")))
    a2 = ax_at(fig, [0.56, 0.14, 0.38, 0.48])
    conv = V["conv"]
    a2.bar(range(len(conv)), [c["rate"] for c in conv], color=MINT, width=0.6,
           yerr=[c["ci"] for c in conv], ecolor=INK2, capsize=4)
    for k, c in enumerate(conv):
        if c is best or c is low:
            a2.text(k, c["rate"] + c["ci"] + 0.02, f"{c['rate']:.0%}", ha="center", fontsize=13, fontweight="bold", color=INK)
    a2.set_xticks(range(len(conv)))
    a2.set_xticklabels([c["m"] for c in conv], fontsize=11)
    a2.set_ylim(0, 0.6)
    a2.yaxis.set_major_formatter(plt.FuncFormatter(lambda v, _: f"{v:.0%}"))
    finish(fig, "v2_2_vanity", "web_v2 Executive 요약 · w6_monthly_kpi, w6_conv_segments 첫 구매 대표 카테고리 · 고객 30명 이상 · 오차막대 = 95% 구간")


def x_journey():
    J = v2()["journey"]
    lost = J["steps"][0] - J["steps"][1]
    fig = slide("", "첫 주가 지나면 재구매는 매주 2% 안팎이라, 리마인드를 D+7·D+30으로 앞당깁니다",
                f"첫 구매 고객 {J['n']:,}명을 똑같이 180일씩 관측 · 1회 → 2회 구매에서 {lost}명으로 가장 많이 빠집니다")
    fig.text(0.07, 0.68, "구매 단계 퍼널 · 180일", fontsize=15, fontweight="bold", color=INK)
    a1 = ax_at(fig, [0.12, 0.14, 0.33, 0.5], grid=None)
    steps = J["steps"][::-1]
    a1.barh(range(len(steps)), steps, color=[ACC] * 3 + [BAD] + [ACC], height=0.62)
    for k, n in enumerate(steps):
        i = len(steps) - 1 - k
        rate = "" if i == 0 else f" · {J['step_rate'][i]:.0%}"
        a1.text(n + 15, k, f"{n:,}명{rate}", va="center", fontsize=12, color=INK2)
    a1.set_yticks(range(len(steps)))
    a1.set_yticklabels([f"{len(steps) - k}회 구매" for k in range(len(steps))], fontsize=12)
    a1.set_xticks([])
    a1.set_xlim(0, J["steps"][0] * 1.35)
    fig.text(0.53, 0.68, "주별 두 번째 구매 확률 · 점선 = 리마인드", fontsize=15, fontweight="bold", color=INK)
    a2 = ax_at(fig, [0.54, 0.14, 0.41, 0.5])
    wk = J["weekly"]
    a2.bar(range(len(wk)), wk, color=[MINT] + [ACC] * (len(wk) - 1), width=0.62)
    for dday in (7, 30):
        xpos = dday / 7 - 0.5
        a2.axvline(xpos, color=GUARD, ls="--", lw=1.6)
        a2.text(xpos + 0.15, max(wk) * 0.95, f"D+{dday}", color=GUARD, fontsize=12, fontweight="bold")
    a2.set_xticks(range(0, len(wk), 2))
    a2.set_xticklabels([f"{k + 1}주" for k in range(0, len(wk), 2)])
    a2.yaxis.set_major_formatter(plt.FuncFormatter(lambda v, _: f"{v:.0%}"))
    finish(fig, "v2_3_journey", "web_v2 여정·퍼널 · w6_purchase_day · 첫 구매가 7/4 이전인 고객")


def x_playbook():
    d = v2()
    S2, E, st = d["summary"], {e["key"]: e for e in d["experiments"]}, d["store"]
    fig = slide("", "캠페인 플레이북: 여정 단계마다 대상 · 시점 · 채널 · 메시지를 정했습니다",
                f"Nest 기기 매출 {st['nest_rev']:.0%} · 대량 주문 고객 매출 {st['bulk_rev']:.0%} · 11~12월 +{st['q4_lift']:.0%} · "
                f"쿠폰 사용 여부별 금액 차이 거의 없음")
    ax = board(fig, (0.05, 0.1, 0.9, 0.63))
    cols = [(0.0, "캠페인"), (0.17, "대상"), (0.34, "보내는 때"), (0.5, "채널"), (0.64, "메시지"), (0.85, "성공 지표")]
    for x, h in cols:
        ax.text(x + 0.01, 0.96, h, fontsize=12, fontweight="bold", color=MUTED, va="center", transform=ax.transAxes)
    rows = [("신규 온보딩", "Activation", MINT, f"90일 미만 신규\n{_rn(1)}명", "첫 구매\nD+7, D+30", "이메일 + 앱 푸시",
             "첫 구매 카테고리\n인기·신상품", f"90일 두 번째\n구매율 {S2['conv90']:.1%}"),
            ("고가치 고객 윈백", "Revenue", GUARD, f"가치 상위 · 위험 High\n{_rn(2, 3)}명", "위험 High\n진입 즉시", "담당자\n이메일·전화",
             "대량 주문: 재주문·전담 상담\n그 외: 첫 구매 카테고리 신상품", f"90일 재구매율\n{E['guard']['base']:.1%}"),
            ("자동 재방문 알림", "Retention", ACC, f"위험 High·Medium\n{_rn(4, 5, 6)}명", "평소 구매 간격\n1.5배 경과", "앱 푸시·이메일\n자동",
             "대표 카테고리\n재입고·신상품", f"90일 재구매율\n{E['auto']['base']:.1%}"),
            ("연말 재주문", "Revenue · 시즌", LILAC, f"대량 주문 고객\n{st['bulk_n']}명", "10월\n마지막 주", "담당자 이름의\n이메일",
             "지난 주문 그대로 재주문\n연말 단체 선물 카탈로그", "4분기\n재주문율"),
            ("관계 유지", "유지", MUTED, f"위험 Low\n{_rn(7)}명", "월 1회", "뉴스레터", "신상품 소식\n할인 없음", "수신 거부율")]
    for i, (name, stage, c, *cells) in enumerate(rows):
        y = 0.82 - i * 0.18
        ax.add_patch(FancyBboxPatch((0, y - 0.075), 1, 0.15, boxstyle="round,pad=0,rounding_size=0.01",
                                    facecolor=SOFT.get(c, "#F5F6F9"), edgecolor="none", transform=ax.transAxes))
        ax.add_patch(FancyBboxPatch((0, y - 0.075), 0.006, 0.15, boxstyle="square,pad=0", facecolor=c, edgecolor="none",
                                    transform=ax.transAxes))
        ax.text(0.02, y + 0.022, name, fontsize=13, fontweight="bold", color=INK, va="center", transform=ax.transAxes)
        ax.text(0.02, y - 0.032, stage, fontsize=10.5, fontweight="bold", color=c, va="center", transform=ax.transAxes)
        for (x, _), txt in zip(cols[1:], cells):
            ax.text(x + 0.01, y, txt, fontsize=10.5, color=INK, va="center", linespacing=1.35, transform=ax.transAxes)
    finish(fig, "v2_4_playbook", "web_v2 실행 플랜 · w4_44_final_roster 실행 규칙 7개 · w4_41_valid_scored 기준값")


# 발표 순서: (섹션 표시, 함수)
PLAN = [
    (None, s_title),
    ("CONTENTS", s_agenda),
    ("TEAM", s_team),
    ("01  주제 선정", s_topic),
    ("02  초기 목표", s_initial_goal),
    ("03  문제제기", s_problem),
    ("04  해결과정", s_unit_compare),
    ("04  해결과정", s_segments),
    ("04  해결과정", s_rfmp),
    ("04  해결과정", s_value_risk),
    ("04  해결과정", s_models2),
    ("04  해결과정", a_log_transform),
    ("05  목표 변경", s_goal_shift2),
    ("06  선택과 집중", s_nest),
    ("07  결론", s_findings2),
    ("08  제안", s_proposal2),
    ("08  제언", s_next_data),
    (None, s_closing),
    (None, s_thanks),
    ("부록 A1 · 90일 기준", a_90_survivor),
    ("부록 A2 · 90일 기준", a_90_robust),
    ("부록 A3 · 데이터", s_tables),
    ("부록 A4 · 개인 예측", s_cannot_pick),
    ("부록 A5 · 시범 설계", a_trials),
    ("부록 A6 · 모델 비교", a_model_table),
    ("부록 A7 · 마진 가정", a_margin),
]

# Git Flow 협업 과정: 팀 저장소의 브랜치·PR 기록을 그대로 옮긴 그림 (x = 작업 순서, 단위 없음)
GF_LANES = [("main", "#D4860B"), ("hotfix/*", "#E0245E"), ("release/*", "#E0A11B"), ("dev", "#F06A1D"),
            ("feature/w1-data-cleansing", "#12A089"), ("feature/w1-rfm-base", "#8B3FE0"), ("feature/w2-rfm-cluster", "#0E97B0"),
            ("feature/w2-churn-model", "#2D6BE4"), ("experiment/w2-frequency-abc", "#E0306E"), ("feature/w2-rfmp-v2", "#0E9E6E"),
            ("feature/w3-risk-scoring", "#5B3FE0"), ("feature/w3-action-design", "#6DAA1E")]
# (레인, 갈라진 dev 위치, 커밋 위치, 합친 dev 위치, [(산출물 x, 이름, 줄)])
GF_FEATURES = [
    (4, 178, [198, 218, 238, 257, 277, 297, 317, 335], 352, [(236, "order_key", 0), (330, "CLEAN_ONLINE", 0)]),
    (5, 352, [370, 390, 410, 430, 450, 470, 490], 506, [(410, "W2_ORDER_BASE", 0), (410, "W2_RFM", 1), (565, "W2_CUSTOMER_FEATURES", 0)]),
    (6, 563, [582, 640, 697], 736, [(615, "W3_MODEL_INPUT", 0)]),
    (7, 563, [600, 620, 640, 660, 680, 700], 755, [(660, "W3_CHURN_SPLIT_V2", 0)]),
    (8, 755, [775, 795, 813, 832, 852, 870], 888, [(815, "W3_FREQ_ABC_INPUT", 0), (878, "W3_FREQUENCY_POLICY", 1)]),
    (9, 888, [908, 928, 948, 968, 988, 1008, 1025], 1043,
     [(940, "W3_RFMP_BASE_PY", 0), (960, "W3_CUSTOMER_RFMP_PY", 1), (975, "W3_CUSTOMER_ANALYTIC_BASE_PY", 2)]),
    (10, 1100, [1120, 1140, 1158], 1177, [(1210, "W4_41_CURRENT_SCORED", 0)]),
    (11, 1177, [1195, 1215, 1235, 1255, 1275, 1295, 1312], 1330,
     [(1265, "W4_42_CUSTOMER_ACTION", 0), (1280, "W4_43_DECISION", 1), (1310, "W4_44_FINAL_ROSTER", 2)]),
]
GF_MERGES = [(352, "#1"), (506, "#2"), (736, "#3"), (755, "#4"), (888, "#5"), (1043, "#6"), (1177, "#7"), (1330, "#8")]
GF_RELEASES = [(506, 524, 543, "v1.0.0", 563), (1043, 1062, 1080, "v2.0.0", 1100), (1330, 1349, 1367, "v3.0.0", 1387),
               (1485, 1503, 1520, "v3.1.0", None)]
GF_WEEKS = [(150, 572, "Week 1 · r1-1 · r2-2 데이터 정제 · RFM"), (572, 1110, "Week 2 · r3-1 군집 · 이탈모형 · Frequency · RFM-P"),
            (1110, 1535, "Week 3 · r4-1 인사이트 · hotfix · 배포")]


def s_gitflow():
    fig = slide("", "Git Flow를 활용한 협업 과정", "브랜치 12개 · 커밋 72개 · PR 8건 · 릴리스 태그 5개")
    ax = fig.add_axes((0.035, 0.1, 0.93, 0.66))
    ax.set_xlim(0, 1560)
    ax.set_ylim(12.7, -1.9)
    ax.axis("off")
    X = lambda x: 285 + (x - 150) * 0.915                         # 왼쪽 285 까지는 레인 이름 칸
    lab = {"fontfamily": ["Segoe UI", "Malgun Gothic"], "style": "italic", "fontsize": 7, "fontweight": "bold"}

    def curve(x0, y0, x1, y1, color, dashed=False, lw=1.6, alpha=1.0):
        t = np.linspace(0, 1, 40)
        e = t * t * (3 - 2 * t)                                   # 양 끝이 수평인 S자
        ax.plot(X(x0) + (X(x1) - X(x0)) * t, y0 + (y1 - y0) * e, color=color, lw=lw, ls=(0, (4, 3)) if dashed else "-",
                alpha=alpha, solid_capstyle="round", zorder=2)

    def dot(x, y, color, hollow=False, size=24):
        ax.scatter([X(x)], [y], s=size, color="white" if hollow else color, edgecolors=color, linewidths=1.5, zorder=4)

    def hline(x0, x1, y, color):
        ax.plot([X(x0), X(x1)], [y, y], color=color, lw=1.8, zorder=2)

    for x0, x1, name in GF_WEEKS:
        if "Week 2" in name:
            ax.add_patch(plt.Rectangle((X(x0), -1.2), X(x1) - X(x0), 13.6, facecolor="#F3F5FA", edgecolor="none", zorder=0))
        ax.text((X(x0) + X(x1)) / 2, -1.55, name, ha="center", va="center", fontsize=10.5, fontweight="bold", color="#0E97B0")
    for i, (name, c) in enumerate(GF_LANES):
        ax.plot([X(150), X(1535)], [i, i], color=LINE, lw=0.7, ls=(0, (1, 3)), zorder=1)
        ax.scatter([12], [i], s=22, color=c, zorder=3)
        ax.text(28, i, name, va="center", fontsize=9.5, color=INK2)
    main, hot, rel, dev = 0, 1, 2, 3
    c = dict(enumerate(c for _, c in GF_LANES))
    hline(160, 1520, main, c[main])
    hline(178, 1485, dev, c[dev])
    curve(160, main, 178, dev, c[dev])
    dot(160, main, c[main])
    dot(178, dev, c[dev])
    for lane, start, commits, merge, arts in GF_FEATURES:
        curve(start, dev, commits[0], lane, c[lane])
        hline(commits[0], commits[-1], lane, c[lane])
        curve(commits[-1], lane, merge, dev, c[lane], dashed=True)
        for x in commits:
            dot(x, lane, c[lane])
        for x, name, row in arts:                                  # 원본 그림과 같은 위치·줄
            ax.text(X(x), lane + 0.33 + row * 0.24, name, ha="center", va="center", color=c[lane], **lab)
    curve(1120, 10, 1195, 11.6, c[hot], dashed=True, lw=1.2, alpha=0.7)          # 위험 점수 → 실행 설계 입력
    for k, (x, pr) in enumerate(GF_MERGES):
        dot(x, dev, c[dev], hollow=True)
        dx = {"#3": -7, "#4": 7}.get(pr, 0)
        ax.text(X(x) + dx, dev - 0.28, pr, ha="center", va="bottom", fontsize=8, color=MUTED, fontweight="bold")
    for d, r, m, tag, back in GF_RELEASES:
        curve(d, dev, r, rel, c[rel], dashed=True)
        curve(r, rel, m, main, c[rel], dashed=True)
        dot(r, rel, c[rel], hollow=True)
        dot(m, main, c[main], hollow=True)
        ax.text(X(m), main - 0.28, tag, ha="center", va="bottom", fontsize=8.5, color=c[main], fontweight="bold")
        if back:
            curve(r, rel, back, dev, c[rel], dashed=True)
            dot(back, dev, c[dev], hollow=True)
    curve(1367, main, 1407, hot, c[hot])
    dot(1407, hot, c[hot])
    curve(1407, hot, 1425, main, c[hot], dashed=True)
    curve(1407, hot, 1445, dev, c[hot], dashed=True)
    dot(1425, main, c[main], hollow=True)
    ax.text(X(1425), main - 0.28, "v3.0.1", ha="center", va="bottom", fontsize=8.5, color=c[main], fontweight="bold")
    dot(1445, dev, c[dev], hollow=True)
    for x in (1465, 1485):
        dot(x, dev, c[dev])
    ax.text(X(1468), dev + 0.33, "PDF 4종", ha="center", va="center", color=c[dev], **lab)
    fig.text(0.05, 0.075, "기울인 글자 = 해당 커밋에서 만들어져 다음 단계의 입력·조인 키로 쓰이는 핵심 산출물",
             fontsize=11.5, color=INK2, style="italic", va="center")
    finish(fig, "03b_gitflow_collaboration", "팀 GitHub 저장소 브랜치·PR·태그 기록")


EXTRA = {"alert": ("추가 · 주기 경보", a_cycle_alert), "cm": ("추가 · 혼동행렬", a_confusion),
         "gitflow": ("TEAM · 협업", s_gitflow, OUT),
         "v2_aarrr": ("추가 · 2기 AARRR", x_aarrr), "v2_vanity": ("추가 · 2기 지표", x_vanity),
         "v2_journey": ("추가 · 2기 여정·퍼널", x_journey), "v2_playbook": ("추가 · 2기 실행 플랜", x_playbook)}
# 2기 덱: 1기 덱에서 세 장만 2기 내용으로 교체 (10 가치×위험은 같은 함수가 2기 기준으로 그림)
PLAN_V2 = [(sec, {s_problem: s_problem_v2, s_proposal2: s_proposal_v2, a_margin: a_margin_v2}.get(fn, fn)) for sec, fn in PLAN]
# 2기: 위험 점수를 만드는 모델을 먼저 고른 뒤 가치와 겹친다 → 모델 비교(해결 ③)를 가치 × 위험(해결 ④) 앞으로
_i, _j = [k for k, (_, fn) in enumerate(PLAN_V2) if fn in (s_value_risk, s_models2)]
PLAN_V2[_i], PLAN_V2[_j] = PLAN_V2[_j], PLAN_V2[_i]

if __name__ == "__main__" and sys.argv[1:] and sys.argv[1:] != ["v2"]:
    EXTRA_OUT.mkdir(exist_ok=True)
    STATE["extra"] = True
    for key in sys.argv[1:]:
        STATE["sec"], fn, *out = EXTRA[key]
        STATE["extra_out"] = out[0] if out else EXTRA_OUT
        fn()
elif __name__ == "__main__":
    plan = PLAN
    if sys.argv[1:] == ["v2"]:
        use_v2()                                     # OUT -> 발표자료_2기, 고가치 위험 고객 기준
        plan = PLAN_V2
    for f in OUT.glob("[0-9][0-9]_*.png"):        # 번호 슬라이드만 지움 (03b_gitflow 같은 추가 장은 유지)
        f.unlink()
    STATE["pdf"] = PdfPages(OUT / "CP_발표자료.pdf")
    for sec, fn in plan:
        STATE["sec"] = sec
        fn()
    STATE["pdf"].close()
    print(f"-> CP_발표자료.pdf ({STATE['no']}장)")
