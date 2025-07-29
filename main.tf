provider "aws" {
  region = local.region
}

data "aws_availability_zones" "available" {}

locals {
  company          = "midecode"
  region           = "ap-southeast-1"
  project_name     = "ionos"
  ecs_cluster_name = "${local.company}-${local.project_name}"
  alb_name         = "${local.company}-${local.project_name}"
  nlb_name         = "${local.company}-${local.project_name}-nlb"
  vpc_name         = "${local.company}-${local.project_name}"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  common_tags = {
    environment = "poc"
    owner       = "midecode"
    project     = local.project_name
  }
}

################################################################################
# Cluster
################################################################################

module "ecs_cluster" {
  source = "./modules/cluster"

  name = local.ecs_cluster_name

  # Capacity provider
  default_capacity_provider_strategy = {
    FARGATE = {
      weight = 100
      # base   = 20
    }
  }

  tags = merge(local.common_tags, {})
}

################################################################################
# Supporting Resources
################################################################################

resource "aws_service_discovery_http_namespace" "this" {
  name        = local.project_name
  description = "CloudMap namespace for ${local.project_name}"
  tags        = merge(local.common_tags, {})
}

################################################################################
# Application Load Balancer 
################################################################################

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 9.0"

  name = local.alb_name

  load_balancer_type = "application"

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.public_subnets

  # For example only
  enable_deletion_protection = false

  # Security Group
  security_group_name = "${local.alb_name}-alb-sg"
  security_group_ingress_rules = {
    http = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
    }
    https = {
      from_port   = 443
      to_port     = 443
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = module.vpc.vpc_cidr_block
    }
  }

  listeners = {
    http = {
      port     = 80
      protocol = "HTTP"

      # Default action for requests that don't match any rules
      fixed_response = {
        content_type = "text/plain"
        message_body = "ALB: No matching rule found"
        status_code  = "404"
      }

      rules = {
        (local.service1_name) = {
          priority   = 101
          conditions = [{ host_header = { values = ["nginx1.midecode.com"] } }]
          actions    = [{ type = "forward", target_group_key = "${local.service1_name}" }]
        }

        (local.service2_name) = {
          priority   = 102
          conditions = [{ host_header = { values = ["nginx2.midecode.com"] } }]
          actions    = [{ type = "forward", target_group_key = "${local.service2_name}" }]
        }
      }
    }

    https = {
      port            = 443
      protocol        = "HTTPS"
      ssl_policy      = "ELBSecurityPolicy-2016-08"
      certificate_arn = "arn:aws:acm:ap-southeast-1:058264383156:certificate/15f45bf6-77d2-47a7-b24e-a7b154c04e26"

      # Default action for requests that don't match any rules
      fixed_response = {
        content_type = "text/plain"
        message_body = "ALB: No matching rule found"
        status_code  = "404"
      }

      rules = {
        (local.service1_name) = {
          priority   = 101
          conditions = [{ host_header = { values = ["nginx1.midecode.com"] } }]
          actions    = [{ type = "forward", target_group_key = "${local.service1_name}" }]
        }
        (local.service2_name) = {
          priority   = 102
          conditions = [{ host_header = { values = ["nginx2.midecode.com"] } }]
          actions    = [{ type = "forward", target_group_key = "${local.service2_name}" }]
        }
      }
    }
  }

  target_groups = {
    (local.service1_name) = {
      backend_protocol                  = "HTTP"
      backend_port                      = local.service1_container_port
      target_type                       = "ip"
      deregistration_delay              = 5
      load_balancing_cross_zone_enabled = true

      health_check = {
        enabled             = true
        healthy_threshold   = 5
        interval            = 30
        matcher             = "200"
        path                = "/"
        port                = "traffic-port"
        protocol            = "HTTP"
        timeout             = 5
        unhealthy_threshold = 2
      }

      create_attachment = false
    }

    (local.service2_name) = {
      backend_protocol                  = "HTTP"
      backend_port                      = local.service2_container_port
      target_type                       = "ip"
      deregistration_delay              = 5
      load_balancing_cross_zone_enabled = true

      health_check = {
        enabled             = true
        healthy_threshold   = 5
        interval            = 30
        matcher             = "200"
        path                = "/"
        port                = "traffic-port"
        protocol            = "HTTP"
        timeout             = 5
        unhealthy_threshold = 2
      }

      # There's nothing to attach here in this definition. Instead,
      # ECS will attach the IPs of the tasks to this target group
      create_attachment = false
    }

  }

  tags = merge(local.common_tags, {
    Name = local.alb_name
  })
}

################################################################################
# Network Load Balancer 
################################################################################

module "nlb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 9.0"

  name = local.nlb_name

  load_balancer_type = "network"
  internal           = true

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.private_subnets

  # For example only
  enable_deletion_protection = false

  # Security Group
  security_group_name = "${local.alb_name}-nlb-sg"
  security_group_ingress_rules = {
    http = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = module.vpc.vpc_cidr_block
    }
  }

  listeners = {
    (local.service3_name) = {
      port     = 8081
      protocol = "TCP"
      forward = {
        target_group_key = local.service3_name
      }
    }
  }

  target_groups = {
    (local.service3_name) = {
      backend_protocol = "TCP"
      protocol         = "TCP"
      backend_port     = local.service3_container_port
      target_type      = "ip"

      health_check = {
        enabled             = true
        healthy_threshold   = 5
        interval            = 30
        port                = "traffic-port"
        protocol            = "TCP"
        timeout             = 5
        unhealthy_threshold = 2
      }

      create_attachment = false
    }
  }

  tags = merge(local.common_tags, {
    Name = local.alb_name
  })
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.vpc_name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = merge(local.common_tags, {
    Name = local.vpc_name
  })
}

