# Private registries for the six images. They outlive the platform stack so the
# images are pushed once instead of at every session (storage: 0.10 USD/GB-month).
resource "aws_ecr_repository" "this" {
  for_each = toset(var.images)

  name                 = "${var.project}/${each.key}"
  image_tag_mutability = "MUTABLE"

  # `terraform destroy` also removes the repositories that still hold images.
  force_delete = true

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Basic scanning (vulnerabilities of the OS packages) at every push of a project
# image. Scan on push is a registry-level filter: without a matching rule ECR
# leaves the repositories in manual scanning, whatever their own scanOnPush flag.
# Enhanced scanning relies on Amazon Inspector, which the Free plan does not include.
resource "aws_ecr_registry_scanning_configuration" "this" {
  scan_type = "BASIC"

  rule {
    scan_frequency = "SCAN_ON_PUSH"
    repository_filter {
      filter      = "${var.project}/*"
      filter_type = "WILDCARD"
    }
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the ${var.images_to_keep} most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.images_to_keep
      }
      action = { type = "expire" }
    }]
  })
}
