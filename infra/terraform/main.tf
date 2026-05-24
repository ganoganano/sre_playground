locals {
  blue_service_name  = "${var.service_name}-blue"
  green_service_name = "${var.service_name}-green"
}

resource "google_cloud_run_v2_service" "blue" {
  name     = local.blue_service_name
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    containers {
      image = var.container_image_blue

      env {
        name  = "APP_COLOR"
        value = "blue"
      }

      env {
        name  = "APP_VERSION"
        value = "blue"
      }
    }
  }
}

resource "google_cloud_run_v2_service" "green" {
  name     = local.green_service_name
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    containers {
      image = var.container_image_green

      env {
        name  = "APP_COLOR"
        value = "green"
      }

      env {
        name  = "APP_VERSION"
        value = "green"
      }
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "blue_invoker" {
  count    = var.allow_unauthenticated ? 1 : 0
  location = var.region
  name     = google_cloud_run_v2_service.blue.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service_iam_member" "green_invoker" {
  count    = var.allow_unauthenticated ? 1 : 0
  location = var.region
  name     = google_cloud_run_v2_service.green.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_compute_region_network_endpoint_group" "blue" {
  name                  = "${var.service_name}-blue-neg"
  network_endpoint_type = "SERVERLESS"
  region                = var.region

  cloud_run {
    service = google_cloud_run_v2_service.blue.name
  }
}

resource "google_compute_region_network_endpoint_group" "green" {
  name                  = "${var.service_name}-green-neg"
  network_endpoint_type = "SERVERLESS"
  region                = var.region

  cloud_run {
    service = google_cloud_run_v2_service.green.name
  }
}

resource "google_compute_backend_service" "default" {
  name                  = "${var.service_name}-blue-backend"
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.blue.id
  }
}

resource "google_compute_backend_service" "green" {
  name                  = "${var.service_name}-green-backend"
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group = google_compute_region_network_endpoint_group.green.id
  }
}

resource "google_compute_url_map" "default" {
  name = "${var.service_name}-url-map"

  default_route_action {
    weighted_backend_services {
      backend_service = google_compute_backend_service.default.id
      weight          = var.blue_weight
    }

    weighted_backend_services {
      backend_service = google_compute_backend_service.green.id
      weight          = var.green_weight
    }
  }
}

resource "google_compute_target_http_proxy" "default" {
  name    = "${var.service_name}-http-proxy"
  url_map = google_compute_url_map.default.id
}

resource "google_compute_global_address" "default" {
  name = "${var.service_name}-ip"
}

resource "google_compute_global_forwarding_rule" "default" {
  name                  = "${var.service_name}-forwarding-rule"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.default.id
  port_range            = "80"
  target                = google_compute_target_http_proxy.default.id
}
