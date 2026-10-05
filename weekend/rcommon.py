"""weekend/r1-1.sas, r2-2.sas 를 Python으로 옮기면서 공통으로 쓰는 도구 모음.

경로 대응 (SAS OnDemand -> 현재 VSCode 작업 폴더)
  %let CSV_DIR=/home/student/J.H._Project/Dataset_csv  -> crm_pj/open        (CSV_DIR)
  libname crm "/home/student/crm_db"                   -> crm_pj/weekend/crm_db (CRM_DIR, .pkl)
  원본 코드가 그리는 분석 과정 그래프(SAS.pyplot)        -> crm_pj/weekend/pipeline_plots (PIPE_PLOT_DIR)
  발표 자료                                             -> crm_pj/발표자료 (weekend/r8_presentation.py)

SAS PROC -> Python 대응
  proc contents varnum  -> proc_contents()
  proc freq             -> proc_freq(), proc_freq_cross()
  proc means            -> proc_means()
  proc print            -> proc_print()
  title "..."           -> title()
  위 함수들은 콘솔 출력과 함께 png=이름 을 주면 SAS 결과창(HTMLBlue 스타일) 모양의
  표 이미지를 rplots/sas/ 에 저장한다.
"""

import re
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd


# ---------------------------------------------------------------- 경로
WEEKEND_DIR = Path(__file__).resolve().parent
CSV_DIR = WEEKEND_DIR.parent / "open"        # SAS: /home/student/J.H._Project/Dataset_csv
CRM_DIR = WEEKEND_DIR / "crm_db"             # SAS: libname crm "/home/student/crm_db"
PIPE_PLOT_DIR = WEEKEND_DIR / "pipeline_plots"   # 원본 코드(SAS.pyplot, proc python)가 그리는 분석 과정 그래프
SAS_PLOT_DIR = PIPE_PLOT_DIR / "sas"              # SAS 결과창 스타일 표 PNG (SAS_TABLE_PNG=True 일 때만)
# SAS 결과창(PDF 출력) 모양의 표 PNG 는 기본으로 만들지 않는다. 같은 내용은 r5_viz_data.py 의
# Viya 데이터 점검 리포트(rplots/0_data_viya)로 본다. 필요하면 True 로 바꾸면 rplots/sas 에 다시 저장된다.
SAS_TABLE_PNG = False
CRM_DIR.mkdir(parents=True, exist_ok=True)

pd.set_option("display.width", 220)
pd.set_option("display.max_columns", 60)
pd.set_option("display.max_rows", 200)
pd.set_option("display.float_format",
              lambda x: f"{x:,.0f}" if float(x).is_integer() else f"{x:,.4f}")

plt.rcParams["font.family"] = "Malgun Gothic"
plt.rcParams["axes.unicode_minus"] = False


# ---------------------------------------------------------------- 라이브러리(crm.*)
def save(df, name):
    """data crm.<name>; ... run;"""
    df.to_pickle(CRM_DIR / f"{name}.pkl")


def load(name):
    """set crm.<name>;"""
    path = CRM_DIR / f"{name}.pkl"
    if not path.exists():
        raise FileNotFoundError(
            f"crm.{name} 이 없습니다. 앞 단계 스크립트(r1-1.py -> r2-2.py)를 먼저 실행하세요."
        )
    return pd.read_pickle(path)


def delete(*names):
    """proc datasets library=crm nolist nowarn; delete ...; quit;"""
    for name in names:
        (CRM_DIR / f"{name}.pkl").unlink(missing_ok=True)


