output "registry" {
  description = "ECR registry host, used by `docker login` and in the image names."
  value       = split("/", values(aws_ecr_repository.this)[0].repository_url)[0]
}

output "repository_urls" {
  description = "Image name => repository URL."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}
