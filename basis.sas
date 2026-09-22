/*====================================================================
  제3절 K-Means (K=6) 군집 다각도 검증 및 보고서 자동 생성 (수정본)
  파일명: WBS_3_Cluster_Validation_fixed.sas

  원본 대비 수정 요약
    1) 존재하지 않는 ODS 표 이름(Fastclus.ClusterSummary 등)에 의존하지 않고
       R-Square, Pseudo-F 를 군집 결과에서 직접 계산 (CCC 는 OUTSTAT 에서 시도)
    2) FASTCLUS 에 maxiter=100 converge=0 추가 (기본값 maxiter=1 은 수렴 전 결과)
    3) GMM: 배열 posterior: 가 0개 변수로 잡혀 DATA 스텝이 실패하던 문제 수정
       (변수명을 dictionary 에서 찾음), 표준화(z-score) 값이 아닌 원 단위
       monetary 의 log(1+x) 사용
    4) MODECLUS(옵션 불확실, HDBSCAN 도 아님) -> kNN 거리 기반 이상치 비율(Tukey 규칙)
    5) MDS -> PCA 2차원 투영 (표준화 변수의 유클리드 거리 기준 고전 MDS 와 같은 결과).
       MDS 는 OUT 데이터에 _TYPE_ 행이 섞여 있고 MERGE 가 BY 없이 행 순서로
       결합되어 좌표와 군집이 어긋날 수 있었음
    6) 부트스트랩: cluster*cluster 를 비교하면 항상 완전 일치가 되므로 무의미 ->
       "전체 데이터 군집" 대 "80% 재표집 군집" 의 Adjusted Rand Index(ARI) 로 교체
    7) Kruskal-Wallis: ODS 표 이름 대신 순위로 H 통계량을 직접 계산,
       효과크기는 epsilon-squared = H / (n - 1)
    8) 리포트 문자열은 작은따옴표 + symget 으로 만들어 % 와 & 매크로 해석 문제 방지
    9) options nosyntaxcheck: 한 단계가 실패해도 이후 단계가 0관측 모드로
       연쇄 실패하지 않도록 함
====================================================================*/

options validvarname=any obs=max replace nosyntaxcheck;

%let CRM_PATH    = /home/student/crm_db;
%let OUTPUT_DIR  = &CRM_PATH.;

libname crm "&CRM_PATH.";

%let VAR_LIST    = recency frequency monetary product_value_p rfmp_score;
%let N_VARS      = %sysfunc(countw(&VAR_LIST.));
%let N_CLUSTERS  = 6;
%let KNN_K       = 10;
%let N_BOOT      = 30;
%let BOOT_RATE   = 0.8;

%global KMEANS_CCC KMEANS_RSQ KMEANS_PSEUDOF GMM_BOUNDARY_PCT NOISE_PCT
        BOOT_ARI_MEAN BOOT_ARI_P5 BOOT_ARI_MIN;

%let KMEANS_CCC        = N/A;
%let KMEANS_RSQ        = N/A;
%let KMEANS_PSEUDOF    = N/A;
%let GMM_BOUNDARY_PCT  = N/A;
%let NOISE_PCT         = N/A;
%let BOOT_ARI_MEAN     = N/A;
%let BOOT_ARI_P5       = N/A;
%let BOOT_ARI_MIN      = N/A;

data _null_;
    rc = dlgcdir("&OUTPUT_DIR.");
run;


/*====================================================================
  0. 입력 테이블과 변수 확인
====================================================================*/

%macro require_table(ds=);

    %if %sysfunc(exist(&ds.)) = 0 %then %do;
        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %abort cancel;
    %end;

    %else %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;

%mend require_table;


%macro require_var(ds=, vars=);

    %local dsid i v rc;

    %let dsid = %sysfunc(open(&ds., i));

    %if &dsid. = 0 %then %do;
        %put ERROR: &ds. 데이터셋을 열 수 없습니다.;
        %abort cancel;
    %end;

    %do i = 1 %to %sysfunc(countw(&vars.));

        %let v = %scan(&vars., &i.);

        %if %sysfunc(varnum(&dsid., &v.)) = 0 %then %do;
            %let rc = %sysfunc(close(&dsid.));
            %put ERROR: &ds. 에 필수 변수 &v. 이(가) 없습니다.;
            %abort cancel;
        %end;

    %end;

    %let rc = %sysfunc(close(&dsid.));

%mend require_var;

%require_table(ds=crm.w3_customer_rfmp_py);
%require_var(ds=crm.w3_customer_rfmp_py, vars=customer_id &VAR_LIST.);


/*====================================================================
  1. 입력 데이터 준비 및 Z-Score 표준화
====================================================================*/

data work.cluster_data_imp;

    set crm.w3_customer_rfmp_py(keep=customer_id &VAR_LIST.);

    array _v{*} &VAR_LIST.;

    do _i = 1 to dim(_v);
        if missing(_v{_i}) then _v{_i} = 0;
    end;

    drop _i;

run;

proc stdize data=work.cluster_data_imp out=work.cluster_data_scaled method=std;
    var &VAR_LIST.;
run;

proc sql noprint;
    select count(*) into :N_OBS trimmed from work.cluster_data_scaled;
quit;

%put NOTE: 군집 대상 고객 수 = &N_OBS., 변수 수 = &N_VARS.;


/*====================================================================
  2. K-Means (K=6) 재현 및 정량 지표 산출

  R-Square 와 Pseudo-F 는 군집 결과에서 직접 계산합니다.
    R-Square = 1 - 군집 내 제곱합 / 전체 제곱합
    Pseudo-F = (R2 / (k-1)) / ((1 - R2) / (n - k))
====================================================================*/

proc fastclus
    data=work.cluster_data_scaled
    maxclusters=&N_CLUSTERS.
    maxiter=100
    converge=0
    out=work.kmeans_res
    outstat=work.kmeans_stat
    noprint;

    var &VAR_LIST.;

run;


/* 군집 중심(평균) 계산 */
proc means data=work.kmeans_res noprint nway;
    class cluster;
    var &VAR_LIST.;
    output out=work.km_centroid(drop=_type_ _freq_) mean=;
run;

proc sort data=work.kmeans_res out=work.km_sorted;
    by cluster;
run;


/* 군집 내 제곱합과 전체 제곱합에 쓸 식을 변수 목록에서 자동 생성 */
%global RENAME_LIST WSS_EXPR TSS_EXPR;

%macro build_ss_lists;

    %local i v;

    %let RENAME_LIST =;
    %let WSS_EXPR    = 0;
    %let TSS_EXPR    = 0;

    %do i = 1 %to &N_VARS.;

        %let v = %scan(&VAR_LIST., &i.);

        %let RENAME_LIST = &RENAME_LIST. &v.=c&i.;
        %let WSS_EXPR    = &WSS_EXPR. + (&v. - c&i.)**2;
        %let TSS_EXPR    = &TSS_EXPR. + (&v.)**2;

    %end;

%mend build_ss_lists;

%build_ss_lists;


data work.km_ss;

    merge
        work.km_sorted
        work.km_centroid(rename=(&RENAME_LIST.));

    by cluster;

    sq_within = &WSS_EXPR.;
    sq_total  = &TSS_EXPR.;

run;


proc sql noprint;

    select
        sum(sq_within),
        sum(sq_total),
        count(*),
        count(distinct cluster)
      into
        :SS_WITHIN trimmed,
        :SS_TOTAL trimmed,
        :N_KM_OBS trimmed,
        :N_KM_CLU trimmed
    from work.km_ss;

quit;


data _null_;

    ss_within = &SS_WITHIN.;
    ss_total  = &SS_TOTAL.;
    n         = &N_KM_OBS.;
    k         = &N_KM_CLU.;

    r2 = 1 - ss_within / ss_total;

    if k > 1 and n > k and r2 < 1 then
        pseudo_f = (r2 / (k - 1)) / ((1 - r2) / (n - k));
    else
        pseudo_f = .;

    call symputx('KMEANS_RSQ', put(r2 * 100, 8.2));
    call symputx('KMEANS_PSEUDOF', put(pseudo_f, 12.2));

run;


/* CCC: FASTCLUS 의 OUTSTAT 데이터에서 찾아보고, 없으면 N/A 로 둡니다. */
%macro get_ccc;

    %local has_cols;

    proc contents data=work.kmeans_stat out=work._stat_cols(keep=name) noprint;
    run;

    proc sql noprint;
        select count(*) into :has_cols trimmed
        from work._stat_cols
        where upcase(name) in ('OVER_ALL', '_TYPE_');
    quit;

    %if &has_cols. = 2 %then %do;

        proc sql noprint;
            select strip(put(over_all, 12.4))
              into :KMEANS_CCC trimmed
            from work.kmeans_stat
            where upcase(strip(_type_)) = 'CCC';
        quit;

    %end;

%mend get_ccc;

%get_ccc;

%put NOTE: R-Square(퍼센트) = &KMEANS_RSQ., Pseudo-F = &KMEANS_PSEUDOF., CCC = &KMEANS_CCC.;


/* 군집별 고객 수 */
proc freq data=work.kmeans_res noprint;
    tables cluster / out=work.cluster_size(rename=(count=cnt percent=pct));
run;


/*====================================================================
  3. 비교 모델: GMM 소프트 군집 (원 단위 monetary 의 log(1+x), 1차원)

  PROC FMM 은 1차원 혼합분포만 지원하므로 K-Means(5변수)와 직접 비교되는
  지표는 아니며, 고객 금액 분포가 여러 봉우리로 나뉘는지 확인하는 용도입니다.
====================================================================*/

data work.gmm_in;

    set work.cluster_data_imp(keep=customer_id monetary);

    log_monetary = log(1 + max(monetary, 0));

run;

ods select none;

proc fmm data=work.gmm_in;
    model log_monetary = / k=&N_CLUSTERS.;
    output out=work.gmm_res posterior;
run;

ods select all;


%macro gmm_boundary;

    %local post_vars;

    %let post_vars =;

    %if %sysfunc(exist(work.gmm_res)) %then %do;

        proc sql noprint;
            select name into :post_vars separated by ' '
            from dictionary.columns
            where libname = 'WORK'
              and memname = 'GMM_RES'
              and substr(upcase(name), 1, 4) = 'POST';
        quit;

    %end;

    %if %length(&post_vars.) > 0 %then %do;

        data work.gmm_eval;
            set work.gmm_res;
            max_p = max(of &post_vars.);
            is_boundary = (max_p < 0.6);
        run;

        proc sql noprint;
            select strip(put(mean(is_boundary) * 100, 8.2))
              into :GMM_BOUNDARY_PCT trimmed
            from work.gmm_eval;
        quit;

    %end;

    %else %put WARNING: GMM 사후확률 변수를 찾지 못해 경계 고객 비율은 N/A 로 둡니다.;

%mend gmm_boundary;

%gmm_boundary;


/*====================================================================
  4. 밀도 기반 이상치 검증 (kNN 거리)

  각 고객에서 K번째로 가까운 이웃까지의 거리(표준화 공간)를 구하고,
  Q3 + 1.5 x IQR 를 넘으면 이상치로 봅니다.
====================================================================*/

data work.knn_out(keep=customer_id knn_dist);

    array X{&N_OBS., &N_VARS.} _temporary_;
    array D{&N_OBS.} _temporary_;
    array V{&N_VARS.} &VAR_LIST.;

    /* 전체 데이터를 배열로 읽기 */
    do i = 1 to &N_OBS.;

        set work.cluster_data_scaled point=i;

        do j = 1 to &N_VARS.;
            X{i, j} = V{j};
        end;

    end;

    /* 각 고객의 K번째 최근접 이웃 거리 (자기 자신 0 포함이므로 K+1번째) */
    do i = 1 to &N_OBS.;

        set work.cluster_data_scaled point=i;

        do m = 1 to &N_OBS.;

            s = 0;

            do j = 1 to &N_VARS.;
                s + (X{i, j} - X{m, j}) ** 2;
            end;

            D{m} = sqrt(s);

        end;

        knn_dist = smallest(&KNN_K. + 1, of D{*});

        output;

    end;

    stop;

run;

proc means data=work.knn_out noprint;
    var knn_dist;
    output out=work.knn_q q1=q1 q3=q3;
run;

data _null_;
    set work.knn_q;
    call symputx('KNN_CUT', q3 + 1.5 * (q3 - q1));
run;

proc sql noprint;
    select strip(put(mean(knn_dist > &KNN_CUT.) * 100, 8.2))
      into :NOISE_PCT trimmed
    from work.knn_out;
quit;


/*====================================================================
  5. 2차원 투영(PCA) 및 시각화
====================================================================*/

proc princomp
    data=work.cluster_data_scaled
    out=work.pca_scores
    n=2
    noprint;

    var &VAR_LIST.;

run;

proc sql;

    create table work.pca_plot as
    select
        p.customer_id,
        p.prin1,
        p.prin2,
        k.cluster

    from work.pca_scores as p
    inner join work.kmeans_res as k
        on p.customer_id = k.customer_id;

quit;

proc means data=work.pca_plot noprint;
    var prin1 prin2;
    output out=work.pca_var var=v1 v2;
run;

data _null_;
    set work.pca_var;
    call symputx('PC1_PCT', put(v1 / &N_VARS. * 100, 5.1));
    call symputx('PC2_PCT', put(v2 / &N_VARS. * 100, 5.1));
run;

ods graphics / reset=all;
ods graphics / width=8in height=6in imagename="pca_clusters_k6" imagefmt=png;
ods listing gpath="&OUTPUT_DIR.";

title "PCA 2D Projection of Customer Segments (K=&N_CLUSTERS.)";

proc sgplot data=work.pca_plot;
    scatter x=prin1 y=prin2 / group=cluster markerattrs=(symbol=CircleFilled size=6);
    xaxis label="PC1 (explained variance &PC1_PCT. pct)";
    yaxis label="PC2 (explained variance &PC2_PCT. pct)";
    keylegend / title="Cluster";
run;

title;


/*====================================================================
  6. 재표집 안정성 검증 (80% 무작위 부분표본 x 30회, Adjusted Rand Index)

  전체 데이터 K-Means 군집(work.kmeans_res)과 부분표본 K-Means 군집을
  같은 고객끼리 비교합니다. 군집 번호가 서로 달라도 되는 ARI 를 씁니다.
====================================================================*/

%macro calc_ari(ds=, ref=, alt=, out=);

    proc freq data=&ds. noprint;
        tables &ref. * &alt. / out=work._ari_ct(rename=(count=cnt));
    run;

    proc sql noprint;

        create table work._ari_rs as
        select sum(cnt) as a
        from work._ari_ct
        group by &ref.;

        create table work._ari_cs as
        select sum(cnt) as b
        from work._ari_ct
        group by &alt.;

        create table work._ari_raw as
        select
            (select sum(cnt * (cnt - 1) / 2) from work._ari_ct) as index_sum,
            (select sum(a * (a - 1) / 2) from work._ari_rs)     as sum_a,
            (select sum(b * (b - 1) / 2) from work._ari_cs)     as sum_b,
            (select sum(cnt) from work._ari_ct)                 as n_obs
        from sashelp.class(obs=1);

    quit;

    data &out.;

        set work._ari_raw;

        total_pairs = n_obs * (n_obs - 1) / 2;
        expected    = sum_a * sum_b / total_pairs;
        max_index   = 0.5 * (sum_a + sum_b);

        if max_index ne expected then
            ari = (index_sum - expected) / (max_index - expected);
        else
            ari = 1;

        keep ari n_obs;

    run;

%mend calc_ari;


%macro bootstrap_stability;

    %local b;

    proc datasets library=work nolist nowarn;
        delete boot_ari_all;
    quit;

    options nonotes;

    %do b = 1 %to &N_BOOT.;

        proc surveyselect
            data=work.cluster_data_scaled
            out=work.boot_sample
            method=srs
            samprate=&BOOT_RATE.
            seed=%eval(2025 + &b.)
            noprint;
        run;

        proc fastclus
            data=work.boot_sample
            maxclusters=&N_CLUSTERS.
            maxiter=100
            converge=0
            out=work.boot_res(keep=customer_id cluster rename=(cluster=boot_cluster))
            noprint;

            var &VAR_LIST.;

        run;

        proc sql noprint;

            create table work.boot_pair as
            select
                a.customer_id,
                r.cluster as ref_cluster,
                a.boot_cluster

            from work.boot_res as a
            inner join work.kmeans_res as r
                on a.customer_id = r.customer_id;

        quit;

        %calc_ari(
            ds=work.boot_pair,
            ref=ref_cluster,
            alt=boot_cluster,
            out=work.boot_ari_one
        );

        data work.boot_ari_one;
            set work.boot_ari_one;
            boot_no = &b.;
        run;

        proc append base=work.boot_ari_all data=work.boot_ari_one force;
        run;

    %end;

    options notes;

    proc means data=work.boot_ari_all noprint;
        var ari;
        output out=work.boot_stat mean=ari_mean p5=ari_p5 min=ari_min;
    run;

    data _null_;
        set work.boot_stat;
        call symputx('BOOT_ARI_MEAN', put(ari_mean, 8.4));
        call symputx('BOOT_ARI_P5',   put(ari_p5, 8.4));
        call symputx('BOOT_ARI_MIN',  put(ari_min, 8.4));
    run;

%mend bootstrap_stability;

%bootstrap_stability;


/*====================================================================
  7. Kruskal-Wallis 검정과 효과크기 (변수별 군집 분리도)

  H 통계량은 순위(동점은 평균순위)로 직접 계산합니다.
    H = (N - 1) x 군집 간 순위 제곱합 / 전체 순위 제곱합
  효과크기 epsilon-squared = H / (N - 1)
====================================================================*/

%macro calc_kw(v);

    proc rank data=work.kmeans_res out=work.kw_rank_&v. ties=mean;
        var &v.;
        ranks rk;
    run;

    proc sql noprint;

        create table work.kw_grp_&v. as
        select
            cluster,
            count(*) as n_g,
            mean(rk) as m_g
        from work.kw_rank_&v.
        where not missing(rk)
        group by cluster;

        select
            count(*),
            mean(rk),
            css(rk)
          into
            :KW_N trimmed,
            :KW_MEAN trimmed,
            :KW_SST trimmed
        from work.kw_rank_&v.
        where not missing(rk);

        select
            sum(n_g * (m_g - &KW_MEAN.) ** 2),
            count(*)
          into
            :KW_SSB trimmed,
            :KW_K trimmed
        from work.kw_grp_&v.;

    quit;

    data work.kw_&v.;

        length variable $32;

        variable = "&v.";
        n_obs    = &KW_N.;
        k_groups = &KW_K.;

        if &KW_SST. > 0 then
            h_stat = (n_obs - 1) * &KW_SSB. / &KW_SST.;
        else
            h_stat = 0;

        p_val      = sdf('CHISQ', h_stat, k_groups - 1);
        epsilon_sq = h_stat / (n_obs - 1);

        keep variable h_stat p_val epsilon_sq;

    run;

%mend calc_kw;

%calc_kw(recency);
%calc_kw(frequency);
%calc_kw(monetary);
%calc_kw(product_value_p);
%calc_kw(rfmp_score);

data work.kw_summary;
    set
        work.kw_recency
        work.kw_frequency
        work.kw_monetary
        work.kw_product_value_p
        work.kw_rfmp_score;
run;

proc sort data=work.kw_summary;
    by descending epsilon_sq;
run;


/*====================================================================
  8. 마크다운 보고서 (cluster_validation_report.md) 자동 생성

  값은 symget 으로 읽고 문장은 작은따옴표로 써서
  % 와 & 가 매크로로 해석되지 않게 했습니다.
====================================================================*/

filename rpt "&OUTPUT_DIR./cluster_validation_report.md" encoding="utf-8";

data _null_;

    file rpt;
    length line $700;

    line = '# 제3절 K-Means 고객 군집(K=' || strip(symget('N_CLUSTERS'))
           || ') 타당성 검증 종합 리포트';
    put line;
    put ' ';

    put '## 1. 정량적 평가 지표';
    line = '- **R-Square (설명력):** `' || strip(symget('KMEANS_RSQ')) || '%`';
    put line;
    line = '- **Pseudo-F (Calinski-Harabasz):** `' || strip(symget('KMEANS_PSEUDOF')) || '`';
    put line;
    line = '- **Cubic Clustering Criterion (CCC):** `' || strip(symget('KMEANS_CCC')) || '`';
    put line;
    put '  - CCC 해석(Sarle, 1983): 2 이상이면 양호, 0~2 는 주의해서 해석, 음수는 이상치 영향 가능. N/A 는 FASTCLUS 통계 데이터에서 값을 찾지 못한 경우.';
    put ' ';

    put '## 2. 군집 구성';
    put '| 군집 | 고객 수 | 비율 |';
    put '| :---: | :---: | :---: |';

run;


data _null_;

    file rpt mod;
    set work.cluster_size;
    length line $200;

    line = '| ' || catx(' | ', put(cluster, 3.), put(cnt, comma8.), strip(put(pct, 6.2)) || '%') || ' |';
    put line;

run;


data _null_;

    file rpt mod;
    length line $700;

    put ' ';
    put '## 3. 군집 구조 시각화';
    put '- **PCA 2차원 투영 파일:** `pca_clusters_k6.png`';
    put '  - 표준화 변수의 유클리드 거리 기준 2차원 투영이며, 군집 번호로 색을 구분함.';
    put ' ';

    put '## 4. 비교 실험';
    line = '- **GMM 경계 고객 비율 (최대 사후확률 < 0.6):** `' || strip(symget('GMM_BOUNDARY_PCT')) || '%`';
    put line;
    put '  - 원 단위 monetary 의 log(1+x) 1차원 혼합분포 기준이며 K-Means 5변수 결과와 직접 비교되는 값은 아님.';
    line = '- **kNN 거리 기반 이상치 비율 (Q3 + 1.5 x IQR 초과):** `' || strip(symget('NOISE_PCT')) || '%`';
    put line;
    put ' ';

    line = '## 5. 재표집 안정성 (80% 부분표본 x ' || strip(symget('N_BOOT')) || '회, ARI)';
    put line;
    line = '- **ARI 평균:** `' || strip(symget('BOOT_ARI_MEAN')) || '`';
    put line;
    line = '- **ARI 하위 5% 값:** `' || strip(symget('BOOT_ARI_P5')) || '`';
    put line;
    line = '- **ARI 최솟값:** `' || strip(symget('BOOT_ARI_MIN')) || '`';
    put line;
    put '- **해석:** ARI 가 0.8 이상이면 부분표본을 바꿔도 군집 구조가 안정적이라고 보는 것이 일반적인 경험 기준임. 전체 데이터 군집과 같은 고객끼리 비교함.';
    put ' ';

    put '## 6. 변수별 군집 분리도 (Kruskal-Wallis, 효과크기 epsilon-squared)';
    put '| 변수명 | H-Statistic | p-value | 효과크기 epsilon-squared |';
    put '| :--- | :---: | :---: | :---: |';

run;


