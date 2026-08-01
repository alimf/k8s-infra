aws_region  = "us-east-1"
environment = "dev"
project     = "kodekloud"
cluster_name = "dev-k8s"

kubernetes_version = "1.31.0"
calico_version     = "3.29.0"

vpc_cidr             = "10.0.0.0/16"
availability_zones   = ["us-east-1a", "us-east-1b"]
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24"]
single_nat_gateway   = true

control_plane_count         = 1
control_plane_instance_type = "t3.medium"
control_plane_volume_size   = 50

worker_count         = 2
worker_instance_type = "t3.medium"
worker_volume_size   = 30

pod_cidr     = "192.168.0.0/16"
service_cidr = "10.96.0.0/12"

# Restrict in production to your corporate CIDR or VPN IP
api_server_allowed_cidrs = ["0.0.0.0/0"]

# key_name = "your-key-pair"  # uncomment if SSH access is needed
