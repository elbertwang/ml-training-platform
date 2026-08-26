# 日志路由方案：什么留 Cloud Logging，什么建模进 BigQuery

> 附录 C。渠道清单见 [`channel-map.md`](channel-map.md)（那份是**实测底数**，这份是**路由决策**）。
>
> 最后更新：2026-08-26，基于 `tpu-for-training` 实测。

---

## 0. 结论

**判据是「人读」还是「机器算」，不是「内容重不重要」。**

| | 归谁 | 在 Grafana 里长什么样 |
|---|---|---|
| **人要「读」的原文** | Cloud Logging | Logs 面板，`googlecloud-logging-datasource`，`$job` 变量实时过滤 |
| **机器要「算」的事实** | BigQuery | Table / Time series 面板，SQL 排序、聚合、跨渠道 join |

这条判据取代了早期那条「读一次还是读多次」——后者没法直接落到操作上，前者可以：**打开面板的人是在看字，还是在看排名/趋势/告警。**

推论（**这一条修正了之前的建议**）：既然原文可以在 Grafana 里直接读 Cloud Logging，**就不需要为了「能看到」而把日志 sink 进 BQ**。sink 的范围应该**收窄**到「要被算的」，而不是拓宽。

---

## 1. Grafana 两个数据源的实测能力

### 1.1 结论表

| | **BigQuery** `grafana-bigquery-datasource` | **Cloud Logging** `googlecloud-logging-datasource` |
|---|---|---|
| 状态 | **已装**（`serve/grafana/Dockerfile`） | **未装**，需加一行 `grafana cli plugins install` |
| 许可 | Apache-2.0（Grafana Labs） | Apache-2.0（GoogleCloudPlatform），v1.7.0，24 stars，2026-08-17 仍在更新 |
| Grafana 版本要求 | 12.4.3 在支持范围内 | 需要 ≥ 11.2.0，我们是 12.4.3 ✓ |
| 认证 | `gce`（Cloud Run SA，无密钥文件） | 同样支持 `gce` ✓ |
| 查询语言 | SQL | LQL（Logging Query Language） |
| **模板变量** | 支持 | **支持** —— `applyTemplateVariables` 对整条 `queryText` 插值，`$job` 可直接写进 LQL |
| **告警** | 支持 | **不支持**（官方明确说明，因 LQL 的工作方式；变通是先建 log-based metric 再用 Cloud Monitoring 数据源） |
| **返回条数** | SQL 自己控制 | **等于面板的 `MaxDataPoints`**，单页上限 1000 |
| 排序 / group by / 百分位 | 原生 | **做不到** |
| 跨渠道 join | 原生 | **做不到** |
| 历史深度 | 取决于我们建模多深 | `_Default` 保留期 **30 天**（已实测） |
| 数据新鲜度 | sink + refresh 周期（分钟级起） | **实时** |
| 查询成本 | 每次扫描计费 | 不额外计费（ingest 已付） |
| 保真度 | 只有 sink 过滤后留下的 | **全量** |

### 1.2 决定性的两条

**① 返回条数 = 面板宽度。** 插件后端把 `query.MaxDataPoints` 直接当作日志条数上限（`pkg/plugin/plugin.go:421`，`Limit: query.MaxDataPoints`），再和 1000 取小（`client.go:342`）。`MaxDataPoints` 在 Grafana 里由面板像素宽度推导——**把面板拉宽，返回的日志条数会变**。

这不是缺陷，是定位：它是**查看器**，不是数据源。任何「完整性重要」的用途（计数、比例、有没有漏）都不能建在它上面。

**② 不支持告警。** 所以「TPU 驱动报错了要告警」这类需求，必须走 BQ，或者走 log-based metric + Cloud Monitoring。Cloud Logging 数据源在这条路上是死的。

### 1.3 对业务易用性的意义

算法同学点进「日志」页，理想形态是**一个页面两层，同一个 `$job` 变量联动**：

