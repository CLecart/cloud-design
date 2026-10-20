variable "region" {
  description = "AWS Region of the whole project (Paris)."
  type        = string
  default     = "eu-west-3"
}

variable "project" {
  description = "Name prefix of every resource; also the EKS cluster name."
  type        = string
  default     = "cloud-design"
}

variable "admin_cidrs" {
  description = "Public IP ranges allowed to reach the EKS API (kubectl, terraform), e.g. [\"203.0.113.7/32\"]."
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0 && !contains(var.admin_cidrs, "0.0.0.0/0")
    error_message = "List at least one range and never 0.0.0.0/0: the cluster API must not be open to the whole Internet."
  }
}

variable "kubernetes_version" {
  description = "EKS version. Keep it in standard support (0.10 USD/h); extended support costs 0.50 USD/h."
  type        = string
  default     = "1.36"
}

variable "node_instance_type" {
  description = "Worker node type. The Free plan only accepts the free-tier-eligible types (aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true)."
  type        = string
  default     = "c7i-flex.large"
}

variable "node_min_size" {
  description = "Minimum number of worker nodes (two, one per Availability Zone)."
  type        = number
  default     = 2
}

variable "node_desired_size" {
  description = "Number of worker nodes at creation."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Upper bound for the cluster autoscaler."
  type        = number
  default     = 3
}