class SASBridge:
    """PROC PYTHON 안의 SAS 객체 대체.

    SAS.sd2df("crm.x")          -> crm_db/x.pkl 로드
    SAS.df2sd(df, dataset=...)  -> crm.x 는 crm_db/x.pkl 저장, work.x 는 메모리 WORK
    SAS.symget("NAME")          -> %let 매크로 변수 (MACROS 딕셔너리)
    SAS.pyplot(plt)             -> rplots/<prefix>_NN.png 로 현재 그림 저장
    """

    def __init__(self, macros=None, plot_prefix="sas_pyplot"):
        self.macros = dict(macros or {})
        self.work = {}
        self.plot_prefix = plot_prefix
        self._plot_no = 0

    @staticmethod
    def _split(dataset):
        lib, _, name = str(dataset).strip().lower().rpartition(".")
        return (lib or "work"), name

    def sd2df(self, dataset):
        lib, name = self._split(dataset)
        if lib == "work":
            return self.work[name].copy()
        return load(name)

    def df2sd(self, df, dataset=None, table=None, libref=None):
        if dataset is None:
            dataset = f"{libref or 'work'}.{table}"
        lib, name = self._split(dataset)
        if lib == "work":
            self.work[name] = df.copy()
        else:
            save(df, name)
        print(f"NOTE: {lib.upper()}.{name.upper()} 저장 ({len(df):,}행, {df.shape[1]}열)")

    def symget(self, name):
        return str(self.macros[name])

    def symput(self, name, value):
        self.macros[name] = value

    def pyplot(self, plt_module):
        self._plot_no += 1
        PIPE_PLOT_DIR.mkdir(exist_ok=True)
        out = PIPE_PLOT_DIR / f"{self.plot_prefix}_{self._plot_no:02d}.png"
        plt_module.gcf().savefig(out, dpi=150, bbox_inches="tight")
        print(f"-> SAS.pyplot 그래프 저장: {out.name}")


def exists(name):
    """%sysfunc(exist(crm.<name>))"""
    return (CRM_DIR / f"{name}.pkl").exists()


def nobs(name):
    """%sysfunc(attrn(open(crm.<name>), nobs)) - 없으면 0"""
    return len(load(name)) if exists(name) else 0


def require_table(name, previous_step):
    """%require_table(ds=crm.<name>, previous_step=...)"""
    if not exists(name):
        raise SystemExit(f"ERROR: 필수 입력 테이블 crm.{name} 이(가) 없습니다. "
                         f"{previous_step} 단계를 먼저 정상 실행하십시오.")
    print(f"NOTE: 입력 테이블 crm.{name} 을(를) 확인했습니다.")


def abort(msg):
    """%put ERROR: ...; %abort cancel;"""
    raise SystemExit(f"ERROR: {msg}")


def is_missing(s):
    """SAS missing(): 숫자는 NaN, 문자는 NaN 또는 빈 문자열"""
    if pd.api.types.is_numeric_dtype(s) or pd.api.types.is_datetime64_any_dtype(s):
        return s.isna()
    return s.isna() | (s.astype("string").str.strip() == "")


def pctl(s, p):
    """SAS 기본 백분위수 정의(PCTLDEF=5)"""
    s = pd.Series(s).dropna()
    if s.empty:
        return np.nan
    return float(np.percentile(s, p, method="averaged_inverted_cdf"))


# ---------------------------------------------------------------- 콘솔 출력
def title(text):
    print("\n" + "=" * 80)
    print(text)
    print("=" * 80)


def note(*lines):
    """data _null_; put ...; run;"""
    print("=" * 54)
    for line in lines:
        print(f"NOTE: {line}")
    print("=" * 54)


# ---------------------------------------------------------------- SAS 결과창 스타일 PNG
SAS_HEADER_BG = "#EDF2F9"
SAS_HEADER_INK = "#112277"
SAS_BORDER = "#C1C1C1"
SAS_BAR = "#6F7EB3"
SAS_BAR_EDGE = "#2F3E6B"


def _slug(text):
    return re.sub(r"[^\w\-]+", "_", text).strip("_")


def _disp_len(text):
    """한글은 영문 약 1.8자 폭"""
    return sum(1.8 if ord(ch) > 0x2E80 else 1.0 for ch in str(text))


