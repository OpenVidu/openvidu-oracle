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

# Base Security List for subnet
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

# Master NSG
resource "oci_core_network_security_group" "master_nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.openvidu_vcn.id
  display_name   = "${var.stackName}-master-nsg"
}

# Media NSG
resource "oci_core_network_security_group" "media_nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.openvidu_vcn.id
  display_name   = "${var.stackName}-media-nsg"
}

# NLB NSG (for the Network Load Balancer)
resource "oci_core_network_security_group" "nlb_nsg" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.openvidu_vcn.id
  display_name   = "${var.stackName}-nlb-nsg"
}

# NSG common egress
resource "oci_core_network_security_group_security_rule" "master_nsg_egress" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "EGRESS"
  destination               = "0.0.0.0/0"
  protocol                  = "all"
}

resource "oci_core_network_security_group_security_rule" "media_nsg_egress" {
  network_security_group_id = oci_core_network_security_group.media_nsg.id
  direction                 = "EGRESS"
  destination               = "0.0.0.0/0"
  protocol                  = "all"
}

resource "oci_core_network_security_group_security_rule" "nlb_nsg_egress" {
  network_security_group_id = oci_core_network_security_group.nlb_nsg.id
  direction                 = "EGRESS"
  destination               = "0.0.0.0/0"
  protocol                  = "all"
}

# Master ingress from Internet: SSH, HTTP, HTTPS, RTMP
resource "oci_core_network_security_group_security_rule" "master_ingress_ssh" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
  description = "Master SSH"
}

resource "oci_core_network_security_group_security_rule" "master_ingress_http" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
  description = "Master HTTP"
}

resource "oci_core_network_security_group_security_rule" "master_ingress_https" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
  description = "Master HTTPS"
}

resource "oci_core_network_security_group_security_rule" "master_ingress_rtmp" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  tcp_options {
    destination_port_range {
      min = 1935
      max = 1935
    }
  }
  description = "Master RTMP"
}

resource "oci_core_network_security_group_security_rule" "master_ingress_livekit" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  tcp_options {
    destination_port_range {
      min = 7880
      max = 7880
    }
  }
  description = "Master LiveKit HTTP"
}

resource "oci_core_network_security_group_security_rule" "master_ingress_turn_tls" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  tcp_options {
    destination_port_range {
      min = 5349
      max = 5349
    }
  }
  description = "Master TURN TLS"
}

resource "oci_core_network_security_group_security_rule" "master_ingress_openvidu_v2" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  tcp_options {
    destination_port_range {
      min = 1945
      max = 1945
    }
  }
  description = "Master OpenVidu v2 compatibility"
}

# NLB ingress from Internet: 443, 80, 1935
resource "oci_core_network_security_group_security_rule" "nlb_ingress_https" {
  network_security_group_id = oci_core_network_security_group.nlb_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
  description = "NLB HTTPS"
}

resource "oci_core_network_security_group_security_rule" "nlb_ingress_http" {
  network_security_group_id = oci_core_network_security_group.nlb_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
  description = "NLB HTTP"
}

resource "oci_core_network_security_group_security_rule" "nlb_ingress_rtmp" {
  network_security_group_id = oci_core_network_security_group.nlb_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  tcp_options {
    destination_port_range {
      min = 1935
      max = 1935
    }
  }
  description = "NLB RTMP"
}

# Media ingress from Internet: SSH, TCP 7881, 50000-60000, UDP 443, 7885, 50000-60000
resource "oci_core_network_security_group_security_rule" "media_ingress_ssh" {
  network_security_group_id = oci_core_network_security_group.media_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
  description = "Media SSH"
}

resource "oci_core_network_security_group_security_rule" "media_ingress_tcp_7881" {
  network_security_group_id = oci_core_network_security_group.media_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  tcp_options {
    destination_port_range {
      min = 7881
      max = 7881
    }
  }
  description = "Media TCP 7881"
}

resource "oci_core_network_security_group_security_rule" "media_ingress_tcp_range" {
  network_security_group_id = oci_core_network_security_group.media_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  tcp_options {
    destination_port_range {
      min = 50000
      max = 60000
    }
  }
  description = "Media TCP range 50000-60000"
}

resource "oci_core_network_security_group_security_rule" "media_ingress_udp_443" {
  network_security_group_id = oci_core_network_security_group.media_nsg.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = "0.0.0.0/0"
  udp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
  description = "Media UDP 443"
}

resource "oci_core_network_security_group_security_rule" "media_ingress_udp_7885" {
  network_security_group_id = oci_core_network_security_group.media_nsg.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = "0.0.0.0/0"
  udp_options {
    destination_port_range {
      min = 7885
      max = 7885
    }
  }
  description = "Media UDP 7885"
}

resource "oci_core_network_security_group_security_rule" "media_ingress_udp_range" {
  network_security_group_id = oci_core_network_security_group.media_nsg.id
  direction                 = "INGRESS"
  protocol                  = "17"
  source                    = "0.0.0.0/0"
  udp_options {
    destination_port_range {
      min = 50000
      max = 60000
    }
  }
  description = "Media UDP range 50000-60000"
}

# Master-to-Master internal communication
resource "oci_core_network_security_group_security_rule" "master_to_master_7000_7001" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.master_nsg.id
  tcp_options {
    destination_port_range {
      min = 7000
      max = 7001
    }
  }
  description = "Master to Master 7000-7001"
}

resource "oci_core_network_security_group_security_rule" "master_to_master_9100_9101" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.master_nsg.id
  tcp_options {
    destination_port_range {
      min = 9100
      max = 9101
    }
  }
  description = "Master to Master 9100-9101"
}

resource "oci_core_network_security_group_security_rule" "master_to_master_20000" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.master_nsg.id
  tcp_options {
    destination_port_range {
      min = 20000
      max = 20000
    }
  }
  description = "Master to Master 20000"
}

resource "oci_core_network_security_group_security_rule" "master_to_master_9095" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.master_nsg.id
  tcp_options {
    destination_port_range {
      min = 9095
      max = 9095
    }
  }
  description = "Master to Master 9095"
}

resource "oci_core_network_security_group_security_rule" "master_to_master_7946" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.master_nsg.id
  tcp_options {
    destination_port_range {
      min = 7946
      max = 7946
    }
  }
  description = "Master to Master 7946"
}

resource "oci_core_network_security_group_security_rule" "master_to_master_9096" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.master_nsg.id
  tcp_options {
    destination_port_range {
      min = 9096
      max = 9096
    }
  }
  description = "Master to Master 9096"
}

resource "oci_core_network_security_group_security_rule" "master_to_master_7947" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.master_nsg.id
  tcp_options {
    destination_port_range {
      min = 7947
      max = 7947
    }
  }
  description = "Master to Master 7947"
}

resource "oci_core_network_security_group_security_rule" "master_to_master_5000" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.master_nsg.id
  tcp_options {
    destination_port_range {
      min = 5000
      max = 5000
    }
  }
  description = "Master to Master 5000"
}

resource "oci_core_network_security_group_security_rule" "master_to_master_3000" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.master_nsg.id
  tcp_options {
    destination_port_range {
      min = 3000
      max = 3000
    }
  }
  description = "Master to Master 3000"
}

resource "oci_core_network_security_group_security_rule" "master_to_master_4443" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.master_nsg.id
  tcp_options {
    destination_port_range {
      min = 4443
      max = 4443
    }
  }
  description = "Master to Master 4443"
}

resource "oci_core_network_security_group_security_rule" "master_to_master_9080" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.master_nsg.id
  tcp_options {
    destination_port_range {
      min = 9080
      max = 9080
    }
  }
  description = "Master to Master 9080"
}

resource "oci_core_network_security_group_security_rule" "master_to_master_6080" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.master_nsg.id
  tcp_options {
    destination_port_range {
      min = 6080
      max = 6080
    }
  }
  description = "Master to Master 6080"
}

# Media -> Master communication
resource "oci_core_network_security_group_security_rule" "master_ingress_from_media_7000" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.media_nsg.id
  tcp_options {
    destination_port_range {
      min = 7000
      max = 7001
    }
  }
  description = "Media to Master 7000-7001"
}

resource "oci_core_network_security_group_security_rule" "master_ingress_from_media_7880" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.media_nsg.id
  tcp_options {
    destination_port_range {
      min = 7880
      max = 7880
    }
  }
  description = "Media to Master 7880"
}

resource "oci_core_network_security_group_security_rule" "master_ingress_from_media_9100" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.media_nsg.id
  tcp_options {
    destination_port_range {
      min = 9100
      max = 9100
    }
  }
  description = "Media to Master 9100"
}

resource "oci_core_network_security_group_security_rule" "master_ingress_from_media_20000" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.media_nsg.id
  tcp_options {
    destination_port_range {
      min = 20000
      max = 20000
    }
  }
  description = "Media to Master 20000"
}

