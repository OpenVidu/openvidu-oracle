# Random suffix for unique naming
resource "random_id" "suffix" {
  byte_length = 3
}

# Get Availability Domain
data "oci_identity_availability_domain" "ad" {
  compartment_id = var.tenancy_ocid
  ad_number      = var.availability_domain
}

# ---------------------- Instance Principals --------------------
resource "oci_identity_dynamic_group" "openvidu_instances_group" {
  compartment_id = var.tenancy_ocid
  name           = "OpenViduInstanceGroup"
  description    = "Dynamic group for OpenVidu nodes"
  matching_rule  = "instance.compartment.id = '${var.compartment_ocid}'"
}

resource "oci_identity_policy" "openvidu_secrets_policy" {
  # At tenancy (root) level so cross-compartment grants work when the vault
  # lives in a different compartment than the deployment.
  compartment_id = var.tenancy_ocid
  name           = "OpenViduSecretsPolicy"
  description    = "Allow OpenVidu instances to manage secrets and use keys"
  statements = [
    # Secrets live in the deployment compartment
    "Allow dynamic-group OpenViduInstanceGroup to manage secret-family in compartment id ${var.compartment_ocid}",
    # Vault and key may be in a different compartment — use the vault's actual one
    "Allow dynamic-group OpenViduInstanceGroup to use vaults in compartment id ${data.oci_kms_vault.openvidu_vault.compartment_id}",
    "Allow dynamic-group OpenViduInstanceGroup to use keys in compartment id ${data.oci_kms_vault.openvidu_vault.compartment_id}",
  ]
}

# Wait for IAM policy propagation (60-120 s) so instance_principal auth is ready
# before launching the instance.
resource "time_sleep" "wait_for_iam_propagation" {
  depends_on = [
    oci_identity_dynamic_group.openvidu_instances_group,
    oci_identity_policy.openvidu_secrets_policy,
  ]
  create_duration = "120s"
}


# ---------------------------- SSH Key -------------------------

resource "tls_private_key" "openvidu_ssh_key_sn" {
  algorithm = "RSA"
}

resource "oci_objectstorage_object" "ssh_private_key" {
  namespace = data.oci_objectstorage_namespace.ns.namespace
  bucket    = local.bucket_app_data_name
  object    = "openvidu_private_ssh_key_${var.stackName}.pem"
  content   = tls_private_key.openvidu_ssh_key_sn.private_key_pem

  # The object must be created after the bucket, and after null_resource.empty_bucket
  # so it is destroyed BEFORE the bulk-delete.
  depends_on = [oci_objectstorage_bucket.openvidu_bucket, null_resource.empty_bucket]
}

# ------------------------- Networking -------------------------

# VCN
resource "oci_core_vcn" "openvidu_vcn" {
  cidr_block     = "10.0.0.0/16"
  compartment_id = var.compartment_ocid
  display_name   = "${var.stackName}-vcn"

  dns_label = "openviduvcn"
}

## Makes the VM reachable from the internet (used by the route table + security list).
##-------------------------------------------------
# Internet Gateway
resource "oci_core_internet_gateway" "openvidu_igw" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.stackName}-igw"
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
    network_entity_id = oci_core_internet_gateway.openvidu_igw.id
  }
}

# Security List (mirrors NSG rules — OCI requires both layers to allow traffic)
resource "oci_core_security_list" "openvidu_sl" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.openvidu_vcn.id
  display_name   = "${var.stackName}-sl"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    description = "SSH"
    tcp_options {
      min = 22
      max = 22
    }
  }
  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    description = "HTTP"
    tcp_options {
      min = 80
      max = 80
    }
  }
  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    description = "HTTPS"
    tcp_options {
      min = 443
      max = 443
    }
  }
  ingress_security_rules {
    protocol    = "17"
    source      = "0.0.0.0/0"
    description = "TURN UDP 443"
    udp_options {
      min = 443
      max = 443
    }
  }
  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    description = "RTMP"
    tcp_options {
      min = 1935
      max = 1935
    }
  }
  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    description = "LiveKit/WebRTC TCP"
    tcp_options {
      min = 7881
      max = 7881
    }
  }
  ingress_security_rules {
    protocol    = "17"
    source      = "0.0.0.0/0"
    description = "LiveKit/WebRTC UDP"
    udp_options {
      min = 7885
      max = 7885
    }
  }
  ingress_security_rules {
    protocol    = "17"
    source      = "0.0.0.0/0"
    description = "WebRTC UDP Range"
    udp_options {
      min = 50000
      max = 60000
    }
  }
}