def _fmt(v, dec=2):
    if v is None or (isinstance(v, float) and np.isnan(v)) or v is pd.NaT:
        return "."
    if isinstance(v, pd.Timestamp):
        return v.strftime("%Y-%m-%d")
    if isinstance(v, (bool, np.bool_)):
        return str(int(v))
    if isinstance(v, (int, np.integer)):
        return f"{v:,}"
    if isinstance(v, (float, np.floating)):
        if float(v).is_integer() and abs(v) < 1e15:
            return f"{int(v):,}"
        return f"{v:,.{dec}f}"
    try:
        if pd.isna(v):
            return "."
    except (TypeError, ValueError):
        pass
    return str(v)


def sas_table_png(df, title_text, png, dec=2, subtitle=None, max_rows=60):
    """DataFrame 을 SAS 결과창(HTMLBlue) 모양 표 이미지로 저장"""
    if png is None or not SAS_TABLE_PNG:
        return
    SAS_PLOT_DIR.mkdir(parents=True, exist_ok=True)
    df = df.head(max_rows)
    header = [str(c) for c in df.columns]
    body = [[_fmt(v, dec) for v in row] for row in df.itertuples(index=False)]
    numeric = [pd.api.types.is_numeric_dtype(df[c]) for c in df.columns]

    widths = []
    for j, h in enumerate(header):
        cells = [body[i][j] for i in range(len(body))]
        widths.append(max([_disp_len(h)] + [_disp_len(c) for c in cells]) * 0.095 + 0.35)
    fig_w = max(4.5, sum(widths) + 0.4)
    row_h = 0.27
    top = 0.75 + (0.25 if subtitle else 0)
    fig_h = top + row_h * (len(body) + 1) + 0.25

    fig = plt.figure(figsize=(fig_w, fig_h), facecolor="white")
    fig.text(0.5, 1 - 0.28 / fig_h, title_text, ha="center", va="top",
             fontsize=12, fontweight="bold", color=SAS_HEADER_INK)
    if subtitle:
        fig.text(0.5, 1 - 0.58 / fig_h, subtitle, ha="center", va="top",
                 fontsize=9, color="#333333")

    table_h = row_h * (len(body) + 1) / fig_h
    table_w = sum(widths) / fig_w
    ax = fig.add_axes([(1 - table_w) / 2, 0.2 / fig_h, table_w, table_h])
    ax.axis("off")
    tbl = ax.table(cellText=body if body else [["" for _ in header]], colLabels=header,
                   colWidths=[w / sum(widths) for w in widths], loc="upper center",
                   bbox=[0, 0, 1, 1])
    tbl.auto_set_font_size(False)
    tbl.set_fontsize(8.5)
    for (r, c), cell in tbl.get_celld().items():
        cell.set_edgecolor(SAS_BORDER)
        cell.set_linewidth(0.6)
        if r == 0:
            cell.set_facecolor(SAS_HEADER_BG)
            cell.get_text().set_color(SAS_HEADER_INK)
            cell.get_text().set_fontweight("bold")
            cell.get_text().set_ha("center")
        else:
            cell.set_facecolor("white")
            cell.get_text().set_color("black")
            cell.get_text().set_ha("right" if numeric[c] else "left")
            cell.PAD = 0.04
    out = SAS_PLOT_DIR / f"{_slug(png)}.png"
    fig.savefig(out, dpi=150, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"-> SAS 스타일 표 저장: {out.name}")


