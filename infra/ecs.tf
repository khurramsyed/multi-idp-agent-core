# Mock Claims and Policy APIs on ECS Fargate (ARM64) behind an internal ALB.

resource "aws_ecs_cluster" "this" {
  name = "${local.name}-apis"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = { Component = "system-of-record" }
}

resource "aws_cloudwatch_log_group" "api" {
  for_each          = local.api_services
  name              = "/ecs/${local.name}/${each.key}"
  retention_in_days = var.log_retention_days
  tags              = { Component = each.key }
}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_execution" {
  name               = "${local.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "api" {
  for_each                 = local.api_services
  family                   = "${local.name}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name                   = each.key
    image                  = "${aws_ecr_repository.this[each.key].repository_url}:${var.image_tag}"
    essential              = true
    readonlyRootFilesystem = true
    portMappings           = [{ containerPort = 8080, protocol = "tcp" }]
    environment = [
      { name = "COGNITO_ISSUER", value = local.cognito_issuer },
      { name = "APP_CLIENT_ID", value = aws_cognito_user_pool_client.assistant.id },
      { name = "REQUIRED_SCOPE", value = local.api_scope },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.api[each.key].name
        awslogs-region        = var.region
        awslogs-stream-prefix = each.key
      }
    }
  }])

  tags = { Component = each.key }
}

resource "aws_lb" "api" {
  name                       = "${local.name}-api"
  internal                   = true
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.private[*].id
  drop_invalid_header_fields = true
  tags                       = { Component = "system-of-record" }
}

resource "aws_lb_target_group" "api" {
  for_each    = local.api_services
  name        = substr("${local.name}-${each.key}", 0, 32)
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.this.id

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 10
  tags                 = { Component = each.key }
}

# Internal plain HTTP keeps the demo simple. For production, add an ACM
# certificate and an HTTPS listener so the user's token is encrypted in transit.
resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"detail\":\"not found\"}"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "api" {
  for_each     = local.api_services
  listener_arn = aws_lb_listener.api.arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api[each.key].arn
  }

  condition {
    path_pattern {
      values = each.value.paths
    }
  }
}

resource "aws_ecs_service" "api" {
  for_each        = local.api_services
  name            = each.key
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.api[each.key].arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.services.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api[each.key].arn
    container_name   = each.key
    container_port   = 8080
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener_rule.api, aws_route_table_association.private]
  tags       = { Component = each.key }
}