```
┌─ 上层：BQ 驱动 —— 「发生了什么」 ────────────────────┐
│  事故时间线 (fact_event)   错误 Top N   goodput 曲线   │   ← 要排序/聚合/join
├─ 下层：Cloud Logging 驱动 —— 「原文长什么样」 ────────┤
│  实时日志流，按 $job / $pod / $severity 过滤          │   ← 要保真/实时/零建模
└──────────────────────────────────────────────────────┘
```

上层回答「哪里不对」，下层回答「具体是什么」。**两层都不需要另一层的能力**，所以不存在「哪个更方便」的问题——缺任何一层这个页面都不成立。

---

## 2. 四层模型

| 层 | 处理 | 一行 = | 谁读 | 成本 |
|---|---|---|---|---|
| **L0** | 不 sink，Grafana 里用 Cloud Logging 数据源直接查 | 一条日志 | **人** | $0（ingest 已付） |
| **L1** | sink 落 `mlobs_raw`，不建模 | 一条日志 | L2 的构建过程 | BQ 存储 |
| **L2** | 从 L1/API **抽**出事实，落 `mlobs_core` | **一个事件 / 一个度量点** | **机器**（面板、告警） | BQ 扫描 |
| **L3** | 实体维度表 | **一个实体** | join 用 | 极小 |

**硬规矩（这条能挡住一整类 bug）：**

> `mlobs_core` 里任何一张表，如果一行等于一条日志行，那它就放错层了。
> `dim_*` 一行必须是一个实体，`fact_*` 一行必须是一个事件或一个度量点。

这条规矩的由来是三次真实事故，形状完全一样——把 L1 的东西直接堆进 L2：

| 事故 | 干了什么 | 如果不修 |
|---|---|---|
| `fact_event` 扫 `defaultLink` | 每次重建读原始日志 | $1,240/月 |
| `fact_metric` 全量重建 | 每次重算全历史 | $88/月 |
| `pod_labels_backfill` | 19 亿行日志表达 8,746 个 pod | $10,151/月 |

三次都已修复。第三次的详情见 `collect/dedupe_pod_labels_backfill.sh`。

**同一个渠道可以同时属于 L0 和 L2。** 渠道不是分类单位，问题才是。最典型的是 TPU 驱动日志：250 万行原文留 L0，只把每小时 23,927 条 `END_TO_END stage duration` 抽成 L2 的编译耗时。

---

## 3. 全渠道路由

**图例**：✅ 已实现 · 🔧 要改 · ⬜ 待建 · ⛔ 明确不做

### 3.1 L-pod（6 个渠道，直接归属）

| 渠道 | 3h 量 | 路由 | 状态 |
|---|---|---|---|
| `stderr` / `jax-tpu` —— `completed step` 行 | 526,910 中 580k 累计 | **L1 → L2 `fact_step`** | ⬜ 未建模。要按 `job-completion-index` 去重（64 个 pod 打同样的 step，但 TFLOPs 各不相同） |
| `stderr` / `jax-tpu` —— 错误与警告 | 同上 | **L1 → L2 `app_error`**（按签名+分钟折叠） | ✅ |
| `stderr` / `jax-tpu` —— `Thread 0x` 栈转储 | 704 个 pod 里只有 3–6 个会打 | **L0 原文 + L2 只记「发生了栈转储」** | ⬜ 原文绝不能进 BQ；但「哪个 rank 卡了」是关键事实 |
| `stdout` / `jax-tpu` | 10,901 | **L1** | ✅ |
| `events` (k8s_pod) | 640 | **L1 → L2 `k8s_event`** | 🔧 falcon-jobs 里 27% 归不到 job |
| `stdout`+`stderr` / gcsfuse sidecar 三件套 | 24,792 | **L0** —— 有 12 个 `gcsfusecsi/*` 指标可用，原文只在排查时读 | ✅（当前只收 ERROR+，够了） |

### 3.2 L-node（21 个渠道，一跳归属）

> **归属语义**：「这个 job 的某个节点上发生的」≠「这个 job 造成的」。TPU 训练 1 pod 1 节点，关联度高，但推因果要小心。

