# ------------------------- OCI Provider Configuration -------------------------

# Get Availability Domain
data "oci_identity_availability_domain" "ad" {
  compartment_id = var.compartment_ocid
  ad_number      = var.availability_domain
}

# Get Object Storage Namespace
data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.compartment_ocid
}

# Auto-discover latest Ubuntu 24.04 image for each shape
data "oci_core_images" "ubuntu_master" {
  compartment_id           = var.tenancy_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = var.masterNodeShape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

data "oci_core_images" "ubuntu_media" {
  compartment_id           = var.tenancy_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = var.mediaNodeShape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# Random suffix for unique naming
resource "random_id" "suffix" {
  byte_length = 3
}

# Random suffix for the auto-generated sslip.io domain — one value shared by all 4 masters.
resource "random_string" "domain_suffix" {
  length  = 8
  special = false
  upper   = false
  numeric = false
}

# ---------------------------- SSH Key -------------------------

resource "tls_private_key" "openvidu_ssh_key_ha" {
  algorithm = "RSA"
}

# ------------------------- Networking -------------------------

# VCN
resource "oci_core_vcn" "openvidu_vcn" {
  cidr_block     = "10.0.0.0/16"
  compartment_id = var.compartment_ocid
  display_name   = "${var.stackName}-vcn"
  dns_label      = lower(replace(substr(var.stackName, 0, 15), "-", ""))
}

# Internet Gateway
resource "oci_core_internet_gateway" "openvidu_ig" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.stackName}-ig"
  vcn_id         = oci_core_vcn.openvidu_vcn.id
  enabled        = true
}

# Route Table
resource "oci_core_route_table" "openvidu_rt" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.openvidu_vcn.id
  display_name   = "${var.stackName}-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.openvidu_ig.id
  }
}

# Base subnet security list (per-role filtering is done with NSGs)
resource "oci_core_security_list" "openvidu_subnet_security_list" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.openvidu_vcn.id
  display_name   = "${var.stackName}-subnet-sl"

  # Allow all egress
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # Allow all intra-VCN ingress — NSGs do fine-grained control. OCI ANDs the
  # security list with NSGs, so without this the SL would block intra-VCN
  # traffic even when an NSG rule allows it.
  ingress_security_rules {
    source   = "10.0.0.0/16"
    protocol = "all"
  }
}

# Master NSG (equivalent to GCP firewall_master)
resource "oci_core_network_security_group" "master_nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.openvidu_vcn.id
  display_name   = "${var.stackName}-master-nsg"
}

# Media NSG (equivalent to GCP firewall_media)
resource "oci_core_network_security_group" "media_nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.openvidu_vcn.id
  display_name   = "${var.stackName}-media-nsg"
}

locals {
  master_internet_ingress_tcp = {
    ssh   = { min = 22, max = 22, label = "SSH" }
    http  = { min = 80, max = 80, label = "HTTP" }
    https = { min = 443, max = 443, label = "HTTPS" }
    rtmp  = { min = 1935, max = 1935, label = "RTMP" }
  }

  media_internet_ingress_tcp = {
    ssh     = { min = 22, max = 22, label = "SSH" }
    livekit = { min = 7881, max = 7881, label = "TCP 7881" }
    api     = { min = 7880, max = 7880, label = "TCP 7880" }
    rtp     = { min = 50000, max = 60000, label = "TCP range" }
  }

  media_internet_ingress_udp = {
    dtls = { min = 443, max = 443, label = "UDP 443" }
    turn = { min = 7885, max = 7885, label = "UDP 7885" }
    rtp  = { min = 50000, max = 60000, label = "UDP range" }
  }

  # Ports a media node opens TOWARDS the masters. HA-specific: Redis range
  # 7000-7001 (7001 = Sentinel port media nodes use to find the master holding
  # the Redis primary) + 7880 cluster endpoint. Without 7001, Sentinel-based
  # failover can't work. Matches AWS/GCP/DigitalOcean HA references.
  master_ingress_from_media_ports = {
    redis     = { min = 7000, max = 7001 }
    cluster   = { min = 7880, max = 7880 }
    metrics   = { min = 9100, max = 9100 }
    openvidu  = { min = 20000, max = 20000 }
    loki      = { min = 3100, max = 3100 }
    tempo     = { min = 9009, max = 9009 }
    rtc       = { min = 4443, max = 4443 }
    media_api = { min = 9080, max = 9080 }
    kurento   = { min = 6080, max = 6080 }
  }

  media_ingress_from_master_ports = {
    rtmp    = { min = 1935, max = 1935 }
    turn    = { min = 5349, max = 5349 }
    livekit = { min = 7880, max = 7880 }
    api     = { min = 8080, max = 8080 }
  }

  # Public ports the NLB must accept from the internet (and from Let's Encrypt
  # ACME validators). The NLB has no NSG by default, so it would otherwise
  # inherit only the subnet SL (VCN-only ingress) and drop ALL inbound internet
  # traffic on these ports (= "Timeout during connect", no cert).
  nlb_ingress_tcp = {
    http  = { min = 80, max = 80, label = "HTTP" }
    https = { min = 443, max = 443, label = "HTTPS" }
    rtmp  = { min = 1935, max = 1935, label = "RTMP" }
  }
}

resource "oci_core_network_security_group_security_rule" "nsg_egress" {
  for_each = {
    master = oci_core_network_security_group.master_nsg.id
    media  = oci_core_network_security_group.media_nsg.id
  }
  network_security_group_id = each.value
  direction                 = "EGRESS"
  destination               = "0.0.0.0/0"
  protocol                  = "all"
}

resource "oci_core_network_security_group_security_rule" "master_internet_ingress" {
  for_each = local.master_internet_ingress_tcp

  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  description               = "Master ${each.value.label}"
  tcp_options {
    destination_port_range {
      min = each.value.min
      max = each.value.max
    }
  }
}

resource "oci_core_network_security_group_security_rule" "media_internet_ingress_tcp" {
  for_each = local.media_internet_ingress_tcp

  network_security_group_id = oci_core_network_security_group.media_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  description               = "Media ${each.value.label}"
  tcp_options {
    destination_port_range {
      min = each.value.min
      max = each.value.max
    }
  }
}

resource "oci_core_network_security_group_security_rule" "media_internet_ingress_udp" {
  for_each = local.media_internet_ingress_udp

  network_security_group_id = oci_core_network_security_group.media_nsg.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = "0.0.0.0/0"
  description               = "Media ${each.value.label}"
  udp_options {
    destination_port_range {
      min = each.value.min
      max = each.value.max
    }
  }
}

resource "oci_core_network_security_group_security_rule" "master_ingress_from_media" {
  for_each = local.master_ingress_from_media_ports

  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.media_nsg.id
  description               = "Media to Master ${each.value.min}"
  tcp_options {
    destination_port_range {
      min = each.value.min
      max = each.value.max
    }
  }
}

resource "oci_core_network_security_group_security_rule" "media_ingress_from_master" {
  for_each = local.media_ingress_from_master_ports

  network_security_group_id = oci_core_network_security_group.media_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.master_nsg.id
  description               = "Master to Media ${each.value.min}"
  tcp_options {
    destination_port_range {
      min = each.value.min
      max = each.value.max
    }
  }
}

# HA-only: allow ALL intra-NSG traffic between masters. Required for clustered
# services spanning all 4 masters — MongoDB replica set (27017), Redis Sentinel
# (6379, 26379, 7000-7001), memberlist gossip (7946 TCP+UDP: Loki/Mimir/Grafana
# Agent), OpenVidu Pro server (20000), Tempo (9009), etc. Enumerating each port
# is fragile to OpenVidu version bumps; intra-NSG allow-all is the canonical OCI
# pattern for tightly coupled cluster members.
resource "oci_core_network_security_group_security_rule" "master_to_master" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.master_nsg.id
  description               = "Master to Master cluster traffic"
}

# HA-only: allow the NLB (and any in-VCN source) to reach the LiveKit health
# endpoint on each master. The NLB probes from an internal address, so open the
# port to the VCN CIDR.
resource "oci_core_network_security_group_security_rule" "master_health_from_vcn" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "CIDR_BLOCK"
  source                    = "10.0.0.0/16"
  description               = "NLB health check (LiveKit /health/caddy on 7880)"
  tcp_options {
    destination_port_range {
      min = 7880
      max = 7880
    }
  }
}

# Subnet
resource "oci_core_subnet" "openvidu_subnet" {
  cidr_block        = "10.0.1.0/24"
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.openvidu_vcn.id
  display_name      = "${var.stackName}-subnet"
  dns_label         = "subnet"
  security_list_ids = [oci_core_security_list.openvidu_subnet_security_list.id]
  route_table_id    = oci_core_route_table.openvidu_rt.id
}

# ------------------------- Object Storage -------------------------

# Customer Secret Key for S3-compatible access.
# 'id' = S3 Access Key ID; 'key' = S3 Secret Key (sensitive, in TF state).
resource "oci_identity_customer_secret_key" "openvidu_s3_key" {
  display_name = "${var.stackName}-s3-key"
  user_id      = var.user_ocid
}

resource "oci_objectstorage_bucket" "appdata_bucket" {
  count          = var.bucketAppDataName == "" ? 1 : 0
  compartment_id = var.compartment_ocid
  name           = "${var.stackName}-appdata-${random_id.suffix.hex}"
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  access_type    = "NoPublicAccess"
}

# HA-only: cluster-data bucket for state shared across all 4 masters (SSH key,
# cluster-bootstrap files). Mirrors EXTERNAL_S3_BUCKET_CLUSTER_DATA in AWS/GCP HA.
resource "oci_objectstorage_bucket" "clusterdata_bucket" {
  count          = var.bucketClusterDataName == "" ? 1 : 0
  compartment_id = var.compartment_ocid
  name           = "${var.stackName}-clusterdata-${random_id.suffix.hex}"
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  access_type    = "NoPublicAccess"
}

locals {
  bucket_app_data_name     = var.bucketAppDataName == "" ? oci_objectstorage_bucket.appdata_bucket[0].name : var.bucketAppDataName
  bucket_cluster_data_name = var.bucketClusterDataName == "" ? oci_objectstorage_bucket.clusterdata_bucket[0].name : var.bucketClusterDataName
}

# SSH key goes in cluster-data — it's operator state, not application data.
resource "oci_objectstorage_object" "ssh_private_key" {
  namespace = data.oci_objectstorage_namespace.ns.namespace
  bucket    = local.bucket_cluster_data_name
  object    = "openvidu_private_ssh_key_${var.stackName}.pem"
  content   = tls_private_key.openvidu_ssh_key_ha.private_key_pem

  # depends_on empty_buckets so this object is destroyed BEFORE the bulk-delete.
  depends_on = [oci_objectstorage_bucket.clusterdata_bucket, null_resource.empty_buckets]
}

# Pre-created scale-in lock. Always exists so invoke_scalein.sh only needs
# --if-match (CAS) — the CLI has no --if-none-match. Runtime writes are ignored.
resource "oci_objectstorage_object" "scalein_lock" {
  count = var.fixedNumberOfMediaNodes > 0 ? 0 : 1

  namespace    = data.oci_objectstorage_namespace.ns.namespace
  bucket       = local.bucket_cluster_data_name
  object       = "scalein.lock"
  content      = jsonencode({ holder = "", expires_at = 0 })
  content_type = "application/json"

  depends_on = [oci_objectstorage_bucket.clusterdata_bucket, null_resource.empty_buckets]
  lifecycle {
    ignore_changes = [content]
  }
}

# Empty TF-created buckets before destroy — OCI won't delete a non-empty bucket
# (runtime recordings in appdata, cluster state in clusterdata). User-provided
# buckets untouched. Ordered after the TF-managed objects' destroy (their
# depends_on), so the bulk-delete only sweeps runtime leftovers.
resource "null_resource" "empty_buckets" {
  triggers = {
    namespace      = data.oci_objectstorage_namespace.ns.namespace
    region         = var.region
    appdata_bucket = var.bucketAppDataName == "" ? local.bucket_app_data_name : ""
    cluster_bucket = var.bucketClusterDataName == "" ? local.bucket_cluster_data_name : ""
  }

  depends_on = [
    oci_objectstorage_bucket.appdata_bucket,
    oci_objectstorage_bucket.clusterdata_bucket,
  ]

  provisioner "local-exec" {
    when    = destroy
    command = <<-SCRIPT
      set -x
      if ! command -v oci >/dev/null 2>&1; then
        echo "[empty-buckets] WARN: 'oci' CLI not in PATH ($PATH); non-empty buckets will block destroy."
        exit 0
      fi
      for B in "${self.triggers.appdata_bucket}" "${self.triggers.cluster_bucket}"; do
        [ -z "$B" ] && continue
        echo "[empty-buckets] Emptying bucket $B ..."
        # Re-sweep until the bucket actually reports empty. depends_on guarantees
        # the masters' terminate is ISSUED before this runs, but the VMs linger
        # during shutdown and Mimir/Loki can flush one more object (e.g. 'index')
        # AFTER the first sweep — leaving the bucket non-empty so its delete fails.
        # A single bulk-delete therefore isn't enough; retry to absorb that window.
        for attempt in 1 2 3 4 5 6; do
          oci os object bulk-delete \
            --namespace "${self.triggers.namespace}" \
            --bucket-name "$B" \
            --region "${self.triggers.region}" \
            --force 2>/dev/null || true
          REMAIN=$(oci os object list \
            --namespace "${self.triggers.namespace}" \
            --bucket-name "$B" \
            --region "${self.triggers.region}" \
            --all --query 'length(data)' --raw-output 2>/dev/null || echo "gone")
          echo "[empty-buckets] $B attempt $attempt: remaining=$REMAIN"
          { [ "$REMAIN" = "0" ] || [ "$REMAIN" = "gone" ]; } && break
          sleep 15
        done
      done
    SCRIPT
  }
}

# ------------------------- Vault / Secrets -------------------------

# Single source of truth for the vault/key OCIDs (user-provided *_ocid vars or
# the ones created here). Avoids repeating the ternary in data sources and the
# embedded vault scripts.
locals {
  vault_id = var.vault_ocid != "" ? var.vault_ocid : oci_kms_vault.openvidu_vault[0].id
  key_id   = var.key_ocid != "" ? var.key_ocid : oci_kms_key.openvidu_key[0].id
}

resource "oci_kms_vault" "openvidu_vault" {
  count          = var.vault_ocid == "" ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "${var.stackName}-vault"
  vault_type     = "DEFAULT"
}

data "oci_kms_vault" "openvidu_vault" {
  vault_id = local.vault_id
}

# OCI marks the vault ACTIVE before its management-endpoint DNS resolves.
# Wait for the hostname to resolve before creating the key.
resource "null_resource" "wait_for_vault_dns" {
  count = var.vault_ocid == "" ? 1 : 0
  triggers = {
    vault_id = oci_kms_vault.openvidu_vault[0].id
  }
  depends_on = [oci_kms_vault.openvidu_vault]
  provisioner "local-exec" {
    command = <<-SH
      HOST=$(echo "${data.oci_kms_vault.openvidu_vault.management_endpoint}" | sed 's|https://||' | sed 's|/.*||')
      echo "[vault-dns] Waiting for $HOST to resolve (up to 15 min)..."
      sleep 30
      for i in $(seq 1 168); do
        if getent hosts "$HOST" > /dev/null 2>&1 || host "$HOST" > /dev/null 2>&1 || nslookup "$HOST" > /dev/null 2>&1; then
          echo "[vault-dns] Resolved after ~$((30 + i * 5))s."
          exit 0
        fi
        echo "[vault-dns] Not resolved yet (attempt $${i}/168), retrying in 5s..."
        sleep 5
      done
      echo "[vault-dns] Timeout after 15 min waiting for vault DNS." >&2
      exit 1
    SH
  }
}