# Subnet
resource "oci_core_subnet" "openvidu_subnet" {
  cidr_block        = "10.0.1.0/24"
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.openvidu_vcn.id
  display_name      = "${var.stackName}-subnet"
  dns_label         = "openvidusubnet"
  route_table_id    = oci_core_route_table.openvidu_rt.id
  security_list_ids = [oci_core_security_list.openvidu_sl.id]
}

##-------------------------------------------------

# Network Security Group
resource "oci_core_network_security_group" "openvidu_nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.openvidu_vcn.id
  display_name   = "${var.stackName}-nsg"
}

# NSG Egress Rules
resource "oci_core_network_security_group_security_rule" "openvidu_nsg_egress" {
  network_security_group_id = oci_core_network_security_group.openvidu_nsg.id
  direction                 = "EGRESS"
  destination               = "0.0.0.0/0"
  protocol                  = "all"
}

# NSG Ingress Rules
resource "oci_core_network_security_group_security_rule" "openvidu_nsg_ingress_ssh" {
  network_security_group_id = oci_core_network_security_group.openvidu_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6" #TCP
  source                    = "0.0.0.0/0"
  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
  description = "SSH"
}

resource "oci_core_network_security_group_security_rule" "openvidu_nsg_ingress_http" {
  network_security_group_id = oci_core_network_security_group.openvidu_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6" #TCP
  source                    = "0.0.0.0/0"
  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
  description = "HTTP"
}

resource "oci_core_network_security_group_security_rule" "openvidu_nsg_ingress_https" {
  network_security_group_id = oci_core_network_security_group.openvidu_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6" #TCP
  source                    = "0.0.0.0/0"
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
  description = "HTTPS"
}

resource "oci_core_network_security_group_security_rule" "openvidu_nsg_ingress_turn_udp" {
  network_security_group_id = oci_core_network_security_group.openvidu_nsg.id
  direction                 = "INGRESS"
  protocol                  = "17" #UDP
  source                    = "0.0.0.0/0"
  udp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
  description = "TURN UDP 443"
}

resource "oci_core_network_security_group_security_rule" "openvidu_nsg_ingress_rtmp" {
  network_security_group_id = oci_core_network_security_group.openvidu_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6" #TCP
  source                    = "0.0.0.0/0"
  tcp_options {
    destination_port_range {
      min = 1935
      max = 1935
    }
  }
  description = "RTMP"
}

resource "oci_core_network_security_group_security_rule" "openvidu_nsg_ingress_livekit_tcp" {
  network_security_group_id = oci_core_network_security_group.openvidu_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6" #TCP
  source                    = "0.0.0.0/0"
  tcp_options {
    destination_port_range {
      min = 7881
      max = 7881
    }
  }
  description = "LiveKit/WebRTC TCP"
}

resource "oci_core_network_security_group_security_rule" "openvidu_nsg_ingress_livekit_udp" {
  network_security_group_id = oci_core_network_security_group.openvidu_nsg.id
  direction                 = "INGRESS"
  protocol                  = "17" #UDP
  source                    = "0.0.0.0/0"
  udp_options {
    destination_port_range {
      min = 7885
      max = 7885
    }
  }
  description = "LiveKit/WebRTC UDP"
}

resource "oci_core_network_security_group_security_rule" "openvidu_nsg_ingress_webrtc_udp" {
  network_security_group_id = oci_core_network_security_group.openvidu_nsg.id
  direction                 = "INGRESS"
  protocol                  = "17" #UDP
  source                    = "0.0.0.0/0"
  udp_options {
    destination_port_range {
      min = 50000
      max = 60000
    }
  }
  description = "WebRTC UDP Range"
}
# ------------------------- Object Storage -------------------------

locals {
  bucket_app_data_name = var.bucketName == "" ? oci_objectstorage_bucket.openvidu_bucket[0].name : var.bucketName
}

