# ------------------------------------------------------------------------------
# CREATE A ROUTE53 ZONE WITH SUBDOMAINS AND CNAMES
# This kongdemo creates a zone and records for the main domain and a subdomain.
#   - (www.)acme.com
#   - (www.)dev.acme.com
#
# The www. subdomains are implement through CNAMES and point on the A records.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Configure the AWS Provider
# ------------------------------------------------------------------------------

provider "aws" {
  region = local.region
}

locals {
  region = "eu-west-1"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "kong-kongdemo-km"
  cidr = "10.0.0.0/16"

  azs             = ["${local.region}a", "${local.region}b", "${local.region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_ipv6 = true

  create_database_subnet_group           = true
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = true

  enable_dns_support   = true
  enable_dns_hostnames = true

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    default = "Tier"
  }

  private_subnet_tags = {
    default = "Tier"
  }

 tags = {
     Owner = "devops@domain.name"
     Team = "DevOps"
  }

  vpc_tags = {
    Name = "vpc-kong-km"
  }
  
}


resource "aws_security_group" "rds" {
  name   = "kongdemo_rds"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "kongdemo_rds"
  }
}


resource "aws_acm_certificate" "kongdemo" {
  domain_name       = "${var.domain}"
  validation_method = "DNS"

  tags = {
    Name = "kongdemo"
  }

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_route53_zone" "kongdemo" {
  name         = "${var.domain}"
  private_zone = false
}

resource "aws_route53_record" "kongdemo" {
  for_each = {
    for dvo in aws_acm_certificate.kongdemo.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.kongdemo.zone_id
}

resource "aws_acm_certificate_validation" "kongdemo" {
  certificate_arn         = aws_acm_certificate.kongdemo.arn
  validation_record_fqdns = [for record in aws_route53_record.kongdemo : record.fqdn]
}

resource "aws_db_subnet_group" "kongdemo" {
  name       = "kongdemo"
  subnet_ids = module.vpc.public_subnets

  tags = {
    Name = "kongdemo"
  }
}

resource "aws_db_instance" "kongdemo" {
  identifier             = "kongdemo"
  instance_class         = "db.t3.micro"
  allocated_storage      = 5
  engine                 = "postgres"
  engine_version         = "13.5"
  username               = "edu"
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.kongdemo.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.kongdemo.name
  publicly_accessible    = false
  skip_final_snapshot    = true
}

resource "aws_db_parameter_group" "kongdemo" {
  name   = "kongdemo"
  family = "postgres13"

  parameter {
    name  = "log_connections"
    value = "1"
  }
}

/* --------------- keys ------------------*/

resource "tls_private_key" "pk" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "kp" {
  key_name   = "kongkey2"
  public_key = tls_private_key.pk.public_key_openssh

  provisioner "local-exec" { 
    command = "echo '${tls_private_key.pk.private_key_pem}' > ./kongkey2.pem"
  }
}


/* --------- kong ----------*/

module "kong" {
  source = "github.com/kong/kong-terraform-aws?ref=v3.3"

  vpc                   = "vpc-kong-km"
  environment           = "default"
  ec2_key_name          = "kongkey2"
  ssl_cert_external     = "${var.domain}"
  ssl_cert_internal     = "${var.domain}"
  ssl_cert_admin        = "${var.domain}"
  ssl_cert_manager      = "${var.domain}"
  ssl_cert_portal       = "${var.domain}"
  db_subnets            = aws_db_subnet_group.kongdemo.name

  tags = {
     Owner = "devops@domain.name"
     Team = "DevOps"
  }
  depends_on = [
    aws_acm_certificate_validation.kongdemo,
    module.vpc.private_subnets,
    module.vpc.public_subnets,
  ] 
} 