def sas_bar_png(labels, values, title_text, png, xlabel="", ylabel="빈도", horizontal=False,
                ylim=None, datalabel=False, fmt="{:,.4g}"):
    """proc freq plots=freqplot 모양의 막대그래프"""
    if not SAS_TABLE_PNG:
        return
    SAS_PLOT_DIR.mkdir(parents=True, exist_ok=True)
    labels = [str(x) for x in labels]
    n = len(labels)
    if horizontal:
        fig, ax = plt.subplots(figsize=(7.5, max(3, 0.3 * n + 1.2)), facecolor="white")
        ax.barh(range(n)[::-1], values, color=SAS_BAR, edgecolor=SAS_BAR_EDGE, linewidth=0.8)
        ax.set_yticks(range(n)[::-1])
        ax.set_yticklabels(labels)
        ax.set_xlabel(ylabel)
        ax.set_ylabel(xlabel)
        ax.grid(axis="x", color="#E6E6E6")
    else:
        fig, ax = plt.subplots(figsize=(max(5, 0.45 * n + 2), 4.2), facecolor="white")
        ax.bar(range(n), values, color=SAS_BAR, edgecolor=SAS_BAR_EDGE, linewidth=0.8, width=0.7)
        ax.set_xticks(range(n))
        ax.set_xticklabels(labels, rotation=45 if n > 6 else 0, ha="right" if n > 6 else "center")
        ax.set_xlabel(xlabel)
        ax.set_ylabel(ylabel)
        ax.grid(axis="y", color="#E6E6E6")
        if ylim:
            ax.set_ylim(*ylim)
        if datalabel:
            for i, v in enumerate(values):
                ax.text(i, v, fmt.format(v), ha="center", va="bottom", fontsize=9)
    ax.set_axisbelow(True)
    ax.set_facecolor("#FAFBFE")
    for sp in ax.spines.values():
        sp.set_color("#A0A0A0")
    ax.set_title(title_text, fontsize=11, fontweight="bold", color=SAS_HEADER_INK)
    out = SAS_PLOT_DIR / f"{_slug(png)}.png"
    fig.tight_layout()
    fig.savefig(out, dpi=150, facecolor="white")
    plt.close(fig)
    print(f"-> SAS 스타일 그래프 저장: {out.name}")


def sas_roc_png(roc, title_text, png):
    """proc sgplot series FPR/TPR + lineparm 대각선"""
    if not SAS_TABLE_PNG:
        return
    SAS_PLOT_DIR.mkdir(parents=True, exist_ok=True)
    fig, ax = plt.subplots(figsize=(6.4, 6), facecolor="white")
    ax.plot(roc["false_positive_rate"], roc["true_positive_rate"], color="blue", lw=2)
    ax.plot([0, 1], [0, 1], color="gray", ls="--", lw=1)
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.set_xlabel("False Positive Rate")
    ax.set_ylabel("True Positive Rate")
    ax.grid(color="#E6E6E6")
    ax.set_facecolor("#FAFBFE")
    ax.set_title(title_text, fontsize=11, fontweight="bold", color=SAS_HEADER_INK)
    out = SAS_PLOT_DIR / f"{_slug(png)}.png"
    fig.tight_layout()
    fig.savefig(out, dpi=150, facecolor="white")
    plt.close(fig)
    print(f"-> SAS 스타일 그래프 저장: {out.name}")


# ---------------------------------------------------------------- PROC 대응
def proc_print(df, title_text=None, obs=None, var=None, png=None, dec=2):
    """title; proc print data=...(obs=) noobs label; var ...; run;"""
    out = df if var is None else df[var]
    if obs is not None:
        out = out.head(obs)
    if title_text:
        title(title_text)
    if len(out) == 0:
        print("NOTE: No observations were selected.")
    else:
        print(out.to_string(index=False))
    sas_table_png(out, title_text or "", png, dec=dec)
    return out


def _sas_type_len(s):
    if pd.api.types.is_numeric_dtype(s) or pd.api.types.is_datetime64_any_dtype(s):
        return "숫자", 8
    lens = s.dropna().astype(str).map(lambda x: len(x.encode("utf-8")))
    return "문자", int(lens.max()) if len(lens) else 1


def proc_contents(df, name, labels=None, formats=None, png=None):
    """proc contents data=... varnum;"""
    labels = labels or {}
    formats = formats or {}
    rows = []
    for i, col in enumerate(df.columns, start=1):
        typ, ln = _sas_type_len(df[col])
        fmt = formats.get(col, "YYMMDD10." if pd.api.types.is_datetime64_any_dtype(df[col]) else "")
        rows.append({"#": i, "변수": col, "유형": typ, "길이": ln,
                     "출력형식": fmt, "레이블": labels.get(col, "")})
    out = pd.DataFrame(rows)
    subtitle = f"관측치 {len(df):,}  |  변수 {df.shape[1]}"
    title(f"{name}  ({subtitle})")
    print(out.to_string(index=False))
    sas_table_png(out, name, png, subtitle=f"변수 목록 (생성 순서)   ·   {subtitle}")
    return out


