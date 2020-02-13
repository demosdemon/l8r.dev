variable "project-name" {
  type    = string
  default = "l8r-dev"
}

variable "environment" {
  type    = string
  default = "development"
}

variable "vpc-cidr" {
  type    = string
  default = "172.21.0.0/16"
}
