variable "project_id" {
  description = "ID do Projeto na Google Cloud Platform"
  type        = string
  default     = "fiap-soat-hackathon-2026"
}

variable "region" {
  description = "Região GCP"
  type        = string
  default     = "us-central1"
}

variable "machine_type" {
  description = "Tipo de máquina para os nodes GKE"
  type        = string
  default     = "e2-standard-2"
}

variable "node_count" {
  description = "Quantidade inicial de nodes no cluster"
  type        = number
  default     = 2
}
