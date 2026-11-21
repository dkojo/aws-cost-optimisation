# Budget monitoring, applied from main by the pipeline. All of it is free.
#   - a monthly budget that alerts at 80% of actual spend and when the forecast goes over 100%
#   - Cost Anomaly Detection, which alerts on unusual spend in any AWS service
#   - one SNS topic, cost-alerts, that both send to (subscribe your email to it to get the alerts)

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  backend "s3" {
    bucket       = "danielkojomegbenu-tfstate"
    key          = "aws-cost-optimisation/guardrails.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Project     = "aws-cost-optimisation"
      CostCenter  = "platform"
      Owner       = "devops"
      Environment = "production"
    }
  }
}

variable "monthly_budget_usd" {
  description = "Monthly budget for the workload. The pipeline's budget gate uses the same number."
  type        = number
  default     = 20
}

data "aws_caller_identity" "me" {}

resource "aws_sns_topic" "cost_alerts" {
  name = "cost-alerts"
}

# Let AWS Budgets and Cost Anomaly Detection publish to the topic
resource "aws_sns_topic_policy" "cost_alerts" {
  arn = aws_sns_topic.cost_alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["budgets.amazonaws.com", "costalerts.amazonaws.com"] }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.cost_alerts.arn
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.me.account_id } }
    }]
  })
}

resource "aws_budgets_budget" "monthly" {
  name         = "aws-cost-optimisation-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.cost_alerts.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.cost_alerts.arn]
  }

  depends_on = [aws_sns_topic_policy.cost_alerts]
}

resource "aws_ce_anomaly_monitor" "services" {
  name              = "aws-services"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

# Alert on any anomaly with an impact of $5 or more
resource "aws_ce_anomaly_subscription" "alerts" {
  name             = "cost-anomaly-alerts"
  frequency        = "IMMEDIATE"
  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  subscriber {
    type    = "SNS"
    address = aws_sns_topic.cost_alerts.arn
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = ["5"]
    }
  }

  depends_on = [aws_sns_topic_policy.cost_alerts]
}

output "cost_alerts_topic" { value = aws_sns_topic.cost_alerts.arn }
