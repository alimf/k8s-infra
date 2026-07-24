# Terraform Infrastructure

Self-managed Kubernetes cluster on AWS EC2 using kubeadm, structured for multi-cloud growth. Modules are namespaced by capability and cloud provider (`modules/network/aws/`, `modules/kubernetes/aws/`) so adding GCP or Azure means dropping in a parallel directory — no existing code changes required.

## Repository layout

```
modules/
  network/
    aws/              # VPC, subnets, IGW, NAT gateways
  kubernetes/
    aws/              # EC2 nodes, NLB, security groups, IAM, kubeadm bootstrap
      templates/
        control_plane.sh.tpl
        worker.sh.tpl
environments/
  dev/
    aws/              # Standalone EC2 demo
    k8s/              # Self-managed Kubernetes cluster
```

## What gets deployed (`environments/dev/k8s`)

| Component | Detail |
|---|---|
| VPC | 10.0.0.0/16 across 2 AZs, public + private subnets, single NAT |
| API server | NLB on port 6443 — stable endpoint across control plane rotation |
| Control plane | 1 × t3.medium, Ubuntu 22.04, 50 GiB gp3 encrypted, private subnet |
| Workers | 2 × t3.medium, Ubuntu 22.04, 30 GiB gp3 encrypted, private subnets |
| CNI | Calico 3.29 with VXLAN (supports NetworkPolicy) |
| Join distribution | kubeadm join command stored in SSM SecureString; workers poll on boot |
| Node access | SSM Session Manager — no bastion, no open SSH port |

## Deploy

```bash
cd environments/dev/k8s
terraform init
terraform plan
terraform apply
```

After apply, connect to the control plane via SSM Session Manager to retrieve the kubeconfig:

```bash
# Get instance ID from Terraform output
terraform output control_plane_private_ips

# Open a session (no SSH key needed)
aws ssm start-session --target <instance-id> --region us-east-1

# On the instance
cat /root/.kube/config
```

## Next steps

- [ ] **Restrict API server access** — change `api_server_allowed_cidrs` in `terraform.tfvars` from `0.0.0.0/0` to your VPN or corporate CIDR before production use
- [ ] **HA control plane** — increase `control_plane_count` to `3` and extend the bootstrap templates to handle secondary control plane joins via a second SSM parameter
- [ ] **Remote kubeconfig** — add a `null_resource` + `local_file` to pull `/etc/kubernetes/admin.conf` from the control plane and write it locally after `terraform apply`
- [ ] **Cluster Autoscaler** — replace fixed `aws_instance` worker resources with an Auto Scaling Group and attach the Cluster Autoscaler with the required IAM policy
- [ ] **etcd backups** — add an S3 bucket and a cron job on the control plane that runs `etcdctl snapshot save` and uploads to S3
- [ ] **Private container registry** — configure the containerd `registry.mirrors` section in the bootstrap template to pull from ECR instead of Docker Hub
- [ ] **Multi-cloud** — add `modules/network/gcp/` and `modules/kubernetes/gcp/` mirroring the same output interface; create `environments/dev/gcp/k8s/` as the GCP entry point