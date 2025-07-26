provider "aws" {
  region = local.region
}

data "aws_availability_zones" "available" {}

locals {
  region = "ap-southeast-1"
  name   = "ex-${basename(path.cwd)}"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  service1_name = "ecs-demo-frontend"
  service1_container_name = "ecsdemo-frontend"
  service1_container_port = 80 

  service2_container_name = "ecsdemo-frontend"
  service2_container_port = 80 

  tags = {
    Name       = local.name
    Example    = local.name
    Repository = "https://github.com/terraform-aws-modules/terraform-aws-ecs"
  }
}

################################################################################
# Cluster
################################################################################

module "ecs_cluster" {
  source = "./modules/cluster"

  name = local.name

  # Capacity provider
  default_capacity_provider_strategy = {
    FARGATE = {
      weight = 50
      base   = 20
    }
    FARGATE_SPOT = {
      weight = 50
    }
  }

  tags = local.tags
}

################################################################################
# Service
################################################################################

module "ecs_service" {
  source = "./modules/service"

  name        = local.name
  cluster_arn = module.ecs_cluster.arn

  cpu    = 1024
  memory = 4096

  # Enables ECS Exec
  enable_execute_command = true

  # Container definition(s)
  container_definitions = {


    (local.service1_container_name) = {
      cpu       = 512
      memory    = 1024
      essential = true
      image     = "nginx:latest"
      portMappings = [
        {
          name          = local.service1_container_name
          containerPort = local.service1_container_port
          hostPort      = local.service1_container_port
          protocol      = "tcp"
        }
      ]

      # Example image used requires access to write to root filesystem
      readonlyRootFilesystem = false

      memoryReservation = 100
    }
  }

  service_connect_configuration = {
    namespace = aws_service_discovery_http_namespace.this.arn
    service = [
      {
        client_alias = {
          port     = local.service1_container_port
          dns_name = local.service1_container_name
        }
        port_name      = local.service1_container_name
        discovery_name = local.service1_container_name
      }
    ]
  }

  load_balancer = {
    service = {
      target_group_arn = module.alb.target_groups[local.service1_name].arn
      container_name   = local.service1_container_name
      container_port   = local.service1_container_port
    }
  }

  subnet_ids = module.vpc.private_subnets
  security_group_ingress_rules = {
    alb_3000 = {
      description                  = "Service port"
      from_port                    = local.service1_container_port
      ip_protocol                  = "tcp"
      referenced_security_group_id = module.alb.security_group_id
    }
  }
  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }

  service_tags = {
    "ServiceTag" = "Tag on service level"
  }

  tags = local.tags

  depends_on = [
    module.alb
  ]
}


################################################################################
# Supporting Resources
################################################################################

resource "aws_service_discovery_http_namespace" "this" {
  name        = local.name
  description = "CloudMap namespace for ${local.name}"
  tags        = local.tags
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 9.0"

  name = local.name

  load_balancer_type = "application"

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.public_subnets

  # For example only
  enable_deletion_protection = false

  # Security Group
  security_group_ingress_rules = {
    all_http = {
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
        example_com_rule = {
          priority = 100
          
          conditions = [
            {
              host_header = {
                values = ["nginx.midecode.com"]
              }
            }
          ]

          actions = [
            {
              type             = "forward"
              target_group_key = "${local.service1_name}" 
            }
          ]
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

      # There's nothing to attach here in this definition. Instead,
      # ECS will attach the IPs of the tasks to this target group
      create_attachment = false
    }

  }

  tags = local.tags
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = local.tags
}

