output "openvidu_nlb_public_ip" {
  value       = local.nlb_ip_address
  description = "The public IP address of the Network Load Balancer (entry point for the HA deployment)"
}

output "openvidu_domain_name" {
  value       = local.domain_name
  description = "The domain name of the OpenVidu deployment"
}

output "openvidu_master_node_1_public_ip" {
  value       = oci_core_instance.openvidu_master_node_1.public_ip
  description = "Public IP of Master Node 1"
}

output "openvidu_master_node_2_public_ip" {
  value       = oci_core_instance.openvidu_master_node_2.public_ip
  description = "Public IP of Master Node 2"
}

output "openvidu_master_node_3_public_ip" {
  value       = oci_core_instance.openvidu_master_node_3.public_ip
  description = "Public IP of Master Node 3"
}

output "openvidu_master_node_4_public_ip" {
  value       = oci_core_instance.openvidu_master_node_4.public_ip
  description = "Public IP of Master Node 4"
}

output "openvidu_bucket_app_data_name" {
  value       = local.bucket_app_data_name
  description = "The name of the Object Storage bucket used for application data and recordings"
}

output "openvidu_bucket_cluster_data_name" {
  value       = local.bucket_cluster_data_name
  description = "The name of the Object Storage bucket used for cluster data"
}

output "openvidu_media_node_pool_id" {
  value       = oci_core_instance_pool.media_node_pool.id
  description = "The ID of the Instance Pool for Media Nodes"
}

output "openvidu_vcn_id" {
  value       = oci_core_vcn.openvidu_vcn.id
  description = "The ID of the VCN"
}

output "openvidu_ssh_private_key_bucket_path" {
  value       = "${local.bucket_cluster_data_name}/${var.stackName}-private-key.pem"
  description = "Bucket path to the generated SSH private key. Download with: oci os object get --bucket-name <bucket> --name <stackName>-private-key.pem --file <stackName>-private-key.pem"
}
