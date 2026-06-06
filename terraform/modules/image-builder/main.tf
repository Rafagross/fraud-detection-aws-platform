##############################################################################
# Module: image-builder
# Purpose: EC2 Image Builder pipeline for Golden AMI (AL2023, arm64).
#          Monthly schedule + on-demand.
#          See docs/architecture.md Section 9
##############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
  name_prefix = "${var.project}-${var.environment}"
}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# IAM role for build instances
resource "aws_iam_role" "image_builder" {
  name = "${local.name_prefix}-role-image-builder"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Name = "${local.name_prefix}-role-image-builder" }
}

resource "aws_iam_role_policy_attachment" "ib_ec2_instance_profile" {
  role       = aws_iam_role.image_builder.name
  policy_arn = "arn:aws:iam::aws:policy/EC2InstanceProfileForImageBuilder"
}

resource "aws_iam_role_policy_attachment" "ib_ssm_core" {
  role       = aws_iam_role.image_builder.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "ib_ssm_param_write" {
  name = "${local.name_prefix}-policy-ib-param-write"
  role = aws_iam_role.image_builder.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ssm:PutParameter", "ssm:GetParameter"]
      Resource = [
        "arn:aws:ssm:${local.region}:${local.account_id}:parameter/${var.project}/${var.environment}/golden-ami/*",
      ]
    }]
  })
}

