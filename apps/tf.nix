# tf <terraform args>   (nix run .#tf -- plan)
#
# Runs terraform for brainerd with its variables decrypted from
# secrets/terraform-brainerd.json.age into TF_VAR_* environment variables.
# The plaintext exists only in this process: nothing is written to disk, so
# there is no window where a stray `terraform fmt -diff` or a backup can pick
# it up. Asks for the YubiKey every run, by design.
#
# Returns the package, not an app: brainerd-bootstrap puts it in runtimeInputs.
{ pkgs, ageIdentity }:

pkgs.writeShellApplication {
  name = "tf";
  runtimeInputs = [
    pkgs.age
    ageIdentity
    pkgs.terraform
    pkgs.jq
    pkgs.coreutils
    pkgs.git
  ];
  text = ''
    cd "$(git rev-parse --show-toplevel)"

    # The identity is a pointer to the YubiKey, not a key, so a temp file for it
    # is harmless. The decrypted variables never leave this process.
    ident="$(mktemp)"
    trap 'rm -f "$ident"' EXIT
    age-identity > "$ident"

    echo "==> Decrypting terraform variables: enter the PIN, then TOUCH the key" >&2
    vars="$(age --decrypt -i "$ident" secrets/terraform-brainerd.json.age)"
    [ -n "$vars" ] || { echo "FATAL: variables decrypted to nothing" >&2; exit 1; }

    # Strings go in raw, everything else as JSON, which is what terraform
    # expects from TF_VAR_. base64 so a value can contain anything.
    # The X sentinel is load-bearing: command substitution strips trailing
    # newlines, which truncates a PEM by one byte and makes terraform want to
    # replace a live certificate.
    while read -r k b64; do
      val="$(printf '%s' "$b64" | base64 -d; printf X)"
      export "TF_VAR_$k=''${val%X}"
    done < <(printf '%s' "$vars" | jq -r '
      to_entries[]
      | "\(.key) \((if (.value|type) == "string" then .value else (.value|tojson) end)|@base64)"')
    unset vars

    terraform -chdir=nixos/hosts/brainerd/terraform "$@"
  '';
}
