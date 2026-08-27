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

两个 dashboard：`/d/mlobs-jobs`（任务索引，点 job 名进详情）与
`/d/mlobs-job`（单个 job 的七个分区，可带 `?var-job_key=<JOB>` 直达）。

### 认证模型：两个服务

Grafana 本身跑匿名 Admin —— Google 已经证明了身份，再要一个 Grafana 密码不增加
安全性，只增加一个要保管的秘密。而且两层认证会抢同一个 `Authorization` 头（实测：
curl 带 Cloud Run 的 Bearer 再带 Grafana 的 basic auth，后者覆盖前者，必然 403）。
身份验证全部交给 Cloud Run 前面那一层，服务始终私有
（`--no-allow-unauthenticated`）。组织策略
`constraints/iam.allowedPolicyMemberDomains` 禁止 `allUsers`，公开访问本来也不可能。

**IAP 有两个前置条件。** 一是项目要有 OAuth 同意屏幕，没有就报 `Error code 9`
（OAuth 重定向失败），而 IAM 策略读回来都是对的。创建 brand 的 API gcloud 会警告已于
2026-03-19 关停，实测那只针对**新项目**，老项目仍可调用；brand 不可删除。二是这样
建出来的 brand 是 `orgInternalOnly`，只有项目所属组织内的账号能登录，且该字段无法
通过 API 修改（PATCH 返回 404），要改只能去 Cloud Console 的 Google Auth Platform
页面，改成 External 后还必须发布，否则只有 100 人测试名单内的账号能登录。

**关键约束：开启 IAP 后它会拦截该服务的每一个入站请求**，包括携带 ID token 的
IAM 直连请求 —— 回 `Invalid IAP credentials: Invalid JWT audience`，浏览器渲染成
`Error code 9`。所以**一个服务无法同时服务 IAP 用户和 proxy 用户**。组织外账号既
过不了 IAP，也不能绕过 IAP 直连，等于无路可走。

因此 `tpu-for-training` 部署的是一对服务，镜像与服务账号完全相同：

| 服务 | 认证 | 谁用 | 怎么进 |
|---|---|---|---|
| `mlobs-grafana` | IAP | `antgroup.com` | 授 `roles/iap.httpsResourceAccessor`，直接开 URL |
| `mlobs-grafana-direct` | 无 IAP，Cloud Run IAM | 组织外（含 `google.com`） | 授 `roles/run.invoker`，起 proxy |

```bash
# 组织内
gcloud beta iap web add-iam-policy-binding --project <P> \
  --resource-type=cloud-run --service=mlobs-grafana --region=us-central1 \
  --member="user:someone@antgroup.com" --role=roles/iap.httpsResourceAccessor

# 组织外
gcloud run services add-iam-policy-binding mlobs-grafana-direct \
  --project <P> --region us-central1 \
  --member="user:someone@example.com" --role="roles/run.invoker"
gcloud run services proxy mlobs-grafana-direct \
  --project <P> --region us-central1 --port 8080
# → http://localhost:8080/d/mlobs-jobs
```

proxy 必须指向 `-direct`。指向 `mlobs-grafana` 会被 IAP 拦成 `Error code 9`，
而 IAM 策略看起来完全正确 —— 这是最容易误判的一个失败。proxy 要在
**`gcloud auth login` 过的机器**上跑，纯 ADC 签不出 ID token。首次会提示装
`cloud-run-proxy` 组件，apt 版 gcloud 用
`sudo apt-get install google-cloud-cli-cloud-run-proxy`。

`deploy.sh` 部署 `mlobs-grafana`，随后若 `mlobs-grafana-direct` 已存在就把它更新到
同一个镜像，两边内容不会漂。该服务只在已存在时才被触碰 —— 是否要这一对是装的时候
做一次的决定，脚本不替新项目做主。新项目默认只有一个服务且 IAP 关闭
（`ENABLE_IAP` 跟随已部署服务的注解，重新部署不会静默改变别人的进入方式）。

> IAP 开启后，服务自身 `run.invoker` 名单上的用户授权不再起作用，但也不会被清理。
> 判断谁能进一个 IAP 服务，看 IAP 策略，不要看 `run.invoker`。

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
