# 指标能力地图

项目 `tpu-for-training`，探测窗口 7 天（2026-08-18 → 2026-08-25）。

由 `tools/build_capability_map.py` 生成，**只列本项目实际有数据的指标**。
Cloud Monitoring 的 `metricDescriptors` 返回的是 Google 全局目录（含 AWS、CloudSQL 等本项目根本不产生的东西），所以每个候选都实际探测过。

**合计 209 个指标有数据。**

| 层 | 含义 | 指标数 |
|---|---|---|
| **L1** | 平台自带，GCP 直接产生，我们不做任何事 | 143 |
| **L2** | 需要采集器：GMP 抓取 / 工作负载自报 | 53 |
| **L?** | 未分类前缀 | 13 |

> L3（派生指标）不在此表 —— 它们由本平台从 L1/L2 加日志和 ML Diagnostics API 算出来，只存在于 BigQuery。见 README §13。

## L1 — 平台自带，GCP 直接产生，我们不做任何事

### Compute（75 个）

| 指标 | kind | 单位 | 7天序列数 | 标签 |
|---|---|---|---|---|
| `guest/system/problem_state` | GAUGE | 1 | 45294 | instance_name,reason,type |
| `nat/dropped_sent_packets_count` | DELTA | {packet} | 8010 | nat_project_number,router_id,nat_gateway_name,ip_protocol,re |
| `guest/disk/bytes_used` | GAUGE | By | 8002 | instance_name,mountoption,mount_option,device_name,state,fst |
| `guest/system/os_feature_enabled` | GAUGE | 1 | 6665 | instance_name,value,os_feature |
| `guest/memory/bytes_used` | GAUGE | By | 6665 | instance_name,state |
| `guest/disk/queue_length` | GAUGE | 1 | 5326 | instance_name,device_name |
| `instance/disk/performance_status` | GAUGE | 1 | 5285 | device_name,storage_type,performance_status |
| `intercept/intercepted_packets_count` | DELTA | 1 | 4017 | ip_protocol |
| `intercept/intercepted_bytes_count` | DELTA | By | 4017 | ip_protocol |
| `instance/integrity/early_boot_validation_status` | GAUGE | 1 | 4014 | instance_name,status |
| `instance/integrity/late_boot_validation_status` | GAUGE | 1 | 4014 | instance_name,status |
| `nat/closed_connections_count` | DELTA | {connection} | 4005 | nat_project_number,router_id,nat_gateway_name,ip_protocol |
| `nat/new_connections_count` | DELTA | {connection} | 4005 | nat_project_number,router_id,nat_gateway_name,ip_protocol |
| `nat/dropped_received_packets_count` | DELTA | {packet} | 4005 | nat_project_number,router_id,nat_gateway_name,ip_protocol |
| `nat/received_bytes_count` | DELTA | By | 4005 | nat_project_number,router_id,nat_gateway_name,ip_protocol |
| `nat/open_connections` | GAUGE | {connection} | 4005 | nat_project_number,router_id,nat_gateway_name,ip_protocol |
| `nat/received_packets_count` | DELTA | {packet} | 4005 | nat_project_number,router_id,nat_gateway_name,ip_protocol |
| `nat/port_usage` | GAUGE | {port} | 4005 | nat_project_number,router_id,nat_gateway_name,ip_protocol |
| `nat/sent_packets_count` | DELTA | {packet} | 4005 | nat_project_number,router_id,nat_gateway_name,ip_protocol |
| `nat/sent_bytes_count` | DELTA | By | 4005 | nat_project_number,router_id,nat_gateway_name,ip_protocol |
| `guest/disk/percent_used` | GAUGE | percent | 4001 | instance_name,device_name |
| `mirroring/dropped_packets_count` | DELTA | 1 | 2678 | reason |
| `mirroring/mirrored_bytes_count` | DELTA | By | 2678 | ip_protocol |
| `mirroring/mirrored_packets_count` | DELTA | 1 | 2678 | ip_protocol |
| `guest/memory/dirty_used` | GAUGE | By | 2666 | instance_name,state |
| `guest/memory/page_cache_used` | GAUGE | By | 2666 | instance_name,state |
| `guest/memory/anonymous_used` | GAUGE | By | 2666 | instance_name,state |
| `instance/tpu/chip_state` | GAUGE | 1 | 2024 | state,accelerator_type,block_id,subblock_id,reservation_id,i |
| `instance/tpu/active_chips` | GAUGE | 1 | 2015 | accelerator_type,reservation_id,provisioning_model,protectio |
| `instance/tpu/utilized_chips` | GAUGE | 1 | 2015 | accelerator_type,reservation_id,provisioning_model,protectio |
| `instance/tpu/scheduled_chips` | GAUGE | 1 | 2015 | accelerator_type,reservation_id,provisioning_model,protectio |
| `instance/disk/read_bytes_count` | DELTA | By | 1370 | instance_name,device_name,storage_type,device_type |
| `instance/disk/read_ops_count` | DELTA | 1 | 1370 | instance_name,device_name,storage_type,device_type |
| `instance/disk/write_bytes_count` | DELTA | By | 1370 | instance_name,device_name,storage_type,device_type |
| `instance/disk/write_ops_count` | DELTA | 1 | 1370 | instance_name,device_name,storage_type,device_type |
| `instance/disk/provisioning/size` | GAUGE | By | 1339 | device_name,storage_type |
| `firewall/dropped_bytes_count` | DELTA | By | 1338 | instance_name |
| `firewall/dropped_packets_count` | DELTA | 1 | 1338 | instance_name |
| `instance/cpu/utilization` | GAUGE | 10^2.% | 1338 | instance_name |
| `instance/cpu/reserved_cores` | GAUGE | 1 | 1338 | instance_name |
| `instance/disk/max_read_ops_count` | GAUGE | 1 | 1338 | device_name,storage_type,device_type |
| `instance/cpu/guest_visible_vcpus` | GAUGE | 1 | 1338 | instance_name |
| `instance/disk/max_write_bytes_count` | GAUGE | By | 1338 | device_name,storage_type,device_type |
| `instance/disk/average_io_queue_depth` | GAUGE | 1 | 1338 | device_name,storage_type |
| `instance/clock_accuracy/ptp_kvm/nanosecond_accuracy` | GAUGE | ns | 1338 | instance_name |
| `instance/disk/max_write_ops_count` | GAUGE | 1 | 1338 | device_name,storage_type,device_type |
| `instance/cpu/usage_time` | DELTA | s{CPU} | 1338 | instance_name |
| `instance/disk/max_read_bytes_count` | GAUGE | By | 1338 | device_name,storage_type,device_type |
| `instance/disk/average_io_latency` | GAUGE | us | 1338 | device_name,storage_type |
| `instance/network/sent_bytes_count` | DELTA | By | 1338 | instance_name,loadbalanced |
| `instance/network/received_bytes_count` | DELTA | By | 1338 | instance_name,loadbalanced |
| `instance/network/received_packets_count` | DELTA | 1 | 1338 | instance_name,loadbalanced |
| `instance/network/sent_packets_count` | DELTA | 1 | 1338 | instance_name,loadbalanced |
| `instance/uptime` | DELTA | s{uptime} | 1338 | instance_name |
| `instance/uptime_total` | GAUGE | s | 1338 | instance_name |
| `network/dropped_packets/no_vm_receive_buffers_count` | DELTA | 1 | 1338 | - |
| `nat/allocated_ports` | GAUGE | {port} | 1334 | nat_project_number,router_id,nat_gateway_name,nat_ip |
| `guest/cpu/load_5m` | GAUGE | 1 | 1333 | instance_name |
| `guest/cpu/load_15m` | GAUGE | 1 | 1333 | instance_name |
| `guest/cpu/runnable_task_count` | GAUGE | 1 | 1333 | instance_name |
| … 另有 15 个 | | | | |