resource "oci_core_network_security_group_security_rule" "master_ingress_from_media_9009" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.media_nsg.id
  tcp_options {
    destination_port_range {
      min = 9009
      max = 9009
    }
  }
  description = "Media to Master 9009"
}

resource "oci_core_network_security_group_security_rule" "master_ingress_from_media_3100" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.media_nsg.id
  tcp_options {
    destination_port_range {
      min = 3100
      max = 3100
    }
  }
  description = "Media to Master 3100"
}

resource "oci_core_network_security_group_security_rule" "master_ingress_from_media_4443" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.media_nsg.id
  tcp_options {
    destination_port_range {
      min = 4443
      max = 4443
    }
  }
  description = "Media to Master 4443"
}

resource "oci_core_network_security_group_security_rule" "master_ingress_from_media_9080" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.media_nsg.id
  tcp_options {
    destination_port_range {
      min = 9080
      max = 9080
    }
  }
  description = "Media to Master 9080"
}

resource "oci_core_network_security_group_security_rule" "master_ingress_from_media_6080" {
  network_security_group_id = oci_core_network_security_group.master_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.media_nsg.id
  tcp_options {
    destination_port_range {
      min = 6080
      max = 6080
    }
  }
  description = "Media to Master 6080"
}

# Master -> Media communication
resource "oci_core_network_security_group_security_rule" "media_ingress_from_master_1935" {
  network_security_group_id = oci_core_network_security_group.media_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.master_nsg.id
  tcp_options {
    destination_port_range {
      min = 1935
      max = 1935
    }
  }
  description = "Master to Media 1935"
}

resource "oci_core_network_security_group_security_rule" "media_ingress_from_master_5349" {
  network_security_group_id = oci_core_network_security_group.media_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.master_nsg.id
  tcp_options {
    destination_port_range {
      min = 5349
      max = 5349
    }
  }
  description = "Master to Media 5349"
}

resource "oci_core_network_security_group_security_rule" "media_ingress_from_master_7880" {
  network_security_group_id = oci_core_network_security_group.media_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.master_nsg.id
  tcp_options {
    destination_port_range {
      min = 7880
      max = 7880
    }
  }
  description = "Master to Media 7880"
}

resource "oci_core_network_security_group_security_rule" "media_ingress_from_master_8080" {
  network_security_group_id = oci_core_network_security_group.media_nsg.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source_type               = "NETWORK_SECURITY_GROUP"
  source                    = oci_core_network_security_group.master_nsg.id
  tcp_options {
    destination_port_range {
      min = 8080
      max = 8080
    }
  }
  description = "Master to Media 8080"
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

# ------------------------- Network Load Balancer -------------------------

# Reserved public IP for NLB (conditional creation)
resource "oci_core_public_ip" "nlb_ip" {
  count          = var.publicIpAddress == "" ? 1 : 0
  compartment_id = var.compartment_ocid
  lifetime       = "RESERVED"
  display_name   = "${var.stackName}-nlb-ip"
}

# OCI Network Load Balancer (Layer-4, TCP passthrough)
resource "oci_network_load_balancer_network_load_balancer" "nlb" {
  compartment_id = var.compartment_ocid
  display_name   = "${var.stackName}-nlb"
  subnet_id      = oci_core_subnet.openvidu_subnet.id

  # Assign reserved IP if we created one; otherwise use provided OCID
  reserved_ips {
    id = var.publicIpAddress != "" ? var.publicIpAddress : oci_core_public_ip.nlb_ip[0].id
  }

  is_private                     = false
  is_preserve_source_destination = false

  network_security_group_ids = [oci_core_network_security_group.nlb_nsg.id]
}

# Backend set for master nodes (health check on port 7880)
resource "oci_network_load_balancer_backend_set" "master_backend_set" {
  name                     = "master-backend-set"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb.id
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = false

  health_checker {
    protocol           = "TCP"
    port               = 7880
    interval_in_millis = 10000
    timeout_in_millis  = 5000
    retries            = 3
  }
}

# Backends: the 4 master nodes
resource "oci_network_load_balancer_backend" "master_backend_1" {
  backend_set_name         = oci_network_load_balancer_backend_set.master_backend_set.name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb.id
  port                     = 443
  target_id                = oci_core_instance.openvidu_master_node_1.id

  depends_on = [oci_core_instance.openvidu_master_node_1]
}

resource "oci_network_load_balancer_backend" "master_backend_2" {
  backend_set_name         = oci_network_load_balancer_backend_set.master_backend_set.name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb.id
  port                     = 443
  target_id                = oci_core_instance.openvidu_master_node_2.id

  depends_on = [oci_core_instance.openvidu_master_node_2]
}

resource "oci_network_load_balancer_backend" "master_backend_3" {
  backend_set_name         = oci_network_load_balancer_backend_set.master_backend_set.name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb.id
  port                     = 443
  target_id                = oci_core_instance.openvidu_master_node_3.id

  depends_on = [oci_core_instance.openvidu_master_node_3]
}

resource "oci_network_load_balancer_backend" "master_backend_4" {
  backend_set_name         = oci_network_load_balancer_backend_set.master_backend_set.name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb.id
  port                     = 443
  target_id                = oci_core_instance.openvidu_master_node_4.id

  depends_on = [oci_core_instance.openvidu_master_node_4]
}

# NLB Listeners: TCP 443, 80, 1935
resource "oci_network_load_balancer_listener" "listener_443" {
  name                     = "listener-443"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb.id
  default_backend_set_name = oci_network_load_balancer_backend_set.master_backend_set.name
  port                     = 443
  protocol                 = "TCP"
}

resource "oci_network_load_balancer_listener" "listener_80" {
  name                     = "listener-80"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb.id
  default_backend_set_name = oci_network_load_balancer_backend_set.master_backend_set.name
  port                     = 80
  protocol                 = "TCP"
}

resource "oci_network_load_balancer_listener" "listener_1935" {
  name                     = "listener-1935"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb.id
  default_backend_set_name = oci_network_load_balancer_backend_set.master_backend_set.name
  port                     = 1935
  protocol                 = "TCP"
}

# ------------------------- Object Storage -------------------------

# Customer Secret Key for S3-compatible access
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

resource "oci_objectstorage_bucket" "clusterdata_bucket" {
  count          = var.bucketClusterDataName == "" ? 1 : 0
  compartment_id = var.compartment_ocid
  name           = "${var.stackName}-clusterdata-${random_id.suffix.hex}"
  namespace      = data.oci_objectstorage_namespace.ns.namespace
  access_type    = "NoPublicAccess"
}

locals {
  bucket_app_data_name     = var.bucketAppDataName != "" ? var.bucketAppDataName : oci_objectstorage_bucket.appdata_bucket[0].name
  bucket_cluster_data_name = var.bucketClusterDataName != "" ? var.bucketClusterDataName : oci_objectstorage_bucket.clusterdata_bucket[0].name
}

# Upload SSH private key to cluster data bucket
resource "oci_objectstorage_object" "ssh_private_key" {
  namespace = data.oci_objectstorage_namespace.ns.namespace
  bucket    = local.bucket_cluster_data_name
  object    = "${var.stackName}-private-key.pem"
  content   = tls_private_key.openvidu_ssh_key_ha.private_key_pem

  depends_on = [oci_objectstorage_bucket.clusterdata_bucket]
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

resource "oci_kms_key" "openvidu_key" {
  count               = var.key_ocid == "" ? 1 : 0
  compartment_id      = var.compartment_ocid
  display_name        = "${var.stackName}-key"
  management_endpoint = data.oci_kms_vault.openvidu_vault.management_endpoint

  key_shape {
    algorithm = "AES"
    length    = 32
  }

  depends_on = [oci_kms_vault.openvidu_vault]
}

data "oci_kms_key" "openvidu_key" {
  management_endpoint = data.oci_kms_vault.openvidu_vault.management_endpoint
  key_id              = var.key_ocid != "" ? var.key_ocid : oci_kms_key.openvidu_key[0].id
}

# ------------------------- IAM -------------------------

resource "oci_identity_dynamic_group" "openvidu_instances_dg" {
  compartment_id = var.tenancy_ocid
  name           = "${var.stackName}-instances-dg"
  description    = "Dynamic group for OpenVidu HA instances (Instance Principal auth)"
  matching_rule  = "instance.compartment.id = '${var.compartment_ocid}'"
}

resource "oci_identity_policy" "openvidu_ha_policy" {
  compartment_id = var.compartment_ocid
  name           = "${var.stackName}-ha-policy"
  description    = "Allow OpenVidu HA instances to manage their own lifecycle and secrets"
  statements = [
    "allow dynamic-group ${oci_identity_dynamic_group.openvidu_instances_dg.name} to manage instance-pools in compartment id ${var.compartment_ocid}",
    "allow dynamic-group ${oci_identity_dynamic_group.openvidu_instances_dg.name} to manage instances in compartment id ${var.compartment_ocid}",
    "allow dynamic-group ${oci_identity_dynamic_group.openvidu_instances_dg.name} to manage secret-family in compartment id ${var.compartment_ocid}",
    "allow dynamic-group ${oci_identity_dynamic_group.openvidu_instances_dg.name} to use vaults in compartment id ${var.compartment_ocid}",
    "allow dynamic-group ${oci_identity_dynamic_group.openvidu_instances_dg.name} to use keys in compartment id ${var.compartment_ocid}",
  ]
}

# ------------------------- Compute Instances (Master Nodes) -------------------------

# Master Node 1
resource "oci_core_instance" "openvidu_master_node_1" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_ocid
  display_name        = "${var.stackName}-master-node-1"
  shape               = var.masterNodeShape

  shape_config {
    ocpus         = var.masterNodeOcpus
    memory_in_gbs = var.masterNodeMemory
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.openvidu_subnet.id
    assign_public_ip = true
    display_name     = "master-node-1-vnic"
    nsg_ids          = [oci_core_network_security_group.master_nsg.id]
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_master.images[0].id
    boot_volume_size_in_gbs = var.masterNodeDiskSize
  }

  metadata = {
    ssh_authorized_keys = tls_private_key.openvidu_ssh_key_ha.public_key_openssh
    user_data           = base64gzip(local.user_data_master)
    masterNodeNum       = "1"
  }

  freeform_tags = {
    "stack"     = var.stackName
    "node-type" = "master"
    "node-num"  = "1"
  }
}

# Master Node 2 — waits for Node 1 to be created first (matching GCP sequential pattern)
resource "oci_core_instance" "openvidu_master_node_2" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_ocid
  display_name        = "${var.stackName}-master-node-2"
  shape               = var.masterNodeShape

  shape_config {
    ocpus         = var.masterNodeOcpus
    memory_in_gbs = var.masterNodeMemory
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.openvidu_subnet.id
    assign_public_ip = true
    display_name     = "master-node-2-vnic"
    nsg_ids          = [oci_core_network_security_group.master_nsg.id]
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_master.images[0].id
    boot_volume_size_in_gbs = var.masterNodeDiskSize
  }

  metadata = {
    ssh_authorized_keys = tls_private_key.openvidu_ssh_key_ha.public_key_openssh
    user_data           = base64gzip(local.user_data_master)
    masterNodeNum       = "2"
  }

  freeform_tags = {
    "stack"     = var.stackName
    "node-type" = "master"
    "node-num"  = "2"
  }

  depends_on = [oci_core_instance.openvidu_master_node_1]
}

