
# Azure Provider source and version being used
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">=3.40.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">=3.4.3"
    }
  }
}

provider "azurerm" {
  features {}
  # subscription_id = var.subscription_id
}

provider "random" {
}
