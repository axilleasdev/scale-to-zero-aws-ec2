##################################################################################
# REQUIRED INPUTS
##################################################################################

variable "name_prefix" {
  description = "Prefix used for all resource names. Keep it short — some AWS resources are length-limited."
  type        = string
  default     = "ondemand"

  validation {
    condition     = length(var.name_prefix) <= 12
    error_message = "name_prefix must be 12 characters or fewer."
  }
}

variable "aws_region" {
  description = "Primary AWS region for the EC2, Lambdas, and API Gateway."
  type        = string
  default     = "eu-central-1"
}

variable "public_domain" {
  description = "The user-facing hostname (e.g. \"app.example.com\"). Leave empty to use the CloudFront domain directly (no custom domain, no ACM cert needed)."
  type        = string
  default     = ""
}

variable "origin_subdomain" {
  description = "FQDN where Route53 publishes the EC2's current public IP. CloudFront uses it as the primary origin. Required only when public_domain is set."
  type        = string
  default     = ""
}

variable "origin_zone_name" {
  description = "Route53 hosted zone that holds origin_subdomain. Required only when public_domain is set."
  type        = string
  default     = ""
}

##################################################################################
# OPTIONAL TUNING
##################################################################################

variable "instance_type" {
  description = "EC2 instance type. ARM (t4g.*) is recommended for Graviton price/performance."
  type        = string
  default     = "t4g.small"
}

variable "root_volume_size_gb" {
  description = "Root EBS size in GB. Comes from the AMI; expanded later via `terraform apply` + `resize2fs`."
  type        = number
  default     = 8
}

variable "data_volume_size_gb" {
  description = "Persistent EBS data volume size in GB. Mounted at /mnt/data inside the instance."
  type        = number
  default     = 4
}

variable "app_port" {
  description = "Port your container app listens on. CloudFront and the router Lambda will hit the EC2 on this port."
  type        = number
  default     = 8080
}

variable "auto_stop_idle_window_min" {
  description = "Minutes of recent NetworkPacketsOut to average for idle detection."
  type        = number
  default     = 15
}

variable "auto_stop_threshold_pps" {
  description = "Average packets/second below which the EC2 is considered idle and stopped."
  type        = number
  default     = 3.0
}

variable "auto_stop_min_uptime_min" {
  description = "Minimum minutes the EC2 must have been running before auto-stop will consider it. Prevents stopping during boot warm-up."
  type        = number
  default     = 10
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for all Lambda log groups."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}
# Spacelift trigger test
