# ML Training Platform 使用指南（算法工程师版）

本文档面向算法工程师，指导如何提交训练任务、查看日志和监控指标。

---

## 快速开始（5 步提交你的第一个 Job）

```bash
# 1. 克隆仓库，创建你的分支
git clone https://github.com/elbertwang/ml-training-platform.git
cd ml-training-platform
git checkout -b job/你的名字/任务名

# 2. 从模板创建 Job YAML
mkdir -p jobs/你的团队/任务名
cp templates/tpu-single-host.yaml jobs/你的团队/任务名/job.yaml

# 3. 修改 job.yaml（见下方「需要修改的字段」）

# 4. 提交 PR
git add jobs/你的团队/任务名/
git commit -m "Submit job: 任务名"
git push -u origin job/你的名字/任务名
# 在 GitHub 上创建 PR，目标分支选 main

# 5. CI 通过后 merge，Job 自动部署到 GKE
```

---

## 详细步骤

### 1. 创建分支

分支命名规则：`job/<你的名字>/<任务名>`

```bash
git checkout -b job/alice/llama-finetune
```

### 2. 从模板创建 Job YAML

仓库提供两个模板：

| 模板 | 适用场景 |
|------|---------|
| `templates/tpu-single-host.yaml` | 单节点 TPU 训练（最常用） |
| `templates/tpu-multi-slice.yaml` | 多节点多切片 TPU 训练 |

```bash
mkdir -p jobs/my-team/llama-finetune
cp templates/tpu-single-host.yaml jobs/my-team/llama-finetune/job.yaml
```

### 3. 修改 Job YAML

打开 `job.yaml`，只需修改 3 个地方：

#### 3.1 Job 名称

```yaml
metadata:
  name: alice-llama-ft-0324     # 必须全局唯一
```

**命名规则**：`<你的名字>-<任务>-<日期>`，如 `alice-llama-ft-0324`

#### 3.2 训练镜像

```yaml
containers:
  - name: jax-tpu
    image: us-docker.pkg.dev/cloud-tpu-images/jax-ai-image/tpu:latest
```

默认使用 Google 官方 JAX TPU 镜像。如果需要自定义镜像，见下方「自定义训练镜像」章节。

#### 3.3 训练命令

训练脚本推荐使用 heredoc 方式写入临时文件，避免 YAML 引号冲突：

```yaml
command:
  - bash
  - -c
  - |
    pip install google-cloud-mldiagnostics google-cloud-logging your-other-deps

    cat << 'PYEOF' > /tmp/train.py
    import jax
    import jax.numpy as jnp
    # ... 你的训练代码 ...
    PYEOF

    python /tmp/train.py
```

> **重要**：不要在 YAML 的 `|` 块中直接写 `python3 -c '...'`，单引号嵌套会导致脚本静默失败。

### 4. 集成 MLDiagnostics（可选但推荐）

在训练脚本中添加以下代码，即可在 Cluster Director Console 中看到训练指标和 Profiling：

```python
import logging
import time
import google.cloud.logging
from google_cloud_mldiagnostics import machinelearning_run, metrics, xprof, metric_types

# 设置 Cloud Logging
google.cloud.logging.Client().setup_logging()
logging.getLogger().setLevel(logging.INFO)

# 创建 ML Run（Cluster Director 中显示）
try:
    run = machinelearning_run(
        name="alice-llama-ft-0324",           # 与 Job 名称一致
        run_group="llama-experiments",         # 实验分组
        configs={"batch_size": 256, "lr": 1e-4},
        project="tpu-launchpad-playground",    # GCP 项目 ID
        region="us-central1",
        gcs_path="gs://yunpeng-mldiagnostics-profiles",
        on_demand_xprof=True,                  # 启用远程 Profiling
    )
except Exception as e:
    logging.warning(f"MLRun creation failed: {e}")

# 在训练循环中上报指标
for step in range(total_steps):
    t0 = time.time()
    loss = train_step(...)
    step_time = time.time() - t0
    tflops = compute_tflops(step_time)

    if step % 10 == 0:
        try:
            metrics.record_metrics([
                {"metric_name": metric_types.MetricType.LOSS, "value": float(loss)},
                {"metric_name": metric_types.MetricType.STEP_TIME, "value": step_time},
                {"metric_name": metric_types.MetricType.TFLOPS, "value": tflops},
                {"metric_name": metric_types.MetricType.MFU, "value": tflops / 900},
            ], step=step)
        except Exception:
            pass

# Profiling 采集（warmup 后执行）
try:
    with xprof():
        for _ in range(20):
            train_step(...)
except Exception:
    pass
```

