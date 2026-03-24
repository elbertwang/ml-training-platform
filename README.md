# ML Training Platform

GCP GKE + TPU 算法团队训练任务管理平台。

## 快速开始

1. 克隆仓库并创建分支：
   ```bash
   git clone https://github.com/elbertwang/ml-training-platform.git
   cd ml-training-platform
   git checkout -b job/<你的名字>/<任务名>
   ```

2. 从模板创建 Job：
   ```bash
   mkdir -p jobs/<team>/<task-name>
   cp templates/tpu-single-host.yaml jobs/<team>/<task-name>/job.yaml
   ```

3. 修改 `job.yaml` 中的：
   - `metadata.name` — 任务名称（唯一）
   - `image` — 训练镜像
   - `command` — 训练命令

4. 提交 PR：
   ```bash
   git add jobs/<team>/<task-name>/
   git commit -m "Submit training job: <task-name>"
   git push -u origin job/<你的名字>/<任务名>
   ```
   然后在 GitHub 创建 PR → CI 自动校验 → Review → Merge → 自动部署

## 查看日志和监控

- **统一 Dashboard**: [Cloud Monitoring Dashboard](https://console.cloud.google.com/monitoring/dashboards?project=tpu-launchpad-playground)
- **训练指标 (loss/TFLOPS/MFU)**: [Cluster Director Console](https://console.cloud.google.com/cluster-director?project=tpu-launchpad-playground)
- **日志搜索**: [Logs Explorer](https://console.cloud.google.com/logs/query?project=tpu-launchpad-playground)

详见 [docs/](docs/) 目录。

## 仓库结构

```
├── infra/          # 平台配置（平台团队维护）
├── jobs/           # 训练任务（算法团队提交）
├── images/         # 自定义训练镜像
├── templates/      # Job YAML 模板
└── docs/           # 使用文档
```

## 分支策略

- `main` — 保护分支，merge 自动部署
- `job/*` — 算法团队提交训练任务
- `feature/*` — 平台团队修改基础设施
