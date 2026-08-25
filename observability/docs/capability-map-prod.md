# 指标能力地图

项目 `tpu-for-training`，探测窗口 1 天（2026-08-24 → 2026-08-25）。

由 `tools/build_capability_map.py` 生成，**只列本项目实际有数据的指标**。
Cloud Monitoring 的 `metricDescriptors` 返回的是 Google 全局目录（含 AWS、CloudSQL 等本项目根本不产生的东西），所以每个候选都实际探测过。

**合计 167 个指标有数据。**

| 层 | 含义 | 指标数 |
|---|---|---|
| **L1** | 平台自带，GCP 直接产生，我们不做任何事 | 109 |
| **L2** | 需要采集器：GMP 抓取 / 工作负载自报 | 58 |

> L3（派生指标）不在此表 —— 它们由本平台从 L1/L2 加日志和 ML Diagnostics API 算出来，只存在于 BigQuery。见 README §13。

## L1 — 平台自带，GCP 直接产生，我们不做任何事

### GKE 平台（89 个）

| 指标 | kind | 单位 | 7天序列数 | 标签 |
|---|---|---|---|---|
| `gcsfusecsi/fs_ops_count` | CUMULATIVE | 1 | 59726 | fs_op,volume_name,bucket_name,pod_uid |
| `gcsfusecsi/fs_ops_latencies` | CUMULATIVE | us | 59726 | fs_op,volume_name,bucket_name,pod_uid |
| `pod/volume/utilization` | GAUGE | 1 | 52659 | volume_name,persistentvolumeclaim_name,persistentvolumeclaim |
| `pod/volume/total_bytes` | GAUGE | By | 52609 | volume_name,persistentvolumeclaim_name,persistentvolumeclaim |
| `pod/volume/used_bytes` | GAUGE | By | 52609 | volume_name,persistentvolumeclaim_name,persistentvolumeclaim |
| `container/memory/used_bytes` | GAUGE | By | 43704 | memory_type |
| `container/memory/page_fault_count` | CUMULATIVE | 1 | 42454 | fault_type |
| `container/memory/request_utilization` | GAUGE | 1 | 33412 | memory_type |
| `gcsfusecsi/gcs_request_count` | CUMULATIVE | 1 | 28403 | gcs_method,volume_name,bucket_name,pod_uid |
| `gcsfusecsi/gcs_request_latencies` | CUMULATIVE | ms | 28403 | gcs_method,volume_name,bucket_name,pod_uid |
| `container/cpu/request_cores` | GAUGE | {cpu} | 22090 | - |
| `container/ephemeral_storage/request_bytes` | GAUGE | By | 22090 | - |
| `container/ephemeral_storage/limit_bytes` | GAUGE | By | 22090 | - |
| `container/memory/request_bytes` | GAUGE | By | 22090 | - |
| `container/memory/limit_bytes` | GAUGE | By | 22090 | - |
| `container/restart_count` | CUMULATIVE | 1 | 22090 | - |
| `container/cpu/limit_cores` | GAUGE | {cpu} | 22090 | - |
| `container/memory/swap_used_bytes` | GAUGE | By | 21862 | - |
| `container/ephemeral_storage/used_bytes` | GAUGE | By | 21852 | - |
| `container/uptime` | GAUGE | s | 21852 | - |
| `container/cpu/core_usage_time` | CUMULATIVE | s{CPU} | 21837 | - |
| `container/memory/limit_utilization` | GAUGE | 1 | 18324 | memory_type |
| `container/accelerator/tensorcore_utilization` | GAUGE | percent | 17768 | make,accelerator_id,model,tpu_topology |
| `container/accelerator/memory_bandwidth_utilization` | GAUGE | percent | 17768 | make,accelerator_id,model,tpu_topology |
| `container/cpu/request_utilization` | GAUGE | 1 | 17089 | - |
| `gcsfusecsi/gcs_reader_count` | CUMULATIVE | 1 | 16000 | io_method,volume_name,bucket_name,pod_uid |
| `container/accelerator/memory_used` | GAUGE | By | 15708 | make,accelerator_id,model |
| `container/accelerator/memory_total` | GAUGE | By | 15708 | make,accelerator_id,model |
| `container/accelerator/duty_cycle` | GAUGE | % | 15708 | make,accelerator_id,model |
| `pod/network/sent_bytes_count` | CUMULATIVE | By | 15138 | interface |
| `pod/network/received_bytes_count` | CUMULATIVE | By | 15137 | interface |
| `gcsfusecsi/gcs_download_bytes_count` | CUMULATIVE | By | 8998 | read_type,volume_name,bucket_name,pod_uid |
| `gcsfusecsi/gcs_read_count` | CUMULATIVE | 1 | 8859 | read_type,volume_name,bucket_name,pod_uid |
| `pod/ephemeral_storage/used_bytes` | GAUGE | By | 8550 | - |
| `gcsfusecsi/fs_ops_error_count` | CUMULATIVE | 1 | 7059 | fs_op,fs_error_category,volume_name,bucket_name,pod_uid |
| `pod/latencies/pod_first_ready` | GAUGE | s | 6600 | - |
| `gcsfusecsi/gcs_read_bytes_count` | CUMULATIVE | By | 5494 | volume_name,bucket_name,pod_uid |
| `gcsfusecsi/file_cache_read_count` | CUMULATIVE | 1 | 4723 | cache_hit,read_type,volume_name,bucket_name,pod_uid |
| `container/accelerator/request` | GAUGE | {devices} | 3928 | resource_name |
| `gcsfusecsi/file_cache_read_latencies` | CUMULATIVE | us | 2645 | cache_hit,volume_name,bucket_name,pod_uid |
| `gcsfusecsi/file_cache_read_bytes_count` | CUMULATIVE | By | 2574 | read_type,volume_name,bucket_name,pod_uid |
| `networking/dns/node_local_dns/dns_cache_request_count` | DELTA | 1 | 2480 | dns_zone,status,server,type |
| `container/cpu/limit_utilization` | GAUGE | 1 | 2306 | - |
| `networking/dns/node_local_dns/dns_request_count` | DELTA | 1 | 2173 | family,type,proto,dns_zone,server,view |
| `node_daemon/memory/used_bytes` | GAUGE | By | 1518 | component,memory_type |
| `networking/dns/node_local_dns/dns_request_latencies` | DELTA | s | 1494 | dns_zone,view,server,type |
| `networking/dns/node_local_dns/forwarding_request_latencies` | DELTA | s | 915 | type,rcode,to,proxy_name |
| `node/accelerator/tensorcore_utilization` | GAUGE | percent | 828 | make,accelerator_id,model,tpu_topology |
| `node/accelerator/memory_bandwidth_utilization` | GAUGE | percent | 828 | make,accelerator_id,model,tpu_topology |
| `node/accelerator/memory_total` | GAUGE | bytes | 780 | make,accelerator_id,model |
| `node/accelerator/duty_cycle` | GAUGE | percent | 780 | make,accelerator_id,model |
| `node/accelerator/memory_used` | GAUGE | bytes | 780 | make,accelerator_id,model |
| `node_daemon/cpu/core_usage_time` | CUMULATIVE | s{CPU} | 759 | component |
| `node/memory/allocatable_utilization` | GAUGE | 1 | 508 | memory_type,component |
| `node/logs/input_bytes` | DELTA | By | 506 | type |
| `node/memory/used_bytes` | GAUGE | By | 506 | memory_type |
| `node/memory/swap_used_bytes` | GAUGE | By | 254 | - |
| `node/cpu/allocatable_cores` | GAUGE | {cpu} | 253 | - |
| `node/cpu/core_usage_time` | CUMULATIVE | s{CPU} | 253 | - |
| `node/cpu/total_cores` | GAUGE | {cpu} | 253 | - |
| … 另有 29 个 | | | | |

