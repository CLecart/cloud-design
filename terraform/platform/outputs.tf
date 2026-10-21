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

output "alb_dns_name" {
  description = "Internal DNS name of the api-gateway load balancer (resolvable inside the VPC only)."
  value       = aws_lb.api.dns_name
}

output "api_url" {
  description = "Public HTTPS URL of the application (API Gateway)."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "container_log_group" {
  description = "CloudWatch log group of the six services (Fluent Bit)."
  value       = aws_cloudwatch_log_group.containers.name
}

output "dashboard_url" {
  description = "CloudWatch dashboard of API Gateway and of the internal load balancer."
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.platform.dashboard_name}"
}

output "alb_target_group_arn" {
  description = "Target group of the worker nodes (aws elbv2 describe-target-health)."
  value       = aws_lb_target_group.api_gateway.arn
}