data "oci_objectstorage_namespace" "ns" {
  compartment_id = var.tenancy_ocid
}

# Customer Secret Key for S3-compatible access.
# 'id' is the S3 Access Key ID; 'key' is the S3 Secret Key (sensitive, stored in Terraform state).
resource "oci_identity_customer_secret_key" "openvidu_s3_key" {
  display_name = "${var.stackName}-s3-key"
  user_id      = var.user_ocid
}

# Object Storage Bucket
resource "oci_objectstorage_bucket" "openvidu_bucket" {
  count          = var.bucketName == "" ? 1 : 0
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  name           = "${var.stackName}-appdata-${random_id.suffix.hex}"
  storage_tier   = "Standard"
}

# Empty the Terraform-created bucket before destroy — OCI won't delete a non-empty
# bucket (runtime recordings, etc.). User-provided buckets (bucketName set) are left
# untouched. Ordered after the SSH key object's destroy (its depends_on).
resource "null_resource" "empty_bucket" {
  triggers = {
    namespace = data.oci_objectstorage_namespace.ns.namespace
    region    = var.region
    bucket    = var.bucketName == "" ? local.bucket_app_data_name : ""
  }

  depends_on = [oci_objectstorage_bucket.openvidu_bucket]

  provisioner "local-exec" {
    when    = destroy
    command = <<-SCRIPT
      set -x
      if ! command -v oci >/dev/null 2>&1; then
        echo "[empty-bucket] WARN: 'oci' CLI not in PATH ($PATH); a non-empty bucket will block destroy."
        exit 0
      fi
      B="${self.triggers.bucket}"
      [ -z "$B" ] && exit 0
      echo "[empty-bucket] Emptying bucket $B ..."
      oci os object bulk-delete \
        --namespace "${self.triggers.namespace}" \
        --bucket-name "$B" \
        --region "${self.triggers.region}" \
        --force 2>/dev/null || echo "[empty-bucket] bulk-delete on $B non-zero (already empty?)"
    SCRIPT
  }
}

# ------------------------- Compute Instance -------------------------

locals {
  is_arm   = length(regexall("\\.(A[0-9]+)\\.", var.instanceType)) > 0
  image_id = data.oci_core_images.ubuntu.images[0].id
}

data "oci_core_images" "ubuntu" {
  compartment_id           = var.tenancy_ocid
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = var.instanceType
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "openvidu_server" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_ocid
  display_name        = "${var.stackName}-vm-ce"
  shape               = var.instanceType

  dynamic "shape_config" {
    for_each = length(regexall("Flex", var.instanceType)) > 0 ? [1] : []
    content {
      ocpus         = var.instanceOCPUs
      memory_in_gbs = var.instanceMemory
    }
  }

  source_details {
    source_type = "image"
    source_id   = local.image_id
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.openvidu_subnet.id
    display_name     = "${var.stackName}-vnic"
    assign_public_ip = true
    nsg_ids          = [oci_core_network_security_group.openvidu_nsg.id]
  }

  metadata = {
    ssh_authorized_keys = tls_private_key.openvidu_ssh_key_sn.public_key_openssh
    user_data           = base64gzip(local.user_data)
  }

  freeform_tags = {
    "stack"    = var.stackName
    "openvidu" = "true"
  }

  depends_on = [time_sleep.wait_for_iam_propagation]
}

# --------------------- Vault for secrets management --------------------

resource "oci_kms_vault" "openvidu_vault" {
  count          = var.vault_ocid == "" ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = "${var.stackName}-vault"
  vault_type     = "DEFAULT"
}

data "oci_kms_vault" "openvidu_vault" {
  vault_id = var.vault_ocid != "" ? var.vault_ocid : oci_kms_vault.openvidu_vault[0].id
}

# OCI marks the vault ACTIVE before its management endpoint DNS resolves.
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
  key_id              = var.key_ocid != "" ? var.key_ocid : oci_kms_key.openvidu_key[0].id
}


# ------------------------- locals with scripts -------------------------