resource "oci_kms_key" "openvidu_key" {
  count               = var.key_ocid == "" ? 1 : 0
  compartment_id      = var.compartment_ocid
  display_name        = "${var.stackName}-key"
  management_endpoint = data.oci_kms_vault.openvidu_vault.management_endpoint

  key_shape {
    algorithm = "AES"
    length    = 32
  }

  depends_on = [null_resource.wait_for_vault_dns]
}

data "oci_kms_key" "openvidu_key" {
  management_endpoint = data.oci_kms_vault.openvidu_vault.management_endpoint
  key_id              = local.key_id
}

# ------------------------- HA deployment generation token -------------------------
#
# Fresh-per-deployment token, injected into every node via IMDS metadata (a
# channel OUTSIDE the vault). Stamps the coordination secrets
# (ALL_SECRETS_GENERATED, MASTER_NODE_N_PRIVATE_IP). On a RECYCLED vault those
# still hold PREVIOUS-deployment values; without a token a follower could read a
# stale "ready" flag or a master pick up a dead IP before the real one registers
# (parallel boot makes this likely). Each node trusts only values stamped with
# ITS token, so stale ones (old token) are ignored, not raced on.
#
# No keepers: random_id regenerates on destroy+apply (state wiped) so each fresh
# deployment gets a distinct token, while plain re-apply keeps it stable (no
# spurious instance recreation).
resource "random_id" "deployment_generation" {
  byte_length = 8
}

locals {
  deployment_generation = random_id.deployment_generation.hex
}

# ------------------------- Compute Instances (4 Master Nodes) -------------------------
#
# HA topology: 4 instances behind an external NLB. Each gets its identity (1..4)
# via metadata.masterNodeNum. install_script_master has master #1 generate the
# cluster secrets and signal ALL_SECRETS_GENERATED while the others wait; all 4
# register their private IP under MASTER_NODE_{N}_PRIVATE_IP and block until all
# 4 are present before running install_ov_master_node.sh with
# --master-node-private-ip-list. Mirrors the AWS/GCP/DigitalOcean HA references.
#
# All 4 boot in parallel — a for_each resource can't express a self-referential
# 1→2→3→4 depends_on chain (and depends_on wouldn't help: it orders provisioning,
# not cloud-init, so a follower's cloud-init can still run before master #1's).
# Ordering is at runtime via the per-deployment generation token (see
# random_id.deployment_generation): on a RECYCLED vault, stale flag/IP values
# carry a different token and are ignored — no manual "reset the flag" step.
#
# Every master carries the scale-in-mode / scale-in-fn-id freeform tags (like
# elastic), read at RUNTIME by invoke_scalein.sh / the media pre-drain daemon.
# So toggling fixedNumberOfMediaNodes only updates tags in place — it never
# rewrites user_data, so masters are NOT recreated (which would mean a fresh
# domain + fresh vault secrets, i.e. a brand-new deployment).

resource "oci_core_instance" "openvidu_master_node" {
  for_each = toset(["1", "2", "3", "4"])

  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_ocid
  display_name        = "${var.stackName}-master-node-${each.key}"
  shape               = var.masterNodeShape

  shape_config {
    ocpus         = var.masterNodeOcpus
    memory_in_gbs = var.masterNodeMemory
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.openvidu_subnet.id
    assign_public_ip = true
    display_name     = "master-node-${each.key}-vnic"
    nsg_ids          = [oci_core_network_security_group.master_nsg.id]
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_master.images[0].id
    boot_volume_size_in_gbs = var.masterNodeDiskSize
  }

  metadata = {
    ssh_authorized_keys  = tls_private_key.openvidu_ssh_key_ha.public_key_openssh
    user_data            = base64gzip(local.user_data_master)
    masterNodeNum        = each.key
    deploymentGeneration = local.deployment_generation
  }

  freeform_tags = {
    "stack"          = var.stackName
    "node-type"      = "master"
    "node-num"       = each.key
    "scale-in-mode"  = var.fixedNumberOfMediaNodes > 0 ? "fixed" : "elastic"
    "scale-in-fn-id" = try(oci_functions_function.scale_in_fn[0].id, "")
  }

  # NSG rules + NLB resource only (NOT backends/listeners → cycle): net path ready before boot.
  depends_on = [
    time_sleep.wait_for_iam_propagation,
    oci_network_load_balancer_network_load_balancer.openvidu_nlb,
    oci_core_network_security_group_security_rule.nsg_egress,
    oci_core_network_security_group_security_rule.nlb_internet_ingress,
    oci_core_network_security_group_security_rule.master_internet_ingress,
    oci_core_network_security_group_security_rule.master_to_master,
    oci_core_network_security_group_security_rule.master_ingress_from_media,
    oci_core_network_security_group_security_rule.media_ingress_from_master,
    oci_core_network_security_group_security_rule.master_health_from_vcn,
    # Destroy ordering: masters must be torn down BEFORE null_resource.empty_buckets
    # sweeps. Otherwise Mimir/Loki on a still-running master flush a block into the
    # cluster-data bucket AFTER the sweep, leaving it non-empty and blocking the
    # bucket delete (the orphaned-bucket bug).
    null_resource.empty_buckets,
  ]
}

# State migration from the previous four-separate-resources layout: keep the
# existing instances instead of destroy/recreate. No-op on a clean apply.
moved {
  from = oci_core_instance.openvidu_master_node_1
  to   = oci_core_instance.openvidu_master_node["1"]
}
moved {
  from = oci_core_instance.openvidu_master_node_2
  to   = oci_core_instance.openvidu_master_node["2"]
}
moved {
  from = oci_core_instance.openvidu_master_node_3
  to   = oci_core_instance.openvidu_master_node["3"]
}
moved {
  from = oci_core_instance.openvidu_master_node_4
  to   = oci_core_instance.openvidu_master_node["4"]
}

# ------------------------- Autoscaling (Media Nodes) -------------------------

resource "oci_core_instance_configuration" "media_node_config" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.stackName}-media-config"

  instance_details {
    instance_type = "compute"

    launch_details {
      compartment_id = var.compartment_ocid
      display_name   = "${var.stackName}-media-pool"
      shape          = var.mediaNodeShape

      shape_config {
        ocpus         = var.mediaNodeOcpus
        memory_in_gbs = var.mediaNodeMemory
      }

      create_vnic_details {
        subnet_id        = oci_core_subnet.openvidu_subnet.id
        assign_public_ip = true
        display_name     = "${var.stackName}-media-pool-vnic"
        nsg_ids          = [oci_core_network_security_group.media_nsg.id]
      }

      source_details {
        source_type             = "image"
        image_id                = data.oci_core_images.ubuntu_media.images[0].id
        boot_volume_size_in_gbs = var.mediaNodeDiskSize
      }

      metadata = {
        ssh_authorized_keys = tls_private_key.openvidu_ssh_key_ha.public_key_openssh
        user_data           = base64gzip(local.user_data_media)
        # Comma-joined list of all 4 master private IPs. In HA mode
        # install_ov_media_node.sh takes --master-node-private-ip-list and uses
        # Redis Sentinel to reach whichever master is currently primary.
        masterNodePrivateIPList = join(",", [
          for key in ["1", "2", "3", "4"] :
          oci_core_instance.openvidu_master_node[key].private_ip
        ])
        deploymentGeneration = local.deployment_generation
      }

      freeform_tags = {
        "stack"     = var.stackName
        "node-type" = "media"
      }
    }
  }

  # An instance_configuration attached to a pool can't be deleted while
  # associated (OCI 409). Create the replacement and re-point the pool before
  # destroying the old one, so a forced replacement (e.g. master IPs change) works.
  lifecycle {
    create_before_destroy = true
  }
}

# Cleanup orphaned media nodes on `terraform destroy`.
#
# Instances detached from the pool by the scale-in function are no longer tracked
# by Terraform; if graceful_shutdown.sh fails to self-terminate one, it lives on
# forever. Destroy order: this provisioner runs first (terminates orphans), then
# the pool is destroyed (OCI terminates its current members). Orphans are
# identified by their freeform tags stack=<stackName> node-type=media.
resource "null_resource" "cleanup_orphaned_media_nodes" {
  triggers = {
    compartment_id = var.compartment_ocid
    stack_name     = var.stackName
  }

  # depends_on subnet so on destroy this runs BEFORE the subnet is deleted,
  # terminating orphaned (out-of-pool) instances first. depends_on empty_buckets
  # so orphan media (which write recordings to app-data) are terminated BEFORE the
  # bucket sweep runs — same destroy-ordering race as the master/pool notes.
  depends_on = [oci_core_subnet.openvidu_subnet, null_resource.empty_buckets]

  provisioner "local-exec" {
    when = destroy
    # No `environment` block on purpose: inherit the invoking shell's PATH so the
    # OCI CLI is found wherever the user installed it (pipx, system, brew, ...).
    command = <<-SCRIPT
      set -x
      if ! command -v oci >/dev/null 2>&1; then
        echo "[cleanup] WARN: 'oci' CLI not found in PATH ($PATH); skipping orphan cleanup."
        echo "[cleanup] If any media nodes detached from the pool are still RUNNING in OCI,"
        echo "[cleanup] terminate them manually before re-deploying or they will accumulate."
        exit 0
      fi
      echo "[cleanup] Looking for orphaned media nodes (stack=${self.triggers.stack_name})..."
      # NOTE: single-dollar shell vars are correct here. Terraform only escapes
      # $${...}; a bare $$VAR passes through literally and breaks jq (syntax) and
      # shell (where $$ expands to the PID).

      # All non-terminated media instances of this stack
      ALL_IDS=$(oci compute instance list \
        --compartment-id "${self.triggers.compartment_id}" \
        --all --output json \
        | jq -r --arg s "${self.triggers.stack_name}" \
            '.data[]
             | select(
                 .["lifecycle-state"] != "TERMINATED" and
                 .["lifecycle-state"] != "TERMINATING" and
                 .["freeform-tags"]["stack"] == $s and
                 .["freeform-tags"]["node-type"] == "media"
               )
             | .id') || { echo "[cleanup] ERROR: failed to list instances"; exit 0; }

      # Pool members (if the pool still exists). The pool's own destroy
      # terminates these — we only want to kill detached/stuck true orphans.
      POOL_ID=$(oci compute-management instance-pool list \
        --compartment-id "${self.triggers.compartment_id}" \
        --all --output json 2>/dev/null \
        | jq -r --arg n "${self.triggers.stack_name}-media-pool" \
            '.data[] | select(."display-name" == $n and ."lifecycle-state" != "TERMINATED") | .id' \
        | head -1) || POOL_ID=""

      MEMBER_IDS=""
      if [ -n "$POOL_ID" ]; then
        MEMBER_IDS=$(oci compute-management instance-pool list-instances \
          --compartment-id "${self.triggers.compartment_id}" \
          --instance-pool-id "$POOL_ID" \
          --all --output json 2>/dev/null \
          | jq -r '.data[].id') || MEMBER_IDS=""
      fi

      # Orphans = ALL_IDS - MEMBER_IDS. POSIX only — local-exec /bin/sh is dash
      # on Ubuntu (no process substitution).
      IDS=""
      for id in $ALL_IDS; do
        case "$MEMBER_IDS" in
          *"$id"*) ;;
          *) IDS="$IDS $id" ;;
        esac
      done

      if [ -z "$IDS" ]; then
        echo "[cleanup] No orphaned media nodes found."
      else
        for ID in $IDS; do
          echo "[cleanup] Terminating orphaned media node $ID..."
          oci compute instance terminate \
            --instance-id "$ID" \
            --preserve-boot-volume true \
            --force || true
        done
        echo "[cleanup] Waiting for instances to reach TERMINATED state..."
        for ID in $IDS; do
          attempt=0
          while true; do
            attempt=$((attempt + 1))
            STATE=$(oci compute instance get --instance-id "$ID" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || echo "TERMINATED")
            echo "[cleanup] $ID state: $STATE (attempt $attempt)"
            if [ "$STATE" = "TERMINATED" ]; then break; fi
            if [ $attempt -ge 60 ]; then echo "[cleanup] Timeout waiting for $ID"; break; fi
            sleep 10
          done
        done
        # Let detaching BVs settle into AVAILABLE before listing.
        sleep 15
      fi

      echo "[cleanup] Looking for orphaned boot volumes (stack=${self.triggers.stack_name})..."
      # BVs are named after the parent instance (inst-XXXXX-STACK-media-pool),
      # not the pool — startswith() never matched, so use contains(). The
      # AVAILABLE filter ensures we never touch BVs still attached to a running
      # instance.
      BVIDS=$(oci bv boot-volume list \
        --compartment-id "${self.triggers.compartment_id}" \
        --all --output json \
        | jq -r --arg s "${self.triggers.stack_name}-media-pool" \
            '.data[]
             | select(
                 .["lifecycle-state"] == "AVAILABLE" and
                 (.["display-name"] | contains($s))
               )
             | .id') || true
      if [ -z "$BVIDS" ]; then
        echo "[cleanup] No orphaned boot volumes found."
      else
        for BVID in $BVIDS; do
          echo "[cleanup] Deleting orphaned boot volume $BVID..."
          oci bv boot-volume delete \
            --boot-volume-id "$BVID" \
            --force || true
        done
      fi
      echo "[cleanup] Done."
    SCRIPT
  }
}

resource "oci_core_instance_pool" "media_node_pool" {
  compartment_id            = var.compartment_ocid
  instance_configuration_id = oci_core_instance_configuration.media_node_config.id
  display_name              = "${var.stackName}-media-pool"
  size                      = var.fixedNumberOfMediaNodes > 0 ? var.fixedNumberOfMediaNodes : var.initialNumberOfMediaNodes

  placement_configurations {
    availability_domain = data.oci_identity_availability_domain.ad.name
    primary_subnet_id   = oci_core_subnet.openvidu_subnet.id
  }

  # Network path ready before boot (media talks to masters directly, not via NLB).
  depends_on = [
    oci_core_network_security_group_security_rule.nsg_egress,
    oci_core_network_security_group_security_rule.media_internet_ingress_tcp,
    oci_core_network_security_group_security_rule.media_internet_ingress_udp,
    oci_core_network_security_group_security_rule.media_ingress_from_master,
    oci_core_network_security_group_security_rule.master_ingress_from_media,
    # Destroy ordering: the pool's media nodes (writing recordings to app-data)
    # must be torn down before null_resource.empty_buckets sweeps. Same race as
    # the master-node note.
    null_resource.empty_buckets,
  ]
}

