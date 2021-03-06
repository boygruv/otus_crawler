provider "google" {
#  version = "1.4.0"
  project = "${var.project}"
  region  = "${var.region}"
  }

resource "google_container_cluster" "k8s" {
  name                = "${var.cluster_name}"
  zone                = "${var.zone}"
  initial_node_count  = "${var.cluster_node_count}"
  enable_legacy_abac  = true
  logging_service     = "none"
  monitoring_service  = "none"
  network             = "projects/${var.project}/global/networks/default"
  subnetwork          = "projects/${var.project}/regions/${var.region}/subnetworks/default"

  addons_config {
    http_load_balancing {
      disabled = true
    } 
    kubernetes_dashboard {
      disabled = true
    }
  }
  #additional_zones = [
  #  "europe-west1-d",
  #  "europe-west1-c",
  #]

  master_auth {
    username = "${var.cluster_auth_username}"
    password = "${var.cluster_auth_password}"
  }

  node_config {
    machine_type = "n1-standard-1"
    disk_size_gb = 40
    #image_type   = "UBUNTU"
    oauth_scopes = [
      "https://www.googleapis.com/auth/compute",
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/trace.append"
    ]

    metadata {  
      ssh-keys = "appuser:${file(var.public_key_path)}"
    }

  }

}

# NodePool для Elasticsearch
resource "google_container_node_pool" "elasticsearch_nodes" {
  name       = "elasticsearch-node-pool"
  zone       = "${var.zone}"
  cluster    = "${google_container_cluster.k8s.name}"
  node_count = 1

  node_config {
    preemptible  = true
    machine_type = "n1-standard-2"
    disk_size_gb = 40

    labels {
      "elastichost" = "true"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/compute",
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/trace.append"
    ]
  }

  depends_on = ["google_container_cluster.k8s"]

}

resource "google_compute_firewall" "crawler" {
  name = "allow-crawler-default"

  # Название сети, в которой действует правило
  network = "default"

  # Какой доступ разрешить
  allow {
    protocol = "tcp"
    ports    = ["30000-32767"]
  }
  allow {
    protocol = "tcp"
    ports    = ["8000"]
  }

  # Каким адресам разрешаем доступ
  source_ranges = ["0.0.0.0/0"]

}

output "cluster_endpoint" {
  value = "${google_container_cluster.k8s.endpoint}"
}


locals {
  k8s_host                   = "${google_container_cluster.k8s.endpoint}"
  k8s_user                   = "${google_container_cluster.k8s.master_auth.0.username}"
  k8s_password               = "${google_container_cluster.k8s.master_auth.0.password}"
  k8s_client_certificate     = "${base64decode(google_container_cluster.k8s.master_auth.0.client_certificate)}"
  k8s_client_key             = "${base64decode(google_container_cluster.k8s.master_auth.0.client_key)}"
  k8s_cluster_ca_certificate = "${base64decode(google_container_cluster.k8s.master_auth.0.cluster_ca_certificate)}"
}

provider "kubernetes" {
  host                   = "${local.k8s_host}"
  username               = "${local.k8s_user}"
  password               = "${local.k8s_password}"
  client_certificate     = "${local.k8s_client_certificate}"
  client_key             = "${local.k8s_client_key}"
  cluster_ca_certificate = "${local.k8s_cluster_ca_certificate}"
}


resource "kubernetes_service_account" "tiller" {
  metadata {
    name      = "tiller"
    namespace = "kube-system"
  }
  automount_service_account_token = true
  depends_on = ["google_container_cluster.k8s"]
}

resource "kubernetes_cluster_role_binding" "tiller" {
  metadata {
    name = "tiller"
  }

  role_ref {
    kind      = "ClusterRole"
    name      = "cluster-admin"
    api_group = "rbac.authorization.k8s.io"
  }

  subject {
    kind = "ServiceAccount"
    name = "tiller"

    api_group = ""
    namespace = "kube-system"
  }

  depends_on = ["google_container_cluster.k8s"]

}



provider "helm" "cluster_helm" {
  version = "~> 0.7.0"

  kubernetes {
    host                   = "${local.k8s_host}"
    username               = "${local.k8s_user}"
    password               = "${local.k8s_password}"
    client_certificate     = "${local.k8s_client_certificate}"
    client_key             = "${local.k8s_client_key}"
    cluster_ca_certificate = "${local.k8s_cluster_ca_certificate}"
  }

  service_account = "${kubernetes_service_account.tiller.metadata.0.name}"
  namespace       = "${kubernetes_service_account.tiller.metadata.0.namespace}"
  install_tiller  = "true"
  tiller_image    = "gcr.io/kubernetes-helm/tiller:v2.11.0"
}


# Подключение к Kubernetes кластеру
resource "null_resource" "cluster_get_credentials" {
  provisioner "local-exec" {
    command = "gcloud container clusters get-credentials ${google_container_cluster.k8s.name} --zone=${google_container_cluster.k8s.zone} --project=${google_container_cluster.k8s.project}"
  }
  depends_on = ["google_container_cluster.k8s"]
}