locals {
  bucket_name      = local.bucket_app_data_name
  bucket_namespace = data.oci_objectstorage_namespace.ns.namespace

  # Common OCI Vault helpers — single source of truth for retry, query
  # sanitization, and vault read/write logic.
  oci_helpers_script = <<-EOF
#!/bin/bash
# Common OCI Vault helpers. Callers must set VAULT_ID and COMPARTMENT_ID before
# sourcing; KEY_ID is needed only when creating new secrets via store_in_vault.
#
# We own retry instead of the OCI CLI default: the default can spin ~10 min on
# 429/5xx and stack under our retry, causing 20-30 min hangs during install.

# Per-attempt wall-clock cap. Vault ops usually finish in <5s; longer means the
# API or auth layer is wedged — kill and let oci_with_retry decide.
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

# OCI CLI --raw-output prints "Query returned empty result..." to stdout (not an
# empty string) when JMESPath matches nothing. Filter it so callers can test [[ -z ]].
ocid_from_query() {
  local result
  result=$("$@")
  if [[ "$result" == *"Query returned empty result"* || "$result" == "null" ]]; then
    echo ""
  else
    echo "$result"
  fi
}

# Read an ACTIVE secret by name. Decoded value to stdout; returns non-zero if
# not found (so `$(get_from_vault X)` callers see empty + nonzero).
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
# Fast path: ACTIVE → update. Avoids cancel-secret-deletion on every call to stay
# below the 30/min vault rate limit. PENDING_DELETION fallback recovers from manual
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
    oci_with_retry oci vault secret update-base64 \
      --secret-id "$secret_id" \
      --secret-content-content "$encoded_value" \
      --enable-auto-generation false \
      --auth instance_principal > /dev/null
    return
  fi

  # PENDING_DELETION fallback — cancel and wait for ACTIVE, else update races
  # against CANCELLING_DELETION and OCI returns 409.
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

  install_script = <<-EOF
#!/bin/bash -x
set -e

OPENVIDU_VERSION=main
DOMAIN=

# Apply firewall rules
systemctl enable firewalld
systemctl start firewalld

iptables -F
iptables -P INPUT ACCEPT
systemctl disable netfilter-persistent 2>/dev/null || true

## Add firewall rules

firewall-cmd --add-port=22/tcp
firewall-cmd --permanent --add-port=22/tcp

firewall-cmd --add-port=80/tcp
firewall-cmd --permanent --add-port=80/tcp

firewall-cmd --add-port=443/tcp
firewall-cmd --permanent --add-port=443/tcp

firewall-cmd --add-port=443/udp
firewall-cmd --permanent --add-port=443/udp

firewall-cmd --add-port=1935/tcp
firewall-cmd --permanent --add-port=1935/tcp

firewall-cmd --add-port=7881/tcp
firewall-cmd --permanent --add-port=7881/tcp

firewall-cmd --add-port=7885/udp
firewall-cmd --permanent --add-port=7885/udp

firewall-cmd --add-port=9000/tcp
firewall-cmd --permanent --add-port=9000/tcp

firewall-cmd --add-port=50000-60000/udp
firewall-cmd --permanent --add-port=50000-60000/udp

## Apply rules
firewall-cmd --reload
firewall-cmd --runtime-to-permanent

firewall-cmd --list-all

# Get public IP
get_public_ip() {
  local ip
  ip=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null) \
    || ip=$(dig +short txt ch whoami.cloudflare @1.1.1.1 2>/dev/null | tr -d '"') \
    || ip=$(dig +short txt o-o.myaddr.l.google.com @ns1.google.com 2>/dev/null | tr -d '"')

  if [[ -z "$ip" ]]; then
    echo "Error: Could not determine public IP" >&2
    return 1
  fi
  echo "$ip"
}
PUBLIC_IP=$(get_public_ip)

# Determine Domain
if [[ "${var.domainName}" == "" ]]; then
  [ ! -d "/usr/share/openvidu" ] && mkdir -p /usr/share/openvidu
  RANDOM_DOMAIN_STRING=$(tr -dc 'a-z' < /dev/urandom | head -c 8)
  DOMAIN="openvidu-$RANDOM_DOMAIN_STRING-$(echo $PUBLIC_IP | tr '.' '-').sslip.io"
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

