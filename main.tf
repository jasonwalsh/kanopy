provider "kubernetes" {
  config_path    = pathexpand("~/.kube/config")
  config_context = "kind-urban-disco"
}

provider "aws" {}

locals {
  environment = replace(terraform.workspace, "default", "production")
  tags        = { Name = random_id.this.hex }
}

resource "random_id" "this" {
  byte_length = 8
  prefix      = "kanopy-"
}

resource "aws_vpc" "this" {
  cidr_block = "172.16.0.0/16"
  tags       = local.tags
}

resource "aws_internet_gateway" "this" {
  tags   = local.tags
  vpc_id = aws_vpc.this.id
}

resource "aws_route_table" "this" {
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags   = local.tags
  vpc_id = aws_vpc.this.id
}

resource "aws_route_table_association" "this" {
  route_table_id = aws_route_table.this.id
  subnet_id      = aws_subnet.this.id
}

data "aws_availability_zones" "this" {
  state = "available"
}

resource "aws_subnet" "this" {
  availability_zone       = data.aws_availability_zones.this.names[0]
  cidr_block              = "172.16.10.0/24"
  map_public_ip_on_launch = true
  tags                    = local.tags
  vpc_id                  = aws_vpc.this.id
}

data "aws_ami" "this" {
  filter {
    name   = "name"
    values = ["amzn2-ami-kernel-5.10-hvm-2.0.*"]
  }

  include_deprecated = false
  most_recent        = true
  owners             = ["amazon"]
}

resource "aws_security_group" "this" {
  egress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 0
    protocol    = "-1"
    to_port     = 0
  }

  ingress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 9100
    protocol    = "TCP"
    to_port     = 9100
  }

  name   = random_id.this.hex
  tags   = local.tags
  vpc_id = aws_vpc.this.id
}

data "aws_iam_policy" "this" {
  name = "AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role" "this" {
  assume_role_policy = jsonencode({
    Statement = [{
      Action    = ["sts:AssumeRole"]
      Effect    = "Allow"
      Principal = { Service = ["ec2.amazonaws.com"] }
    }]
    Version = "2012-10-17"
  })

  description         = "Allows EC2 instances to call AWS services on your behalf."
  managed_policy_arns = [data.aws_iam_policy.this.arn]
  name                = random_id.this.hex
  tags                = local.tags
}

resource "aws_iam_instance_profile" "this" {
  name = random_id.this.hex
  role = aws_iam_role.this.name
  tags = local.tags
}

locals {
  node_exporter = {
    version = "1.4.0"
  }

  asset_name = "node_exporter-${local.node_exporter.version}.linux-amd64.tar.gz"
}

data "cloudinit_config" "this" {
  base64_encode = true
  gzip          = true

  part {
    content = join("\n", ["#cloud-config", yamlencode({
      runcmd = [
        ["yum", "install", "-y", "https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm"],
        ["systemctl", "start", "amazon-ssm-agent"],
        ["wget", "https://github.com/prometheus/node_exporter/releases/download/v${local.node_exporter.version}/${local.asset_name}"],
        ["tar", "xvfz", local.asset_name],
        ["mv", "${replace(local.asset_name, ".tar.gz", "")}/node_exporter", "/usr/local/bin"],
        ["systemctl", "start", "node_exporter"]
      ]
      users = [
        "default",
        {
          name  = "node_exporter"
          shell = "/bin/false"
        }
      ]
      write_files = [{
        content  = <<-EOT
          [Unit]
          After=network.target

          [Service]
          User=node_exporter
          Group=node_exporter
          Type=simple
          ExecStart=/usr/local/bin/node_exporter

          [Install]
          WantedBy=multi-user.target
        EOT
        encoding = "text/plain"
        path     = "/etc/systemd/system/node_exporter.service"
      }]
    })])
    content_type = "text/cloud-config"
  }
}

resource "aws_instance" "this" {
  ami                         = data.aws_ami.this.id
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.this.name
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.this.id
  tags                        = merge(local.tags, { noreap = true })
  user_data_base64            = data.cloudinit_config.this.rendered
  user_data_replace_on_change = true
  vpc_security_group_ids      = [aws_security_group.this.id]
}

resource "aws_eip" "this" {
  instance = aws_instance.this.id
  tags     = local.tags
  vpc      = true

  depends_on = [aws_internet_gateway.this]
}

resource "kubernetes_service" "this" {
  metadata {
    labels = {
      "app.kubernetes.io/name" = random_id.this.hex
      release                  = "kube-prometheus-stack-1667743513"
    }
    name      = kubernetes_endpoints.this.metadata[0].name
    namespace = var.namespace
  }

  spec {
    port {
      name        = "http-metrics"
      port        = 9100
      target_port = 9100
    }
  }
}

resource "kubernetes_endpoints" "this" {
  metadata {
    labels = {
      "app.kubernetes.io/name" = random_id.this.hex
    }
    name      = random_id.this.hex
    namespace = var.namespace
  }

  subset {
    address {
      ip = aws_eip.this.public_ip
    }

    port {
      name = "http-metrics"
      port = 9100
    }
  }
}

resource "kubernetes_manifest" "this" {
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      labels = {
        "app.kubernetes.io/name" = random_id.this.hex
        release                  = "kube-prometheus-stack-1667743513"
      }
      name      = random_id.this.hex
      namespace = var.namespace
    }
    spec = {
      endpoints = [{
        interval = "30s"
        port     = "http-metrics"
      }]
      namespaceSelector = {
        matchNames = [var.namespace]
      }
      selector = {
        matchLabels = {
          "app.kubernetes.io/name" = random_id.this.hex
        }
      }
    }
  }
}