data _null_;

    file rpt mod;
    set work.kw_summary end=last;
    length line $300 p_str $12;

    p_str = ifc(p_val < 0.001, '< 0.001', put(p_val, 8.4));

    line = '| ' || catx(' | ', strip(variable), strip(put(h_stat, 10.2)), strip(p_str), strip(put(epsilon_sq, 8.4))) || ' |';
    put line;

    if last then do;
        put ' ';
        put '---';
        put '> **[유의사항]** 표본 수가 크면 Kruskal-Wallis 검정의 p-value 는 거의 항상 0 에 가깝게 나옵니다.';
        put '> 군집을 만드는 데 쓴 변수로 군집 간 차이를 검정하는 것이므로 새로운 가설 검증이 아니라, epsilon-squared 중심의 변수별 군집 분리도(기술 통계)로 해석해야 합니다.';
    end;

run;

filename rpt clear;


/*====================================================================
  9. 실행 요약
====================================================================*/

%put NOTE: ========================================================;
%put NOTE: 군집 검증 파이프라인 실행이 끝났습니다.;
%put NOTE: R-Square(퍼센트)=&KMEANS_RSQ. Pseudo-F=&KMEANS_PSEUDOF. CCC=&KMEANS_CCC.;
%put NOTE: GMM 경계 고객(퍼센트)=&GMM_BOUNDARY_PCT. kNN 이상치(퍼센트)=&NOISE_PCT.;
%put NOTE: 재표집 ARI 평균=&BOOT_ARI_MEAN. 하위5퍼센트=&BOOT_ARI_P5. 최솟값=&BOOT_ARI_MIN.;
%put NOTE: 리포트 파일: &OUTPUT_DIR./cluster_validation_report.md;
%put NOTE: ========================================================;

title "Kruskal-Wallis 효과크기 요약";

proc print data=work.kw_summary noobs;
    format h_stat 10.2 p_val 8.4 epsilon_sq 8.4;
run;

title;


/*==========================================================
  군집 검증 대상 테이블 찾기

  1) CRM / PROJ 라이브러리에서 군집·세그먼트·등급 컬럼이 있는 테이블 목록
  2) CAS(casuser)에 올려 둔 테이블 목록
  3) CRM.W3_CUSTOMER_RFMP_PY 의 행 수, 등급별 고객 수, 컬럼 목록
  결과 표를 그대로 붙여 주시면 검증 대상을 확정합니다.
==========================================================*/

options validvarname=any;

libname crm  "/home/student/crm_db";
libname proj "/home/student/open";


/*----------------------------------------------------------
  1. 군집·세그먼트·등급 컬럼이 있는 테이블
----------------------------------------------------------*/

title "1. CRM/PROJ 라이브러리의 군집·세그먼트·등급 컬럼";

proc sql;

    select
        libname,
        memname,
        name

    from dictionary.columns

    where libname in ('CRM', 'PROJ')
      and memtype = 'DATA'
      and (
              index(upcase(name), 'CLUSTER') > 0
           or index(upcase(name), 'SEGMENT') > 0
           or index(upcase(name), 'TIER') > 0
           or index(name, '군집') > 0
           or index(name, '등급') > 0
          )

    order by libname, memname, name;

quit;


/*----------------------------------------------------------
  2. CAS(casuser)에 올려 둔 테이블
----------------------------------------------------------*/

%if %sysfunc(sessfound(mysession)) = 0 %then %do;
    cas mysession;
%end;

title "2. casuser 테이블 목록";

proc casutil incaslib="casuser";
    list tables;
quit;


/*----------------------------------------------------------
  3. 현재 파이프라인의 최종 등급 테이블 확인
----------------------------------------------------------*/

title "3-1. CRM.W3_CUSTOMER_RFMP_PY 행 수";

proc sql;

    select
        count(*) as n_rows,
        count(distinct customer_id) as n_customers

    from crm.w3_customer_rfmp_py;

quit;


title "3-2. RFMP 등급별 고객 수";

proc freq data=crm.w3_customer_rfmp_py;
    tables rfmp_tier / nocum;
run;


title "3-3. 컬럼 목록";

proc contents data=crm.w3_customer_rfmp_py varnum;
run;

title;


/*====================================================================
  WBS 5. 최종 고객 테이블 군집 검증 (PROC PYTHON)
  파일명: WBS_5_Final_Table_Validation.sas

  검증 대상
    CRM.W3_CUSTOMER_RFMP_PY  (고객당 1행, 1,468명)
      rfmp_tier : RFMP 점수를 6분위로 자른 등급 (Bronze ~ VIP)
      r/f/m/p_cluster : 지표별 1차원 K-Means 군집 (참고용)

  검증에 쓰는 특성 (표준화 후 사용)
    recency, log_frequency, log_monetary, log_product_value_p
    - F/M/P는 오른쪽 꼬리가 길어 이미 만들어 둔 로그 변환 변수를 씀
    - rfmp_score, r/f/m/p_score 는 위 변수에서 만든 합성 점수라 뺌

  이 코드가 하는 검증
    A. K=2~8 비교: K-Means, GMM 의 Silhouette / Davies-Bouldin /
       Calinski-Harabasz / BIC  -> K=6 이 다른 K 보다 나은가
    B. 교차검증: K-Means(k-means++), 다변량 GMM, HDBSCAN, RFMP 등급 간
       ARI / NMI 일치도
    C. 각 라벨의 내부 타당도(Silhouette 등)와 GMM 경계 고객 비율
    D. K-Means(K=6) 재표집 안정성 (80% 부분표본 x 30회, ARI)
    E. 시각적 분리: PCA, t-SNE, UMAP(설치되어 있을 때) 2차원 투영
    F. RFMP 등급 검증: 등급별 프로파일, 단조성, Spearman, Kruskal-Wallis
    G. 마크다운 종합 리포트 자동 생성

  주의
    - rfmp_tier 는 점수를 분위로 자른 등급이므로 특성 공간의 군집이 아님.
      내부 타당도가 낮게 나오는 것은 설계상 예상되는 결과이고, 핵심은
      "자연스러운 군집 구조와 얼마나 겹치는가" 를 보는 것임.
    - t-SNE/UMAP 은 시각 확인용이며 축소 공간의 거리는 의미가 없음.
    - 판정 문구는 경험적 기준(Silhouette 구간, ARI 구간)에 따른 참고용임.
====================================================================*/

options validvarname=any;

%let CRM_PATH   = /home/student/crm_db;
libname crm "&CRM_PATH.";

%let SEED       = 2026;
%let K_MIN      = 2;
%let K_MAX      = 8;
%let K_FINAL    = 6;
%let N_BOOT     = 30;
%let BOOT_RATE  = 0.8;


/*====================================================================
  0. 입력 테이블 확인
====================================================================*/

%macro require_table(ds=);

    %if %sysfunc(exist(&ds.)) = 0 %then %do;
        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %abort cancel;
    %end;

    %else %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;

%mend require_table;

%require_table(ds=crm.w3_customer_rfmp_py);


/* 이전 실행 결과만 삭제합니다. */
proc datasets library=crm nolist nowarn;
    delete
        w5_val_k_scan
        w5_val_agreement
        w5_val_label_quality
        w5_val_crosstab
        w5_val_tier_profile
        w5_val_tier_tests
        w5_val_summary;
quit;


/*====================================================================
  1. PROC PYTHON 검증
====================================================================*/

proc python restart;
submit;

import os

os.environ["OMP_NUM_THREADS"] = "1"
os.environ["OPENBLAS_NUM_THREADS"] = "1"
os.environ["MKL_NUM_THREADS"] = "1"

import warnings

warnings.filterwarnings("ignore")

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

from scipy import stats
from sklearn.cluster import KMeans
from sklearn.decomposition import PCA
from sklearn.manifold import TSNE, trustworthiness
from sklearn.metrics import (
    adjusted_rand_score,
    calinski_harabasz_score,
    davies_bouldin_score,
    normalized_mutual_info_score,
    silhouette_score
)
from sklearn.mixture import GaussianMixture
from sklearn.preprocessing import StandardScaler


# --------------------------------------------------------------------
# 1-0. 설정과 공통 함수
# --------------------------------------------------------------------

def sas_number(name):
    return int(float(str(SAS.symget(name)).strip()))


SEED = sas_number("SEED")
K_MIN = sas_number("K_MIN")
K_MAX = sas_number("K_MAX")
K_FINAL = sas_number("K_FINAL")
N_BOOT = sas_number("N_BOOT")
BOOT_RATE = float(str(SAS.symget("BOOT_RATE")).strip())
OUT_DIR = str(SAS.symget("CRM_PATH")).strip()

TIER_ORDER = ["Bronze", "Silver", "Gold", "Platinum", "Diamond", "VIP"]
TIER_RANK = {name: number + 1 for number, name in enumerate(TIER_ORDER)}

FEATURES = [
    "recency",
    "log_frequency",
    "log_monetary",
    "log_product_value_p"
]

RAW_FEATURES = [
    "recency",
    "frequency",
    "monetary",
    "product_value_p"
]

# 등급이 높을수록 값이 커져야 하는 방향 (Recency 는 작을수록 좋음)
EXPECTED_DIRECTION = {
    "recency": -1,
    "frequency": 1,
    "monetary": 1,
    "product_value_p": 1
}


def save_sas(frame, table_name):
    output = frame.reset_index(drop=True).copy()

    for column in output.columns:
        if output[column].dtype == object:
            output[column] = output[column].astype(str)

    SAS.df2sd(output, dataset=f"crm.{table_name}")


def relabel_by_score(labels, score):
    """군집 번호를 rfmp_score 평균이 낮은 순서대로 1, 2, ... 로 다시 붙입니다."""
    labels = np.asarray(labels)
    result = labels.copy()
    valid_ids = [value for value in np.unique(labels) if value != -1]
    order = sorted(
        valid_ids,
        key=lambda value: float(np.mean(score[labels == value]))
    )
    for new_number, old_number in enumerate(order, start=1):
        result[labels == old_number] = new_number
    return result


def quality_scores(X, labels):
    """잡음(-1)은 뺀 나머지 고객으로 내부 타당도를 계산합니다."""
    labels = np.asarray(labels)
    mask = labels != -1
    noise_pct = float(100.0 * (~mask).mean())
    labels_used = labels[mask]
    n_clusters = int(len(np.unique(labels_used)))

    result = {
        "n_clusters": n_clusters,
        "noise_pct": noise_pct,
        "silhouette": np.nan,
        "davies_bouldin": np.nan,
        "calinski_harabasz": np.nan
    }

    if n_clusters >= 2 and len(labels_used) > n_clusters:
        X_used = X[mask]
        result["silhouette"] = float(silhouette_score(X_used, labels_used))
        result["davies_bouldin"] = float(davies_bouldin_score(X_used, labels_used))
        result["calinski_harabasz"] = float(calinski_harabasz_score(X_used, labels_used))

    return result


def min_cluster_pct(labels):
    labels = np.asarray(labels)
    labels = labels[labels != -1]
    if len(labels) == 0:
        return np.nan
    counts = np.unique(labels, return_counts=True)[1]
    return float(100.0 * counts.min() / len(labels))


def read_silhouette(value):
    if not np.isfinite(value):
        return "계산 불가"
    if value >= 0.71:
        return "강한 구조"
    if value >= 0.51:
        return "합리적인 구조"
    if value >= 0.26:
        return "약한 구조"
    return "뚜렷한 구조 없음"


def read_ari(value):
    if not np.isfinite(value):
        return "계산 불가"
    if value >= 0.8:
        return "매우 높은 일치"
    if value >= 0.6:
        return "높은 일치"
    if value >= 0.3:
        return "중간 정도 일치"
    return "낮은 일치"


def get_hdbscan(X, min_cluster_size):
    """sklearn 의 HDBSCAN 을 먼저 쓰고, 없으면 hdbscan 패키지를 씁니다."""
    try:
        from sklearn.cluster import HDBSCAN
        model = HDBSCAN(min_cluster_size=min_cluster_size, min_samples=10)
        return model.fit_predict(X), "sklearn.cluster.HDBSCAN"
    except Exception:
        pass

    try:
        import hdbscan
        model = hdbscan.HDBSCAN(min_cluster_size=min_cluster_size, min_samples=10)
        return model.fit_predict(X), "hdbscan package"
    except Exception:
        return None, "not available"


print("=" * 72)
print("WBS 5. 최종 고객 테이블 군집 검증")
print("=" * 72)


# --------------------------------------------------------------------
# 1-1. 데이터 준비
# --------------------------------------------------------------------

df = SAS.sd2df("crm.w3_customer_rfmp_py")
df.columns = [str(column).strip().lower() for column in df.columns]

required = (
    ["customer_id", "rfmp_score", "rfmp_tier"]
    + FEATURES
    + RAW_FEATURES
)

missing_columns = [column for column in required if column not in df.columns]

if missing_columns:
    raise ValueError("필수 변수가 없습니다: " + ", ".join(missing_columns))

for column in FEATURES + RAW_FEATURES + ["rfmp_score"]:
    df[column] = pd.to_numeric(df[column], errors="coerce")

df["rfmp_tier"] = df["rfmp_tier"].astype(str).str.strip()

unknown_tiers = sorted(set(df["rfmp_tier"]) - set(TIER_ORDER))

if unknown_tiers:
    raise ValueError("알 수 없는 등급이 있습니다: " + ", ".join(unknown_tiers))

if df[FEATURES + RAW_FEATURES + ["rfmp_score"]].isna().any().any():
    raise ValueError("특성 또는 점수에 결측값이 있습니다.")

if df["customer_id"].duplicated().any():
    raise ValueError("customer_id 가 중복되었습니다.")

df["tier_rank"] = df["rfmp_tier"].map(TIER_RANK).astype(int)

n_customers = len(df)
score = df["rfmp_score"].to_numpy(dtype=float)

X = StandardScaler().fit_transform(df[FEATURES].to_numpy(dtype=float))

print(f"고객 수: {n_customers:,}, 검증 특성: {FEATURES}")


# --------------------------------------------------------------------
# 1-2. A. K=2~8 비교 (K-Means, GMM)
# --------------------------------------------------------------------

scan_rows = []

for k in range(K_MIN, K_MAX + 1):

    km = KMeans(
        n_clusters=k,
        init="k-means++",
        n_init=30,
        random_state=SEED
    ).fit(X)

    quality = quality_scores(X, km.labels_)

    scan_rows.append({
        "method": "KMEANS",
        "k": k,
        "silhouette": quality["silhouette"],
        "davies_bouldin": quality["davies_bouldin"],
        "calinski_harabasz": quality["calinski_harabasz"],
        "inertia": float(km.inertia_),
        "bic": np.nan,
        "aic": np.nan,
        "min_cluster_pct": min_cluster_pct(km.labels_)
    })

    gm = GaussianMixture(
        n_components=k,
        covariance_type="full",
        n_init=5,
        random_state=SEED,
        reg_covar=1e-4
    ).fit(X)

    gm_labels = gm.predict(X)
    quality = quality_scores(X, gm_labels)

    scan_rows.append({
        "method": "GMM",
        "k": k,
        "silhouette": quality["silhouette"],
        "davies_bouldin": quality["davies_bouldin"],
        "calinski_harabasz": quality["calinski_harabasz"],
        "inertia": np.nan,
        "bic": float(gm.bic(X)),
        "aic": float(gm.aic(X)),
        "min_cluster_pct": min_cluster_pct(gm_labels)
    })

k_scan = pd.DataFrame(scan_rows)

save_sas(k_scan, "w5_val_k_scan")

print("[A] K 비교 완료")


def rank_of_final_k(method, column, higher_is_better):
    part = k_scan[k_scan["method"] == method].dropna(subset=[column])
    if part.empty or K_FINAL not in set(part["k"]):
        return np.nan, np.nan
    ranked = part.sort_values(column, ascending=not higher_is_better)["k"].tolist()
    best_k = int(ranked[0])
    return best_k, ranked.index(K_FINAL) + 1


km_sil_best, km_sil_rank = rank_of_final_k("KMEANS", "silhouette", True)
km_db_best, km_db_rank = rank_of_final_k("KMEANS", "davies_bouldin", False)
gm_bic_best, gm_bic_rank = rank_of_final_k("GMM", "bic", False)


# --------------------------------------------------------------------
# 1-3. B. 최종 라벨 만들기와 교차검증
# --------------------------------------------------------------------

km_final = KMeans(
    n_clusters=K_FINAL,
    init="k-means++",
    n_init=50,
    random_state=SEED
).fit(X)

km_name = f"KMEANS_K{K_FINAL}"
gm_name = f"GMM_K{K_FINAL}"
tier_name = "RFMP_TIER6"

labels = {}
labels[tier_name] = df["tier_rank"].to_numpy()
labels[km_name] = relabel_by_score(km_final.labels_, score)

gm_final = GaussianMixture(
    n_components=K_FINAL,
    covariance_type="full",
    n_init=10,
    random_state=SEED,
    reg_covar=1e-4
).fit(X)

labels[gm_name] = relabel_by_score(gm_final.predict(X), score)

posterior = gm_final.predict_proba(X)
gmm_boundary_pct = float(100.0 * (posterior.max(axis=1) < 0.6).mean())
gmm_mean_max_posterior = float(posterior.max(axis=1).mean())

hdb_labels, hdb_source = get_hdbscan(X, min_cluster_size=max(15, int(0.02 * n_customers)))

if hdb_labels is not None:
    labels["HDBSCAN"] = relabel_by_score(hdb_labels, score)

print(f"[B] 최종 라벨 생성 완료 (HDBSCAN: {hdb_source})")

names = list(labels.keys())
agreement_rows = []
ari_matrix = pd.DataFrame(np.nan, index=names, columns=names)

for i, left in enumerate(names):
    for j, right in enumerate(names):
        ari_value = float(adjusted_rand_score(labels[left], labels[right]))
        ari_matrix.loc[left, right] = ari_value

        if i < j:
            agreement_rows.append({
                "label_a": left,
                "label_b": right,
                "ari": ari_value,
                "nmi": float(normalized_mutual_info_score(labels[left], labels[right])),
                "reading": read_ari(ari_value)
            })

agreement = pd.DataFrame(agreement_rows)

save_sas(agreement, "w5_val_agreement")

crosstab = (
    pd.crosstab(df["rfmp_tier"], labels[km_name])
    .reindex(TIER_ORDER)
    .fillna(0)
    .astype(int)
)

crosstab_long = crosstab.stack().reset_index()
crosstab_long.columns = ["rfmp_tier", "kmeans_cluster", "customers"]

save_sas(crosstab_long, "w5_val_crosstab")


# --------------------------------------------------------------------
# 1-4. C. 라벨별 내부 타당도
# --------------------------------------------------------------------

quality_rows = []

for name in names:
    quality = quality_scores(X, labels[name])
    quality_rows.append({
        "label_set": name,
        "n_clusters": quality["n_clusters"],
        "noise_pct": quality["noise_pct"],
        "min_cluster_pct": min_cluster_pct(labels[name]),
        "silhouette": quality["silhouette"],
        "davies_bouldin": quality["davies_bouldin"],
        "calinski_harabasz": quality["calinski_harabasz"],
        "silhouette_reading": read_silhouette(quality["silhouette"])
    })

label_quality = pd.DataFrame(quality_rows)

save_sas(label_quality, "w5_val_label_quality")

print("[C] 내부 타당도 계산 완료")


# --------------------------------------------------------------------
# 1-5. D. K-Means 재표집 안정성
# --------------------------------------------------------------------

rng = np.random.RandomState(SEED)
boot_aris = []

for b in range(N_BOOT):

    idx = rng.choice(n_customers, size=int(n_customers * BOOT_RATE), replace=False)

    boot_model = KMeans(
        n_clusters=K_FINAL,
        init="k-means++",
        n_init=10,
        random_state=SEED + b
    ).fit(X[idx])

    boot_aris.append(
        float(adjusted_rand_score(labels[km_name][idx], boot_model.labels_))
    )

boot_aris = np.array(boot_aris)
boot_mean = float(boot_aris.mean())
boot_p5 = float(np.percentile(boot_aris, 5))
boot_min = float(boot_aris.min())

print(f"[D] 재표집 안정성 ARI 평균 {boot_mean:.4f}, 하위5% {boot_p5:.4f}")


# --------------------------------------------------------------------
# 1-6. F. RFMP 등급 검증
# --------------------------------------------------------------------

profile_rows = []

for tier in TIER_ORDER:
    part = df[df["rfmp_tier"] == tier]
    row = {
        "rfmp_tier": tier,
        "tier_rank": TIER_RANK[tier],
        "customers": int(len(part)),
        "rfmp_score_mean": float(part["rfmp_score"].mean())
    }
    for column in RAW_FEATURES:
        row[f"{column}_mean"] = float(part[column].mean())
        row[f"{column}_median"] = float(part[column].median())
    profile_rows.append(row)

tier_profile = pd.DataFrame(profile_rows)

save_sas(tier_profile, "w5_val_tier_profile")

test_rows = []

for column in RAW_FEATURES:

    means = [float(df.loc[df["tier_rank"] == r, column].mean()) for r in range(1, 7)]
    direction = EXPECTED_DIRECTION[column]
    steps = np.diff(means)
    monotonic = bool(np.all(steps * direction > 0))

    rho, rho_p = stats.spearmanr(df["tier_rank"], df[column])

    groups = [df.loc[df["tier_rank"] == r, column].to_numpy() for r in range(1, 7)]
    h_stat, p_value = stats.kruskal(*groups)
    epsilon_sq = float(h_stat / (n_customers - 1))

    test_rows.append({
        "variable": column,
        "expected_direction": "higher tier, higher value" if direction > 0 else "higher tier, lower value",
        "monotonic_by_tier_mean": int(monotonic),
        "spearman_rho": float(rho),
        "spearman_p": float(rho_p),
        "kruskal_h": float(h_stat),
        "kruskal_p": float(p_value),
        "epsilon_sq": epsilon_sq
    })

tier_tests = pd.DataFrame(test_rows)

save_sas(tier_tests, "w5_val_tier_tests")

print("[F] 등급 검증 완료")


# --------------------------------------------------------------------
# 1-7. E. 시각적 분리 (PCA, t-SNE, UMAP)
# --------------------------------------------------------------------

embeds = {}
embed_notes = {}

pca = PCA(n_components=2, random_state=SEED)
embeds["PCA"] = pca.fit_transform(X)
embed_notes["PCA"] = (
    f"PC1 {100 * pca.explained_variance_ratio_[0]:.1f}%, "
    f"PC2 {100 * pca.explained_variance_ratio_[1]:.1f}%"
)

try:
    embeds["t-SNE"] = TSNE(
        n_components=2,
        perplexity=30,
        init="pca",
        learning_rate="auto",
        random_state=SEED
    ).fit_transform(X)
except (TypeError, ValueError):
    embeds["t-SNE"] = TSNE(
        n_components=2,
        perplexity=30,
        init="pca",
        learning_rate=200.0,
        random_state=SEED
    ).fit_transform(X)

umap_available = False

try:
    import umap
    embeds["UMAP"] = umap.UMAP(
        n_neighbors=15,
        min_dist=0.1,
        random_state=SEED
    ).fit_transform(X)
    umap_available = True
except Exception:
    print("UMAP 을 사용할 수 없어 PCA 와 t-SNE 만 그립니다.")

trust_rows = []

for name, embedding in embeds.items():
    trust_rows.append({
        "embedding": name,
        "trustworthiness": float(trustworthiness(X, embedding, n_neighbors=15))
    })

trust = pd.DataFrame(trust_rows)

print("[E] 2차원 투영 계산 완료: " + ", ".join(embeds.keys()))