# Store usernames and generate random passwords
REDIS_PASSWORD="$(/usr/local/bin/store_secret.sh generate REDIS_PASSWORD)"
MONGO_ADMIN_USERNAME="$(/usr/local/bin/store_secret.sh save MONGO_ADMIN_USERNAME "mongoadmin")"
MONGO_ADMIN_PASSWORD="$(/usr/local/bin/store_secret.sh generate MONGO_ADMIN_PASSWORD)"
MONGO_REPLICA_SET_KEY="$(/usr/local/bin/store_secret.sh generate MONGO_REPLICA_SET_KEY)"
DASHBOARD_ADMIN_USERNAME="$(/usr/local/bin/store_secret.sh save DASHBOARD_ADMIN_USERNAME "dashboardadmin")"
DASHBOARD_ADMIN_PASSWORD="$(/usr/local/bin/store_secret.sh generate DASHBOARD_ADMIN_PASSWORD)"
GRAFANA_ADMIN_USERNAME="$(/usr/local/bin/store_secret.sh save GRAFANA_ADMIN_USERNAME "grafanaadmin")"
GRAFANA_ADMIN_PASSWORD="$(/usr/local/bin/store_secret.sh generate GRAFANA_ADMIN_PASSWORD)"
ENABLED_MODULES="$(/usr/local/bin/store_secret.sh save ENABLED_MODULES "observability,openviduMeet")"
LIVEKIT_API_KEY="$(/usr/local/bin/store_secret.sh generate LIVEKIT_API_KEY "API" 12)"
LIVEKIT_API_SECRET="$(/usr/local/bin/store_secret.sh generate LIVEKIT_API_SECRET)"

# Build install command
INSTALL_COMMAND="sh <(curl -fsSL http://get.openvidu.io/community/singlenode/$OPENVIDU_VERSION/install.sh)"

