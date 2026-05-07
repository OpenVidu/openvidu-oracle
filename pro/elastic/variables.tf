# ------------------------- variables -------------------------

# Variables used by the configuration
variable "tenancy_ocid" {
  description = "OCI Tenancy OCID. Required for Object Storage namespace."
  type        = string
}

variable "compartment_ocid" {
  description = "OCI Compartment OCID where the resources will be created."
  type        = string
}

variable "region" {
  description = "OCI region where resources will be created."
  type        = string
  default     = "eu-frankfurt-1"
}

variable "availability_domain" {
  description = "Availability Domain number (1, 2, or 3) to use for resources."
  type        = number
  default     = 1
  validation {
    condition     = var.availability_domain >= 1 && var.availability_domain <= 3
    error_message = "availability_domain must be 1, 2, or 3."
  }
}

variable "stackName" {
  description = "Stack name for OpenVidu deployment."
  type        = string
}

variable "certificateType" {
  description = "[selfsigned] Not recommended for production use. Just for testing purposes or development environments. You don't need a FQDN to use this option. [owncert] Valid for production environments. Use your own certificate. You need a FQDN to use this option. [letsencrypt] Valid for production environments. Can be used with or without a FQDN (if no FQDN is provided, a random sslip.io domain will be used)."
  type        = string
  default     = "letsencrypt"
  validation {
    condition     = contains(["selfsigned", "owncert", "letsencrypt"], var.certificateType)
    error_message = "certificateType must be one of: selfsigned, owncert, letsencrypt"
  }
}

variable "publicIpAddress" {
  description = "Previously created Reserved Public IP address for the OpenVidu Master Node. Blank will generate a new public IP."
  type        = string
  default     = ""
  validation {
    condition     = can(regex("^$|^([01]?\\d{1,2}|2[0-4]\\d|25[0-5])\\.([01]?\\d{1,2}|2[0-4]\\d|25[0-5])\\.([01]?\\d{1,2}|2[0-4]\\d|25[0-5])\\.([01]?\\d{1,2}|2[0-4]\\d|25[0-5])$", var.publicIpAddress))
    error_message = "The Public IP does not have a valid IPv4 format"
  }
}

variable "domainName" {
  description = "Domain name for the OpenVidu Deployment."
  type        = string
  default     = ""
  validation {
    condition     = can(regex("^$|^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$", var.domainName))
    error_message = "The domain name does not have a valid domain name format"
  }
}

variable "ownPublicCertificate" {
  description = "If certificate type is 'owncert', this parameter will be used to specify the public certificate in base64 format"
  type        = string
  default     = ""
}

variable "ownPrivateCertificate" {
  description = "If certificate type is 'owncert', this parameter will be used to specify the private certificate in base64 format"
  type        = string
  default     = ""
}

variable "initialMeetAdminPassword" {
  description = "Initial password for the 'admin' user in OpenVidu Meet. If not provided, a random password will be generated."
  type        = string
  default     = ""
  sensitive   = true
  validation {
    condition     = can(regex("^[A-Za-z0-9_-]*$", var.initialMeetAdminPassword))
    error_message = "Must contain only alphanumeric characters, underscores or hyphens (A-Z, a-z, 0-9, _, -). Leave empty to generate a random password."
  }
}

variable "initialMeetApiKey" {
  description = "Initial API key for OpenVidu Meet. If not provided, no API key will be set and the user can set it later from Meet Console."
  type        = string
  default     = ""
  sensitive   = true
  validation {
    condition     = can(regex("^[A-Za-z0-9_-]*$", var.initialMeetApiKey))
    error_message = "Must contain only alphanumeric characters, underscores or hyphens (A-Z, a-z, 0-9, _, -). Leave empty to not set an initial API key."
  }
}

variable "masterNodeShape" {
  description = "OCI Shape for the OpenVidu Master Node."
  type        = string
  default     = "VM.Standard.E4.Flex"
}

variable "masterNodeOcpus" {
  description = "Number of OCPUs for the Master Node (if using Flex shape)."
  type        = number
  default     = 2
}

variable "masterNodeMemory" {
  description = "Memory in GB for the Master Node (if using Flex shape)."
  type        = number
  default     = 8
}

variable "masterNodeDiskSize" {
  description = "Boot disk size in GB for the Master Node."
  type        = number
  default     = 100
}

variable "mediaNodeDiskSize" {
  description = "Boot disk size in GB for Media Nodes."
  type        = number
  default     = 100
}

variable "mediaNodeShape" {
  description = "OCI Shape for the OpenVidu Media Nodes."
  type        = string
  default     = "VM.Standard.E4.Flex"
}

variable "mediaNodeOcpus" {
  description = "Number of OCPUs for Media Nodes (if using Flex shape)."
  type        = number
  default     = 3
}

variable "mediaNodeMemory" {
  description = "Memory in GB for Media Nodes (if using Flex shape)."
  type        = number
  default     = 4
}

variable "initialNumberOfMediaNodes" {
  description = "Number of initial media nodes to deploy."
  type        = number
  default     = 1
}

variable "minNumberOfMediaNodes" {
  description = "Minimum number of media nodes for autoscaling."
  type        = number
  default     = 1
}

variable "maxNumberOfMediaNodes" {
  description = "Maximum number of media nodes for autoscaling."
  type        = number
  default     = 5
}

variable "scaleTargetCPU" {
  description = "Target CPU percentage to trigger scale-out."
  type        = number
  default     = 50
}

variable "bucketName" {
  description = "Name of the OCI Object Storage bucket to store data and recordings. If empty, a bucket will be created."
  type        = string
  default     = ""
}

variable "openviduLicense" {
  description = "OpenVidu Pro/Enterprise license key. Visit https://openvidu.io/account"
  type        = string
  sensitive   = true
}

variable "rtcEngine" {
  description = "RTC Engine to use (pion or mediasoup)."
  type        = string
  default     = "pion"
  validation {
    condition     = contains(["pion", "mediasoup"], var.rtcEngine)
    error_message = "rtcEngine must be one of: pion, mediasoup"
  }
}

variable "additionalInstallFlags" {
  description = "Additional optional flags to pass to the OpenVidu installer (comma-separated, e.g.,'--flag1=value, --flag2')."
  type        = string
  default     = ""
  validation {
    condition     = can(regex("^[A-Za-z0-9, =_./:@\\-]*$", var.additionalInstallFlags))
    error_message = "Must be a comma-separated list of flags (for example, --flag=value, --bool-flag)."
  }
}

variable "vault_ocid" {
  description = "OCI KMS Vault OCID for secrets management. If empty, a new vault will be created."
  type        = string
  default     = ""
}

variable "key_ocid" {
  description = "OCI KMS Key OCID for secrets management. If empty, a new key will be created."
  type        = string
  default     = ""
}

variable "user_ocid" {
  description = "OCI User OCID used to create Customer Secret Keys for S3-compatible access to Object Storage."
  type        = string
}


