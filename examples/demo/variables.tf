variable "ibmcloud_api_key" {
  type        = string
  description = "The IBM Cloud API key this account authenticates to"
  sensitive   = true
}

variable "region" {
  type        = string
  description = "Region where resources will be created"
  default     = "us-south"
}

variable "instance_id" {
  type        = string
  description = "SM Instance ID"
}