| 渠道 | 3h 量 | 路由 | 状态 |
|---|---|---|---|
| **`sidecar-log-collector`**（TPU 驱动日志转发） | 61,961 行 / 底层 250 万行 | **L0 原文** + **L2 抽 `deepsea_compiler_*` 编译耗时** | ⬜ **修正了之前的建议**：原文不 sink，用 Cloud Logging 数据源读。只有编译耗时进 BQ（无任何指标替代） |
| **`tpu-device-plugin`**（驱动层） | 68,582 | **L0 原文** + **L2 抽故障事件** | ⬜ 当前只收 ERROR+ |
| **`vbar-control-agent`**（板级控制） | 22,401 | **L0 原文** + **L2 抽故障事件** | ⬜ 同上 |
| `events` (k8s_node) —— OOM / NotReady / 修复 | 3,632 | **L1 → L2**，走 node→job 一跳 | 🔧 **17,710 条 `OOMKilling` 完全没有 pod name，现在全是孤儿** |
| `maintenance-handler` | 79,232 | **L0** + **L2 中断事件** | ⬜ 中断归因用 |
| `gcs-fuse-csi-driver` | 469,276 | **L0**（有指标替代） | ✅ 只收 ERROR+ |
| `gke-managed-checkpointing/csi` | 3,777 | **L0** | ⬜ checkpoint 慢的时候读 |
| `kubelet` / `container-runtime` | 8,853 | **L0** | ✅ |
| serial console | 14 | **L0** | ⬜ 罕见但关键，只在硬件故障时读 |
| `fluentbit` / `kube-proxy` / `gke-metadata-server` / `netd` / `gce-pd-driver` / `gke-metrics-agent` / GMP prometheus / 4 个 metrics-collector | ~356,000 | ⛔ **L0，且应从 sink 排除** | 🔧 **现在误收了 7 万行**（`fluentbit` 70,199 + `kube_proxy` 447 + `GCEGuestAgent` 456） |
| XLA `GetUnconstrained` verbosity | 116,575+ | ⛔ **永不收** | ✅ 本来就没收 |

### 3.3 L-cluster（2 个渠道，不归属）

| 渠道 | 3h 量 | 路由 | 状态 |
|---|---|---|---|
| `events` (k8s_cluster) —— `Job completed` / JobSet 状态 | 1,854 | **L1 → L2** | ✅ |
| `cluster-autoscaler-visibility` | 732 | **L1 → L2** | 🔧 3,365 条 **100% 归不到 job**，见 §4 TBD-6 |

### 3.4 L-api（4 个渠道）

| 渠道 | 3h 量 | 路由 | 状态 |
|---|---|---|---|
| `ml_diagnostics_workload_event` —— 含 `WORKLOAD_TERMINATION` | 198 | **L1 → L2** | ⬜ **已 sink 但未建模**。REST API 五个月没返回过一条 TERMINATION，只有这条流有 |
| `ml_diagnostic_workload_performance` —— 10 秒 0–1 性能比 | 3,549 | **L1 → L2 `fact_metric`** | ⬜ **完全没采集**。比我们的 goodput 细 30 倍 |
| `tpu.googleapis.com/runtime_monitor` | 649 | **L1 → L2** | ⬜ 已 sink 未建模 |
| ML Diagnostics REST API | 13.4k runs | **L2 `dim_mlrun` / `fact_mlrun_event`** | ✅ 但 poller 未排期 |
| GKE Operations API —— 节点池修复事件 | — | **L2** | ⬜ falcon 有专属节点池，可归属 |

---

## 4. 待解决（TBD）

按严重度排。**P0 三条互相咬合，要一起做，单做任何一条都会被另外两条抵消。**

