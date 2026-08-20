variable "region" {
  description = "AWS region to deploy VPC"
  type        = string
  default     = "ap-south-1"
}

variable "profile" {
  description = "AWS CLI profile (leave empty for Cloud Shell or IAM role-based auth)"
  type        = string
  default     = null
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.95.0.0/16"
}

variable "azs" {
  description = "Availability zones to use"
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}