def draw_and_save(figure_name):
    path = os.path.join(OUT_DIR, figure_name)
    try:
        plt.savefig(path, dpi=150, bbox_inches="tight")
    except Exception as error:
        print(f"그림 파일 저장 실패({figure_name}): {error}")
    SAS.pyplot(plt)
    plt.close("all")


# 그림 1: K 비교
fig, axes = plt.subplots(2, 2, figsize=(12, 8))

for method, color in [("KMEANS", "tab:blue"), ("GMM", "tab:orange")]:
    part = k_scan[k_scan["method"] == method]
    axes[0, 0].plot(part["k"], part["silhouette"], marker="o", color=color, label=method)
    axes[0, 1].plot(part["k"], part["davies_bouldin"], marker="o", color=color, label=method)

part = k_scan[k_scan["method"] == "KMEANS"]
axes[1, 0].plot(part["k"], part["calinski_harabasz"], marker="o", color="tab:blue")

part = k_scan[k_scan["method"] == "GMM"]
axes[1, 1].plot(part["k"], part["bic"], marker="o", color="tab:orange")

axes[0, 0].set_title("Silhouette (higher is better)")
axes[0, 1].set_title("Davies-Bouldin (lower is better)")
axes[1, 0].set_title("Calinski-Harabasz, K-Means (higher is better)")
axes[1, 1].set_title("BIC, GMM (lower is better)")

for axis in axes.ravel():
    axis.axvline(K_FINAL, color="red", linestyle="--", linewidth=1)
    axis.set_xlabel("K")
    axis.grid(alpha=0.3)

axes[0, 0].legend()
axes[0, 1].legend()

plt.suptitle("K comparison on log-transformed RFMP features", fontsize=14)
plt.tight_layout()
draw_and_save("w5_val_k_scan.png")


# 그림 2: 2차원 투영 (위: RFMP 등급, 아래: K-Means)
n_cols = len(embeds)

fig, axes = plt.subplots(2, n_cols, figsize=(5.2 * n_cols, 9.5), squeeze=False)

tier_cmap = plt.get_cmap("viridis", 6)
last_scatter = None

for column_number, (name, embedding) in enumerate(embeds.items()):

    last_scatter = axes[0, column_number].scatter(
        embedding[:, 0], embedding[:, 1],
        c=df["tier_rank"], cmap=tier_cmap, vmin=0.5, vmax=6.5, s=8
    )
    axes[0, column_number].set_title(f"{name} - RFMP tier")

    axes[1, column_number].scatter(
        embedding[:, 0], embedding[:, 1],
        c=labels[km_name], cmap="tab10", s=8
    )
    axes[1, column_number].set_title(f"{name} - K-Means K={K_FINAL}")

    for row_number in (0, 1):
        axes[row_number, column_number].set_xticks([])
        axes[row_number, column_number].set_yticks([])

plt.suptitle("2D projections of the 4 standardized features", fontsize=14)
plt.tight_layout(rect=[0, 0, 0.9, 0.96])

# 등급 색상 막대는 별도 축에 그려 위아래 그림 크기가 같게 유지합니다.
color_axis = fig.add_axes([0.92, 0.55, 0.015, 0.3])
colorbar = fig.colorbar(last_scatter, cax=color_axis, ticks=list(range(1, 7)))
colorbar.ax.set_yticklabels(TIER_ORDER)

draw_and_save("w5_val_embeddings.png")


# 그림 3: 라벨 간 ARI
fig, ax = plt.subplots(figsize=(6.5, 5.5))
image = ax.imshow(ari_matrix.to_numpy(dtype=float), vmin=0, vmax=1, cmap="Blues")

ax.set_xticks(range(len(names)))
ax.set_xticklabels(names, rotation=30, ha="right")
ax.set_yticks(range(len(names)))
ax.set_yticklabels(names)

for row_number in range(len(names)):
    for column_number in range(len(names)):
        ax.text(
            column_number, row_number,
            f"{ari_matrix.iloc[row_number, column_number]:.2f}",
            ha="center", va="center", color="black"
        )

ax.set_title("Adjusted Rand Index between label sets")
fig.colorbar(image, ax=ax)
plt.tight_layout()
draw_and_save("w5_val_ari_heatmap.png")


# --------------------------------------------------------------------
# 1-8. 요약표와 마크다운 리포트
# --------------------------------------------------------------------

def label_value(label_set, column):
    return float(label_quality.loc[label_quality["label_set"] == label_set, column].iloc[0])


def pair_ari(a, b):
    match = agreement[
        ((agreement["label_a"] == a) & (agreement["label_b"] == b))
        | ((agreement["label_a"] == b) & (agreement["label_b"] == a))
    ]
    return float(match["ari"].iloc[0]) if len(match) else np.nan


km_sil = label_value(km_name, "silhouette")
tier_sil = label_value(tier_name, "silhouette")
ari_tier_km = pair_ari(tier_name, km_name)
ari_km_gmm = pair_ari(km_name, gm_name)
ari_km_hdb = pair_ari(km_name, "HDBSCAN") if "HDBSCAN" in labels else np.nan
hdb_clusters = label_value("HDBSCAN", "n_clusters") if "HDBSCAN" in labels else np.nan
hdb_noise = label_value("HDBSCAN", "noise_pct") if "HDBSCAN" in labels else np.nan

monotonic_count = int(tier_tests["monotonic_by_tier_mean"].sum())

summary_rows = [
    ("A. K 비교", f"K-Means 실루엣 최고 K / K={K_FINAL} 순위", f"{km_sil_best} / {km_sil_rank}위", "K 별 값은 w5_val_k_scan 표 참고"),
    ("A. K 비교", f"K-Means Davies-Bouldin 최저 K / K={K_FINAL} 순위", f"{km_db_best} / {km_db_rank}위", "낮을수록 좋음"),
    ("A. K 비교", f"GMM BIC 최저 K / K={K_FINAL} 순위", f"{gm_bic_best} / {gm_bic_rank}위", "낮을수록 좋음"),
    ("C. 내부 타당도", f"{km_name} 실루엣", f"{km_sil:.4f}", read_silhouette(km_sil)),
    ("C. 내부 타당도", f"{tier_name} 실루엣", f"{tier_sil:.4f}", "점수 분위 절단 등급이라 낮게 나오는 것이 설계상 자연스러움"),
    ("B. 교차검증", f"ARI({km_name}, {gm_name})", f"{ari_km_gmm:.4f}", read_ari(ari_km_gmm)),
    ("B. 교차검증", f"ARI({km_name}, HDBSCAN)", f"{ari_km_hdb:.4f}", f"HDBSCAN 군집 {hdb_clusters:.0f}개, 잡음 {hdb_noise:.1f}%" if "HDBSCAN" in labels else "HDBSCAN 사용 불가"),
    ("B. 교차검증", f"ARI({tier_name}, {km_name})", f"{ari_tier_km:.4f}", read_ari(ari_tier_km)),
    ("C. 경계 고객", "GMM 경계 고객 비율(최대 사후확률 < 0.6)", f"{gmm_boundary_pct:.2f}%", f"평균 최대 사후확률 {gmm_mean_max_posterior:.3f}"),
    ("D. 안정성", f"{km_name} 재표집 ARI 평균 / 하위5% / 최솟값", f"{boot_mean:.4f} / {boot_p5:.4f} / {boot_min:.4f}", read_ari(boot_mean)),
    ("F. 등급 검증", "등급 순서대로 평균이 단조로운 변수 수", f"{monotonic_count} / {len(tier_tests)}", "기대 방향: Recency 감소, F/M/P 증가")
]

summary = pd.DataFrame(summary_rows, columns=["area", "metric", "value", "reading"])

save_sas(summary, "w5_val_summary")

lines = []
lines.append("# WBS 5. 최종 고객 테이블 군집 검증 리포트")
lines.append("")
lines.append(f"- 대상: `crm.w3_customer_rfmp_py` ({n_customers:,}명), 검증 특성: {', '.join(FEATURES)} (표준화)")
lines.append(f"- 검증 라벨: RFMP 등급(6분위), K-Means(k-means++) K={K_FINAL}, GMM K={K_FINAL}, HDBSCAN")
lines.append("")
lines.append("## 1. 요약")
lines.append("")
lines.append("| 영역 | 지표 | 값 | 해석 |")
lines.append("| :--- | :--- | :---: | :--- |")

for row in summary_rows:
    lines.append(f"| {row[0]} | {row[1]} | {row[2]} | {row[3]} |")

lines.append("")
lines.append("## 2. 라벨별 내부 타당도")
lines.append("")
lines.append("| 라벨 | 군집 수 | 잡음(%) | 최소 군집(%) | Silhouette | Davies-Bouldin | Calinski-Harabasz |")
lines.append("| :--- | :---: | :---: | :---: | :---: | :---: | :---: |")

for _, row in label_quality.iterrows():
    lines.append(
        f"| {row['label_set']} | {int(row['n_clusters'])} | {row['noise_pct']:.1f} | "
        f"{row['min_cluster_pct']:.1f} | {row['silhouette']:.4f} | "
        f"{row['davies_bouldin']:.4f} | {row['calinski_harabasz']:.1f} |"
    )

lines.append("")
lines.append("## 3. 등급 검증 (Kruskal-Wallis, Spearman)")
lines.append("")
lines.append("| 변수 | 단조성 | Spearman rho | epsilon-squared |")
lines.append("| :--- | :---: | :---: | :---: |")

for _, row in tier_tests.iterrows():
    lines.append(
        f"| {row['variable']} | {'예' if row['monotonic_by_tier_mean'] == 1 else '아니오'} | "
        f"{row['spearman_rho']:.3f} | {row['epsilon_sq']:.4f} |"
    )

lines.append("")
lines.append("## 4. 2차원 투영")
lines.append("")

for _, row in trust.iterrows():
    lines.append(f"- {row['embedding']} trustworthiness(이웃 15): `{row['trustworthiness']:.4f}`")

lines.append(f"- PCA 설명분산: {embed_notes['PCA']}")
lines.append(f"- UMAP 사용: {'예' if umap_available else '아니오(설치되어 있지 않음)'}")
lines.append("- 그림 파일: `w5_val_k_scan.png`, `w5_val_embeddings.png`, `w5_val_ari_heatmap.png`")
lines.append("")
lines.append("## 5. 해석 시 유의사항")
lines.append("")
lines.append("- RFMP 등급은 점수를 6분위로 자른 것이므로 특성 공간의 군집이 아닙니다. 낮은 Silhouette는 결함이 아니라 설계상 예상되는 결과이고, 자연스러운 군집(K-Means/GMM)과의 ARI가 등급 경계가 데이터 구조와 얼마나 겹치는지를 보여줍니다.")
lines.append("- ARI와 Silhouette의 구간별 표현은 경험적 기준이며 통계적 증명이 아닙니다.")
lines.append("- HDBSCAN의 내부 타당도는 잡음으로 분류된 고객을 뺀 나머지로 계산하므로 다른 라벨의 값과 직접 비교할 수 없습니다.")
lines.append("- 군집을 만든 변수로 군집 간 차이를 검정하면 유의하게 나오는 것이 정상입니다. Kruskal-Wallis 값은 변수별 분리 정도를 설명하는 기술 통계로 보십시오.")
lines.append("- t-SNE/UMAP은 시각 확인용입니다. 축소 공간에서의 군집 간 거리와 크기는 의미가 없습니다.")

report_path = os.path.join(OUT_DIR, "w5_cluster_validation_report.md")

try:
    with open(report_path, "w", encoding="utf-8") as report_file:
        report_file.write("\n".join(lines) + "\n")
    print(f"리포트 저장: {report_path}")
except Exception as error:
    print(f"리포트 저장 실패: {error}")

print("\n[요약]")
print(summary.to_string(index=False))
print("\nWBS 5 검증이 끝났습니다.")

endsubmit;
quit;


/*====================================================================
  2. 산출물 생성 확인
====================================================================*/

%macro check_outputs;

    %local missing_count;
    %let missing_count = 0;

    %if %sysfunc(exist(crm.w5_val_k_scan))        = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5_val_agreement))     = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5_val_label_quality)) = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5_val_crosstab))      = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5_val_tier_profile))  = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5_val_tier_tests))    = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5_val_summary))       = 0 %then %let missing_count = %eval(&missing_count. + 1);

    %if &missing_count. > 0 %then
        %put ERROR: WBS 5 산출물 &missing_count.개가 생성되지 않았습니다. 위쪽 PROC PYTHON 로그를 확인하십시오.;
    %else
        %put NOTE: WBS 5 산출물 7개를 확인했습니다.;

%mend check_outputs;

%check_outputs;


/*====================================================================
  3. 핵심 결과 출력
====================================================================*/

title "WBS 5-1. 검증 요약";

proc print data=crm.w5_val_summary noobs;
run;


title "WBS 5-2. K=2~8 비교";

proc print data=crm.w5_val_k_scan noobs;
    format silhouette davies_bouldin 8.4 calinski_harabasz comma10.1
           inertia bic aic comma14.1 min_cluster_pct 8.2;
run;


title "WBS 5-3. 라벨 간 일치도(ARI, NMI)";

proc print data=crm.w5_val_agreement noobs;
    format ari nmi 8.4;
run;


title "WBS 5-4. 라벨별 내부 타당도";

proc print data=crm.w5_val_label_quality noobs;
    format noise_pct min_cluster_pct 8.2 silhouette davies_bouldin 8.4 calinski_harabasz comma10.1;
run;


title "WBS 5-5. RFMP 등급 x K-Means 교차표";

proc freq data=crm.w5_val_crosstab;
    tables rfmp_tier * kmeans_cluster / norow nocol nopercent nocum;
    weight customers;
run;


title "WBS 5-6. RFMP 등급 검증";

proc print data=crm.w5_val_tier_tests noobs;
    format spearman_rho epsilon_sq kruskal_p spearman_p 8.4 kruskal_h 10.2;
run;

title;


/*====================================================================
  WBS 5. 최종 고객 테이블 군집 검증 (PROC PYTHON)
  파일명: WBS_5_Final_Table_Validation.sas

  검증 대상
    CRM.W3_CUSTOMER_RFMP_PY  (고객당 1행, 1,468명)
      rfmp_tier : RFMP 점수를 6분위로 자른 등급 (Bronze ~ VIP)
      r/f/m/p_cluster : 지표별 1차원 K-Means 군집 (참고용)

  검증에 쓰는 특성 (표준화 후 사용)
    recency, log_frequency, log_monetary, log_product_value_p
    - F/M/P는 오른쪽 꼬리가 길어 이미 만들어 둔 로그 변환 변수를 씀
    - rfmp_score, r/f/m/p_score 는 위 변수에서 만든 합성 점수라 뺌

  이 코드가 하는 검증
    A. K=2~8 비교: K-Means, GMM 의 Silhouette / Davies-Bouldin /
       Calinski-Harabasz / BIC  -> K=6 이 다른 K 보다 나은가
    B. 교차검증: K-Means(k-means++), 다변량 GMM, HDBSCAN, RFMP 등급 간
       ARI / NMI 일치도
    C. 각 라벨의 내부 타당도(Silhouette 등)와 GMM 경계 고객 비율
    D. K-Means(K=6) 재표집 안정성 (80% 부분표본 x 30회, ARI)
    E. 시각적 분리: PCA, t-SNE, UMAP(설치되어 있을 때) 2차원 투영
    F. RFMP 등급 검증: 등급별 프로파일, 단조성, Spearman, Kruskal-Wallis
    G. 마크다운 종합 리포트 자동 생성

  주의
    - rfmp_tier 는 점수를 분위로 자른 등급이므로 특성 공간의 군집이 아님.
      내부 타당도가 낮게 나오는 것은 설계상 예상되는 결과이고, 핵심은
      "자연스러운 군집 구조와 얼마나 겹치는가" 를 보는 것임.
    - t-SNE/UMAP 은 시각 확인용이며 축소 공간의 거리는 의미가 없음.
    - 판정 문구는 경험적 기준(Silhouette 구간, ARI 구간)에 따른 참고용임.
====================================================================*/

options validvarname=any;

%let CRM_PATH   = /home/student/crm_db;
libname crm "&CRM_PATH.";

%let SEED       = 2026;
%let K_MIN      = 2;
%let K_MAX      = 8;
%let K_FINAL    = 6;
%let N_BOOT     = 30;
%let BOOT_RATE  = 0.8;


/*====================================================================
  0. 입력 테이블 확인
====================================================================*/

%macro require_table(ds=);

    %if %sysfunc(exist(&ds.)) = 0 %then %do;
        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %abort cancel;
    %end;

    %else %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;

%mend require_table;

%require_table(ds=crm.w3_customer_rfmp_py);


/* 이전 실행 결과만 삭제합니다. */
proc datasets library=crm nolist nowarn;
    delete
        w5_val_k_scan
        w5_val_agreement
        w5_val_label_quality
        w5_val_crosstab
        w5_val_tier_profile
        w5_val_tier_tests
        w5_val_summary;
quit;


/*====================================================================
  1. PROC PYTHON 검증
====================================================================*/

proc python restart;
submit;

import os

os.environ["OMP_NUM_THREADS"] = "1"
os.environ["OPENBLAS_NUM_THREADS"] = "1"
os.environ["MKL_NUM_THREADS"] = "1"

import warnings

warnings.filterwarnings("ignore")

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

from scipy import stats
from sklearn.cluster import KMeans
from sklearn.decomposition import PCA
from sklearn.manifold import TSNE, trustworthiness
from sklearn.metrics import (
    adjusted_rand_score,
    calinski_harabasz_score,
    davies_bouldin_score,
    normalized_mutual_info_score,
    silhouette_score
)
from sklearn.mixture import GaussianMixture
from sklearn.preprocessing import StandardScaler


# --------------------------------------------------------------------
# 1-0. 설정과 공통 함수
# --------------------------------------------------------------------

def sas_number(name):
    return int(float(str(SAS.symget(name)).strip()))


SEED = sas_number("SEED")
K_MIN = sas_number("K_MIN")
K_MAX = sas_number("K_MAX")
K_FINAL = sas_number("K_FINAL")
N_BOOT = sas_number("N_BOOT")
BOOT_RATE = float(str(SAS.symget("BOOT_RATE")).strip())
OUT_DIR = str(SAS.symget("CRM_PATH")).strip()

TIER_ORDER = ["Bronze", "Silver", "Gold", "Platinum", "Diamond", "VIP"]
TIER_RANK = {name: number + 1 for number, name in enumerate(TIER_ORDER)}

FEATURES = [
    "recency",
    "log_frequency",
    "log_monetary",
    "log_product_value_p"
]

RAW_FEATURES = [
    "recency",
    "frequency",
    "monetary",
    "product_value_p"
]

# 등급이 높을수록 값이 커져야 하는 방향 (Recency 는 작을수록 좋음)
EXPECTED_DIRECTION = {
    "recency": -1,
    "frequency": 1,
    "monetary": 1,
    "product_value_p": 1
}


def save_sas(frame, table_name):
    output = frame.reset_index(drop=True).copy()

    for column in output.columns:
        if output[column].dtype == object:
            output[column] = output[column].astype(str)

    SAS.df2sd(output, dataset=f"crm.{table_name}")


def relabel_by_score(labels, score):
    """군집 번호를 rfmp_score 평균이 낮은 순서대로 1, 2, ... 로 다시 붙입니다."""
    labels = np.asarray(labels)
    result = labels.copy()
    valid_ids = [value for value in np.unique(labels) if value != -1]
    order = sorted(
        valid_ids,
        key=lambda value: float(np.mean(score[labels == value]))
    )
    for new_number, old_number in enumerate(order, start=1):
        result[labels == old_number] = new_number
    return result


def quality_scores(X, labels):
    """잡음(-1)은 뺀 나머지 고객으로 내부 타당도를 계산합니다."""
    labels = np.asarray(labels)
    mask = labels != -1
    noise_pct = float(100.0 * (~mask).mean())
    labels_used = labels[mask]
    n_clusters = int(len(np.unique(labels_used)))

    result = {
        "n_clusters": n_clusters,
        "noise_pct": noise_pct,
        "silhouette": np.nan,
        "davies_bouldin": np.nan,
        "calinski_harabasz": np.nan
    }

    if n_clusters >= 2 and len(labels_used) > n_clusters:
        X_used = X[mask]
        result["silhouette"] = float(silhouette_score(X_used, labels_used))
        result["davies_bouldin"] = float(davies_bouldin_score(X_used, labels_used))
        result["calinski_harabasz"] = float(calinski_harabasz_score(X_used, labels_used))

    return result


def min_cluster_pct(labels):
    labels = np.asarray(labels)
    labels = labels[labels != -1]
    if len(labels) == 0:
        return np.nan
    counts = np.unique(labels, return_counts=True)[1]
    return float(100.0 * counts.min() / len(labels))


def read_silhouette(value):
    if not np.isfinite(value):
        return "계산 불가"
    if value >= 0.71:
        return "강한 구조"
    if value >= 0.51:
        return "합리적인 구조"
    if value >= 0.26:
        return "약한 구조"
    return "뚜렷한 구조 없음"


def read_ari(value):
    if not np.isfinite(value):
        return "계산 불가"
    if value >= 0.8:
        return "매우 높은 일치"
    if value >= 0.6:
        return "높은 일치"
    if value >= 0.3:
        return "중간 정도 일치"
    return "낮은 일치"


def get_hdbscan(X, min_cluster_size):
    """sklearn 의 HDBSCAN 을 먼저 쓰고, 없으면 hdbscan 패키지를 씁니다."""
    try:
        from sklearn.cluster import HDBSCAN
        model = HDBSCAN(min_cluster_size=min_cluster_size, min_samples=10)
        return model.fit_predict(X), "sklearn.cluster.HDBSCAN"
    except Exception:
        pass

    try:
        import hdbscan
        model = hdbscan.HDBSCAN(min_cluster_size=min_cluster_size, min_samples=10)
        return model.fit_predict(X), "hdbscan package"
    except Exception:
        return None, "not available"


print("=" * 72)
print("WBS 5. 최종 고객 테이블 군집 검증")
print("=" * 72)


# --------------------------------------------------------------------
# 1-1. 데이터 준비
# --------------------------------------------------------------------

df = SAS.sd2df("crm.w3_customer_rfmp_py")
df.columns = [str(column).strip().lower() for column in df.columns]

required = (
    ["customer_id", "rfmp_score", "rfmp_tier"]
    + FEATURES
    + RAW_FEATURES
)

missing_columns = [column for column in required if column not in df.columns]

if missing_columns:
    raise ValueError("필수 변수가 없습니다: " + ", ".join(missing_columns))

for column in FEATURES + RAW_FEATURES + ["rfmp_score"]:
    df[column] = pd.to_numeric(df[column], errors="coerce")

df["rfmp_tier"] = df["rfmp_tier"].astype(str).str.strip()

unknown_tiers = sorted(set(df["rfmp_tier"]) - set(TIER_ORDER))

if unknown_tiers:
    raise ValueError("알 수 없는 등급이 있습니다: " + ", ".join(unknown_tiers))

if df[FEATURES + RAW_FEATURES + ["rfmp_score"]].isna().any().any():
    raise ValueError("특성 또는 점수에 결측값이 있습니다.")

if df["customer_id"].duplicated().any():
    raise ValueError("customer_id 가 중복되었습니다.")

df["tier_rank"] = df["rfmp_tier"].map(TIER_RANK).astype(int)

