# ML Training Platform 部署指南（架构师版）

本文档面向平台架构师，指导如何在一个新的 GCP 项目中从零部署 ML Training Platform。

---

## 变量定义

以下步骤中的变量请替换为你自己项目的值：

```bash
export PROJECT_ID="your-project-id"
export CLUSTER_NAME="your-cluster-name"
export REGION="us-central1"
export ZONE="us-central1-c"
export BUCKET_NAME="your-mldiag-profiles"
export TPU_MACHINE_TYPE="tpu7x-standard-4t"
export NODE_POOL_NAME="np-mldiag-tpu"
export GITHUB_OWNER="your-github-org"
export GITHUB_REPO="ml-training-platform"
```

---

## 前提条件

| 项目 | 要求 |
|------|------|
| GCP 项目 | 已创建，有 Owner 或 Editor 权限 |
| GKE 集群 | Regional 集群，已启用 Workload Identity |
| JobSet CRD | GKE 1.27+ 默认已安装 |
| 工具 | gcloud、kubectl、helm、gh（GitHub CLI） |
| GitHub 仓库 | Fork 或 clone 本仓库到你的 GitHub 组织 |

---

## Step 1: Fork 仓库并修改配置

```bash
# Fork 本仓库到你的 GitHub 组织
gh repo fork elbertwang/ml-training-platform --org=$GITHUB_OWNER --clone

cd ml-training-platform
```

需要修改的文件：

| 文件 | 修改内容 |
|------|---------|
| `infra/cloudbuild/cloudbuild-pr.yaml` | `CLOUDSDK_CONTAINER_CLUSTER` 改为你的集群名 |
| `infra/cloudbuild/cloudbuild-deploy.yaml` | `CLOUDSDK_CONTAINER_CLUSTER` 改为你的集群名 |
| `infra/monitoring/dashboard.json` | 所有 `cluster_name` 过滤条件改为你的集群名 |
| `infra/setup/setup.sh` | 修改顶部的变量定义 |
| `templates/*.yaml` | 修改 `nodeSelector` 中的 node pool 名和 TPU 类型 |
| `.github/CODEOWNERS` | 修改为你的团队成员 |

---

## Step 2: GKE 集群基础设施

### 2.1 启用所需 API

```bash
gcloud services enable hypercomputecluster.googleapis.com --project=$PROJECT_ID
gcloud services enable cloudbuild.googleapis.com --project=$PROJECT_ID
gcloud services enable secretmanager.googleapis.com --project=$PROJECT_ID
gcloud services enable artifactregistry.googleapis.com --project=$PROJECT_ID
```

> **注意**：Cluster Director API 名是 `hypercomputecluster.googleapis.com`，不是 `clusterdirector`。

### 2.2 启用 Log Analytics

Cluster Director Console 的 Metrics 图表依赖 Log Analytics。如果未启用，Metrics 页面将为空。

```bash
# 启用 _Default log bucket 的 Log Analytics
gcloud logging buckets update _Default \
  --location=global \
  --enable-analytics \
  --project=$PROJECT_ID

# 创建 linked BigQuery dataset
gcloud logging links create defaultLink \
  --bucket=_Default \
  --location=global \
  --project=$PROJECT_ID
```

验证：

```bash
gcloud logging buckets describe _Default \
  --location=global \
  --project=$PROJECT_ID \
  --format="value(analyticsEnabled)"
# 应输出: true
```

### 2.3 创建 GCS Bucket（存储 Profiling 数据）

```bash
gsutil mb -l $REGION gs://$BUCKET_NAME/

# 授予 Hypercompute SA 访问权限
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")
gsutil iam ch \
  serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-hypercomputecluster.iam.gserviceaccount.com:roles/storage.admin \
  gs://$BUCKET_NAME/
```

### 2.4 创建 TPU Node Pool

```bash
gcloud container node-pools create $NODE_POOL_NAME \
  --location=$REGION \
  --cluster=$CLUSTER_NAME \
  --node-locations=$ZONE \
  --machine-type=$TPU_MACHINE_TYPE \
  --num-nodes=0 --min-nodes=0 --max-nodes=2 \
  --scopes=https://www.googleapis.com/auth/cloud-platform \
  --enable-autoscaling \
  --reservation-affinity=none \
  --flex-start
```