### GKE 平台（57 个）

| 指标 | kind | 单位 | 7天序列数 | 标签 |
|---|---|---|---|---|
| `container/accelerator/memory_bandwidth_utilization` | GAUGE | percent | 98984 | make,accelerator_id,model,tpu_topology |
| `container/accelerator/tensorcore_utilization` | GAUGE | percent | 98984 | make,accelerator_id,model,tpu_topology |
| `container/memory/request_utilization` | GAUGE | 1 | 98736 | memory_type |
| `container/memory/used_bytes` | GAUGE | By | 98502 | memory_type |
| `pod/volume/total_bytes` | GAUGE | By | 98368 | volume_name,persistentvolumeclaim_name,persistentvolumeclaim |
| `pod/volume/used_bytes` | GAUGE | By | 98368 | volume_name,persistentvolumeclaim_name,persistentvolumeclaim |
| `pod/volume/utilization` | GAUGE | 1 | 98362 | volume_name,persistentvolumeclaim_name,persistentvolumeclaim |
| `container/ephemeral_storage/used_bytes` | GAUGE | By | 98325 | - |
| `container/memory/limit_bytes` | GAUGE | By | 98323 | - |
| `container/cpu/request_cores` | GAUGE | {cpu} | 98323 | - |
| `container/cpu/limit_cores` | GAUGE | {cpu} | 98323 | - |
| `container/ephemeral_storage/request_bytes` | GAUGE | By | 98323 | - |
| `container/memory/request_bytes` | GAUGE | By | 98323 | - |
| `container/ephemeral_storage/limit_bytes` | GAUGE | By | 98323 | - |
| `container/memory/swap_used_bytes` | GAUGE | By | 98315 | - |
| `container/cpu/request_utilization` | GAUGE | 1 | 84317 | - |
| `container/accelerator/memory_total` | GAUGE | By | 79518 | make,accelerator_id,model |
| `container/accelerator/memory_used` | GAUGE | By | 79518 | make,accelerator_id,model |
| `container/accelerator/duty_cycle` | GAUGE | % | 79486 | make,accelerator_id,model |
| `container/memory/limit_utilization` | GAUGE | 1 | 73963 | memory_type |
| `pod/ephemeral_storage/used_bytes` | GAUGE | By | 52785 | - |
| `pod/latencies/pod_first_ready` | GAUGE | s | 51059 | - |
| `node/status_condition` | GAUGE | 1 | 33073 | status,condition |
| `container/accelerator/request` | GAUGE | {devices} | 19873 | resource_name |
| `networking/dns/node_local_dns/dns_cache_request_count` | DELTA | 1 | 12898 | dns_zone,status,server,type |
| `node/assigned_jobsets` | GAUGE | 1 | 11168 | jobset_namespace,jobset_name,jobset_uid |
| `networking/dns/node_local_dns/dns_request_count` | DELTA | 1 | 11093 | family,type,proto,dns_zone,server,view |
| `container/cpu/limit_utilization` | GAUGE | 1 | 9401 | - |
| `node_daemon/memory/used_bytes` | GAUGE | By | 7980 | component,memory_type |
| `node/accelerator/memory_bandwidth_utilization` | GAUGE | percent | 5072 | make,accelerator_id,model,tpu_topology |
| `node/accelerator/tensorcore_utilization` | GAUGE | percent | 5072 | make,accelerator_id,model,tpu_topology |
| `node/accelerator/memory_total` | GAUGE | bytes | 4680 | make,accelerator_id,model |
| `node/accelerator/memory_used` | GAUGE | bytes | 4680 | make,accelerator_id,model |
| `node/accelerator/duty_cycle` | GAUGE | percent | 4660 | make,accelerator_id,model |
| `node/memory/allocatable_utilization` | GAUGE | 1 | 2660 | memory_type,component |
| `node/memory/used_bytes` | GAUGE | By | 2660 | memory_type |
| `node/logs/input_bytes` | DELTA | By | 2652 | type |
| `node/cpu/allocatable_cores` | GAUGE | {cpu} | 1330 | - |
| `node/cpu/total_cores` | GAUGE | {cpu} | 1330 | - |
| `node/ephemeral_storage/allocatable_bytes` | GAUGE | By | 1330 | - |
| `node/ephemeral_storage/used_bytes` | GAUGE | By | 1330 | - |
| `node/ephemeral_storage/inodes_free` | GAUGE | 1 | 1330 | - |
| `node/cpu/allocatable_utilization` | GAUGE | 1 | 1330 | - |
| `node/memory/total_bytes` | GAUGE | By | 1330 | - |
| `node/memory/swap_used_bytes` | GAUGE | By | 1330 | - |
| `node/pid_limit` | GAUGE | 1 | 1330 | - |
| `node/ephemeral_storage/total_bytes` | GAUGE | By | 1330 | - |
| `node/pid_used` | GAUGE | 1 | 1330 | - |
| `node/ephemeral_storage/inodes_total` | GAUGE | 1 | 1330 | - |
| `node/memory/allocatable_bytes` | GAUGE | By | 1330 | - |
| `node/latencies/startup` | GAUGE | s | 1184 | accelerator_family,kube_control_plane_available |
| `node/interruption_count` | GAUGE | 1 | 102 | interruption_type,interruption_reason |
| `networking/dns/node_local_dns/max_concurrent_rejected_request_count` | DELTA | 1 | 73 | - |
| `autoscaler/container/cpu/per_replica_recommended_request_cores` | GAUGE | {cpu} | 25 | container_name |
| `autoscaler/container/memory/per_replica_recommended_request_bytes` | GAUGE | By | 25 | container_name |
| `cluster/version` | GAUGE | 1 | 3 | cluster_version |
| `container/uptime` | GAUGE | s | 0 | - |

