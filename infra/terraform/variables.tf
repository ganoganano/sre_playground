variable "project_id" {
  description = "GCP project id."
  type        = string
}

variable "region" {
  description = "Primary GCP region."
  type        = string
  default     = "asia-northeast1"
}

variable "service_name" {
  description = "Base service name for playground."
  type        = string
  default     = "sre-playground"
}

variable "container_image_blue" {
  description = "Container image for the blue deployment."
  type        = string
}

variable "container_image_green" {
  description = "Container image for the green deployment."
  type        = string
}

variable "blue_weight" {
  description = "Traffic percentage routed to the blue backend."
  type        = number
  default     = 100

  validation {
    condition     = var.blue_weight >= 0 && var.blue_weight <= 100
    error_message = "blue_weight must be between 0 and 100."
  }
}

variable "green_weight" {
  description = "Traffic percentage routed to the green backend."
  type        = number
  default     = 0

  validation {
    condition     = var.green_weight >= 0 && var.green_weight <= 100
    error_message = "green_weight must be between 0 and 100."
  }
}

variable "allow_unauthenticated" {
  description = "Allow public access to the Cloud Run services."
  type        = bool
  default     = true
}

variable "otel_exporter_otlp_traces_endpoint" {
  description = "OTLP HTTP traces endpoint for the sample app."
  type        = string
  default     = ""
}

variable "otel_environment" {
  description = "OTel environment attribute for the sample app."
  type        = string
  default     = "demo"
}

variable "green_extra_latency_ms" {
  description = "Extra latency injected into green responses."
  type        = string
  default     = "0"
}

variable "app_error_rate" {
  description = "Injected error rate for the green app."
  type        = string
  default     = "0"
}