def proc_freq(df, var, title_text=None, order="freq", missing=True, png=None, plot=True):
    """proc freq order=freq; tables var / missing; run;"""
    s = df[var]
    counts = s.value_counts(dropna=not missing)
    if order == "data":                       # 처음 나타난 순서
        counts = counts.reindex(pd.unique(s.dropna() if not missing else s))
    elif order != "freq":                     # internal: 값 순서
        counts = counts.sort_index()
    if missing and s.isna().any():
        counts.index = counts.index.map(lambda x: "." if pd.isna(x) else x)
    out = pd.DataFrame({
        var: counts.index,
        "빈도": counts.values,
        "백분율": counts.values / counts.sum() * 100,
        "누적 빈도": counts.values.cumsum(),
        "누적 백분율": counts.values.cumsum() / counts.sum() * 100,
    })
    head = title_text or f"{var} 빈도"
    title(f"{head} - {var}")
    print(out.to_string(index=False))
    if not missing and s.isna().any():
        print(f"결측 빈도 = {s.isna().sum()}")
    if png:
        sas_table_png(out, f"{head}", png, subtitle=f"FREQ 프로시저 · {var}")
        if plot and len(out) <= 60:
            sas_bar_png(out[var], out["빈도"], f"{var} 빈도 분포", f"{png}_plot",
                        xlabel=var, horizontal=len(out) > 12)
    return out


def proc_freq_cross(df, row, col, title_text=None, png=None):
    """proc freq; tables row*col / missing norow nocol; (셀: 빈도 / 전체 백분율)"""
    ct = pd.crosstab(df[row].fillna("."), df[col].fillna("."), margins=True, margins_name="합계")
    total = ct.loc["합계", "합계"]
    title(title_text or f"{row} * {col} 교차표")
    print("빈도")
    print(ct.to_string())
    print("\n전체 백분율(%)")
    print((ct / total * 100).round(2).to_string())
    if png:
        cell = ct.astype(object).copy()
        for r in ct.index:
            for c in ct.columns:
                cell.loc[r, c] = f"{ct.loc[r, c]:,}\n{ct.loc[r, c] / total * 100:.2f}%"
        cell = cell.reset_index().rename(columns={row: f"{row} \\ {col}"})
        cell.columns = [str(c) for c in cell.columns]
        _cross_png(cell, title_text or f"{row} * {col} 교차표", png)
    return ct


def _cross_png(cell, title_text, png):
    if not SAS_TABLE_PNG:
        return
    SAS_PLOT_DIR.mkdir(parents=True, exist_ok=True)
    n_r, n_c = cell.shape
    widths = [max(_disp_len(c), 8) * 0.095 + 0.35 for c in cell.columns]
    widths[0] = max(widths[0], 1.4)
    fig_w, row_h = max(5, sum(widths) + 0.4), 0.46
    fig_h = 0.9 + row_h * (n_r + 1)
    fig = plt.figure(figsize=(fig_w, fig_h), facecolor="white")
    fig.text(0.5, 1 - 0.28 / fig_h, title_text, ha="center", va="top",
             fontsize=12, fontweight="bold", color=SAS_HEADER_INK)
    fig.text(0.5, 1 - 0.55 / fig_h, "셀 내용: 빈도 / 전체 백분율", ha="center", va="top",
             fontsize=8.5, color="#333333")
    tw = sum(widths) / fig_w
    ax = fig.add_axes([(1 - tw) / 2, 0.15 / fig_h, tw, row_h * (n_r + 1) / fig_h])
    ax.axis("off")
    tbl = ax.table(cellText=cell.values.tolist(), colLabels=list(cell.columns),
                   colWidths=[w / sum(widths) for w in widths], bbox=[0, 0, 1, 1])
    tbl.auto_set_font_size(False)
    tbl.set_fontsize(8.5)
    for (r, c), x in tbl.get_celld().items():
        x.set_edgecolor(SAS_BORDER)
        x.set_linewidth(0.6)
        if r == 0 or c == 0:
            x.set_facecolor(SAS_HEADER_BG)
            x.get_text().set_color(SAS_HEADER_INK)
            x.get_text().set_fontweight("bold")
        x.get_text().set_ha("center")
    out = SAS_PLOT_DIR / f"{_slug(png)}.png"
    fig.savefig(out, dpi=150, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"-> SAS 스타일 표 저장: {out.name}")