**可上报的指标类型**：

| MetricType | 说明 | 建议上报频率 |
|------------|------|------------|
| `LOSS` | 训练损失 | 每 10 步 |
| `LEARNING_RATE` | 学习率 | 每 10 步 |
| `GRADIENT_NORM` | 梯度范数 | 每 10 步 |
| `STEP_TIME` | 每步耗时（秒） | 每 10 步 |
| `TFLOPS` | 每秒万亿浮点运算 | 每 10 步 |
| `THROUGHPUT` | 吞吐量 | 每 10 步 |
| `MFU` | Model FLOPS Utilization | 每 10 步 |
| `TOTAL_WEIGHTS` | 模型参数量 | 每 1000 步 |

### 5. 提交 PR

```bash
git add jobs/my-team/llama-finetune/
git commit -m "Submit job: llama-finetune"
git push -u origin job/alice/llama-finetune
```

在 GitHub 上创建 PR，目标分支选 `main`。

### 6. CI 自动校验

提交 PR 后，Cloud Build 自动执行：

1. **YAML 格式校验** — 检查语法是否正确
2. **TPU 配额检查** — 确保不超过限额（单 Job 最多 8 TPU chips）
3. **Dry-run 验证** — 模拟部署检查 K8s 资源是否合法

等待所有检查通过（绿色 ✓）。

### 7. Review & Merge

团队 Lead 审批 PR 后，merge 到 `main` 分支。Cloud Build 自动执行 `kubectl apply`，Job 部署到 GKE。

---

## 查看日志

你**不需要** kubectl 权限，所有日志都可以通过浏览器查看。

### 方式 1：统一 Dashboard

打开统一 Dashboard：

**https://console.cloud.google.com/monitoring/dashboards?project=tpu-launchpad-playground**

找到 `ML Training Platform - Overview`，Dashboard 分为两个区域：

- **Training Metrics** — Loss、TFLOPS、Step Time、MFU、Learning Rate、Gradient Norm、Throughput
  - 使用顶部 `job_name` 筛选器选择你的 Job
- **Infra Metrics** — TPU 利用率、HBM 内存、Pod CPU/内存、Pod 重启、Node 状态
  - 使用顶部 `cluster_name` 筛选器选择集群
- **底部** — 实时日志面板

### 方式 2：Logs Explorer（搜索/过滤）

