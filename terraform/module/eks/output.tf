output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value = "aws eks --region ${local.region} update-kubeconfig --name ${module.eks.cluster_name}"
}
output "verify_auto_mode" {
  description = "Verify Auto Mode is working"
  value = "kubectl get nodes # Should show nodes automatically created by Auto Mode"
}
output "cluster_name" {
  description = "EKS Cluster Name"
  value = module.eks.cluster_name
}
output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value = module.eks.cluster_endpoint
}
output "cluster_security_group_id" {
  description = "Security group ids attached to the cluster control plane"
  value = module.eks.cluster_security_group_id
}
output "region" {
  description = "AWS region"
  value = local.region
}
output "vpc_id" {
  description = "The ID of the VPC"
  value = data.aws_vpc.main.id # Modified: Use pre-existing VPC ID
}
output "custom_nodepool_name" {
  description = "Custom NodePool Name"
  value = "t4g-medium-only"
}
output "cleanup_status" {
  description = "NodePool and Node cleanup status"
  value = "Default NodePools and their nodes will be automatically deleted after infrastructure is ready"
}