n_customers = len(df)
score = df["rfmp_score"].to_numpy(dtype=float)

X = StandardScaler().fit_transform(df[FEATURES].to_numpy(dtype=float))

print(f"고객 수: {n_customers:,}, 검증 특성: {FEATURES}")


# --------------------------------------------------------------------
# 1-2. A. K=2~8 비교 (K-Means, GMM)
# --------------------------------------------------------------------

scan_rows = []

for k in range(K_MIN, K_MAX + 1):

    km = KMeans(
        n_clusters=k,
        init="k-means++",
        n_init=30,
        random_state=SEED
    ).fit(X)

    quality = quality_scores(X, km.labels_)

    scan_rows.append({
        "method": "KMEANS",
        "k": k,
        "silhouette": quality["silhouette"],
        "davies_bouldin": quality["davies_bouldin"],
        "calinski_harabasz": quality["calinski_harabasz"],
        "inertia": float(km.inertia_),
        "bic": np.nan,
        "aic": np.nan,
        "min_cluster_pct": min_cluster_pct(km.labels_)
    })

    gm = GaussianMixture(
        n_components=k,
        covariance_type="full",
        n_init=5,
        random_state=SEED,
        reg_covar=1e-4
    ).fit(X)

    gm_labels = gm.predict(X)
    quality = quality_scores(X, gm_labels)

    scan_rows.append({
        "method": "GMM",
        "k": k,
        "silhouette": quality["silhouette"],
        "davies_bouldin": quality["davies_bouldin"],
        "calinski_harabasz": quality["calinski_harabasz"],
        "inertia": np.nan,
        "bic": float(gm.bic(X)),
        "aic": float(gm.aic(X)),
        "min_cluster_pct": min_cluster_pct(gm_labels)
    })

k_scan = pd.DataFrame(scan_rows)

save_sas(k_scan, "w5_val_k_scan")

print("[A] K 비교 완료")


def rank_of_final_k(method, column, higher_is_better):
    part = k_scan[k_scan["method"] == method].dropna(subset=[column])
    if part.empty or K_FINAL not in set(part["k"]):
        return np.nan, np.nan
    ranked = part.sort_values(column, ascending=not higher_is_better)["k"].tolist()
    best_k = int(ranked[0])
    return best_k, ranked.index(K_FINAL) + 1


km_sil_best, km_sil_rank = rank_of_final_k("KMEANS", "silhouette", True)
km_db_best, km_db_rank = rank_of_final_k("KMEANS", "davies_bouldin", False)
gm_bic_best, gm_bic_rank = rank_of_final_k("GMM", "bic", False)


# --------------------------------------------------------------------
# 1-3. B. 최종 라벨 만들기와 교차검증
# --------------------------------------------------------------------

km_final = KMeans(
    n_clusters=K_FINAL,
    init="k-means++",
    n_init=50,
    random_state=SEED
).fit(X)

km_name = f"KMEANS_K{K_FINAL}"
gm_name = f"GMM_K{K_FINAL}"
tier_name = "RFMP_TIER6"

labels = {}
labels[tier_name] = df["tier_rank"].to_numpy()
labels[km_name] = relabel_by_score(km_final.labels_, score)

gm_final = GaussianMixture(
    n_components=K_FINAL,
    covariance_type="full",
    n_init=10,
    random_state=SEED,
    reg_covar=1e-4
).fit(X)

labels[gm_name] = relabel_by_score(gm_final.predict(X), score)

posterior = gm_final.predict_proba(X)
gmm_boundary_pct = float(100.0 * (posterior.max(axis=1) < 0.6).mean())
gmm_mean_max_posterior = float(posterior.max(axis=1).mean())

hdb_labels, hdb_source = get_hdbscan(X, min_cluster_size=max(15, int(0.02 * n_customers)))

if hdb_labels is not None:
    labels["HDBSCAN"] = relabel_by_score(hdb_labels, score)

print(f"[B] 최종 라벨 생성 완료 (HDBSCAN: {hdb_source})")

names = list(labels.keys())
agreement_rows = []
ari_matrix = pd.DataFrame(np.nan, index=names, columns=names)

for i, left in enumerate(names):
    for j, right in enumerate(names):
        ari_value = float(adjusted_rand_score(labels[left], labels[right]))
        ari_matrix.loc[left, right] = ari_value

        if i < j:
            agreement_rows.append({
                "label_a": left,
                "label_b": right,
                "ari": ari_value,
                "nmi": float(normalized_mutual_info_score(labels[left], labels[right])),
                "reading": read_ari(ari_value)
            })

agreement = pd.DataFrame(agreement_rows)

save_sas(agreement, "w5_val_agreement")

crosstab = (
    pd.crosstab(df["rfmp_tier"], labels[km_name])
    .reindex(TIER_ORDER)
    .fillna(0)
    .astype(int)
)

crosstab_long = crosstab.stack().reset_index()
crosstab_long.columns = ["rfmp_tier", "kmeans_cluster", "customers"]

save_sas(crosstab_long, "w5_val_crosstab")


# --------------------------------------------------------------------
# 1-4. C. 라벨별 내부 타당도
# --------------------------------------------------------------------

quality_rows = []

for name in names:
    quality = quality_scores(X, labels[name])
    quality_rows.append({
        "label_set": name,
        "n_clusters": quality["n_clusters"],
        "noise_pct": quality["noise_pct"],
        "min_cluster_pct": min_cluster_pct(labels[name]),
        "silhouette": quality["silhouette"],
        "davies_bouldin": quality["davies_bouldin"],
        "calinski_harabasz": quality["calinski_harabasz"],
        "silhouette_reading": read_silhouette(quality["silhouette"])
    })

label_quality = pd.DataFrame(quality_rows)

save_sas(label_quality, "w5_val_label_quality")

print("[C] 내부 타당도 계산 완료")


# --------------------------------------------------------------------
# 1-5. D. K-Means 재표집 안정성
# --------------------------------------------------------------------

rng = np.random.RandomState(SEED)
boot_aris = []

for b in range(N_BOOT):

    idx = rng.choice(n_customers, size=int(n_customers * BOOT_RATE), replace=False)

    boot_model = KMeans(
        n_clusters=K_FINAL,
        init="k-means++",
        n_init=10,
        random_state=SEED + b
    ).fit(X[idx])

    boot_aris.append(
        float(adjusted_rand_score(labels[km_name][idx], boot_model.labels_))
    )

boot_aris = np.array(boot_aris)
boot_mean = float(boot_aris.mean())
boot_p5 = float(np.percentile(boot_aris, 5))
boot_min = float(boot_aris.min())

print(f"[D] 재표집 안정성 ARI 평균 {boot_mean:.4f}, 하위5% {boot_p5:.4f}")


# --------------------------------------------------------------------
# 1-6. F. RFMP 등급 검증
# --------------------------------------------------------------------

profile_rows = []

for tier in TIER_ORDER:
    part = df[df["rfmp_tier"] == tier]
    row = {
        "rfmp_tier": tier,
        "tier_rank": TIER_RANK[tier],
        "customers": int(len(part)),
        "rfmp_score_mean": float(part["rfmp_score"].mean())
    }
    for column in RAW_FEATURES:
        row[f"{column}_mean"] = float(part[column].mean())
        row[f"{column}_median"] = float(part[column].median())
    profile_rows.append(row)

tier_profile = pd.DataFrame(profile_rows)

save_sas(tier_profile, "w5_val_tier_profile")

test_rows = []

for column in RAW_FEATURES:

    means = [float(df.loc[df["tier_rank"] == r, column].mean()) for r in range(1, 7)]
    direction = EXPECTED_DIRECTION[column]
    steps = np.diff(means)
    monotonic = bool(np.all(steps * direction > 0))

    rho, rho_p = stats.spearmanr(df["tier_rank"], df[column])

    groups = [df.loc[df["tier_rank"] == r, column].to_numpy() for r in range(1, 7)]
    h_stat, p_value = stats.kruskal(*groups)
    epsilon_sq = float(h_stat / (n_customers - 1))

    test_rows.append({
        "variable": column,
        "expected_direction": "higher tier, higher value" if direction > 0 else "higher tier, lower value",
        "monotonic_by_tier_mean": int(monotonic),
        "spearman_rho": float(rho),
        "spearman_p": float(rho_p),
        "kruskal_h": float(h_stat),
        "kruskal_p": float(p_value),
        "epsilon_sq": epsilon_sq
    })

tier_tests = pd.DataFrame(test_rows)

save_sas(tier_tests, "w5_val_tier_tests")

print("[F] 등급 검증 완료")


# --------------------------------------------------------------------
# 1-7. E. 시각적 분리 (PCA, t-SNE, UMAP)
# --------------------------------------------------------------------

embeds = {}
embed_notes = {}

pca = PCA(n_components=2, random_state=SEED)
embeds["PCA"] = pca.fit_transform(X)
embed_notes["PCA"] = (
    f"PC1 {100 * pca.explained_variance_ratio_[0]:.1f}%, "
    f"PC2 {100 * pca.explained_variance_ratio_[1]:.1f}%"
)

try:
    embeds["t-SNE"] = TSNE(
        n_components=2,
        perplexity=30,
        init="pca",
        learning_rate="auto",
        random_state=SEED
    ).fit_transform(X)
except (TypeError, ValueError):
    embeds["t-SNE"] = TSNE(
        n_components=2,
        perplexity=30,
        init="pca",
        learning_rate=200.0,
        random_state=SEED
    ).fit_transform(X)

umap_available = False

try:
    import umap
    embeds["UMAP"] = umap.UMAP(
        n_neighbors=15,
        min_dist=0.1,
        random_state=SEED
    ).fit_transform(X)
    umap_available = True
except Exception:
    print("UMAP 을 사용할 수 없어 PCA 와 t-SNE 만 그립니다.")

trust_rows = []

for name, embedding in embeds.items():
    trust_rows.append({
        "embedding": name,
        "trustworthiness": float(trustworthiness(X, embedding, n_neighbors=15))
    })

trust = pd.DataFrame(trust_rows)

print("[E] 2차원 투영 계산 완료: " + ", ".join(embeds.keys()))


def draw_and_save(figure_name):
    path = os.path.join(OUT_DIR, figure_name)
    try:
        plt.savefig(path, dpi=150, bbox_inches="tight")
    except Exception as error:
        print(f"그림 파일 저장 실패({figure_name}): {error}")
    SAS.pyplot(plt)
    plt.close("all")


# 그림 1: K 비교
fig, axes = plt.subplots(2, 2, figsize=(12, 8))

for method, color in [("KMEANS", "tab:blue"), ("GMM", "tab:orange")]:
    part = k_scan[k_scan["method"] == method]
    axes[0, 0].plot(part["k"], part["silhouette"], marker="o", color=color, label=method)
    axes[0, 1].plot(part["k"], part["davies_bouldin"], marker="o", color=color, label=method)

part = k_scan[k_scan["method"] == "KMEANS"]
axes[1, 0].plot(part["k"], part["calinski_harabasz"], marker="o", color="tab:blue")

part = k_scan[k_scan["method"] == "GMM"]
axes[1, 1].plot(part["k"], part["bic"], marker="o", color="tab:orange")

axes[0, 0].set_title("Silhouette (higher is better)")
axes[0, 1].set_title("Davies-Bouldin (lower is better)")
axes[1, 0].set_title("Calinski-Harabasz, K-Means (higher is better)")
axes[1, 1].set_title("BIC, GMM (lower is better)")

for axis in axes.ravel():
    axis.axvline(K_FINAL, color="red", linestyle="--", linewidth=1)
    axis.set_xlabel("K")
    axis.grid(alpha=0.3)

axes[0, 0].legend()
axes[0, 1].legend()

plt.suptitle("K comparison on log-transformed RFMP features", fontsize=14)
plt.tight_layout()
draw_and_save("w5_val_k_scan.png")


# 그림 2: 2차원 투영 (위: RFMP 등급, 아래: K-Means)
n_cols = len(embeds)

fig, axes = plt.subplots(2, n_cols, figsize=(5.2 * n_cols, 9.5), squeeze=False)

tier_cmap = plt.get_cmap("viridis", 6)
last_scatter = None

for column_number, (name, embedding) in enumerate(embeds.items()):

    last_scatter = axes[0, column_number].scatter(
        embedding[:, 0], embedding[:, 1],
        c=df["tier_rank"], cmap=tier_cmap, vmin=0.5, vmax=6.5, s=8
    )
    axes[0, column_number].set_title(f"{name} - RFMP tier")

    axes[1, column_number].scatter(
        embedding[:, 0], embedding[:, 1],
        c=labels[km_name], cmap="tab10", s=8
    )
    axes[1, column_number].set_title(f"{name} - K-Means K={K_FINAL}")

    for row_number in (0, 1):
        axes[row_number, column_number].set_xticks([])
        axes[row_number, column_number].set_yticks([])

plt.suptitle("2D projections of the 4 standardized features", fontsize=14)
plt.tight_layout(rect=[0, 0, 0.9, 0.96])

# 등급 색상 막대는 별도 축에 그려 위아래 그림 크기가 같게 유지합니다.
color_axis = fig.add_axes([0.92, 0.55, 0.015, 0.3])
colorbar = fig.colorbar(last_scatter, cax=color_axis, ticks=list(range(1, 7)))
colorbar.ax.set_yticklabels(TIER_ORDER)

draw_and_save("w5_val_embeddings.png")


# 그림 3: 라벨 간 ARI
fig, ax = plt.subplots(figsize=(6.5, 5.5))
image = ax.imshow(ari_matrix.to_numpy(dtype=float), vmin=0, vmax=1, cmap="Blues")

ax.set_xticks(range(len(names)))
ax.set_xticklabels(names, rotation=30, ha="right")
ax.set_yticks(range(len(names)))
ax.set_yticklabels(names)

for row_number in range(len(names)):
    for column_number in range(len(names)):
        ax.text(
            column_number, row_number,
            f"{ari_matrix.iloc[row_number, column_number]:.2f}",
            ha="center", va="center", color="black"
        )

ax.set_title("Adjusted Rand Index between label sets")
fig.colorbar(image, ax=ax)
plt.tight_layout()
draw_and_save("w5_val_ari_heatmap.png")


# --------------------------------------------------------------------
# 1-8. 요약표와 마크다운 리포트
# --------------------------------------------------------------------

def label_value(label_set, column):
    return float(label_quality.loc[label_quality["label_set"] == label_set, column].iloc[0])


def pair_ari(a, b):
    match = agreement[
        ((agreement["label_a"] == a) & (agreement["label_b"] == b))
        | ((agreement["label_a"] == b) & (agreement["label_b"] == a))
    ]
    return float(match["ari"].iloc[0]) if len(match) else np.nan


km_sil = label_value(km_name, "silhouette")
tier_sil = label_value(tier_name, "silhouette")
ari_tier_km = pair_ari(tier_name, km_name)
ari_km_gmm = pair_ari(km_name, gm_name)
ari_km_hdb = pair_ari(km_name, "HDBSCAN") if "HDBSCAN" in labels else np.nan
hdb_clusters = label_value("HDBSCAN", "n_clusters") if "HDBSCAN" in labels else np.nan
hdb_noise = label_value("HDBSCAN", "noise_pct") if "HDBSCAN" in labels else np.nan

monotonic_count = int(tier_tests["monotonic_by_tier_mean"].sum())

summary_rows = [
    ("A. K 비교", f"K-Means 실루엣 최고 K / K={K_FINAL} 순위", f"{km_sil_best} / {km_sil_rank}위", "K 별 값은 w5_val_k_scan 표 참고"),
    ("A. K 비교", f"K-Means Davies-Bouldin 최저 K / K={K_FINAL} 순위", f"{km_db_best} / {km_db_rank}위", "낮을수록 좋음"),
    ("A. K 비교", f"GMM BIC 최저 K / K={K_FINAL} 순위", f"{gm_bic_best} / {gm_bic_rank}위", "낮을수록 좋음"),
    ("C. 내부 타당도", f"{km_name} 실루엣", f"{km_sil:.4f}", read_silhouette(km_sil)),
    ("C. 내부 타당도", f"{tier_name} 실루엣", f"{tier_sil:.4f}", "점수 분위 절단 등급이라 낮게 나오는 것이 설계상 자연스러움"),
    ("B. 교차검증", f"ARI({km_name}, {gm_name})", f"{ari_km_gmm:.4f}", read_ari(ari_km_gmm)),
    ("B. 교차검증", f"ARI({km_name}, HDBSCAN)", f"{ari_km_hdb:.4f}", f"HDBSCAN 군집 {hdb_clusters:.0f}개, 잡음 {hdb_noise:.1f}%" if "HDBSCAN" in labels else "HDBSCAN 사용 불가"),
    ("B. 교차검증", f"ARI({tier_name}, {km_name})", f"{ari_tier_km:.4f}", read_ari(ari_tier_km)),
    ("C. 경계 고객", "GMM 경계 고객 비율(최대 사후확률 < 0.6)", f"{gmm_boundary_pct:.2f}%", f"평균 최대 사후확률 {gmm_mean_max_posterior:.3f}"),
    ("D. 안정성", f"{km_name} 재표집 ARI 평균 / 하위5% / 최솟값", f"{boot_mean:.4f} / {boot_p5:.4f} / {boot_min:.4f}", read_ari(boot_mean)),
    ("F. 등급 검증", "등급 순서대로 평균이 단조로운 변수 수", f"{monotonic_count} / {len(tier_tests)}", "기대 방향: Recency 감소, F/M/P 증가")
]

summary = pd.DataFrame(summary_rows, columns=["area", "metric", "value", "reading"])

save_sas(summary, "w5_val_summary")

lines = []
lines.append("# WBS 5. 최종 고객 테이블 군집 검증 리포트")
lines.append("")
lines.append(f"- 대상: `crm.w3_customer_rfmp_py` ({n_customers:,}명), 검증 특성: {', '.join(FEATURES)} (표준화)")
lines.append(f"- 검증 라벨: RFMP 등급(6분위), K-Means(k-means++) K={K_FINAL}, GMM K={K_FINAL}, HDBSCAN")
lines.append("")
lines.append("## 1. 요약")
lines.append("")
lines.append("| 영역 | 지표 | 값 | 해석 |")
lines.append("| :--- | :--- | :---: | :--- |")

for row in summary_rows:
    lines.append(f"| {row[0]} | {row[1]} | {row[2]} | {row[3]} |")

lines.append("")
lines.append("## 2. 라벨별 내부 타당도")
lines.append("")
lines.append("| 라벨 | 군집 수 | 잡음(%) | 최소 군집(%) | Silhouette | Davies-Bouldin | Calinski-Harabasz |")
lines.append("| :--- | :---: | :---: | :---: | :---: | :---: | :---: |")

for _, row in label_quality.iterrows():
    lines.append(
        f"| {row['label_set']} | {int(row['n_clusters'])} | {row['noise_pct']:.1f} | "
        f"{row['min_cluster_pct']:.1f} | {row['silhouette']:.4f} | "
        f"{row['davies_bouldin']:.4f} | {row['calinski_harabasz']:.1f} |"
    )

lines.append("")
lines.append("## 3. 등급 검증 (Kruskal-Wallis, Spearman)")
lines.append("")
lines.append("| 변수 | 단조성 | Spearman rho | epsilon-squared |")
lines.append("| :--- | :---: | :---: | :---: |")

for _, row in tier_tests.iterrows():
    lines.append(
        f"| {row['variable']} | {'예' if row['monotonic_by_tier_mean'] == 1 else '아니오'} | "
        f"{row['spearman_rho']:.3f} | {row['epsilon_sq']:.4f} |"
    )

lines.append("")
lines.append("## 4. 2차원 투영")
lines.append("")

for _, row in trust.iterrows():
    lines.append(f"- {row['embedding']} trustworthiness(이웃 15): `{row['trustworthiness']:.4f}`")

lines.append(f"- PCA 설명분산: {embed_notes['PCA']}")
lines.append(f"- UMAP 사용: {'예' if umap_available else '아니오(설치되어 있지 않음)'}")
lines.append("- 그림 파일: `w5_val_k_scan.png`, `w5_val_embeddings.png`, `w5_val_ari_heatmap.png`")
lines.append("")
lines.append("## 5. 해석 시 유의사항")
lines.append("")
lines.append("- RFMP 등급은 점수를 6분위로 자른 것이므로 특성 공간의 군집이 아닙니다. 낮은 Silhouette는 결함이 아니라 설계상 예상되는 결과이고, 자연스러운 군집(K-Means/GMM)과의 ARI가 등급 경계가 데이터 구조와 얼마나 겹치는지를 보여줍니다.")
lines.append("- ARI와 Silhouette의 구간별 표현은 경험적 기준이며 통계적 증명이 아닙니다.")
lines.append("- HDBSCAN의 내부 타당도는 잡음으로 분류된 고객을 뺀 나머지로 계산하므로 다른 라벨의 값과 직접 비교할 수 없습니다.")
lines.append("- 군집을 만든 변수로 군집 간 차이를 검정하면 유의하게 나오는 것이 정상입니다. Kruskal-Wallis 값은 변수별 분리 정도를 설명하는 기술 통계로 보십시오.")
lines.append("- t-SNE/UMAP은 시각 확인용입니다. 축소 공간에서의 군집 간 거리와 크기는 의미가 없습니다.")

report_path = os.path.join(OUT_DIR, "w5_cluster_validation_report.md")

try:
    with open(report_path, "w", encoding="utf-8") as report_file:
        report_file.write("\n".join(lines) + "\n")
    print(f"리포트 저장: {report_path}")
except Exception as error:
    print(f"리포트 저장 실패: {error}")

print("\n[요약]")
print(summary.to_string(index=False))
print("\nWBS 5 검증이 끝났습니다.")

endsubmit;
quit;


/*====================================================================
  2. 산출물 생성 확인
====================================================================*/

%macro check_outputs;

    %local missing_count;
    %let missing_count = 0;

    %if %sysfunc(exist(crm.w5_val_k_scan))        = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5_val_agreement))     = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5_val_label_quality)) = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5_val_crosstab))      = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5_val_tier_profile))  = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5_val_tier_tests))    = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5_val_summary))       = 0 %then %let missing_count = %eval(&missing_count. + 1);

    %if &missing_count. > 0 %then
        %put ERROR: WBS 5 산출물 &missing_count.개가 생성되지 않았습니다. 위쪽 PROC PYTHON 로그를 확인하십시오.;
    %else
        %put NOTE: WBS 5 산출물 7개를 확인했습니다.;

%mend check_outputs;

%check_outputs;


/*====================================================================
  3. 핵심 결과 출력
====================================================================*/

title "WBS 5-1. 검증 요약";

proc print data=crm.w5_val_summary noobs;
run;


title "WBS 5-2. K=2~8 비교";

proc print data=crm.w5_val_k_scan noobs;
    format silhouette davies_bouldin 8.4 calinski_harabasz comma10.1
           inertia bic aic comma14.1 min_cluster_pct 8.2;
run;


title "WBS 5-3. 라벨 간 일치도(ARI, NMI)";

proc print data=crm.w5_val_agreement noobs;
    format ari nmi 8.4;
run;


title "WBS 5-4. 라벨별 내부 타당도";

proc print data=crm.w5_val_label_quality noobs;
    format noise_pct min_cluster_pct 8.2 silhouette davies_bouldin 8.4 calinski_harabasz comma10.1;