resource "oci_autoscaling_auto_scaling_configuration" "media_node_autoscaling" {
  count = var.fixedNumberOfMediaNodes > 0 ? 0 : 1

  compartment_id       = var.compartment_ocid
  display_name         = "${var.stackName}-autoscaling"
  cool_down_in_seconds = 300
  is_enabled           = true

  auto_scaling_resources {
    id   = oci_core_instance_pool.media_node_pool.id
    type = "instancePool"
  }

  policies {
    display_name = "cpu-policy"
    policy_type  = "threshold"
    capacity {
      initial = var.initialNumberOfMediaNodes
      max     = var.maxNumberOfMediaNodes
      min     = var.minNumberOfMediaNodes
    }
    rules {
      action {
        type  = "CHANGE_COUNT_BY"
        value = 1
      }
      display_name = "scale-out-rule"
      metric {
        metric_type = "CPU_UTILIZATION"
        threshold {
          operator = "GT"
          value    = var.scaleTargetCPU
        }
      }
    }
    # OCI provider ≥8.12.0 requires ≥1 scale-in rule. LT 0% can never fire (CPU
    # is always ≥ 0) — this exists ONLY to satisfy the provider. Real scale-in
    # is owned by the OCI Function (func.py), invoked every 5 min.
    rules {
      action {
        type  = "CHANGE_COUNT_BY"
        value = -1
      }
      display_name = "scale-in-rule-noop"
      metric {
        metric_type = "CPU_UTILIZATION"
        threshold {
          operator = "LT"
          value    = 0
        }
      }
    }
  }
}

# ------------------------- IAM: Instance Principal for Pre-drain Daemon -------------------------

# Dynamic Group matching all compartment instances. Lets media nodes auth to the
# OCI API via Instance Principal (no on-instance credentials) to poll their own
# lifecycle state.
resource "oci_identity_dynamic_group" "openvidu_instances_dg" {
  compartment_id = var.tenancy_ocid
  name           = "${var.stackName}-instances-dg"
  description    = "Dynamic group for OpenVidu instances (Instance Principal auth for pre-drain)"
  matching_rule  = "instance.compartment.id = '${var.compartment_ocid}'"
}

# Policy: lets instances poll pool membership (pre-drain daemon), self-terminate
# after drain (graceful_shutdown.sh), manage vault secrets, and invoke the
# scale-in function (master node).
resource "oci_identity_policy" "media_node_predrain_policy" {
  # At tenancy (root) level so cross-compartment grants work when the vault lives
  # in a different compartment than the deployment.
  compartment_id = var.tenancy_ocid
  name           = "${var.stackName}-predrain-policy"
  description    = "Allow OpenVidu instances to manage their lifecycle and invoke the scale-in function"
  statements = [
    "allow dynamic-group ${oci_identity_dynamic_group.openvidu_instances_dg.name} to manage instance-pools in compartment id ${var.compartment_ocid}",
    "allow dynamic-group ${oci_identity_dynamic_group.openvidu_instances_dg.name} to manage instances in compartment id ${var.compartment_ocid}",
    "allow dynamic-group ${oci_identity_dynamic_group.openvidu_instances_dg.name} to {INSTANCE_INSPECT,INSTANCE_READ,INSTANCE_UPDATE,INSTANCE_DELETE} in compartment id ${var.compartment_ocid}",
    "allow dynamic-group ${oci_identity_dynamic_group.openvidu_instances_dg.name} to manage boot-volumes in compartment id ${var.compartment_ocid}",
    # use vnics + use subnets required for OCI to detach the VNIC when terminating an instance
    "allow dynamic-group ${oci_identity_dynamic_group.openvidu_instances_dg.name} to use vnics in compartment id ${var.compartment_ocid}",
    "allow dynamic-group ${oci_identity_dynamic_group.openvidu_instances_dg.name} to use subnets in compartment id ${var.compartment_ocid}",
    "allow dynamic-group ${oci_identity_dynamic_group.openvidu_instances_dg.name} to manage secret-family in compartment id ${var.compartment_ocid}",
    "allow dynamic-group ${oci_identity_dynamic_group.openvidu_instances_dg.name} to read secret-bundles in compartment id ${var.compartment_ocid}",
    "allow dynamic-group ${oci_identity_dynamic_group.openvidu_instances_dg.name} to read metrics in compartment id ${var.compartment_ocid}",
    # Vault and key may be in a different compartment — use the vault's actual compartment
    "allow dynamic-group ${oci_identity_dynamic_group.openvidu_instances_dg.name} to use vaults in compartment id ${data.oci_kms_vault.openvidu_vault.compartment_id}",
    "allow dynamic-group ${oci_identity_dynamic_group.openvidu_instances_dg.name} to use keys in compartment id ${data.oci_kms_vault.openvidu_vault.compartment_id}",
    "allow dynamic-group ${oci_identity_dynamic_group.openvidu_instances_dg.name} to use fn-invocation in compartment id ${var.compartment_ocid}",
    "allow dynamic-group ${oci_identity_dynamic_group.openvidu_instances_dg.name} to use fn-function in compartment id ${var.compartment_ocid}",
    # Object Storage scale-in lock (scalein.lock) — atomic CAS via ETag.
    "allow dynamic-group ${oci_identity_dynamic_group.openvidu_instances_dg.name} to manage objects in compartment id ${var.compartment_ocid} where target.bucket.name = '${local.bucket_cluster_data_name}'",
  ]
}

# ------------------------- OCI Functions: Scale-in -------------------------

# Dynamic Group matching the scale-in function for Resource Principal auth, so
# it can call OCI APIs (instance-pools, monitoring) without baked-in credentials.
resource "oci_identity_dynamic_group" "scale_in_fn_dg" {
  count = var.fixedNumberOfMediaNodes > 0 ? 0 : 1

  compartment_id = var.tenancy_ocid
  name           = "${var.stackName}-scalein-fn-dg"
  description    = "Dynamic group for OpenVidu scale-in OCI Function (Resource Principal auth)"
  matching_rule  = "ALL {resource.type='fnfunc', resource.compartment.id='${var.compartment_ocid}'}"
}

# Policy: lets the scale-in function list/inspect/resize the media node pool and
# read CPU metrics from OCI Monitoring (same data source as func.py).
resource "oci_identity_policy" "scale_in_fn_policy" {
  count = var.fixedNumberOfMediaNodes > 0 ? 0 : 1

  compartment_id = var.compartment_ocid
  name           = "${var.stackName}-scalein-fn-policy"
  description    = "Allow OpenVidu scale-in OCI Function to manage media node pool size"
  statements = [
    "allow dynamic-group ${oci_identity_dynamic_group.scale_in_fn_dg[0].name} to manage instance-pools in compartment id ${var.compartment_ocid}",
    "allow dynamic-group ${oci_identity_dynamic_group.scale_in_fn_dg[0].name} to manage instances in compartment id ${var.compartment_ocid}",
    # terminate-instance with preserve_boot_volume=false must delete the boot
    # volume too — without volume-family OCI rejects with "volume ... cannot be
    # terminated because this user does not have sufficient permissions".
    "allow dynamic-group ${oci_identity_dynamic_group.scale_in_fn_dg[0].name} to manage volume-family in compartment id ${var.compartment_ocid}",
    "allow dynamic-group ${oci_identity_dynamic_group.scale_in_fn_dg[0].name} to read metrics in compartment id ${var.compartment_ocid}",
  ]
}

# OCI IAM policy propagation takes 60-120s after creation. Wait before launching
# masters so instance_principal auth is ready.
resource "time_sleep" "wait_for_iam_propagation" {
  depends_on = [
    oci_identity_dynamic_group.openvidu_instances_dg,
    oci_identity_policy.media_node_predrain_policy,
  ]
  create_duration = "120s"
}

# Function Application: hosts the scale-in function and injects runtime config.
# Config vars are set by Terraform and read at invocation via os.environ — no
# image rebuild needed to change them.
resource "oci_functions_application" "scale_in_app" {
  count = var.fixedNumberOfMediaNodes > 0 ? 0 : 1

  compartment_id = var.compartment_ocid
  display_name   = "${var.stackName}-scalein-app"
  subnet_ids     = [oci_core_subnet.openvidu_subnet.id]

  config = {
    COMPARTMENT_ID    = var.compartment_ocid
    POOL_DISPLAY_NAME = "${var.stackName}-media-pool"
    MIN_NODES         = tostring(var.minNumberOfMediaNodes)
    CPU_THRESHOLD     = tostring(var.scaleTargetCPU)
  }
}

# Function: uses the pre-built image published by OpenVidu in their OCIR — no
# docker build/push during terraform apply.
resource "oci_functions_function" "scale_in_fn" {
  count = var.fixedNumberOfMediaNodes > 0 ? 0 : 1

  application_id     = oci_functions_application.scale_in_app[0].id
  display_name       = "${var.stackName}-scalein-fn"
  image              = var.scale_in_function_image
  memory_in_mbs      = "256"
  timeout_in_seconds = 120
}

# Log Group: container for the scale-in function logs.
resource "oci_logging_log_group" "scale_in_log_group" {
  count = var.fixedNumberOfMediaNodes > 0 ? 0 : 1

  compartment_id = var.compartment_ocid
  display_name   = "${var.stackName}-scalein-log-group"
}

# Log: captures function invocation logs (func.py stdout/stderr).
# service=functions, resource=application OCID, category=invoke
resource "oci_logging_log" "scale_in_fn_log" {
  count = var.fixedNumberOfMediaNodes > 0 ? 0 : 1

  display_name = "${var.stackName}-scalein-fn-log"
  log_group_id = oci_logging_log_group.scale_in_log_group[0].id
  log_type     = "SERVICE"

  configuration {
    source {
      category    = "invoke"
      resource    = oci_functions_application.scale_in_app[0].id
      service     = "functions"
      source_type = "OCISERVICE"
    }
    compartment_id = var.compartment_ocid
  }

  is_enabled         = true
  retention_duration = 30
}

# ------------------------- Network Load Balancer (HA entry point) -------------------------
#
# OCI NLB (layer-4 TCP passthrough) in front of the 4 masters. Listeners:
#   - TCP 443  -> backends 443  (HTTPS/WSS, terminated by Caddy on each master)
#   - TCP 80   -> backends 80   (HTTP, Let's Encrypt + redirect to HTTPS)
#   - TCP 1935 -> backends 1935 (RTMP ingress)
# Health check is TCP 7880 (LiveKit /health/caddy, internal-only). Backend policy
# FIVE_TUPLE for connection consistency. Media UDP does NOT traverse this NLB —
# clients hit media nodes directly on UDP ports.

# NSG for the NLB's own VNIC. Without it the NLB inherits only the subnet SL
# (VCN-only ingress) and silently drops all inbound internet traffic on
# 80/443/1935 — unreachable from outside, and Let's Encrypt can't reach Caddy for
# the ACME challenge ("Timeout during connect"). OCI UNIONs SLs and NSGs, so this
# only ADDS public ingress; intra-VCN traffic (health checks, backend forwarding)
# still works via the SL. Master/media VNICs have their own NSGs; the NLB needed
# its own — that was what was missing.
resource "oci_core_network_security_group" "nlb_nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.openvidu_vcn.id
  display_name   = "${var.stackName}-nlb-nsg"
}

resource "oci_core_network_security_group_security_rule" "nlb_internet_ingress" {
  for_each                  = local.nlb_ingress_tcp
  network_security_group_id = oci_core_network_security_group.nlb_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "NLB ${each.value.label}"
  tcp_options {
    destination_port_range {
      min = each.value.min
      max = each.value.max
    }
  }
}

# Stateful NSGs auto-allow return traffic, but the NLB also originates
# health-check probes to masters (TCP 7880); allow all egress so they're never blocked.
resource "oci_core_network_security_group_security_rule" "nlb_egress" {
  network_security_group_id = oci_core_network_security_group.nlb_nsg.id
  direction                 = "EGRESS"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  protocol                  = "all"
}

resource "oci_network_load_balancer_network_load_balancer" "openvidu_nlb" {
  compartment_id                 = var.compartment_ocid
  display_name                   = "${var.stackName}-nlb"
  subnet_id                      = oci_core_subnet.openvidu_subnet.id
  is_private                     = false
  is_preserve_source_destination = false
  network_security_group_ids     = [oci_core_network_security_group.nlb_nsg.id]

  # Attach the user's reserved public IP OCID if supplied; otherwise OCI
  # allocates a new one automatically.
  dynamic "reserved_ips" {
    for_each = var.publicIpAddress != "" ? [var.publicIpAddress] : []
    content {
      id = reserved_ips.value
    }
  }
}

locals {
  # Master-terminated ports reachable through the NLB. The NLB does dest-NAT to
  # the BACKEND port, so each listener needs its OWN same-port backend set — a
  # shared 443 backend set would wrongly forward 80 and 1935 to 443.
  nlb_ports = [80, 443, 1935]

  master_private_ips = {
    for key in ["1", "2", "3", "4"] :
    key => oci_core_instance.openvidu_master_node[key].private_ip
  }

  # One backend per (port, master): {"80-1" = {port=80, node="1"}, ...}
  nlb_backends = {
    for pair in setproduct(local.nlb_ports, keys(local.master_private_ips)) :
    "${pair[0]}-${pair[1]}" => { port = pair[0], node = pair[1] }
  }
}

# One backend set per exposed port. Health check is the masters' LiveKit/Caddy
# endpoint on TCP 7880 — healthy there means it's serving 80/443/1935.
resource "oci_network_load_balancer_backend_set" "master" {
  for_each = toset([for p in local.nlb_ports : tostring(p)])

  name                     = "master-backend-set-${each.key}"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.openvidu_nlb.id
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = false

  health_checker {
    protocol           = "TCP"
    port               = 7880
    interval_in_millis = 10000
    retries            = 3
    timeout_in_millis  = 3000
  }
}

# 4 masters × 3 ports = 12 backends, each on its matching backend port.
resource "oci_network_load_balancer_backend" "master" {
  for_each = local.nlb_backends

  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.openvidu_nlb.id
  backend_set_name         = oci_network_load_balancer_backend_set.master[tostring(each.value.port)].name
  name                     = "master-${each.value.node}-${each.value.port}"
  ip_address               = local.master_private_ips[each.value.node]
  port                     = each.value.port
}

# Listeners forward each port to the same-port backend set: 80 (HTTP/ACME +
# redirect), 443 (HTTPS/WSS via Caddy), 1935 (RTMP ingress).
resource "oci_network_load_balancer_listener" "master" {
  for_each = toset([for p in local.nlb_ports : tostring(p)])

  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.openvidu_nlb.id
  name                     = "listener-${each.key}"
  default_backend_set_name = oci_network_load_balancer_backend_set.master[each.key].name
  port                     = tonumber(each.key)
  protocol                 = "TCP"
}