打开 [Logs Explorer](https://console.cloud.google.com/logs/query?project=tpu-launchpad-playground)，输入查询：

```
resource.type="k8s_container"
resource.labels.cluster_name="shun-elm-poc-gke"
labels."k8s-pod/jobset_sigs_k8s_io/jobset-name"="你的Job名称"
```

**常用查询模板**：

```
# 查看指定 Job 的所有日志
labels."k8s-pod/jobset_sigs_k8s_io/jobset-name"="alice-llama-ft-0324"

# 只看包含 Step 的日志行
labels."k8s-pod/jobset_sigs_k8s_io/jobset-name"="alice-llama-ft-0324"
textPayload=~"Step"

# 只看错误日志
labels."k8s-pod/jobset_sigs_k8s_io/jobset-name"="alice-llama-ft-0324"
severity>=ERROR
```

---

## 查看训练指标（loss / TFLOPS / MFU）

> 前提：训练脚本中已集成 MLDiagnostics（见上方 Step 4）

### 打开 Cluster Director Console

**https://console.cloud.google.com/cluster-director?project=tpu-launchpad-playground**

1. 找到你的 ML Run（按名称搜索）
2. 点击 **Metrics** tab 查看：
   - Loss 曲线
   - Learning Rate
   - TFLOPS / MFU
   - Step Time
   - TPU 利用率 / HBM 使用量（自动采集）

> 指标从上报到显示可能有 2-5 分钟延迟。

---

## 查看 Profiling

### Programmatic Profiling

在训练脚本中使用 `with xprof()` 采集的 profile 会自动出现在 Cluster Director Console 的 **Profiles** tab。

可以查看：
- **Trace Viewer** — 每个 TPU 核心的操作时间线
- **HLO Op Profile** — 按操作类型汇总统计
- **Graph Viewer** — HLO 计算图

### On-Demand Profiling

训练运行期间可随时触发采集（需要 `on_demand_xprof=True`）：

1. 在 Cluster Director Console 找到你的 ML Run
2. 点击 **Profiles** tab → **Capture Profile**
3. 选择采集时长（默认 2 秒）
4. 等待采集完成

---

## 自定义训练镜像

如果你需要预装特定依赖（避免每次启动 `pip install`），可以构建自定义镜像。

### 编写 Dockerfile

在 `images/` 目录下创建：

```
images/my-training/Dockerfile
```

示例：

```dockerfile
FROM us-docker.pkg.dev/cloud-tpu-images/jax-ai-image/tpu:latest

RUN pip install --no-cache-dir \
    google-cloud-mldiagnostics \
    google-cloud-logging \
    transformers \
    datasets

WORKDIR /app
COPY train.py .
```

### 构建和推送

提交 PR 时如果 `images/` 目录有变更，Cloud Build 会自动构建并推送到 Artifact Registry。

镜像地址格式：
```
us-central1-docker.pkg.dev/tpu-launchpad-playground/ml-training-images/<目录名>:latest
```

在 Job YAML 中使用：
```yaml
image: us-central1-docker.pkg.dev/tpu-launchpad-playground/ml-training-images/my-training:latest
```

---

## 常见问题

### Pod 一直 Pending

| 可能原因 | 解决方案 |
|---------|---------|
| TPU node pool 正在扩容 | 等待 5-15 分钟（flex-start TPU 需要时间） |
| 已有 Job 占用了所有 TPU 节点 | 等其他 Job 完成，或联系平台团队增加 node pool max-nodes |
| nodeSelector 不匹配 | 检查 Job YAML 中的 `gke-tpu-accelerator` 和 `gke-tpu-topology` 是否正确 |

### Job 名称冲突

每个 JobSet 的 `metadata.name` 必须在集群中唯一。命名规则：`<你的名字>-<任务>-<日期>`

### Job 立即 Failed

常见原因：
- 训练脚本有语法错误 → 查看 Logs Explorer 中的日志
- `machinelearning_run()` 抛异常 → 用 try/except 包裹（见 Step 4 示例）
- YAML 中 Python 脚本引号冲突 → 使用 heredoc 方式写入临时文件

### 日志在 Logs Explorer 中看不到

- Cloud Logging 有 1-5 分钟延迟，稍等后再查
- 确认查询中的 Job 名称拼写正确
- 如果使用了 `google.cloud.logging.Client().setup_logging()`，日志通过 API 直接发送，可能在不同的 logName 下

### 如何删除运行中的 Job

联系平台团队，提供 Job 名称：
```
kubectl delete jobset <job-name>
```

### 端口冲突（didn't have free ports）

每个 TPU 节点同时只能运行一个 `hostNetwork: true` 的 Job。如果已有 Job 占用了节点，新 Job 需要等待或使用其他节点。

---

## 仓库目录说明

```
ml-training-platform/
├── jobs/                  # 你的训练任务放这里
│   ├── team-a/            #   按团队分子目录
│   │   └── llama-ft/      #     按任务分子目录
│   │       └── job.yaml   #       Job YAML 文件
│   └── examples/          #   示例 Job
├── templates/             # Job YAML 模板（复制后修改）
├── images/                # 自定义训练镜像 Dockerfile
├── infra/                 # 平台配置（请勿修改）
└── docs/                  # 文档
```

---

## 链接汇总

| 入口 | 链接 |
|------|------|
| GitHub 仓库 | https://github.com/elbertwang/ml-training-platform |
| 统一 Dashboard | https://console.cloud.google.com/monitoring/dashboards?project=tpu-launchpad-playground |
| Cluster Director | https://console.cloud.google.com/cluster-director?project=tpu-launchpad-playground |
| Logs Explorer | https://console.cloud.google.com/logs/query?project=tpu-launchpad-playground |
| Artifact Registry | https://console.cloud.google.com/artifacts?project=tpu-launchpad-playground |
