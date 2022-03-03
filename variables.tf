variable "domain" {
  type = string
  default = "kirstymunro.co.uk"
}

variable "bucket_name" {
    type = string
    default = "kongbucket"
}

variable "db_password" {
  description = "RDS root user password"
  type        = string
  sensitive   = true
}

