output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "region" {
  description = "AWS Region of the cluster."
  value       = var.region
}

output "configure_kubectl" {
  description = "Command that adds the cluster to ~/.kube/config."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "vpc_id" {
  description = "VPC of the platform."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnets (nodes, pods, internal load balancers)."
  value       = module.vpc.private_subnets
}
