#######################################################################
# Terraform & Providers
#######################################################################
terraform {
  required_version = ">= 1.4"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = ">= 5.0"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = ">= 2.23"
    }
    helm = {
      source = "hashicorp/helm"
      version = ">= 2.12"
    }
    null = {
      source = "hashicorp/null"
    }
    local = {
      source = "hashicorp/local"
    }
    time = {
      source = "hashicorp/time"
    }
  }
}
#######################################################################
# Providers
#######################################################################
provider "aws" {
  region = local.region
}
# Data source to get cluster info after it's created
data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_name
  depends_on = [module.eks]
}
data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
  depends_on = [module.eks]
}
# IMPROVED: Using exec-based authentication (best practice)
provider "kubernetes" {
  host = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command = "aws"
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", local.region]
  }
}
provider "helm" {
  kubernetes {
    host = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command = "aws"
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", local.region]
    }
  }
}
#######################################################################
# Locals
#######################################################################
data "aws_availability_zones" "available" {
  filter {
    name = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}
locals {
  name = basename(path.cwd)
  region = "ap-south-1"
  azs = ["ap-south-1a", "ap-south-1b"] # Modified to match your VPC's 2 AZs (instead of 3)
  istio_chart_url = "https://istio-release.storage.googleapis.com/charts"
  istio_chart_version = "1.20.2"
  # Detect OS for script execution
  is_windows = substr(pathexpand("~"), 0, 1) == "/" ? false : true
  tags = {
    Blueprint = local.name
    GithubRepo = "github.com/aws-ia/terraform-aws-eks-blueprints"
  }
}
#######################################################################
# Data Sources for Pre-Existing VPC (replaces the removed module "vpc")
#######################################################################
data "aws_vpc" "main" {
  tags = {
    Name = "y0-vpc"
  }
}
data "aws_subnets" "private" {
  filter {
    name = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  tags = {
    Type = "private"
  }
}
data "aws_subnets" "public" {
  filter {
    name = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  tags = {
    Type = "public"
  }
}
# Add required tags to pre-existing subnets (to ensure EKS/LB/Karpenter functionality)
resource "aws_ec2_tag" "private_internal_elb" {
  for_each = toset(data.aws_subnets.private.ids)
  resource_id = each.value
  key = "kubernetes.io/role/internal-elb"
  value = "1"
}
resource "aws_ec2_tag" "private_karpenter_discovery" {
  for_each = toset(data.aws_subnets.private.ids)
  resource_id = each.value
  key = "karpenter.sh/discovery"
  value = "Y0-Dev-eks"  # Changed to match the fixed cluster name
}
resource "aws_ec2_tag" "public_elb" {
  for_each = toset(data.aws_subnets.public.ids)
  resource_id = each.value
  key = "kubernetes.io/role/elb"
  value = "1"
}
#######################################################################
# EKS Cluster with Auto Mode
#######################################################################
module "eks" {
  source = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"
  name = "Y0-Dev-eks"  # Changed to fixed cluster name
  kubernetes_version = "1.34"
  endpoint_public_access = true
  vpc_id = data.aws_vpc.main.id # Modified: Use pre-existing VPC
  subnet_ids = data.aws_subnets.private.ids # Modified: Use pre-existing private subnets
  # EKS Auto Mode Configuration
  compute_config = {
    enabled = true
    node_pools = ["general-purpose"]
  }
  # Core addons
  addons = {
    coredns = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni = { most_recent = true }
  }
  # IMPROVED: Security group rules for Istio (matching second script)
  node_security_group_additional_rules = {
    ingress_15017 = {
      description = "Cluster API - Istio Webhook namespace.sidecar-injector.istio.io"
      protocol = "TCP"
      from_port = 15017
      to_port = 15017
      type = "ingress"
      source_cluster_security_group = true
    }
    ingress_15012 = {
      description = "Cluster API to nodes ports/protocols"
      protocol = "TCP"
      from_port = 15012
      to_port = 15012
      type = "ingress"
      source_cluster_security_group = true
    }
  }
  enable_cluster_creator_admin_permissions = true
  tags = local.tags
}
#######################################################################
# Wait for Cluster and Initial Nodes - Windows
#######################################################################
resource "null_resource" "wait_for_cluster_and_nodes_windows" {
  count = local.is_windows ? 1 : 0
  provisioner "local-exec" {
    command = <<-EOT
      Write-Host "Waiting for EKS cluster to be active..."
      aws eks wait cluster-active --name ${module.eks.cluster_name} --region ${local.region}
   
      Write-Host "Updating kubeconfig..."
      aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${local.region}
   
      Write-Host "Waiting for Kubernetes API..."
      $count = 0
      while ($count -lt 60) {
        try {
          kubectl get nodes 2>$null
          if ($LASTEXITCODE -eq 0) {
            Write-Host "Kubernetes API is ready!"
            break
          }
        } catch {}
        Start-Sleep -Seconds 10
        $count++
      }
   
      Write-Host "Waiting for at least one node to be Ready..."
      $count = 0
      while ($count -lt 60) {
        $readyNodes = kubectl get nodes --no-headers 2>$null | Select-String "Ready" | Measure-Object | Select-Object -ExpandProperty Count
        if ($readyNodes -gt 0) {
          Write-Host "Found $readyNodes ready node(s)!"
          break
        }
        Write-Host "Waiting for nodes... ($count/60)"
        Start-Sleep -Seconds 10
        $count++
      }
   
      Write-Host "Cluster and nodes are ready!"
    EOT
 
    interpreter = ["powershell", "-Command"]
  }
  depends_on = [module.eks]
}
#######################################################################
# Wait for Cluster and Initial Nodes - Linux/Mac
#######################################################################
resource "null_resource" "wait_for_cluster_and_nodes_linux" {
  count = local.is_windows ? 0 : 1
  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for EKS cluster to be active..."
      aws eks wait cluster-active --name ${module.eks.cluster_name} --region ${local.region}
   
      echo "Updating kubeconfig..."
      aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${local.region}
   
      echo "Waiting for Kubernetes API..."
      for i in {1..60}; do
        if kubectl get nodes 2>/dev/null; then
          echo "Kubernetes API is ready!"
          break
        fi
        sleep 10
      done
   
      echo "Waiting for at least one node to be Ready..."
      for i in {1..60}; do
        READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
        if [ "$READY_NODES" -gt 0 ]; then
          echo "Found $READY_NODES ready node(s)!"
          break
        fi
        echo "Waiting for nodes... ($i/60)"
        sleep 10
      done
   
      echo "Cluster and nodes are ready!"
    EOT
 
    interpreter = ["bash", "-c"]
  }
  depends_on = [module.eks]
}
#######################################################################
# Istio Namespace
#######################################################################
resource "kubernetes_namespace_v1" "istio_system" {
  metadata {
    name = "istio-system"
  }
  depends_on = [
    null_resource.wait_for_cluster_and_nodes_windows,
    null_resource.wait_for_cluster_and_nodes_linux
  ]
}
#######################################################################
# EKS Blueprints Addons with Istio
#######################################################################
module "eks_blueprints_addons" {
  source = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.22.0"
  cluster_name = module.eks.cluster_name
  cluster_endpoint = module.eks.cluster_endpoint
  cluster_version = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn
  # AWS Load Balancer Controller
  enable_aws_load_balancer_controller = true
  aws_load_balancer_controller = {
    values = [
      yamlencode({
        clusterName = module.eks.cluster_name
        region = local.region
        vpcId = data.aws_vpc.main.id # Your existing VPC: vpc-049f6698b64a4e651
      })
    ]
  }
  # ===================================
  # IMPROVED: Declarative Istio installation using helm_releases
  helm_releases = {
    istio-base = {
      chart = "base"
      chart_version = local.istio_chart_version
      repository = local.istio_chart_url
      name = "istio-base"
      namespace = kubernetes_namespace_v1.istio_system.metadata[0].name
    }
    istiod = {
      chart = "istiod"
      chart_version = local.istio_chart_version
      repository = local.istio_chart_url
      name = "istiod"
      namespace = kubernetes_namespace_v1.istio_system.metadata[0].name
      set = [
        {
          name = "meshConfig.accessLogFile"
          value = "/dev/stdout"
        }
      ]
    }
    istio-ingress = {
      chart = "gateway"
      chart_version = local.istio_chart_version
      repository = local.istio_chart_url
      name = "istio-ingress"
      namespace = "istio-ingress"
      create_namespace = true
      values = [
        yamlencode(
          {
            labels = {
              istio = "ingressgateway"
            }
            service = {
              type = "NodePort" #New Enforced Nodeport to ignore NLB creation
            }
          }
        )
      ]
    }
  }
  depends_on = [
    module.eks,
    kubernetes_namespace_v1.istio_system,
    null_resource.wait_for_cluster_and_nodes_windows,
    null_resource.wait_for_cluster_and_nodes_linux
  ]
  tags = local.tags
}
#######################################################################
# Custom NodePool Manifest
#######################################################################
resource "local_file" "nodepool_manifest" {
  filename = "${path.module}/manifests/nodepool-t4g-medium.yaml"
  content = <<-EOT
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: t4g-medium-only
spec:
  template:
    spec:
      nodeClassRef:
        group: eks.amazonaws.com
        kind: NodeClass
        name: default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]
        - key: eks.amazonaws.com/instance-category
          operator: In
          values: ["t"]
        - key: eks.amazonaws.com/instance-generation
          operator: In
          values: ["4"]
        - key: eks.amazonaws.com/instance-size
          operator: In
          values: ["medium"]
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 30s
  weight: 100
  limits:
    cpu: 50
    memory: 100Gi
EOT
}
#######################################################################
# Create Custom NodePool - Windows
#######################################################################
resource "null_resource" "create_nodepool_windows" {
  count = local.is_windows ? 1 : 0
  triggers = {
    manifest_content = local_file.nodepool_manifest.content
    cluster_endpoint = module.eks.cluster_endpoint
  }
  provisioner "local-exec" {
    command = <<-EOT
      Write-Host "Creating custom NodePool..."
      aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${local.region}
      kubectl apply -f ${path.module}/manifests/nodepool-t4g-medium.yaml
      Write-Host "Custom NodePool created successfully!"
    EOT
 
    interpreter = ["powershell", "-Command"]
  }
  depends_on = [
    module.eks_blueprints_addons,
    local_file.nodepool_manifest
  ]
}
#######################################################################
# Create Custom NodePool - Linux/Mac
#######################################################################
resource "null_resource" "create_nodepool_linux" {
  count = local.is_windows ? 0 : 1
  triggers = {
    manifest_content = local_file.nodepool_manifest.content
    cluster_endpoint = module.eks.cluster_endpoint
  }
  provisioner "local-exec" {
    command = <<-EOT
      echo "Creating custom NodePool..."
      aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${local.region}
      kubectl apply -f ${path.module}/manifests/nodepool-t4g-medium.yaml
      echo "Custom NodePool created successfully!"
    EOT
 
    interpreter = ["bash", "-c"]
  }
  depends_on = [
    module.eks_blueprints_addons,
    local_file.nodepool_manifest
  ]
}
#######################################################################
# Cleanup Script Files
#######################################################################
resource "local_file" "cleanup_script_bash" {
  count = local.is_windows ? 0 : 1
  filename = "${path.module}/scripts/cleanup-nodepools.sh"
  content = <<-EOT
#!/usr/bin/env bash
set -e
echo "=========================================="
echo "Starting NodePool and Node Cleanup Process"
echo "=========================================="
aws eks update-kubeconfig --region "${local.region}" --name "${module.eks.cluster_name}"
echo "Waiting for custom NodePool to be ready..."
sleep 30
echo "Fetching all NodePools..."
NODEPOOLS=$(kubectl get nodepools -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
if [ -z "$NODEPOOLS" ]; then
  echo "No NodePools found"
  exit 0
fi
echo "Found NodePools: $NODEPOOLS"
NODEPOOLS_TO_DELETE=""
for nodepool in $NODEPOOLS; do
  if [ "$nodepool" = "default" ] || [ "$nodepool" = "general-purpose" ] || [ "$nodepool" = "system" ]; then
    NODEPOOLS_TO_DELETE="$NODEPOOLS_TO_DELETE $nodepool"
    echo "Marked for deletion: NodePool '$nodepool'"
  else
    echo "Keeping custom NodePool: '$nodepool'"
  fi
done
if [ -z "$NODEPOOLS_TO_DELETE" ]; then
  echo "No default/system NodePools found to delete."
  exit 0
fi
echo ""
echo "Step 1: Deleting Nodes from Default NodePools"
ALL_NODES=$(kubectl get nodes -o json)
for nodepool in $NODEPOOLS_TO_DELETE; do
  echo "Finding nodes for NodePool '$nodepool'..."
  NODES=$(echo "$ALL_NODES" | jq -r ".items[] | select(.metadata.labels[\"karpenter.sh/nodepool\"] == \"$nodepool\") | .metadata.name" 2>/dev/null || echo "")
  if [ -z "$NODES" ]; then
    echo "No nodes found for NodePool '$nodepool'"
  else
    echo "Found nodes: $NODES"
    for node in $NODES; do
      echo " Cordoning: $node"
      kubectl cordon "$node" 2>/dev/null || true
      echo " Draining: $node"
      kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force --grace-period=30 --timeout=180s --disable-eviction 2>/dev/null || true
      echo " Deleting: $node"
      kubectl delete node "$node" --timeout=60s 2>/dev/null || true
    done
  fi
done
echo ""
echo "Step 2: Deleting Default NodePools"
for nodepool in $NODEPOOLS_TO_DELETE; do
  echo "Deleting NodePool: '$nodepool'"
  kubectl delete nodepool "$nodepool" --timeout=120s 2>/dev/null || true
done
echo ""
echo "=========================================="
echo "Cleanup Completed!"
echo "=========================================="
kubectl get nodepools
kubectl get nodes
EOT
  file_permission = "0755"
}
resource "local_file" "cleanup_script_powershell" {
  count = local.is_windows ? 1 : 0
  filename = "${path.module}/scripts/cleanup-nodepools.ps1"
  content = <<-EOT
$ErrorActionPreference = "Stop"
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Starting NodePool and Node Cleanup Process" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
aws eks update-kubeconfig --region ${local.region} --name ${module.eks.cluster_name}
Write-Host "Waiting for custom NodePool to be ready..."
Start-Sleep -Seconds 30
try {
    $nodepools = kubectl get nodepools -o jsonpath='{.items[*].metadata.name}' 2>$null
 
    if ([string]::IsNullOrWhiteSpace($nodepools)) {
        Write-Host "No NodePools found"
        exit 0
    }
 
    $nodepoolArray = $nodepools -split ' '
    Write-Host "Found NodePools: $nodepools" -ForegroundColor Green
 
    $nodepoolsToDelete = @()
    foreach ($nodepool in $nodepoolArray) {
        if ($nodepool -eq "default" -or $nodepool -eq "general-purpose" -or $nodepool -eq "system") {
            $nodepoolsToDelete += $nodepool
            Write-Host "Marked for deletion: '$nodepool'" -ForegroundColor Red
        } else {
            Write-Host "Keeping custom NodePool: '$nodepool'" -ForegroundColor Green
        }
    }
 
    if ($nodepoolsToDelete.Count -eq 0) {
        Write-Host "No default/system NodePools found to delete." -ForegroundColor Green
        exit 0
    }
 
    Write-Host ""
    Write-Host "Step 1: Deleting Nodes from Default NodePools" -ForegroundColor Cyan
    $allNodesJson = kubectl get nodes -o json | ConvertFrom-Json
 
    foreach ($nodepool in $nodepoolsToDelete) {
        Write-Host "Finding nodes for NodePool '$nodepool'..."
        $nodes = $allNodesJson.items | Where-Object {
            $_.metadata.labels.'karpenter.sh/nodepool' -eq $nodepool
        } | Select-Object -ExpandProperty metadata | Select-Object -ExpandProperty name
     
        if ($null -eq $nodes -or $nodes.Count -eq 0) {
            Write-Host "No nodes found for NodePool '$nodepool'"
        } else {
            Write-Host "Found nodes: $nodes"
            foreach ($node in $nodes) {
                Write-Host " Cordoning: $node"
                kubectl cordon $node 2>$null | Out-Null
                Write-Host " Draining: $node"
                kubectl drain $node --ignore-daemonsets --delete-emptydir-data --force --grace-period=30 --timeout=180s --disable-eviction 2>$null | Out-Null
                Write-Host " Deleting: $node"
                kubectl delete node $node --timeout=60s 2>$null | Out-Null
            }
        }
    }
 
    Write-Host ""
    Write-Host "Step 2: Deleting Default NodePools" -ForegroundColor Cyan
    foreach ($nodepool in $nodepoolsToDelete) {
        Write-Host "Deleting NodePool: '$nodepool'"
        kubectl delete nodepool $nodepool --timeout=120s 2>$null | Out-Null
    }
 
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "Cleanup Completed!" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    kubectl get nodepools
    kubectl get nodes
 
} catch {
    Write-Host "Error: $_" -ForegroundColor Red
    exit 1
}
EOT
  file_permission = "0644"
}
#######################################################################
# Final Cleanup
#######################################################################
resource "null_resource" "delete_default_nodepools" {
  triggers = {
    nodepool_created = try(null_resource.create_nodepool_windows[0].id, null_resource.create_nodepool_linux[0].id)
    cluster_endpoint = module.eks.cluster_endpoint
  }
  provisioner "local-exec" {
    command = local.is_windows ? "powershell.exe -File ${path.module}/scripts/cleanup-nodepools.ps1" : "bash ${path.module}/scripts/cleanup-nodepools.sh"
    working_dir = path.module
  }
  depends_on = [
    module.eks_blueprints_addons,
    null_resource.create_nodepool_windows,
    null_resource.create_nodepool_linux,
    local_file.cleanup_script_bash,
    local_file.cleanup_script_powershell
  ]
}
#######################################################################
# Outputs - Defined in outputs.tf
#######################################################################