run;


title "WBS 5-5. RFMP 등급 x K-Means 교차표";

proc freq data=crm.w5_val_crosstab;
    tables rfmp_tier * kmeans_cluster / norow nocol nopercent nocum;
    weight customers;
run;


title "WBS 5-6. RFMP 등급 검증";

proc print data=crm.w5_val_tier_tests noobs;
    format spearman_rho epsilon_sq kruskal_p spearman_p 8.4 kruskal_h 10.2;
run;

title;


/*==========================================================
  RFMP 가중치와 Recency 반영 정도 확인

  1) R/F/M/P 최종 가중치            (CRM.W3_RFMP_WEIGHTS_PY)
  2) 가중치의 근거가 된 지표별 군집 CV (CRM.W3_RFMP_CLUSTER_CV_PY)
  3) 점수 간 Spearman 상관           (CRM.W3_CUSTOMER_RFMP_PY)
       r_score 가 f/m/p_score 와 얼마나 따로 움직이는지,
       각 점수가 rfmp_score 와 얼마나 같이 움직이는지
  4) 등급별 Recency 평균/중앙값      (CRM.W5_VAL_TIER_PROFILE, 있으면)

  읽는 법
    - final_weight 가 작을수록 그 지표가 rfmp_score(등급)에 덜 반영됩니다.
    - 가중치는 "군집 안에서 값이 얼마나 일정한가(CV가 작을수록 큼)"로 만든
      값이라 지표의 중요도가 아니라 일관성을 나타냅니다.
    - 3번에서 rfmp_score 와의 상관이 지표별로 얼마나 다른지 보면
      실제로 등급을 움직이는 지표가 무엇인지 알 수 있습니다.
==========================================================*/

options validvarname=any;

%let CRM_PATH = /home/student/crm_db;
libname crm "&CRM_PATH.";


%macro require_table(ds=);

    %if %sysfunc(exist(&ds.)) = 0 %then %do;
        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %abort cancel;
    %end;

    %else %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;

%mend require_table;

%require_table(ds=crm.w3_rfmp_weights_py);
%require_table(ds=crm.w3_rfmp_cluster_cv_py);
%require_table(ds=crm.w3_customer_rfmp_py);


title "1. R/F/M/P 최종 가중치";

proc print data=crm.w3_rfmp_weights_py noobs;
    format weighted_cv raw_weight 10.6 final_weight percent8.2;
run;


title "2. 지표별 군집 CV (가중치의 근거)";

proc print data=crm.w3_rfmp_cluster_cv_py noobs;
    var metric cluster cluster_n mean_value std_value cv;
    format mean_value std_value comma14.2 cv 10.4;
run;


title "3. 점수 간 Spearman 상관";

proc corr data=crm.w3_customer_rfmp_py spearman nosimple;
    var r_score f_score m_score p_score rfmp_score;
run;


%macro tier_recency;

    %if %sysfunc(exist(crm.w5_val_tier_profile)) %then %do;

        title "4. 등급별 Recency 평균과 중앙값";

        proc print data=crm.w5_val_tier_profile noobs;
            var rfmp_tier tier_rank customers recency_mean recency_median rfmp_score_mean;
            format recency_mean recency_median rfmp_score_mean 10.2;
        run;

    %end;

    %else %put NOTE: CRM.W5_VAL_TIER_PROFILE 이(가) 없어 4번은 건너뜁니다.;

%mend tier_recency;

%tier_recency;

title;


/*====================================================================
  WBS 5b. K-Means 군집 프로파일 + Recency 반영 what-if
  파일명: WBS_5b_Cluster_Profile_Recency.sas

  A. K-Means(K=6) 군집별 프로파일
     - WBS_5_Final_Table_Validation.sas 와 같은 특성, 같은 설정(seed 2026,
       k-means++, n_init=50)으로 군집을 다시 만들고 군집 번호는
       rfmp_score 평균이 낮은 순서대로 1~6 으로 붙임
     - 원 단위 평균/중앙값, 표준화 평균(z), 대표 등급, 특징 요약
     - 이웃한 군집(1-2, 2-3, ... 5-6)이 어떤 변수로 갈리는지 Cohen's d 로 비교
       (특히 2-3, 4-5)
     - 고객별 군집 번호를 CRM.W5_VAL_KMEANS_LABELS 로 저장
  B. Recency 반영 what-if
     - 현재 가중치(CRM.W3_RFMP_WEIGHTS_PY)와 대안 가중치로 rfmp_score 를
       다시 계산해 등급을 새로 나눴을 때
         등급이 얼마나 바뀌는지, 등급별 Recency 평균이 순서대로 줄어드는지
       를 비교. 시나리오 가중치는 민감도 확인용 임의 설정이며 정답이 아님.

  입력: CRM.W3_CUSTOMER_RFMP_PY, CRM.W3_RFMP_WEIGHTS_PY
====================================================================*/

options validvarname=any;

%let CRM_PATH       = /home/student/crm_db;
libname crm "&CRM_PATH.";

%let SEED           = 2026;
%let K_FINAL        = 6;

/* WBS 5 결과에서 확인된 군집별 고객 수(군집 1~6). 재현 여부 확인용 */
%let EXPECTED_SIZES = 161 263 250 360 193 241;


%macro require_table(ds=);

    %if %sysfunc(exist(&ds.)) = 0 %then %do;
        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %abort cancel;
    %end;

    %else %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;

%mend require_table;

%require_table(ds=crm.w3_customer_rfmp_py);
%require_table(ds=crm.w3_rfmp_weights_py);


proc datasets library=crm nolist nowarn;
    delete
        w5_val_kmeans_labels
        w5_val_cluster_profile
        w5_val_cluster_pair_diff
        w5_recency_whatif
        w5_recency_whatif_by_tier;
quit;


proc python restart;
submit;

import os

os.environ["OMP_NUM_THREADS"] = "1"
os.environ["OPENBLAS_NUM_THREADS"] = "1"
os.environ["MKL_NUM_THREADS"] = "1"

import warnings

warnings.filterwarnings("ignore")

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

from scipy import stats
from sklearn.cluster import KMeans
from sklearn.preprocessing import StandardScaler


# --------------------------------------------------------------------
# 0. 설정과 공통 함수
# --------------------------------------------------------------------

SEED = int(float(str(SAS.symget("SEED")).strip()))
K_FINAL = int(float(str(SAS.symget("K_FINAL")).strip()))
OUT_DIR = str(SAS.symget("CRM_PATH")).strip()

expected_text = str(SAS.symget("EXPECTED_SIZES")).strip()
EXPECTED_SIZES = [int(value) for value in expected_text.split()] if expected_text else []

TIER_ORDER = ["Bronze", "Silver", "Gold", "Platinum", "Diamond", "VIP"]
TIER_RANK = {name: number + 1 for number, name in enumerate(TIER_ORDER)}

FEATURES = ["recency", "log_frequency", "log_monetary", "log_product_value_p"]
RAW_FEATURES = ["recency", "frequency", "monetary", "product_value_p"]

FEATURE_KOREAN = {
    "recency": "마지막 구매 후 경과일",
    "log_frequency": "구매 횟수",
    "log_monetary": "구매 금액",
    "log_product_value_p": "제품가치"
}

FOCUS_PAIRS = [(2, 3), (4, 5)]


def save_sas(frame, table_name):
    output = frame.reset_index(drop=True).copy()
    for column in output.columns:
        if output[column].dtype == object:
            output[column] = output[column].astype(str)
    SAS.df2sd(output, dataset=f"crm.{table_name}")


def relabel_by_score(labels, score):
    labels = np.asarray(labels)
    result = labels.copy()
    order = sorted(
        np.unique(labels),
        key=lambda value: float(np.mean(score[labels == value]))
    )
    for new_number, old_number in enumerate(order, start=1):
        result[labels == old_number] = new_number
    return result


def draw_and_save(figure_name):
    path = os.path.join(OUT_DIR, figure_name)
    try:
        plt.savefig(path, dpi=150, bbox_inches="tight")
    except Exception as error:
        print(f"그림 파일 저장 실패({figure_name}): {error}")
    SAS.pyplot(plt)
    plt.close("all")


print("=" * 72)
print("WBS 5b. 군집 프로파일 + Recency 반영 what-if")
print("=" * 72)


# --------------------------------------------------------------------
# 1. 데이터 준비
# --------------------------------------------------------------------

df = SAS.sd2df("crm.w3_customer_rfmp_py")
df.columns = [str(column).strip().lower() for column in df.columns]

required = (
    ["customer_id", "rfmp_score", "rfmp_tier",
     "r_score", "f_score", "m_score", "p_score"]
    + FEATURES + RAW_FEATURES
)

missing_columns = [column for column in required if column not in df.columns]

if missing_columns:
    raise ValueError("필수 변수가 없습니다: " + ", ".join(missing_columns))

for column in FEATURES + RAW_FEATURES + ["rfmp_score", "r_score", "f_score", "m_score", "p_score"]:
    df[column] = pd.to_numeric(df[column], errors="coerce")

df["rfmp_tier"] = df["rfmp_tier"].astype(str).str.strip()

unknown_tiers = sorted(set(df["rfmp_tier"]) - set(TIER_ORDER))

if unknown_tiers:
    raise ValueError("알 수 없는 등급이 있습니다: " + ", ".join(unknown_tiers))

if df[FEATURES + RAW_FEATURES + ["rfmp_score"]].isna().any().any():
    raise ValueError("특성 또는 점수에 결측값이 있습니다.")

df["tier_rank"] = df["rfmp_tier"].map(TIER_RANK).astype(int)

n_customers = len(df)
score = df["rfmp_score"].to_numpy(dtype=float)

X = StandardScaler().fit_transform(df[FEATURES].to_numpy(dtype=float))


# --------------------------------------------------------------------
# 2. A. K-Means 재현과 군집 프로파일
# --------------------------------------------------------------------

km = KMeans(
    n_clusters=K_FINAL,
    init="k-means++",
    n_init=50,
    random_state=SEED
).fit(X)

km_labels = relabel_by_score(km.labels_, score)
df["kmeans_cluster"] = km_labels

sizes = [int((km_labels == c).sum()) for c in range(1, K_FINAL + 1)]

print(f"군집 크기(1~{K_FINAL}): {sizes}")

if EXPECTED_SIZES:
    if sizes == EXPECTED_SIZES:
        print("WBS 5 결과와 군집 크기가 같습니다(재현 확인).")
    else:
        print(f"주의: WBS 5 결과의 군집 크기 {EXPECTED_SIZES} 와 다릅니다. 프로파일을 WBS 5 교차표와 직접 대응시키지 마십시오.")

save_sas(
    df[["customer_id", "rfmp_tier", "kmeans_cluster"]],
    "w5_val_kmeans_labels"
)

profile_rows = []

for c in range(1, K_FINAL + 1):

    mask = km_labels == c
    part = df[mask]

    row = {
        "kmeans_cluster": c,
        "customers": int(mask.sum()),
        "pct": float(100.0 * mask.mean()),
        "rfmp_score_mean": float(part["rfmp_score"].mean())
    }

    for column in RAW_FEATURES:
        row[f"{column}_mean"] = float(part[column].mean())
        row[f"{column}_median"] = float(part[column].median())

    z_values = {}

    for j, column in enumerate(FEATURES):
        z_values[column] = float(X[mask, j].mean())
        row[f"z_{column}"] = z_values[column]

    counts = part["rfmp_tier"].value_counts()
    row["dominant_tier"] = str(counts.index[0])
    row["dominant_tier_pct"] = float(100.0 * counts.iloc[0] / len(part))

    words = []

    for column in FEATURES:
        z = z_values[column]
        if z >= 0.5:
            words.append(f"{FEATURE_KOREAN[column]} 높음")
        elif z <= -0.5:
            words.append(f"{FEATURE_KOREAN[column]} 낮음")

    row["signature"] = ", ".join(words) if words else "모든 특성이 평균 근처"

    profile_rows.append(row)

profile = pd.DataFrame(profile_rows)

save_sas(profile, "w5_val_cluster_profile")

print("[A-1] 군집 프로파일 완료")


# --------------------------------------------------------------------
# 3. 이웃 군집 비교 (Cohen's d)
# --------------------------------------------------------------------

pair_rows = []

for a in range(1, K_FINAL):

    b = a + 1
    mask_a = km_labels == a
    mask_b = km_labels == b

    pair_records = []

    for j, column in enumerate(FEATURES):

        xa = X[mask_a, j]
        xb = X[mask_b, j]

        pooled_var = (
            (len(xa) - 1) * xa.var(ddof=1) + (len(xb) - 1) * xb.var(ddof=1)
        ) / (len(xa) + len(xb) - 2)

        pooled_sd = float(np.sqrt(pooled_var))
        d = float((xb.mean() - xa.mean()) / pooled_sd) if pooled_sd > 0 else np.nan

        pair_records.append({
            "pair": f"{a} vs {b}",
            "cluster_a": a,
            "cluster_b": b,
            "feature": column,
            "z_mean_a": float(xa.mean()),
            "z_mean_b": float(xb.mean()),
            "diff_z": float(xb.mean() - xa.mean()),
            "cohens_d": d,
            "focus_pair": int((a, b) in FOCUS_PAIRS)
        })

    abs_d = np.array([abs(record["cohens_d"]) for record in pair_records])
    order = (-abs_d).argsort().argsort() + 1

    for record, rank_number in zip(pair_records, order):
        record["abs_d_rank"] = int(rank_number)
        pair_rows.append(record)

pair_diff = pd.DataFrame(pair_rows)

save_sas(pair_diff, "w5_val_cluster_pair_diff")

print("[A-2] 이웃 군집 비교 완료")


# --------------------------------------------------------------------
# 4. A 그림: 군집 프로파일 히트맵, 등급/군집별 Recency 분포
# --------------------------------------------------------------------

fig, axes = plt.subplots(1, 3, figsize=(18, 5.8), gridspec_kw={"width_ratios": [1.15, 1, 1]})

heat = profile[[f"z_{column}" for column in FEATURES]].to_numpy(dtype=float)
image = axes[0].imshow(heat, cmap="RdBu_r", vmin=-1.5, vmax=1.5, aspect="auto")

axes[0].set_xticks(range(len(FEATURES)))
axes[0].set_xticklabels(["Recency", "Frequency(log)", "Monetary(log)", "Product value(log)"], rotation=25, ha="right")
axes[0].set_yticks(range(K_FINAL))
axes[0].set_yticklabels([f"C{int(c)} (n={int(n)})" for c, n in zip(profile["kmeans_cluster"], profile["customers"])])

for row_number in range(K_FINAL):
    for column_number in range(len(FEATURES)):
        cell_value = heat[row_number, column_number]
        axes[0].text(column_number, row_number, f"{cell_value:.2f}", ha="center", va="center",
                     color="white" if abs(cell_value) >= 1.0 else "black")

axes[0].set_title("Cluster mean of standardized features")
fig.colorbar(image, ax=axes[0])

tier_groups = [df.loc[df["tier_rank"] == r, "recency"].to_numpy() for r in range(1, 7)]
axes[1].boxplot(tier_groups, showfliers=False)
axes[1].set_xticklabels(TIER_ORDER, rotation=25, ha="right")
axes[1].set_title("Recency (days) by RFMP tier")
axes[1].grid(alpha=0.3)

cluster_groups = [df.loc[df["kmeans_cluster"] == c, "recency"].to_numpy() for c in range(1, K_FINAL + 1)]
axes[2].boxplot(cluster_groups, showfliers=False)
axes[2].set_xticklabels([f"C{c}" for c in range(1, K_FINAL + 1)])
axes[2].set_title("Recency (days) by K-Means cluster")
axes[2].grid(alpha=0.3)

plt.tight_layout()
draw_and_save("w5b_cluster_profile.png")


# --------------------------------------------------------------------
# 5. B. Recency 반영 what-if
# --------------------------------------------------------------------

weights_table = SAS.sd2df("crm.w3_rfmp_weights_py")
weights_table.columns = [str(column).strip().lower() for column in weights_table.columns]

current_weights = {
    str(metric).strip().upper(): float(weight)
    for metric, weight in zip(weights_table["metric"], weights_table["final_weight"])
}

if set(current_weights) != {"R", "F", "M", "P"}:
    raise ValueError("가중치 표에 R/F/M/P 네 지표가 모두 있어야 합니다: " + str(current_weights))


def normalized(weights):
    total = sum(weights.values())
    return {key: value / total for key, value in weights.items()}


others = {key: value for key, value in current_weights.items() if key != "R"}
scale = 0.60 / sum(others.values())

scenarios = {
    "BASE": current_weights,
    "EQUAL": {"R": 0.25, "F": 0.25, "M": 0.25, "P": 0.25},
    "R_DOUBLE": normalized({**current_weights, "R": current_weights["R"] * 2}),
    "R_40": {"R": 0.40, **{key: value * scale for key, value in others.items()}}
}

score_columns = {"R": "r_score", "F": "f_score", "M": "m_score", "P": "p_score"}

whatif_rows = []
by_tier_rows = []
mean_by_scenario = {}

for name, weights in scenarios.items():

    new_score = sum(weights[key] * df[column].to_numpy(dtype=float) for key, column in score_columns.items())

    order = pd.Series(new_score).rank(method="first")
    new_rank = (pd.qcut(order, 6, labels=False) + 1).to_numpy().astype(int)

    old_rank = df["tier_rank"].to_numpy()
    recency = df["recency"].to_numpy(dtype=float)

    tier_means = [float(recency[new_rank == r].mean()) for r in range(1, 7)]
    monotonic = bool(np.all(np.diff(tier_means) < 0))

    groups = [recency[new_rank == r] for r in range(1, 7)]
    h_stat, _ = stats.kruskal(*groups)
    rho = float(stats.spearmanr(new_rank, recency)[0])

    row = {
        "scenario": name,
        "w_recency": float(weights["R"]),
        "w_frequency": float(weights["F"]),
        "w_monetary": float(weights["M"]),
        "w_product": float(weights["P"]),
        "same_tier_pct": float(100.0 * (new_rank == old_rank).mean()),
        "moved_2plus_pct": float(100.0 * (np.abs(new_rank - old_rank) >= 2).mean()),
        "spearman_tier_recency": rho,
        "recency_epsilon_sq": float(h_stat / (n_customers - 1)),
        "recency_monotonic": int(monotonic),
        "recency_mean_bronze": tier_means[0],
        "recency_mean_vip": tier_means[-1]
    }

    if name == "BASE":
        row["max_abs_diff_vs_rfmp_score"] = float(np.max(np.abs(new_score - score)))
    else:
        row["max_abs_diff_vs_rfmp_score"] = np.nan

    whatif_rows.append(row)
    mean_by_scenario[name] = tier_means

    for r in range(1, 7):
        by_tier_rows.append({
            "scenario": name,
            "tier_rank": r,
            "rfmp_tier": TIER_ORDER[r - 1],
            "customers": int((new_rank == r).sum()),
            "recency_mean": tier_means[r - 1],
            "recency_median": float(np.median(recency[new_rank == r]))
        })

whatif = pd.DataFrame(whatif_rows)
whatif_by_tier = pd.DataFrame(by_tier_rows)

save_sas(whatif, "w5_recency_whatif")
save_sas(whatif_by_tier, "w5_recency_whatif_by_tier")

base_check = float(whatif.loc[whatif["scenario"] == "BASE", "max_abs_diff_vs_rfmp_score"].iloc[0])

print(f"[B] what-if 완료. BASE 가중치로 다시 계산한 점수와 rfmp_score 의 최대 차이: {base_check:.6f}")

if base_check > 1e-6:
    print("주의: 저장된 rfmp_score 가 이 가중치/점수 조합으로 재현되지 않습니다. 가중치 표 또는 점수 컬럼을 확인하십시오.")


fig, ax = plt.subplots(figsize=(8.5, 5.5))

for name, means in mean_by_scenario.items():
    ax.plot(range(1, 7), means, marker="o", label=name)

ax.set_xticks(range(1, 7))
ax.set_xticklabels(TIER_ORDER)
ax.set_ylabel("Mean recency (days)")
ax.set_title("Mean recency by tier under alternative recency weights")
ax.grid(alpha=0.3)
ax.legend()

plt.tight_layout()
draw_and_save("w5b_recency_whatif.png")


# --------------------------------------------------------------------
# 6. 마크다운 리포트
# --------------------------------------------------------------------

lines = []
lines.append("# WBS 5b. 군집 프로파일과 Recency 반영 what-if")
lines.append("")
lines.append("## 1. K-Means 군집 프로파일 (군집 번호는 rfmp_score 평균이 낮은 순서)")
lines.append("")
lines.append("| 군집 | 고객 수 | 비율(%) | Recency 평균 | Frequency 평균 | Monetary 평균 | 제품가치 평균 | 대표 등급 | 특징 |")
lines.append("| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :--- | :--- |")

for _, row in profile.iterrows():
    lines.append(
        f"| {int(row['kmeans_cluster'])} | {int(row['customers'])} | {row['pct']:.1f} | "
        f"{row['recency_mean']:.1f} | {row['frequency_mean']:.1f} | {row['monetary_mean']:,.0f} | "
        f"{row['product_value_p_mean']:.1f} | {row['dominant_tier']} ({row['dominant_tier_pct']:.0f}%) | {row['signature']} |"
    )

lines.append("")
lines.append("## 2. 이웃 군집을 가르는 변수 (|Cohen's d| 가 큰 순서)")
lines.append("")
lines.append("| 비교 | 1순위 변수 (d) | 2순위 변수 (d) | 비고 |")
lines.append("| :---: | :--- | :--- | :--- |")

for a in range(1, K_FINAL):
    part = pair_diff[(pair_diff["cluster_a"] == a)].sort_values("abs_d_rank")
    first = part.iloc[0]
    second = part.iloc[1]
    note = "관심 비교" if int(first["focus_pair"]) == 1 else ""
    lines.append(
        f"| {a} vs {a + 1} | {first['feature']} ({first['cohens_d']:+.2f}) | "
        f"{second['feature']} ({second['cohens_d']:+.2f}) | {note} |"
    )

lines.append("")
lines.append("Cohen's d 는 표준화 특성 기준이며 (뒤 군집 평균 - 앞 군집 평균) / 합동 표준편차입니다. 절댓값 0.2 작음, 0.5 중간, 0.8 큼이 일반적인 기준입니다.")
lines.append("")
lines.append("## 3. Recency 가중치 what-if")
lines.append("")
lines.append("| 시나리오 | R 가중치 | F | M | P | 등급 유지(%) | 2단계 이상 이동(%) | Spearman(등급, Recency) | 등급순 Recency 단조 |")
lines.append("| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |")

for _, row in whatif.iterrows():
    lines.append(
        f"| {row['scenario']} | {row['w_recency']:.3f} | {row['w_frequency']:.3f} | {row['w_monetary']:.3f} | "
        f"{row['w_product']:.3f} | {row['same_tier_pct']:.1f} | {row['moved_2plus_pct']:.1f} | "
        f"{row['spearman_tier_recency']:.3f} | {'예' if row['recency_monotonic'] == 1 else '아니오'} |"
    )

lines.append("")
lines.append("시나리오 가중치는 민감도 확인용 임의 설정입니다. BASE 는 현재 가중치, EQUAL 은 0.25 씩, R_DOUBLE 은 R 가중치를 2배로 올린 뒤 합이 1이 되게 조정, R_40 은 R 을 0.40 으로 두고 나머지를 현재 비율대로 나눈 값입니다.")

