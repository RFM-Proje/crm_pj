# crm_pj

file:///C:/Users/USER/Downloads/git-flow-detailed-rendered.html
{
  "schema_version": 2,
  "diagram_type": "workflow",
  "meta": {
    "title": "CRM Insight Hub Git Flow (작업 내역 포함 예시)",
    "animation": "trace",
    "visual_preset": "classic",
    "quality_profile": "showcase",
    "output": "git-flow-detailed-rendered.html",
    "views": [
      {
        "id": "dh-work",
        "label": "DH: 모델링 작업",
        "focus": ["dh_1", "dh_2", "dh_3", "dev_merge"],
        "note": "RFM 피처 설계부터 이탈 라벨 정의까지, DH가 dev에 통합되는 과정을 따라갑니다."
      },
      {
        "id": "sas-work",
        "label": "SAS_Preliminary: 파이프라인 작업",
        "focus": ["sas_1", "sas_2", "sas_3", "dev_merge"],
        "note": "데이터 정제부터 예비 검증까지, SAS 파이프라인이 dev에 통합되는 과정입니다."
      },
      {
        "id": "jh-work",
        "label": "JH: 대시보드 작업",
        "focus": ["jh_1", "jh_2", "jh_3", "dev_merge"],
        "note": "React 대시보드부터 시각화까지, JH 작업이 dev에 통합되는 과정입니다."
      },
      {
        "id": "release",
        "label": "dev → main 배포",
        "focus": ["dev_merge", "main_release"],
        "note": "세 브랜치가 모두 합쳐진 dev가 최종적으로 main으로 배포됩니다."
      }
    ]
  },
  "lanes": [
    { "id": "dh", "label": "DH" },
    { "id": "sas", "label": "SAS_Preliminary" },
    { "id": "jh", "label": "JH" },
    { "id": "dev", "label": "dev" },
    { "id": "main", "label": "main" }
  ],
  "phases": [
    { "id": "feature_work", "label": "Feature 작업", "fromCol": 0, "toCol": 2 },
    { "id": "integration", "label": "dev 통합", "fromCol": 3, "toCol": 3, "variant": "emphasis" },
    { "id": "release", "label": "main 배포", "fromCol": 4, "toCol": 4, "variant": "dashed" }
  ],
  "mainPath": ["dh_1", "dh_2", "dh_3", "dev_merge", "main_release"],
  "nodes": [
    { "id": "dh_1", "lane": "dh", "col": 0, "type": "backend", "label": "RFM 피처 설계", "width": 140 },
    { "id": "dh_2", "lane": "dh", "col": 1, "type": "backend", "label": "K-Means 클러스터링", "width": 150 },
    { "id": "dh_3", "lane": "dh", "col": 2, "type": "backend", "label": "이탈 라벨 정의", "width": 140 },

    { "id": "sas_1", "lane": "sas", "col": 0, "type": "database", "label": "데이터 정제", "width": 130 },
    { "id": "sas_2", "lane": "sas", "col": 1, "type": "database", "label": "PROC SQL 파이프라인", "width": 160 },
    { "id": "sas_3", "lane": "sas", "col": 2, "type": "database", "label": "예비 검증", "width": 120 },

    { "id": "jh_1", "lane": "jh", "col": 0, "type": "frontend", "label": "React 대시보드", "width": 140 },
    { "id": "jh_2", "lane": "jh", "col": 1, "type": "frontend", "label": "FastAPI 연동", "width": 130 },
    { "id": "jh_3", "lane": "jh", "col": 2, "type": "frontend", "label": "시각화 구현", "width": 130 },

    { "id": "dev_merge", "lane": "dev", "col": 3, "type": "messagebus", "label": "dev", "sublabel": "3개 브랜치 통합", "tag": "integration", "width": 132 },
    { "id": "main_release", "lane": "main", "col": 4, "type": "cloud", "label": "main", "sublabel": "배포 가능한 산출물", "tag": "protected", "width": 132 }
  ],
  "edges": [
    { "id": "dh-1-2", "from": "dh_1", "to": "dh_2", "variant": "default" },
    { "id": "dh-2-3", "from": "dh_2", "to": "dh_3", "variant": "default" },
    { "id": "dh-to-dev", "from": "dh_3", "to": "dev_merge", "label": "merge", "variant": "emphasis" },

    { "id": "sas-1-2", "from": "sas_1", "to": "sas_2", "variant": "default" },
    { "id": "sas-2-3", "from": "sas_2", "to": "sas_3", "variant": "default" },
    { "id": "sas-to-dev", "from": "sas_3", "to": "dev_merge", "label": "merge", "variant": "emphasis" },

    { "id": "jh-1-2", "from": "jh_1", "to": "jh_2", "variant": "default" },
    { "id": "jh-2-3", "from": "jh_2", "to": "jh_3", "variant": "default" },
    { "id": "jh-to-dev", "from": "jh_3", "to": "dev_merge", "label": "merge", "variant": "emphasis" },

    { "id": "dev-to-main", "from": "dev_merge", "to": "main_release", "label": "release", "variant": "default" }
  ]
}