| # | 事项 | 现状 | 影响 | 需要决策 |
|---|---|---|---|---|
| **TBD-1** | **历史深度只有 3 天** | `dim_pod` 最早 08-23；`defaultLink` 有 07-27 起共 30 天；**08-20 单天就有 10,317 个 pod / 21.9 亿行，我们一个都没有** | 「历史所有 job 的启动/停止/占卡数」这个核心目标现在只能回答 3 天 | **要不要花 ~$56 一次性扫 8.9 TB 把 30 天补齐？** |
| **TBD-2** | **`dim_pod` 会遗忘** | `CREATE OR REPLACE` + 30 天滚动窗口 | 就算补齐，第 31 天旧数据照样掉。**维度表不能滚动重建，必须 MERGE 累积** | 无（确定要改） |
| **TBD-3** | **`refresh.sh` 未排期** | 数据停在 08-25 05:44 | 一切都不刷新 | Cloud Run Job + Cloud Scheduler，周期定多少 |
| **TBD-4** | **L-node 一跳归属完全没实现** | 21 个 L-node 渠道，`fact_event` 里一个都没接 | 17,710 条 `OOMKilling` 全部落不到 job | 无（确定要做） |
| **TBD-5** | **falcon-jobs 27% 事件归不到 job** | 12,211 未归属 / 33,597 已归属。其中 `SuccessfulCreate` 4,273 条其实可归属——pod 名在正文里（`Created pod: falcon-job-...`），但 `involvedObject` 是 Job 不是 Pod | 事件进了时间轴却落不到任何 job | 无（确定要做） |
| **TBD-6** | **autoscaler 归属：定性** | 3,365 条 100% 未归属。`channel-map.md` 说它是 L-cluster「不归属，按时间对齐」，但 falcon 有专属节点池，理论上能归属 | 两种说法现在都写在文档里，自相矛盾 | **选一个：实现 node-pool 归属，还是承认只做时间对齐** |
| **TBD-7** | **`sidecar-log-collector` 在 crash-loop** | `BackOff` **18,155 次**，全在这个容器 | TPU 驱动日志本身可能是断续的。**在修好之前，从它抽出的任何指标都有采样缺口** | 是客户侧问题还是配置问题，要先定位 |
| **TBD-8** | **sink 误收了系统日志** | `fluentbit` 70,199 + `kube_proxy` 447 + `GCEGuestAgent` 456 | 存储浪费，且污染 L1 | 无（加排除条件即可） |
| **TBD-9** | **Cloud Logging 数据源未装** | Grafana 里只有 BQ + Cloud Monitoring | 「原文」那一层现在没有承载 | 无（Dockerfile 加一行） |
| **TBD-10** | **要不要用排除过滤器省 ingest** | 未做 | sink + `_Default` 排除**能**免掉 $0.50/GiB。**但一旦排除，L0 就不成立了**——省了 ingest 就换不回 Logs Explorer 能查 | 对 TPU 驱动日志这种量级（一个 64-pod jobset 3 小时 250 万行）值不值得 |

### 客户侧 TBD（不在我们控制范围）

| 事项 | 状态 |
|---|---|
| kubemaker → JobSet 迁移 | 进行中。完成后 1,540 个 falcon job 白拿 GKE 原生 goodput |
| All Capacity topology 模式 | 集群未启用 |
| `use_vertex_tensorboard=true` / `ENABLE_GOODPUT=true` | 未开 |
| TensorBoard | 先留空，只提供 `base_output_directory/{run_name}/tensorboard/` 的 GCS 路径 |

---

## 5. 落地顺序

```
第一批（互相咬合，一起做）
  TBD-2  dim_pod 改 MERGE 累积
  TBD-1  回填补到 30 天         ← 等 TBD-2 先改完，否则白花 $56
  TBD-3  refresh.sh 排期

第二批（归属修复，让已收的数据能用）
  TBD-4  L-node 一跳（先接 OOMKilling / 节点事件）
  TBD-5  falcon 27% 缺口 + SuccessfulCreate 从正文取 pod 名
  TBD-6  autoscaler 定性
  TBD-8  sink 排除系统日志

第三批（补齐渠道）
  TBD-9  装 Cloud Logging 数据源 —— 成本最低、见效最快，可以提前做
  ML Diagnostics 两条子流（WORKLOAD_TERMINATION + 10 秒性能比）
  TBD-7  先定位 crash-loop，再抽 TPU 驱动的编译耗时
  TBD-10 排除过滤器的取舍
```

**TBD-9 可以插队先做**：装个插件、加个数据源，就能让「看原文」这一层立刻可用，而且它不依赖上面任何一条。
