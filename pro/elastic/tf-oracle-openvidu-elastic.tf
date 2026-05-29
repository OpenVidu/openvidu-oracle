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

# ---------------------------- SSH Key -------------------------

resource "tls_private_key" "openvidu_ssh_key_elastic" {
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

# Base Security List for subnet (specific filtering is done with NSGs per node role)
resource "oci_core_security_list" "openvidu_subnet_security_list" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.openvidu_vcn.id
  display_name   = "${var.stackName}-subnet-sl"

  # Allow all egress
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # Allow all ingress from within the VCN — NSGs handle fine-grained control.
  # OCI evaluates security lists AND NSGs with AND logic, so without this
  # ingress rule the security list would block all intra-VCN traffic even
  # when the NSG has a matching allow rule.
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

  master_ingress_from_media_ports = {
    livekit   = { min = 7000, max = 7000 }
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

# Customer Secret Key for S3-compatible access
# The 'id' attribute is the S3 Access Key ID; 'key' is the S3 Secret Key (sensitive, stored in Terraform state)
resource "oci_identity_customer_secret_key" "openvidu_s3_key" {
  display_name = "${var.stackName}-s3-key"
  user_id      = var.user_ocid
}

resource "oci_objectstorage_bucket" "appdata_bucket" {
  count          = var.bucketName == "" ? 1 : 0
  compartment_id = var.compartment_ocid
  name           = "${var.stackName}-appdata-${random_id.suffix.hex}"
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  access_type    = "NoPublicAccess"
}

locals {
  bucket_app_data_name = var.bucketName == "" ? oci_objectstorage_bucket.appdata_bucket[0].name : var.bucketName
}

resource "oci_objectstorage_object" "ssh_private_key" {
  namespace = data.oci_objectstorage_namespace.ns.namespace
  bucket    = local.bucket_app_data_name
  object    = "openvidu_private_ssh_key_${var.stackName}.pem"
  content   = tls_private_key.openvidu_ssh_key_elastic.private_key_pem

  depends_on = [oci_objectstorage_bucket.appdata_bucket]
}

# ------------------------- Vault / Secrets -------------------------

resource "oci_kms_vault" "openvidu_vault" {
  count          = var.vault_ocid == "" ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "${var.stackName}-vault"
  vault_type     = "DEFAULT"
}

data "oci_kms_vault" "openvidu_vault" {
  vault_id = var.vault_ocid != "" ? var.vault_ocid : oci_kms_vault.openvidu_vault[0].id
}

# OCI marks the vault ACTIVE before its management endpoint DNS is resolvable.
# Wait until the hostname resolves before creating the key.
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
  key_id              = var.key_ocid != "" ? var.key_ocid : oci_kms_key.openvidu_key[0].id
}

# ------------------------- Compute Instance (Master Node) -------------------------

# Master Node
resource "oci_core_instance" "openvidu_master_node" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_ocid
  display_name        = "${var.stackName}-master-node"
  shape               = var.masterNodeShape

  shape_config {
    ocpus         = var.masterNodeOcpus
    memory_in_gbs = var.masterNodeMemory
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.openvidu_subnet.id
    assign_public_ip = true
    display_name     = "master-node-vnic"
    nsg_ids          = [oci_core_network_security_group.master_nsg.id]
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_master.images[0].id
    boot_volume_size_in_gbs = var.masterNodeDiskSize
  }

  metadata = {
    ssh_authorized_keys = tls_private_key.openvidu_ssh_key_elastic.public_key_openssh
    user_data           = base64gzip(local.user_data_master)
  }

  freeform_tags = {
    "stack"     = var.stackName
    "node-type" = "master"
    # Runtime config consumed by invoke_scalein.sh. Kept as tags (not baked
    # into user_data) so toggling fixedNumberOfMediaNodes updates the master
    # in place instead of recreating it (which would mean a fresh domain,
    # vault secrets, and effectively a new deployment).
    "scale-in-mode"  = var.fixedNumberOfMediaNodes > 0 ? "fixed" : "elastic"
    "scale-in-fn-id" = try(oci_functions_function.scale_in_fn[0].id, "")
  }

  depends_on = [time_sleep.wait_for_iam_propagation]
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
        ssh_authorized_keys = tls_private_key.openvidu_ssh_key_elastic.public_key_openssh
        user_data           = base64gzip(local.user_data_media)
        masterNodePrivateIP = oci_core_instance.openvidu_master_node.private_ip
      }

      freeform_tags = {
        "stack"     = var.stackName
        "node-type" = "media"
      }
    }
  }
}

