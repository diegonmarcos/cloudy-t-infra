# GCP Infrastructure — data-driven from terraform.json
# All values live in terraform.json; this file is a pure template.

locals {
  config = jsondecode(file("${path.module}/terraform.json"))
  # Index instances by name for resource addressing
  instances_with_static_ip = { for i in local.config.instances : i.name => i if i.static_ip_name != null }
  instances_with_gpu       = { for i in local.config.instances : i.name => i if i.gpu != null }
  # Cloud Run (serverless containers): terraform.json cloud_run_services is the fleet registry. Only entries with
  # managed = true become resources; the rest are declarations (state declared / live-unmanaged) read by the UI and
  # the migration plan. A live-unmanaged service must be imported before managed flips to true.
  cloud_run          = { for s in try(local.config.cloud_run_services, []) : s.name => s if try(s.managed, false) }
  cloud_run_buckets  = { for v in flatten([for s in values(local.cloud_run) : try(s.volumes, [])]) : v.bucket => v if try(v.create_bucket, true) }
  cloud_run_registry = try(local.config.cloud_run_registry, null)
}

# =============================================================================
# Provider
# =============================================================================

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = local.config.provider.project_id
  region  = local.config.provider.region
  zone    = local.config.provider.zone
}

provider "google-beta" {
  project = local.config.provider.project_id
  region  = local.config.provider.region
  zone    = local.config.provider.zone
}

variable "ssh_public_key" {
  description = "SSH public key for diego user"
  type        = string
  # Set via: TF_VAR_ssh_public_key=$(cat ~/git/cloud-vault/A0_keys/ssh/google_compute_engine.pub)
  # Or via build.sh which reads from vault automatically
}

variable "gpu_embed_bearer_token" {
  description = "Bearer token the GPU-embed VM's Caddy proxy requires on /v1/embeddings (see startup-gpu-embed.sh). Only reaches instances with a `gpu` block in terraform.json. Set via ship-terraform.yml TF_VAR_gpu_embed_bearer_token <- secrets.GPU_EMBED_BEARER_TOKEN; empty default keeps non-GPU applies working with no secret configured."
  type        = string
  sensitive   = true
  default     = ""
}

# =============================================================================
# VPC Network
# =============================================================================

resource "google_compute_network" "main" {
  name                    = local.config.network.name
  description             = local.config.network.description
  auto_create_subnetworks = local.config.network.auto_create_subnetworks

  lifecycle {
    prevent_destroy = true
  }
}

# =============================================================================
# Firewall Rules — all from terraform.json
# NOTE: default-allow-icmp, default-allow-internal, default-allow-rdp,
#       default-allow-ssh are GCP auto-created defaults — NOT managed here.
# =============================================================================

resource "google_compute_firewall" "rules" {
  for_each = { for r in local.config.firewall_rules : r.name => r }

  name    = each.value.name
  network = google_compute_network.main.name

  allow {
    protocol = each.value.protocol
    ports    = each.value.ports
  }

  source_ranges = [each.value.source]
  target_tags   = length(each.value.tags) > 0 ? each.value.tags : null
  description   = each.value.description
}

# =============================================================================
# Static IPs
# =============================================================================

resource "google_compute_address" "ips" {
  for_each = { for ip in local.config.static_ips : ip.name => ip }

  name   = each.value.name
  region = each.value.region
}

# =============================================================================
# Compute Instances — all from terraform.json
# =============================================================================

resource "google_compute_instance" "vms" {
  for_each = { for i in local.config.instances : i.name => i }

  name         = each.value.name
  machine_type = each.value.machine_type
  # Per-instance zone override (terraform.json instances[*].zone), falling back
  # to the provider default. Needed for GPU instances: GPU capacity is a per-ZONE
  # stockout ("does not have enough resources available", us-central1-a,
  # 2026-09-03 apply) while the NVIDIA_*_GPUS quotas are REGIONAL (T4 was out in every us-central1 zone), so moving the
  # GPU VM to a sibling zone is the fix and the rest of the fleet stays put.
  zone         = try(each.value.zone, local.config.provider.zone)
  tags         = each.value.tags

  boot_disk {
    initialize_params {
      image = each.value.image
      size  = each.value.disk_size_gb
      type  = each.value.disk_type
    }
  }

  dynamic "guest_accelerator" {
    for_each = each.value.gpu != null ? [each.value.gpu] : []
    content {
      type  = guest_accelerator.value.type
      count = guest_accelerator.value.count
    }
  }

  network_interface {
    network = google_compute_network.main.name

    access_config {
      nat_ip = each.value.static_ip_name != null ? google_compute_address.ips[each.value.static_ip_name].address : null
    }
  }

  # GPU instances (declared via terraform.json instances[*].gpu) run a
  # dedicated startup script — ollama + Caddy bearer-auth proxy, no HM/mesh —
  # instead of bootstrap.sh's home-manager-fleet prep. See startup-gpu-embed.sh
  # header. The bearer token is metadata-only on GPU instances so a non-GPU
  # apply with the var unset never writes a stray key onto e.g. gcp-proxy.
  metadata = merge(
    {
      ssh-keys       = "diego:${var.ssh_public_key}"
      startup-script = each.value.gpu != null ? file("${path.module}/startup-gpu-embed.sh") : file("${path.module}/bootstrap.sh")
    },
    each.value.gpu != null ? { embed-bearer-token = var.gpu_embed_bearer_token } : {}
  )

  scheduling {
    preemptible                 = each.value.preemptible
    automatic_restart           = each.value.automatic_restart
    on_host_maintenance         = each.value.on_host_maintenance
    instance_termination_action = each.value.preemptible ? "STOP" : null
  }

  service_account {
    email  = local.config.service_account.email
    scopes = each.value.scopes
  }

  lifecycle {
    # Data-driven from terraform.json[instances[*].ignore_changes].
    # Static-list constraint of Terraform: include all candidates, conditionally
    # treated as no-op if not in JSON list.
    ignore_changes = [boot_disk]
  }
}

