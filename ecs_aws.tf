############################################
# Variables
############################################

variable "aws_account_id" {
  default = "911540681189"
}

variable "ecs_cluster_name" {
  default = "crt-lab"
}

variable "alb_name" {
  default = "crt-lab-api"
}

variable "service_name" {
  default = "crt-creative-studio"
}

variable "container_port" {
  default = 8080
}

variable "public_domain" {
  default = "media.lab.create-store.com"
}

variable "route53_zone_name" {
  default = "lab.create-store.com"
}

variable "acm_certificate_arn" {
  default = "arn:aws:acm:eu-south-2:911540681189:certificate/7f836d97-53f8-49c4-95f1-1299bb71db23"
}

variable "basic_auth_user" {
  default = "admin"
}

variable "basic_auth_password" {
  sensitive = true
  default   = "changeme-ROTATE-ME"
}

variable "gcp_project_id" {
  default = "crt-creative-team"
}

variable "gcp_sa_key_file" {
  description = "Local path to GCP service account JSON key"
  default     = "/tmp/creative-studio-key.json"
}

variable "task_cpu" {
  default = "1024"
}

variable "task_memory" {
  default = "2048"
}

############################################
# Data sources (existing infra)
############################################

data "aws_lb" "api" {
  name = var.alb_name
}

data "aws_lb_listener" "https" {
  load_balancer_arn = data.aws_lb.api.arn
  port              = 443
}

data "aws_vpc" "main" {
  id = data.aws_lb.api.vpc_id
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  tags = {
    Tier = "private-app"
  }
}

data "aws_route53_zone" "public" {
  name         = "${var.route53_zone_name}."
  private_zone = false
}

data "aws_iam_role" "ecs_execution" {
  name = "crt-lab-ecs-task-execution"
}

############################################
# ECR repository
############################################

resource "aws_ecr_repository" "creative_studio" {
  name                 = "skl/${var.service_name}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "creative_studio" {
  repository = aws_ecr_repository.creative_studio.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

############################################
# Secrets Manager
############################################

resource "aws_secretsmanager_secret" "config" {
  name                    = "${var.service_name}/config"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "config" {
  secret_id = aws_secretsmanager_secret.config.id
  secret_string = jsonencode({
    BASIC_AUTH_USER = var.basic_auth_user
    BASIC_AUTH_PASS = var.basic_auth_password
    GCP_SA_KEY_JSON = file(var.gcp_sa_key_file)
    GCP_PROJECT_ID  = var.gcp_project_id
  })
}

############################################
# IAM — task role (runtime perms inside container)
############################################

resource "aws_iam_role" "task" {
  name = "${var.service_name}-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Allow execution role to read this secret (uses existing shared execution role)
resource "aws_iam_role_policy" "execution_secret_access" {
  name = "${var.service_name}-secret-access"
  role = data.aws_iam_role.ecs_execution.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.config.arn
    }]
  })
}

############################################
# Security group — ECS task
############################################

