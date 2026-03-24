# Getting Started

## Prerequisites

- GitHub 账号，已加入 `elbertwang/ml-training-platform` 仓库
- Google Cloud 项目 `tpu-launchpad-playground` 的访问权限
- 基本的 Git 操作知识

## 提交训练任务

详见 [submit-job.md](submit-job.md)

## 查看日志和监控

详见 [monitoring.md](monitoring.md)

## 仓库结构

```
ml-training-platform/
├── jobs/           # 你的训练任务放这里
├── templates/      # Job YAML 模板（复制后修改）
├── images/         # 自定义训练镜像（如需要）
├── infra/          # 平台配置（不要修改）
└── docs/           # 文档
```

## 常见问题

### Pod 一直 Pending？
- TPU node pool 需要自动扩容，可能需要 5-15 分钟
- 检查 nodeSelector 是否与 node pool 的 labels 匹配

### Job 名称冲突？
- 每个 JobSet 的 `metadata.name` 必须唯一
- 建议命名规则：`<你的名字>-<任务>-<日期>`，如 `alice-llama-ft-0324`

### 如何删除运行中的 Job？
- 联系平台团队执行 `kubectl delete jobset <name>`
