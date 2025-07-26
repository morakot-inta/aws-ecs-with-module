locals {
  service1_name           = "nginx1"
  service1_container_name = "nginx"
  service1_container_port = 80
}
module "ecs_service" {
  source = "./modules/service"

  name        = local.service1_name
  cluster_arn = module.ecs_cluster.arn

  cpu    = 1024
  memory = 4096

  # Enables ECS Exec
  enable_execute_command = true

  # Subnet IDs for the service
  subnet_ids = module.vpc.private_subnets

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
      cloudwatch_log_group_retention_in_days = 7 

      memoryReservation = 100
      # when container run, it will change the default nginx page
      command = [
        "sh",
        "-c",
        "echo '<h1>Hello from ${local.service1_name}</h1>' > /usr/share/nginx/html/index.html && exec nginx -g 'daemon off;'"
      ]

    }
  }

  service_connect_configuration = {
    namespace = aws_service_discovery_http_namespace.this.arn
    service = [
      {
        client_alias = {
          port     = local.service1_container_port
          dns_name = local.service1_name
        }
        port_name      = local.service1_container_name
        discovery_name = local.service1_name
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

  ################################################################################
  # Service - IAM Role
  ################################################################################
  task_exec_iam_role_name = "${local.service1_name}-ecs-task-exec-role"
  tasks_iam_role_name     = "${local.service1_name}-ecs-task-role"
  tasks_iam_role_policies = {
    ReadOnlyAccess        = "arn:aws:iam::aws:policy/ReadOnlyAccess"
    SSMManageInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
  tasks_iam_role_statements = [
    {
      actions   = ["s3:List*"]
      resources = ["arn:aws:s3:::*"]
    },
  ]


  ################################################################################
  # Security Group
  ################################################################################
  security_group_name = "${local.service1_name}-ecs-service-sg"
  security_group_ingress_rules = {
    alb = {
      description                  = "Service port"
      from_port                    = local.service1_container_port
      ip_protocol                  = "tcp"
      referenced_security_group_id = module.alb.security_group_id
    }
    ecs_service_connect = {
      description                  = "Service Connect port"
      from_port                    = 0
      to_port                      = 0 
      ip_protocol                  = "tcp"
      referenced_security_group_id = module.ecs_service.security_group_id
    }
  }
  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }

  tags = merge(local.common_tags, {
    Name = local.service1_name
  }) 
  depends_on = [
    module.alb
  ]
}
