# age-identity > <file>
#
# Prints an age identity for whichever YubiKey is plugged in; exits non-zero
# if none, so `set -e` callers stop before decrypting.
# AGE_IDENTITY=/path/to/key overrides (break-glass with a software key).
{ pkgs }:

pkgs.writeShellApplication {
  name = "age-identity";
  runtimeInputs = [
    pkgs.age-plugin-yubikey
    pkgs.coreutils
  ];
  text = ''
    if [ -n "''${AGE_IDENTITY:-}" ]; then
      cat "$AGE_IDENTITY"
      exit 0
    fi

    out="$(age-plugin-yubikey --identity 2>/dev/null || true)"
    if [ -z "$out" ]; then
      echo "No YubiKey detected. Plug one in, or set AGE_IDENTITY=/path/to/key." >&2
      exit 1
    fi
    printf '%s\n' "$out"
  '';
}
