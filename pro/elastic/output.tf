output "openvidu_master_public_ip" {
  value       = oci_core_instance.openvidu_master_node.public_ip
  description = "The public IP address of the OpenVidu Master Node"
}

output "openvidu_master_private_ip" {
  value       = oci_core_instance.openvidu_master_node.private_ip
  description = "The private IP address of the OpenVidu Master Node"
}

output "openvidu_domain_name" {
  value       = local.domain_name
  description = "The domain name of the OpenVidu deployment"
}

output "openvidu_bucket_name" {
  value       = local.bucket_app_data_name
  description = "The name of the Object Storage bucket used for OpenVidu data"
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
  value       = "${local.bucket_app_data_name}/${var.stackName}-private-key.pem"
  description = "Bucket path to the generated SSH private key. Download with: oci os object get --bucket-name <bucket> --name <stackName>-private-key.pem --file <stackName>-private-key.pem"
}
