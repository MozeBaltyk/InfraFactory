# Generated with hosts.tpl
[all]
## ALL HOSTS
localhost ansible_connection=local

[CONTROLLERS]
%{ for idx, ip in controller_ips ~}
controller${idx + 1} ansible_host=${ip} # Controller${idx + 1}
%{ endfor ~}

[WORKERS]
%{ for idx, ip in worker_ips ~}
worker${idx + 1} ansible_host=${ip} # Worker${idx + 1}
%{ endfor ~}

[K8S_CLUSTER:children]
CONTROLLERS
WORKERS
