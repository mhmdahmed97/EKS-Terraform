terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${project_name}-vpc-${var.environment}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${project_name}-igw-${var.environment}"
  }
}

resource "aws_eip" "nat_eip" {
  tags = {
    Name = "${project_name}-nat-eip-${var.environment}"
  }
}


resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${project_name}-nat-gateway-${var.environment}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${project_name}-public-rt-${var.environment}"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "${project_name}-private-rt-${var.environment}"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(var.private_subnet_cidrs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${project_name}-public-subnet-${count.index + 1}-${var.environment}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb" = 1
  }
}

resource "aws_subnet" "private" {
  count              = length(var.private_subnet_cidrs)
  vpc_id             = aws_vpc.main.id
  cidr_block         = var.private_subnet_cidrs[count.index]
  availability_zone  = var.availability_zones[count.index]

  tags = {
    Name = "${project_name}-private-subnet-${count.index + 1}-${var.environment}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_iam_role" "eks_cluster_role" {
  name = "${project_name}-eks-cluster-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "eks.amazonaws.com" }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

resource "aws_iam_role_policy_attachment" "eks_service_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster_role.arn

  vpc_config {
    subnet_ids = concat(
      aws_subnet.public[*].id,
      aws_subnet.private[*].id
    )
  }

  tags = {
    Name = var.cluster_name
  }
}

resource "aws_iam_role" "eks_node_role" {
  name = "${project_name}-eks-node-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
      }
    ]
  })
}

resource "aws_iam_policy" "eks_worker_node_ecr_policy" {
  name        = "eks-worker-node-ecr-policy"
  description = "Policy to allow EKS worker nodes to pull images from ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:ListImages"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_policy_attachment" {
  policy_arn = aws_iam_policy.eks_worker_node_ecr_policy.arn
  role       = aws_iam_role.eks_node_role.name
}


resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "cloudwatch_logs_policy" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_ssm_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.eks_node_role.name
}


resource "aws_launch_template" "eks_api_node_launch_template" {
  name_prefix   = "${project_name}-api-node-launch-template-${var.environment}"
  instance_type = var.api_node_instance_type

  monitoring {
    enabled = true
  }

  user_data = base64encode(<<-EOT
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="==BOUNDARY=="

    --==BOUNDARY==
    Content-Type: text/x-shellscript; charset="us-ascii"

    #!/bin/bash
    set -o xtrace
    /etc/eks/nodeadm --config /etc/eks/nodeadm.yaml
    --==BOUNDARY==--
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${project_name}-api-node-${var.environment}"
    }
  }
}


resource "aws_eks_node_group" "api_nodes" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${project_name}-api-node-group"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = aws_subnet.private[*].id

  scaling_config {
    desired_size = var.api_desired_capacity
    max_size     = var.api_desired_capacity + 2
    min_size     = 1
  }

  launch_template {
    id      = aws_launch_template.eks_api_node_launch_template.id
    version = "$Latest"
  }

  tags = {
    Name = "${project_name}-api-node-group-${var.environment}"
  }
}

resource "aws_launch_template" "eks_compute_node_launch_template" {
  name_prefix   = "${project_name}-compute-node-launch-template-${var.environment}"
  instance_type = var.compute_node_instance_type
  # image_id = "ami-029ad906e33947128"

  monitoring {
    enabled = true
  }

  user_data = base64encode(<<-EOT
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="==BOUNDARY=="

    --==BOUNDARY==
    Content-Type: text/x-shellscript; charset="us-ascii"

    #!/bin/bash
    set -o xtrace
    /etc/eks/nodeadm --config /etc/eks/nodeadm.yaml
    --==BOUNDARY==--
  EOT
  )
  # user_data = base64encode(<<-EOT
  #   MIME-Version: 1.0
  #   Content-Type: multipart/mixed; boundary="==BOUNDARY=="

  #   --==BOUNDARY==
  #   Content-Type: text/x-shellscript; charset="us-ascii"

  #   #!/bin/bash
  #   set -o xtrace
  #   yum update -y
  #   yum install -y nvidia-driver-latest-dkms cuda
  #   /etc/eks/bootstrap.sh ${var.cluster_name} --kubelet-extra-args '--node-labels=purpose=compute --node-taints=purpose=compute:NoSchedule'
  #   --==BOUNDARY==--
  #   EOT
  # )


  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${project_name}-compute-node-${var.environment}"
    }
  }
}

resource "aws_eks_node_group" "compute_nodes" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${project_name}-compute-node-group"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = aws_subnet.private[*].id

  scaling_config {
    desired_size = var.compute_desired_capacity
    max_size     = var.compute_desired_capacity + 2
    min_size     = 1
  }

  taint {
  key    = "purpose"
  value  = "compute"
  effect = "NO_SCHEDULE"
}


  launch_template {
    id      = aws_launch_template.eks_compute_node_launch_template.id
    version = "$Latest"
  }

  tags = {
    Name = "${project_name}-compute-node-group-${var.environment}"
  }
}