report_path = os.path.join(OUT_DIR, "w5b_cluster_profile_report.md")

try:
    with open(report_path, "w", encoding="utf-8") as report_file:
        report_file.write("\n".join(lines) + "\n")
    print(f"리포트 저장: {report_path}")
except Exception as error:
    print(f"리포트 저장 실패: {error}")

print("\n[군집 프로파일]")
print(profile[["kmeans_cluster", "customers", "recency_mean", "frequency_mean", "monetary_mean", "dominant_tier", "signature"]].round(2).to_string(index=False))
print("\n[what-if]")
print(whatif.round(3).to_string(index=False))
print("\nWBS 5b 가 끝났습니다.")

endsubmit;
quit;


%macro check_outputs;

    %local missing_count;
    %let missing_count = 0;

    %if %sysfunc(exist(crm.w5_val_kmeans_labels))       = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5_val_cluster_profile))     = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5_val_cluster_pair_diff))   = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5_recency_whatif))          = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5_recency_whatif_by_tier))  = 0 %then %let missing_count = %eval(&missing_count. + 1);

    %if &missing_count. > 0 %then
        %put ERROR: WBS 5b 산출물 &missing_count.개가 생성되지 않았습니다. 위쪽 PROC PYTHON 로그를 확인하십시오.;
    %else
        %put NOTE: WBS 5b 산출물 5개를 확인했습니다.;

%mend check_outputs;

%check_outputs;


title "WBS 5b-1. K-Means 군집 프로파일";

proc print data=crm.w5_val_cluster_profile noobs;
    var kmeans_cluster customers pct
        recency_mean frequency_mean monetary_mean product_value_p_mean
        z_recency z_log_frequency z_log_monetary z_log_product_value_p
        dominant_tier dominant_tier_pct signature;
    format pct dominant_tier_pct 8.1
           recency_mean frequency_mean product_value_p_mean 10.1
           monetary_mean comma14.0
           z_recency z_log_frequency z_log_monetary z_log_product_value_p 8.2;
run;


title "WBS 5b-2. 이웃 군집 비교 (Cohen's d)";

proc print data=crm.w5_val_cluster_pair_diff noobs;
    var pair feature z_mean_a z_mean_b diff_z cohens_d abs_d_rank focus_pair;
    format z_mean_a z_mean_b diff_z cohens_d 8.2;
run;


title "WBS 5b-3. Recency 가중치 what-if";

proc print data=crm.w5_recency_whatif noobs;
    format w_recency w_frequency w_monetary w_product 8.3
           same_tier_pct moved_2plus_pct 8.1
           spearman_tier_recency recency_epsilon_sq 8.4
           recency_mean_bronze recency_mean_vip max_abs_diff_vs_rfmp_score 10.2;
run;


title "WBS 5b-4. 시나리오별 등급별 Recency";

proc print data=crm.w5_recency_whatif_by_tier noobs;
    format recency_mean recency_median 10.2;
run;

title;


/*====================================================================
  WBS 5c. 활동/휴면 축 도입 전 확인 (등급은 그대로 두고 상태 축만 추가)
  파일명: WBS_5c_Activity_Axis_Checks.sas

  확인 1. 상대위험 등급(4.2)과 Recency 는 얼마나 같은 정보인가
          -> 위험 축과 상태 축이 중복이면 상태 축을 따로 만들 이유가 줄어듦
  확인 2. 단순 Recency 규칙만으로 90일 이탈을 얼마나 맞히는가
          -> 4.1 모델의 VALID AUC 와 비교
  확인 3. 10/02 이후 첫 구매 고객과 1회 구매 고객이 K-Means 군집 어디에 몰려 있는가
          -> 이들은 Recency 가 구조적으로 짧아 "활동"으로 잘못 분류될 위험이 있음
  확인 4. 활동/휴면 경계일 후보 (K-Means 군집 기준, 이탈률 기준)
  확인 5. 상태 3단계(활동 / 휴면 / 신규·1회 구매) 미리보기
          -> 등급 x 상태, 위험등급 x 상태 표에서 희소 칸(30명 미만) 확인

  입력 테이블
    CRM.W3_CUSTOMER_RFMP_PY   등급, 지표 (고객당 1행)
    CRM.W5_VAL_KMEANS_LABELS  WBS 5b 에서 저장한 K-Means 군집 번호
    CRM.W2_RFM                첫 구매일, 마지막 구매일
    CRM.W4_CUSTOMER_ACTION_PLAN  상대위험 등급, 이탈확률 (4.2)
    CRM.W3_CHURN_SPLIT_V2     TRAIN/VALID 스냅샷 Recency 와 이탈 라벨 (3.2)
    CRM.W4_MODEL_COMPARISON   4.1 모델의 VALID 성능

  주의
    - 아래 기본값(활동/휴면 군집 번호, 신규 기준일)은 WBS 5b 결과를 보고
      정한 값이므로 군집 번호가 다르게 재현되면 반드시 고쳐서 쓰십시오.
    - 결과 표는 "결정 전 확인용" 이며 상태 정의를 확정하는 코드가 아닙니다.
====================================================================*/

options validvarname=any;

%let CRM_PATH          = /home/student/crm_db;
libname crm "&CRM_PATH.";

/* 군집 번호(WBS 5b 프로파일 기준): 최근 구매 활발 = 2 4 6, 휴면 = 3 5, 1회 구매 = 1 */
%let ACTIVE_CLUSTERS   = 2 4 6;
%let DORMANT_CLUSTERS  = 3 5;

/* 이 날짜 이후 처음 구매한 고객을 "신규"로 봄 (3.2 의 VALID 기준일과 같음) */
%let NEW_CUTOFF        = 2019-10-02;

/* 휴면 판정 일수(마지막 구매 후 경과일이 이 값 이상이면 휴면).
   비워 두면 K-Means 군집 기준으로 계산한 값을 씁니다. */
%let DORMANT_DAYS      =;

/* 등급 x 상태 표에서 희소 칸으로 표시할 최소 고객 수 */
%let MIN_CELL          = 30;


%macro require_table(ds=);

    %if %sysfunc(exist(&ds.)) = 0 %then %do;
        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %abort cancel;
    %end;

    %else %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;

%mend require_table;

%require_table(ds=crm.w3_customer_rfmp_py);
%require_table(ds=crm.w5_val_kmeans_labels);
%require_table(ds=crm.w2_rfm);
%require_table(ds=crm.w4_customer_action_plan);
%require_table(ds=crm.w3_churn_split_v2);
%require_table(ds=crm.w4_model_comparison);


proc datasets library=crm nolist nowarn;
    delete
        w5c_risk_recency
        w5c_risk_recency_by_grade
        w5c_recency_auc
        w5c_recency_rules
        w5c_recency_bins
        w5c_new_by_cluster
        w5c_threshold_candidates
        w5c_state_preview
        w5c_state_by_tier
        w5c_state_by_risk
        w5c_state_by_cluster
        w5c_customer_state_preview;
quit;


proc python restart;
submit;

import os

os.environ["OMP_NUM_THREADS"] = "1"
os.environ["OPENBLAS_NUM_THREADS"] = "1"
os.environ["MKL_NUM_THREADS"] = "1"

import warnings

warnings.filterwarnings("ignore")

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

from scipy import stats
from sklearn.metrics import roc_auc_score, roc_curve


# --------------------------------------------------------------------
# 0. 설정과 공통 함수
# --------------------------------------------------------------------

OUT_DIR = str(SAS.symget("CRM_PATH")).strip()
ACTIVE_CLUSTERS = [int(v) for v in str(SAS.symget("ACTIVE_CLUSTERS")).split()]
DORMANT_CLUSTERS = [int(v) for v in str(SAS.symget("DORMANT_CLUSTERS")).split()]
NEW_CUTOFF = pd.Timestamp(str(SAS.symget("NEW_CUTOFF")).strip())
MIN_CELL = int(float(str(SAS.symget("MIN_CELL")).strip()))

dormant_days_text = str(SAS.symget("DORMANT_DAYS")).strip()
DORMANT_DAYS_OVERRIDE = int(float(dormant_days_text)) if dormant_days_text else None

TIER_ORDER = ["Bronze", "Silver", "Gold", "Platinum", "Diamond", "VIP"]


def lower_columns(frame):
    frame = frame.copy()
    frame.columns = [str(column).strip().lower() for column in frame.columns]
    return frame


def save_sas(frame, table_name):
    output = frame.reset_index(drop=True).copy()
    for column in output.columns:
        if output[column].dtype == object:
            output[column] = output[column].astype(str)
    SAS.df2sd(output, dataset=f"crm.{table_name}")


def sas_date_to_datetime(series):
    if pd.api.types.is_datetime64_any_dtype(series):
        return pd.to_datetime(series)
    numeric = pd.to_numeric(series, errors="coerce")
    if numeric.notna().mean() >= 0.90:
        return pd.to_datetime(numeric, unit="D", origin="1960-01-01", errors="coerce")
    return pd.to_datetime(series, errors="coerce")


def draw_and_save(figure_name):
    path = os.path.join(OUT_DIR, figure_name)
    try:
        plt.savefig(path, dpi=150, bbox_inches="tight")
    except Exception as error:
        print(f"그림 파일 저장 실패({figure_name}): {error}")
    SAS.pyplot(plt)
    plt.close("all")


def youden_cut(y_true, score):
    """score >= 컷 이면 양성으로 볼 때 Youden J 가 최대인 컷과 그때의 지표."""
    fpr, tpr, thresholds = roc_curve(y_true, score)
    j = tpr - fpr
    best = int(np.argmax(j))
    return float(thresholds[best]), float(j[best]), float(tpr[best]), float(1 - fpr[best])


print("=" * 72)
print("WBS 5c. 활동/휴면 축 도입 전 확인")
print("=" * 72)


# --------------------------------------------------------------------
# 1. 데이터 준비
# --------------------------------------------------------------------

base = lower_columns(SAS.sd2df("crm.w3_customer_rfmp_py"))
labels = lower_columns(SAS.sd2df("crm.w5_val_kmeans_labels"))
w2 = lower_columns(SAS.sd2df("crm.w2_rfm"))
risk = lower_columns(SAS.sd2df("crm.w4_customer_action_plan"))
split = lower_columns(SAS.sd2df("crm.w3_churn_split_v2"))
model_cmp = lower_columns(SAS.sd2df("crm.w4_model_comparison"))

for frame in (base, labels, w2, risk):
    frame["customer_id"] = frame["customer_id"].astype(str).str.strip()

split["split_role"] = split["split_role"].astype(str).str.strip().str.upper()

base = base[["customer_id", "recency", "frequency", "monetary", "rfmp_score", "rfmp_tier"]].copy()

for column in ["recency", "frequency", "monetary", "rfmp_score"]:
    base[column] = pd.to_numeric(base[column], errors="coerce")

base["rfmp_tier"] = base["rfmp_tier"].astype(str).str.strip()

w2 = w2[["customer_id", "first_purchase_date", "last_purchase_date"]].copy()
w2["first_purchase_date"] = sas_date_to_datetime(w2["first_purchase_date"])
w2["last_purchase_date"] = sas_date_to_datetime(w2["last_purchase_date"])

cust = (
    base
    .merge(labels[["customer_id", "kmeans_cluster"]], on="customer_id", how="left", validate="one_to_one")
    .merge(w2, on="customer_id", how="left", validate="one_to_one")
    .merge(
        risk[["customer_id", "relative_risk_grade", "final_churn_probability"]],
        on="customer_id", how="left", validate="one_to_one"
    )
)

n_customers = len(cust)

missing_cluster = int(cust["kmeans_cluster"].isna().sum())
missing_first = int(cust["first_purchase_date"].isna().sum())
missing_risk = int(cust["relative_risk_grade"].isna().sum())

print(f"고객 {n_customers:,}명 (군집 결측 {missing_cluster}, 첫 구매일 결측 {missing_first}, 위험등급 결측 {missing_risk})")

if missing_cluster > 0 or missing_first > 0:
    raise ValueError("군집 또는 첫 구매일이 없는 고객이 있습니다. WBS 5b 결과와 W2_RFM 을 확인하십시오.")

cust["kmeans_cluster"] = cust["kmeans_cluster"].astype(int)
cust["relative_risk_grade"] = cust["relative_risk_grade"].fillna("UNSCORED").astype(str).str.strip()


# --------------------------------------------------------------------
# 2. 확인 1: 상대위험 등급 / 이탈확률 과 Recency
# --------------------------------------------------------------------

scored = cust[cust["relative_risk_grade"] != "UNSCORED"].copy()

summary_rows = []

for column in ["recency", "frequency", "monetary", "rfmp_score"]:
    rho, p_value = stats.spearmanr(scored["final_churn_probability"], scored[column])
    summary_rows.append({
        "check": "1. 이탈확률과의 Spearman 상관",
        "variable": column,
        "rho": float(rho),
        "p_value": float(p_value),
        "n": int(len(scored))
    })

risk_recency = pd.DataFrame(summary_rows)

save_sas(risk_recency, "w5c_risk_recency")

grade_order = ["Low", "Medium", "High"]
grade_rows = []

for grade in grade_order:
    part = scored[scored["relative_risk_grade"] == grade]
    grade_rows.append({
        "relative_risk_grade": grade,
        "customers": int(len(part)),
        "recency_mean": float(part["recency"].mean()),
        "recency_median": float(part["recency"].median()),
        "recency_p25": float(part["recency"].quantile(0.25)),
        "recency_p75": float(part["recency"].quantile(0.75)),
        "mean_churn_probability": float(part["final_churn_probability"].mean())
    })

risk_by_grade = pd.DataFrame(grade_rows)

groups = [scored.loc[scored["relative_risk_grade"] == g, "recency"].to_numpy() for g in grade_order]
h_stat, _ = stats.kruskal(*groups)
risk_recency_epsilon = float(h_stat / (len(scored) - 1))
risk_by_grade["recency_epsilon_sq_all_grades"] = risk_recency_epsilon

save_sas(risk_by_grade, "w5c_risk_recency_by_grade")

rho_recency = float(risk_recency.loc[risk_recency["variable"] == "recency", "rho"].iloc[0])

print(f"[1] 이탈확률 vs Recency Spearman rho = {rho_recency:.3f}, 위험등급 간 Recency epsilon-squared = {risk_recency_epsilon:.3f}")


# --------------------------------------------------------------------
# 3. 확인 2: Recency 하나만으로 90일 이탈을 맞히는 정도
# --------------------------------------------------------------------

model_auc = np.nan
raw_rows = model_cmp[model_cmp["probability_type"].astype(str).str.upper().str.startswith("RAW")]

if len(raw_rows):
    model_auc = float(pd.to_numeric(raw_rows["roc_auc"], errors="coerce").iloc[0])

auc_rows = []

for role in ["TRAIN", "VALID"]:
    part = split[split["split_role"] == role]
    y = pd.to_numeric(part["churn_flag"], errors="coerce").astype(int).to_numpy()
    x = pd.to_numeric(part["recency"], errors="coerce").to_numpy(dtype=float)

    cut, j_value, tpr, tnr = youden_cut(y, x)

    auc_rows.append({
        "dataset_role": role,
        "customers": int(len(part)),
        "churn_rate": float(y.mean()),
        "recency_only_auc": float(roc_auc_score(y, x)),
        "youden_cut_days": cut,
        "youden_j": j_value,
        "recall_at_cut": tpr,
        "specificity_at_cut": tnr,
        "model_valid_auc_4_1": model_auc if role == "VALID" else np.nan
    })

recency_auc = pd.DataFrame(auc_rows)

save_sas(recency_auc, "w5c_recency_auc")

valid_auc = float(recency_auc.loc[recency_auc["dataset_role"] == "VALID", "recency_only_auc"].iloc[0])

print(f"[2] Recency 단독 VALID AUC = {valid_auc:.4f} (4.1 모델 VALID AUC = {model_auc:.4f})")


rule_rows = []

for role in ["TRAIN", "VALID"]:
    part = split[split["split_role"] == role]
    y = pd.to_numeric(part["churn_flag"], errors="coerce").astype(int).to_numpy()
    x = pd.to_numeric(part["recency"], errors="coerce").to_numpy(dtype=float)
    base_rate = float(y.mean())

    for threshold in range(30, 331, 30):
        flagged = x >= threshold
        n_flagged = int(flagged.sum())

        if n_flagged == 0:
            continue

        precision = float(y[flagged].mean())

        rule_rows.append({
            "dataset_role": role,
            "recency_at_least": threshold,
            "flagged_customers": n_flagged,
            "flagged_pct": float(100.0 * n_flagged / len(y)),
            "churn_rate_flagged": precision,
            "churn_rate_not_flagged": float(y[~flagged].mean()) if (~flagged).any() else np.nan,
            "recall": float(y[flagged].sum() / max(y.sum(), 1)),
            "lift_vs_base": float(precision / base_rate)
        })

recency_rules = pd.DataFrame(rule_rows)

save_sas(recency_rules, "w5c_recency_rules")

edges = [0, 30, 60, 90, 120, 150, 180, 210, 240, 270, 300, np.inf]
bin_names = [f"{int(a)}-{int(b) - 1}" if np.isfinite(b) else f"{int(a)}+" for a, b in zip(edges[:-1], edges[1:])]

bin_rows = []

for role in ["TRAIN", "VALID"]:
    part = split[split["split_role"] == role].copy()
    part["recency"] = pd.to_numeric(part["recency"], errors="coerce")
    part["churn_flag"] = pd.to_numeric(part["churn_flag"], errors="coerce")
    part["bin"] = pd.cut(part["recency"], bins=edges, right=False, labels=bin_names)

    for bin_name in bin_names:
        sub = part[part["bin"] == bin_name]
        bin_rows.append({
            "dataset_role": role,
            "recency_bin": bin_name,
            "customers": int(len(sub)),
            "churn_rate": float(sub["churn_flag"].mean()) if len(sub) else np.nan
        })

recency_bins = pd.DataFrame(bin_rows)

save_sas(recency_bins, "w5c_recency_bins")


# --------------------------------------------------------------------
# 4. 확인 3: 신규 / 1회 구매 고객이 군집 어디에 있는가
# --------------------------------------------------------------------

cust["is_new"] = (cust["first_purchase_date"] > NEW_CUTOFF).astype(int)
cust["is_one_time"] = (cust["frequency"] == 1).astype(int)
cust["is_new_or_one"] = ((cust["is_new"] == 1) | (cust["is_one_time"] == 1)).astype(int)

total_new = int(cust["is_new"].sum())
total_one = int(cust["is_one_time"].sum())

new_rows = []

for cluster in sorted(cust["kmeans_cluster"].unique()):
    part = cust[cust["kmeans_cluster"] == cluster]
    new_part = part[part["is_new"] == 1]

    new_rows.append({
        "kmeans_cluster": int(cluster),
        "customers": int(len(part)),
        "new_customers": int(len(new_part)),
        "new_pct_of_cluster": float(100.0 * len(new_part) / len(part)),
        "share_of_all_new_pct": float(100.0 * len(new_part) / total_new) if total_new else np.nan,
        "one_time_customers": int(part["is_one_time"].sum()),
        "one_time_pct_of_cluster": float(100.0 * part["is_one_time"].mean()),
        "share_of_all_one_time_pct": float(100.0 * part["is_one_time"].sum() / total_one) if total_one else np.nan,
        "new_recency_median": float(new_part["recency"].median()) if len(new_part) else np.nan,
        "new_recency_max": float(new_part["recency"].max()) if len(new_part) else np.nan
    })

new_by_cluster = pd.DataFrame(new_rows)

save_sas(new_by_cluster, "w5c_new_by_cluster")

print(f"[3] 신규(첫 구매 {NEW_CUTOFF.date()} 이후) {total_new}명, 1회 구매 {total_one}명")


# --------------------------------------------------------------------
# 5. 확인 4: 활동/휴면 경계일 후보
# --------------------------------------------------------------------

sub_cluster = cust[cust["kmeans_cluster"].isin(ACTIVE_CLUSTERS + DORMANT_CLUSTERS)]
y_cluster = sub_cluster["kmeans_cluster"].isin(DORMANT_CLUSTERS).astype(int).to_numpy()
x_cluster = sub_cluster["recency"].to_numpy(dtype=float)

cluster_cut, cluster_j, cluster_tpr, cluster_tnr = youden_cut(y_cluster, x_cluster)

candidates = [{
    "method": "K-Means 군집 기준 (Youden J)",
    "recency_at_least": cluster_cut,
    "detail": f"휴면 군집 {DORMANT_CLUSTERS} 재현율 {cluster_tpr:.3f}, 활동 군집 {ACTIVE_CLUSTERS} 특이도 {cluster_tnr:.3f}, J {cluster_j:.3f}"
}]

for _, row in recency_auc.iterrows():
    candidates.append({
        "method": f"이탈 예측 기준 ({row['dataset_role']} Youden J)",
        "recency_at_least": float(row["youden_cut_days"]),
        "detail": f"AUC {row['recency_only_auc']:.4f}, J {row['youden_j']:.3f}"
    })

candidates.append({
    "method": "휴면 군집 하위 5% Recency",
    "recency_at_least": float(np.percentile(cust.loc[cust["kmeans_cluster"].isin(DORMANT_CLUSTERS), "recency"], 5)),
    "detail": f"휴면 군집 {DORMANT_CLUSTERS} 중 95% 가 이 값 이상"
})

candidates.append({
    "method": "활동 군집 상위 95% Recency",
    "recency_at_least": float(np.percentile(cust.loc[cust["kmeans_cluster"].isin(ACTIVE_CLUSTERS), "recency"], 95)),
    "detail": f"활동 군집 {ACTIVE_CLUSTERS} 중 95% 가 이 값 이하"
})

threshold_candidates = pd.DataFrame(candidates)

save_sas(threshold_candidates, "w5c_threshold_candidates")

DORMANT_DAYS = DORMANT_DAYS_OVERRIDE if DORMANT_DAYS_OVERRIDE is not None else int(round(cluster_cut))

print(f"[4] 미리보기에 쓰는 휴면 기준: 마지막 구매 후 {DORMANT_DAYS}일 이상 ("
      + ("직접 지정" if DORMANT_DAYS_OVERRIDE is not None else "K-Means 군집 기준") + ")")


# --------------------------------------------------------------------
# 6. 확인 5: 상태 3단계 미리보기
# --------------------------------------------------------------------

cust["state"] = np.where(
    cust["is_new_or_one"] == 1,
    "NEW_OR_ONE",
    np.where(cust["recency"] >= DORMANT_DAYS, "DORMANT", "ACTIVE")
)

state_order = ["ACTIVE", "DORMANT", "NEW_OR_ONE"]
total_monetary = float(cust["monetary"].sum())

preview_rows = []

for state in state_order:
    part = cust[cust["state"] == state]
    preview_rows.append({
        "state": state,
        "customers": int(len(part)),
        "customers_pct": float(100.0 * len(part) / n_customers),
        "monetary_share_pct": float(100.0 * part["monetary"].sum() / total_monetary),
        "recency_median": float(part["recency"].median()) if len(part) else np.nan,
        "dormant_days_used": DORMANT_DAYS
    })

state_preview = pd.DataFrame(preview_rows)

save_sas(state_preview, "w5c_state_preview")


