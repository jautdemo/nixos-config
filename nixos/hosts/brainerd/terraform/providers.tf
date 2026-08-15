terraform {
  required_version = ">= 1.5"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.23.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "oci" {
    bucket              = "brainerd-tfstate"
    namespace           = "zrywqjey5apk"
    key                 = "terraform.tfstate"
    region              = "eu-frankfurt-1"
    auth                = "APIKey"
    config_file_profile = "DEFAULT"
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "oci" {
  config_file_profile = "DEFAULT"
  region              = var.region
}
