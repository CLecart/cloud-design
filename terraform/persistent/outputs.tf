output "registry" {
  description = "ECR registry host, used by `docker login` and in the image names."
  value       = split("/", values(aws_ecr_repository.this)[0].repository_url)[0]
}

output "repository_urls" {
  description = "Image name => repository URL."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "cognito_user_pool_id" {
  description = "Cognito user pool of the API users."
  value       = aws_cognito_user_pool.this.id
}

output "cognito_client_id" {
  description = "App client the users sign in with; also the audience checked by API Gateway."
  value       = aws_cognito_user_pool_client.api.id
}

output "cognito_issuer" {
  description = "Token issuer checked by the API Gateway JWT authorizer."
  value       = "https://${aws_cognito_user_pool.this.endpoint}"
}
