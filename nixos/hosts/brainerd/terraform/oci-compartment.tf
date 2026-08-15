# The brainerd compartment was created once via OCI CLI and is never managed
# by Terraform - it must not be destroyed when the VPS is reprovisioned.
#
# To recreate: oci iam compartment create --compartment-id <tenancy_ocid> \
#              --name brainerd --description "OCI VPS relay"
locals {
  compartment_id = "ocid1.compartment.oc1..deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef01"
}
