terraform {
  required_version = ">= 0.12.2"

  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "leblanc-codes"

    workspaces {
      name = "l8rdev"
    }
  }
}

provider "aws" {
  version = "~> 2.48"
}

//provider "kubernetes" {
//  version          = "~> 1.10"
//  load_config_file = false
//
//  host                   = data.aws_eks_cluster.cluster.endpoint
//  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
//  token                  = data.aws_eks_cluster_auth.cluster.token
//}

locals {
  common-tags = {
    Project     = var.project-name
    Environment = var.environment
  }

  cluster_name    = lower("${var.project-name}-${var.environment}")
  zones           = [for idx, n in data.aws_availability_zones.available.names : n if idx < 3]
  public_prefix   = cidrsubnet(var.vpc-cidr, 1, 0)
  public_subnets  = [for idx, _ in local.zones : cidrsubnet(local.public_prefix, 6, idx)]
  private_prefix  = cidrsubnet(var.vpc-cidr, 1, 0)
  private_subnets = [for idx, _ in local.zones : cidrsubnet(local.private_prefix, 6, idx)]
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

resource "aws_route53_zone" "l8r-dev" {
  name = "l8r.dev"
}

resource "aws_security_group" "public-worker" {
  name_prefix = "public-group-mgmt"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_security_group" "private-worker" {
  name_prefix = "private-group-mgmt"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_security_group_rule" "public-worker-egress" {
  security_group_id = aws_security_group.public-worker.id
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  from_port         = 0
  to_port           = 0
  protocol          = "all"
}

resource "aws_security_group_rule" "public-worker-egress-private" {
  security_group_id        = aws_security_group.public-worker.id
  type                     = "egress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "all"
  source_security_group_id = aws_security_group.private-worker.id
}

resource "aws_security_group_rule" "public-worker-ingress-http" {
  security_group_id = aws_security_group.public-worker.id
  type              = "ingress"
  // TODO: this should only be open to an lb
  cidr_blocks      = ["0.0.0.0/0"]
  ipv6_cidr_blocks = ["::/0"]
  from_port        = 80
  to_port          = 80
  protocol         = "tcp"
}

resource "aws_security_group_rule" "public-worker-ingress-https" {
  security_group_id = aws_security_group.public-worker.id
  type              = "ingress"
  // TODO: this should only be open to an lb
  cidr_blocks      = ["0.0.0.0/0"]
  ipv6_cidr_blocks = ["::/0"]
  from_port        = 443
  to_port          = 443
  protocol         = "tcp"
}

resource "aws_security_group_rule" "public-worker-ingress-ssh" {
  security_group_id = aws_security_group.public-worker.id
  type              = "ingress"
  // TODO: this shouldn't be open to everyone
  cidr_blocks      = ["0.0.0.0/0"]
  ipv6_cidr_blocks = ["::/0"]
  from_port        = 22
  to_port          = 22
  protocol         = "tcp"
}

resource "aws_security_group_rule" "public-worker-ingress-app-ssh" {
  security_group_id = aws_security_group.public-worker.id
  type              = "ingress"
  // TODO: this should only be open to an lb
  cidr_blocks      = ["0.0.0.0/0"]
  ipv6_cidr_blocks = ["::/0"]
  from_port        = 8022
  to_port          = 8022
  protocol         = "tcp"
}

resource "aws_security_group_rule" "private-worker-egress" {
  security_group_id = aws_security_group.private-worker.id
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
  from_port         = 0
  to_port           = 0
  protocol          = "all"
}

resource "aws_security_group_rule" "private-worker-ingress-public" {
  security_group_id        = aws_security_group.private-worker.id
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "all"
  source_security_group_id = aws_security_group.public-worker.id
}

module "vpc" {
  source = "./modules/vpc"

  name                            = "vpc-${local.cluster_name}"
  cidr                            = var.vpc-cidr
  assign_ipv6_address_on_creation = true

  azs                         = local.zones
  public_subnets              = local.public_subnets
  public_subnet_ipv6_prefixes = [for idx, _ in local.public_subnets : idx]
  private_subnets             = local.private_subnets

  enable_ipv6            = true
  enable_dns_hostnames   = true
  enable_dns_support     = true
  enable_nat_gateway     = true
  one_nat_gateway_per_az = true

  tags = merge(
    local.common-tags,
    {
      "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    },
  )

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

module "eks" {
  source = "./modules/eks"

  write_kubeconfig = false

  cluster_enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  cluster_name = local.cluster_name
  subnets      = module.vpc.public_subnets
  vpc_id       = module.vpc.vpc_id

  worker_groups_launch_template = [
    {
      name                 = "public-group"
      instance_type        = "t3.micro"
      asg_desired_capacity = 3
      asg_max_size         = 5
      public_ip            = true
    },
    {
      name                 = "private-group"
      instance_type        = "t3.micro"
      spot_instance_pools  = 4
      asg_desired_capacity = 3
      asg_max_size         = 5
      public_ip            = false
      kubelet_extra_args   = "--node-labels=kubernetes.io/lifecycle=spot"
    }
  ]
}
