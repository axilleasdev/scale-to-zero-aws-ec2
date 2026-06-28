##################################################################################
# EC2 + EBS + Security Group + SSM IAM
#
# The instance gets a fresh public IP every start (we don't pay for an
# Elastic IP). The data volume is separate, persistent, and re-attached
# automatically by the user-data script.
##################################################################################

##################################################################################
# IAM — SSM Session Manager
##################################################################################

resource "aws_iam_role" "ssm" {
  name = "${var.name_prefix}-ec2-ssm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-ec2-ssm" })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "${var.name_prefix}-ec2-ssm"
  role = aws_iam_role.ssm.name

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-ec2-ssm" })
}

##################################################################################
# Security Group
#
# Inbound: only the app port. SSH is intentionally NOT open — use SSM
# Session Manager (or SSH-over-SSM with an authorized public key
# pre-baked into your AMI / written by user-data).
##################################################################################

resource "aws_security_group" "ec2" {
  name        = "${var.name_prefix}-ec2"
  description = "Inbound app port; outbound all. No SSH (use SSM)."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description      = "App port"
    from_port        = var.app_port
    to_port          = var.app_port
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    description      = "All outbound"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-ec2" })
}

##################################################################################
# Persistent EBS data volume
##################################################################################

resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.default_a.availability_zone
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true

  tags = merge(local.common_tags, {
    Name    = "${var.name_prefix}-data"
    Purpose = "App data persistence (DB + uploads)"
  })

  lifecycle {
    # Avoid losing the disk if you accidentally `terraform destroy` the
    # whole stack. Set prevent_destroy = true if you have important data.
    prevent_destroy = false
  }
}

##################################################################################
# EC2 instance
##################################################################################

resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu_arm.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.default_a.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm.name

  # Root volume is ephemeral — destroyed on terminate. The data lives on
  # aws_ebs_volume.data, attached below.
  root_block_device {
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true

    tags = merge(local.common_tags, { Name = "${var.name_prefix}-root" })
  }

  # cloud-init: install Docker + Compose plugin, mount the data volume
  # at /mnt/data preserving any existing filesystem.
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    apt-get update -y
    apt-get install -y docker.io docker-compose-v2 git

    systemctl enable --now docker
    usermod -aG docker ubuntu

    DATA_DEV="/dev/nvme1n1"
    for i in {1..60}; do
      if [ -b "$DATA_DEV" ]; then break; fi
      sleep 2
    done

    if ! blkid "$DATA_DEV" >/dev/null 2>&1; then
      mkfs.ext4 -L ${var.name_prefix}-data "$DATA_DEV"
    fi

    mkdir -p /mnt/data
    if ! grep -q "/mnt/data" /etc/fstab; then
      echo "LABEL=${var.name_prefix}-data /mnt/data ext4 defaults,nofail 0 2" >> /etc/fstab
    fi
    mount -a

    chown -R ubuntu:ubuntu /mnt/data

    APP_DIR="/home/ubuntu/app"
    mkdir -p "$APP_DIR"

    %{if var.deploy_mode == "demo"}
    # Deploy the demo app (cats-vs-dogs)
    if [ ! -f "$APP_DIR/docker-compose.yml" ]; then
      git clone https://github.com/axilleasdev/scale-to-zero-aws-ec2.git /tmp/repo
      cp -r /tmp/repo/examples/cats-vs-dogs/* "$APP_DIR/"
      rm -rf /tmp/repo
    fi
    chown -R ubuntu:ubuntu "$APP_DIR"
    cd "$APP_DIR" && docker compose up -d
    %{endif}

    %{if var.deploy_mode == "custom"}
    # Deploy custom docker-compose
    cat > "$APP_DIR/docker-compose.yml" << 'COMPOSE'
    ${var.docker_compose_content}
    COMPOSE
    chown -R ubuntu:ubuntu "$APP_DIR"
    cd "$APP_DIR" && docker compose up -d
    %{endif}

    %{if var.extra_boot_script != ""}
    # Extra boot script
    ${var.extra_boot_script}
    %{endif}
  EOF

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-app"
    Role = "web"
  })

  lifecycle {
    ignore_changes = [
      ami, # don't recreate if Canonical publishes a new AMI revision
    ]
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf" # Linux Nitro: maps to /dev/nvme1n1
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.app.id
}
