terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Define tu región. us-east-1 (Norte de Virginia) 
provider "aws" {
  region = "us-east-1"
}

# -----------------------------------------------------------
# 1. Repositorio de Contenedores (ECR)
# -----------------------------------------------------------

resource "aws_ecr_repository" "api_repo" {
  name                 = "cultural-api-repo"
  image_tag_mutability = "MUTABLE"

  # force_delete = true nos permite destruir el entorno fácilmente para no generar cobros
  force_delete         = true
}

# -----------------------------------------------------------
# 2. Grupo de Seguridad (Firewall)
# -----------------------------------------------------------

resource "aws_security_group" "web_sg" {
  name        = "cultural_api_sg"
  description = "Permitir trafico HTTP/HTTPS"

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "API Cultural"
    from_port   = 8010
    to_port     = 8010
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Permitir todo el trafico de salida"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -----------------------------------------------------------
# 3. Rol de IAM para la EC2 (AWS Systems Manager + ECR)
# -----------------------------------------------------------

resource "aws_iam_role" "ec2_role" {
  name = "cultural_api_ec2_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# Permite administrar la máquina remota desde AWS SSM (Sin SSH)
resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Permite que la EC2 descargue imágenes de tu repositorio ECR
resource "aws_iam_role_policy_attachment" "ecr_policy" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "cultural_api_ec2_profile"
  role = aws_iam_role.ec2_role.name
}

# -----------------------------------------------------------
# 4. Encontrar la AMI de Ubuntu más reciente
# -----------------------------------------------------------

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # ID Oficial de Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# -----------------------------------------------------------
# 5. La Instancia EC2 (Con Bootstrapping)
# -----------------------------------------------------------

resource "aws_instance" "app_server" {
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = "t3.micro"
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  # SCRIPT DE INICIALIZACIÓN AUTOMÁTICA
  user_data = <<-EOF
  #!/bin/bash
  # 1. Configurar 2GB de Memoria Swap para proteger a PostGIS de OOM Kills
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab

  # 2. Instalar Docker y Docker Compose
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # 3. Permisos de Docker para el usuario ubuntu
  usermod -aG docker ubuntu

  # 4. Instalar AWS CLI (Necesario para el ECR Login)
  snap install aws-cli --classic

  # 5. Habilitar agente SSM
  systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
  systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service
  EOF

  tags = {
    Name = "MapaCultural-Server"
  }
}