# Master Node 3
resource "oci_core_instance" "openvidu_master_node_3" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_ocid
  display_name        = "${var.stackName}-master-node-3"
  shape               = var.masterNodeShape

  shape_config {
    ocpus         = var.masterNodeOcpus
    memory_in_gbs = var.masterNodeMemory
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.openvidu_subnet.id
    assign_public_ip = true
    display_name     = "master-node-3-vnic"
    nsg_ids          = [oci_core_network_security_group.master_nsg.id]
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_master.images[0].id
    boot_volume_size_in_gbs = var.masterNodeDiskSize
  }

  metadata = {
    ssh_authorized_keys = tls_private_key.openvidu_ssh_key_ha.public_key_openssh
    user_data           = base64gzip(local.user_data_master)
    masterNodeNum       = "3"
  }

  freeform_tags = {
    "stack"     = var.stackName
    "node-type" = "master"
    "node-num"  = "3"
  }

  depends_on = [oci_core_instance.openvidu_master_node_2]
}

# Master Node 4
resource "oci_core_instance" "openvidu_master_node_4" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_ocid
  display_name        = "${var.stackName}-master-node-4"
  shape               = var.masterNodeShape

  shape_config {
    ocpus         = var.masterNodeOcpus
    memory_in_gbs = var.masterNodeMemory
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.openvidu_subnet.id
    assign_public_ip = true
    display_name     = "master-node-4-vnic"
    nsg_ids          = [oci_core_network_security_group.master_nsg.id]
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_master.images[0].id
    boot_volume_size_in_gbs = var.masterNodeDiskSize
  }

  metadata = {
    ssh_authorized_keys = tls_private_key.openvidu_ssh_key_ha.public_key_openssh
    user_data           = base64gzip(local.user_data_master)
    masterNodeNum       = "4"
  }

  freeform_tags = {
    "stack"     = var.stackName
    "node-type" = "master"
    "node-num"  = "4"
  }

  depends_on = [oci_core_instance.openvidu_master_node_3]
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
        ssh_authorized_keys     = tls_private_key.openvidu_ssh_key_ha.public_key_openssh
        user_data               = base64gzip(local.user_data_media)
        masterNodePrivateIPList = "${oci_core_instance.openvidu_master_node_1.private_ip},${oci_core_instance.openvidu_master_node_2.private_ip},${oci_core_instance.openvidu_master_node_3.private_ip},${oci_core_instance.openvidu_master_node_4.private_ip}"
      }

      freeform_tags = {
        "stack"     = var.stackName
        "node-type" = "media"
      }
    }
  }

  depends_on = [
    oci_core_instance.openvidu_master_node_1,
    oci_core_instance.openvidu_master_node_2,
    oci_core_instance.openvidu_master_node_3,
    oci_core_instance.openvidu_master_node_4,
  ]
}

resource "oci_core_instance_pool" "media_node_pool" {
  compartment_id            = var.compartment_ocid
  instance_configuration_id = oci_core_instance_configuration.media_node_config.id
  display_name              = "${var.stackName}-media-pool"
  size                      = var.initialNumberOfMediaNodes

  placement_configurations {
    availability_domain = data.oci_identity_availability_domain.ad.name
    primary_subnet_id   = oci_core_subnet.openvidu_subnet.id
  }

  depends_on = [
    oci_core_instance.openvidu_master_node_1,
    oci_core_instance.openvidu_master_node_2,
    oci_core_instance.openvidu_master_node_3,
    oci_core_instance.openvidu_master_node_4,
  ]
}

resource "oci_autoscaling_auto_scaling_configuration" "media_node_autoscaling" {
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
    # Threshold is LT 1% — only fires when CPU is essentially 0% (no active sessions).
    # Real scale-in is owned entirely by the pre-drain daemon (detaches itself,
    # drains with no time limit, then self-terminates). The daemon's re-verification
    # step aborts drain if a session starts before detach commits.
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
          value    = 1
        }
      }
    }
  }
}

# ------------------------- Locals & User Data -------------------------

locals {
  # NLB public IP address (from created or provided reserved IP)
  nlb_ip_address = var.publicIpAddress != "" ? (
    # User provided an OCID — look up the actual IP via data source (handled below)
    data.oci_core_public_ip.existing_nlb_ip[0].ip_address
  ) : oci_core_public_ip.nlb_ip[0].ip_address

  # Domain name: use provided or derive from NLB IP using sslip.io
  domain_name = var.domainName != "" ? var.domainName : "openvidu-${replace(local.nlb_ip_address, ".", "-")}.sslip.io"

  # ARM shape detection for yq binary arch
  is_arm_instance = startswith(var.masterNodeShape, "VM.Standard.A") || startswith(var.masterNodeShape, "BM.Standard.A")
  yq_arch         = local.is_arm_instance ? "arm64" : "amd64"
  yq_sha256       = local.is_arm_instance ? "10a4a2093090363a00b55ad52e132a082f9652970cb8f1ad35a1ae048b917e6e" : "3fa3c1c32d94520102ea4d853d03c3ab907867d964540e896410ad8a7fc6c8f7"
}

# Data source to resolve existing reserved public IP OCID -> IP address
data "oci_core_public_ip" "existing_nlb_ip" {
  count = var.publicIpAddress != "" ? 1 : 0
  id    = var.publicIpAddress
}

