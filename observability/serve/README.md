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
| 给无 GCP 权限的人看 | 做不到 —— 需要 `run.invoker` | 最方便 |
| 部署 | `grafana/deploy.sh` | 手工点，见 `LOOKER_STUDIO.md` |

**选 Grafana 做主力的理由是结构性的，不是偏好**：这个项目已经开了 GMP
（`autoMonitoring scope=ALL`）和 DCGM / JOBSET / CADVISOR 全套指标。Looker Studio
接不了 Cloud Monitoring 也接不了 Prometheus，那些现成的实时指标它一个都用不上。

---

## Grafana（生产已部署并验证）

```bash
export CLOUDSDK_AUTH_ACCESS_TOKEN=$(gcloud auth application-default print-access-token)
PROJECT_ID=tpu-for-training ./grafana/deploy.sh
```

一条命令做完：服务账号 + 三个数据源各自的读权限、Artifact Registry、
生成 dashboard JSON、Cloud Build 构建镜像、部署 Cloud Run。

### 访问

服务是私有的（`--no-allow-unauthenticated`），匿名请求返回 403。给人开权限：

```bash
gcloud run services add-iam-policy-binding mlobs-grafana \
  --project <P> --region us-central1 \
  --member="user:someone@example.com" --role="roles/run.invoker"
```

查看者在自己**登录过 gcloud 的机器**上起代理：

```bash
gcloud run services proxy mlobs-grafana --project <P> --region us-central1 --port 8080
# http://localhost:8080/d/mlobs-job                    带下拉选 job
# http://localhost:8080/d/mlobs-job?var-job_key=<JOB>  一站式 URL
```

首次会提示装 `cloud-run-proxy` 组件。apt 版 gcloud 要用
`sudo apt-get install google-cloud-cli-cloud-run-proxy`。

### 认证模型

**IAP 是主路径，Cloud Run IAM + proxy 是组织外用户的备路径。** 服务两种情况下都是
私有的（`--no-allow-unauthenticated`），Grafana 本身跑匿名 Admin —— Google 已经证明
了身份，再要一个 Grafana 密码不增加安全性，只增加一个要保管的秘密。而且两层认证会
抢同一个 `Authorization` 头（实测：curl 带 Cloud Run 的 Bearer 再带 Grafana 的
basic auth，后者覆盖前者，必然 403）。

组织策略 `constraints/iam.allowedPolicyMemberDomains` 禁止 `allUsers`，公开访问本来
也不可能。

**IAP 的两个前置条件。** 一是项目要有 OAuth 同意屏幕，没有就报 `Error code 9`
（OAuth 重定向失败），而 IAM 策略读回来都是对的。创建 brand 的 API gcloud 会警告已于
2026-03-19 关停，实测那只针对**新项目**，老项目仍可调用；brand 不可删除。二是这样
建出来的 brand 是 `orgInternalOnly`，只有项目所属组织内的账号能登录，且该字段无法
通过 API 修改。

**因此 `tpu-for-training` 的实际模式是**：`antgroup.com` 用户授
`roles/iap.httpsResourceAccessor` 后直接开 URL；组织外用户授 `roles/run.invoker`
后走 `gcloud run services proxy`。

> 开启 IAP 后它会拦截**所有**请求，包括 IAM 直连的（`Invalid IAP credentials:
> Invalid JWT audience`）。所以配到一半的 IAP 会让两条路同时不通，而且两边报错不同。

### 已验证（生产，以 Grafana 服务账号身份实跑）

| 项 | 结果 |
|---|---|
| Provisioning | 三个数据源自动加载：`mlobs-bq` / `mlobs-cm` / `mlobs-logs`（都用 `gce` 认证，无密钥文件） |
| BigQuery | ✅ `job_overview(<job>)` 返回真实数据 |
| Cloud Monitoring | ✅ tensorcore / memory_used / log_entry_count 各 4 序列 48 点 |
| Cloud Logging | ✅ 取到实时 `completed step` 行 |
| 最小权限 | ✅ 查 `defaultLink` **被拒绝** —— 读权限只在 `mlobs_raw` / `mlobs_core` |
| 匿名访问 | ✅ 403 |

> **数据源缺权限时面板只显示 No data，不报错。** Cloud Monitoring 面板全空了一阵，
> 原因是 SA 少了 `monitoring.viewer` —— 和「这个 job 确实没指标」长得一模一样。
> 每加一个数据源，都要单独授它自己的读权限。

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
