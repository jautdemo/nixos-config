resource "oci_core_instance" "vps" {
  compartment_id      = local.compartment_id
  availability_domain = var.availability_domain
  display_name        = "vps"
  shape               = var.instance_shape

  # Only populated for Flex shapes - ignored for fixed shapes
  dynamic "shape_config" {
    for_each = var.instance_ocpus != null ? [1] : []
    content {
      ocpus         = var.instance_ocpus
      memory_in_gbs = var.instance_memory_gb
    }
  }

  source_details {
    source_type             = "image"
    source_id               = var.image_ocid
    boot_volume_size_in_gbs = var.boot_volume_size_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = false # managed by oci_core_public_ip.vps (reserved)
    hostname_label   = "vps"
  }

  launch_options {
    firmware         = "UEFI_64"
    network_type     = "PARAVIRTUALIZED"
    boot_volume_type = "PARAVIRTUALIZED"
  }

  metadata = {
    # OCI only accepts RSA / standard Ed25519 here - not FIDO2 sk keys.
    # This is bootstrap-only; YubiKey authorized_keys are set in the NixOS config.
    ssh_authorized_keys = join("\n", [for p in var.ssh_public_key_paths : file(pathexpand(p))])
  }

}


data "oci_core_vnic_attachments" "vps" {
  compartment_id = local.compartment_id
  instance_id    = oci_core_instance.vps.id
}

data "oci_core_vnic" "vps_primary" {
  vnic_id = data.oci_core_vnic_attachments.vps.vnic_attachments[0].vnic_id
}

data "oci_core_private_ips" "vps_primary" {
  ip_address = data.oci_core_vnic.vps_primary.private_ip_address
  subnet_id  = oci_core_subnet.public.id
}

# Reserved so the address survives instance replacement.
resource "oci_core_public_ip" "vps" {
  compartment_id = local.compartment_id
  lifetime       = "RESERVED"
  display_name   = "vps-reserved-ip"
  private_ip_id  = data.oci_core_private_ips.vps_primary.private_ips[0].id
}

output "vps_public_ip" {
  description = "Reserved public IP of the VPS"
  value       = oci_core_public_ip.vps.ip_address
}

output "vps_ocid" {
  description = "OCID of the VPS instance"
  value       = oci_core_instance.vps.id
}

resource "terraform_data" "image_trigger" {
  input = var.image_ocid
}

# Tell OCI the firmware/virtualization capabilities of our NixOS image.
# Without this, OCI uses wrong defaults and the instance boots unresponsive.
resource "oci_core_compute_image_capability_schema" "vps" {
  compartment_id                                      = local.compartment_id
  image_id                                            = var.image_ocid
  compute_global_image_capability_schema_version_name = "807910c5-d2a8-4c82-8dec-7ebe22b841c3"

  schema_data = {
    "Compute.Firmware" = jsonencode({
      descriptorType = "enumstring"
      source         = "IMAGE"
      defaultValue   = "UEFI_64"
      values         = ["UEFI_64"]
    })
    "Compute.LaunchMode" = jsonencode({
      descriptorType = "enumstring"
      source         = "IMAGE"
      defaultValue   = "PARAVIRTUALIZED"
      values         = ["PARAVIRTUALIZED", "EMULATED", "CUSTOM", "NATIVE"]
    })
    "Storage.BootVolumeType" = jsonencode({
      descriptorType = "enumstring"
      source         = "IMAGE"
      defaultValue   = "PARAVIRTUALIZED"
      values         = ["PARAVIRTUALIZED", "ISCSI", "SCSI", "IDE", "NVME"]
    })
    "Network.AttachmentType" = jsonencode({
      descriptorType = "enumstring"
      source         = "IMAGE"
      defaultValue   = "PARAVIRTUALIZED"
      values         = ["PARAVIRTUALIZED", "E1000", "VFIO", "VDPA"]
    })
  }

  depends_on = [terraform_data.image_trigger]
}