### Logging（2 个）

| 指标 | kind | 单位 | 7天序列数 | 标签 |
|---|---|---|---|---|
| `user/maxtext_completed_step` | DELTA | 1 | 6033 | log,run,namespace |
| `user/tpu_init_slow` | DELTA | - | 5429 | log,job_name |

### TPU runtime（9 个）

| 指标 | kind | 单位 | 7天序列数 | 标签 |
|---|---|---|---|---|
| `cpu/utilization` | GAUGE | % | 360 | core |
| `accelerator/memory_bandwidth_utilization` | GAUGE | % | 8 | accelerator_id |
| `instance/interruption_count` | GAUGE | 1 | 2 | instance_name,interruption_type,interruption_reason |
| `memory/usage` | GAUGE | By | 2 | - |
| `network/received_bytes_count` | DELTA | By | 2 | - |
| `network/sent_bytes_count` | DELTA | By | 2 | - |
| `accelerator/tensorcore_utilization` | GAUGE | % | 0 | accelerator_id |
| `instance/uptime_total` | GAUGE | s | 0 | - |
| `tpu/tensorcore/idle_duration` | GAUGE | s | 0 | chip |

## L2 — 需要采集器：GMP 抓取 / 工作负载自报

### GMP 采集（35 个）

| 指标 | kind | 单位 | 7天序列数 | 标签 |
|---|---|---|---|---|
| `container_memory_rss/gauge` | GAUGE | - | 93147 | pod,container,image,name,id,node |
| `container_memory_working_set_bytes/gauge` | GAUGE | - | 93147 | pod,container,image,name,id,node |
| `kube_pod_status_phase/gauge` | GAUGE | - | 88095 | pod,phase,uid |
| `kube_pod_container_status_ready/gauge` | GAUGE | - | 39150 | pod,container,uid |
| `container_fs_usage_bytes/gauge` | GAUGE | - | 17331 | device,id,node |
| `kubelet_running_containers/gauge` | GAUGE | - | 3959 | container_state,node |
| `scrape_duration_seconds/gauge` | GAUGE | - | 2668 | node |
| `kubelet_node_name/gauge` | GAUGE | - | 1333 | exported_node,node |
| `kube_pod_status_unschedulable/gauge` | GAUGE | - | 893 | pod,uid |
| `kube_jobset_failed_replicas/gauge` | GAUGE | - | 831 | replicated_job_name,customresource_group,customresource_vers |
| `kube_jobset_ready_replicas/gauge` | GAUGE | - | 831 | replicated_job_name,customresource_group,customresource_vers |
| `kube_jobset_active_replicas/gauge` | GAUGE | - | 831 | replicated_job_name,customresource_group,customresource_vers |
| `kube_jobset_succeeded_replicas/gauge` | GAUGE | - | 831 | replicated_job_name,customresource_group,customresource_vers |
| `kube_jobset_suspended_replicas/gauge` | GAUGE | - | 831 | replicated_job_name,customresource_group,customresource_vers |
| `kube_jobset_specified_replicas/gauge` | GAUGE | - | 828 | replicated_job_name,customresource_group,customresource_vers |
| `kube_jobset_status_condition/gauge` | GAUGE | - | 447 | condition,customresource_group,customresource_version,custom |
| `kube_jobset_restarts/gauge` | GAUGE | - | 80 | customresource_group,customresource_version,customresource_k |
| `kube_persistentvolume_status_phase/gauge` | GAUGE | - | 45 | phase,persistentvolume |
| `kube_deployment_status_replicas_available/gauge` | GAUGE | - | 20 | deployment |
| `kube_deployment_spec_replicas/gauge` | GAUGE | - | 20 | deployment |
| `kube_deployment_status_replicas_updated/gauge` | GAUGE | - | 20 | deployment |
| `kube_persistentvolume_capacity_bytes/gauge` | GAUGE | - | 9 | persistentvolume |
| `kube_persistentvolume_info/gauge` | GAUGE | - | 9 | csi_volume_handle,csi_driver,persistentvolume,storageclass |
| `kube_persistentvolume_claim_ref/gauge` | GAUGE | - | 9 | claim_namespace,name,persistentvolume |
| `kube_persistentvolumeclaim_resource_requests_storage_bytes/gauge` | GAUGE | - | 9 | persistentvolumeclaim |
| `kube_persistentvolumeclaim_info/gauge` | GAUGE | - | 9 | volumemode,persistentvolumeclaim,volumename,storageclass |
| `kube_persistentvolumeclaim_status_phase/gauge` | GAUGE | - | 0 | phase,persistentvolumeclaim |
| `kube_pod_container_status_waiting_reason/gauge` | GAUGE | - | 0 | pod,container,reason,uid |
| `scrape_samples_scraped/gauge` | GAUGE | - | 0 | node |
| `up/gauge` | GAUGE | - | 0 | node |
| `container_fs_limit_bytes/gauge` | GAUGE | - | 0 | device,id,node |
| `kubelet_running_pods/gauge` | GAUGE | - | 0 | node |
| `scrape_samples_post_metric_relabeling/gauge` | GAUGE | - | 0 | node |
| `scrape_series_added/gauge` | GAUGE | - | 0 | node |
| `kubelet_certificate_manager_server_ttl_seconds/gauge` | GAUGE | - | 0 | node |

