output "openvidu_nlb_public_ip" {
  value       = local.nlb_ip_address
  description = "Public IP of the Network Load Balancer — the HA entry point for the cluster."
}

output "openvidu_domain_name" {
  value       = local.domain_name
  description = "Domain name resolved for the OpenVidu HA deployment (sslip.io if no custom domain was provided)."
}

output "openvidu_master_node_1_public_ip" {
  value       = oci_core_instance.openvidu_master_node_1.public_ip
  description = "Public IP of Master Node 1 (for SSH only — user traffic should go to the NLB)."
}

output "openvidu_master_node_2_public_ip" {
  value       = oci_core_instance.openvidu_master_node_2.public_ip
  description = "Public IP of Master Node 2 (for SSH only — user traffic should go to the NLB)."
}

output "openvidu_master_node_3_public_ip" {
  value       = oci_core_instance.openvidu_master_node_3.public_ip
  description = "Public IP of Master Node 3 (for SSH only — user traffic should go to the NLB)."
}

output "openvidu_master_node_4_public_ip" {
  value       = oci_core_instance.openvidu_master_node_4.public_ip
  description = "Public IP of Master Node 4 (for SSH only — user traffic should go to the NLB)."
}

output "openvidu_master_node_private_ips" {
  value = [
    oci_core_instance.openvidu_master_node_1.private_ip,
    oci_core_instance.openvidu_master_node_2.private_ip,
    oci_core_instance.openvidu_master_node_3.private_ip,
    oci_core_instance.openvidu_master_node_4.private_ip,
  ]
  description = "Private IPs of the 4 master nodes (used internally by the cluster)."
}

output "openvidu_media_node_pool_id" {
  value       = oci_core_instance_pool.media_node_pool.id
  description = "OCID of the media-node Instance Pool."
}

output "openvidu_bucket_app_data_name" {
  value       = local.bucket_app_data_name
  description = "Name of the Object Storage bucket used for application data and recordings."
}

output "openvidu_bucket_cluster_data_name" {
  value       = local.bucket_cluster_data_name
  description = "Name of the Object Storage bucket used for cluster-wide shared state."
}

output "openvidu_ssh_private_key_bucket_path" {
  value       = "${local.bucket_cluster_data_name}/${var.stackName}-private-key.pem"
  description = "Bucket path to the generated SSH private key. Download with: oci os object get --bucket-name <bucket> --name <stackName>-private-key.pem --file <stackName>-private-key.pem"
}

output "openvidu_vcn_id" {
  value       = oci_core_vcn.openvidu_vcn.id
  description = "OCID of the VCN."
}

output "openvidu_scale_in_function_id" {
  value       = oci_functions_function.scale_in_fn.id
  description = "OCID of the scale-in OCI Function (invoked every 5 min by whichever master holds the SCALEIN_LOCK)."
}