def crosstab_long(row_col, row_order, name_row):
    table = pd.crosstab(cust[row_col], cust["state"]).reindex(index=row_order, columns=state_order).fillna(0).astype(int)
    long = table.stack().reset_index()
    long.columns = [name_row, "state", "customers"]
    long["sparse_cell"] = (long["customers"] < MIN_CELL).astype(int)
    return long


state_by_tier = crosstab_long("rfmp_tier", TIER_ORDER, "rfmp_tier")
state_by_risk = crosstab_long("relative_risk_grade", grade_order + ["UNSCORED"], "relative_risk_grade")
state_by_cluster = crosstab_long("kmeans_cluster", sorted(cust["kmeans_cluster"].unique()), "kmeans_cluster")

save_sas(state_by_tier, "w5c_state_by_tier")
save_sas(state_by_risk, "w5c_state_by_risk")
save_sas(state_by_cluster, "w5c_state_by_cluster")

preview_out = cust[[
    "customer_id", "rfmp_tier", "kmeans_cluster", "relative_risk_grade",
    "recency", "frequency", "monetary", "state"
]].copy()

# strftime 의 % 형식 문자는 SAS 매크로로 해석되므로 문자열 앞 10자리를 씁니다.
preview_out["first_purchase_date"] = cust["first_purchase_date"].astype(str).str[:10]
preview_out["dormant_days_used"] = DORMANT_DAYS

save_sas(preview_out, "w5c_customer_state_preview")

sparse_tier = int(state_by_tier["sparse_cell"].sum())

print(f"[5] 등급 x 상태 희소 칸(< {MIN_CELL}명): {sparse_tier} / {len(state_by_tier)}")
print(state_preview.round(2).to_string(index=False))


# --------------------------------------------------------------------
# 7. 그림: 이탈률 vs Recency, Recency 분포와 경계일
# --------------------------------------------------------------------

fig, axes = plt.subplots(1, 2, figsize=(14, 5.2))

for role, color in [("TRAIN", "tab:blue"), ("VALID", "tab:orange")]:
    part = recency_bins[recency_bins["dataset_role"] == role]
    axes[0].plot(range(len(part)), part["churn_rate"], marker="o", color=color, label=role)

axes[0].set_xticks(range(len(bin_names)))
axes[0].set_xticklabels(bin_names, rotation=35, ha="right")
axes[0].set_xlabel("Recency at snapshot (days)")
axes[0].set_ylabel("Observed 90-day churn rate")
axes[0].set_title("Churn rate by recency bin")
axes[0].grid(alpha=0.3)
axes[0].legend()

bins_hist = np.arange(0, 380, 15)

axes[1].hist(cust.loc[cust["kmeans_cluster"].isin(ACTIVE_CLUSTERS), "recency"], bins=bins_hist, alpha=0.6, color="tab:blue", label=f"Active clusters {ACTIVE_CLUSTERS}")
axes[1].hist(cust.loc[cust["kmeans_cluster"].isin(DORMANT_CLUSTERS), "recency"], bins=bins_hist, alpha=0.6, color="tab:red", label=f"Dormant clusters {DORMANT_CLUSTERS}")
axes[1].axvline(cluster_cut, color="black", linestyle="--", linewidth=1.2, label=f"Cluster-based cut {cluster_cut:.0f}")

valid_cut = float(recency_auc.loc[recency_auc["dataset_role"] == "VALID", "youden_cut_days"].iloc[0])
axes[1].axvline(valid_cut, color="green", linestyle=":", linewidth=1.5, label=f"VALID churn Youden cut {valid_cut:.0f}")

axes[1].set_xlabel("Recency (days since last purchase)")
axes[1].set_ylabel("Customers")
axes[1].set_title("Recency distribution by cluster group")
axes[1].legend(fontsize=8)
axes[1].grid(alpha=0.3)

plt.tight_layout()
draw_and_save("w5c_activity_axis_checks.png")

print("\nWBS 5c 확인이 끝났습니다.")

endsubmit;
quit;


%macro check_outputs;

    %local missing_count;
    %let missing_count = 0;

    %if %sysfunc(exist(crm.w5c_risk_recency))           = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5c_risk_recency_by_grade))  = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5c_recency_auc))            = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5c_recency_rules))          = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5c_recency_bins))           = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5c_new_by_cluster))         = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5c_threshold_candidates))   = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5c_state_preview))          = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5c_state_by_tier))          = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5c_state_by_risk))          = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5c_state_by_cluster))       = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5c_customer_state_preview)) = 0 %then %let missing_count = %eval(&missing_count. + 1);

    %if &missing_count. > 0 %then
        %put ERROR: WBS 5c 산출물 &missing_count.개가 생성되지 않았습니다. 위쪽 PROC PYTHON 로그를 확인하십시오.;
    %else
        %put NOTE: WBS 5c 산출물 12개를 확인했습니다.;

%mend check_outputs;

%check_outputs;


title "WBS 5c-1. 이탈확률과 지표의 Spearman 상관";

proc print data=crm.w5c_risk_recency noobs;
    format rho 8.3 p_value 10.4;
run;


title "WBS 5c-2. 상대위험 등급별 Recency";

proc print data=crm.w5c_risk_recency_by_grade noobs;
    format recency_mean recency_median recency_p25 recency_p75 10.1
           mean_churn_probability recency_epsilon_sq_all_grades 8.3;
run;


title "WBS 5c-3. Recency 단독 이탈 예측 (AUC)";

proc print data=crm.w5c_recency_auc noobs;
    format churn_rate 8.3 recency_only_auc model_valid_auc_4_1 8.4
           youden_cut_days 8.0 youden_j recall_at_cut specificity_at_cut 8.3;
run;


title "WBS 5c-4. Recency 구간별 이탈률";

proc print data=crm.w5c_recency_bins noobs;
    format churn_rate 8.3;
run;


title "WBS 5c-5. 신규 / 1회 구매 고객의 군집 분포";

proc print data=crm.w5c_new_by_cluster noobs;
    format new_pct_of_cluster share_of_all_new_pct one_time_pct_of_cluster
           share_of_all_one_time_pct 8.1 new_recency_median new_recency_max 8.0;
run;


title "WBS 5c-6. 활동/휴면 경계일 후보";

proc print data=crm.w5c_threshold_candidates noobs;
    format recency_at_least 8.1;
run;


title "WBS 5c-7. 상태 3단계 미리보기";

proc print data=crm.w5c_state_preview noobs;
    format customers_pct monetary_share_pct 8.1 recency_median 8.0;
run;


title "WBS 5c-8. 등급 x 상태 (희소 칸 표시)";

proc print data=crm.w5c_state_by_tier noobs;
run;


title "WBS 5c-9. 상대위험 등급 x 상태";

proc print data=crm.w5c_state_by_risk noobs;
run;


title "WBS 5c-10. K-Means 군집 x 상태";

proc print data=crm.w5c_state_by_cluster noobs;
run;

title;


/*====================================================================
  WBS 5d. 고객별 상태 컬럼과 재활성화 대상 명단
  파일명: WBS_5d_Customer_State_Reactivation.sas

  결정된 설계
    - RFMP 등급(Bronze ~ VIP)은 그대로 둡니다. 등급은 "얼마나 샀나" 입니다.
    - 상태는 등급 옆에 붙이는 별도 컬럼이며 "최근에 샀나" 입니다.

        상태 코드     이름           기준
        NEW_OR_ONE    신규·1회 구매  첫 구매가 NEW_CUTOFF 이후이거나 구매 횟수가 1회
        DORMANT       장기 미구매    위에 해당하지 않고 마지막 구매 후 DORMANT_DAYS 일 이상
        ACTIVE        최근 구매      나머지

    - 재활성화 명단은 상태가 DORMANT 인 고객이며 우선순위는 다음 규칙입니다.
        P1: VIP / Diamond / Platinum   P2: Gold / Silver   P3: Bronze
        같은 그룹 안에서는 과거 구매금액(monetary)이 큰 고객이 먼저
      이 우선순위는 "과거 구매 규모 우선" 이라는 업무 규칙(제안)이며
      재활성화 성공 확률을 반영한 값이 아닙니다.

  산출물 (CRM 라이브러리)
    W5D_CUSTOMER_STATE     고객별 등급, 상태, 위험등급, 우선순위
    W5D_STATE_SUMMARY      상태별 고객 수, 구매금액 비중
    W5D_TIER_BY_STATE      등급 x 상태
    W5D_TARGET_COMPARE     대상 추출 방식 비교
    W5D_PRIORITY_SUMMARY   우선순위 그룹 요약
    W5D_REACTIVATION_LIST  재활성화 명단 (우선순위 순)
  파일 (CRM_PATH 폴더)
    reactivation_list.csv, w5d_state_overview.png, w5d_state_report.md

  입력 테이블
    CRM.W3_CUSTOMER_RFMP_PY, CRM.W2_RFM, CRM.W4_CUSTOMER_ACTION_PLAN,
    CRM.W5_VAL_KMEANS_LABELS (있으면 군집 번호를 참고용으로 붙임)
====================================================================*/

options validvarname=any;

%let CRM_PATH      = /home/student/crm_db;
libname crm "&CRM_PATH.";

/* 마지막 구매 후 경과일이 이 값 이상이면 "장기 미구매" */
%let DORMANT_DAYS  = 180;

/* 이 날짜 이후 처음 구매한 고객은 "신규" (3.2 의 VALID 기준일과 같음) */
%let NEW_CUTOFF    = 2019-10-02;


%macro require_table(ds=);

    %if %sysfunc(exist(&ds.)) = 0 %then %do;
        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %abort cancel;
    %end;

    %else %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;

%mend require_table;

%require_table(ds=crm.w3_customer_rfmp_py);
%require_table(ds=crm.w2_rfm);
%require_table(ds=crm.w4_customer_action_plan);


/* 군집 번호는 있으면 참고용으로만 붙입니다. */
%global HAS_LABELS;

%macro check_labels;

    %if %sysfunc(exist(crm.w5_val_kmeans_labels)) %then %let HAS_LABELS = 1;
    %else %let HAS_LABELS = 0;

%mend check_labels;

%check_labels;


proc datasets library=crm nolist nowarn;
    delete
        w5d_customer_state
        w5d_state_summary
        w5d_tier_by_state
        w5d_target_compare
        w5d_priority_summary
        w5d_reactivation_list;
quit;


proc python restart;
submit;

import os

os.environ["OMP_NUM_THREADS"] = "1"
os.environ["OPENBLAS_NUM_THREADS"] = "1"
os.environ["MKL_NUM_THREADS"] = "1"

import warnings

warnings.filterwarnings("ignore")

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt


# --------------------------------------------------------------------
# 0. 설정과 공통 함수
# --------------------------------------------------------------------

OUT_DIR = str(SAS.symget("CRM_PATH")).strip()
DORMANT_DAYS = int(float(str(SAS.symget("DORMANT_DAYS")).strip()))
NEW_CUTOFF = pd.Timestamp(str(SAS.symget("NEW_CUTOFF")).strip())
HAS_LABELS = str(SAS.symget("HAS_LABELS")).strip() == "1"

TIER_ORDER = ["Bronze", "Silver", "Gold", "Platinum", "Diamond", "VIP"]

PRIORITY_GROUP = {
    "VIP": "P1", "Diamond": "P1", "Platinum": "P1",
    "Gold": "P2", "Silver": "P2",
    "Bronze": "P3"
}

STATE_ORDER = ["ACTIVE", "DORMANT", "NEW_OR_ONE"]

STATE_LABEL = {
    "ACTIVE": "최근 구매",
    "DORMANT": "장기 미구매",
    "NEW_OR_ONE": "신규·1회 구매"
}


def lower_columns(frame):
    frame = frame.copy()
    frame.columns = [str(column).strip().lower() for column in frame.columns]
    return frame


def save_sas(frame, table_name):
    output = frame.reset_index(drop=True).copy()
    for column in output.columns:
        if output[column].dtype == object:
            output[column] = output[column].astype(str)
    SAS.df2sd(output, dataset=f"crm.{table_name}")


def sas_date_to_datetime(series):
    if pd.api.types.is_datetime64_any_dtype(series):
        return pd.to_datetime(series)
    numeric = pd.to_numeric(series, errors="coerce")
    if numeric.notna().mean() >= 0.90:
        return pd.to_datetime(numeric, unit="D", origin="1960-01-01", errors="coerce")
    return pd.to_datetime(series, errors="coerce")


def draw_and_save(figure_name):
    path = os.path.join(OUT_DIR, figure_name)
    try:
        plt.savefig(path, dpi=150, bbox_inches="tight")
    except Exception as error:
        print(f"그림 파일 저장 실패({figure_name}): {error}")
    SAS.pyplot(plt)
    plt.close("all")


print("=" * 72)
print("WBS 5d. 고객별 상태와 재활성화 명단")
print("=" * 72)
print(f"장기 미구매 기준: {DORMANT_DAYS}일 이상, 신규 기준일: {NEW_CUTOFF.date()} 이후 첫 구매")


# --------------------------------------------------------------------
# 1. 데이터 준비
# --------------------------------------------------------------------

base = lower_columns(SAS.sd2df("crm.w3_customer_rfmp_py"))
w2 = lower_columns(SAS.sd2df("crm.w2_rfm"))
risk = lower_columns(SAS.sd2df("crm.w4_customer_action_plan"))

for frame in (base, w2, risk):
    frame["customer_id"] = frame["customer_id"].astype(str).str.strip()

base = base[["customer_id", "rfmp_tier", "recency", "frequency", "monetary"]].copy()

for column in ["recency", "frequency", "monetary"]:
    base[column] = pd.to_numeric(base[column], errors="coerce")

base["rfmp_tier"] = base["rfmp_tier"].astype(str).str.strip()

unknown_tiers = sorted(set(base["rfmp_tier"]) - set(TIER_ORDER))

if unknown_tiers:
    raise ValueError("알 수 없는 등급이 있습니다: " + ", ".join(unknown_tiers))

if base[["recency", "frequency", "monetary"]].isna().any().any():
    raise ValueError("recency, frequency, monetary 에 결측값이 있습니다.")

w2 = w2[["customer_id", "first_purchase_date"]].copy()
w2["first_purchase_date"] = sas_date_to_datetime(w2["first_purchase_date"])

risk = risk[["customer_id", "relative_risk_grade", "final_churn_probability"]].copy()

cust = (
    base
    .merge(w2, on="customer_id", how="left", validate="one_to_one")
    .merge(risk, on="customer_id", how="left", validate="one_to_one")
)

if HAS_LABELS:
    labels = lower_columns(SAS.sd2df("crm.w5_val_kmeans_labels"))
    labels["customer_id"] = labels["customer_id"].astype(str).str.strip()
    cust = cust.merge(
        labels[["customer_id", "kmeans_cluster"]],
        on="customer_id", how="left", validate="one_to_one"
    )
else:
    cust["kmeans_cluster"] = np.nan

n_customers = len(cust)

if cust["first_purchase_date"].isna().any():
    raise ValueError("첫 구매일이 없는 고객이 있어 신규 여부를 판정할 수 없습니다. CRM.W2_RFM 을 확인하십시오.")

cust["relative_risk_grade"] = cust["relative_risk_grade"].fillna("UNSCORED").astype(str).str.strip()

print(f"고객 {n_customers:,}명")


# --------------------------------------------------------------------
# 2. 상태 부여
# --------------------------------------------------------------------

cust["is_new"] = (cust["first_purchase_date"] > NEW_CUTOFF).astype(int)
cust["is_one_time"] = (cust["frequency"] == 1).astype(int)

cust["state"] = np.where(
    (cust["is_new"] == 1) | (cust["is_one_time"] == 1),
    "NEW_OR_ONE",
    np.where(cust["recency"] >= DORMANT_DAYS, "DORMANT", "ACTIVE")
)

cust["state_label"] = cust["state"].map(STATE_LABEL)


# --------------------------------------------------------------------
# 3. 재활성화 우선순위 (상태 = DORMANT)
# --------------------------------------------------------------------

dormant = cust[cust["state"] == "DORMANT"].copy()
dormant["priority_group"] = dormant["rfmp_tier"].map(PRIORITY_GROUP)

dormant = dormant.sort_values(
    ["priority_group", "monetary", "customer_id"],
    ascending=[True, False, True]
).reset_index(drop=True)

dormant["priority_rank"] = np.arange(1, len(dormant) + 1)

cust = cust.merge(
    dormant[["customer_id", "priority_group", "priority_rank"]],
    on="customer_id", how="left"
)

cust["priority_group"] = cust["priority_group"].fillna("")
cust["priority_rank"] = cust["priority_rank"].fillna(0).astype(int)


# --------------------------------------------------------------------
# 4. 결과 표
# --------------------------------------------------------------------

total_monetary = float(cust["monetary"].sum())

summary_rows = []

for state in STATE_ORDER:
    part = cust[cust["state"] == state]
    summary_rows.append({
        "state": state,
        "state_label": STATE_LABEL[state],
        "customers": int(len(part)),
        "customers_pct": float(100.0 * len(part) / n_customers),
        "monetary_share_pct": float(100.0 * part["monetary"].sum() / total_monetary),
        "recency_median": float(part["recency"].median()) if len(part) else np.nan,
        "frequency_median": float(part["frequency"].median()) if len(part) else np.nan
    })

state_summary = pd.DataFrame(summary_rows)

tier_rows = []

for tier in TIER_ORDER:
    tier_part = cust[cust["rfmp_tier"] == tier]
    for state in STATE_ORDER:
        part = tier_part[tier_part["state"] == state]
        tier_rows.append({
            "rfmp_tier": tier,
            "state": state,
            "state_label": STATE_LABEL[state],
            "customers": int(len(part)),
            "pct_of_tier": float(100.0 * len(part) / len(tier_part)) if len(tier_part) else np.nan,
            "monetary_sum": float(part["monetary"].sum())
        })

tier_by_state = pd.DataFrame(tier_rows)

total_dormant = int((cust["state"] == "DORMANT").sum())

compare_rows = []


def add_compare(name, mask):
    n_target = int(mask.sum())
    n_dormant_in = int((mask & (cust["state"] == "DORMANT")).sum())
    compare_rows.append({
        "target_rule": name,
        "target_customers": n_target,
        "dormant_included": n_dormant_in,
        "dormant_coverage_pct": float(100.0 * n_dormant_in / total_dormant) if total_dormant else np.nan,
        "dormant_share_of_target_pct": float(100.0 * n_dormant_in / n_target) if n_target else np.nan
    })


high = cust["relative_risk_grade"] == "High"
medium = cust["relative_risk_grade"] == "Medium"

add_compare("위험등급 High 만", high)
add_compare("위험등급 High + Medium", high | medium)
add_compare("상태 = 장기 미구매", cust["state"] == "DORMANT")
add_compare("상태 = 장기 미구매 그리고 위험등급 High", (cust["state"] == "DORMANT") & high)

target_compare = pd.DataFrame(compare_rows)

priority_rows = []

for group in ["P1", "P2", "P3"]:
    part = dormant[dormant["priority_group"] == group]
    tiers = ", ".join(f"{tier} {int((part['rfmp_tier'] == tier).sum())}" for tier in TIER_ORDER[::-1] if (part["rfmp_tier"] == tier).any())
    priority_rows.append({
        "priority_group": group,
        "customers": int(len(part)),
        "pct_of_dormant": float(100.0 * len(part) / total_dormant) if total_dormant else np.nan,
        "monetary_share_of_dormant_pct": float(100.0 * part["monetary"].sum() / dormant["monetary"].sum()) if total_dormant else np.nan,
        "recency_median": float(part["recency"].median()) if len(part) else np.nan,
        "tier_composition": tiers
    })

priority_summary = pd.DataFrame(priority_rows)

customer_state = cust[[
    "customer_id", "rfmp_tier", "state", "state_label", "recency", "frequency", "monetary",
    "relative_risk_grade", "final_churn_probability", "kmeans_cluster",
    "priority_group", "priority_rank"
]].copy()

customer_state["first_purchase_date"] = cust["first_purchase_date"].astype(str).str[:10]
customer_state["dormant_days_used"] = DORMANT_DAYS

reactivation = dormant[[
    "priority_rank", "priority_group", "customer_id", "rfmp_tier", "recency", "frequency",
    "monetary", "relative_risk_grade", "final_churn_probability", "kmeans_cluster"
]].copy()

save_sas(customer_state, "w5d_customer_state")
save_sas(state_summary, "w5d_state_summary")
save_sas(tier_by_state, "w5d_tier_by_state")
save_sas(target_compare, "w5d_target_compare")
save_sas(priority_summary, "w5d_priority_summary")
save_sas(reactivation, "w5d_reactivation_list")

csv_path = os.path.join(OUT_DIR, "reactivation_list.csv")

try:
    reactivation.to_csv(csv_path, index=False, encoding="utf-8-sig")
    print(f"CSV 저장: {csv_path}")
except Exception as error:
    print(f"CSV 저장 실패: {error}")


# --------------------------------------------------------------------
# 5. 그림
# --------------------------------------------------------------------

fig, axes = plt.subplots(1, 2, figsize=(15, 5.6), gridspec_kw={"width_ratios": [1, 1.25]})

x = np.arange(len(STATE_ORDER))
width = 0.38

axes[0].bar(x - width / 2, state_summary["customers_pct"], width, label="Customers (pct)", color="tab:blue")
axes[0].bar(x + width / 2, state_summary["monetary_share_pct"], width, label="Past purchase amount (pct)", color="tab:orange")

for index, row in state_summary.iterrows():
    axes[0].text(index - width / 2, row["customers_pct"] + 0.8, f"{row['customers_pct']:.0f}", ha="center")
    axes[0].text(index + width / 2, row["monetary_share_pct"] + 0.8, f"{row['monetary_share_pct']:.0f}", ha="center")

axes[0].set_xticks(x)
axes[0].set_xticklabels(["Recent", "Long dormant", "New or one-time"])
axes[0].set_ylabel("Share (pct)")
axes[0].set_title(f"State overview (dormant = {DORMANT_DAYS}+ days)")
axes[0].legend()
axes[0].grid(axis="y", alpha=0.3)

grid = (
    tier_by_state.pivot(index="rfmp_tier", columns="state", values="customers")
    .reindex(index=TIER_ORDER[::-1], columns=STATE_ORDER)
    .to_numpy(dtype=float)
)

image = axes[1].imshow(grid, cmap="Blues", aspect="auto")

axes[1].set_xticks(range(len(STATE_ORDER)))
axes[1].set_xticklabels(["Recent", "Long dormant", "New or one-time"])
axes[1].set_yticks(range(len(TIER_ORDER)))
axes[1].set_yticklabels(TIER_ORDER[::-1])

for row_number in range(grid.shape[0]):
    for column_number in range(grid.shape[1]):
        value = grid[row_number, column_number]
        axes[1].text(
            column_number, row_number, f"{int(value)}", ha="center", va="center",
            color="white" if value > grid.max() * 0.6 else "black"
        )

axes[1].set_title("Customers by RFMP tier and state")
fig.colorbar(image, ax=axes[1])

plt.tight_layout()
draw_and_save("w5d_state_overview.png")


# --------------------------------------------------------------------
# 6. 마크다운 리포트
# --------------------------------------------------------------------