> **踩坑提醒**：
> - tpu7x 创建 node pool 时**不要**加 `--tpu-topology` 参数
> - 必须加 `--flex-start` 和 `--reservation-affinity=none`（如无 reservation）
> - `--max-nodes` 建议至少 2，否则一个 job 占满后新 job 无法调度

创建完成后，记录 node pool 的 TPU labels：

```bash
kubectl get nodes -l cloud.google.com/gke-nodepool=$NODE_POOL_NAME \
  -o jsonpath='{.items[0].metadata.labels}' | python3 -m json.tool | grep tpu
```

记下 `gke-tpu-accelerator`（如 `tpu7x`）和 `gke-tpu-topology`（如 `2x2x1`），后续模板中需要用。

---

## Step 3: Workload Identity 配置

### 3.1 创建 Service Account

```bash
# K8s ServiceAccount
kubectl create serviceaccount mldiag-sa -n default

# GCP ServiceAccount
gcloud iam service-accounts create mldiag-sa --project=$PROJECT_ID
```

### 3.2 绑定 IAM 角色

```bash
SA_EMAIL="mldiag-sa@${PROJECT_ID}.iam.gserviceaccount.com"

# Cluster Director 权限（角色名是 hypercomputecluster，不是 clusterdirector）
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/hypercomputecluster.editor"

# Cloud Logging 写入权限
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/logging.logWriter"

# GCS 存储权限（Profiling 数据）
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/storage.objectUser"
```

### 3.3 Workload Identity 绑定

```bash
# 允许 K8s SA 使用 GCP SA 的身份
gcloud iam service-accounts add-iam-policy-binding $SA_EMAIL \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[default/mldiag-sa]"

# 在 K8s SA 上添加注解（注意项目名必须正确）
kubectl annotate serviceaccount mldiag-sa -n default \
  iam.gke.io/gcp-service-account=$SA_EMAIL
```

> **踩坑提醒**：K8s SA 的 `iam.gke.io/gcp-service-account` 注解中的项目名**必须**与 GCP SA 所在项目一致。如果写错项目名，Pod 会拿到错误的身份，导致 403 权限错误。

---

## Step 4: 安装 MLDiagnostics 组件

### 4.1 安装 Helm

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### 4.2 安装 cert-manager

cert-manager 是 mldiagnostics injection-webhook 的前置依赖。

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.13.0 \
  --set installCRDs=true \
  --set global.leaderElection.namespace=cert-manager \
  --timeout 10m
```

验证：

```bash
kubectl get pods -n cert-manager
# 3 个 pod 都应为 Running
```

### 4.3 安装 mldiagnostics-injection-webhook

为 SDK 注入元数据（JobSet/RayJob/LWS 的 pod 自动注入 `GKE_DIAGON_METADATA` 环境变量）。

```bash
helm upgrade --install mldiagnostics-injection-webhook \
  --namespace=gke-mldiagnostics \
  --create-namespace \
  oci://us-docker.pkg.dev/ai-on-gke/mldiagnostics-webhook-and-operator-helm/mldiagnostics-injection-webhook
```

### 4.4 安装 mldiagnostics-connection-operator

用于 on-demand profiling 时自动发现 GKE 节点。

```bash
helm upgrade --install mldiagnostics-connection-operator \
  --namespace=gke-mldiagnostics \
  --create-namespace \
  oci://us-docker.pkg.dev/ai-on-gke/mldiagnostics-webhook-and-operator-helm/mldiagnostics-connection-operator
```

验证：

```bash
kubectl get pods -n gke-mldiagnostics
# webhook (3 replicas) + operator (1 replica) 都应为 Running
```

### 4.5 标记 Namespace

触发 injection-webhook 对该 namespace 下的 workload 注入元数据。

```bash
kubectl label namespace default managed-mldiagnostics-gke=true
```

---

## Step 5: CI/CD 配置（Cloud Build）

### 5.1 连接 GitHub 到 Cloud Build

```bash
# 创建 GitHub connection（会输出一个 OAuth 授权链接）
gcloud builds connections create github "github-connection" \
  --region=$REGION \
  --project=$PROJECT_ID

