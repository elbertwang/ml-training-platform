# 展示层：每个 job 一个 URL

两条路都保留，因为它们解决的是不同的问题。

| | **Grafana**（主力） | **Looker Studio**（对外分享） |
|---|---|---|
| 一个 job 一个 URL | `?var-job_key=<job>`，一级功能 | `?params={"job_key":"<job>"}`，要手动开「允许 URL 修改」 |
| 能接 Cloud Monitoring / GMP | ✅ **只有它能** | ❌ 只有 BigQuery |
| 时序图 | 本行 | 一般 |
| 刷新 | 秒级可配 | 默认缓存 12 小时 |
| 告警 | 内置（BQ 数据也能告警） | 无 |
| 运维 | 一个 Cloud Run 服务 | 零 |
| 给无 GCP 权限的人看 | 要授权 IAP | 最方便 |
| 部署 | `grafana/deploy.sh` | 手工点，见 `LOOKER_STUDIO.md` |

**选 Grafana 做主力的理由是结构性的，不是偏好**：这个项目已经开了 GMP
（`autoMonitoring scope=ALL`）和 DCGM / JOBSET / CADVISOR 全套指标。Looker Studio
接不了 Cloud Monitoring 也接不了 Prometheus，那些现成的实时指标它一个都用不上。

---

## Grafana（已部署并验证）

```bash
export CLOUDSDK_AUTH_ACCESS_TOKEN=$(gcloud auth application-default print-access-token)
PROJECT_ID=tpu-launchpad-playground ./grafana/deploy.sh
```

一条命令做完：服务账号 + BQ 授权、Artifact Registry、生成 dashboard JSON、
Cloud Build 构建镜像、部署 Cloud Run（带 IAP）。

### 访问

```
https://<service-url>/d/mlobs-job                        # 带下拉选 job
https://<service-url>/d/mlobs-job?var-job_key=<JOB>      # 一站式 URL
```

给人开权限：

```bash
gcloud beta iap web add-iam-policy-binding --project <P> \
  --resource-type=cloud-run --service=mlobs-grafana --region=us-central1 \
  --member="user:someone@example.com" --role="roles/iap.httpsResourceAccessor"
```

### 认证模型

**IAP 是唯一的认证层，Grafana 本身跑匿名（Admin 角色）。**

不是偷懒 —— 两层认证会抢同一个 `Authorization` 头（实测：curl 带 Cloud Run 的
Bearer 再带 Grafana 的 basic auth，后者会覆盖前者，必然 403）。而且 IAP 已经
证明了 Google 身份，再要一个 Grafana 密码不增加任何安全性，只增加一个要保管的
秘密。

组织策略 `constraints/iam.allowedPolicyMemberDomains` 禁止 `allUsers`，所以公开
访问本来也不可能。

### 已验证

| 项 | 结果 |
|---|---|
| Provisioning | datasource `mlobs-bq`（`gce` 认证，无密钥文件）+ dashboard `mlobs-job` 自动加载 |
| BigQuery 查询 | ✅ Cloud Run 上实测返回真实数据 |
| TVF 查询 | ✅ `job_timeline('vllm-tpu')` 返回 tpu_idle / app_error / k8s_event 三源交叉 |
| 变量下拉 | ✅ 从 `job_hub` 拉出真实 job 列表 |
| IAP | ✅ 未认证访问返回 302 跳登录 |

### 成本

一次页面加载扫描约 **2.3 MB**（全部走 TVF）。按 1 分钟刷新 × 每天 8 小时 ×
10 个用户估算，约 **$4/月** BigQuery 扫描费。Cloud Run 空闲缩到 0，几乎不计费。

**别把刷新间隔调到秒级** —— 每次刷新都是真查 BigQuery。dashboard 默认 1 分钟，
底层链路本身的新鲜度是：sink 2–5 秒、Monitoring 指标 3–4 分钟，所以 1 分钟
已经比数据本身还快。

### 图表设计要点

- **6 个事件来源的配色是验证过的**，不是挑好看的：取自分类色板前 6 槽，
  浅色/深色两个模式下相邻色对的色盲可分辨度（CVD ΔE）和正常视觉可分辨度都过线。
  浅色模式下 aqua/yellow/magenta 三个色对比度低于 3:1 —— 所以时间线图**永远
  配一份表格视图**，不能只靠颜色分辨。
- **颜色跟着来源走，不跟着排名走。** 筛掉一个来源，剩下的颜色不变。
- **Goodput 和 sample coverage 用的是保留的状态色**（good/warning/critical），
  不会和序列色混用，而且都带文字标签 —— 颜色从不单独表意。
- **成本给两个数**：`est_usd`（墙钟外推）和 `est_usd_observed`（实测）。
  `sample_coverage` 低于 0.5 时前者不可信 —— 测试环境里两者差 112 倍。

### 还没接的

- **GMP / Cloud Monitoring 数据源。** Grafana 查 GMP 需要一个
  **datasource syncer** CronJob（Google 官方要求：Grafana 不支持 Prometheus
  数据源用 OAuth2 服务账号，必须靠 syncer 每 10 分钟刷 token）。它要跑在集群里，
  等确认要不要动集群再加。加上之后，实时 TPU 指标和 BQ 建模数据就能同页。
- Cluster Director 单个 run 的深链接路径（未实测确认，现在只到项目级）。