# =============================================================================
# Cloud Run services (terraform.json cloud_run_services, managed = true only)
# =============================================================================

# Remote Artifact Registry repo proxying ghcr.io, so Cloud Run pulls the fleet's GHCR images (amd64 manifests).
resource "google_artifact_registry_repository" "ghcr_remote" {
  count         = local.cloud_run_registry != null && length(local.cloud_run) > 0 ? 1 : 0
  location      = local.cloud_run_registry.region
  repository_id = local.cloud_run_registry.repository_id
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  description   = local.cloud_run_registry.description
  remote_repository_config {
    docker_repository {
      custom_repository {
        uri = local.cloud_run_registry.upstream
      }
    }
  }
}

resource "google_storage_bucket" "cloud_run_volumes" {
  for_each                    = local.cloud_run_buckets
  name                        = each.key
  location                    = upper(local.config.provider.region)
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_cloud_run_v2_service" "svc" {
  for_each = local.cloud_run
  name     = each.key
  location = each.value.region
  ingress  = try(each.value.ingress, "INGRESS_TRAFFIC_ALL")

  template {
    execution_environment            = try(each.value.execution_environment, "EXECUTION_ENVIRONMENT_GEN2")
    session_affinity                 = try(each.value.session_affinity, false)
    timeout                          = "${try(each.value.timeout_s, 300)}s"
    max_instance_request_concurrency = try(each.value.concurrency, 80)
    service_account                  = try(each.value.service_account, null)

    scaling {
      min_instance_count = try(each.value.min_instances, 0)
      max_instance_count = try(each.value.max_instances, 1)
    }

    containers {
      image = each.value.image
      ports {
        container_port = each.value.port
      }
      resources {
        limits            = { cpu = each.value.cpu, memory = each.value.memory }
        cpu_idle          = try(each.value.cpu_throttling, true)
        startup_cpu_boost = try(each.value.startup_cpu_boost, false)
      }
      dynamic "env" {
        for_each = try(each.value.env, {})
        content {
          name  = env.key
          value = env.value
        }
      }
      # Secrets by Secret Manager NAME only; values never live in this repo.
      dynamic "env" {
        for_each = try(each.value.secret_env, {})
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }
      dynamic "volume_mounts" {
        for_each = try(each.value.volumes, [])
        content {
          name       = volume_mounts.value.name
          mount_path = volume_mounts.value.mount_path
        }
      }
    }

    dynamic "volumes" {
      for_each = try(each.value.volumes, [])
      content {
        name = volumes.value.name
        gcs {
          bucket    = volumes.value.bucket
          read_only = try(volumes.value.read_only, false)
        }
      }
    }
  }

  depends_on = [google_storage_bucket.cloud_run_volumes]
}

# Public invoker only where the entry says so (the app gates itself, e.g. oauth2-proxy); otherwise IAM-only.
resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  for_each = { for k, s in local.cloud_run : k => s if try(s.invoker, "iam") == "public" }
  name     = google_cloud_run_v2_service.svc[each.key].name
  location = google_cloud_run_v2_service.svc[each.key].location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# =============================================================================
# Budget Alerts
# =============================================================================

resource "google_billing_budget" "main" {
  provider        = google-beta
  billing_account = local.config.budget.billing_account
  display_name    = local.config.budget.display_name

  budget_filter {
    projects = ["projects/${local.config.provider.project_id}"]
  }

  amount {
    specified_amount {
      currency_code = local.config.budget.currency
      units         = tostring(local.config.budget.amount)
    }
  }

  dynamic "threshold_rules" {
    for_each = local.config.budget.thresholds
    content {
      threshold_percent = threshold_rules.value
    }
  }
}

# =============================================================================
# Outputs
# =============================================================================

output "static_ips" {
  value       = { for name, ip in google_compute_address.ips : name => ip.address }
  description = "Static public IPs"
}

output "instances" {
  value       = { for name, vm in google_compute_instance.vms : name => vm.network_interface[0].access_config[0].nat_ip }
  description = "Instance IPs"
}

output "cloud_run_urls" {
  value       = { for name, svc in google_cloud_run_v2_service.svc : name => svc.uri }
  description = "Cloud Run service URLs (managed entries only)"
}