resource "aws_security_group" "task" {
  name        = "${var.service_name}-task"
  description = "ECS task SG for ${var.service_name}"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    from_port   = var.container_port
    to_port     = var.container_port
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
    description = "VPC to container port"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

############################################
# CloudWatch log group (reuses existing /ecs/crt-lab pattern via prefix)
############################################

resource "aws_cloudwatch_log_group" "creative_studio" {
  name              = "/ecs/crt-lab/${var.service_name}"
  retention_in_days = 14
}

############################################
# ALB target group + listener rule
############################################

resource "aws_lb_target_group" "creative_studio" {
  name        = var.service_name
  port        = var.container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.aws_vpc.main.id

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30
}

resource "aws_lb_listener_rule" "creative_studio" {
  listener_arn = data.aws_lb_listener.https.arn
  priority     = 150

  condition {
    host_header {
      values = [var.public_domain]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.creative_studio.arn
  }
}

############################################
# Route53 record
############################################

resource "aws_route53_record" "creative_studio" {
  zone_id = data.aws_route53_zone.public.zone_id
  name    = var.public_domain
  type    = "A"

  alias {
    name                   = data.aws_lb.api.dns_name
    zone_id                = data.aws_lb.api.zone_id
    evaluate_target_health = true
  }
}

############################################
# ECS Task Definition
############################################

locals {
  aws_asset_bucket_name = "creative-studio-${var.gcp_project_id}-assets"
  env_vars = {
    ENABLE_BASIC_AUTH                     = "false"
    ENABLE_CF_ACCESS                      = "false"
    PROJECT_ID                            = var.gcp_project_id
    LOCATION                              = "us-central1"
    GEMINI_TTS_LOCATION                   = "global"
    MODEL_ID                              = "gemini-2.5-flash"
    GEMINI_CRITIQUE_MODEL_ID              = "gemini-3-flash-preview"
    GEMINI_CRITIQUE_LOCATION              = "global"
    CHARACTER_CONSISTENCY_GEMINI_LOCATION = "global"
    VEO_MODEL_ID                          = "veo-3.1-fast-generate-001"
    VEO_EXP_MODEL_ID                      = "veo-3.1-generate-001"
    LYRIA_MODEL_VERSION                   = "lyria-002"
    LYRIA_PROJECT_ID                      = var.gcp_project_id
    GENMEDIA_BUCKET                       = local.aws_asset_bucket_name
    VIDEO_BUCKET                          = local.aws_asset_bucket_name
    MEDIA_BUCKET                          = local.aws_asset_bucket_name
    IMAGE_BUCKET                          = local.aws_asset_bucket_name
    GCS_ASSETS_BUCKET                     = local.aws_asset_bucket_name
    GENMEDIA_FIREBASE_DB                  = "create-studio-asset-metadata"
    SERVICE_ACCOUNT_EMAIL                 = "creative-studio-aws@${var.gcp_project_id}.iam.gserviceaccount.com"
    EDIT_IMAGES_ENABLED                   = "true"
    GOOGLE_APPLICATION_CREDENTIALS        = "/tmp/gcp-sa-key.json"
    APP_ENV                               = "production"
    PYTHONUNBUFFERED                      = "1"
    DEBUG_MODE                            = "true"
  }
}

resource "aws_ecs_task_definition" "creative_studio" {
  family                   = var.service_name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = data.aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "creative-studio"
      image     = "${aws_ecr_repository.creative_studio.repository_url}:latest"
      essential = true

      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
      }]

      environment = [for k, v in local.env_vars : { name = k, value = tostring(v) }]

      secrets = [
        { name = "BASIC_AUTH_USER", valueFrom = "${aws_secretsmanager_secret.config.arn}:BASIC_AUTH_USER::" },
        { name = "BASIC_AUTH_PASS", valueFrom = "${aws_secretsmanager_secret.config.arn}:BASIC_AUTH_PASS::" },
        { name = "GCP_SA_KEY_JSON", valueFrom = "${aws_secretsmanager_secret.config.arn}:GCP_SA_KEY_JSON::" },
      ]

      # Write GCP key file from env var on startup
      entryPoint = ["/bin/sh", "-c"]
      command = [
        "printf '%s' \"$GCP_SA_KEY_JSON\" > /tmp/gcp-sa-key.json && exec /app/.venv/bin/uvicorn main:app --host 0.0.0.0 --port ${var.container_port} --workers 1 --proxy-headers --forwarded-allow-ips '*'"
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.creative_studio.name
          awslogs-region        = "eu-south-2"
          awslogs-stream-prefix = "creative-studio"
        }
      }
    }
  ])

  tags = {
    Name = var.service_name
    Team = "create-store"
  }
}

############################################
# ECS Service
############################################

resource "aws_ecs_service" "creative_studio" {
  name            = var.service_name
  cluster         = var.ecs_cluster_name
  task_definition = aws_ecs_task_definition.creative_studio.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.private.ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.creative_studio.arn
    container_name   = "creative-studio"
    container_port   = var.container_port
  }

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 200

  depends_on = [aws_lb_listener_rule.creative_studio]
}

############################################
# Outputs
############################################

output "service_url" {
  value = "https://${var.public_domain}"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.creative_studio.repository_url
}

output "alb_dns" {
  value = data.aws_lb.api.dns_name
}
