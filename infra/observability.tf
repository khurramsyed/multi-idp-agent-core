# Audit trail and authorization metrics from the tool Lambda's structured logs.

resource "aws_cloudwatch_log_metric_filter" "authz" {
  for_each = {
    ALLOW     = "AuthzAllowed"
    DENY      = "AuthzDenied"
    NOT_FOUND = "RecordNotFound"
  }
  name           = "${local.name}-${lower(replace(each.key, "_", "-"))}"
  log_group_name = aws_cloudwatch_log_group.tools.name
  pattern        = "{ $.event = \"authz_decision\" && $.decision = \"${each.key}\" }"

  metric_transformation {
    name      = each.value
    namespace = "${local.name}/Authorization"
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "identity_missing" {
  name           = "${local.name}-missing-caller-identity"
  log_group_name = aws_cloudwatch_log_group.tools.name
  pattern        = "{ $.event = \"missing_caller_identity\" }"

  metric_transformation {
    name      = "MissingCallerIdentity"
    namespace = "${local.name}/Authorization"
    value     = "1"
    unit      = "Count"
  }
}

# Any tool call without an injected identity means the interceptor path is broken.
resource "aws_cloudwatch_metric_alarm" "identity_missing" {
  alarm_name          = "${local.name}-missing-caller-identity"
  alarm_description   = "A tool was called without the caller's token. Check the gateway interceptor."
  namespace           = "${local.name}/Authorization"
  metric_name         = "MissingCallerIdentity"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

# "Which human caused the agent to read this record?" — one query for compliance.
resource "aws_cloudwatch_query_definition" "who_read_what" {
  name            = "${local.name}/who-read-what"
  log_group_names = [aws_cloudwatch_log_group.tools.name]

  query_string = <<-EOT
    fields @timestamp, username, sub, population, agency_id, role, tool, `resources.0` as resource_id, decision, gateway_request_id
    | filter event = "authz_decision"
    | sort @timestamp desc
    | limit 200
  EOT
}

resource "aws_cloudwatch_query_definition" "denials" {
  name            = "${local.name}/denied-requests"
  log_group_names = [aws_cloudwatch_log_group.tools.name, aws_cloudwatch_log_group.interceptor.name]

  query_string = <<-EOT
    fields @timestamp, event, username, population, agency_id, tool, `resources.0` as resource_id, decision, reason
    | filter (event = "authz_decision" and decision = "DENY") or event = "interceptor_denied"
    | sort @timestamp desc
    | limit 200
  EOT
}