### Ops Agent（15 个）

| 指标 | kind | 单位 | 7天序列数 | 标签 |
|---|---|---|---|---|
| `processes/rss_usage` | GAUGE | By | 4420 | process,command,command_line,owner,pid |
| `processes/vm_usage` | GAUGE | By | 4420 | process,command,command_line,owner,pid |
| `network/tcp_connections` | GAUGE | 1 | 14 | port,tcp_state |
| `cpu/utilization` | GAUGE | % | 8 | cpu_number,cpu_state |
| `disk/bytes_used` | GAUGE | By | 6 | device,state |
| `disk/percent_used` | GAUGE | % | 6 | device,state |
| `memory/bytes_used` | GAUGE | By | 5 | state |
| `memory/percent_used` | GAUGE | % | 5 | state |
| `disk/pending_operations` | GAUGE | 1 | 4 | device |
| `processes/count_by_state` | GAUGE | 1 | 4 | state |
| `agent/ops_agent/enabled_receivers` | GAUGE | 1 | 2 | receiver_type,telemetry_type |
| `agent/memory_usage` | GAUGE | By | 1 | - |
| `cpu/load_5m` | GAUGE | 1 | 1 | - |
| `cpu/load_15m` | GAUGE | 1 | 1 | - |
| `cpu/load_1m` | GAUGE | 1 | 1 | - |