# Install helm Gitlab
resource "helm_release" "gitlab" {
  name          = "gitlab"
  repository    = "../chart"
  chart         = "gitlab-omnibus"
  version       = "0.1.37"

  values = [
    "${file("../chart/gitlab-omnibus/values.yaml")}"
  ]

  depends_on = ["google_container_cluster.k8s","google_container_node_pool.elasticsearch_nodes"]

}

# Install helm Prometheus
resource "helm_release" "prometheus" {
  name          = "prometheus"
  repository    = "../chart"
  chart         = "prometheus"
  version       = "8.7.1"

  values = [
    "${file("../chart/prometheus/custom_values.yaml")}"
  ]
  depends_on = ["google_container_cluster.k8s","google_container_node_pool.elasticsearch_nodes"]

}


# Install helm Grafana
resource "helm_release" "grafana" {
  name          = "grafana"
  repository    = "../chart"
  chart         = "grafana"
  version       = "1.26.1"

  set {
    name  = "adminPassword"
    value = "admin"
  }
  set {
    name  = "service.type"
    value = "NodePort"
  }
  set {
    name  = "ingress.enabled"
    value = "true"
  }
  set {
    name  = "ingress.hosts"
    value = "{crawler-grafana}"
  }
  depends_on = ["google_container_cluster.k8s","google_container_node_pool.elasticsearch_nodes"]
  
}

# Install helm Prometheus
resource "helm_release" "efk" {
  name          = "efk"
  repository    = "../chart"
  chart         = "efk"
  version       = "1.0.0"

  depends_on = ["google_container_cluster.k8s","google_container_node_pool.elasticsearch_nodes"]

}


# Install helm Kibana
resource "helm_release" "kibana" {
  name          = "kibana"
  repository    = "stable"
  chart         = "kibana"
  version       = "0.2.1"

  set {
    name  = "env.ELASTICSEARCH_URL"
    value = "http://elasticsearch-logging:9200"
  }
  set {
    name  = "ingress.enabled"
    value = "true"
  }
  set {
    name  = "ingress.hosts"
    value = "{crawler-kibana}"
  }

  depends_on = ["google_container_cluster.k8s","google_container_node_pool.elasticsearch_nodes"]
  
}



###############################################################################################


/*
module "tiller" {
  source = "git::https://github.com/lsst-sqre/terraform-tinfoil-tiller.git//?ref=master"

  namespace       = "kube-system"
  service_account = "tiller"
  tiller_image    = "gcr.io/kubernetes-helm/tiller:v2.11.0"

}
*/

/*
resource "null_resource" "helm_init" {
  provisioner "local-exec" {
    command = "helm init --client-only"
  }
  depends_on = ["google_container_cluster.k8s"]
}


resource "null_resource" "helm_install_gitlab" {
  provisioner "local-exec" {
    command = "helm install --name gitlab ../chart/gitlab-omnibus/ -f ../chart/gitlab-omnibus/values.yaml"
  }
  depends_on = ["google_container_cluster.k8s"]
}
*/

/*
resource "kubernetes_config_map" "postgres-config" {
  metadata {
    name = "postgres-config"
  }

  data {
    POSTGRES_DB       = "postgresdb"
    POSTGRES_USER     = "postgresadmin"
    POSTGRES_PASSWORD = "admin123"
  }
}

resource "kubernetes_deployment" "postgresql" {
  metadata {
    name = "postgresql"
    labels {
      app = "gitlab"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels {
        app = "gitlab"
      }
    }

    template {
      metadata {
        labels {
          app = "gitlab"
        }
      }

      spec {
        container {
          image = "postgres:9.6.5"
          name  = "postgresql"
          port {
            container_port = 5432
          } 
          env_from {
             config_map_ref {
               name = "${kubernetes_config_map.postgres-config.metadata.0.name}"
             }
          }
          volume_mount {
            name       = "posgres-gce-pd-storage"
            mount_path = "/var/lib/postgresql/data"
            sub_path   = "postgres"
          }
        }
        volume {
          name = "posgres-gce-pd-storage"
          gce_persistent_disk {
            pd_name = "gitlab-postgresql-disk"
            fs_type = "ext4"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "gitlab_postgres" {
  metadata {
    name = "gitlab-postgres"
    labels {
      app = "gitlab"
    }
  }
  spec {
    selector {
      app = "gitlab"
    }
    type = "ClusterIP"
    port {
      port = 5432
      target_port = 5432
    }

    #type = "LoadBalancer"
  }
}
*/



/*
resource "null_resource" "helm_init" {
  provisioner "local-exec" {
    command = "helm init --service-account tiller --wait"
  }
  depends_on = ["google_container_cluster.k8s"]
}
*/
/*
resource "null_resource" "helm_init" {
  provisioner "local-exec" {
    command = "helm init --service-account tiller --wait"
  }
  depends_on = ["google_container_cluster.k8s"]
}


# Add Gitlab-repo
resource "null_resource" "helm_repo_add" {
  provisioner "local-exec" {
    command = "helm repo add gitlab https://charts.gitlab.io"
  }
  depends_on = ["google_container_cluster.primary"]
}
*/