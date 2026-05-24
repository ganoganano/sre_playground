output "load_balancer_ip" {
  description = "Public IP address of the external HTTP load balancer."
  value       = google_compute_global_address.default.address
}

output "load_balancer_url" {
  description = "Convenience URL for the load balancer."
  value       = "http://${google_compute_global_address.default.address}"
}

output "blue_service_uri" {
  description = "Direct Cloud Run URI for the blue service."
  value       = google_cloud_run_v2_service.blue.uri
}

output "green_service_uri" {
  description = "Direct Cloud Run URI for the green service."
  value       = google_cloud_run_v2_service.green.uri
}

output "traffic_split" {
  description = "Current traffic split represented in Terraform."
  value = {
    blue  = var.blue_weight
    green = var.green_weight
  }
}
