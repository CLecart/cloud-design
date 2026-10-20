data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# Two Availability Zones, each with a public subnet (load balancers, NAT) and a
# private subnet (worker nodes, pods, databases). The private subnets are large
# because the VPC CNI gives every pod an address from them.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.project
  cidr = "10.0.0.0/16"
  azs  = local.azs

  private_subnets = ["10.0.0.0/19", "10.0.32.0/19"]
  public_subnets  = ["10.0.96.0/24", "10.0.97.0/24"]

  # One NAT gateway (0.05 USD/h) instead of one per zone: the nodes keep pulling
  # images if a zone fails only while the NAT zone is up, an accepted trade-off.
  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true

  # Subnet discovery for the AWS Load Balancer Controller.
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}