### GKE 控制面（8 个）

| 指标 | kind | 单位 | 7天序列数 | 标签 |
|---|---|---|---|---|
| `quota/quota/containers_per_cluster_standard/usage` | GAUGE | 1 | 2 | limit_name |
| `quota/quota/containers_per_cluster_standard/limit` | GAUGE | 1 | 2 | limit_name |
| `quota/quota/etcd_database_size_bytes/limit` | GAUGE | By | 2 | limit_name |
| `quota/quota/etcd_database_size_bytes/usage` | GAUGE | By | 2 | limit_name |
| `quota/quota/nodes_per_cluster/limit` | GAUGE | 1 | 2 | limit_name |
| `quota/quota/nodes_per_cluster/usage` | GAUGE | 1 | 2 | limit_name |
| `quota/quota/pods_per_cluster_standard/limit` | GAUGE | 1 | 2 | limit_name |
| `quota/quota/pods_per_cluster_standard/usage` | GAUGE | 1 | 2 | limit_name |

### Logging（12 个）

| 指标 | kind | 单位 | 7天序列数 | 标签 |
|---|---|---|---|---|
| `byte_count` | DELTA | By | 67955 | log,severity |
| `log_entry_count` | DELTA | 1 | 67955 | log,severity |
| `user/maxtext_completed_step` | DELTA | 1 | 939 | log,run,namespace |
| `user/tpu_init_slow` | DELTA | - | 320 | log,job_name |
| `billing/log_bucket_monthly_bytes_ingested` | GAUGE | By | 22 | log_source,resource_type,log_bucket_location,log_bucket_id |
| `billing/monthly_bytes_ingested` | GAUGE | By | 22 | resource_type |
| `billing/bytes_ingested` | DELTA | By | 21 | resource_type |
| `billing/log_bucket_bytes_ingested` | DELTA | By | 21 | log_source,resource_type,log_bucket_location,log_bucket_id |
| `exports/byte_count` | DELTA | By | 13 | - |
| `exports/log_entry_count` | DELTA | 1 | 13 | - |
| `metric_label_cardinality` | GAUGE | 1 | 5 | label |
| `time_series_count` | GAUGE | 1 | 2 | - |