locals {
  # NLB public IP (the HA entry point), used to derive a sslip.io domain when no
  # domain is given. OCI returns `ip_addresses` as a list; the public one has
  # `is_public = true`.
  nlb_ip_address = one([for ip in oci_network_load_balancer_network_load_balancer.openvidu_nlb.ip_addresses : ip.ip_address if ip.is_public])
  domain_name    = var.domainName != "" ? var.domainName : "openvidu-${random_string.domain_suffix.result}-${replace(local.nlb_ip_address, ".", "-")}.sslip.io"

  # OCI ARM (Ampere) shapes use "VM.Standard.A" / "BM.Standard.A" prefixes; all
  # others (VM.Standard.E*, VM.Standard3/2, BM.Standard2...) are x86.
  is_arm_instance = startswith(var.masterNodeShape, "VM.Standard.A") || startswith(var.masterNodeShape, "BM.Standard.A")
  yq_arch         = local.is_arm_instance ? "arm64" : "amd64"
  yq_sha256       = local.is_arm_instance ? "10a4a2093090363a00b55ad52e132a082f9652970cb8f1ad35a1ae048b917e6e" : "3fa3c1c32d94520102ea4d853d03c3ab907867d964540e896410ad8a7fc6c8f7"

  # Common OCI Vault helpers (single source of truth for retry, query
  # sanitization, and vault read/write), sourced by store_secret /
  # update_config_from_secret / update_secret_from_config.
  oci_helpers_script = <<-EOF
#!/bin/bash
# Common OCI Vault helpers. Callers must set VAULT_ID and COMPARTMENT_ID before
# sourcing; KEY_ID is needed only when creating new secrets via store_in_vault.
#
# We own retry rather than the OCI CLI default: the default can spin ~10 min on
# 429/5xx and stack under our own retry, causing 20-30 min install hangs.

# Per-attempt wall-clock cap. Vault ops finish in <5s; longer means the API or
# auth layer is wedged — kill and let oci_with_retry decide.
: "$${OCI_CALL_TIMEOUT:=45}"

oci_with_retry() {
  # Default 6 attempts (5+10+20+40+80s ≈ 155s budget) to outlast first-boot OCI
  # Vault/KMS eventual-consistency (~70s when re-saving just-created secrets).
  # Overridable via OCI_MAX_ATTEMPTS.
  local max_attempts="$${OCI_MAX_ATTEMPTS:-6}"
  local attempt=0
  local delay=5
  local stderr_file
  stderr_file=$(mktemp)
  while true; do
    attempt=$((attempt + 1))
    if output=$(timeout "$OCI_CALL_TIMEOUT" "$@" 2>"$stderr_file"); then
      rm -f "$stderr_file"
      echo "$output"
      return 0
    fi
    if [[ $attempt -ge $max_attempts ]]; then
      cat "$stderr_file" >&2
      rm -f "$stderr_file"
      return 1
    fi
    echo "[oci-helpers] OCI API call failed (attempt $attempt/$max_attempts), retrying in $${delay}s..." >&2
    sleep "$delay"
    delay=$((delay * 2))
  done
}

# OCI CLI --raw-output prints "Query returned empty result..." to stdout instead
# of an empty string when JMESPath matches nothing. Filter it so callers can
# test with [[ -z ]].
ocid_from_query() {
  local result
  result=$("$@")
  if [[ "$result" == *"Query returned empty result"* || "$result" == "null" ]]; then
    echo ""
  else
    echo "$result"
  fi
}

# Read an ACTIVE secret by name. Decoded value to stdout; non-zero if not found
# (so `$(get_from_vault X)` callers see empty + nonzero).
get_from_vault() {
  local secret_name="$1"
  local secret_id
  secret_id=$(ocid_from_query oci_with_retry oci vault secret list \
    --compartment-id "$COMPARTMENT_ID" \
    --vault-id "$VAULT_ID" \
    --all \
    --query "data[?\"secret-name\"=='$secret_name' && \"lifecycle-state\"=='ACTIVE'].id | [0]" \
    --raw-output \
    --auth instance_principal)
  if [[ -z "$secret_id" ]]; then
    echo "[oci-helpers] Secret '$secret_name' not found in vault" >&2
    return 1
  fi
  oci_with_retry oci secrets secret-bundle get \
    --secret-id "$secret_id" \
    --query 'data."secret-bundle-content".content' \
    --raw-output \
    --auth instance_principal | base64 -d
}

# Store or update a secret in the vault.
# Fast path: ACTIVE → update (no cancel-secret-deletion per call, to stay under
# the 30/min vault rate limit). PENDING_DELETION fallback recovers from manual
# schedule-deletion or external tooling. Create requires KEY_ID.
store_in_vault() {
  local secret_name="$1"
  local secret_value="$2"
  local encoded_value
  encoded_value=$(echo -n "$secret_value" | base64)

  local secret_id

  secret_id=$(ocid_from_query oci_with_retry oci vault secret list \
    --compartment-id "$COMPARTMENT_ID" \
    --vault-id "$VAULT_ID" \
    --all \
    --query "data[?\"secret-name\"=='$secret_name' && \"lifecycle-state\"=='ACTIVE'].id | [0]" \
    --raw-output \
    --auth instance_principal)

  if [[ -n "$secret_id" ]]; then
    # Skip if unchanged — each update adds a version and OCI caps secrets at 30.
    local current
    current=$(oci_with_retry oci secrets secret-bundle get \
      --secret-id "$secret_id" \
      --query 'data."secret-bundle-content".content' \
      --raw-output \
      --auth instance_principal 2>/dev/null | base64 -d 2>/dev/null)
    if [[ "$current" == "$secret_value" ]]; then
      return 0
    fi
    oci_with_retry oci vault secret update-base64 \
      --secret-id "$secret_id" \
      --secret-content-content "$encoded_value" \
      --enable-auto-generation false \
      --auth instance_principal > /dev/null
    return
  fi

  # PENDING_DELETION fallback — recover a secret a prior cleanup/destroy scheduled
  # for deletion. cancel-secret-deletion flips lifecycle-state to ACTIVE on the
  # control plane WELL BEFORE the secret is actually writable: an update-base64
  # fired too soon returns 409 IncorrectState (KMS/Vault eventual consistency).
  # On bootstrap (store_secret.sh) any failure here kills cloud-init, so we must
  # (1) poll until it reports ACTIVE, (2) refuse to update while it is not, and
  # (3) let it SETTLE before the version write.
  secret_id=$(ocid_from_query oci_with_retry oci vault secret list \
    --compartment-id "$COMPARTMENT_ID" \
    --vault-id "$VAULT_ID" \
    --all \
    --query "data[?\"secret-name\"=='$secret_name' && \"lifecycle-state\"=='PENDING_DELETION'].id | [0]" \
    --raw-output \
    --auth instance_principal)

  if [[ -n "$secret_id" ]]; then
    oci_with_retry oci vault secret cancel-secret-deletion \
      --secret-id "$secret_id" \
      --auth instance_principal > /dev/null
    # Wait for ACTIVE (cancel + CANCELLING_DELETION can take a while). Generous
    # ceiling (40 x 3s = 120s); do NOT fall through to update while non-ACTIVE.
    local i state=""
    for i in $(seq 1 40); do
      state=$(oci_with_retry oci vault secret get \
        --secret-id "$secret_id" \
        --query 'data."lifecycle-state"' \
        --raw-output \
        --auth instance_principal 2>/dev/null || echo "")
      [[ "$state" == "ACTIVE" ]] && break
      sleep 3
    done
    if [[ "$state" != "ACTIVE" ]]; then
      echo "[oci-helpers] '$secret_name' still '$state' after cancel-deletion wait; not updating (will retry next start)" >&2
      return 1
    fi
    # ACTIVE on the API != immediately writable. Let the data plane settle before
    # the version write so update-base64 doesn't race a stale-PENDING 409.
    sleep "$${VAULT_SETTLE_SECONDS:-30}"
    oci_with_retry oci vault secret update-base64 \
      --secret-id "$secret_id" \
      --secret-content-content "$encoded_value" \
      --enable-auto-generation false \
      --auth instance_principal > /dev/null
    return
  fi

  if [[ -z "$${KEY_ID:-}" ]]; then
    echo "[oci-helpers] Cannot create '$secret_name': KEY_ID not set" >&2
    return 1
  fi
  oci_with_retry oci vault secret create-base64 \
    --compartment-id "$COMPARTMENT_ID" \
    --secret-name "$secret_name" \
    --vault-id "$VAULT_ID" \
    --key-id "$KEY_ID" \
    --secret-content-content "$encoded_value" \
    --secret-content-name "$secret_name" \
    --auth instance_principal > /dev/null
}
EOF

  # get_master_tag.sh — runtime read of config that depends on
  # fixedNumberOfMediaNodes. The master carries scale-in-mode / scale-in-fn-id as
  # freeform tags (updated in place on toggle). Media nodes query them via OCI
  # API rather than baking into user_data — that would force
  # instance_configuration replacement on every toggle and 409 (pool still refs it).
  get_master_tag_script = <<-EOF
#!/bin/bash
# Read a freeform tag from this stack's master node.
# Usage: $0 <tag-name>
# stdout: tag value (empty string if not found or API failure).

set -u
source /etc/openvidu/predrain.conf

export HOME="/root"
export PATH="$PATH:/root/.local/bin"

TAG_NAME="$${1:-}"
[ -z "$TAG_NAME" ] && { echo "Usage: $0 <tag-name>" >&2; exit 1; }

oci compute instance list \
  --compartment-id "$COMPARTMENT_ID" \
  --lifecycle-state RUNNING \
  --auth instance_principal \
  --all --output json 2>/dev/null \
  | jq -r --arg s "$STACK_NAME" --arg t "$TAG_NAME" \
    '.data[]
     | select(
         .["freeform-tags"]["stack"] == $s and
         .["freeform-tags"]["node-type"] == "master"
       )
     | .["freeform-tags"][$t] // empty' 2>/dev/null \
  | head -1
EOF

  # Pre-drain daemon: polls pool membership every 30s; when this instance is no
  # longer in the pool (detached by func.py on scale-in), calls graceful_shutdown.sh.
  pre_drain_daemon_script = <<-EOF
#!/bin/bash
# OpenVidu Pre-drain Daemon for OCI
# Detect that the scale-in OCI Function detached this instance from the pool and
# call graceful_shutdown.sh. Scale-in decisions are owned by func.py — this
# daemon only reacts.

source /etc/openvidu/predrain.conf

# OCI CLI is in /root/.local/bin (pipx); systemd doesn't set HOME
export HOME="/root"
export PATH="$PATH:/root/.local/bin"

log() { echo "[openvidu-predrain $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" >&2; }

# Drain lock present → daemon restarted mid-drain; wait for self-termination
if [ -f "/var/run/openvidu-drain.lock" ]; then
    log "Drain lock exists — drain already in progress. Waiting for self-termination."
    while true; do sleep 60; done
fi

INSTANCE_OCID=$(curl -sf -H "Authorization: Bearer Oracle" \
    "http://169.254.169.254/opc/v2/instance/" | jq -r '.id')
log "Started. Instance: $INSTANCE_OCID"

# Discover pool OCID once at startup by exact display-name match.
POOL_ID=""
while [ -z "$POOL_ID" ]; do
    POOL_ID=$(oci compute-management instance-pool list \
        --compartment-id "$COMPARTMENT_ID" \
        --lifecycle-state RUNNING \
        --auth instance_principal \
        --all \
        --output json 2>/dev/null \
        | jq -r --arg n "$POOL_DISPLAY_NAME" \
            '.data[] | select(."display-name" == $n) | .id' \
        | head -1) || true
    if [ -z "$POOL_ID" ]; then
        log "Pool '$POOL_DISPLAY_NAME' not found. Retrying in 30s..."
        sleep 30
    fi
done
log "Pool discovered: $POOL_ID"

# Poll every 30s: still a pool member? When func.py detaches this instance
# (is_decrement_size=True) it drops from the member list — our drain signal.
#
# Fixed mode has no scale-in function / detach events, so skip the check. Mode is
# re-read every iteration so a Terraform toggle takes effect without a daemon
# restart (worst case ~1 min of staleness).
while true; do
    MODE=$(/usr/local/bin/get_master_tag.sh scale-in-mode 2>/dev/null || echo "")
    if [ "$MODE" = "fixed" ]; then
        sleep 60
        continue
    fi

    IN_POOL=$(oci compute-management instance-pool list-instances \
        --compartment-id "$COMPARTMENT_ID" \
        --instance-pool-id "$POOL_ID" \
        --auth instance_principal \
        --all \
        --output json 2>/dev/null \
        | jq -r --arg id "$INSTANCE_OCID" \
            '[.data[] | select(.id == $id)] | length' 2>/dev/null) || IN_POOL="1"

    if [ "$IN_POOL" = "0" ]; then
        log "Instance no longer in pool — calling graceful shutdown."
        exec /usr/local/bin/graceful_shutdown.sh
    fi

    sleep 30
done
EOF

  # invoke_terminate.py — calls the scale-in function with a terminate_instance_id
  # payload via the OCI SDK directly.
  #
  # Why not `oci fn function invoke --body ...`: OCI CLI 3.83 does NOT reliably
  # ship the --body content — the function receives an empty/unparseable body
  # (verified in fn logs) and takes the scale-in branch instead of terminate. The
  # Python SDK passes the body as raw bytes with no shell/CLI layer in between.
  #
  # Runs under the pipx OCI CLI venv's Python, which already has the oci SDK.
  invoke_terminate_script = <<-PYEOF
#!/root/.local/share/pipx/venvs/oci-cli/bin/python
"""Invoke the scale-in function with a {"terminate_instance_id": "<ocid>"}
body. Uses Instance Principal auth (works on any compartment member node).

The function OCID is resolved at runtime from the master node's scale-in-fn-id
freeform tag (via get_master_tag.sh). Embedding the OCID would force
oci_core_instance_configuration replacement on every fixedNumberOfMediaNodes
toggle, which OCI rejects with 409 while the pool still references it."""
import json
import subprocess
import sys

import oci


def get_fn_id() -> str:
    try:
        result = subprocess.run(
            ["/usr/local/bin/get_master_tag.sh", "scale-in-fn-id"],
            capture_output=True,
            text=True,
            timeout=30,
        )
        return result.stdout.strip()
    except Exception as exc:
        print(f"[invoke_terminate] failed to resolve fn id: {exc}", file=sys.stderr)
        return ""


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: invoke_terminate.py <instance_ocid>", file=sys.stderr)
        return 2
    instance_ocid = sys.argv[1]

    fn_id = get_fn_id()
    if not fn_id:
        print("[invoke_terminate] No scale-in function configured (fixed mode or master unreachable).", file=sys.stderr)
        return 1

    signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
    mgmt = oci.functions.FunctionsManagementClient(config={}, signer=signer)
    fn = mgmt.get_function(function_id=fn_id).data
    invoke = oci.functions.FunctionsInvokeClient(
        config={}, signer=signer, service_endpoint=fn.invoke_endpoint
    )

    body = json.dumps({"terminate_instance_id": instance_ocid}).encode()
    print(f"[invoke_terminate] body={body!r}", file=sys.stderr)

    result = invoke.invoke_function(function_id=fn_id, invoke_function_body=body)

    # result.data is a urllib3 response stream
    try:
        text = result.data.text
    except AttributeError:
        try:
            text = result.data.content.decode("utf-8", errors="replace")
        except AttributeError:
            text = str(result.data)
    print(f"[invoke_terminate] response={text}", file=sys.stderr)
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF

  # graceful_shutdown.sh — drain+terminate, called from two paths:
  #   1. openvidu-pre-drain.service: pool detach detected
  #   2. graceful_shutdown.service: ACPI shutdown (e.g. manual console terminate)
  # A lock file prevents double execution if both fire at once.
  graceful_shutdown_script = <<-EOF
#!/bin/bash
# Graceful shutdown for OpenVidu Media Node (OCI). Called by the pre-drain daemon
# (pool detach) and the systemd fallback (ACPI shutdown); both drain + self-terminate.

export HOME="/root"
export PATH="$PATH:/root/.local/bin"

DRAIN_LOCK="/var/run/openvidu-drain.lock"

if [ -f "$DRAIN_LOCK" ]; then
    echo "[graceful-shutdown] Drain already in progress. Exiting."
    exit 0
fi
touch "$DRAIN_LOCK"

echo "[graceful-shutdown] Starting graceful shutdown..."

# Step 1: SIGQUIT — stop accepting new sessions
if command -v docker &>/dev/null; then
    docker container kill --signal=SIGQUIT openvidu 2>/dev/null || true
    docker container kill --signal=SIGQUIT ingress 2>/dev/null || true
    docker container kill --signal=SIGQUIT egress 2>/dev/null || true
    for agent in $(docker ps --filter "label=openvidu-agent=true" --format '{{.Names}}' 2>/dev/null); do
        docker container kill --signal=SIGQUIT "$agent" 2>/dev/null || true
    done

    # Step 2: Wait for all containers to finish (no time limit)
    while [ "$(docker ps --filter 'label=openvidu-agent=true' -q 2>/dev/null | wc -l)" -gt 0 ] || \
          [ "$(docker inspect -f '{{.State.Running}}' openvidu 2>/dev/null)" = "true" ] || \
          [ "$(docker inspect -f '{{.State.Running}}' ingress 2>/dev/null)" = "true" ] || \
          [ "$(docker inspect -f '{{.State.Running}}' egress 2>/dev/null)" = "true" ]; do
        echo "[graceful-shutdown] Waiting for containers to stop..."
        sleep 10
    done
fi

echo "[graceful-shutdown] All containers stopped."

# Fixed mode has no scale-in function — drain is done, let OCI/ACPI terminate. If
# the mode is undetermined (master unreachable / transient), default to elastic:
# the function call retries and self-corrects once the master is reachable.
MODE=$(/usr/local/bin/get_master_tag.sh scale-in-mode 2>/dev/null || echo "")
if [ "$MODE" = "fixed" ]; then
    echo "[graceful-shutdown] Fixed mode — drain complete, exiting."
    exit 0
fi

# Step 3: Request termination via OCI Function (Resource Principal).
# Direct instance_principal terminate is blocked by a tenancy-level deny; the
# scale-in function's Resource Principal isn't subject to it and can call
# TerminateInstance on our behalf.
INSTANCE_OCID=$(curl -sf -H "Authorization: Bearer Oracle" \
    "http://169.254.169.254/opc/v2/instance/" | jq -r '.id')
echo "[graceful-shutdown] Instance OCID: $INSTANCE_OCID. Self-terminating via function..."

attempt=0
while true; do
    attempt=$((attempt + 1))
    echo "[graceful-shutdown] Terminate via function, attempt $attempt..."
    # Uses the Python SDK (see invoke_terminate.py) to bypass
    # `oci fn function invoke --body ...`, which doesn't reliably deliver the
    # JSON body in CLI 3.83.
    if /usr/local/bin/invoke_terminate.py "$INSTANCE_OCID"; then
        echo "[graceful-shutdown] Terminate request accepted on attempt $attempt. Waiting for OCI to terminate."
        while true; do sleep 60; done
    else
        echo "[graceful-shutdown] Attempt $attempt failed. Retrying in 15s..."
        sleep 15
    fi
done
EOF

  config_s3_script = <<-EOF
#!/bin/bash -x
set -e

INSTALL_DIR="/opt/openvidu"
CLUSTER_CONFIG_DIR="$${INSTALL_DIR}/config/cluster"

# OCI Object Storage S3 compatibility endpoint
EXTERNAL_S3_ENDPOINT="https://${data.oci_objectstorage_namespace.ns.namespace}.compat.objectstorage.${var.region}.oraclecloud.com"
EXTERNAL_S3_REGION="${var.region}"
EXTERNAL_S3_PATH_STYLE_ACCESS="true"
EXTERNAL_S3_BUCKET_APP_DATA="${local.bucket_app_data_name}"
EXTERNAL_S3_BUCKET_CLUSTER_DATA="${local.bucket_cluster_data_name}"

# S3 credentials: this deployment's Customer Secret Key (from Terraform)
EXTERNAL_S3_ACCESS_KEY="${oci_identity_customer_secret_key.openvidu_s3_key.id}"
EXTERNAL_S3_SECRET_KEY="${oci_identity_customer_secret_key.openvidu_s3_key.key}"

sed -i "s|EXTERNAL_S3_ENDPOINT=.*|EXTERNAL_S3_ENDPOINT=$EXTERNAL_S3_ENDPOINT|" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s|EXTERNAL_S3_REGION=.*|EXTERNAL_S3_REGION=$EXTERNAL_S3_REGION|" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s|EXTERNAL_S3_PATH_STYLE_ACCESS=.*|EXTERNAL_S3_PATH_STYLE_ACCESS=$EXTERNAL_S3_PATH_STYLE_ACCESS|" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s|EXTERNAL_S3_BUCKET_APP_DATA=.*|EXTERNAL_S3_BUCKET_APP_DATA=$EXTERNAL_S3_BUCKET_APP_DATA|" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s|EXTERNAL_S3_BUCKET_CLUSTER_DATA=.*|EXTERNAL_S3_BUCKET_CLUSTER_DATA=$EXTERNAL_S3_BUCKET_CLUSTER_DATA|" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s|EXTERNAL_S3_ACCESS_KEY=.*|EXTERNAL_S3_ACCESS_KEY=$EXTERNAL_S3_ACCESS_KEY|" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s|EXTERNAL_S3_SECRET_KEY=.*|EXTERNAL_S3_SECRET_KEY=$EXTERNAL_S3_SECRET_KEY|" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
EOF

  install_script_master = <<-EOF
#!/bin/bash -x
set -e

OPENVIDU_VERSION=main
DOMAIN=
YQ_VERSION=v4.52.4
echo "DPkg::Lock::Timeout \"-1\";" > /etc/apt/apt.conf.d/99timeout

apt-get update && apt-get install -y \
  curl \
  unzip \
  jq \
  wget \
  ca-certificates \
  gnupg \
  lsb-release \
  openssl \
  firewalld

# Apply firewall rules
systemctl enable firewalld
systemctl start firewalld

iptables -F
iptables -P INPUT ACCEPT
systemctl disable netfilter-persistent 2>/dev/null || true

## Allow all intra-VCN traffic (NSGs handle fine-grained control)
firewall-cmd --add-source=10.0.0.0/16 --zone=trusted
firewall-cmd --permanent --add-source=10.0.0.0/16 --zone=trusted

## Master internet-facing ports (HA also exposes 7880 internally for NLB health check)
firewall-cmd --add-port=22/tcp
firewall-cmd --permanent --add-port=22/tcp

firewall-cmd --add-port=80/tcp
firewall-cmd --permanent --add-port=80/tcp

firewall-cmd --add-port=443/tcp
firewall-cmd --permanent --add-port=443/tcp

firewall-cmd --add-port=1935/tcp
firewall-cmd --permanent --add-port=1935/tcp

firewall-cmd --add-port=7880/tcp
firewall-cmd --permanent --add-port=7880/tcp

firewall-cmd --add-port=9000/tcp
firewall-cmd --permanent --add-port=9000/tcp

## Apply rules
firewall-cmd --reload
firewall-cmd --runtime-to-permanent

firewall-cmd --list-all

wget -q "https://github.com/mikefarah/yq/releases/download/$${YQ_VERSION}/yq_linux_${local.yq_arch}.tar.gz" -O /tmp/yq.tar.gz
echo "${local.yq_sha256}  /tmp/yq.tar.gz" | sha256sum -c -
tar xz -f /tmp/yq.tar.gz -C /tmp && mv "/tmp/yq_linux_${local.yq_arch}" /usr/bin/yq
rm -f /tmp/yq.tar.gz

# Make OCI CLI available (installed via pipx under /root/.local/bin)
export HOME="/root"
export PATH="$PATH:$HOME/.local/bin"

# Create counter file for tracking script executions
echo 1 > /usr/local/bin/openvidu_install_counter.txt

# ============================================================================
# HA bootstrap coordination
# ============================================================================
# Each master gets identity (1..4) from IMDS metadata.masterNodeNum. Master #1
# generates+stores all cluster secrets; 2..4 wait. All 4 register their private
# IP under MASTER_NODE_{N}_PRIVATE_IP and block until all 4 are present before
# running install_ov_master_node.sh with --master-node-private-ip-list.
#
# Coordination is stamped with the per-deployment token (DEPLOY_GEN, from IMDS
# metadata.deploymentGeneration): ALL_SECRETS_GENERATED holds the token (not
# "true") and each MASTER_NODE_N_PRIVATE_IP holds "<token>|<ip>". On a RECYCLED
# vault, previous-deployment values carry a different token and are ignored — so
# a follower never reads a stale "ready" flag and no master picks up a dead IP.
# ============================================================================

get_meta() { curl -sf -H "Authorization: Bearer Oracle" "http://169.254.169.254/opc/v2/instance/$1"; }
MASTER_NODE_NUM=$(get_meta "" | jq -r '.metadata.masterNodeNum // "1"')
echo "[ha-bootstrap] This is master #$MASTER_NODE_NUM"

# Per-deployment token (from Terraform via IMDS metadata, NOT the vault). Stamps
# coordination secrets so a RECYCLED vault's stale (previous-token) values are
# ignored, not raced on.
DEPLOY_GEN=$(get_meta "" | jq -r '.metadata.deploymentGeneration // empty')
echo "[ha-bootstrap] Deployment generation: $DEPLOY_GEN"

# Own private IP (from the VNIC, fallback to hostname -I)
PRIVATE_IP=$(curl -sf -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/vnics/ | jq -r '.[0].privateIp // empty' 2>/dev/null)
[ -z "$PRIVATE_IP" ] && PRIVATE_IP=$(hostname -I | awk '{print $1}')

# Register own IP up front, stamped "<deployment_gen>|<ip>" so the loop below can
# tell THIS deployment's IPs from a recycled vault's stale ones. All 4 do this so
# the loop converges even if one races ahead.
/usr/local/bin/store_secret.sh save "MASTER_NODE_$${MASTER_NODE_NUM}_PRIVATE_IP" "$DEPLOY_GEN|$PRIVATE_IP" >/dev/null

if [[ "$MASTER_NODE_NUM" == "1" ]]; then
  # ----- BOOTSTRAP PATH: master #1 generates the shared cluster secrets -----
  echo "[ha-bootstrap] Master #1 — generating cluster secrets."

  # Mark not-ready first so previous-deployment media nodes don't read stale
  # values pointing to dead masters.
  /usr/local/bin/store_secret.sh save ALL_SECRETS_GENERATED "false" >/dev/null

  # Domain: var.domainName if set, else derived at Terraform time from the NLB
  # public IP (the HA entry point).
  if [[ "${var.domainName}" == "" ]]; then
    DOMAIN="${local.domain_name}"
  else
    DOMAIN="${var.domainName}"
  fi
  DOMAIN="$(/usr/local/bin/store_secret.sh save DOMAIN_NAME "$DOMAIN")"

  # Meet initial admin user and password
  MEET_INITIAL_ADMIN_USER="$(/usr/local/bin/store_secret.sh save MEET_INITIAL_ADMIN_USER "admin")"
  if [[ "${var.initialMeetAdminPassword}" != '' ]]; then
    MEET_INITIAL_ADMIN_PASSWORD="$(/usr/local/bin/store_secret.sh save MEET_INITIAL_ADMIN_PASSWORD "${var.initialMeetAdminPassword}")"
  else
    MEET_INITIAL_ADMIN_PASSWORD="$(/usr/local/bin/store_secret.sh generate MEET_INITIAL_ADMIN_PASSWORD)"
  fi
  if [[ "${var.initialMeetApiKey}" != '' ]]; then
    MEET_INITIAL_API_KEY="$(/usr/local/bin/store_secret.sh save MEET_INITIAL_API_KEY "${var.initialMeetApiKey}")"
  fi

  REDIS_PASSWORD="$(/usr/local/bin/store_secret.sh generate REDIS_PASSWORD)"
  MONGO_ADMIN_USERNAME="$(/usr/local/bin/store_secret.sh save MONGO_ADMIN_USERNAME "mongoadmin")"
  MONGO_ADMIN_PASSWORD="$(/usr/local/bin/store_secret.sh generate MONGO_ADMIN_PASSWORD)"
  MONGO_REPLICA_SET_KEY="$(/usr/local/bin/store_secret.sh generate MONGO_REPLICA_SET_KEY)"
  DASHBOARD_ADMIN_USERNAME="$(/usr/local/bin/store_secret.sh save DASHBOARD_ADMIN_USERNAME "dashboardadmin")"
  DASHBOARD_ADMIN_PASSWORD="$(/usr/local/bin/store_secret.sh generate DASHBOARD_ADMIN_PASSWORD)"
  GRAFANA_ADMIN_USERNAME="$(/usr/local/bin/store_secret.sh save GRAFANA_ADMIN_USERNAME "grafanaadmin")"
  GRAFANA_ADMIN_PASSWORD="$(/usr/local/bin/store_secret.sh generate GRAFANA_ADMIN_PASSWORD)"
  ENABLED_MODULES="$(/usr/local/bin/store_secret.sh save ENABLED_MODULES "observability,openviduMeet,v2compatibility")"
  LIVEKIT_API_KEY="$(/usr/local/bin/store_secret.sh generate LIVEKIT_API_KEY "API" 12)"
  LIVEKIT_API_SECRET="$(/usr/local/bin/store_secret.sh generate LIVEKIT_API_SECRET)"

  OPENVIDU_PRO_LICENSE="$(/usr/local/bin/store_secret.sh save OPENVIDU_PRO_LICENSE "${var.openviduLicense}")"
  OPENVIDU_RTC_ENGINE="$(/usr/local/bin/store_secret.sh save OPENVIDU_RTC_ENGINE "${var.rtcEngine}")"
  OPENVIDU_VERSION="$(/usr/local/bin/store_secret.sh save OPENVIDU_VERSION "$OPENVIDU_VERSION")"

  # Signal readiness with the deployment token (not a bare "true") so a recycled
  # vault's stale ALL_SECRETS_GENERATED can't be mistaken for ours.
  /usr/local/bin/store_secret.sh save ALL_SECRETS_GENERATED "$DEPLOY_GEN" >/dev/null
  echo "[ha-bootstrap] Master #1 finished writing cluster secrets."

else
  # ----- FOLLOWER PATH: wait for master #1 to publish the secrets -----
  echo "[ha-bootstrap] Master #$MASTER_NODE_NUM — waiting for master #1 to publish generation $DEPLOY_GEN..."
  for i in $(seq 1 360); do
    state=$(/usr/local/bin/store_secret.sh get ALL_SECRETS_GENERATED 2>/dev/null || echo "")
    if [[ "$state" == "$DEPLOY_GEN" ]]; then
      echo "[ha-bootstrap] Secrets ready after $${i} polls."
      break
    fi
    sleep 10
  done
  if [[ "$state" != "$DEPLOY_GEN" ]]; then
    echo "[ha-bootstrap] Timeout waiting for ALL_SECRETS_GENERATED=$DEPLOY_GEN (got '$state')" >&2
    exit 1
  fi

  DOMAIN="$(/usr/local/bin/store_secret.sh get DOMAIN_NAME)"
  REDIS_PASSWORD="$(/usr/local/bin/store_secret.sh get REDIS_PASSWORD)"
  MONGO_ADMIN_USERNAME="$(/usr/local/bin/store_secret.sh get MONGO_ADMIN_USERNAME)"
  MONGO_ADMIN_PASSWORD="$(/usr/local/bin/store_secret.sh get MONGO_ADMIN_PASSWORD)"
  MONGO_REPLICA_SET_KEY="$(/usr/local/bin/store_secret.sh get MONGO_REPLICA_SET_KEY)"
  DASHBOARD_ADMIN_USERNAME="$(/usr/local/bin/store_secret.sh get DASHBOARD_ADMIN_USERNAME)"
  DASHBOARD_ADMIN_PASSWORD="$(/usr/local/bin/store_secret.sh get DASHBOARD_ADMIN_PASSWORD)"
  GRAFANA_ADMIN_USERNAME="$(/usr/local/bin/store_secret.sh get GRAFANA_ADMIN_USERNAME)"
  GRAFANA_ADMIN_PASSWORD="$(/usr/local/bin/store_secret.sh get GRAFANA_ADMIN_PASSWORD)"
  ENABLED_MODULES="$(/usr/local/bin/store_secret.sh get ENABLED_MODULES)"
  LIVEKIT_API_KEY="$(/usr/local/bin/store_secret.sh get LIVEKIT_API_KEY)"
  LIVEKIT_API_SECRET="$(/usr/local/bin/store_secret.sh get LIVEKIT_API_SECRET)"
  MEET_INITIAL_ADMIN_USER="$(/usr/local/bin/store_secret.sh get MEET_INITIAL_ADMIN_USER)"
  MEET_INITIAL_ADMIN_PASSWORD="$(/usr/local/bin/store_secret.sh get MEET_INITIAL_ADMIN_PASSWORD)"
  if [[ "${var.initialMeetApiKey}" != '' ]]; then
    MEET_INITIAL_API_KEY="$(/usr/local/bin/store_secret.sh get MEET_INITIAL_API_KEY)"
  fi
  OPENVIDU_PRO_LICENSE="$(/usr/local/bin/store_secret.sh get OPENVIDU_PRO_LICENSE)"
  OPENVIDU_RTC_ENGINE="$(/usr/local/bin/store_secret.sh get OPENVIDU_RTC_ENGINE)"
  OPENVIDU_VERSION="$(/usr/local/bin/store_secret.sh get OPENVIDU_VERSION)"
fi

# All 4 masters: wait for every MASTER_NODE_N_PRIVATE_IP registered BY THIS
# deployment. Each value is "<deployment_gen>|<ip>"; on a recycled vault stale
# entries carry a previous generation (or old plain-IP format), so get_fresh_ip
# returns "" for anything not stamped with OUR DEPLOY_GEN. This keeps the "all 4
# non-empty" guard correct: no master picks up a dead leftover IP before the real
# one registers.
get_fresh_ip() {
  local raw gen ip
  raw=$(/usr/local/bin/store_secret.sh get "MASTER_NODE_$1_PRIVATE_IP" 2>/dev/null || echo "")
  IFS='|' read -r gen ip <<< "$raw"
  if [[ "$gen" == "$DEPLOY_GEN" && -n "$ip" ]]; then echo "$ip"; else echo ""; fi
}
echo "[ha-bootstrap] Waiting for all 4 master IPs (generation $DEPLOY_GEN) to be registered..."
for i in $(seq 1 360); do
  IP1=$(get_fresh_ip 1)
  IP2=$(get_fresh_ip 2)
  IP3=$(get_fresh_ip 3)
  IP4=$(get_fresh_ip 4)
  if [[ -n "$IP1" && -n "$IP2" && -n "$IP3" && -n "$IP4" ]]; then
    echo "[ha-bootstrap] All 4 master IPs ready: $IP1, $IP2, $IP3, $IP4"
    break
  fi
  sleep 10
done
if [[ -z "$IP1" || -z "$IP2" || -z "$IP3" || -z "$IP4" ]]; then
  echo "[ha-bootstrap] Timeout waiting for all master IPs (got: 1=$IP1, 2=$IP2, 3=$IP3, 4=$IP4)" >&2
  exit 1
fi
MASTER_NODE_PRIVATE_IP_LIST="$IP1,$IP2,$IP3,$IP4"

# Build install command for HA master node
INSTALL_COMMAND="sh <(curl -fsSL http://get.openvidu.io/pro/ha/$OPENVIDU_VERSION/install_ov_master_node.sh)"

COMMON_ARGS=(
  "--no-tty"
  "--install"
  "--environment=oracle"
  "--deployment-type=ha"
  "--node-role=master-node"
  "--external-load-balancer"
  "--internal-tls-termination"
  "--master-node-private-ip-list=$MASTER_NODE_PRIVATE_IP_LIST"
  "--openvidu-pro-license=$OPENVIDU_PRO_LICENSE"
  "--domain-name=$DOMAIN"
  "--enabled-modules='$ENABLED_MODULES'"
  "--rtc-engine=$OPENVIDU_RTC_ENGINE"
  "--redis-password=$REDIS_PASSWORD"
  "--mongo-admin-user=$MONGO_ADMIN_USERNAME"
  "--mongo-admin-password=$MONGO_ADMIN_PASSWORD"
  "--mongo-replica-set-key=$MONGO_REPLICA_SET_KEY"
  "--dashboard-admin-user=$DASHBOARD_ADMIN_USERNAME"
  "--dashboard-admin-password=$DASHBOARD_ADMIN_PASSWORD"
  "--grafana-admin-user=$GRAFANA_ADMIN_USERNAME"
  "--grafana-admin-password=$GRAFANA_ADMIN_PASSWORD"
  "--meet-initial-admin-password=$MEET_INITIAL_ADMIN_PASSWORD"
  "--livekit-api-key=$LIVEKIT_API_KEY"
  "--livekit-api-secret=$LIVEKIT_API_SECRET"
)

# Only pass --meet-initial-api-key when set; an empty value would null out the
# installer default.
if [[ "${var.initialMeetApiKey}" != '' ]]; then
  COMMON_ARGS+=("--meet-initial-api-key=$MEET_INITIAL_API_KEY")
fi

# Include additional installer flags provided by the user
if [[ "${var.additionalInstallFlags}" != "" ]]; then
  IFS=',' read -ra EXTRA_FLAGS <<< "${var.additionalInstallFlags}"
  for extra_flag in "$${EXTRA_FLAGS[@]}"; do
    extra_flag="$(echo -e "$${extra_flag}" | sed -e 's/^[ \t]*//' -e 's/[ \t]*$//')"
    if [[ "$extra_flag" != "" ]]; then
      COMMON_ARGS+=("$extra_flag")
    fi
  done
fi

# Certificate arguments
if [[ "${var.certificateType}" == "selfsigned" ]]; then
  CERT_ARGS=("--certificate-type=selfsigned")
elif [[ "${var.certificateType}" == "letsencrypt" ]]; then
  CERT_ARGS=("--certificate-type=letsencrypt")
else
  OWN_CERT_CRT=${var.ownPublicCertificate}
  OWN_CERT_KEY=${var.ownPrivateCertificate}
  CERT_ARGS=(
    "--certificate-type=owncert"
    "--owncert-public-key=$OWN_CERT_CRT"
    "--owncert-private-key=$OWN_CERT_KEY"
  )
fi

FINAL_COMMAND="$INSTALL_COMMAND $(printf "%s " "$${COMMON_ARGS[@]}") $(printf "%s " "$${CERT_ARGS[@]}")"
exec bash -c "$FINAL_COMMAND"
EOF

  after_install_script = <<-EOF
#!/bin/bash
set -e

export HOME="/root"
export PATH="$PATH:$HOME/.local/bin"

# Only master #1 writes the shared URL secrets.
MASTER_NODE_NUM=$(curl -sf -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/ | jq -r '.metadata.masterNodeNum // empty')
[[ "$MASTER_NODE_NUM" == "1" ]] || { echo "[after_install] not master #1 (num='$MASTER_NODE_NUM'); skipping shared URL secrets"; exit 0; }

# Generate URLs
DOMAIN="$(/usr/local/bin/store_secret.sh get DOMAIN_NAME)"
OPENVIDU_URL="https://$${DOMAIN}/"
LIVEKIT_URL="wss://$${DOMAIN}/"
DASHBOARD_URL="https://$${DOMAIN}/dashboard/"
GRAFANA_URL="https://$${DOMAIN}/grafana/"

/usr/local/bin/store_secret.sh save OPENVIDU_URL "$OPENVIDU_URL"
/usr/local/bin/store_secret.sh save LIVEKIT_URL "$LIVEKIT_URL"
/usr/local/bin/store_secret.sh save DASHBOARD_URL "$DASHBOARD_URL"
/usr/local/bin/store_secret.sh save GRAFANA_URL "$GRAFANA_URL"
EOF

  update_config_from_secret_script = <<-EOF
#!/bin/bash -x
set -e

export HOME="/root"
export PATH="$PATH:$HOME/.local/bin"
export OCI_CLI_DISABLE_DEFAULT_RETRY=True

VAULT_ID="${local.vault_id}"
KEY_ID="${local.key_id}"
COMPARTMENT_ID="${var.compartment_ocid}"

# shellcheck source=/dev/null
. /usr/local/bin/oci_helpers.sh

INSTALL_DIR="/opt/openvidu"
CLUSTER_CONFIG_DIR="$${INSTALL_DIR}/config/cluster"
MASTER_NODE_CONFIG_DIR="$${INSTALL_DIR}/config/node"

export DOMAIN=$(get_from_vault DOMAIN_NAME)
[[ -n "$DOMAIN" ]] || exit 1
sed -i "s/DOMAIN_NAME=.*/DOMAIN_NAME=$DOMAIN/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"

export REDIS_PASSWORD=$(get_from_vault REDIS_PASSWORD)
export OPENVIDU_RTC_ENGINE=$(get_from_vault OPENVIDU_RTC_ENGINE)
export OPENVIDU_PRO_LICENSE=$(get_from_vault OPENVIDU_PRO_LICENSE)
export MONGO_ADMIN_USERNAME=$(get_from_vault MONGO_ADMIN_USERNAME)
export MONGO_ADMIN_PASSWORD=$(get_from_vault MONGO_ADMIN_PASSWORD)
export MONGO_REPLICA_SET_KEY=$(get_from_vault MONGO_REPLICA_SET_KEY)
export DASHBOARD_ADMIN_USERNAME=$(get_from_vault DASHBOARD_ADMIN_USERNAME)
export DASHBOARD_ADMIN_PASSWORD=$(get_from_vault DASHBOARD_ADMIN_PASSWORD)
export GRAFANA_ADMIN_USERNAME=$(get_from_vault GRAFANA_ADMIN_USERNAME)
export GRAFANA_ADMIN_PASSWORD=$(get_from_vault GRAFANA_ADMIN_PASSWORD)
export LIVEKIT_API_KEY=$(get_from_vault LIVEKIT_API_KEY)
export LIVEKIT_API_SECRET=$(get_from_vault LIVEKIT_API_SECRET)
export MEET_INITIAL_ADMIN_USER=$(get_from_vault MEET_INITIAL_ADMIN_USER)
export MEET_INITIAL_ADMIN_PASSWORD=$(get_from_vault MEET_INITIAL_ADMIN_PASSWORD)
if [[ "${var.initialMeetApiKey}" != '' ]]; then
  export MEET_INITIAL_API_KEY=$(get_from_vault MEET_INITIAL_API_KEY)
fi
export ENABLED_MODULES=$(get_from_vault ENABLED_MODULES)

sed -i "s/REDIS_PASSWORD=.*/REDIS_PASSWORD=$REDIS_PASSWORD/" "$${MASTER_NODE_CONFIG_DIR}/master_node.env"
sed -i "s/OPENVIDU_RTC_ENGINE=.*/OPENVIDU_RTC_ENGINE=$OPENVIDU_RTC_ENGINE/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s/OPENVIDU_PRO_LICENSE=.*/OPENVIDU_PRO_LICENSE=$OPENVIDU_PRO_LICENSE/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s/MONGO_ADMIN_USERNAME=.*/MONGO_ADMIN_USERNAME=$MONGO_ADMIN_USERNAME/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s/MONGO_ADMIN_PASSWORD=.*/MONGO_ADMIN_PASSWORD=$MONGO_ADMIN_PASSWORD/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s/MONGO_REPLICA_SET_KEY=.*/MONGO_REPLICA_SET_KEY=$MONGO_REPLICA_SET_KEY/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s/DASHBOARD_ADMIN_USERNAME=.*/DASHBOARD_ADMIN_USERNAME=$DASHBOARD_ADMIN_USERNAME/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s/DASHBOARD_ADMIN_PASSWORD=.*/DASHBOARD_ADMIN_PASSWORD=$DASHBOARD_ADMIN_PASSWORD/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s/GRAFANA_ADMIN_USERNAME=.*/GRAFANA_ADMIN_USERNAME=$GRAFANA_ADMIN_USERNAME/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s/GRAFANA_ADMIN_PASSWORD=.*/GRAFANA_ADMIN_PASSWORD=$GRAFANA_ADMIN_PASSWORD/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s/LIVEKIT_API_KEY=.*/LIVEKIT_API_KEY=$LIVEKIT_API_KEY/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s/LIVEKIT_API_SECRET=.*/LIVEKIT_API_SECRET=$LIVEKIT_API_SECRET/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s/MEET_INITIAL_ADMIN_USER=.*/MEET_INITIAL_ADMIN_USER=$MEET_INITIAL_ADMIN_USER/" "$${CLUSTER_CONFIG_DIR}/master_node/meet.env"
sed -i "s/MEET_INITIAL_ADMIN_PASSWORD=.*/MEET_INITIAL_ADMIN_PASSWORD=$MEET_INITIAL_ADMIN_PASSWORD/" "$${CLUSTER_CONFIG_DIR}/master_node/meet.env"
if [[ "${var.initialMeetApiKey}" != '' ]]; then
  sed -i "s/MEET_INITIAL_API_KEY=.*/MEET_INITIAL_API_KEY=$MEET_INITIAL_API_KEY/" "$${CLUSTER_CONFIG_DIR}/master_node/meet.env"
fi
sed -i "s/ENABLED_MODULES=.*/ENABLED_MODULES=$ENABLED_MODULES/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"

# Refresh URL secrets
OPENVIDU_URL="https://$${DOMAIN}/"
LIVEKIT_URL="wss://$${DOMAIN}/"
DASHBOARD_URL="https://$${DOMAIN}/dashboard/"
GRAFANA_URL="https://$${DOMAIN}/grafana/"
store_in_vault DOMAIN_NAME "$DOMAIN"
store_in_vault OPENVIDU_URL "$OPENVIDU_URL"
store_in_vault LIVEKIT_URL "$LIVEKIT_URL"
store_in_vault DASHBOARD_URL "$DASHBOARD_URL"
store_in_vault GRAFANA_URL "$GRAFANA_URL"
EOF

  update_secret_from_config_script = <<-EOF
#!/bin/bash -x
# openvidu.service ExecStartPre. Best-effort (no 'set -e'): a failed write can't abort start.
set +e

export HOME="/root"
export PATH="$PATH:$HOME/.local/bin"
export OCI_CLI_DISABLE_DEFAULT_RETRY=True

# Only master #1 writes (OCI Vault rejects concurrent updates).
MASTER_NODE_NUM=$(curl -sf -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/ | jq -r '.metadata.masterNodeNum // empty')
[[ "$MASTER_NODE_NUM" == "1" ]] || { echo "[update_secret_from_config] not master #1 (num='$MASTER_NODE_NUM'); skipping vault writes"; exit 0; }

VAULT_ID="${local.vault_id}"
KEY_ID="${local.key_id}"
COMPARTMENT_ID="${var.compartment_ocid}"

# shellcheck source=/dev/null
. /usr/local/bin/oci_helpers.sh

INSTALL_DIR="/opt/openvidu"
CLUSTER_CONFIG_DIR="$${INSTALL_DIR}/config/cluster"
MASTER_NODE_CONFIG_DIR="$${INSTALL_DIR}/config/node"

# Skip writes when the config has no real value — otherwise an unset/commented
# key gets persisted to vault as the literal "" or "none", corrupting the secret.
maybe_save() {
  local key="$1"
  local value="$2"
  if [[ -z "$value" || "$value" == "none" ]]; then
    echo "[update_secret_from_config] Skipping '$key': empty value in config" >&2
    return 0
  fi
  if ! store_in_vault "$key" "$value"; then
    echo "[update_secret_from_config] WARNING: could not save '$key' to vault (transient OCI eventual-consistency?); keeping existing value, will retry on next start" >&2
  fi
  return 0
}

REDIS_PASSWORD="$(/usr/local/bin/get_value_from_config.sh REDIS_PASSWORD "$${MASTER_NODE_CONFIG_DIR}/master_node.env")"
DOMAIN_NAME="$(/usr/local/bin/get_value_from_config.sh DOMAIN_NAME "$${CLUSTER_CONFIG_DIR}/openvidu.env")"
OPENVIDU_RTC_ENGINE="$(/usr/local/bin/get_value_from_config.sh OPENVIDU_RTC_ENGINE "$${CLUSTER_CONFIG_DIR}/openvidu.env")"
OPENVIDU_PRO_LICENSE="$(/usr/local/bin/get_value_from_config.sh OPENVIDU_PRO_LICENSE "$${CLUSTER_CONFIG_DIR}/openvidu.env")"
MONGO_ADMIN_USERNAME="$(/usr/local/bin/get_value_from_config.sh MONGO_ADMIN_USERNAME "$${CLUSTER_CONFIG_DIR}/openvidu.env")"
MONGO_ADMIN_PASSWORD="$(/usr/local/bin/get_value_from_config.sh MONGO_ADMIN_PASSWORD "$${CLUSTER_CONFIG_DIR}/openvidu.env")"
MONGO_REPLICA_SET_KEY="$(/usr/local/bin/get_value_from_config.sh MONGO_REPLICA_SET_KEY "$${CLUSTER_CONFIG_DIR}/openvidu.env")"
DASHBOARD_ADMIN_USERNAME="$(/usr/local/bin/get_value_from_config.sh DASHBOARD_ADMIN_USERNAME "$${CLUSTER_CONFIG_DIR}/openvidu.env")"
DASHBOARD_ADMIN_PASSWORD="$(/usr/local/bin/get_value_from_config.sh DASHBOARD_ADMIN_PASSWORD "$${CLUSTER_CONFIG_DIR}/openvidu.env")"
GRAFANA_ADMIN_USERNAME="$(/usr/local/bin/get_value_from_config.sh GRAFANA_ADMIN_USERNAME "$${CLUSTER_CONFIG_DIR}/openvidu.env")"
GRAFANA_ADMIN_PASSWORD="$(/usr/local/bin/get_value_from_config.sh GRAFANA_ADMIN_PASSWORD "$${CLUSTER_CONFIG_DIR}/openvidu.env")"
LIVEKIT_API_KEY="$(/usr/local/bin/get_value_from_config.sh LIVEKIT_API_KEY "$${CLUSTER_CONFIG_DIR}/openvidu.env")"
LIVEKIT_API_SECRET="$(/usr/local/bin/get_value_from_config.sh LIVEKIT_API_SECRET "$${CLUSTER_CONFIG_DIR}/openvidu.env")"
MEET_INITIAL_ADMIN_USER="$(/usr/local/bin/get_value_from_config.sh MEET_INITIAL_ADMIN_USER "$${CLUSTER_CONFIG_DIR}/master_node/meet.env")"
MEET_INITIAL_ADMIN_PASSWORD="$(/usr/local/bin/get_value_from_config.sh MEET_INITIAL_ADMIN_PASSWORD "$${CLUSTER_CONFIG_DIR}/master_node/meet.env")"
if [[ "${var.initialMeetApiKey}" != '' ]]; then
  MEET_INITIAL_API_KEY="$(/usr/local/bin/get_value_from_config.sh MEET_INITIAL_API_KEY "$${CLUSTER_CONFIG_DIR}/master_node/meet.env")"
fi
ENABLED_MODULES="$(/usr/local/bin/get_value_from_config.sh ENABLED_MODULES "$${CLUSTER_CONFIG_DIR}/openvidu.env")"

maybe_save REDIS_PASSWORD "$REDIS_PASSWORD"
maybe_save DOMAIN_NAME "$DOMAIN_NAME"
maybe_save OPENVIDU_RTC_ENGINE "$OPENVIDU_RTC_ENGINE"
maybe_save OPENVIDU_PRO_LICENSE "$OPENVIDU_PRO_LICENSE"
maybe_save MONGO_ADMIN_USERNAME "$MONGO_ADMIN_USERNAME"
maybe_save MONGO_ADMIN_PASSWORD "$MONGO_ADMIN_PASSWORD"
maybe_save MONGO_REPLICA_SET_KEY "$MONGO_REPLICA_SET_KEY"
maybe_save DASHBOARD_ADMIN_USERNAME "$DASHBOARD_ADMIN_USERNAME"
maybe_save DASHBOARD_ADMIN_PASSWORD "$DASHBOARD_ADMIN_PASSWORD"
maybe_save GRAFANA_ADMIN_USERNAME "$GRAFANA_ADMIN_USERNAME"
maybe_save GRAFANA_ADMIN_PASSWORD "$GRAFANA_ADMIN_PASSWORD"
maybe_save LIVEKIT_API_KEY "$LIVEKIT_API_KEY"
maybe_save LIVEKIT_API_SECRET "$LIVEKIT_API_SECRET"
maybe_save MEET_INITIAL_ADMIN_USER "$MEET_INITIAL_ADMIN_USER"
maybe_save MEET_INITIAL_ADMIN_PASSWORD "$MEET_INITIAL_ADMIN_PASSWORD"
if [[ "${var.initialMeetApiKey}" != '' ]]; then
  maybe_save MEET_INITIAL_API_KEY "$MEET_INITIAL_API_KEY"
fi
maybe_save ENABLED_MODULES "$ENABLED_MODULES"
EOF

  get_value_from_config_script = <<-EOF
#!/bin/bash
set -e

get_value() {
    local key="$1"
    local file_path="$2"
    local value=$(grep -E "^\s*$key\s*=" "$file_path" | awk -F= '{print $2}' | sed 's/#.*//; s/^\s*//; s/\s*$//')
    if [ -z "$value" ]; then echo "none"; else echo "$value"; fi
}

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <key> <file_path>"
    exit 1
fi
get_value "$1" "$2"
EOF

  store_secret_script = <<-EOF
#!/bin/bash
set -e

export HOME="/root"
export PATH="$PATH:$HOME/.local/bin"
export OCI_CLI_DISABLE_DEFAULT_RETRY=True

VAULT_ID="${local.vault_id}"
KEY_ID="${local.key_id}"
COMPARTMENT_ID="${var.compartment_ocid}"

# shellcheck source=/dev/null
. /usr/local/bin/oci_helpers.sh

MODE="$1"
if [[ "$MODE" == "generate" ]]; then
  SECRET_KEY_NAME="$2"
  PREFIX="$${3:-}"
  LENGTH="$${4:-44}"
  RANDOM_PASSWORD="$(openssl rand -base64 64 | tr -d '+/=\n' | cut -c -$${LENGTH})"
  RANDOM_PASSWORD="$${PREFIX}$${RANDOM_PASSWORD}"
  store_in_vault "$SECRET_KEY_NAME" "$RANDOM_PASSWORD"
  echo "$RANDOM_PASSWORD"
elif [[ "$MODE" == "save" ]]; then
  SECRET_KEY_NAME="$2"
  SECRET_VALUE="$3"
  store_in_vault "$SECRET_KEY_NAME" "$SECRET_VALUE"
  echo "$SECRET_VALUE"
elif [[ "$MODE" == "get" ]]; then
  SECRET_KEY_NAME="$2"
  get_from_vault "$SECRET_KEY_NAME"
else
  echo "Usage: $0 {generate|save|get} SECRET_NAME [VALUE|PREFIX] [LENGTH]" >&2
  exit 1
fi
EOF

  check_app_ready_script = <<-EOF
#!/bin/bash
# Poll OpenVidu's health endpoint until 200, then exit (final blocking cloud-init
# step, so "cloud-init done" == app healthy). Poll-only, like the GCP/DO HA
# references: recovery is owned by systemd (openvidu.service Restart=always), so
# NO restart logic here — an in-script restart while the HA cluster forms risks
# the restart storm that kept the replica set from converging.
while true; do
  HTTP_STATUS=$(curl -Ik http://localhost:7880/health/caddy 2>/dev/null | head -n1 | awk '{print $2}')
  if [ "$HTTP_STATUS" == "200" ]; then
    break
  fi
  sleep 5
done
EOF

  restart_script = <<-EOF
#!/bin/bash -x
set -e

export HOME="/root"
export PATH="$PATH:$HOME/.local/bin"

# Stop all services
systemctl stop openvidu

# Update config from secrets
/usr/local/bin/update_config_from_secret.sh

# Start all services
systemctl start openvidu
EOF

  user_data_master = <<-EOF
#!/bin/bash -x
set -eu -o pipefail

# restart.sh
cat > /usr/local/bin/restart.sh << 'RESTART_EOF'
${local.restart_script}
RESTART_EOF
chmod +x /usr/local/bin/restart.sh

# Installation already done? (reboot path)
if [ -f /usr/local/bin/openvidu_install_counter.txt ]; then
  /usr/local/bin/restart.sh || { echo "[OpenVidu] error restarting OpenVidu"; exit 1; }
else
  # install.sh
  cat > /usr/local/bin/install.sh << 'INSTALL_EOF'
${local.install_script_master}
INSTALL_EOF
  chmod +x /usr/local/bin/install.sh

  # after_install.sh
  cat > /usr/local/bin/after_install.sh << 'AFTER_INSTALL_EOF'
${local.after_install_script}
AFTER_INSTALL_EOF
  chmod +x /usr/local/bin/after_install.sh

  # oci_helpers.sh — must come BEFORE the scripts that source it
  cat > /usr/local/bin/oci_helpers.sh << 'OCI_HELPERS_EOF'
${local.oci_helpers_script}
OCI_HELPERS_EOF
  chmod +x /usr/local/bin/oci_helpers.sh

  # update_config_from_secret.sh
  cat > /usr/local/bin/update_config_from_secret.sh << 'UPDATE_CONFIG_EOF'
${local.update_config_from_secret_script}
UPDATE_CONFIG_EOF
  chmod +x /usr/local/bin/update_config_from_secret.sh

  # update_secret_from_config.sh
  cat > /usr/local/bin/update_secret_from_config.sh << 'UPDATE_SECRET_EOF'
${local.update_secret_from_config_script}
UPDATE_SECRET_EOF
  chmod +x /usr/local/bin/update_secret_from_config.sh

  # get_value_from_config.sh
  cat > /usr/local/bin/get_value_from_config.sh << 'GET_VALUE_EOF'
${local.get_value_from_config_script}
GET_VALUE_EOF
  chmod +x /usr/local/bin/get_value_from_config.sh

  # store_secret.sh
  cat > /usr/local/bin/store_secret.sh << 'STORE_SECRET_EOF'
${local.store_secret_script}
STORE_SECRET_EOF
  chmod +x /usr/local/bin/store_secret.sh

  # check_app_ready.sh
  cat > /usr/local/bin/check_app_ready.sh << 'CHECK_APP_EOF'
${local.check_app_ready_script}
CHECK_APP_EOF
  chmod +x /usr/local/bin/check_app_ready.sh

  # config_s3.sh
  cat > /usr/local/bin/config_s3.sh << 'CONFIG_S3_EOF'
${local.config_s3_script}
CONFIG_S3_EOF
  chmod +x /usr/local/bin/config_s3.sh

  echo "DPkg::Lock::Timeout \"-1\";" > /etc/apt/apt.conf.d/99timeout
  apt-get update && apt-get install -y \
    curl \
    jq \
    wget \
    ca-certificates \
    gnupg \
    lsb-release \
    openssl \
    pipx

  # Install OCI CLI via pipx (correct method on modern Ubuntu)
  export HOME="/root"
  OCI_CLI_VERSION="3.83.0"
  pipx install oci-cli==$${OCI_CLI_VERSION}
  export PATH="$PATH:$HOME/.local/bin"

  # Install OpenVidu
  /usr/local/bin/install.sh || { echo "[OpenVidu] error installing OpenVidu"; exit 1; }

  # Configure S3 bucket
  /usr/local/bin/config_s3.sh || { echo "[OpenVidu] error configuring S3 bucket"; exit 1; }

  # Raise start timeout (installer default 90s too tight while the cluster forms).
  mkdir -p /etc/systemd/system/openvidu.service.d
  printf '[Service]\nTimeoutStartSec=300\n' > /etc/systemd/system/openvidu.service.d/10-start-timeout.conf
  systemctl daemon-reload

  # Start OpenVidu. NON-FATAL (cluster forms over minutes; Restart=always retries).
  systemctl start openvidu || echo "[OpenVidu] initial start not healthy yet (cluster still forming); continuing"

  # Shared URL secrets. NON-FATAL; after_install.sh self-gates to master #1.
  /usr/local/bin/after_install.sh || echo "[OpenVidu] after_install did not complete (transient OCI Vault read); non-fatal, reconciles on restart"

  # Scale-in invoker (cron on all 4 masters). An atomic Object Storage lock
  # (scalein.lock, ETag CAS) ensures only one master invokes per cycle — no OCI
  # Vault writes, so it never burns secret versions.
  cat > /usr/local/bin/invoke_scalein.sh << 'INVOKE_EOF'
#!/bin/bash
set -e
export HOME="/root"
export PATH="$PATH:/root/.local/bin"
export OCI_CLI_DISABLE_DEFAULT_RETRY=True

NS="${data.oci_objectstorage_namespace.ns.namespace}"
BUCKET="${local.bucket_cluster_data_name}"
LOCK_OBJ="scalein.lock"
LOCK_TTL=180  # 3 min — must be < 5 min cron interval so an idle master can grab it next cycle

META=$(curl -sf -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/) || exit 0
MODE=$(echo "$META" | jq -r '.freeformTags["scale-in-mode"] // empty')
FN_ID=$(echo "$META" | jq -r '.freeformTags["scale-in-fn-id"] // empty')
MY_ID=$(echo "$META" | jq -r '.id')

# Fixed-mode deployments have no scale-in function — exit quietly.
[ "$MODE" = "fixed" ] && exit 0
[ -z "$FN_ID" ] && exit 0

# ---- Distributed lock in Object Storage (pre-created by Terraform) ----
# Read the lock + ETag, then claim by overwriting with --if-match: an atomic CAS
# that fails (412) if another master claimed it since our read.
NOW=$(date +%s)
LOCK_TMP=$(mktemp)
if ! oci os object get --namespace "$NS" --bucket-name "$BUCKET" --name "$LOCK_OBJ" --file "$LOCK_TMP" --auth instance_principal 2>/dev/null; then
  echo "[scalein-lock] lock object unreadable; skipping."; rm -f "$LOCK_TMP"; exit 0
fi
ETAG=$(oci os object head --namespace "$NS" --bucket-name "$BUCKET" --name "$LOCK_OBJ" --auth instance_principal 2>/dev/null | jq -r '.etag // empty')
EXPIRES=$(jq -r '.expires_at // 0' "$LOCK_TMP" 2>/dev/null || echo 0)
HOLDER=$(jq -r '.holder // empty' "$LOCK_TMP" 2>/dev/null || echo "")
rm -f "$LOCK_TMP"

if [ "$NOW" -lt "$EXPIRES" ] && [ "$HOLDER" != "$MY_ID" ]; then
  echo "[scalein-lock] Held by $HOLDER until $EXPIRES (now $NOW). Skipping."
  exit 0
fi
[ -z "$ETAG" ] && { echo "[scalein-lock] no ETag; skipping."; exit 0; }

printf '{"holder":"%s","expires_at":%s}' "$MY_ID" "$((NOW + LOCK_TTL))" > /tmp/scalein-lock.json
if ! oci os object put --namespace "$NS" --bucket-name "$BUCKET" --name "$LOCK_OBJ" \
    --file /tmp/scalein-lock.json --content-type application/json --if-match "$ETAG" --force \
    --auth instance_principal 2>/dev/null; then
  echo "[scalein-lock] Lost the race (ETag changed). Skipping."
  exit 0
fi

echo "[scalein-lock] Acquired lock, invoking scale-in function."
oci fn function invoke \
  --function-id "$FN_ID" \
  --fn-invoke-type sync \
  --file /dev/stdout \
  --body '' \
  --auth instance_principal
INVOKE_EOF
  chmod +x /usr/local/bin/invoke_scalein.sh

  # Create boot volume cleanup script
  cat > /usr/local/bin/cleanup_boot_volumes.sh << 'CLEANUP_EOF'
#!/bin/bash
export HOME="/root"
export PATH="$PATH:/root/.local/bin"
COMPARTMENT_ID="${var.compartment_ocid}"
POOL_PREFIX="${var.stackName}-media-pool"
oci bv boot-volume list \
  --compartment-id "$COMPARTMENT_ID" \
  --all --output json \
  --auth instance_principal \
  2>/dev/null \
| jq -r --arg p "$POOL_PREFIX" \
    '.data[] | select(."lifecycle-state" == "AVAILABLE" and (."display-name" | contains($p))) | .id' \
| while read -r BV_ID; do
    ATTACHED=$(oci compute boot-volume-attachment list \
      --compartment-id "$COMPARTMENT_ID" \
      --boot-volume-id "$BV_ID" \
      --output json \
      --auth instance_principal \
      2>/dev/null \
      | jq '[.data[] | select(."lifecycle-state" != "DETACHED" and ."lifecycle-state" != "DETACHING")] | length')
    if [ "$ATTACHED" = "0" ]; then
      echo "[cleanup-bv] Deleting orphaned boot volume $BV_ID..."
      oci bv boot-volume delete \
        --boot-volume-id "$BV_ID" \
        --force \
        --auth instance_principal \
        2>/dev/null || true
    fi
  done
CLEANUP_EOF
  chmod +x /usr/local/bin/cleanup_boot_volumes.sh

  # Cron: restart on reboot; scale-in every 5 min (no-op in fixed mode and on
  # masters that don't win the lock — gated in-script); boot-volume cleanup every 5 min.
  { \
    echo "@reboot /usr/local/bin/restart.sh >> /var/log/openvidu-restart.log 2>&1"; \
    echo "*/5 * * * * /usr/local/bin/invoke_scalein.sh >> /var/log/openvidu-scalein.log 2>&1"; \
    echo "*/5 * * * * /usr/local/bin/cleanup_boot_volumes.sh >> /var/log/openvidu-cleanup-bv.log 2>&1"; \
  } | crontab

  # Mark installation as complete
  echo "installation_complete" > /usr/local/bin/openvidu_install_counter.txt
fi

# Wait for the app to be ready
/usr/local/bin/check_app_ready.sh
EOF

  install_script_media = <<-EOF
#!/bin/bash -x
set -e

echo "DPkg::Lock::Timeout \"-1\";" > /etc/apt/apt.conf.d/99timeout

apt-get update && apt-get install -y \
  curl \
  unzip \
  jq \
  wget \
  ca-certificates \
  gnupg \
  lsb-release \
  openssl \
  firewalld

# Apply firewall rules
systemctl enable firewalld
systemctl start firewalld

iptables -F
iptables -P INPUT ACCEPT
systemctl disable netfilter-persistent 2>/dev/null || true

## Allow all intra-VCN traffic (NSGs handle fine-grained control)
firewall-cmd --add-source=10.0.0.0/16 --zone=trusted
firewall-cmd --permanent --add-source=10.0.0.0/16 --zone=trusted

## Media internet-facing ports
firewall-cmd --add-port=22/tcp
firewall-cmd --permanent --add-port=22/tcp

firewall-cmd --add-port=7881/tcp
firewall-cmd --permanent --add-port=7881/tcp

firewall-cmd --add-port=7880/tcp
firewall-cmd --permanent --add-port=7880/tcp

firewall-cmd --add-port=50000-60000/tcp
firewall-cmd --permanent --add-port=50000-60000/tcp

firewall-cmd --add-port=443/udp
firewall-cmd --permanent --add-port=443/udp

firewall-cmd --add-port=7885/udp
firewall-cmd --permanent --add-port=7885/udp

firewall-cmd --add-port=50000-60000/udp
firewall-cmd --permanent --add-port=50000-60000/udp

## Apply rules
firewall-cmd --reload
firewall-cmd --runtime-to-permanent

firewall-cmd --list-all

# Make OCI CLI available (installed via pipx under /root/.local/bin)
export HOME="/root"
export PATH="$PATH:$HOME/.local/bin"

# Get metadata via OCI IMDS v2
get_meta() { curl -sf -H "Authorization: Bearer Oracle" "http://169.254.169.254/opc/v2/instance/$1"; }

MASTER_NODE_PRIVATE_IP_LIST=$(get_meta "" | jq -r '.metadata.masterNodePrivateIPList // empty')
DEPLOY_GEN=$(get_meta "" | jq -r '.metadata.deploymentGeneration // empty')
PRIVATE_IP=$(curl -sf -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/vnics/ | jq -r '.[0].privateIp // empty' 2>/dev/null)
[ -z "$PRIVATE_IP" ] && PRIVATE_IP=$(hostname -I | awk '{print $1}')

# Run an OCI CLI command with retry on transient errors
oci_with_retry() {
  local max_attempts=5
  local attempt=0
  local delay=10
  local stderr_file
  stderr_file=$(mktemp)
  while true; do
    attempt=$((attempt + 1))
    if output=$("$@" 2>"$stderr_file"); then
      rm -f "$stderr_file"
      echo "$output"
      return 0
    fi
    if [[ $attempt -ge $max_attempts ]]; then
      cat "$stderr_file" >&2
      rm -f "$stderr_file"
      return 1
    fi
    echo "[get_secret] OCI API call failed (attempt $attempt/$max_attempts), retrying in $${delay}s..." >&2
    sleep "$delay"
    delay=$((delay * 2))
  done
}

ocid_from_query() {
  local result
  result=$("$@")
  if [[ "$result" == *"Query returned empty result"* || "$result" == "null" ]]; then
    echo ""
  else
    echo "$result"
  fi
}

# Read a secret from OCI Vault via Instance Principal
get_secret() {
  local secret_name="$1"
  local secret_id
  secret_id=$(ocid_from_query oci_with_retry oci vault secret list \
    --compartment-id "${var.compartment_ocid}" \
    --vault-id "${local.vault_id}" \
    --all \
    --query "data[?\"secret-name\"=='$secret_name' && \"lifecycle-state\"=='ACTIVE'].id | [0]" \
    --raw-output \
    --auth instance_principal)
  oci_with_retry oci secrets secret-bundle get \
    --secret-id "$secret_id" \
    --query 'data."secret-bundle-content".content' \
    --raw-output \
    --auth instance_principal | base64 -d
}

# Wait for the master to finish writing all secrets FOR THIS deployment. Gate on
# the deployment token (not "true") so a recycled vault's stale
# ALL_SECRETS_GENERATED isn't mistaken for ours.
until [[ "$(get_secret ALL_SECRETS_GENERATED 2>/dev/null)" == "$DEPLOY_GEN" ]]; do
  echo "Waiting for master node to initialize secrets (generation $DEPLOY_GEN)..."
  sleep 10
done

DOMAIN=$(get_secret DOMAIN_NAME)
OPENVIDU_PRO_LICENSE=$(get_secret OPENVIDU_PRO_LICENSE)
REDIS_PASSWORD=$(get_secret REDIS_PASSWORD)
OPENVIDU_VERSION=$(get_secret OPENVIDU_VERSION)

if [[ -z "$OPENVIDU_VERSION" || "$OPENVIDU_VERSION" == "none" ]]; then
  echo "OpenVidu version not found in secrets"
  exit 1
fi

# Build install command for HA media node
INSTALL_COMMAND="sh <(curl -fsSL http://get.openvidu.io/pro/ha/$OPENVIDU_VERSION/install_ov_media_node.sh)"

COMMON_ARGS=(
  "--no-tty"
  "--install"
  "--environment=oracle"
  "--deployment-type=ha"
  "--node-role=media-node"
  "--master-node-private-ip-list=$MASTER_NODE_PRIVATE_IP_LIST"
  "--private-ip=$PRIVATE_IP"
  "--redis-password=$REDIS_PASSWORD"
)

FINAL_COMMAND="$INSTALL_COMMAND $(printf "%s " "$${COMMON_ARGS[@]}")"
exec bash -c "$FINAL_COMMAND"
EOF

  user_data_media = <<-EOF
#!/bin/bash -x
set -eu -o pipefail

echo "DPkg::Lock::Timeout \"-1\";" > /etc/apt/apt.conf.d/99timeout
apt-get update && apt-get install -y \
  curl \
  jq \
  wget \
  ca-certificates \
  gnupg \
  lsb-release \
  openssl \
  pipx

# Install OCI CLI via pipx — required by install script and pre-drain daemon
export HOME="/root"
OCI_CLI_VERSION="3.83.0"
pipx install oci-cli==$${OCI_CLI_VERSION}
export PATH="$PATH:$HOME/.local/bin"

# Write pre-drain config (Terraform bakes in values at deploy time).
# STACK_NAME lets get_master_tag.sh find the master by freeform tag.
mkdir -p /etc/openvidu
cat > /etc/openvidu/predrain.conf << 'CONF_EOF'
COMPARTMENT_ID=${var.compartment_ocid}
POOL_DISPLAY_NAME=${var.stackName}-media-pool
STACK_NAME=${var.stackName}
CONF_EOF

# install.sh
cat > /usr/local/bin/install.sh << 'INSTALL_EOF'
${local.install_script_media}
INSTALL_EOF
chmod +x /usr/local/bin/install.sh

# get_master_tag.sh — runtime resolver for the master's scale-in-* freeform tags.
# Used by the pre-drain daemon, graceful_shutdown.sh, and invoke_terminate.py to
# tell if scale-in is active without baking values into user_data.
cat > /usr/local/bin/get_master_tag.sh << 'GET_MASTER_TAG_EOF'
${local.get_master_tag_script}
GET_MASTER_TAG_EOF
chmod +x /usr/local/bin/get_master_tag.sh

# ------------------------- Graceful Drain Setup (two-layer approach) -------------------------
# Layer 1 — Pre-drain daemon (primary): on scale-in it detaches itself from the
#   pool (target -1, no replacement), drains with no time limit, then
#   self-terminates. OCI's 15-min ACPI timeout never applies — the instance is
#   outside the pool while draining.
# Layer 2 — Systemd shutdown service (fallback): catches the rare ACPI shutdown
#   that arrives before the daemon completes; blocks poweroff until drain finishes.
#
# Both layers are ALWAYS installed regardless of fixedNumberOfMediaNodes; they
# self-gate at runtime via the master's scale-in-mode tag (get_master_tag.sh) — in
# fixed mode the daemon idles and graceful_shutdown skips the function call.
# Baking the toggle into user_data would force instance_configuration replacement
# on every change, which OCI rejects (409) while the pool is attached.

# Layer 1: pre-drain daemon
cat > /usr/local/bin/openvidu-pre-drain.sh << 'PREDRAIN_EOF'
${local.pre_drain_daemon_script}
PREDRAIN_EOF
chmod +x /usr/local/bin/openvidu-pre-drain.sh

cat > /etc/systemd/system/openvidu-pre-drain.service << 'PREDRAIN_SVC_EOF'
[Unit]
Description=OpenVidu Pre-drain Daemon
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=simple
ExecStart=/usr/local/bin/openvidu-pre-drain.sh
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
PREDRAIN_SVC_EOF

# invoke_terminate.py — graceful_shutdown.sh asks the scale-in function to
# terminate this instance. Uses the OCI Python SDK to avoid CLI 3.83's broken
# --body handling for fn function invoke.
cat > /usr/local/bin/invoke_terminate.py << 'INVOKE_TERMINATE_EOF'
${local.invoke_terminate_script}
INVOKE_TERMINATE_EOF
chmod +x /usr/local/bin/invoke_terminate.py

# Layer 2: fallback systemd shutdown service
cat > /usr/local/bin/graceful_shutdown.sh << 'SHUTDOWN_SCRIPT_EOF'
${local.graceful_shutdown_script}
SHUTDOWN_SCRIPT_EOF
chmod +x /usr/local/bin/graceful_shutdown.sh

cat > /etc/systemd/system/graceful_shutdown.service << 'SERVICE_EOF'
[Unit]
Description=OpenVidu Graceful Shutdown (fallback)
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/graceful_shutdown.sh
TimeoutStartSec=infinity
TimeoutStopSec=infinity
RemainAfterExit=yes
KillMode=control-group

[Install]
WantedBy=halt.target reboot.target shutdown.target
SERVICE_EOF

# Let systemd wait indefinitely during shutdown (fallback layer)
sed -i 's/^#*DefaultTimeoutStopSec=.*/DefaultTimeoutStopSec=infinity/' /etc/systemd/system.conf

systemctl daemon-reload
systemctl enable openvidu-pre-drain.service
systemctl enable graceful_shutdown.service

# Install OpenVidu media node
/usr/local/bin/install.sh || { echo "[OpenVidu] error installing media node"; exit 1; }

# Start OpenVidu. Like the masters, this initial start can fail if the media node
# comes up while the master cluster is still forming quorum. NON-FATAL (Restart=
# retries until the masters are reachable) so the completion marker and pre-drain
# daemon below still get set up — a hard 'exit 1' would leave the node without
# graceful-drain on scale-in and re-installing on every reboot.
systemctl start openvidu || echo "[OpenVidu] initial start not healthy yet (expected on HA while the master cluster forms); continuing"

# Warm Chrome+Xvfb so the first recording doesn't pay OCI's cold block-volume read of
# the Chrome binary and blow chromedp's 20s startup timeout. Best-effort, non-fatal.
( set +e
  for i in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Running}}' egress 2>/dev/null)" = "true" ] && break; sleep 5; done
  WS=$(date +%s)
  docker exec egress sh -c '
    CH=/opt/google/chrome/chrome
    cat "$CH" >/dev/null 2>&1
    XV=$(command -v Xvfb 2>/dev/null); [ -n "$XV" ] && cat "$XV" >/dev/null 2>&1
    timeout 120 "$CH" --headless=new --no-sandbox --disable-gpu --user-data-dir=/tmp/ov-warm --dump-dom about:blank >/dev/null 2>&1
    rm -rf /tmp/ov-warm
  ' 2>/dev/null
  echo "[warm-egress] chrome warm-up took $(( $(date +%s) - WS ))s"
) || true

# Mark installation as complete
echo "installation_complete" > /usr/local/bin/openvidu_install_counter.txt

# Start pre-drain daemon after install (no-op in fixed mode, gated at runtime by
# the master's scale-in-mode tag).
systemctl start openvidu-pre-drain.service

EOF
}
