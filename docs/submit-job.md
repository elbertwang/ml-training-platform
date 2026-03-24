# How to Submit a Training Job

## Step 1: Clone and Branch

```bash
git clone https://github.com/elbertwang/ml-training-platform.git
cd ml-training-platform
git checkout -b job/<your-name>/<task-name>
```

## Step 2: Create Job YAML

```bash
mkdir -p jobs/<team>/<task-name>
cp templates/tpu-single-host.yaml jobs/<team>/<task-name>/job.yaml
```

## Step 3: Edit Job YAML

Open `job.yaml` and modify the following fields:

```yaml
metadata:
  name: alice-llama-ft-0324        # unique job name

containers:
  - name: jax-tpu
    image: your-image:tag          # your training image
    command:
      - bash
      - -c
      - |
        pip install your-dependencies
        python your_training_script.py
```

### Tips

- **Job name** must be unique across the cluster. Use format: `<name>-<task>-<date>`
- **Image**: Use `us-docker.pkg.dev/cloud-tpu-images/jax-ai-image/tpu:latest` for JAX, or build your own (see `images/` directory)
- **MLDiagnostics**: Add `pip install google-cloud-mldiagnostics google-cloud-logging` to enable metrics and profiling
- **TPU count**: Default is 4 chips. Max per job: 8 chips

## Step 4: Submit PR

```bash
git add jobs/<team>/<task-name>/
git commit -m "Submit job: <task-name>"
git push -u origin job/<your-name>/<task-name>
```

Then create a Pull Request on GitHub targeting `main` branch.

## Step 5: Wait for CI

Cloud Build will automatically:
1. Validate YAML syntax
2. Check TPU resource quota
3. Run `kubectl apply --dry-run`

Wait for all checks to pass (green checkmark).

## Step 6: Merge and Deploy

After review approval, merge the PR. Cloud Build will automatically deploy your job to GKE.

## Step 7: Monitor

See [monitoring.md](monitoring.md) for how to view logs and metrics.