# ⚠️ 按照输出的链接，在浏览器中完成 GitHub OAuth 授权

# 验证连接状态
gcloud builds connections describe github-connection \
  --region=$REGION --project=$PROJECT_ID
# installationState.stage 应为 COMPLETE

# Link 仓库
gcloud builds repositories create $GITHUB_REPO \
  --remote-uri=https://github.com/$GITHUB_OWNER/$GITHUB_REPO.git \
  --connection=github-connection \
  --region=$REGION \
  --project=$PROJECT_ID
```

### 5.2 创建 Artifact Registry

```bash
gcloud artifacts repositories create ml-training-images \
  --repository-format=docker \
  --location=$REGION \
  --project=$PROJECT_ID
```

### 5.3 授权 Cloud Build SA

```bash
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

# 授权访问 GKE
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/container.developer"

# 授权 Cloud Build
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/cloudbuild.builds.builder"

# 授权读取 GitHub 连接凭证
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# 授权写日志
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/logging.logWriter"
```

### 5.4 创建 Triggers

```bash
REPO_PATH="projects/$PROJECT_ID/locations/$REGION/connections/github-connection/repositories/$GITHUB_REPO"

# PR 校验 Trigger（匹配目标分支为 main 的 PR）
gcloud builds triggers create github \
  --name="ml-platform-pr-check" \
  --repository="$REPO_PATH" \
  --pull-request-pattern="^main$" \
  --build-config="infra/cloudbuild/cloudbuild-pr.yaml" \
  --region=$REGION \
  --service-account="projects/$PROJECT_ID/serviceAccounts/${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --project=$PROJECT_ID

# 部署 Trigger（push 到 main 时触发）
gcloud builds triggers create github \
  --name="ml-platform-deploy" \
  --repository="$REPO_PATH" \
  --branch-pattern="^main$" \
  --build-config="infra/cloudbuild/cloudbuild-deploy.yaml" \
  --region=$REGION \
  --service-account="projects/$PROJECT_ID/serviceAccounts/${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --project=$PROJECT_ID
```

> **注意**：
> - 2nd gen triggers 必须指定 `--service-account`，否则会报 `INVALID_ARGUMENT`
> - PR trigger 的 `--pull-request-pattern` 匹配的是 **base branch**（PR 目标分支），不是 source branch

验证：

```bash
gcloud builds triggers list --region=$REGION --project=$PROJECT_ID
```

---

## Step 6: 监控配置

### 6.1 创建 Cloud Monitoring Dashboard

先修改 `infra/monitoring/dashboard.json` 中所有 `cluster_name` 为你的集群名，然后：

```bash
gcloud monitoring dashboards create \
  --config-from-file=infra/monitoring/dashboard.json \
  --project=$PROJECT_ID
```

Dashboard 包含：
- 顶部快捷链接（Cluster Director / Logs Explorer / 提交文档）
- TPU 利用率 + HBM 内存
- Pod CPU / 内存
- 实时日志面板
- Pod 重启计数 + Node 状态

### 6.2 授权算法团队

```bash
ALGO_TEAM_GROUP="group:algo-team@your-domain.com"

# 日志查看
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="$ALGO_TEAM_GROUP" \
  --role="roles/logging.viewer"

# 监控仪表盘查看
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="$ALGO_TEAM_GROUP" \
  --role="roles/monitoring.viewer"

# Cluster Director Console 查看（训练指标 + Profiling）
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="$ALGO_TEAM_GROUP" \
  --role="roles/hypercomputecluster.viewer"