_STAT_LABEL = {
    "n": "N", "nmiss": "N 결측", "mean": "평균", "std": "표준편차",
    "min": "최소값", "p1": "1번째 백분위수", "p25": "25번째 백분위수", "q1": "하위 사분위수",
    "median": "중위수", "p75": "75번째 백분위수", "q3": "상위 사분위수",
    "p90": "90번째 백분위수", "p95": "95번째 백분위수",
    "p99": "99번째 백분위수", "max": "최대값",
}


def _stat(s, name):
    s = pd.to_numeric(s, errors="coerce") if not pd.api.types.is_numeric_dtype(s) else s
    if name == "n":
        return s.count()
    if name == "nmiss":
        return s.isna().sum()
    if name in ("q1", "p25"):
        return pctl(s, 25)
    if name == "median":
        return pctl(s, 50)
    if name in ("q3", "p75"):
        return pctl(s, 75)
    if name.startswith("p"):
        return pctl(s, float(name[1:]))
    return getattr(s, name)()


def proc_means(df, var, stats, title_text=None, labels=None, maxdec=2, png=None):
    """proc means data=... <stats> maxdec=; var ...; run;"""
    labels = labels or {}
    rows = []
    for v in var:
        s = df[v].astype(float) if df[v].dtype == bool else df[v]
        row = {"변수": v, "레이블": labels.get(v, "")}
        for st in stats:
            val = _stat(s, st)
            row[_STAT_LABEL[st]] = int(val) if st in ("n", "nmiss") else val
        rows.append(row)
    out = pd.DataFrame(rows)
    if not any(out["레이블"]):
        out = out.drop(columns="레이블")
    if title_text:
        title(title_text)
    print(out.round(maxdec).to_string(index=False))
    sas_table_png(out, title_text or "MEANS", png, dec=maxdec, subtitle="MEANS 프로시저")
    return out


# ======================================================================
# 이탈 모델 공통 변환: 크게 치우친 금액·횟수·간격 변수는 log(1+x)
#   기준: TRAIN 왜도 > 2 인 금액·간격 변수. 극단값 한 개가 위험 점수를 좌우하는 문제 방지
#   (예: 누적 구매 $35K 신규 고객이 금액 하나 때문에 위험 상위 11위로 나오던 문제 -> 변환 후 686위)
#   횟수 변수(frequency_days·frequency_orders)는 3.3 의 '주문 수 vs 구매일 수' 비교 대상이라 원값 유지
#   sklearn Pipeline 맨 앞에 넣으면 학습·검증·전체 고객 점수 계산에 똑같이 적용되고, 저장 테이블은 원값 그대로 남는다.
# ======================================================================
LOG_FEATURES = ["monetary", "avg_order_value", "avg_shipping", "avg_days_between_orders",
                "std_days_between_orders", "clv_proxy"]


def log_skewed(X, cols=None):
    """DataFrame 의 치우친 변수만 log1p (음수는 0으로). 없는 열은 건너뛴다"""
    X = X.copy()
    for c in (cols or LOG_FEATURES):
        if c in X.columns:
            X[c] = np.log1p(pd.to_numeric(X[c], errors="coerce").clip(lower=0))
    return X


def LogSkewed():
    """Pipeline 첫 단계용 변환기: Pipeline([("log", LogSkewed()), ("preprocessor", ...), ("classifier", ...)])"""
    from sklearn.preprocessing import FunctionTransformer
    return FunctionTransformer(log_skewed, validate=False, feature_names_out="one-to-one")
