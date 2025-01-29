variable "aws_region" {
  description = "AWS region to deploy the infrastructure"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "availability_zones" {
  description = "List of availability zones to use"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "List of CIDRs for public subnets"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "List of CIDRs for private subnets"
  type        = list(string)
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "api_node_instance_type" {
  description = "Instance type for the API EKS worker nodes"
  type        = string
}

variable "api_desired_capacity" {
  description = "Desired number of API worker nodes"
  type        = number
}

variable "compute_node_instance_type" {
  description = "Instance type for the Compute EKS worker nodes"
  type        = string
}

variable "compute_desired_capacity" {
  description = "Desired number of Compute worker nodes"
  type        = number
}

variable "environment" {
  description = "Environment name (e.g., dev, prod)"
  type        = string
}

variable "project_name" {
    description = "Name of the application or project that will be appended to the start of all resources"
    type        = string
}