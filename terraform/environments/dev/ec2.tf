# Find the latest Ubuntu 24.04 LTS AMI from Canonical.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

# Create a dedicated security group for our lab EC2 host.
resource "aws_security_group" "lab_host" {
  name        = "platform-devsecops-lab-host-sg"
  description = "SSH administration and HTTP access for the DevSecOps lab host"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH access from my current public IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["73.30.71.184/32"]
  }

  ingress {
    description = "Public HTTP access"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow outbound HTTP for package downloads"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow outbound HTTPS for package downloads and image pulls"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "platform-devsecops-lab-host-sg"
    Environment = "dev"
    Project     = "aws-platform-devsecops-lab"
    ManagedBy   = "Terraform"
  }
}

# Launch one EC2 instance in the existing public subnet.
resource "aws_instance" "lab_host" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.lab_host.id]
  key_name                    = "platform-lab-key"
  associate_public_ip_address = true

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = {
    Name        = "platform-devsecops-lab-host"
    Environment = "dev"
    Project     = "aws-platform-devsecops-lab"
    ManagedBy   = "Terraform"
  }
}

# Display connection information after deployment.
output "lab_host_instance_id" {
  description = "ID of the DevSecOps lab EC2 instance"
  value       = aws_instance.lab_host.id
}

output "lab_host_public_ip" {
  description = "Public IP address of the DevSecOps lab EC2 instance"
  value       = aws_instance.lab_host.public_ip
}

output "lab_host_public_dns" {
  description = "Public DNS name of the DevSecOps lab EC2 instance"
  value       = aws_instance.lab_host.public_dns
}

output "lab_host_security_group_id" {
  description = "Security group ID of the DevSecOps lab host"
  value       = aws_security_group.lab_host.id
}
