#!/usr/bin/env python3
"""Check TPU resource quota in job YAML files.

Prevents algorithm team from requesting more TPU resources than allowed.
"""

import glob
import sys

import yaml

# Maximum TPU chips per single job
MAX_TPU_PER_JOB = 8
# Maximum total TPU chips across all jobs in a single PR
MAX_TPU_TOTAL = 32


def check_tpu_quota():
    errors = []
    total_tpu = 0

    for filepath in sorted(glob.glob("jobs/**/*.yaml", recursive=True)):
        with open(filepath) as f:
            docs = list(yaml.safe_load_all(f))

        for doc in docs:
            if not doc or doc.get("kind") != "JobSet":
                continue

            job_name = doc.get("metadata", {}).get("name", filepath)
            replicated_jobs = (
                doc.get("spec", {}).get("replicatedJobs", [])
            )

            for rj in replicated_jobs:
                replicas = rj.get("replicas", 1)
                pod_spec = (
                    rj.get("template", {})
                    .get("spec", {})
                    .get("template", {})
                    .get("spec", {})
                )
                parallelism = rj.get("template", {}).get("spec", {}).get(
                    "parallelism", 1
                )

                for container in pod_spec.get("containers", []):
                    limits = container.get("resources", {}).get("limits", {})
                    tpu_count = int(limits.get("google.com/tpu", 0))

                    if tpu_count > 0:
                        job_total = tpu_count * parallelism * replicas
                        total_tpu += job_total
                        print(
                            f"  {job_name}: {tpu_count} TPU x "
                            f"{parallelism} parallel x {replicas} replicas "
                            f"= {job_total} TPU chips"
                        )

                        if job_total > MAX_TPU_PER_JOB:
                            errors.append(
                                f"{job_name}: requests {job_total} TPU chips, "
                                f"max allowed per job is {MAX_TPU_PER_JOB}"
                            )

    if total_tpu > MAX_TPU_TOTAL:
        errors.append(
            f"Total TPU request ({total_tpu}) exceeds max allowed "
            f"({MAX_TPU_TOTAL})"
        )

    if errors:
        print("\nQuota check FAILED:")
        for e in errors:
            print(f"  - {e}")
        sys.exit(1)
    else:
        print(f"\nQuota check PASSED. Total TPU: {total_tpu}")


if __name__ == "__main__":
    check_tpu_quota()