```

---

## Step 7: 验证

### 7.1 验证清单

| 检查项 | 命令 | 预期 |
|--------|------|------|
| GKE 集群可访问 | `kubectl get nodes` | 列出节点 |
| TPU node pool 存在 | `kubectl get nodes -l cloud.google.com/gke-nodepool=$NODE_POOL_NAME` | 0 或更多节点 |
| mldiag SA 存在 | `kubectl get sa mldiag-sa` | 存在 |
| Workload Identity 注解正确 | `kubectl get sa mldiag-sa -o yaml \| grep gcp-service-account` | 指向正确的 GCP SA |
| MLDiagnostics 组件运行中 | `kubectl get pods -n gke-mldiagnostics` | 4 个 pod Running |
| namespace 已标记 | `kubectl get ns default --show-labels \| grep mldiag` | 有 `managed-mldiagnostics-gke=true` |
| Cloud Build triggers 存在 | `gcloud builds triggers list --region=$REGION` | 2 个 triggers |
| Dashboard 已创建 | `gcloud monitoring dashboards list` | 有 `ML Training Platform` |
| Artifact Registry 存在 | `gcloud artifacts repositories list --location=$REGION` | 有 `ml-training-images` |

### 7.2 端到端烟雾测试

```bash
# 1. 部署示例 Job
kubectl apply -f jobs/examples/gemm-demo/job.yaml

# 2. 监控 pod 状态（TPU 扩容可能需要 5-15 分钟）
kubectl get pods -l jobset.sigs.k8s.io/jobset-name=gemm-demo -w

# 3. 查看日志
kubectl logs -l jobset.sigs.k8s.io/jobset-name=gemm-demo -c jax-tpu -f

# 4. 验证 Dashboard 有数据
# 打开 Cloud Monitoring Dashboard 查看 TPU 利用率和日志

# 5. 清理
kubectl delete jobset gemm-demo
```

---

## 踩坑总结

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| Cluster Director Console metrics 为空 | 未启用 Log Analytics | Step 2.2：启用 `_Default` bucket analytics |
| IAM 角色 `clusterdirector.editor` 无效 | 实际角色名是 `hypercomputecluster.editor` | 使用 `roles/hypercomputecluster.editor` |
| API `clusterdirector.googleapis.com` 不存在 | 实际 API 名是 `hypercomputecluster.googleapis.com` | Step 2.1 |
| 创建 node pool 报 placement policy 错误 | tpu7x 不支持传统 placement policy | 去掉 `--tpu-topology`，加 `--flex-start` |
| 2nd gen trigger 报 `INVALID_ARGUMENT` | 未指定 `--service-account` | Step 5.4：添加 `--service-account` 参数 |
| PR trigger 不触发 | `--pull-request-pattern` 匹配的是 base branch | 设置为 `^main$`，不是 source branch pattern |
| Pod 403 权限错误 | Workload Identity 注解中项目名写错 | 确认注解与 GCP SA 项目一致 |
| Pod Pending: `didn't have free ports` | `hostNetwork: true` 端口冲突 | 删除同节点上的旧 pod，或增大 `--max-nodes` |
| Autoscaler 不扩容 | `max-nodes=1` 且已满 | 增大 node pool 的 `--max-nodes` |
| `machinelearning_run()` 抛异常导致 Job 失败 | SA 权限不足但未捕获异常 | 训练脚本中用 try/except 包裹 MLRun 调用 |
| quota check 步骤报 `ModuleNotFoundError: yaml` | Cloud Build 容器无 pyyaml | pipeline 中先 `pip install pyyaml` |

---

## 架构概览

```
算法工程师                          GitHub                          Cloud Build
  │                                  │                                  │
  │  1. 创建 job/* 分支              │                                  │
  │  2. 提交 Job YAML                │                                  │
  │  3. 创建 PR ──────────────────▶  │                                  │
  │                                  │  4. Webhook ──────────────────▶  │
  │                                  │                                  │  5. YAML 校验
  │                                  │                                  │  6. Quota 检查
  │                                  │  7. Status check ◀────────────  │  7. Dry-run
  │  8. Review + Merge               │                                  │
  │                                  │  9. Push event ───────────────▶  │
  │                                  │                                  │  10. kubectl apply
  │                                  │                                  │       │
  │                                  │                                  │       ▼
  │                                  │                                GKE Cluster
  │                                  │                                  │
  │  11. 查看 Dashboard ────────────────────────────────────────▶  Cloud Monitoring
  │  12. 查看 Metrics ──────────────────────────────────────────▶  Cluster Director
  │  13. 查看 Logs ─────────────────────────────────────────────▶  Logs Explorer
```
