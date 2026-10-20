module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.project
  kubernetes_version = var.kubernetes_version

  # Public API endpoint, restricted to the admin IPs; the nodes use the private one.
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.admin_cidrs

  # The IAM identity running terraform becomes cluster admin (EKS access entry).
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # No customer managed KMS key (1 USD/month, and a 7-day minimum deletion wait):
  # EKS already encrypts all Kubernetes API data by default since version 1.28.
  create_kms_key    = false
  encryption_config = null

  # Control plane logs in CloudWatch, kept one day only.
  enabled_log_types                      = ["api", "audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 1

  addons = {
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
    kube-proxy             = {}
    coredns                = {}
    # Resource metrics for the HorizontalPodAutoscalers.
    metrics-server = {}
    # Encrypted gp3 volumes for the databases and RabbitMQ.
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  eks_managed_node_groups = {
    main = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_type]
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min_size
      desired_size = var.node_desired_size
      max_size     = var.node_max_size
    }
  }
}

# Role assumed by the EBS CSI controller through EKS Pod Identity.
resource "aws_iam_role" "ebs_csi" {
  name = "${var.project}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
