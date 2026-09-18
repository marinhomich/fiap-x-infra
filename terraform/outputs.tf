output "gke_cluster_name" {
  description = "Nome do Cluster GKE"
  value       = google_container_cluster.fiapx_cluster.name
}

output "gke_endpoint" {
  description = "Endpoint do Cluster GKE"
  value       = google_container_cluster.fiapx_cluster.endpoint
}

output "storage_bucket_name" {
  description = "Nome do Bucket no Cloud Storage"
  value       = google_storage_bucket.fiapx_media_bucket.name
}

output "postgres_instance_ip" {
  description = "IP da Instância Cloud SQL PostgreSQL"
  value       = google_sql_database_instance.fiapx_postgres.public_ip_address
}

output "artifact_registry_url" {
  description = "URL do repositório Docker no Artifact Registry"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.fiapx_repo.repository_id}"
}
