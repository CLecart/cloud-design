variable "region" {
  description = "AWS Region of the whole project (Paris)."
  type        = string
  default     = "eu-west-3"
}

variable "project" {
  description = "Name prefix of every resource."
  type        = string
  default     = "cloud-design"
}

variable "images" {
  description = "One ECR repository per image built from Dockerfiles/<name>."
  type        = list(string)
  default = [
    "api-gateway",
    "inventory-app",
    "inventory-database",
    "billing-app",
    "billing-database",
    "rabbitmq-server",
  ]
}

variable "images_to_keep" {
  description = "Number of images kept per repository; older ones are expired by the lifecycle policy."
  type        = number
  default     = 5
}
