# nix run .#brainerd-bootstrap
#
# Bootstrap the brainerd OCI VPS: build the image on duluth, upload, terraform
# apply with port 22 briefly open, push credentials, switch, close 22.
# Assumes clean state; `terraform destroy` first when reprovisioning. An IP
# change needs nothing at home - wg-gateway re-resolves the hostname.
# Self-contained: every tool comes from runtimeInputs.
{
  pkgs,
  cluster,
  tf,
  ageIdentity,
  mkApp,
}:
let
  # All k8s nodes as potential x86_64-linux remote builders, nix picks any available
  buildersStr = pkgs.lib.concatMapStringsSep " ; " (
    ip: "ssh://root@${ip} x86_64-linux - 1 - kvm,nixos-test,big-parallel"
  ) (builtins.attrValues cluster.nodes);
in
mkApp {
  name = "brainerd-bootstrap";
  runtimeInputs = [
    pkgs.openssh
    pkgs.nixos-rebuild
    pkgs.nix
    pkgs.git
    pkgs.oci-cli
    pkgs.rsync
    pkgs.gnused
    pkgs.gawk
    pkgs.age
    pkgs.age-plugin-yubikey
    ageIdentity
    tf
  ];
  text = ''

    TF_DIR="$REPO_ROOT/nixos/hosts/brainerd/terraform"


    TENANCY_OCID=$(oci iam availability-domain list \
      --query 'data[0]."compartment-id"' --raw-output)

    tf init -input=false -no-color >/dev/null
    EXISTING=$(tf state list 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$EXISTING" -gt 0 ]]; then
      echo "WARNING: $EXISTING existing resource(s) in Terraform state:"
      tf state list 2>/dev/null
      echo ""
      echo -n "Destroy all and reprovision from scratch? [y/N] "
      read -r answer
      if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        echo "Aborted. To update config only: nix run .#deploy -- brainerd"
        exit 0
      fi
      echo "=== Destroying existing infrastructure ==="
      tf destroy -auto-approve
    fi

    # The OCID lives in variables.tf as the default; auto-tfvars are
    # gitignored wholesale and silently override it, so never write one.
    IMAGE_OCID=""
    CANDIDATE=$(awk '/variable "image_ocid"/,/^}/' "$TF_DIR/variables.tf" \
      | grep -o '"ocid1\.image[^"]*"' | tr -d '"' || true)
    if [[ -n "$CANDIDATE" ]]; then
      STATE=$(oci compute image get --image-id "$CANDIDATE" \
        --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)
      if [[ "$STATE" == "AVAILABLE" ]]; then
        echo "=== Reusing existing NixOS image: $CANDIDATE ==="
        IMAGE_OCID="$CANDIDATE"
      fi
    fi

    if [[ -z "$IMAGE_OCID" ]]; then
    IMAGE_STORE=$(nix build \
      --builders "${buildersStr}" \
      --max-jobs 0 \
      "$REPO_ROOT#packages.x86_64-linux.brainerd-image" \
      --no-link --print-out-paths)

    QCOW2=$(find "$IMAGE_STORE" -maxdepth 1 -name "*.qcow2" | head -1)
    if [[ -z "$QCOW2" ]]; then
      echo "ERROR: no qcow2 file found in $IMAGE_STORE - listing:" >&2
      find "$IMAGE_STORE" -maxdepth 1 >&2; exit 1
    fi
    echo "    Built: $QCOW2  ($(du -h "$QCOW2" | cut -f1))"

    NAMESPACE=$(oci os ns get --query 'data' --raw-output)
    BUCKET="brainerd-nixos-upload-$$"
    OBJECT="brainerd-nixos.qcow2"
    IMAGE_NAME="brainerd-nixos-$(date +%Y%m%d)"

    cleanup_upload() {
      oci os object delete --namespace "$NAMESPACE" --bucket-name "$BUCKET" \
        --name "$OBJECT" --force 2>/dev/null || true
      oci os bucket delete --namespace "$NAMESPACE" --name "$BUCKET" \
        --force 2>/dev/null || true
    }

    oci os bucket create --compartment-id "$TENANCY_OCID" \
      --name "$BUCKET" --region eu-frankfurt-1

    oci os object put --namespace "$NAMESPACE" --bucket-name "$BUCKET" \
      --name "$OBJECT" --file "$QCOW2" --part-size 100 --force

    # OCI display metadata only; this flake tracks nixos-unstable, so there
    # is no release number to state.
    IMAGE_OCID=$(oci compute image create \
      --compartment-id "$TENANCY_OCID" \
      --display-name "$IMAGE_NAME" \
      --launch-mode PARAVIRTUALIZED \
      --image-source-details \
        "{\"sourceType\":\"objectStorageTuple\",\"bucketName\":\"$BUCKET\",\"namespaceName\":\"$NAMESPACE\",\"objectName\":\"$OBJECT\",\"operatingSystem\":\"NixOS\",\"operatingSystemVersion\":\"unstable\",\"sourceImageType\":\"QCOW2\"}" \
      --query 'data.id' --raw-output)

    echo "    OCID: $IMAGE_OCID"
    while true; do
      STATE=$(oci compute image get --image-id "$IMAGE_OCID" \
        --query 'data."lifecycle-state"' --raw-output)
      printf "    state: %-20s\r" "$STATE"
      [[ "$STATE" == "AVAILABLE" ]] && break
      sleep 15
    done
    echo ""

    cleanup_upload

    sed -i -E "s|(default *= *)\"ocid1\.image[^\"]*\"|\1\"$IMAGE_OCID\"|" \
      "$TF_DIR/variables.tf"
    git -C "$REPO_ROOT" add "$TF_DIR/variables.tf"
    echo "    variables.tf updated with the new image OCID - commit it."

    fi # end image build block

    # Ensure the remote state bucket exists (oci backend, no Customer Secret Keys needed)
    oci os bucket create \
      --compartment-id "$TENANCY_OCID" \
      --name brainerd-tfstate \
      --region eu-frankfurt-1 2>/dev/null || true

    tf init -input=false
    # allow_public_ssh=true: the fresh instance has no tunnel credential yet,
    # so bootstrap must reach sshd directly. Closed again in the final step.
    tf apply -auto-approve -var allow_public_ssh=true

    VPS_IP=$(tf output -raw vps_public_ip)
    echo "    VPS IP: $VPS_IP  (brainerd.infra.homelab.invalid)"

    oci compute image delete --image-id "$IMAGE_OCID" --force 2>/dev/null || true

    until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        "root@$VPS_IP" true 2>/dev/null; do
      printf "."
      sleep 5
    done
    echo " up!"

    # The pre-created host key, BEFORE the first rebuild: it keeps
    # brainerd's SSH identity stable across reprovisions, which is what
    # will let it become an agenix recipient. sshd picks it up on restart.
    IDENT=$(mktemp); trap 'rm -f "$IDENT"' EXIT
    age-identity > "$IDENT"
    age -d -i "$IDENT" "$REPO_ROOT/secrets/brainerd-host-key.age" \
      | ssh "root@$VPS_IP" "umask 077; cat > /etc/ssh/ssh_host_ed25519_key && systemctl restart sshd"
    ssh-keygen -R "$VPS_IP" >/dev/null 2>&1 || true

    nixos-rebuild switch \
      --flake "$REPO_ROOT#brainerd" \
      --build-host "root@$VPS_IP" \
      --target-host "root@$VPS_IP"

    rsync -a --delete --exclude .git --exclude result \
      "$REPO_ROOT/" "root@$VPS_IP:/etc/nixos-config/"

    TUNNEL_UNIT="cloudflared-tunnel-deadbeef-dead-beef-dead-beefdeadbe01.service"
    if ssh -o StrictHostKeyChecking=no "root@$VPS_IP" \
        "systemctl is-active $TUNNEL_UNIT" >/dev/null 2>&1; then
      tf apply -auto-approve   # allow_public_ssh back to false
      echo "    Tunnel active - public port 22 closed."
    else
      echo "WARNING: $TUNNEL_UNIT is NOT active - leaving public port 22 OPEN." >&2
      echo "  Fix the tunnel, then: nix run .#tf -- apply  (closes 22)" >&2
    fi

    echo ""
    echo "========================================"
    echo " brainerd is live!"
    echo " IP:  $VPS_IP"
    echo " DNS: brainerd.infra.homelab.invalid"
    echo ""
    echo " If the public IP CHANGED, clear stale host keys:"
    echo "   ssh-keygen -R $VPS_IP && ssh-keygen -R brainerd.homelab.invalid"
    echo " (wg-gateway pod re-resolves the hostname and reconnects on its"
    echo "  own within ~2 minutes via the liveness probe)"
    echo "========================================"
  '';
}