data "aws_autoscaling_groups" "api-groups" {
  filter {
    name   = "tag:eks:nodegroup-name"
    values = ["${project_name}-api-node-group"]
  }

  filter {
    name   = "tag:eks:cluster-name"
    values = ["${project_name}-prod-cluster"]
  }
}

data "aws_autoscaling_groups" "compute-groups" {
  filter {
    name   = "tag:eks:nodegroup-name"
    values = ["${project_name}-compute-node-group"]
  }

  filter {
    name   = "tag:eks:cluster-name"
    values = ["${project_name}-prod-cluster"]
  }
}

############################################################################----DYNAMIC-SCALING-POLICIES----#####################################################################
resource "aws_autoscaling_policy" "api_node_scale_out" {
  name                   = "api-node-scale-out-policy-${var.environment}"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 60
  autoscaling_group_name = data.aws_autoscaling_groups.api-groups.names[0]

  depends_on = [aws_eks_node_group.api_nodes]
}

resource "aws_cloudwatch_metric_alarm" "api_node_high_cpu" {
  alarm_name                = "api-node-high-cpu-alarm-${var.environment}"
  comparison_operator       = "GreaterThanThreshold"
  evaluation_periods        = 1
  metric_name               = "CPUUtilization"
  namespace                 = "AWS/EC2"
  period                    = 60
  statistic                 = "Average"
  threshold                 = 70
  dimensions = {
    AutoScalingGroupName = data.aws_autoscaling_groups.api-groups.names[0]
  }

  alarm_actions = [aws_autoscaling_policy.api_node_scale_out.arn]
  depends_on    = [aws_eks_node_group.api_nodes]
}

resource "aws_autoscaling_policy" "api_node_scale_in" {
  name                   = "api-node-scale-in-policy-${var.environment}"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 150
  autoscaling_group_name = data.aws_autoscaling_groups.api-groups.names[0]

  depends_on = [aws_eks_node_group.api_nodes]
}

resource "aws_cloudwatch_metric_alarm" "api_node_low_cpu" {
  alarm_name                = "api-node-low-cpu-alarm-${var.environment}"
  comparison_operator       = "LessThanThreshold"
  evaluation_periods        = 1
  metric_name               = "CPUUtilization"
  namespace                 = "AWS/EC2"
  period                    = 60
  statistic                 = "Average"
  threshold                 = 25
  dimensions = {
    AutoScalingGroupName = data.aws_autoscaling_groups.api-groups.names[0]
  }

  alarm_actions = [aws_autoscaling_policy.api_node_scale_in.arn]
  depends_on    = [aws_eks_node_group.api_nodes]
}

resource "aws_autoscaling_policy" "compute_node_scale_out" {
  name                   = "compute-node-scale-out-policy-${var.environment}"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 60
  autoscaling_group_name = data.aws_autoscaling_groups.compute-groups.names[0]

  depends_on = [aws_eks_node_group.compute_nodes]
}

resource "aws_cloudwatch_metric_alarm" "compute_node_high_cpu" {
  alarm_name                = "compute-node-high-cpu-alarm-${var.environment}"
  comparison_operator       = "GreaterThanThreshold"
  evaluation_periods        = 1
  metric_name               = "CPUUtilization"
  namespace                 = "AWS/EC2"
  period                    = 60
  statistic                 = "Average"
  threshold                 = 70
  dimensions = {
    AutoScalingGroupName = data.aws_autoscaling_groups.compute-groups.names[0]
  }

  alarm_actions = [aws_autoscaling_policy.compute_node_scale_out.arn]
  depends_on    = [aws_eks_node_group.compute_nodes]
}

resource "aws_autoscaling_policy" "compute_node_scale_in" {
  name                   = "compute-node-scale-in-policy-${var.environment}"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 150
  autoscaling_group_name = data.aws_autoscaling_groups.compute-groups.names[0]

  depends_on = [aws_eks_node_group.compute_nodes]
}

resource "aws_cloudwatch_metric_alarm" "compute_node_low_cpu" {
  alarm_name                = "compute-node-low-cpu-${var.environment}"
  comparison_operator       = "LessThanThreshold"
  evaluation_periods        = 1
  metric_name               = "CPUUtilization"
  namespace                 = "AWS/EC2"
  period                    = 60
  statistic                 = "Average"
  threshold                 = 25
  dimensions = {
    AutoScalingGroupName = data.aws_autoscaling_groups.compute-groups.names[0]
  }

  alarm_actions = [aws_autoscaling_policy.compute_node_scale_in.arn]
  depends_on    = [aws_eks_node_group.compute_nodes]
}

#################################################################################################################################################

output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Endpoint for the EKS cluster"
  value       = aws_eks_cluster.main.endpoint
}

output "api_node_group_name" {
  description = "Name of the API EKS node group"
  value       = aws_eks_node_group.api_nodes.node_group_name_prefix
}

output "compute_node_group_name" {
  description = "Name of the Compute EKS node group"
  value       = aws_eks_node_group.compute_nodes.node_group_name_prefix
}