# Common arguments
COMMON_ARGS=(
  "--no-tty"
  "--install"
  "--environment=oracle"
  "--deployment-type=single_node"
  "--domain-name=$DOMAIN"
  "--enabled-modules='$ENABLED_MODULES'"
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

# Only pass --meet-initial-api-key when the user provided one; an empty value
# would null out the installer default.
if [[ "${var.initialMeetApiKey}" != '' ]]; then
  COMMON_ARGS+=("--meet-initial-api-key=$MEET_INITIAL_API_KEY")
fi

# Append user-provided installer flags
if [[ "${var.additionalInstallFlags}" != "" ]]; then
  IFS=',' read -ra EXTRA_FLAGS <<< "${var.additionalInstallFlags}"
  for extra_flag in "$${EXTRA_FLAGS[@]}"; do
    # Trim whitespace around each flag
    extra_flag="$(echo -e "$${extra_flag}" | sed -e 's/^[ \t]*//' -e 's/[ \t]*$//')"
    if [[ "$extra_flag" != "" ]]; then
      COMMON_ARGS+=("$extra_flag")
    fi
  done
fi

# Certificate arguments
if [[ "${var.certificateType}" == "selfsigned" ]]; then
  CERT_ARGS=(
    "--certificate-type=selfsigned"
  )
elif [[ "${var.certificateType}" == "letsencrypt" ]]; then
  CERT_ARGS=(
    "--certificate-type=letsencrypt"
  )
else
  # Use base64 encoded certificates directly
  OWN_CERT_CRT=${var.ownPublicCertificate}
  OWN_CERT_KEY=${var.ownPrivateCertificate}
  CERT_ARGS=(
    "--certificate-type=owncert"
    "--owncert-public-key=$OWN_CERT_CRT"
    "--owncert-private-key=$OWN_CERT_KEY"
  )
fi

# Final command
FINAL_COMMAND="$INSTALL_COMMAND $(printf "%s " "$${COMMON_ARGS[@]}") $(printf "%s " "$${CERT_ARGS[@]}")"

# Execute installation
exec bash -c "$FINAL_COMMAND"
EOF

  config_s3_script = <<-EOF
#!/bin/bash -x
set -e

# Install dir and config dir
INSTALL_DIR="/opt/openvidu"
CONFIG_DIR="$${INSTALL_DIR}/config"


# OCI Object Storage S3-compatible endpoint:
# https://<namespace>.compat.objectstorage.<region>.oraclecloud.com
EXTERNAL_S3_ENDPOINT="https://${local.bucket_namespace}.compat.objectstorage.${var.region}.oraclecloud.com"
EXTERNAL_S3_REGION="${var.region}"
EXTERNAL_S3_PATH_STYLE_ACCESS="true"
EXTERNAL_S3_BUCKET_APP_DATA="${local.bucket_name}"

# S3 credentials: Customer Secret Key generated by Terraform for this deployment
EXTERNAL_S3_ACCESS_KEY="${oci_identity_customer_secret_key.openvidu_s3_key.id}"
EXTERNAL_S3_SECRET_KEY="${oci_identity_customer_secret_key.openvidu_s3_key.key}"

sed -i "s|EXTERNAL_S3_ENDPOINT=.*|EXTERNAL_S3_ENDPOINT=$EXTERNAL_S3_ENDPOINT|" "$${CONFIG_DIR}/openvidu.env"
sed -i "s|EXTERNAL_S3_REGION=.*|EXTERNAL_S3_REGION=$EXTERNAL_S3_REGION|" "$${CONFIG_DIR}/openvidu.env"
sed -i "s|EXTERNAL_S3_PATH_STYLE_ACCESS=.*|EXTERNAL_S3_PATH_STYLE_ACCESS=$EXTERNAL_S3_PATH_STYLE_ACCESS|" "$${CONFIG_DIR}/openvidu.env"
sed -i "s|EXTERNAL_S3_BUCKET_APP_DATA=.*|EXTERNAL_S3_BUCKET_APP_DATA=$EXTERNAL_S3_BUCKET_APP_DATA|" "$${CONFIG_DIR}/openvidu.env"
sed -i "s|EXTERNAL_S3_ACCESS_KEY=.*|EXTERNAL_S3_ACCESS_KEY=$EXTERNAL_S3_ACCESS_KEY|" "$${CONFIG_DIR}/openvidu.env"
sed -i "s|EXTERNAL_S3_SECRET_KEY=.*|EXTERNAL_S3_SECRET_KEY=$EXTERNAL_S3_SECRET_KEY|" "$${CONFIG_DIR}/openvidu.env"
EOF

  after_install_script = <<-EOF
#!/bin/bash
set -e

export HOME="/root"
export PATH="$PATH:$HOME/.local/bin"

# URLs derived from the domain stored in vault
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
CONFIG_DIR="$${INSTALL_DIR}/config"

# Replace DOMAIN_NAME first (everything else depends on it)
export DOMAIN=$(get_from_vault DOMAIN_NAME)
if [[ -z "$DOMAIN" ]]; then
    exit 1
fi
sed -i "s/DOMAIN_NAME=.*/DOMAIN_NAME=$DOMAIN/" "$${CONFIG_DIR}/openvidu.env"

# Get the rest of the values
export REDIS_PASSWORD=$(get_from_vault REDIS_PASSWORD)
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

# Replace rest of the values
sed -i "s/REDIS_PASSWORD=.*/REDIS_PASSWORD=$REDIS_PASSWORD/" "$${CONFIG_DIR}/openvidu.env"
sed -i "s/MONGO_ADMIN_USERNAME=.*/MONGO_ADMIN_USERNAME=$MONGO_ADMIN_USERNAME/" "$${CONFIG_DIR}/openvidu.env"
sed -i "s/MONGO_ADMIN_PASSWORD=.*/MONGO_ADMIN_PASSWORD=$MONGO_ADMIN_PASSWORD/" "$${CONFIG_DIR}/openvidu.env"
sed -i "s/MONGO_REPLICA_SET_KEY=.*/MONGO_REPLICA_SET_KEY=$MONGO_REPLICA_SET_KEY/" "$${CONFIG_DIR}/openvidu.env"
sed -i "s/DASHBOARD_ADMIN_USERNAME=.*/DASHBOARD_ADMIN_USERNAME=$DASHBOARD_ADMIN_USERNAME/" "$${CONFIG_DIR}/openvidu.env"
sed -i "s/DASHBOARD_ADMIN_PASSWORD=.*/DASHBOARD_ADMIN_PASSWORD=$DASHBOARD_ADMIN_PASSWORD/" "$${CONFIG_DIR}/openvidu.env"
sed -i "s/GRAFANA_ADMIN_USERNAME=.*/GRAFANA_ADMIN_USERNAME=$GRAFANA_ADMIN_USERNAME/" "$${CONFIG_DIR}/openvidu.env"
sed -i "s/GRAFANA_ADMIN_PASSWORD=.*/GRAFANA_ADMIN_PASSWORD=$GRAFANA_ADMIN_PASSWORD/" "$${CONFIG_DIR}/openvidu.env"
sed -i "s/LIVEKIT_API_KEY=.*/LIVEKIT_API_KEY=$LIVEKIT_API_KEY/" "$${CONFIG_DIR}/openvidu.env"
sed -i "s/LIVEKIT_API_SECRET=.*/LIVEKIT_API_SECRET=$LIVEKIT_API_SECRET/" "$${CONFIG_DIR}/openvidu.env"
sed -i "s/MEET_INITIAL_ADMIN_USER=.*/MEET_INITIAL_ADMIN_USER=$MEET_INITIAL_ADMIN_USER/" "$${CONFIG_DIR}/meet.env"
sed -i "s/MEET_INITIAL_ADMIN_PASSWORD=.*/MEET_INITIAL_ADMIN_PASSWORD=$MEET_INITIAL_ADMIN_PASSWORD/" "$${CONFIG_DIR}/meet.env"
if [[ "${var.initialMeetApiKey}" != '' ]]; then
  sed -i "s/MEET_INITIAL_API_KEY=.*/MEET_INITIAL_API_KEY=$MEET_INITIAL_API_KEY/" "$${CONFIG_DIR}/meet.env"
fi
sed -i "s/ENABLED_MODULES=.*/ENABLED_MODULES=$ENABLED_MODULES/" "$${CONFIG_DIR}/openvidu.env"

# URLs derived from the (possibly user-edited) domain
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
CONFIG_DIR="$${INSTALL_DIR}/config"

# Skip writes when the config has no real value, else an unset/commented-out key
# gets persisted to vault as the literal "" or "none", corrupting the secret.
maybe_save() {
  local key="$1"
  local value="$2"
  if [[ -z "$value" || "$value" == "none" ]]; then
    echo "[update_secret_from_config] Skipping '$key': empty value in config" >&2
    return 0
  fi
  store_in_vault "$key" "$value"
}

# Read current values from the env files
REDIS_PASSWORD="$(/usr/local/bin/get_value_from_config.sh REDIS_PASSWORD "$${CONFIG_DIR}/openvidu.env")"
DOMAIN_NAME="$(/usr/local/bin/get_value_from_config.sh DOMAIN_NAME "$${CONFIG_DIR}/openvidu.env")"
MONGO_ADMIN_USERNAME="$(/usr/local/bin/get_value_from_config.sh MONGO_ADMIN_USERNAME "$${CONFIG_DIR}/openvidu.env")"
MONGO_ADMIN_PASSWORD="$(/usr/local/bin/get_value_from_config.sh MONGO_ADMIN_PASSWORD "$${CONFIG_DIR}/openvidu.env")"
MONGO_REPLICA_SET_KEY="$(/usr/local/bin/get_value_from_config.sh MONGO_REPLICA_SET_KEY "$${CONFIG_DIR}/openvidu.env")"
DASHBOARD_ADMIN_USERNAME="$(/usr/local/bin/get_value_from_config.sh DASHBOARD_ADMIN_USERNAME "$${CONFIG_DIR}/openvidu.env")"
DASHBOARD_ADMIN_PASSWORD="$(/usr/local/bin/get_value_from_config.sh DASHBOARD_ADMIN_PASSWORD "$${CONFIG_DIR}/openvidu.env")"
GRAFANA_ADMIN_USERNAME="$(/usr/local/bin/get_value_from_config.sh GRAFANA_ADMIN_USERNAME "$${CONFIG_DIR}/openvidu.env")"
GRAFANA_ADMIN_PASSWORD="$(/usr/local/bin/get_value_from_config.sh GRAFANA_ADMIN_PASSWORD "$${CONFIG_DIR}/openvidu.env")"
LIVEKIT_API_KEY="$(/usr/local/bin/get_value_from_config.sh LIVEKIT_API_KEY "$${CONFIG_DIR}/openvidu.env")"
LIVEKIT_API_SECRET="$(/usr/local/bin/get_value_from_config.sh LIVEKIT_API_SECRET "$${CONFIG_DIR}/openvidu.env")"
MEET_INITIAL_ADMIN_USER="$(/usr/local/bin/get_value_from_config.sh MEET_INITIAL_ADMIN_USER "$${CONFIG_DIR}/meet.env")"
MEET_INITIAL_ADMIN_PASSWORD="$(/usr/local/bin/get_value_from_config.sh MEET_INITIAL_ADMIN_PASSWORD "$${CONFIG_DIR}/meet.env")"
if [[ "${var.initialMeetApiKey}" != '' ]]; then
  MEET_INITIAL_API_KEY="$(/usr/local/bin/get_value_from_config.sh MEET_INITIAL_API_KEY "$${CONFIG_DIR}/meet.env")"
fi
ENABLED_MODULES="$(/usr/local/bin/get_value_from_config.sh ENABLED_MODULES "$${CONFIG_DIR}/openvidu.env")"

maybe_save REDIS_PASSWORD "$REDIS_PASSWORD"
maybe_save DOMAIN_NAME "$DOMAIN_NAME"
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
#!/bin/bash -x
set -e

# Get the value of a key from an env file
get_value() {
    local key="$1"
    local file_path="$2"
    # grep the key line (skip comments), then take the part after '='
    local value=$(grep -E "^\s*$key\s*=" "$file_path" | awk -F= '{print $2}' | sed 's/#.*//; s/^\s*//; s/\s*$//')
    # Empty value → "none"
    if [ -z "$value" ]; then
        echo "none"
    else
        echo "$value"
    fi
}

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <key> <file_path>"
    exit 1
fi

key="$1"
file_path="$2"

get_value "$key" "$file_path"
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

# Make OCI CLI available (installed via pipx under /root/.local/bin)
export HOME="/root"
export PATH="$PATH:$HOME/.local/bin"

# Stop all services
systemctl stop openvidu

# Update config from secrets
/usr/local/bin/update_config_from_secret.sh

# Start all services
systemctl start openvidu
EOF

  user_data = <<-EOF
#!/bin/bash -x
set -eu -o pipefail

# restart.sh
cat > /usr/local/bin/restart.sh << 'RESTART_EOF'
${local.restart_script}
RESTART_EOF
chmod +x /usr/local/bin/restart.sh

# Check if installation already completed
if [ -f /usr/local/bin/openvidu_install_counter.txt ]; then
  # Launch on reboot
  /usr/local/bin/restart.sh || { echo "[OpenVidu] error restarting OpenVidu"; exit 1; }
else
  # install.sh
  cat > /usr/local/bin/install.sh << 'INSTALL_EOF'
${local.install_script}
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
    python3-pip \
    jq \
    wget \
    ca-certificates \
    gnupg \
    lsb-release \
    openssl \
    pipx \
    firewalld

  # Install OCI CLI via pipx (required on modern Ubuntu)
  OCI_CLI_VERSION="3.83.0"
  pipx install oci-cli==$${OCI_CLI_VERSION}

  # Add pipx bin dir to PATH so 'oci' is found
  export HOME="/root"
  export PATH="$PATH:$HOME/.local/bin"
  
  # Install OpenVidu
  /usr/local/bin/install.sh || { echo "[OpenVidu] error installing OpenVidu"; exit 1; }
  
  # Config S3 bucket
  /usr/local/bin/config_s3.sh || { echo "[OpenVidu] error configuring S3 bucket"; exit 1; }

  # Start OpenVidu
  systemctl start openvidu || { echo "[OpenVidu] error starting OpenVidu"; exit 1; }

  # Update shared secrets
  /usr/local/bin/after_install.sh || { echo "[OpenVidu] error updating shared secrets"; exit 1; }

  # restart.sh on reboot
  echo "@reboot /usr/local/bin/restart.sh >> /var/log/openvidu-restart.log 2>&1" | crontab
  
  # Mark installation as complete
  echo "installation_complete" > /usr/local/bin/openvidu_install_counter.txt
fi

# Wait for the app
/usr/local/bin/check_app_ready.sh
EOF
}