## L2 — 需要采集器：GMP 抓取 / 工作负载自报

### GMP 采集（53 个）

| 指标 | kind | 单位 | 7天序列数 | 标签 |
|---|---|---|---|---|
| `container_network_transmit_packets_dropped_total/counter` | CUMULATIVE | - | 60688 | pod,image,name,id,node,interface |
| `container_network_receive_packets_dropped_total/counter` | CUMULATIVE | - | 60688 | pod,image,name,id,node,interface |
| `container_network_receive_packets_total/counter` | CUMULATIVE | - | 60688 | pod,image,name,id,node,interface |
| `container_network_transmit_packets_total/counter` | CUMULATIVE | - | 60688 | pod,image,name,id,node,interface |
| `container_network_transmit_bytes_total/counter` | CUMULATIVE | - | 60688 | pod,image,name,id,node,interface |
| `container_network_receive_bytes_total/counter` | CUMULATIVE | - | 60688 | pod,image,name,id,node,interface |
| `container_memory_rss/gauge` | GAUGE | - | 43172 | pod,container,image,name,id,node |
| `container_memory_working_set_bytes/gauge` | GAUGE | - | 43172 | pod,container,image,name,id,node |
| `container_cpu_usage_seconds_total/counter` | CUMULATIVE | - | 40473 | pod,container,image,name,id,node,cpu |
| `container_fs_reads_total/counter` | CUMULATIVE | - | 32578 | device,pod,container,image,name,id,node |
| `container_fs_writes_total/counter` | CUMULATIVE | - | 32578 | device,pod,container,image,name,id,node |
| `container_fs_reads_bytes_total/counter` | CUMULATIVE | - | 29542 | device,pod,container,image,name,id,node |
| `container_fs_writes_bytes_total/counter` | CUMULATIVE | - | 29542 | device,pod,container,image,name,id,node |
| `kube_pod_status_phase/gauge` | GAUGE | - | 28175 | pod,phase,uid |
| `kube_pod_container_status_ready/gauge` | GAUGE | - | 5581 | pod,container,uid |
| `kubelet_runtime_operations_total/counter` | CUMULATIVE | - | 4258 | operation_type,node |
| `container_fs_limit_bytes/gauge` | GAUGE | - | 3290 | device,id,node |
| `container_fs_usage_bytes/gauge` | GAUGE | - | 3290 | device,id,node |
| `container_fs_write_seconds_total/counter` | CUMULATIVE | - | 3290 | device,id,node |
| `container_fs_read_seconds_total/counter` | CUMULATIVE | - | 3290 | device,id,node |
| `container_cpu_cfs_throttled_periods_total/counter` | CUMULATIVE | - | 2249 | pod,container,image,name,id,node |
| `container_cpu_cfs_periods_total/counter` | CUMULATIVE | - | 2249 | pod,container,image,name,id,node |
| `kube_pod_container_status_waiting_reason/gauge` | GAUGE | - | 1362 | pod,container,reason,uid |
| `kubelet_pod_worker_duration_seconds/histogram` | CUMULATIVE | - | 993 | operation_type,node |
| `kubelet_running_containers/gauge` | GAUGE | - | 754 | container_state,node |
| `scrape_samples_scraped/gauge` | GAUGE | - | 508 | node |
| `scrape_samples_post_metric_relabeling/gauge` | GAUGE | - | 508 | node |
| `scrape_duration_seconds/gauge` | GAUGE | - | 508 | node |
| `up/gauge` | GAUGE | - | 508 | node |
| `scrape_series_added/gauge` | GAUGE | - | 508 | node |
| `kubelet_certificate_manager_server_ttl_seconds/gauge` | GAUGE | - | 253 | node |
| `kubelet_node_name/gauge` | GAUGE | - | 253 | exported_node,node |
| `kubelet_pleg_relist_duration_seconds/histogram` | CUMULATIVE | - | 253 | node |
| `kubelet_running_pods/gauge` | GAUGE | - | 253 | node |
| `kube_pod_status_unschedulable/gauge` | GAUGE | - | 244 | pod,uid |
| `kube_jobset_active_replicas/gauge` | GAUGE | - | 139 | replicated_job_name,customresource_group,customresource_vers |
| `kube_jobset_failed_replicas/gauge` | GAUGE | - | 139 | replicated_job_name,customresource_group,customresource_vers |
| `kube_jobset_ready_replicas/gauge` | GAUGE | - | 139 | replicated_job_name,customresource_group,customresource_vers |
| `kube_jobset_specified_replicas/gauge` | GAUGE | - | 139 | replicated_job_name,customresource_group,customresource_vers |
| `kube_jobset_succeeded_replicas/gauge` | GAUGE | - | 139 | replicated_job_name,customresource_group,customresource_vers |
| `kube_jobset_suspended_replicas/gauge` | GAUGE | - | 139 | replicated_job_name,customresource_group,customresource_vers |
| `kube_jobset_status_condition/gauge` | GAUGE | - | 108 | condition,customresource_group,customresource_version,custom |
| `kube_persistentvolume_status_phase/gauge` | GAUGE | - | 45 | phase,persistentvolume |
| `kube_jobset_restarts/gauge` | GAUGE | - | 37 | customresource_group,customresource_version,customresource_k |
| `kube_persistentvolumeclaim_status_phase/gauge` | GAUGE | - | 27 | phase,persistentvolumeclaim |
| `kube_deployment_spec_replicas/gauge` | GAUGE | - | 20 | deployment |
| `kube_deployment_status_replicas_available/gauge` | GAUGE | - | 20 | deployment |
| `kube_deployment_status_replicas_updated/gauge` | GAUGE | - | 20 | deployment |
| `kube_persistentvolume_capacity_bytes/gauge` | GAUGE | - | 9 | persistentvolume |
| `kube_persistentvolume_claim_ref/gauge` | GAUGE | - | 9 | claim_namespace,name,persistentvolume |
| `kube_persistentvolume_info/gauge` | GAUGE | - | 9 | csi_volume_handle,csi_driver,persistentvolume,storageclass |
| `kube_persistentvolumeclaim_info/gauge` | GAUGE | - | 9 | volumemode,persistentvolumeclaim,volumename,storageclass |
| `kube_persistentvolumeclaim_resource_requests_storage_bytes/gauge` | GAUGE | - | 9 | persistentvolumeclaim |

### 工作负载自报（5 个）

| 指标 | kind | 单位 | 7天序列数 | 标签 |
|---|---|---|---|---|
| `tpu_finance/jobstat_mfu` | GAUGE | - | 50 | end_time,job_name,start_time |
| `tpu_finance/jobstat_duty_cycle` | GAUGE | - | 34 | end_time,job_name,start_time |
| `tpu_finance/month_mfu` | GAUGE | - | 5 | month |
| `tpu_finance/month_reservation_utilization` | GAUGE | - | 4 | month |
| `tpu_finance/month_duty_cycle` | GAUGE | - | 4 | month |

