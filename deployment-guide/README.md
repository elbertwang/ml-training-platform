# ML Training Platform 部署与使用指南

本目录包含在 GCP GKE + TPU 环境中部署和使用 ML Training Platform 所需的全部文档和脚本。

---

## 文档

| 文档 | 面向角色 | 说明 |
|------|---------|------|
| [architect-deployment-guide.md](architect-deployment-guide.md) | 平台架构师 | 从零部署整套系统：GKE 基础设施、Workload Identity、MLDiagnostics、CI/CD、监控 |
| [algorithm-engineer-guide.md](algorithm-engineer-guide.md) | 算法工程师 | 提交训练 Job、查看日志、监控指标、Profiling |

## 脚本

| 脚本 | 用途 |
|------|------|
| [setup.sh](setup.sh) | 一次性 GCP 配置：Cloud Build SA 授权、Artifact Registry、Triggers、Dashboard |
| [create-log-metrics.sh](create-log-metrics.sh) | 创建 7 个 log-based metrics（loss/TFLOPS/MFU 等），用于 Dashboard 训练指标图表 |

## 配置

| 文件 | 用途 |
|------|------|
| [dashboard.json](dashboard.json) | Cloud Monitoring Dashboard 定义，包含 Training Metrics 和 Infra Metrics 两个 Section |

---

## 快速开始

### 架构师：部署平台

```bash
# 1. 修改变量（见 architect-deployment-guide.md 顶部）
# 2. 按文档执行 Step 1-7
# 3. 运行脚本
bash setup.sh
bash create-log-metrics.sh
```

### 算法工程师：提交 Job

```bash
# 1. 克隆仓库、创建分支
git clone https://github.com/elbertwang/ml-training-platform.git
git checkout -b job/<你的名字>/<任务名>

# 2. 从模板创建 Job YAML
cp templates/tpu-single-host.yaml jobs/<团队>/<任务>/job.yaml

# 3. 修改 job.yaml，提交 PR，merge 后自动部署
```

详见 [algorithm-engineer-guide.md](algorithm-engineer-guide.md)。

---

## 系统架构

```
算法工程师 ─── PR ──▶ GitHub ──── Webhook ──▶ Cloud Build
                                                  │
                       ┌──────────────────────────┘
                       ▼
              GKE Cluster (TPU)
                       │
         ┌─────────────┼─────────────┐
         ▼             ▼             ▼
   Cloud Logging   Cloud Monitoring  Cluster Director
   (Job 日志)      (Infra 指标)      (训练指标 + Profiling)
         │             │             │
         └─────────────┼─────────────┘
                       ▼
              统一 Dashboard
```
