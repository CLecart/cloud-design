# Private registries for the six images. They outlive the platform stack so the
# images are pushed once instead of at every session (storage: 0.10 USD/GB-month).
resource "aws_ecr_repository" "this" {
  for_each = toset(var.images)

  name                 = "${var.project}/${each.key}"
  image_tag_mutability = "MUTABLE"

  # `terraform destroy` also removes the repositories that still hold images.
  force_delete = true

  # Basic scanning (vulnerabilities of the OS packages) at every push. Enhanced
  # scanning relies on Amazon Inspector, which the Free plan does not include.
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
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