resource "aws_iam_role_policy" "ib_s3_logs" {
  name = "${local.name_prefix}-policy-ib-s3-logs"
  role = aws_iam_role.image_builder.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:GetBucketLocation",
      ]
      Resource = [
        "arn:aws:s3:::${var.image_builder_logs_bucket}",
        "arn:aws:s3:::${var.image_builder_logs_bucket}/*",
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "image_builder" {
  name = "${local.name_prefix}-iprofile-image-builder"
  role = aws_iam_role.image_builder.name
  tags = { Name = "${local.name_prefix}-iprofile-image-builder" }
}

# Infrastructure configuration
resource "aws_imagebuilder_infrastructure_configuration" "default" {
  name                          = "${local.name_prefix}-ibinfra-default"
  description                   = "Build infrastructure for Golden AMI pipeline"
  instance_types                = ["t4g.medium"]
  instance_profile_name         = aws_iam_instance_profile.image_builder.name
  terminate_instance_on_failure = true

  logging {
    s3_logs {
      s3_bucket_name = var.image_builder_logs_bucket
      s3_key_prefix  = "image-builder-logs/"
    }
  }

  tags = { Name = "${local.name_prefix}-ibinfra-default" }
}

# Custom components
resource "aws_imagebuilder_component" "cis_baseline" {
  name     = "${local.name_prefix}-ibcomp-cis-baseline"
  platform = "Linux"
  version  = "1.0.0"
  data = yamlencode({
    name          = "CIS Baseline Hardening"
    schemaVersion = "1.0"
    phases = [
      {
        name = "build"
        steps = [
          {
            name   = "SysctlHardening"
            action = "ExecuteBash"
            inputs = {
              commands = [
                "echo 'net.ipv4.conf.all.rp_filter = 1' >> /etc/sysctl.d/99-cloudops-hardening.conf",
                "echo 'kernel.randomize_va_space = 2' >> /etc/sysctl.d/99-cloudops-hardening.conf",
                "sysctl -p /etc/sysctl.d/99-cloudops-hardening.conf",
              ]
            }
          },
          {
            name   = "AuditdEnable"
            action = "ExecuteBash"
            inputs = { commands = ["systemctl enable auditd", "systemctl start auditd"] }
          },
          {
            name   = "SSHHardening"
            action = "ExecuteBash"
            inputs = {
              commands = [
                "sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config",
                "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config",
              ]
            }
          },
        ]
      },
      {
        name = "validate"
        steps = [
          {
            name   = "ValidateAuditd"
            action = "ExecuteBash"
            inputs = { commands = ["systemctl is-active auditd || exit 1"] }
          },
          {
            name   = "ValidateSSH"
            action = "ExecuteBash"
            inputs = { commands = ["grep -q 'PermitRootLogin no' /etc/ssh/sshd_config || exit 1"] }
          },
        ]
      },
    ]
  })
  tags = { Name = "${local.name_prefix}-ibcomp-cis-baseline" }

  lifecycle { create_before_destroy = true }
}

resource "aws_imagebuilder_component" "cwagent_install" {
  name     = "${local.name_prefix}-ibcomp-cwagent-install"
  platform = "Linux"
  version  = "1.0.0"
  data = yamlencode({
    name          = "CloudWatch Agent Install"
    schemaVersion = "1.0"
    phases = [
      {
        name = "build"
        steps = [{
          name   = "InstallCWA"
          action = "ExecuteBash"
          inputs = { commands = ["dnf install -y amazon-cloudwatch-agent", "systemctl enable amazon-cloudwatch-agent"] }
        }]
      },
      {
        name = "validate"
        steps = [{
          name   = "ValidateCWA"
          action = "ExecuteBash"
          inputs = { commands = ["amazon-cloudwatch-agent-ctl -a status | grep -q 'stopped\\|running' || exit 1"] }
        }]
      },
    ]
  })
  tags = { Name = "${local.name_prefix}-ibcomp-cwagent-install" }

  lifecycle { create_before_destroy = true }
}

resource "aws_imagebuilder_component" "heartbeat_api_install" {
  name     = "${local.name_prefix}-ibcomp-heartbeat-api-install"
  platform = "Linux"
  version  = "1.0.0"
  data = yamlencode({
    name          = "heartbeat-api Install"
    schemaVersion = "1.0"
    phases = [
      {
        name = "build"
        steps = [
          {
            name   = "CreateDirs"
            action = "ExecuteBash"
            inputs = { commands = ["mkdir -p /usr/local/bin /etc/heartbeat /var/log/heartbeat"] }
          },
          {
            name   = "InstallService"
            action = "ExecuteBash"
            inputs = {
              commands = [
                "printf '[Unit]\\nDescription=heartbeat-api\\nAfter=network.target\\n[Service]\\nType=simple\\nUser=nobody\\nExecStart=/usr/local/bin/heartbeat-api\\nRestart=on-failure\\n[Install]\\nWantedBy=multi-user.target\\n' > /etc/systemd/system/heartbeat-api.service",
                "systemctl daemon-reload",
                "systemctl enable heartbeat-api.service",
              ]
            }
          },
        ]
      },
      {
        name = "validate"
        steps = [{
          name   = "ValidateIMDSv2"
          action = "ExecuteBash"
          inputs = {
            commands = [
              "HTTP=$(curl -s -o /dev/null -w '%%{http_code}' http://169.254.169.254/latest/meta-data/ --max-time 2 || echo 000)",
              "[ \"$HTTP\" = '401' ] || exit 1",
            ]
          }
        }]
      },
    ]
  })
  tags = { Name = "${local.name_prefix}-ibcomp-heartbeat-api-install" }

  lifecycle { create_before_destroy = true }
}

locals {
  # base64-encode the script so yamlencode produces a clean single-line
  # shell command — avoids heredoc quoting issues inside YAML strings.
  fraud_worker_script_b64 = base64encode(file("${path.module}/templates/fraud-worker.sh"))
}

resource "aws_imagebuilder_component" "fraud_worker_install" {
  name     = "${local.name_prefix}-ibcomp-fraud-worker-install"
  platform = "Linux"
  version  = "1.0.0"
  data = yamlencode({
    name          = "fraud-worker Install"
    schemaVersion = "1.0"
    phases = [
      {
        name = "build"
        steps = [
          {
            name   = "CreateDirs"
            action = "ExecuteBash"
            inputs = { commands = ["mkdir -p /usr/local/bin /etc/fraud-worker"] }
          },
          {
            name   = "InstallScript"
            action = "ExecuteBash"
            inputs = {
              commands = [
                "echo '${local.fraud_worker_script_b64}' | base64 -d > /usr/local/bin/fraud-worker.sh",
                "chmod 0750 /usr/local/bin/fraud-worker.sh",
                "chown root:nobody /usr/local/bin/fraud-worker.sh",
              ]
            }
          },
          {
            name   = "WriteConfig"
            action = "ExecuteBash"
            inputs = {
              commands = [
                "printf 'SSM_PREFIX=/${var.project}/${var.environment}/worker\\n' > /etc/fraud-worker/config.env",
                "chmod 0640 /etc/fraud-worker/config.env",
                "chown root:nobody /etc/fraud-worker/config.env",
              ]
            }
          },
          {
            name   = "InstallSystemdUnit"
            action = "ExecuteBash"
            inputs = {
              commands = [
                "printf '[Unit]\\nDescription=Fraud Screening Worker\\nAfter=network.target\\n\\n[Service]\\nType=simple\\nUser=nobody\\nExecStart=/usr/local/bin/fraud-worker.sh\\nRestart=on-failure\\nRestartSec=10\\nStandardOutput=journal\\nStandardError=journal\\nSyslogIdentifier=fraud-worker\\nNoNewPrivileges=yes\\nPrivateTmp=yes\\n\\n[Install]\\nWantedBy=multi-user.target\\n' > /etc/systemd/system/fraud-worker.service",
                "systemctl daemon-reload",
                "systemctl enable fraud-worker.service",
              ]
            }
          },
        ]
      },
      {
        name = "validate"
        steps = [
          {
            name   = "ValidateScript"
            action = "ExecuteBash"
            inputs = { commands = ["[ -x /usr/local/bin/fraud-worker.sh ] || exit 1"] }
          },
          {
            name   = "ValidateConfig"
            action = "ExecuteBash"
            inputs = { commands = ["grep -q 'SSM_PREFIX' /etc/fraud-worker/config.env || exit 1"] }
          },
          {
            name   = "ValidateService"
            action = "ExecuteBash"
            inputs = { commands = ["systemctl is-enabled fraud-worker.service || exit 1"] }
          },
        ]
      },
    ]
  })
  tags = { Name = "${local.name_prefix}-ibcomp-fraud-worker-install" }

  lifecycle { create_before_destroy = true }
}

resource "aws_imagebuilder_component" "cleanup" {
  name     = "${local.name_prefix}-ibcomp-cleanup"
  platform = "Linux"
  version  = "1.0.0"
  data = yamlencode({
    name          = "Cleanup"
    schemaVersion = "1.0"
    phases = [{
      name = "build"
      steps = [{
        name   = "CleanCaches"
        action = "ExecuteBash"
        inputs = { commands = ["dnf clean all", "rm -rf /tmp/* /var/tmp/*"] }
      }]
    }]
  })
  tags = { Name = "${local.name_prefix}-ibcomp-cleanup" }

  lifecycle { create_before_destroy = true }
}

# Image recipe
resource "aws_imagebuilder_image_recipe" "golden_al2023_arm64" {
  name         = "${local.name_prefix}-ibrecipe-golden-al2023-arm64"
  parent_image = data.aws_ssm_parameter.al2023_arm64.value
  version      = "1.1.0"

  block_device_mapping {
    device_name = "/dev/xvda"
    ebs {
      delete_on_termination = true
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      volume_size           = 30
      volume_type           = "gp3"
    }
  }

  component {
    component_arn = "arn:${data.aws_partition.current.partition}:imagebuilder:${local.region}:aws:component/update-linux/x.x.x"
  }
  component { component_arn = aws_imagebuilder_component.cis_baseline.arn }
  component { component_arn = aws_imagebuilder_component.cwagent_install.arn }
  component { component_arn = aws_imagebuilder_component.heartbeat_api_install.arn }
  component { component_arn = aws_imagebuilder_component.fraud_worker_install.arn }
  component { component_arn = aws_imagebuilder_component.cleanup.arn }

  tags = { Name = "${local.name_prefix}-ibrecipe-golden-al2023-arm64" }

  lifecycle { create_before_destroy = true }
}

# Distribution configuration
resource "aws_imagebuilder_distribution_configuration" "golden" {
  name = "${local.name_prefix}-ibdist-us-east-1"

  distribution {
    region = local.region
    ami_distribution_configuration {
      name = "${local.name_prefix}-ami-golden-al2023-arm64-{{ imagebuilder:buildDate }}"
      ami_tags = {
        Project     = "${var.project}-platform"
        Environment = var.environment
        ManagedBy   = "image-builder"
        GoldenAMI   = "true"
      }
      launch_permission {
        user_ids = [local.account_id]
      }
    }
    launch_template_configuration {
      launch_template_id = var.launch_template_id
      default            = true
    }
  }

  tags = { Name = "${local.name_prefix}-ibdist-us-east-1" }
}

# Pipeline
resource "aws_imagebuilder_image_pipeline" "golden_al2023_arm64" {
  name                             = "${local.name_prefix}-ibpipe-golden-al2023-arm64"
  status                           = "ENABLED"
  image_recipe_arn                 = aws_imagebuilder_image_recipe.golden_al2023_arm64.arn
  infrastructure_configuration_arn = aws_imagebuilder_infrastructure_configuration.default.arn
  distribution_configuration_arn   = aws_imagebuilder_distribution_configuration.golden.arn

  schedule {
    schedule_expression                = "cron(0 6 ? * SUN#1 *)"
    pipeline_execution_start_condition = "EXPRESSION_MATCH_ONLY"
  }

  image_tests_configuration {
    image_tests_enabled = true
    timeout_minutes     = 60
  }

  tags = { Name = "${local.name_prefix}-ibpipe-golden-al2023-arm64" }
}
