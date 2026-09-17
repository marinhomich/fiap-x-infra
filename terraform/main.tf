terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  # State remoto: permite que o pipeline do GitHub Actions aplique o Terraform
  # de forma incremental (o bucket já existe e é o mesmo das fases anteriores).
  backend "gcs" {
    bucket = "fiap-oficina-terraform-state-2026"
    prefix = "terraform/state/fiapx"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Rede VPC Dedicada
resource "google_compute_network" "fiapx_vpc" {
  name                    = "fiapx-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "fiapx_subnet" {
  name          = "fiapx-subnet"
  ip_cidr_range = "10.0.0.0/20"
  region        = var.region
  network       = google_compute_network.fiapx_vpc.id
}

# Cluster Kubernetes Gerenciado (GKE)
resource "google_container_cluster" "fiapx_cluster" {
  name     = "fiapx-gke-cluster"
  location = var.region

  network    = google_compute_network.fiapx_vpc.name
  subnetwork = google_compute_subnetwork.fiapx_subnet.name

  remove_default_node_pool = true
  initial_node_count       = 1
}

resource "google_container_node_pool" "primary_nodes" {
  name       = "fiapx-node-pool"
  location   = var.region
  cluster    = google_container_cluster.fiapx_cluster.name
  node_count = var.node_count

  autoscaling {
    min_node_count = 2
    max_node_count = 6
  }

  node_config {
    preemptible  = true
    machine_type = var.machine_type

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

# Cloud Storage Bucket para Mídias & Zips
resource "google_storage_bucket" "fiapx_media_bucket" {
  name          = "fiapx-media-storage-${var.project_id}"
  location      = var.region
  force_destroy = true

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }
}

# Cloud SQL PostgreSQL Gerenciado
resource "google_sql_database_instance" "fiapx_postgres" {
  name             = "fiapx-postgres-instance"
  database_version = "POSTGRES_16"
  region           = var.region

  settings {
    tier = "db-f1-micro"
    ip_configuration {
      ipv4_enabled = true
    }
  }
}

resource "google_sql_database" "database" {
  name     = "fiapx_db"
  instance = google_sql_database_instance.fiapx_postgres.name
}