locals {
  # Pre-drain daemon: monitors pool size and local CPU. When scale-in conditions are met
  # and this is the oldest instance in the pool, the daemon detaches itself from the pool
  # (pool target decrements by 1, OCI spawns no replacement), drains OpenVidu containers
  # with no time constraint, then self-terminates via the OCI API.
  # This is the OCI equivalent of GCP's "remove from MIG + self-delete" — the instance
  # is fully decoupled from the autoscaler before drain starts, so no ACPI timeout applies.
  pre_drain_daemon_script = <<-EOF
#!/bin/bash
# OpenVidu Pre-drain Daemon for OCI HA
# Strategy: sustained idle detection -> SIGQUIT -> detach from pool -> wait indefinitely -> self-terminate

source /etc/openvidu/predrain.conf

# OCI CLI is installed via pipx under /root/.local/bin; systemd does not set HOME
export HOME="/root"
export PATH="$PATH:/root/.local/bin"

DRAIN_LOCK="/var/run/openvidu-drain.lock"
log() { echo "[openvidu-predrain $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" >&2; }

# If drain lock exists, daemon restarted mid-drain — wait for self-termination to complete
if [ -f "$DRAIN_LOCK" ]; then
    log "Drain lock exists — drain already in progress. Waiting for self-termination."
    while true; do sleep 60; done
fi

# Accurate CPU usage via /proc/stat 2-second delta.
# /proc/loadavg is NOT a CPU percentage — it is a queue length and can exceed 100.
get_cpu_usage() {
    read -ra s1 < <(grep '^cpu ' /proc/stat)
    sleep 2
    read -ra s2 < <(grep '^cpu ' /proc/stat)
    local t1=$(( s1[1]+s1[2]+s1[3]+s1[4]+s1[5]+s1[6]+s1[7] ))
    local i1=$${s1[4]}
    local t2=$(( s2[1]+s2[2]+s2[3]+s2[4]+s2[5]+s2[6]+s2[7] ))
    local i2=$${s2[4]}
    awk "BEGIN { printf \"%d\", (1 - ($i2-$i1)/($t2-$t1)) * 100 }"
}

# Retry with exponential backoff (max 5 attempts).
# Captures output internally — partial stdout from failed attempts never
# contaminates the JSON result captured by the caller's $(...).
oci_call() {
    local attempt=0 delay=5 _out
    while true; do
        if _out=$("$@" 2>/dev/null); then
            printf '%s' "$_out"
            return 0
        fi
        attempt=$(( attempt + 1 ))
        [ "$attempt" -ge 5 ] && { log "OCI call failed after 5 attempts."; return 1; }
        log "OCI call failed (attempt $attempt/5). Retrying in $${delay}s..."
        sleep "$delay"
        delay=$(( delay * 2 ))
    done
}

INSTANCE_OCID=$(curl -sf -H "Authorization: Bearer Oracle" \
    "http://169.254.169.254/opc/v2/instance/" | jq -r '.id')
log "Started. Instance: $INSTANCE_OCID"

# Discover pool OCID at runtime via exact display-name match.
# Cannot embed pool OCID at Terraform time: instance_configuration -> user_data -> pool_id
# -> instance_pool -> instance_configuration would be a circular dependency.
POOL_ID=""
while [ -z "$POOL_ID" ]; do
    POOL_ID=$(oci_call oci compute-management instance-pool list \
        --compartment-id "$COMPARTMENT_ID" \
        --lifecycle-state RUNNING \
        --auth instance_principal \
        --all \
        --output json \
        | jq -r --arg n "$POOL_DISPLAY_NAME" \
            '.data[] | select(."display-name" == $n) | .id' \
        | head -1) || true
    if [ -z "$POOL_ID" ]; then
        log "Pool '$POOL_DISPLAY_NAME' not found. Retrying in 30s..."
        sleep 30
    fi
done
log "Pool discovered: $POOL_ID"

# Require N consecutive idle readings before acting — avoids reacting to transient CPU dips
IDLE_STREAK=0
REQUIRED_STREAK=3   # 3 × ~62s ≈ 3 minutes of sustained low CPU

while true; do
    # Only count RUNNING instances — excludes PROVISIONING, TERMINATING, etc.
    # OCI instance-pool list-instances returns InstancePoolInstanceSummary with a 'state'
    # field (compute instance state: RUNNING, STOPPED, ...) not 'lifecycle-state'.
    POOL_JSON=$(oci_call oci compute-management instance-pool list-instances \
        --instance-pool-id "$POOL_ID" \
        --compartment-id "$COMPARTMENT_ID" \
        --auth instance_principal \
        --all \
        --output json) || { log "list-instances failed. Retrying in 60s..."; sleep 60; continue; }

    RUNNING_INSTANCES=$(echo "$POOL_JSON" | \
        jq -c '[.data[] | select(.state == "RUNNING")]')
    POOL_SIZE=$(echo "$RUNNING_INSTANCES" | jq 'length')

    if [ "$POOL_SIZE" -le "$MIN_NODES" ]; then
        [ "$IDLE_STREAK" -gt 0 ] && log "Pool at minimum ($POOL_SIZE). Resetting idle streak."
        IDLE_STREAK=0
        sleep 60
        continue
    fi

    LOCAL_CPU=$(get_cpu_usage)
    log "Pool: $POOL_SIZE running, local CPU: $${LOCAL_CPU}%"

    if [ "$LOCAL_CPU" -ge "$SCALE_IN_CPU_THRESHOLD" ]; then
        [ "$IDLE_STREAK" -gt 0 ] && log "CPU above threshold. Resetting idle streak."
        IDLE_STREAK=0
        sleep 60
        continue
    fi

    IDLE_STREAK=$(( IDLE_STREAK + 1 ))
    log "Idle streak: $IDLE_STREAK/$REQUIRED_STREAK (cpu=$${LOCAL_CPU}% < $${SCALE_IN_CPU_THRESHOLD}%)"

    if [ "$IDLE_STREAK" -lt "$REQUIRED_STREAK" ]; then
        sleep 60
        continue
    fi

    # Select oldest RUNNING instance as sole scale-in candidate
    OLDEST_ID=$(echo "$RUNNING_INSTANCES" | \
        jq -r 'sort_by(.["time-created"]) | .[0].id')

    if [ "$OLDEST_ID" != "$INSTANCE_OCID" ]; then
        log "Oldest instance is $OLDEST_ID (not us). Standing down."
        IDLE_STREAK=0
        sleep 60
        continue
    fi

    # Random jitter 0-30s: staggers decisions from nodes that simultaneously passed the check
    JITTER=$(( RANDOM % 30 ))
    log "We are the oldest idle node. Waiting $${JITTER}s jitter before committing..."
    sleep "$JITTER"

    # Re-verify after jitter — another node may have detached, changing the oldest candidate
    POOL_JSON_RV=$(oci_call oci compute-management instance-pool list-instances \
        --instance-pool-id "$POOL_ID" \
        --compartment-id "$COMPARTMENT_ID" \
        --auth instance_principal \
        --all \
        --output json) || { log "list-instances (re-verify) failed. Retrying in 60s..."; sleep 60; continue; }

    RUNNING_RV=$(echo "$POOL_JSON_RV" | jq -c '[.data[] | select(.state == "RUNNING")]')
    POOL_SIZE_RV=$(echo "$RUNNING_RV" | jq 'length')
    OLDEST_RV=$(echo "$RUNNING_RV" | jq -r 'sort_by(.["time-created"]) | .[0].id')
    CPU_RV=$(get_cpu_usage)

    if [ "$POOL_SIZE_RV" -le "$MIN_NODES" ] || \
       [ "$CPU_RV" -ge "$SCALE_IN_CPU_THRESHOLD" ] || \
       [ "$OLDEST_RV" != "$INSTANCE_OCID" ]; then
        log "Conditions changed after jitter (pool=$POOL_SIZE_RV, cpu=$${CPU_RV}%, oldest=$OLDEST_RV). Aborting."
        IDLE_STREAK=0
        sleep 60
        continue
    fi

    log "Committed to scale-in. Pool: $POOL_SIZE_RV, CPU: $${CPU_RV}%"
    touch "$DRAIN_LOCK"

    # Step 1: SIGQUIT BEFORE detach — stops OpenVidu accepting new sessions while still
    # registered, so the master node doesn't route new rooms here during the detach window
    if command -v docker &>/dev/null; then
        log "Sending SIGQUIT to OpenVidu containers (stop accepting new sessions)..."
        docker container kill --signal=SIGQUIT openvidu 2>/dev/null || true
        docker container kill --signal=SIGQUIT ingress 2>/dev/null || true
        docker container kill --signal=SIGQUIT egress 2>/dev/null || true
        for agent in $(docker ps --filter "label=openvidu-agent=true" --format '{{.Names}}' 2>/dev/null); do
            docker container kill --signal=SIGQUIT "$agent" 2>/dev/null || true
        done
    fi

    # Step 2: Detach from pool — reduces pool target by 1 with no replacement spawned.
    # Instance is now completely independent; OCI will never send ACPI or force-terminate it.
    log "Detaching from pool..."
    oci_call oci compute-management instance-pool detach-instance \
        --instance-pool-id "$POOL_ID" \
        --instance-id "$INSTANCE_OCID" \
        --is-decrement-size true \
        --is-auto-terminate false \
        --auth instance_principal \
        --force \
        && log "Detached from pool." \
        || log "Warning: detach failed — drain continues independently."

    if command -v docker &>/dev/null; then
        log "Waiting for all sessions to end (no time limit)..."
        while [ "$(docker ps --filter 'label=openvidu-agent=true' -q 2>/dev/null | wc -l)" -gt 0 ] || \
              [ "$(docker inspect -f '{{.State.Running}}' openvidu 2>/dev/null)" = "true" ] || \
              [ "$(docker inspect -f '{{.State.Running}}' ingress 2>/dev/null)" = "true" ] || \
              [ "$(docker inspect -f '{{.State.Running}}' egress 2>/dev/null)" = "true" ]; do
            log "Sessions still active. Waiting 30s..."
            sleep 30
        done
        log "All sessions ended."
    fi

    # Step 4: Self-terminate via OCI API (boot volume not preserved)
    log "Self-terminating..."
    oci_call oci compute instance terminate \
        --instance-id "$INSTANCE_OCID" \
        --auth instance_principal \
        --preserve-boot-volume false \
        --force \
        && exit 0 || true

    log "OCI terminate API failed. Falling back to OS shutdown."
    shutdown -h now
    exit 0
done
EOF

  graceful_shutdown_script = <<-EOF
#!/bin/bash
# Fallback graceful shutdown for OpenVidu Media Node (OCI HA)
# Primary drain is handled by the pre-drain daemon; this is only a safety net.

DRAIN_LOCK="/var/run/openvidu-drain.lock"

if [ -f "$DRAIN_LOCK" ]; then
    echo "[graceful-shutdown] Pre-drain daemon already handled drain. Proceeding with shutdown."
    exit 0
fi

echo "[graceful-shutdown] Starting fallback graceful shutdown..."

# Note: no 'set -e' — we must not abort if any individual command fails,
# as that would let the OS power off before containers have stopped.
if command -v docker &>/dev/null; then
    docker container kill --signal=SIGQUIT openvidu 2>/dev/null || true
    docker container kill --signal=SIGQUIT ingress 2>/dev/null || true
    docker container kill --signal=SIGQUIT egress 2>/dev/null || true
    for agent in $(docker ps --filter "label=openvidu-agent=true" --format '{{.Names}}' 2>/dev/null); do
        docker container kill --signal=SIGQUIT "$agent" 2>/dev/null || true
    done

    while [ "$(docker ps --filter 'label=openvidu-agent=true' -q 2>/dev/null | wc -l)" -gt 0 ] || \
          [ "$(docker inspect -f '{{.State.Running}}' openvidu 2>/dev/null)" = "true" ] || \
          [ "$(docker inspect -f '{{.State.Running}}' ingress 2>/dev/null)" = "true" ] || \
          [ "$(docker inspect -f '{{.State.Running}}' egress 2>/dev/null)" = "true" ]; do
        echo "[graceful-shutdown] Waiting for containers to stop..."
        sleep 10
    done
fi

echo "[graceful-shutdown] Completed."
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

# S3 credentials: Customer Secret Key generated by Terraform for this deployment
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

## Master internet-facing ports
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

firewall-cmd --add-port=5349/tcp
firewall-cmd --permanent --add-port=5349/tcp

firewall-cmd --add-port=1945/tcp
firewall-cmd --permanent --add-port=1945/tcp

## Apply rules
firewall-cmd --reload
firewall-cmd --runtime-to-permanent

firewall-cmd --list-all

wget -q "https://github.com/mikefarah/yq/releases/download/$${YQ_VERSION}/yq_linux_${local.yq_arch}.tar.gz" -O /tmp/yq.tar.gz
echo "${local.yq_sha256}  /tmp/yq.tar.gz" | sha256sum -c -
tar xz -f /tmp/yq.tar.gz -C /tmp && mv "/tmp/yq_linux_${local.yq_arch}" /usr/bin/yq
rm -f /tmp/yq.tar.gz

export HOME="/root"
export PATH="$PATH:$HOME/.local/bin"

# Get master node number from OCI IMDS v2 custom metadata
get_meta() { curl -sf -H "Authorization: Bearer Oracle" "http://169.254.169.254/opc/v2/instance/$1"; }
MASTER_NODE_NUM=$(get_meta "" | jq -r '.metadata.masterNodeNum // empty')
PRIVATE_IP=$(get_meta "vnics/" | jq -r '.[0].privateIp' 2>/dev/null || hostname -I | awk '{print $1}')

# Store this node's private IP in the vault so other nodes can discover it
/usr/local/bin/store_secret.sh save "MASTER_NODE_$${MASTER_NODE_NUM}_PRIVATE_IP" "$PRIVATE_IP"

# Node 1 generates all shared secrets; other nodes wait
ALL_SECRETS_GENERATED=$(/usr/local/bin/store_secret.sh get ALL_SECRETS_GENERATED 2>/dev/null || echo "false")

if [[ "$MASTER_NODE_NUM" == "1" ]] && [[ "$ALL_SECRETS_GENERATED" != "true" ]]; then
  # Get NLB public IP for domain derivation
  EXTERNAL_IP="${local.nlb_ip_address}"

  if [[ "${var.domainName}" == "" ]]; then
    RANDOM_DOMAIN_STRING=$(tr -dc 'a-z' < /dev/urandom | head -c 8)
    DOMAIN="openvidu-$RANDOM_DOMAIN_STRING-$(echo $EXTERNAL_IP | tr '.' '-').sslip.io"
  else
    DOMAIN="${var.domainName}"
  fi
  /usr/local/bin/store_secret.sh save DOMAIN_NAME "$DOMAIN"

  MEET_INITIAL_ADMIN_USER="$(/usr/local/bin/store_secret.sh save MEET_INITIAL_ADMIN_USER "admin")"
  if [[ "${var.initialMeetAdminPassword}" != '' ]]; then
    /usr/local/bin/store_secret.sh save MEET_INITIAL_ADMIN_PASSWORD "${var.initialMeetAdminPassword}"
  else
    /usr/local/bin/store_secret.sh generate MEET_INITIAL_ADMIN_PASSWORD
  fi

  if [[ "${var.initialMeetApiKey}" != '' ]]; then
    /usr/local/bin/store_secret.sh save MEET_INITIAL_API_KEY "${var.initialMeetApiKey}"
  fi

  /usr/local/bin/store_secret.sh generate REDIS_PASSWORD
  /usr/local/bin/store_secret.sh save MONGO_ADMIN_USERNAME "mongoadmin"
  /usr/local/bin/store_secret.sh generate MONGO_ADMIN_PASSWORD
  /usr/local/bin/store_secret.sh generate MONGO_REPLICA_SET_KEY
  /usr/local/bin/store_secret.sh save MINIO_ACCESS_KEY "minioadmin"
  /usr/local/bin/store_secret.sh generate MINIO_SECRET_KEY
  /usr/local/bin/store_secret.sh save DASHBOARD_ADMIN_USERNAME "dashboardadmin"
  /usr/local/bin/store_secret.sh generate DASHBOARD_ADMIN_PASSWORD
  /usr/local/bin/store_secret.sh save GRAFANA_ADMIN_USERNAME "grafanaadmin"
  /usr/local/bin/store_secret.sh generate GRAFANA_ADMIN_PASSWORD
  /usr/local/bin/store_secret.sh save ENABLED_MODULES "observability,openviduMeet,v2compatibility"
  /usr/local/bin/store_secret.sh generate LIVEKIT_API_KEY "API" 12
  /usr/local/bin/store_secret.sh generate LIVEKIT_API_SECRET
  /usr/local/bin/store_secret.sh save OPENVIDU_PRO_LICENSE "${var.openviduLicense}"
  /usr/local/bin/store_secret.sh save OPENVIDU_RTC_ENGINE "${var.rtcEngine}"
  /usr/local/bin/store_secret.sh save OPENVIDU_VERSION "$OPENVIDU_VERSION"
  /usr/local/bin/store_secret.sh save ALL_SECRETS_GENERATED "true"
fi

# Wait for all 4 master nodes to register their private IPs
while true; do
  MASTER_NODE_1_PRIVATE_IP=$(/usr/local/bin/store_secret.sh get MASTER_NODE_1_PRIVATE_IP 2>/dev/null || echo "")
  MASTER_NODE_2_PRIVATE_IP=$(/usr/local/bin/store_secret.sh get MASTER_NODE_2_PRIVATE_IP 2>/dev/null || echo "")
  MASTER_NODE_3_PRIVATE_IP=$(/usr/local/bin/store_secret.sh get MASTER_NODE_3_PRIVATE_IP 2>/dev/null || echo "")
  MASTER_NODE_4_PRIVATE_IP=$(/usr/local/bin/store_secret.sh get MASTER_NODE_4_PRIVATE_IP 2>/dev/null || echo "")

  if [[ -n "$MASTER_NODE_1_PRIVATE_IP" ]] && \
     [[ -n "$MASTER_NODE_2_PRIVATE_IP" ]] && \
     [[ -n "$MASTER_NODE_3_PRIVATE_IP" ]] && \
     [[ -n "$MASTER_NODE_4_PRIVATE_IP" ]]; then
    break
  fi
  echo "Waiting for all master nodes to register their IPs..."
  sleep 5
done

MASTER_NODE_PRIVATE_IP_LIST="$MASTER_NODE_1_PRIVATE_IP,$MASTER_NODE_2_PRIVATE_IP,$MASTER_NODE_3_PRIVATE_IP,$MASTER_NODE_4_PRIVATE_IP"

# Fetch all shared secrets
DOMAIN=$(/usr/local/bin/store_secret.sh get DOMAIN_NAME)
OPENVIDU_PRO_LICENSE=$(/usr/local/bin/store_secret.sh get OPENVIDU_PRO_LICENSE)
OPENVIDU_RTC_ENGINE=$(/usr/local/bin/store_secret.sh get OPENVIDU_RTC_ENGINE)
REDIS_PASSWORD=$(/usr/local/bin/store_secret.sh get REDIS_PASSWORD)
MONGO_ADMIN_USERNAME=$(/usr/local/bin/store_secret.sh get MONGO_ADMIN_USERNAME)
MONGO_ADMIN_PASSWORD=$(/usr/local/bin/store_secret.sh get MONGO_ADMIN_PASSWORD)
MONGO_REPLICA_SET_KEY=$(/usr/local/bin/store_secret.sh get MONGO_REPLICA_SET_KEY)
MINIO_ACCESS_KEY=$(/usr/local/bin/store_secret.sh get MINIO_ACCESS_KEY)
MINIO_SECRET_KEY=$(/usr/local/bin/store_secret.sh get MINIO_SECRET_KEY)
DASHBOARD_ADMIN_USERNAME=$(/usr/local/bin/store_secret.sh get DASHBOARD_ADMIN_USERNAME)
DASHBOARD_ADMIN_PASSWORD=$(/usr/local/bin/store_secret.sh get DASHBOARD_ADMIN_PASSWORD)
GRAFANA_ADMIN_USERNAME=$(/usr/local/bin/store_secret.sh get GRAFANA_ADMIN_USERNAME)
GRAFANA_ADMIN_PASSWORD=$(/usr/local/bin/store_secret.sh get GRAFANA_ADMIN_PASSWORD)
LIVEKIT_API_KEY=$(/usr/local/bin/store_secret.sh get LIVEKIT_API_KEY)
LIVEKIT_API_SECRET=$(/usr/local/bin/store_secret.sh get LIVEKIT_API_SECRET)
MEET_INITIAL_ADMIN_USER=$(/usr/local/bin/store_secret.sh get MEET_INITIAL_ADMIN_USER)
MEET_INITIAL_ADMIN_PASSWORD=$(/usr/local/bin/store_secret.sh get MEET_INITIAL_ADMIN_PASSWORD)
if [[ "${var.initialMeetApiKey}" != '' ]]; then
  MEET_INITIAL_API_KEY=$(/usr/local/bin/store_secret.sh get MEET_INITIAL_API_KEY)
fi
ENABLED_MODULES=$(/usr/local/bin/store_secret.sh get ENABLED_MODULES)
OPENVIDU_VERSION=$(/usr/local/bin/store_secret.sh get OPENVIDU_VERSION)

# Build install command
INSTALL_COMMAND="sh <(curl -fsSL http://get.openvidu.io/pro/ha/$OPENVIDU_VERSION/install_ov_master_node.sh)"

COMMON_ARGS=(
  "--no-tty"
  "--install"
  "--environment=oracle"
  "--deployment-type=ha"
  "--node-role=master-node"
  "--external-load-balancer"
  "--internal-tls-termination"
  "--master-node-private-ip-list='$MASTER_NODE_PRIVATE_IP_LIST'"
  "--openvidu-pro-license='$OPENVIDU_PRO_LICENSE'"
  "--domain-name='$DOMAIN'"
  "--enabled-modules='$ENABLED_MODULES'"
  "--rtc-engine=$OPENVIDU_RTC_ENGINE"
  "--redis-password=$REDIS_PASSWORD"
  "--mongo-admin-user=$MONGO_ADMIN_USERNAME"
  "--mongo-admin-password=$MONGO_ADMIN_PASSWORD"
  "--mongo-replica-set-key=$MONGO_REPLICA_SET_KEY"
  "--minio-access-key=$MINIO_ACCESS_KEY"
  "--minio-secret-key=$MINIO_SECRET_KEY"
  "--dashboard-admin-user=$DASHBOARD_ADMIN_USERNAME"
  "--dashboard-admin-password=$DASHBOARD_ADMIN_PASSWORD"
  "--grafana-admin-user=$GRAFANA_ADMIN_USERNAME"
  "--grafana-admin-password=$GRAFANA_ADMIN_PASSWORD"
  "--meet-initial-admin-password=$MEET_INITIAL_ADMIN_PASSWORD"
  "--meet-initial-api-key=$MEET_INITIAL_API_KEY"
  "--livekit-api-key=$LIVEKIT_API_KEY"
  "--livekit-api-secret=$LIVEKIT_API_SECRET"
)

# Additional user flags
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
MINIO_URL="https://$${DOMAIN}/minio-console/"

/usr/local/bin/store_secret.sh save OPENVIDU_URL "$OPENVIDU_URL"
/usr/local/bin/store_secret.sh save LIVEKIT_URL "$LIVEKIT_URL"
/usr/local/bin/store_secret.sh save DASHBOARD_URL "$DASHBOARD_URL"
/usr/local/bin/store_secret.sh save GRAFANA_URL "$GRAFANA_URL"
/usr/local/bin/store_secret.sh save MINIO_URL "$MINIO_URL"
EOF

  update_config_from_secret_script = <<-EOF
#!/bin/bash -x
set -e

export HOME="/root"
export PATH="$PATH:$HOME/.local/bin"

INSTALL_DIR="/opt/openvidu"
CLUSTER_CONFIG_DIR="$${INSTALL_DIR}/config/cluster"
MASTER_NODE_CONFIG_DIR="$${INSTALL_DIR}/config/node"

get_secret() {
  local secret_name="$1"
  local secret_id
  secret_id=$(oci vault secret list \
    --compartment-id ${var.compartment_ocid} \
    --all \
    --query "data[?\"secret-name\"=='$secret_name' && \"lifecycle-state\"=='ACTIVE'].id | [0]" \
    --raw-output \
    --auth instance_principal)
  oci secrets secret-bundle get \
    --secret-id "$secret_id" \
    --query 'data."secret-bundle-content".content' \
    --raw-output \
    --auth instance_principal | base64 -d
}

update_secret() {
  local secret_name="$1"
  local secret_value="$2"
  local secret_id
  secret_id=$(oci vault secret list \
    --compartment-id ${var.compartment_ocid} \
    --all \
    --query "data[?\"secret-name\"=='$secret_name' && \"lifecycle-state\"=='ACTIVE'].id | [0]" \
    --raw-output \
    --auth instance_principal)
  if [[ -z "$secret_id" || "$secret_id" == "null" ]]; then
    echo "Secret $secret_name not found in vault" >&2; return 1
  fi
  oci vault secret update-base64 \
    --secret-id "$secret_id" \
    --secret-content-content "$(echo -n "$secret_value" | base64)" \
    --enable-auto-generation false \
    --auth instance_principal
}

export DOMAIN=$(get_secret DOMAIN_NAME)
[[ -n "$DOMAIN" ]] || exit 1
sed -i "s/DOMAIN_NAME=.*/DOMAIN_NAME=$DOMAIN/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"

export REDIS_PASSWORD=$(get_secret REDIS_PASSWORD)
export OPENVIDU_RTC_ENGINE=$(get_secret OPENVIDU_RTC_ENGINE)
export OPENVIDU_PRO_LICENSE=$(get_secret OPENVIDU_PRO_LICENSE)
export MONGO_ADMIN_USERNAME=$(get_secret MONGO_ADMIN_USERNAME)
export MONGO_ADMIN_PASSWORD=$(get_secret MONGO_ADMIN_PASSWORD)
export MONGO_REPLICA_SET_KEY=$(get_secret MONGO_REPLICA_SET_KEY)
export DASHBOARD_ADMIN_USERNAME=$(get_secret DASHBOARD_ADMIN_USERNAME)
export DASHBOARD_ADMIN_PASSWORD=$(get_secret DASHBOARD_ADMIN_PASSWORD)
export MINIO_ACCESS_KEY=$(get_secret MINIO_ACCESS_KEY)
export MINIO_SECRET_KEY=$(get_secret MINIO_SECRET_KEY)
export GRAFANA_ADMIN_USERNAME=$(get_secret GRAFANA_ADMIN_USERNAME)
export GRAFANA_ADMIN_PASSWORD=$(get_secret GRAFANA_ADMIN_PASSWORD)
export LIVEKIT_API_KEY=$(get_secret LIVEKIT_API_KEY)
export LIVEKIT_API_SECRET=$(get_secret LIVEKIT_API_SECRET)
export MEET_INITIAL_ADMIN_USER=$(get_secret MEET_INITIAL_ADMIN_USER)
export MEET_INITIAL_ADMIN_PASSWORD=$(get_secret MEET_INITIAL_ADMIN_PASSWORD)
if [[ "${var.initialMeetApiKey}" != '' ]]; then
  export MEET_INITIAL_API_KEY=$(get_secret MEET_INITIAL_API_KEY)
fi
export ENABLED_MODULES=$(get_secret ENABLED_MODULES)

sed -i "s/REDIS_PASSWORD=.*/REDIS_PASSWORD=$REDIS_PASSWORD/" "$${MASTER_NODE_CONFIG_DIR}/master_node.env"
sed -i "s/OPENVIDU_RTC_ENGINE=.*/OPENVIDU_RTC_ENGINE=$OPENVIDU_RTC_ENGINE/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s/OPENVIDU_PRO_LICENSE=.*/OPENVIDU_PRO_LICENSE=$OPENVIDU_PRO_LICENSE/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s/MONGO_ADMIN_USERNAME=.*/MONGO_ADMIN_USERNAME=$MONGO_ADMIN_USERNAME/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s/MONGO_ADMIN_PASSWORD=.*/MONGO_ADMIN_PASSWORD=$MONGO_ADMIN_PASSWORD/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s/MONGO_REPLICA_SET_KEY=.*/MONGO_REPLICA_SET_KEY=$MONGO_REPLICA_SET_KEY/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s/DASHBOARD_ADMIN_USERNAME=.*/DASHBOARD_ADMIN_USERNAME=$DASHBOARD_ADMIN_USERNAME/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s/DASHBOARD_ADMIN_PASSWORD=.*/DASHBOARD_ADMIN_PASSWORD=$DASHBOARD_ADMIN_PASSWORD/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s/MINIO_ACCESS_KEY=.*/MINIO_ACCESS_KEY=$MINIO_ACCESS_KEY/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
sed -i "s/MINIO_SECRET_KEY=.*/MINIO_SECRET_KEY=$MINIO_SECRET_KEY/" "$${CLUSTER_CONFIG_DIR}/openvidu.env"
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
MINIO_URL="https://$${DOMAIN}/minio-console/"
update_secret DOMAIN_NAME "$DOMAIN"
update_secret OPENVIDU_URL "$OPENVIDU_URL"
update_secret LIVEKIT_URL "$LIVEKIT_URL"
update_secret DASHBOARD_URL "$DASHBOARD_URL"
update_secret GRAFANA_URL "$GRAFANA_URL"
update_secret MINIO_URL "$MINIO_URL"
EOF

  update_secret_from_config_script = <<-EOF
#!/bin/bash
set -e

export HOME="/root"
export PATH="$PATH:$HOME/.local/bin"

INSTALL_DIR="/opt/openvidu"
CLUSTER_CONFIG_DIR="$${INSTALL_DIR}/config/cluster"
MASTER_NODE_CONFIG_DIR="$${INSTALL_DIR}/config/node"

update_secret() {
  local secret_name="$1"
  local secret_value="$2"
  local secret_id
  secret_id=$(oci vault secret list \
    --compartment-id ${var.compartment_ocid} \
    --all \
    --query "data[?\"secret-name\"=='$secret_name' && \"lifecycle-state\"=='ACTIVE'].id | [0]" \
    --raw-output \
    --auth instance_principal)
  if [[ -z "$secret_id" || "$secret_id" == "null" ]]; then
    echo "Secret $secret_name not found in vault" >&2; return 1
  fi
  oci vault secret update-base64 \
    --secret-id "$secret_id" \
    --secret-content-content "$(echo -n "$secret_value" | base64)" \
    --enable-auto-generation false \
    --auth instance_principal
}

REDIS_PASSWORD="$(/usr/local/bin/get_value_from_config.sh REDIS_PASSWORD "$${MASTER_NODE_CONFIG_DIR}/master_node.env")"
DOMAIN_NAME="$(/usr/local/bin/get_value_from_config.sh DOMAIN_NAME "$${CLUSTER_CONFIG_DIR}/openvidu.env")"
OPENVIDU_RTC_ENGINE="$(/usr/local/bin/get_value_from_config.sh OPENVIDU_RTC_ENGINE "$${CLUSTER_CONFIG_DIR}/openvidu.env")"
OPENVIDU_PRO_LICENSE="$(/usr/local/bin/get_value_from_config.sh OPENVIDU_PRO_LICENSE "$${CLUSTER_CONFIG_DIR}/openvidu.env")"
MONGO_ADMIN_USERNAME="$(/usr/local/bin/get_value_from_config.sh MONGO_ADMIN_USERNAME "$${CLUSTER_CONFIG_DIR}/openvidu.env")"
MONGO_ADMIN_PASSWORD="$(/usr/local/bin/get_value_from_config.sh MONGO_ADMIN_PASSWORD "$${CLUSTER_CONFIG_DIR}/openvidu.env")"
MONGO_REPLICA_SET_KEY="$(/usr/local/bin/get_value_from_config.sh MONGO_REPLICA_SET_KEY "$${CLUSTER_CONFIG_DIR}/openvidu.env")"
MINIO_ACCESS_KEY="$(/usr/local/bin/get_value_from_config.sh MINIO_ACCESS_KEY "$${CLUSTER_CONFIG_DIR}/openvidu.env")"
MINIO_SECRET_KEY="$(/usr/local/bin/get_value_from_config.sh MINIO_SECRET_KEY "$${CLUSTER_CONFIG_DIR}/openvidu.env")"
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

update_secret REDIS_PASSWORD "$REDIS_PASSWORD"
update_secret DOMAIN_NAME "$DOMAIN_NAME"
update_secret OPENVIDU_RTC_ENGINE "$OPENVIDU_RTC_ENGINE"
update_secret OPENVIDU_PRO_LICENSE "$OPENVIDU_PRO_LICENSE"
update_secret MONGO_ADMIN_USERNAME "$MONGO_ADMIN_USERNAME"
update_secret MONGO_ADMIN_PASSWORD "$MONGO_ADMIN_PASSWORD"
update_secret MONGO_REPLICA_SET_KEY "$MONGO_REPLICA_SET_KEY"
update_secret MINIO_ACCESS_KEY "$MINIO_ACCESS_KEY"
update_secret MINIO_SECRET_KEY "$MINIO_SECRET_KEY"
update_secret DASHBOARD_ADMIN_USERNAME "$DASHBOARD_ADMIN_USERNAME"
update_secret DASHBOARD_ADMIN_PASSWORD "$DASHBOARD_ADMIN_PASSWORD"
update_secret GRAFANA_ADMIN_USERNAME "$GRAFANA_ADMIN_USERNAME"
update_secret GRAFANA_ADMIN_PASSWORD "$GRAFANA_ADMIN_PASSWORD"
update_secret LIVEKIT_API_KEY "$LIVEKIT_API_KEY"
update_secret LIVEKIT_API_SECRET "$LIVEKIT_API_SECRET"
update_secret MEET_INITIAL_ADMIN_USER "$MEET_INITIAL_ADMIN_USER"
update_secret MEET_INITIAL_ADMIN_PASSWORD "$MEET_INITIAL_ADMIN_PASSWORD"
if [[ "${var.initialMeetApiKey}" != '' ]]; then
  update_secret MEET_INITIAL_API_KEY "$MEET_INITIAL_API_KEY"
fi
update_secret ENABLED_MODULES "$ENABLED_MODULES"
EOF

  get_value_from_config_script = <<-EOF
#!/bin/bash -x
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

VAULT_ID="${var.vault_ocid != "" ? var.vault_ocid : oci_kms_vault.openvidu_vault[0].id}"
KEY_ID="${var.key_ocid != "" ? var.key_ocid : oci_kms_key.openvidu_key[0].id}"
COMPARTMENT_ID="${var.compartment_ocid}"

store_in_vault() {
  local secret_name="$1"
  local secret_value="$2"
  local encoded_value
  encoded_value=$(echo -n "$secret_value" | base64)

  local secret_id
  secret_id=$(oci vault secret list \
    --compartment-id "$COMPARTMENT_ID" \
    --all \
    --query "data[?\"secret-name\"=='$secret_name' && \"lifecycle-state\"=='ACTIVE'].id | [0]" \
    --raw-output \
    --auth instance_principal)

  if [[ -z "$secret_id" || "$secret_id" == "null" ]]; then
    local pending_id
    pending_id=$(oci vault secret list \
      --compartment-id "$COMPARTMENT_ID" \
      --all \
      --query "data[?\"secret-name\"=='$secret_name' && (\"lifecycle-state\"=='PENDING_DELETION' || \"lifecycle-state\"=='SCHEDULED_FOR_DELETION')].id | [0]" \
      --raw-output \
      --auth instance_principal)

    if [[ -n "$pending_id" && "$pending_id" != "null" ]]; then
      oci vault secret cancel-secret-deletion --secret-id "$pending_id" --auth instance_principal > /dev/null
      oci vault secret update-base64 \
        --secret-id "$pending_id" \
        --secret-content-content "$encoded_value" \
        --enable-auto-generation false \
        --auth instance_principal > /dev/null
    else
      oci vault secret create-base64 \
        --compartment-id "$COMPARTMENT_ID" \
        --secret-name "$secret_name" \
        --vault-id "$VAULT_ID" \
        --key-id "$KEY_ID" \
        --secret-content-content "$encoded_value" \
        --secret-content-name "$secret_name" \
        --auth instance_principal > /dev/null
    fi
  else
    oci vault secret update-base64 \
      --secret-id "$secret_id" \
      --secret-content-content "$encoded_value" \
      --enable-auto-generation false \
      --auth instance_principal > /dev/null
  fi
}

get_from_vault() {
  local secret_name="$1"
  local secret_id
  secret_id=$(oci vault secret list \
    --compartment-id "$COMPARTMENT_ID" \
    --all \
    --query "data[?\"secret-name\"=='$secret_name' && \"lifecycle-state\"=='ACTIVE'].id | [0]" \
    --raw-output \
    --auth instance_principal)
  oci secrets secret-bundle get \
    --secret-id "$secret_id" \
    --query 'data."secret-bundle-content".content' \
    --raw-output \
    --auth instance_principal | base64 -d
}

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
  exit 1
fi
EOF

  check_app_ready_script = <<-EOF
#!/bin/bash
while true; do
  HTTP_STATUS=$(curl -Ik http://localhost:7880/health/caddy | head -n1 | awk '{print $2}')
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

systemctl stop openvidu
/usr/local/bin/update_config_from_secret.sh
systemctl start openvidu
EOF

  # User Data Script for Master Nodes
  user_data_master = <<-EOF
#!/bin/bash -x
set -eu -o pipefail

# restart.sh
cat > /usr/local/bin/restart.sh << 'RESTART_EOF'
${local.restart_script}
RESTART_EOF
chmod +x /usr/local/bin/restart.sh

if [ -f /usr/local/bin/openvidu_install_counter.txt ]; then
  /usr/local/bin/restart.sh || { echo "[OpenVidu] error restarting OpenVidu"; exit 1; }
else
  cat > /usr/local/bin/install.sh << 'INSTALL_EOF'
${local.install_script_master}
INSTALL_EOF
  chmod +x /usr/local/bin/install.sh

  cat > /usr/local/bin/after_install.sh << 'AFTER_INSTALL_EOF'
${local.after_install_script}
AFTER_INSTALL_EOF
  chmod +x /usr/local/bin/after_install.sh

  cat > /usr/local/bin/update_config_from_secret.sh << 'UPDATE_CONFIG_EOF'
${local.update_config_from_secret_script}
UPDATE_CONFIG_EOF
  chmod +x /usr/local/bin/update_config_from_secret.sh

  cat > /usr/local/bin/update_secret_from_config.sh << 'UPDATE_SECRET_EOF'
${local.update_secret_from_config_script}
UPDATE_SECRET_EOF
  chmod +x /usr/local/bin/update_secret_from_config.sh

  cat > /usr/local/bin/get_value_from_config.sh << 'GET_VALUE_EOF'
${local.get_value_from_config_script}
GET_VALUE_EOF
  chmod +x /usr/local/bin/get_value_from_config.sh

  cat > /usr/local/bin/store_secret.sh << 'STORE_SECRET_EOF'
${local.store_secret_script}
STORE_SECRET_EOF
  chmod +x /usr/local/bin/store_secret.sh

  cat > /usr/local/bin/check_app_ready.sh << 'CHECK_APP_EOF'
${local.check_app_ready_script}
CHECK_APP_EOF
  chmod +x /usr/local/bin/check_app_ready.sh

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

  export HOME="/root"
  OCI_CLI_VERSION="3.52.0"
  pipx install oci-cli==$${OCI_CLI_VERSION}
  export PATH="$PATH:$HOME/.local/bin"

  /usr/local/bin/install.sh || { echo "[OpenVidu] error installing OpenVidu"; exit 1; }
  /usr/local/bin/config_s3.sh || { echo "[OpenVidu] error configuring S3 buckets"; exit 1; }
  systemctl start openvidu || { echo "[OpenVidu] error starting OpenVidu"; exit 1; }
  /usr/local/bin/after_install.sh || { echo "[OpenVidu] error updating shared secrets"; exit 1; }

  echo "@reboot /usr/local/bin/restart.sh >> /var/log/openvidu-restart.log 2>&1" | crontab

  echo "installation_complete" > /usr/local/bin/openvidu_install_counter.txt
fi

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

export HOME="/root"
export PATH="$PATH:$HOME/.local/bin"

get_meta() { curl -sf -H "Authorization: Bearer Oracle" "http://169.254.169.254/opc/v2/instance/$1"; }

MASTER_NODE_PRIVATE_IP_LIST=$(get_meta "" | jq -r '.metadata.masterNodePrivateIPList // empty')
PRIVATE_IP=$(get_meta "vnics/" | jq -r '.[0].privateIp' 2>/dev/null || hostname -I | awk '{print $1}')

get_secret() {
  local secret_name="$1"
  local secret_id
  secret_id=$(oci vault secret list \
    --compartment-id "${var.compartment_ocid}" \
    --all \
    --query "data[?\"secret-name\"=='$secret_name' && \"lifecycle-state\"=='ACTIVE'].id | [0]" \
    --raw-output \
    --auth instance_principal)
  oci secrets secret-bundle get \
    --secret-id "$secret_id" \
    --query 'data."secret-bundle-content".content' \
    --raw-output \
    --auth instance_principal | base64 -d
}

# Wait for master nodes to finish initializing secrets
until get_secret ALL_SECRETS_GENERATED 2>/dev/null | grep -q "true"; do
  echo "Waiting for master nodes to initialize secrets..."
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

export HOME="/root"
OCI_CLI_VERSION="3.52.0"
pipx install oci-cli==$${OCI_CLI_VERSION}
export PATH="$PATH:$HOME/.local/bin"

mkdir -p /etc/openvidu
cat > /etc/openvidu/predrain.conf << 'CONF_EOF'
COMPARTMENT_ID=${var.compartment_ocid}
POOL_DISPLAY_NAME=${var.stackName}-media-pool
MIN_NODES=${var.minNumberOfMediaNodes}
SCALE_IN_CPU_THRESHOLD=${var.scaleTargetCPU}
CONF_EOF

cat > /usr/local/bin/install.sh << 'INSTALL_EOF'
${local.install_script_media}
INSTALL_EOF
chmod +x /usr/local/bin/install.sh

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

cat > /usr/local/bin/openvidu-graceful-shutdown.sh << 'SHUTDOWN_SCRIPT_EOF'
${local.graceful_shutdown_script}
SHUTDOWN_SCRIPT_EOF
chmod +x /usr/local/bin/openvidu-graceful-shutdown.sh

cat > /etc/systemd/system/openvidu-graceful-shutdown.service << 'SERVICE_EOF'
[Unit]
Description=OpenVidu Graceful Shutdown (fallback)
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/openvidu-graceful-shutdown.sh
TimeoutStartSec=infinity
TimeoutStopSec=infinity
RemainAfterExit=yes
KillMode=none

[Install]
WantedBy=halt.target reboot.target shutdown.target
SERVICE_EOF

sed -i 's/^#*DefaultTimeoutStopSec=.*/DefaultTimeoutStopSec=infinity/' /etc/systemd/system.conf

systemctl daemon-reload
systemctl enable openvidu-pre-drain.service
systemctl enable openvidu-graceful-shutdown.service

/usr/local/bin/install.sh || { echo "[OpenVidu] error installing media node"; exit 1; }
systemctl start openvidu || { echo "[OpenVidu] error starting OpenVidu"; exit 1; }
echo "installation_complete" > /usr/local/bin/openvidu_install_counter.txt
systemctl start openvidu-pre-drain.service
EOF
}