### 工作负载自报（3 个）

| 指标 | kind | 单位 | 7天序列数 | 标签 |
|---|---|---|---|---|
| `tpu_finance/jobstat_mfu` | GAUGE | - | 87 | end_time,job_name,start_time |
| `tpu_finance/month_duty_cycle` | GAUGE | - | 4 | month |
| `tpu_finance/month_reservation_utilization` | GAUGE | - | 4 | month |

## L? — 未分类前缀

### 其它（13 个）

| 指标 | kind | 单位 | 7天序列数 | 标签 |
|---|---|---|---|---|
| `pod_flow/egress_packets_count` | DELTA | 1 | 16289 | local_network,local_subnetwork,remote_location_type,remote_p |
| `pod_flow/ingress_packets_count` | DELTA | 1 | 16112 | local_network,local_subnetwork,remote_location_type,remote_p |
| `pod_flow/egress_bytes_count` | DELTA | By | 15260 | local_network,local_subnetwork,remote_location_type,remote_p |
| `pod_flow/ingress_bytes_count` | DELTA | By | 15191 | local_network,local_subnetwork,remote_location_type,remote_p |
| `vm_flow/egress_packets_count` | DELTA | 1 | 13838 | local_network,local_subnetwork,local_network_interface,remot |
| `vm_flow/egress_bytes_count` | DELTA | By | 13447 | local_network,local_subnetwork,local_network_interface,remot |
| `node_flow/egress_packets_count` | DELTA | 1 | 13199 | local_network,local_subnetwork,remote_location_type,remote_p |
| `node_flow/egress_bytes_count` | DELTA | By | 12867 | local_network,local_subnetwork,remote_location_type,remote_p |
| `vm_flow/ingress_packets_count` | DELTA | 1 | 12496 | local_network,local_subnetwork,local_network_interface,remot |
| `vm_flow/ingress_bytes_count` | DELTA | By | 12186 | local_network,local_subnetwork,local_network_interface,remot |
| `node_flow/ingress_packets_count` | DELTA | 1 | 12080 | local_network,local_subnetwork,remote_location_type,remote_p |
| `node_flow/ingress_bytes_count` | DELTA | By | 11859 | local_network,local_subnetwork,remote_location_type,remote_p |
| `vm_flow/connection_count` | DELTA | 1 | 11226 | local_network,local_subnetwork,local_network_interface,remot |