# Cleanup orphaned media nodes on `terraform destroy`.
#
# Instances detached from the pool by the scale-in function (is_auto_terminate=false)
# are no longer tracked by Terraform. If graceful_shutdown.sh fails to self-terminate
# one of them it would stay alive forever.
#
# Destroy order (null_resource depends_on pool):
#   1. THIS provisioner runs first → terminates detached/orphaned media nodes
#   2. instance pool destroyed → OCI terminates its current members
#
# Identification: every media node is created with freeform tags
#   stack=<stackName>  node-type=media  (set in media_node_config launch_details).
resource "null_resource" "cleanup_orphaned_media_nodes" {
  triggers = {
    compartment_id = var.compartment_ocid
    stack_name     = var.stackName
  }

  # depends_on subnet so that on destroy this runs BEFORE the subnet is deleted,
  # ensuring orphaned instances (outside the pool) are terminated first.
  depends_on = [oci_core_subnet.openvidu_subnet]

  provisioner "local-exec" {
    when = destroy
    # No `environment` block on purpose: the provisioner inherits the PATH of
    # the shell that invoked `terraform destroy`, so wherever the user has the
    # OCI CLI (pipx ~/.local/bin, system /usr/local/bin, brew, etc.) it just
    # works without us guessing.
    command = <<-SCRIPT
      set -x
      if ! command -v oci >/dev/null 2>&1; then
        echo "[cleanup] WARN: 'oci' CLI not found in PATH ($PATH); skipping orphan cleanup."
        echo "[cleanup] If any media nodes detached from the pool are still RUNNING in OCI,"
        echo "[cleanup] terminate them manually before re-deploying or they will accumulate."
        exit 0
      fi
      echo "[cleanup] Looking for orphaned media nodes (stack=${self.triggers.stack_name})..."
      # NOTE: single-dollar shell vars are correct here. Terraform only treats
      # double-dollar followed by an open-brace as an escape. A bare $$VAR
      # passes through literally and breaks both jq (invalid syntax) and shell
      # (where $$ alone expands to the PID).

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

      # Pool members (if the pool still exists at this point). The pool's own
      # destroy will terminate its members — we ONLY want to kill instances
      # that detached and got stuck (true orphans).
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

      # Orphans = ALL_IDS - MEMBER_IDS. Plain POSIX, no bashisms — local-exec
      # uses /bin/sh which on Ubuntu is dash (no process substitution).
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
        # Detaching BVs need a moment to settle into AVAILABLE before listing.
        sleep 15
      fi

      echo "[cleanup] Looking for orphaned boot volumes (stack=${self.triggers.stack_name})..."
      # BVs are named after their parent instance (inst-XXXXX-STACK-media-
      # pool), NOT the pool itself. startswith() never matched these — use
      # contains(). The AVAILABLE filter guarantees we never touch BVs that
      # are still attached to a running instance.
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
    # OCI provider ≥8.12.0 requires at least one scale-in rule in the policy.
    # Threshold LT 0% is mathematically impossible — CPU utilisation is always ≥ 0.
    # This rule exists ONLY to satisfy the provider; it will NEVER fire.
    # All scale-in is owned by the OCI Function (func.py), invoked every 5 min.
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

# Dynamic Group matching all instances in the compartment.
# Enables media nodes to authenticate to the OCI API via Instance Principal
# (no credentials required on the instance) to poll their own lifecycle state.
resource "oci_identity_dynamic_group" "openvidu_instances_dg" {
  compartment_id = var.tenancy_ocid
  name           = "${var.stackName}-instances-dg"
  description    = "Dynamic group for OpenVidu instances (Instance Principal auth for pre-drain)"
  matching_rule  = "instance.compartment.id = '${var.compartment_ocid}'"
}

# Policy: allows instances to poll pool membership (pre-drain daemon), self-terminate
# after drain (graceful_shutdown.sh), manage vault secrets, and invoke the scale-in
# function (master node).
resource "oci_identity_policy" "media_node_predrain_policy" {
  # Must be at tenancy (root) level so that cross-compartment grants work
  # when the vault lives in a different compartment than the deployment.
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
  ]
}

# ------------------------- OCI Functions: Scale-in -------------------------

# Dynamic Group: matches the scale-in function for Resource Principal auth.
# Required so the function can call OCI APIs (instance-pools, monitoring)
# without embedding credentials in the image.
resource "oci_identity_dynamic_group" "scale_in_fn_dg" {
  count = var.fixedNumberOfMediaNodes > 0 ? 0 : 1

  compartment_id = var.tenancy_ocid
  name           = "${var.stackName}-scalein-fn-dg"
  description    = "Dynamic group for OpenVidu scale-in OCI Function (Resource Principal auth)"
  matching_rule  = "ALL {resource.type='fnfunc', resource.compartment.id='${var.compartment_ocid}'}"
}

# Policy: allows the scale-in function to list/inspect/resize the media node pool
# and to read CPU metrics from OCI Monitoring (same data source as func.py).
resource "oci_identity_policy" "scale_in_fn_policy" {
  count = var.fixedNumberOfMediaNodes > 0 ? 0 : 1

  compartment_id = var.compartment_ocid
  name           = "${var.stackName}-scalein-fn-policy"
  description    = "Allow OpenVidu scale-in OCI Function to manage media node pool size"
  statements = [
    "allow dynamic-group ${oci_identity_dynamic_group.scale_in_fn_dg[0].name} to manage instance-pools in compartment id ${var.compartment_ocid}",
    "allow dynamic-group ${oci_identity_dynamic_group.scale_in_fn_dg[0].name} to manage instances in compartment id ${var.compartment_ocid}",
    # terminate-instance with preserve_boot_volume=false must delete the boot
    # volume too — without volume-family OCI rejects with "volume ... cannot
    # be terminated because this user does not have sufficient permissions".
    "allow dynamic-group ${oci_identity_dynamic_group.scale_in_fn_dg[0].name} to manage volume-family in compartment id ${var.compartment_ocid}",
    "allow dynamic-group ${oci_identity_dynamic_group.scale_in_fn_dg[0].name} to read metrics in compartment id ${var.compartment_ocid}",
  ]
}

# OCI IAM policy propagation can take 60-120 s after creation/recreation.
# Wait before launching the master node so instance_principal auth is ready.
resource "time_sleep" "wait_for_iam_propagation" {
  depends_on = [
    oci_identity_dynamic_group.openvidu_instances_dg,
    oci_identity_policy.media_node_predrain_policy,
  ]
  create_duration = "120s"
}

# Function Application: hosts the scale-in function and injects runtime config.
# The config vars are updated by Terraform; the function reads them at invocation
# time via os.environ — no image rebuild needed to change them.
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

# Function: uses the pre-built image published by OpenVidu Team in their OCIR
# (Option B). No docker build/push during terraform apply.
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

# Log: captures function invocation logs (stdout/stderr from func.py).
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



locals {
  domain_name = var.domainName != "" ? var.domainName : "openvidu-${replace(oci_core_instance.openvidu_master_node.public_ip, ".", "-")}.sslip.io"

  # ARM shapes in OCI use "VM.Standard.A" / "BM.Standard.A" prefixes (Ampere).
  # All others (VM.Standard.E*, VM.Standard3, VM.Standard2, BM.Standard2...) are x86.
  is_arm_instance = startswith(var.masterNodeShape, "VM.Standard.A") || startswith(var.masterNodeShape, "BM.Standard.A")
  yq_arch         = local.is_arm_instance ? "arm64" : "amd64"
  yq_sha256       = local.is_arm_instance ? "10a4a2093090363a00b55ad52e132a082f9652970cb8f1ad35a1ae048b917e6e" : "3fa3c1c32d94520102ea4d853d03c3ab907867d964540e896410ad8a7fc6c8f7"

  # Common OCI Vault helpers, sourced by store_secret / update_config_from_secret /
  # update_secret_from_config. Keeps a single source of truth for retry, query
  # sanitization, and read/write logic against the vault.
  oci_helpers_script = <<-EOF
#!/bin/bash
# Common OCI Vault helpers. Sourced by store_secret.sh, update_config_from_secret.sh,
# and update_secret_from_config.sh. Callers must set VAULT_ID and COMPARTMENT_ID
# before sourcing; KEY_ID is required only when creating new secrets via
# store_in_vault.
#
# We own retry instead of relying on the OCI CLI default: the default strategy
# can spin internally for ~10 min on 429/5xx and stack under our own retry,
# producing 20-30 min hangs during install.

# Per-attempt wall-clock cap. Vault ops typically finish in <5s; longer means
# the API or auth layer is wedged — kill and let oci_with_retry decide.
: "$${OCI_CALL_TIMEOUT:=45}"

oci_with_retry() {
  local max_attempts=3
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

# OCI CLI --raw-output prints "Query returned empty result, no output to show."
# to stdout instead of an empty string when JMESPath matches nothing. Filter
# that so callers can test with [[ -z ]].
ocid_from_query() {
  local result
  result=$("$@")
  if [[ "$result" == *"Query returned empty result"* || "$result" == "null" ]]; then
    echo ""
  else
    echo "$result"
  fi
}

# Read an ACTIVE secret by name. Decoded value goes to stdout; returns non-zero
# if not found (so callers using `$(get_from_vault X)` see empty + nonzero).
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
# Fast path: ACTIVE → update. Avoids cancel-secret-deletion on every call so we
# stay below the 30/min vault rate limit. PENDING_DELETION fallback recovers
# from manual schedule-deletion or external tooling. Create requires KEY_ID.
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
    oci_with_retry oci vault secret update-base64 \
      --secret-id "$secret_id" \
      --secret-content-content "$encoded_value" \
      --enable-auto-generation false \
      --auth instance_principal > /dev/null
    return
  fi

  # PENDING_DELETION fallback — cancel and wait for ACTIVE; otherwise update
  # races against CANCELLING_DELETION and OCI returns 409.
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
    local i state=""
    for i in $(seq 1 30); do
      state=$(oci_with_retry oci vault secret get \
        --secret-id "$secret_id" \
        --query 'data."lifecycle-state"' \
        --raw-output \
        --auth instance_principal 2>/dev/null || echo "")
      [[ "$state" == "ACTIVE" ]] && break
      sleep 2
    done
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

  # get_master_tag.sh — single source of truth for runtime config that depends on
  # var.fixedNumberOfMediaNodes. The master node carries scale-in-mode and
  # scale-in-fn-id as freeform tags (updated in place by Terraform on toggle).
  # Media nodes query them via OCI API instead of baking values into their
  # user_data, which would force instance_configuration replacement on every
  # toggle and conflict 409 because the pool still references it.
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

  # Pre-drain daemon: polls pool membership every 30s. When this instance is
  # no longer in the pool (detached by func.py on scale-in), calls graceful_shutdown.sh.
  pre_drain_daemon_script = <<-EOF
#!/bin/bash
# OpenVidu Pre-drain Daemon for OCI
# Responsibility: detect that this instance has been detached from the pool
# (by the scale-in OCI Function) and call graceful_shutdown.sh.
# Scale-in decisions are owned by func.py — this daemon only reacts to them.

source /etc/openvidu/predrain.conf

# OCI CLI is installed via pipx under /root/.local/bin; systemd does not set HOME
export HOME="/root"
export PATH="$PATH:/root/.local/bin"

log() { echo "[openvidu-predrain $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" >&2; }

# If drain lock exists, daemon restarted mid-drain — wait for self-termination to complete
if [ -f "/var/run/openvidu-drain.lock" ]; then
    log "Drain lock exists — drain already in progress. Waiting for self-termination."
    while true; do sleep 60; done
fi

INSTANCE_OCID=$(curl -sf -H "Authorization: Bearer Oracle" \
    "http://169.254.169.254/opc/v2/instance/" | jq -r '.id')
log "Started. Instance: $INSTANCE_OCID"

# Discover pool OCID once at startup via exact display-name match.
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

# Poll every 30s: am I still a member of the pool?
# When func.py detaches this instance (is_decrement_size=True), it disappears
# from the pool member list — that is our drain signal.
#
# In fixed-mode deployments there is no scale-in function and no detach events,
# so we skip the membership check. The check is re-evaluated every iteration
# so toggling between modes via Terraform takes effect without restarting the
# daemon (worst case: one minute of staleness).
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

  # invoke_terminate.py — Python script that calls the scale-in function
  # with a terminate_instance_id payload using the OCI SDK directly.
  #
  # Why a Python script instead of `oci fn function invoke --body ...`:
  # OCI CLI 3.83 does NOT reliably ship the --body content to the function
  # — empirically (verified in scale-in fn logs) the function receives an
  # empty/unparseable body and falls into the scale-in branch instead of
  # the terminate branch. The Python SDK lets us pass the body as raw bytes
  # so there is no shell quoting / CLI parsing layer in between.
  #
  # Runs under the pipx-installed OCI CLI venv's Python, which has the oci
  # SDK available without any extra install.
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

  # graceful_shutdown.sh — single drain+terminate script called from two paths:
  #   1. openvidu-pre-drain.service: pool detach detected → exec graceful_shutdown.sh
  #   2. graceful_shutdown.service: ACPI shutdown (e.g. manual terminate from console)
  # A lock file prevents double execution when both paths fire simultaneously.
  graceful_shutdown_script = <<-EOF
#!/bin/bash
# Graceful shutdown for OpenVidu Media Node (OCI)
# Called by the pre-drain daemon (detected pool detach) and by the systemd
# fallback service (ACPI shutdown). In both cases: drain + self-terminate.

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

# In fixed-mode deployments there is no scale-in function — drain is complete,
# let OCI/ACPI proceed with the termination. If we can't determine the mode
# (master unreachable, API transient), default to elastic behaviour: the
# function call will retry and self-correct once the master is reachable.
MODE=$(/usr/local/bin/get_master_tag.sh scale-in-mode 2>/dev/null || echo "")
if [ "$MODE" = "fixed" ]; then
    echo "[graceful-shutdown] Fixed mode — drain complete, exiting."
    exit 0
fi

# Step 3: Request termination via OCI Function (Resource Principal).
# Direct instance_principal terminate is blocked by a tenancy-level deny policy;
# the scale-in function uses Resource Principal auth which is not subject to the
# same restriction and can call TerminateInstance on our behalf.
INSTANCE_OCID=$(curl -sf -H "Authorization: Bearer Oracle" \
    "http://169.254.169.254/opc/v2/instance/" | jq -r '.id')
echo "[graceful-shutdown] Instance OCID: $INSTANCE_OCID. Self-terminating via function..."

attempt=0
while true; do
    attempt=$((attempt + 1))
    echo "[graceful-shutdown] Terminate via function, attempt $attempt..."
    # Calls the scale-in function via OCI Python SDK (see invoke_terminate.py
    # docstring): bypasses `oci fn function invoke --body ...` which does NOT
    # reliably deliver the JSON body in CLI 3.83.
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

# S3 credentials: Customer Secret Key generated by Terraform for this deployment
EXTERNAL_S3_ACCESS_KEY="${oci_identity_customer_secret_key.openvidu_s3_key.id}"
EXTERNAL_S3_SECRET_KEY="${oci_identity_customer_secret_key.openvidu_s3_key.key}"

sed -i "s|EXTERNAL_S3_ENDPOINT=.*|EXTERNAL_S3_ENDPOINT=$EXTERNAL_S3_ENDPOINT|" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s|EXTERNAL_S3_REGION=.*|EXTERNAL_S3_REGION=$EXTERNAL_S3_REGION|" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s|EXTERNAL_S3_PATH_STYLE_ACCESS=.*|EXTERNAL_S3_PATH_STYLE_ACCESS=$EXTERNAL_S3_PATH_STYLE_ACCESS|" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s|EXTERNAL_S3_BUCKET_APP_DATA=.*|EXTERNAL_S3_BUCKET_APP_DATA=$EXTERNAL_S3_BUCKET_APP_DATA|" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
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

## Master internet-facing ports
firewall-cmd --add-port=22/tcp
firewall-cmd --permanent --add-port=22/tcp

firewall-cmd --add-port=80/tcp
firewall-cmd --permanent --add-port=80/tcp

firewall-cmd --add-port=443/tcp
firewall-cmd --permanent --add-port=443/tcp

firewall-cmd --add-port=1935/tcp
firewall-cmd --permanent --add-port=1935/tcp

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

# Mark secrets as not ready before generating them, so media nodes
# from a previous deployment don't read stale values.
/usr/local/bin/store_secret.sh save ALL_SECRETS_GENERATED "false"

# Configure domain using OCI IMDS v2
get_meta() { curl -sf -H "Authorization: Bearer Oracle" "http://169.254.169.254/opc/v2/instance/$1"; }
# Resolve the public IP with explicit fallbacks. The jq pipe always exits 0
# (even on null), so || chaining would never trigger the fallbacks.
EXTERNAL_IP=$(get_meta "vnics/" | jq -r '.[0].publicIp // empty' 2>/dev/null) || true
[[ -z "$EXTERNAL_IP" ]] && EXTERNAL_IP=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null) || true
[[ -z "$EXTERNAL_IP" ]] && EXTERNAL_IP=$(curl -sf https://api4.ipify.org 2>/dev/null) || true

if [[ "${var.domainName}" == "" ]]; then
  [ ! -d "/usr/share/openvidu" ] && mkdir -p /usr/share/openvidu
  RANDOM_DOMAIN_STRING=$(tr -dc 'a-z' < /dev/urandom | head -c 8)
  DOMAIN="openvidu-$RANDOM_DOMAIN_STRING-$(echo $EXTERNAL_IP | tr '.' '-').sslip.io"
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

# Get own private IP
PRIVATE_IP=$(get_meta "vnics/" | jq -r '.[0].privateIp' 2>/dev/null || hostname -I | awk '{print $1}')

# Store usernames and generate random passwords
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

# Store OpenVidu Pro license, RTC engine and version
OPENVIDU_PRO_LICENSE="$(/usr/local/bin/store_secret.sh save OPENVIDU_PRO_LICENSE "${var.openviduLicense}")"
OPENVIDU_RTC_ENGINE="$(/usr/local/bin/store_secret.sh save OPENVIDU_RTC_ENGINE "${var.rtcEngine}")"
OPENVIDU_VERSION="$(/usr/local/bin/store_secret.sh save OPENVIDU_VERSION "$OPENVIDU_VERSION")"
ALL_SECRETS_GENERATED="$(/usr/local/bin/store_secret.sh save ALL_SECRETS_GENERATED "true")"

# Build install command and args
INSTALL_COMMAND="sh <(curl -fsSL http://get.openvidu.io/pro/elastic/$OPENVIDU_VERSION/install_ov_master_node.sh)"

COMMON_ARGS=(
  "--no-tty"
  "--install"
  "--environment=oracle"
  "--deployment-type=elastic"
  "--node-role=master-node"
  "--openvidu-pro-license=$OPENVIDU_PRO_LICENSE"
  "--private-ip=$PRIVATE_IP"
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

# Only pass --meet-initial-api-key when the user provided one. Passing an empty
# value would explicitly null out the installer default.
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

VAULT_ID="${var.vault_ocid != "" ? var.vault_ocid : oci_kms_vault.openvidu_vault[0].id}"
KEY_ID="${var.key_ocid != "" ? var.key_ocid : oci_kms_key.openvidu_key[0].id}"
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
set -e

export HOME="/root"
export PATH="$PATH:$HOME/.local/bin"
export OCI_CLI_DISABLE_DEFAULT_RETRY=True

VAULT_ID="${var.vault_ocid != "" ? var.vault_ocid : oci_kms_vault.openvidu_vault[0].id}"
KEY_ID="${var.key_ocid != "" ? var.key_ocid : oci_kms_key.openvidu_key[0].id}"
COMPARTMENT_ID="${var.compartment_ocid}"

# shellcheck source=/dev/null
. /usr/local/bin/oci_helpers.sh

INSTALL_DIR="/opt/openvidu"
CLUSTER_CONFIG_DIR="$${INSTALL_DIR}/config/cluster"
MASTER_NODE_CONFIG_DIR="$${INSTALL_DIR}/config/node"

# Skip writes when the config didn't yield a real value. Without this, an
# unset / commented-out config key gets persisted to vault as the literal
# string we'd otherwise have written ("" or "none"), corrupting the secret.
maybe_save() {
  local key="$1"
  local value="$2"
  if [[ -z "$value" || "$value" == "none" ]]; then
    echo "[update_secret_from_config] Skipping '$key': empty value in config" >&2
    return 0
  fi
  store_in_vault "$key" "$value"
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

VAULT_ID="${var.vault_ocid != "" ? var.vault_ocid : oci_kms_vault.openvidu_vault[0].id}"
KEY_ID="${var.key_ocid != "" ? var.key_ocid : oci_kms_key.openvidu_key[0].id}"
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
FAIL_COUNT=0
while true; do
  HTTP_STATUS=$(curl -Ik http://localhost:7880/health/caddy 2>/dev/null | head -n1 | awk '{print $2}')
  if [ "$HTTP_STATUS" == "200" ]; then
    break
  fi
  FAIL_COUNT=$((FAIL_COUNT + 1))
  if [ $FAIL_COUNT -ge 10 ]; then
    echo "[check_app_ready] $FAIL_COUNT consecutive failures, restarting openvidu..."
    systemctl restart openvidu
    FAIL_COUNT=0
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

# Check if installation already completed (reboot path)
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

  # Install OCI CLI via pipx (correct method for modern Ubuntu)
  export HOME="/root"
  OCI_CLI_VERSION="3.83.0"
  pipx install oci-cli==$${OCI_CLI_VERSION}
  export PATH="$PATH:$HOME/.local/bin"

  # Install OpenVidu
  /usr/local/bin/install.sh || { echo "[OpenVidu] error installing OpenVidu"; exit 1; }

  # Configure S3 bucket
  /usr/local/bin/config_s3.sh || { echo "[OpenVidu] error configuring S3 bucket"; exit 1; }

  # Start OpenVidu
  systemctl start openvidu || { echo "[OpenVidu] error starting OpenVidu"; exit 1; }

  # Update shared secrets
  /usr/local/bin/after_install.sh || { echo "[OpenVidu] error updating shared secrets"; exit 1; }

  # Scale-in function invoker. Always installed; behavior is driven at runtime
  # by this instance's freeform tags (set by Terraform). When the user toggles
  # fixedNumberOfMediaNodes, only the tags change — user_data is immutable in
  # OCI, so embedding the function OCID here would force master recreation.
  cat > /usr/local/bin/invoke_scalein.sh << 'INVOKE_EOF'
#!/bin/bash
export HOME="/root"
export PATH="$PATH:/root/.local/bin"

META=$(curl -sf -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/) || exit 0
MODE=$(echo "$META" | jq -r '.freeformTags["scale-in-mode"] // empty')
FN_ID=$(echo "$META" | jq -r '.freeformTags["scale-in-fn-id"] // empty')

# Fixed-mode deployments have no scale-in function — exit quietly.
[ "$MODE" = "fixed" ] && exit 0
[ -z "$FN_ID" ] && exit 0

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

  # Schedule restart on reboot, scale-in every 5 min (no-op in fixed mode,
  # gated by tags inside the script), boot volume cleanup every 5 min.
  { \
    echo "@reboot /usr/local/bin/restart.sh >> /var/log/openvidu-restart.log 2>&1"; \
    echo "*/5 * * * * /usr/local/bin/invoke_scalein.sh >> /dev/null 2>&1"; \
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

MASTER_NODE_PRIVATE_IP=$(get_meta "" | jq -r '.metadata.masterNodePrivateIP // empty')
PRIVATE_IP=$(get_meta "vnics/" | jq -r '.[0].privateIp' 2>/dev/null || hostname -I | awk '{print $1}')

# Helper: run an OCI CLI command with automatic retry on transient errors
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

# Helper: read a secret from OCI Vault via Instance Principal
get_secret() {
  local secret_name="$1"
  local secret_id
  secret_id=$(ocid_from_query oci_with_retry oci vault secret list \
    --compartment-id "${var.compartment_ocid}" \
    --vault-id "${var.vault_ocid != "" ? var.vault_ocid : oci_kms_vault.openvidu_vault[0].id}" \
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

# Wait for master node to finish writing all secrets
until get_secret ALL_SECRETS_GENERATED 2>/dev/null | grep -q "true"; do
  echo "Waiting for master node to initialize secrets..."
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

# Build install command for media node
INSTALL_COMMAND="sh <(curl -fsSL http://get.openvidu.io/pro/elastic/$OPENVIDU_VERSION/install_ov_media_node.sh)"

COMMON_ARGS=(
  "--no-tty"
  "--install"
  "--environment=oracle"
  "--deployment-type=elastic"
  "--node-role=media-node"
  "--master-node-private-ip=$MASTER_NODE_PRIVATE_IP"
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

# Write pre-drain config (Terraform bakes in actual values at deploy time).
# STACK_NAME is used by get_master_tag.sh to find the master node by freeform tag.
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

# get_master_tag.sh — runtime resolver for the master's scale-in-* freeform
# tags. Used by the pre-drain daemon, graceful_shutdown.sh, and invoke_terminate.py
# to decide whether scale-in is active without baking values into user_data.
cat > /usr/local/bin/get_master_tag.sh << 'GET_MASTER_TAG_EOF'
${local.get_master_tag_script}
GET_MASTER_TAG_EOF
chmod +x /usr/local/bin/get_master_tag.sh

# ------------------------- Graceful Drain Setup (two-layer approach) -------------------------
# Layer 1 — Pre-drain daemon (primary): monitors pool size and local CPU. When scale-in
#   conditions are met and this is the oldest node, it detaches itself from the pool
#   (pool target -1, no replacement spawned), drains with no time limit, then self-terminates.
#   OCI's 15-min ACPI timeout never applies — the instance is outside the pool when draining.
# Layer 2 — Systemd shutdown service (fallback): catches the rare case where an ACPI
#   shutdown arrives before the daemon completes; blocks OS poweroff until drain finishes.
#
# Both layers are ALWAYS installed regardless of fixedNumberOfMediaNodes. They self-gate
# at runtime via the master's scale-in-mode freeform tag (read through get_master_tag.sh):
# in fixed mode the pre-drain daemon idles and graceful_shutdown skips the function
# invocation. Baking the toggle into user_data would force instance_configuration
# replacement on every change, which OCI rejects (409) while the pool is attached.

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

# invoke_terminate.py — called by graceful_shutdown.sh to ask the scale-in
# function to terminate this instance. Uses the OCI Python SDK directly to
# avoid OCI CLI 3.83's broken --body handling for fn function invoke.
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

# Allow systemd to wait indefinitely during shutdown (fallback layer)
sed -i 's/^#*DefaultTimeoutStopSec=.*/DefaultTimeoutStopSec=infinity/' /etc/systemd/system.conf

systemctl daemon-reload
systemctl enable openvidu-pre-drain.service
systemctl enable graceful_shutdown.service

# Install OpenVidu media node
/usr/local/bin/install.sh || { echo "[OpenVidu] error installing media node"; exit 1; }

# Start OpenVidu
systemctl start openvidu || { echo "[OpenVidu] error starting OpenVidu"; exit 1; }

# Mark installation as complete
echo "installation_complete" > /usr/local/bin/openvidu_install_counter.txt

# Start pre-drain daemon after OpenVidu is installed (no-op in fixed mode, gated
# at runtime by the master's scale-in-mode tag).
systemctl start openvidu-pre-drain.service

EOF
}