lines = []
lines.append("# WBS 5d. 고객 상태와 재활성화 명단")
lines.append("")
lines.append(f"- 장기 미구매 기준: 마지막 구매 후 {DORMANT_DAYS}일 이상")
lines.append(f"- 신규 기준: 첫 구매가 {NEW_CUTOFF.date()} 이후, 또는 구매 횟수 1회")
lines.append("- 상태는 등급과 별개인 컬럼이며, 등급(구매 규모)은 바꾸지 않았습니다.")
lines.append("")
lines.append("## 1. 상태별 요약")
lines.append("")
lines.append("| 상태 | 고객 수 | 고객 비율(%) | 과거 구매금액 비중(%) | Recency 중앙값 |")
lines.append("| :--- | :---: | :---: | :---: | :---: |")

for _, row in state_summary.iterrows():
    lines.append(
        f"| {row['state_label']} | {int(row['customers'])} | {row['customers_pct']:.1f} | "
        f"{row['monetary_share_pct']:.1f} | {row['recency_median']:.0f} |"
    )

lines.append("")
lines.append("## 2. 재활성화 대상 추출 방식 비교")
lines.append("")
lines.append("| 방식 | 대상 고객 수 | 그중 장기 미구매 | 장기 미구매 포함률(%) | 대상 중 장기 미구매 비율(%) |")
lines.append("| :--- | :---: | :---: | :---: | :---: |")

for _, row in target_compare.iterrows():
    lines.append(
        f"| {row['target_rule']} | {int(row['target_customers'])} | {int(row['dormant_included'])} | "
        f"{row['dormant_coverage_pct']:.1f} | {row['dormant_share_of_target_pct']:.1f} |"
    )

lines.append("")
lines.append("## 3. 재활성화 우선순위 그룹")
lines.append("")
lines.append("| 그룹 | 고객 수 | 장기 미구매 중 비율(%) | 구매금액 비중(%) | 등급 구성 |")
lines.append("| :---: | :---: | :---: | :---: | :--- |")

for _, row in priority_summary.iterrows():
    lines.append(
        f"| {row['priority_group']} | {int(row['customers'])} | {row['pct_of_dormant']:.1f} | "
        f"{row['monetary_share_of_dormant_pct']:.1f} | {row['tier_composition']} |"
    )

lines.append("")
lines.append("## 4. 해석 시 유의사항")
lines.append("")
lines.append("- 우선순위는 과거 구매 규모 기준의 업무 규칙이며 재활성화 성공 확률이 아닙니다.")
lines.append("- 캠페인 이력이 없어 재활성화 반응률과 매출 효과는 이 데이터로 검증할 수 없습니다.")
lines.append("- \"최근 구매\" 상태도 다음 90일 구매를 보장하지 않습니다. 구매가 있던 고객 중에도 이탈이 많았습니다.")
lines.append("- 상태는 기준일에 따라 바뀌므로 갱신 주기와 기준일을 함께 관리해야 합니다.")

report_path = os.path.join(OUT_DIR, "w5d_state_report.md")

try:
    with open(report_path, "w", encoding="utf-8") as report_file:
        report_file.write("\n".join(lines) + "\n")
    print(f"리포트 저장: {report_path}")
except Exception as error:
    print(f"리포트 저장 실패: {error}")

print("\n[상태별 요약]")
print(state_summary.round(1).to_string(index=False))
print("\n[대상 추출 방식 비교]")
print(target_compare.round(1).to_string(index=False))
print("\n[우선순위 그룹]")
print(priority_summary.round(1).to_string(index=False))
print("\nWBS 5d 가 끝났습니다.")

endsubmit;
quit;


%macro check_outputs;

    %local missing_count;
    %let missing_count = 0;

    %if %sysfunc(exist(crm.w5d_customer_state))    = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5d_state_summary))     = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5d_tier_by_state))     = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5d_target_compare))    = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5d_priority_summary))  = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5d_reactivation_list)) = 0 %then %let missing_count = %eval(&missing_count. + 1);

    %if &missing_count. > 0 %then
        %put ERROR: WBS 5d 산출물 &missing_count.개가 생성되지 않았습니다. 위쪽 PROC PYTHON 로그를 확인하십시오.;
    %else
        %put NOTE: WBS 5d 산출물 6개를 확인했습니다.;

%mend check_outputs;

%check_outputs;


title "WBS 5d-1. 상태별 요약";

proc print data=crm.w5d_state_summary noobs;
    format customers_pct monetary_share_pct 8.1 recency_median frequency_median 8.0;
run;


title "WBS 5d-2. 등급 x 상태";

proc print data=crm.w5d_tier_by_state noobs;
    format pct_of_tier 8.1 monetary_sum comma16.0;
run;


title "WBS 5d-3. 재활성화 대상 추출 방식 비교";

proc print data=crm.w5d_target_compare noobs;
    format dormant_coverage_pct dormant_share_of_target_pct 8.1;
run;


title "WBS 5d-4. 재활성화 우선순위 그룹";

proc print data=crm.w5d_priority_summary noobs;
    format pct_of_dormant monetary_share_of_dormant_pct 8.1 recency_median 8.0;
run;


title "WBS 5d-5. 재활성화 명단 상위 30명";

proc print data=crm.w5d_reactivation_list(obs=30) noobs;
    format monetary comma14.0 final_churn_probability 8.3;
run;

title;


/*====================================================================
  WBS 5e. "충성 후보"가 실제로 다음 90일에 더 구매했는가
  파일명: WBS_5e_Loyal_Candidate_Test.sas

  질문
    VIP/Diamond x 최근 구매 고객(현재 311명)을 "충성 후보"라고 부를 수 있는가?
    -> 다음 90일 구매 여부를 이미 알고 있는 과거 두 시점(TRAIN 6/30, VALID 10/02)에서
       같은 성격의 고객이 실제로 나머지보다 더 구매했는지 비교

  왜 스냅샷으로 검증하나
    - 현재(12/31) 고객에게는 "다음 90일" 결과가 아직 없음
    - RFMP 등급은 전체 기간(12/31까지)으로 만든 값이라 과거 시점에 쓰면 미래 정보가 섞임
      -> 각 스냅샷 시점에 알 수 있는 값만으로 같은 성격의 집단을 다시 정의함

  스냅샷에서의 정의 (현재 정의의 근사이며 완전히 같지는 않음)
    규모 큼   : 그 시점 구매 횟수와 구매금액 백분위 평균이 상위 TOP_SHARE
                (현재 등급의 VIP+Diamond = 상위 1/3 에 대응)
    최근 구매 : 그 시점 Recency 가 RECENT_DAYS 미만
    신규·1회  : 구매 횟수 1회이거나 첫 구매가 스냅샷 기준 NEW_WINDOW_DAYS 일 이내
    집단
      1_LOYAL_CANDIDATE  규모 큼 + 최근 구매   (충성 후보)
      2_LARGE_DORMANT    규모 큼 + 장기 미구매
      3_SMALL_RECENT     규모 작음 + 최근 구매
      4_SMALL_DORMANT    규모 작음 + 장기 미구매
      5_NEW_OR_ONE       신규·1회 구매

  비교
    충성 후보 vs 나머지 전체 / vs 3번(규모 효과) / vs 2번(최근성 효과)
    충성 후보 안에서 구매 간격의 규칙성, 가입기간별 구매율

  해석 유의사항
    - TRAIN 과 VALID 는 같은 고객이 많이 겹치는 서로 다른 시점이라 독립 검증 두 번이 아님
    - 차이가 있어도 인과가 아닌 관찰된 차이이며, 집단 간 다른 조건(규모 등)이 섞여 있음
    - 결과가 기대와 다르면 "충성고객" 표현을 쓰지 말고 "규모가 큰 최근 고객"으로 쓰십시오.

  입력: CRM.W3_CHURN_SPLIT_V2, CRM.W5D_CUSTOMER_STATE (있으면 현재 후보 명단 저장)
====================================================================*/

options validvarname=any;

%let CRM_PATH         = /home/student/crm_db;
libname crm "&CRM_PATH.";

%let TOP_SHARE        = 0.3333;
%let RECENT_DAYS      = 180;
%let NEW_WINDOW_DAYS  = 90;


%macro require_table(ds=);

    %if %sysfunc(exist(&ds.)) = 0 %then %do;
        %put ERROR: 필수 입력 테이블 &ds. 이(가) 없습니다.;
        %abort cancel;
    %end;

    %else %put NOTE: 입력 테이블 &ds. 을(를) 확인했습니다.;

%mend require_table;

%require_table(ds=crm.w3_churn_split_v2);


%global HAS_STATE;

%macro check_state;

    %if %sysfunc(exist(crm.w5d_customer_state)) %then %let HAS_STATE = 1;
    %else %let HAS_STATE = 0;

%mend check_state;

%check_state;


proc datasets library=crm nolist nowarn;
    delete
        w5e_group_rates
        w5e_group_tests
        w5e_candidate_traits
        w5e_loyal_current;
quit;


proc python restart;
submit;

import os

os.environ["OMP_NUM_THREADS"] = "1"
os.environ["OPENBLAS_NUM_THREADS"] = "1"
os.environ["MKL_NUM_THREADS"] = "1"

import warnings

warnings.filterwarnings("ignore")

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

from scipy import stats


# --------------------------------------------------------------------
# 0. 설정과 공통 함수
# --------------------------------------------------------------------

OUT_DIR = str(SAS.symget("CRM_PATH")).strip()
TOP_SHARE = float(str(SAS.symget("TOP_SHARE")).strip())
RECENT_DAYS = int(float(str(SAS.symget("RECENT_DAYS")).strip()))
NEW_WINDOW_DAYS = int(float(str(SAS.symget("NEW_WINDOW_DAYS")).strip()))
HAS_STATE = str(SAS.symget("HAS_STATE")).strip() == "1"

GROUP_LABEL = {
    "1_LOYAL_CANDIDATE": "충성 후보 (규모 큼 + 최근 구매)",
    "2_LARGE_DORMANT": "규모 큼 + 장기 미구매",
    "3_SMALL_RECENT": "규모 작음 + 최근 구매",
    "4_SMALL_DORMANT": "규모 작음 + 장기 미구매",
    "5_NEW_OR_ONE": "신규·1회 구매"
}

GROUP_ORDER = list(GROUP_LABEL.keys())


def lower_columns(frame):
    frame = frame.copy()
    frame.columns = [str(column).strip().lower() for column in frame.columns]
    return frame


def save_sas(frame, table_name):
    output = frame.reset_index(drop=True).copy()
    for column in output.columns:
        if output[column].dtype == object:
            output[column] = output[column].astype(str)
    SAS.df2sd(output, dataset=f"crm.{table_name}")


def sas_date_to_datetime(series):
    if pd.api.types.is_datetime64_any_dtype(series):
        return pd.to_datetime(series)
    numeric = pd.to_numeric(series, errors="coerce")
    if numeric.notna().mean() >= 0.90:
        return pd.to_datetime(numeric, unit="D", origin="1960-01-01", errors="coerce")
    return pd.to_datetime(series, errors="coerce")


def wilson(k, n, z=1.96):
    if n == 0:
        return np.nan, np.nan
    p = k / n
    denom = 1 + z ** 2 / n
    centre = (p + z ** 2 / (2 * n)) / denom
    half = z * np.sqrt(p * (1 - p) / n + z ** 2 / (4 * n ** 2)) / denom
    return float(centre - half), float(centre + half)


def compare(name, snapshot, mask_a, mask_b, outcome):
    a = outcome[mask_a]
    b = outcome[mask_b]
    n_a, n_b = int(len(a)), int(len(b))

    if n_a == 0 or n_b == 0:
        return None

    k_a, k_b = int(a.sum()), int(b.sum())
    p_a, p_b = k_a / n_a, k_b / n_b
    se = np.sqrt(p_a * (1 - p_a) / n_a + p_b * (1 - p_b) / n_b)
    diff = p_a - p_b
    _, p_value = stats.fisher_exact([[k_a, n_a - k_a], [k_b, n_b - k_b]])

    return {
        "snapshot": snapshot,
        "comparison": name,
        "n_candidate": n_a,
        "n_comparison": n_b,
        "purchase_rate_candidate": float(p_a),
        "purchase_rate_comparison": float(p_b),
        "diff_pp": float(100 * diff),
        "diff_ci_low_pp": float(100 * (diff - 1.96 * se)),
        "diff_ci_high_pp": float(100 * (diff + 1.96 * se)),
        "fisher_p": float(p_value)
    }


def reading(row):
    if row["diff_ci_low_pp"] > 0:
        return "후보가 유의하게 높음"
    if row["diff_ci_high_pp"] < 0:
        return "후보가 유의하게 낮음"
    return "차이를 확정할 수 없음"


print("=" * 72)
print("WBS 5e. 충성 후보 검증")
print("=" * 72)
print(f"규모 상위 {TOP_SHARE:.4f}, 최근 구매 = Recency {RECENT_DAYS}일 미만, 신규 = 첫 구매 {NEW_WINDOW_DAYS}일 이내 또는 1회 구매")


# --------------------------------------------------------------------
# 1. 스냅샷 데이터 준비와 집단 정의
# --------------------------------------------------------------------

split = lower_columns(SAS.sd2df("crm.w3_churn_split_v2"))

required = [
    "split_role", "customer_id", "snapshot_cutoff", "first_purchase_date",
    "recency", "frequency", "monetary", "churn_flag",
    "avg_days_between_orders", "std_days_between_orders", "tenure"
]

missing = [column for column in required if column not in split.columns]

if missing:
    raise ValueError("필수 변수가 없습니다: " + ", ".join(missing))

split["split_role"] = split["split_role"].astype(str).str.strip().str.upper()
split["snapshot_cutoff"] = sas_date_to_datetime(split["snapshot_cutoff"])
split["first_purchase_date"] = sas_date_to_datetime(split["first_purchase_date"])

for column in ["recency", "frequency", "monetary", "churn_flag",
               "avg_days_between_orders", "std_days_between_orders", "tenure"]:
    split[column] = pd.to_numeric(split[column], errors="coerce")

rate_rows = []
test_rows = []
trait_rows = []
frames = {}

for snapshot in ["TRAIN", "VALID"]:

    d = split[split["split_role"] == snapshot].copy().reset_index(drop=True)

    if d[["recency", "frequency", "monetary", "churn_flag"]].isna().any().any():
        raise ValueError(f"{snapshot} 스냅샷에 결측값이 있습니다.")

    d["purchased_next90"] = (1 - d["churn_flag"]).astype(int)

    d["scale_score"] = (d["frequency"].rank(pct=True) + d["monetary"].rank(pct=True)) / 2
    is_large = d["scale_score"].rank(pct=True) > (1 - TOP_SHARE)
    is_recent = d["recency"] < RECENT_DAYS

    days_since_first = (d["snapshot_cutoff"] - d["first_purchase_date"]).dt.days
    is_new_or_one = (d["frequency"] == 1) | (days_since_first < NEW_WINDOW_DAYS)

    d["group"] = np.select(
        [is_new_or_one, is_large & is_recent, is_large & ~is_recent, ~is_large & is_recent],
        ["5_NEW_OR_ONE", "1_LOYAL_CANDIDATE", "2_LARGE_DORMANT", "3_SMALL_RECENT"],
        default="4_SMALL_DORMANT"
    )

    frames[snapshot] = d
    outcome = d["purchased_next90"].to_numpy()

    for group in GROUP_ORDER:
        mask = (d["group"] == group).to_numpy()
        n = int(mask.sum())
        k = int(outcome[mask].sum())
        low, high = wilson(k, n)
        rate_rows.append({
            "snapshot": snapshot,
            "group": group,
            "group_label": GROUP_LABEL[group],
            "customers": n,
            "share_pct": float(100 * n / len(d)),
            "purchased_next90": k,
            "purchase_rate": float(k / n) if n else np.nan,
            "ci_low": low,
            "ci_high": high
        })

    loyal = (d["group"] == "1_LOYAL_CANDIDATE").to_numpy()

    for name, other in [
        ("충성 후보 vs 나머지 전체", ~loyal),
        ("충성 후보 vs 규모 작음 + 최근 구매 (규모 효과)", (d["group"] == "3_SMALL_RECENT").to_numpy()),
        ("충성 후보 vs 규모 큼 + 장기 미구매 (최근성 효과)", (d["group"] == "2_LARGE_DORMANT").to_numpy())
    ]:
        result = compare(name, snapshot, loyal, other, outcome)
        if result is not None:
            result["reading"] = reading(result)
            test_rows.append(result)

    # 충성 후보 안에서 규칙성(간격 변동계수)과 가입기간별 구매율
    cand = d[d["group"] == "1_LOYAL_CANDIDATE"].copy()
    cand["gap_cv"] = np.where(
        cand["avg_days_between_orders"] > 0,
        cand["std_days_between_orders"] / cand["avg_days_between_orders"],
        np.nan
    )

    for trait, column, note in [
        ("구매 간격 변동계수 (낮을수록 규칙적)", "gap_cv", "1=가장 규칙적"),
        ("가입기간(tenure)", "tenure", "1=가장 짧음")
    ]:
        valid = cand[cand[column].notna()].copy()

        if len(valid) < 30:
            continue

        valid["tercile"] = pd.qcut(valid[column].rank(method="first"), 3, labels=[1, 2, 3]).astype(int)

        for tercile in [1, 2, 3]:
            part = valid[valid["tercile"] == tercile]
            trait_rows.append({
                "snapshot": snapshot,
                "trait": trait,
                "tercile": tercile,
                "note": note,
                "customers": int(len(part)),
                "trait_min": float(part[column].min()),
                "trait_max": float(part[column].max()),
                "purchase_rate": float(part["purchased_next90"].mean())
            })

group_rates = pd.DataFrame(rate_rows)
group_tests = pd.DataFrame(test_rows)
candidate_traits = pd.DataFrame(trait_rows)

save_sas(group_rates, "w5e_group_rates")
save_sas(group_tests, "w5e_group_tests")

if len(candidate_traits):
    save_sas(candidate_traits, "w5e_candidate_traits")
else:
    print("충성 후보 내부 비교에 필요한 고객 수가 부족해 특성별 표는 만들지 않았습니다.")

print("[1] 집단별 다음 90일 구매율")
print(group_rates[["snapshot", "group", "customers", "purchase_rate", "ci_low", "ci_high"]].round(3).to_string(index=False))
print("\n[2] 충성 후보 비교")
print(group_tests[["snapshot", "comparison", "purchase_rate_candidate", "purchase_rate_comparison", "diff_pp", "diff_ci_low_pp", "diff_ci_high_pp", "fisher_p", "reading"]].round(3).to_string(index=False))


# --------------------------------------------------------------------
# 2. 현재 충성 후보 명단 (VIP/Diamond x 최근 구매)
# --------------------------------------------------------------------

if HAS_STATE:
    current = lower_columns(SAS.sd2df("crm.w5d_customer_state"))
    current["rfmp_tier"] = current["rfmp_tier"].astype(str).str.strip()
    current["state"] = current["state"].astype(str).str.strip()

    flag = current["rfmp_tier"].isin(["VIP", "Diamond"]) & (current["state"] == "ACTIVE")

    loyal_now = current[flag][[
        "customer_id", "rfmp_tier", "state_label", "recency", "frequency", "monetary",
        "relative_risk_grade", "final_churn_probability"
    ]].sort_values("monetary", ascending=False).reset_index(drop=True)

    save_sas(loyal_now, "w5e_loyal_current")

    print(f"\n[3] 현재 충성 후보(VIP/Diamond x 최근 구매): {len(loyal_now)}명")
else:
    print("\n[3] CRM.W5D_CUSTOMER_STATE 가 없어 현재 후보 명단은 만들지 않았습니다. (WBS 5d 를 먼저 실행하십시오)")


# --------------------------------------------------------------------
# 3. 그림
# --------------------------------------------------------------------

fig, axes = plt.subplots(1, 2, figsize=(15, 5.4), sharey=True)

short_names = ["Loyal cand.", "Large dormant", "Small recent", "Small dormant", "New/one-time"]

for axis, snapshot in zip(axes, ["TRAIN", "VALID"]):
    part = group_rates[group_rates["snapshot"] == snapshot].set_index("group").reindex(GROUP_ORDER)
    rates = part["purchase_rate"].to_numpy(dtype=float)
    lower = rates - part["ci_low"].to_numpy(dtype=float)
    upper = part["ci_high"].to_numpy(dtype=float) - rates

    colors = ["tab:green"] + ["tab:gray"] * 4

    axis.bar(range(5), rates, yerr=[lower, upper], capsize=4, color=colors)

    for index, (rate, n) in enumerate(zip(rates, part["customers"])):
        axis.text(index, rate + 0.03, f"{rate:.2f}\n(n={int(n)})", ha="center", fontsize=9)

    axis.set_xticks(range(5))
    axis.set_xticklabels(short_names, rotation=20, ha="right")
    axis.set_title(f"{snapshot}: purchased in next 90 days")
    axis.grid(axis="y", alpha=0.3)

axes[0].set_ylabel("Share who purchased in next 90 days (95 pct CI)")

plt.tight_layout()

path = os.path.join(OUT_DIR, "w5e_loyal_candidate_test.png")

try:
    plt.savefig(path, dpi=150, bbox_inches="tight")
except Exception as error:
    print(f"그림 파일 저장 실패: {error}")

SAS.pyplot(plt)
plt.close("all")

print("\nWBS 5e 가 끝났습니다.")

endsubmit;
quit;


%macro check_outputs;

    %local missing_count;
    %let missing_count = 0;

    %if %sysfunc(exist(crm.w5e_group_rates)) = 0 %then %let missing_count = %eval(&missing_count. + 1);
    %if %sysfunc(exist(crm.w5e_group_tests)) = 0 %then %let missing_count = %eval(&missing_count. + 1);

    %if &missing_count. > 0 %then
        %put ERROR: WBS 5e 핵심 산출물이 생성되지 않았습니다. 위쪽 PROC PYTHON 로그를 확인하십시오.;
    %else
        %put NOTE: WBS 5e 핵심 산출물을 확인했습니다.;

%mend check_outputs;

%check_outputs;


title "WBS 5e-1. 집단별 다음 90일 구매율";

proc print data=crm.w5e_group_rates noobs;
    format share_pct 8.1 purchase_rate ci_low ci_high 8.3;
run;


title "WBS 5e-2. 충성 후보 비교 (구매율 차이, 퍼센트포인트)";

proc print data=crm.w5e_group_tests noobs;
    format purchase_rate_candidate purchase_rate_comparison 8.3
           diff_pp diff_ci_low_pp diff_ci_high_pp 8.1 fisher_p 10.4;
run;


%macro print_traits;

    %if %sysfunc(exist(crm.w5e_candidate_traits)) %then %do;

        title "WBS 5e-3. 충성 후보 안에서 규칙성과 가입기간별 구매율";

        proc print data=crm.w5e_candidate_traits noobs;
            format trait_min trait_max 10.2 purchase_rate 8.3;
        run;

    %end;

%mend print_traits;

%print_traits;


%macro print_current;

    %if %sysfunc(exist(crm.w5e_loyal_current)) %then %do;

        title "WBS 5e-4. 현재 충성 후보 상위 20명 (VIP/Diamond x 최근 구매)";

        proc print data=crm.w5e_loyal_current(obs=20) noobs;
            format monetary comma14.0 final_churn_probability 8.3;
        run;

    %end;

%mend print_current;

%print_current;

title;



