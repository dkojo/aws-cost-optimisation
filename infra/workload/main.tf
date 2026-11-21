# A small web tier, sized and scaled for cost. The pipeline plans it, prices it and checks it on every change.
# It is never applied, so it costs nothing to run this repo.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

# 1. Cost tagging: every resource the provider creates gets these tags automatically
provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = local.cost_tags
  }
}

locals {
  cost_tags = {
    Project     = "aws-cost-optimisation"
    CostCenter  = "platform"
    Owner       = "devops"
    Environment = "production"
  }
  # Two Availability Zones, so losing one zone doesn't take the service down
  zones = ["us-east-1a", "us-east-1b"]
}

resource "aws_vpc" "main" {
  cidr_block           = "10.40.0.0/16"
  enable_dns_hostnames = true
}

resource "aws_subnet" "web" {
  count             = length(local.zones)
  vpc_id            = aws_vpc.main.id
  availability_zone = local.zones[count.index]
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
}

resource "aws_security_group" "web" {
  name   = "web"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 2. Rightsizing: a small Graviton (arm64) instance and a small gp3 disk
resource "aws_launch_template" "web" {
  name          = "web"
  image_id      = "resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
  instance_type = "t4g.micro"

  vpc_security_group_ids = [aws_security_group.web.id]

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 8
      volume_type = "gp3"
      encrypted   = true
    }
  }

  metadata_options {
    http_tokens = "required"
  }

  # default_tags don't reach instances launched by Auto Scaling, so tag them here too
  tag_specifications {
    resource_type = "instance"
    tags          = local.cost_tags
  }
  tag_specifications {
    resource_type = "volume"
    tags          = local.cost_tags
  }
}

# 3. Auto Scaling: 2 instances by day across both zones, up to 4 under load
resource "aws_autoscaling_group" "web" {
  name                      = "web"
  min_size                  = 2
  max_size                  = 4
  desired_capacity          = 2
  vpc_zone_identifier       = aws_subnet.web[*].id
  health_check_type         = "EC2"
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }
}

# Add or remove instances to keep average CPU near 50%
resource "aws_autoscaling_policy" "cpu" {
  name                   = "keep-cpu-at-50"
  autoscaling_group_name = aws_autoscaling_group.web.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 50
  }
}

# Quiet hours: scale down to 1 instance at night and back to 2 in the morning (UTC, weekdays)
resource "aws_autoscaling_schedule" "night" {
  scheduled_action_name  = "night-scale-down"
  autoscaling_group_name = aws_autoscaling_group.web.name
  recurrence             = "0 20 * * 1-5"
  min_size               = 1
  max_size               = 2
  desired_capacity       = 1
}

resource "aws_autoscaling_schedule" "morning" {
  scheduled_action_name  = "morning-scale-up"
  autoscaling_group_name = aws_autoscaling_group.web.name
  recurrence             = "0 7 * * 1-5"
  min_size               = 2
  max_size               = 4
  desired_capacity       = 2
}
