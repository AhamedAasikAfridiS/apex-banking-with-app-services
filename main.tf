# Terraform configuration to deploy the Secure Private KYC Banking Infrastructure on Azure

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.71.0"
    }
  }
}

variable "smtp_host" {
  type        = string
  description = "The SMTP server hostname (e.g., smtp.sendgrid.net)"
  default     = "smtp.mailtrap.io"
}

variable "smtp_port" {
  type        = string
  description = "The SMTP server port (e.g., 587)"
  default     = "587"
}

variable "smtp_user" {
  type        = string
  description = "The SMTP server username"
  default     = ""
}

variable "smtp_pass" {
  type        = string
  description = "The SMTP server password"
  default     = ""
  sensitive   = true
}

provider "azurerm" {
  features {}
}

# 1. Resource Group
resource "azurerm_resource_group" "rg" {
  name     = "rg-apex-private-tf"
  location = "Central India"
}

# 2. Virtual Network & Subnets
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-apex-banking-tf"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "snet_appgw" {
  name                 = "snet-appgw"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/27"]
}

resource "azurerm_subnet" "snet_appservice" {
  name                 = "snet-appservice"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/27"]

  delegation {
    name = "appservice-delegation"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_subnet" "snet_function" {
  name                 = "snet-function"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.5.0/27"]

  delegation {
    name = "function-delegation"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_subnet" "snet_postgres" {
  name                 = "snet-postgres"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.4.0/28"]

  delegation {
    name = "postgres-delegation"
    service_delegation {
      name    = "Microsoft.Network/fpga" # Fallback/generic or PostgreSQL
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_subnet" "snet_privateendpoints" {
  name                 = "snet-privateendpoints"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.3.0/26"]
}

# Private DNS Zone for PostgreSQL Flexible Server
resource "azurerm_private_dns_zone" "postgres_dns" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres_dns_link" {
  name                  = "postgres-dns-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.postgres_dns.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

# 3. PostgreSQL Flexible Server
resource "azurerm_postgresql_flexible_server" "db_server" {
  name                   = "banking-app-db-tf"
  resource_group_name    = azurerm_resource_group.rg.name
  location               = azurerm_resource_group.rg.location
  version                = "15"
  delegated_subnet_id    = azurerm_subnet.snet_postgres.id
  private_dns_zone_id    = azurerm_private_dns_zone.postgres_dns.id
  administrator_login    = "bankingapp"
  administrator_password = "ApexSecure123!" # Meets strong password rules

  sku_name   = "B_Standard_B1ms"
  storage_mb = 32768

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres_dns_link]
}

resource "azurerm_postgresql_flexible_server_database" "db" {
  name      = "autohub"
  server_id = azurerm_postgresql_flexible_server.db_server.id
  collation = "en_US.utf8"
  charset   = "utf8"
}

# 4. Storage Account & Containers
resource "azurerm_storage_account" "storage" {
  name                     = "saapexbankingtf"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  public_network_access_enabled = false
}

resource "azurerm_storage_container" "kyc_docs" {
  name                  = "kyc-documents"
  storage_account_name  = azurerm_storage_account.storage.name
  container_access_type = "private"
}

resource "azurerm_storage_container" "processed_docs" {
  name                  = "processed-and-validated-container"
  storage_account_name  = azurerm_storage_account.storage.name
  container_access_type = "private"
}

# Private DNS Zone for Storage Blob Endpoints
resource "azurerm_private_dns_zone" "blob_dns" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob_dns_link" {
  name                  = "blob-dns-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.blob_dns.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

# Private Endpoint for Storage Account
resource "azurerm_private_endpoint" "storage_pe" {
  name                = "pe-storage-blob"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.snet_privateendpoints.id

  private_service_connection {
    name                           = "storage-blob-connection"
    private_connection_resource_id = azurerm_storage_account.storage.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "storage-dns-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob_dns.id]
  }
}

# 5. Service Bus Namespace & Queue
resource "azurerm_servicebus_namespace" "sb" {
  name                = "sb-apex-notifications-tf"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"

  public_network_access_enabled = false
}

resource "azurerm_servicebus_queue" "sb_queue" {
  name         = "kyc-notifications"
  namespace_id = azurerm_servicebus_namespace.sb.id
}

# Private DNS Zone for Service Bus
resource "azurerm_private_dns_zone" "sb_dns" {
  name                = "privatelink.servicebus.windows.net"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "sb_dns_link" {
  name                  = "sb-dns-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.sb_dns.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

# Private Endpoint for Service Bus Namespace
resource "azurerm_private_endpoint" "sb_pe" {
  name                = "pe-servicebus"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  subnet_id           = azurerm_subnet.snet_privateendpoints.id

  private_service_connection {
    name                           = "sb-connection"
    private_connection_resource_id = azurerm_servicebus_namespace.sb.id
    subresource_names              = ["namespace"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "sb-dns-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.sb_dns.id]
  }
}

# 6. App Service Plan
resource "azurerm_service_plan" "app_plan" {
  name                = "asp-apex-banking-tf"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Linux"
  sku_name            = "B1"
}

# 7. Linux Web App (Express Application)
resource "azurerm_linux_web_app" "web_app" {
  name                = "apex-bank-tf"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  service_plan_id     = azurerm_service_plan.app_plan.id

  site_config {
    always_on = true
    application_stack {
      node_version = "20-lts"
    }

    # Restrict incoming access to only the App Gateway Subnet
    ip_restriction {
      name                      = "Allow-AppGW-Only"
      priority                  = 100
      action                    = "Allow"
      virtual_network_subnet_id = azurerm_subnet.snet_appgw.id
    }
  }

  virtual_network_subnet_id = azurerm_subnet.snet_appservice.id

  app_settings = {
    "PORT"                                  = "8080"
    "JWT_SECRET"                            = "banking_premium_app_secret_key_9988776655"
    "DATABASE_URL"                          = "postgres://bankingapp:ApexSecure123%21@banking-app-db-tf.postgres.database.azure.com:5432/autohub?sslmode=require"
    "AZURE_STORAGE_CONNECTION_STRING"       = "DefaultEndpointsProtocol=https;AccountName=${azurerm_storage_account.storage.name};AccountKey=${azurerm_storage_account.storage.primary_access_key};EndpointSuffix=core.windows.net"
    "AZURE_SERVICE_BUS_CONNECTION_STRING"   = azurerm_servicebus_namespace.sb.default_primary_connection_string
    "SMTP_HOST"                             = var.smtp_host
    "SMTP_PORT"                             = var.smtp_port
    "SMTP_USER"                             = var.smtp_user
    "SMTP_PASS"                             = var.smtp_pass
  }
}

# 8. Function App (Blob triggered OCR)
resource "azurerm_linux_function_app" "func_app" {
  name                = "fn-apex-kyc-validator-tf"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  service_plan_id     = azurerm_service_plan.app_plan.id

  storage_account_name       = azurerm_storage_account.storage.name
  storage_account_access_key = azurerm_storage_account.storage.primary_access_key

  site_config {
    application_stack {
      node_version = "20"
    }
  }

  virtual_network_subnet_id = azurerm_subnet.snet_function.id

  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME"              = "node"
    "AzureWebJobsStorage"                   = "DefaultEndpointsProtocol=https;AccountName=${azurerm_storage_account.storage.name};AccountKey=${azurerm_storage_account.storage.primary_access_key};EndpointSuffix=core.windows.net"
    "DATABASE_URL"                          = "postgres://bankingapp:ApexSecure123%21@banking-app-db-tf.postgres.database.azure.com:5432/autohub?sslmode=require"
    "AZURE_STORAGE_CONNECTION_STRING"       = "DefaultEndpointsProtocol=https;AccountName=${azurerm_storage_account.storage.name};AccountKey=${azurerm_storage_account.storage.primary_access_key};EndpointSuffix=core.windows.net"
    "AZURE_SERVICE_BUS_CONNECTION_STRING"   = azurerm_servicebus_namespace.sb.default_primary_connection_string
  }
}

# 9. Public IP for Application Gateway
resource "azurerm_public_ip" "appgw_pip" {
  name                = "pip-agw-tf"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# 10. Application Gateway
resource "azurerm_application_gateway" "appgw" {
  name                = "agw-apex-banking-tf"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 1
  }

  gateway_ip_configuration {
    name      = "my-gateway-ip-configuration"
    subnet_id = azurerm_subnet.snet_appgw.id
  }

  frontend_port {
    name = "port-80"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "appgw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw_pip.id
  }

  backend_address_pool {
    name  = "bp-webapp"
    fqdns = [azurerm_linux_web_app.web_app.default_hostname]
  }

  backend_http_settings {
    name                                = "http-settings"
    cookie_based_affinity               = "Disabled"
    path                                = "/"
    port                                = 80
    protocol                            = "Http"
    request_timeout                     = 60
    probe_name                          = "probe-health"
    pick_host_name_from_backend_address = true
  }

  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "appgw-frontend-ip"
    frontend_port_name             = "port-80"
    protocol                       = "Http"
  }

  probe {
    name                                      = "probe-health"
    protocol                                  = "Http"
    path                                      = "/health"
    interval                                  = 30
    timeout                                   = 30
    unhealthy_threshold                       = 3
    pick_host_name_from_backend_http_settings = true
  }

  request_routing_rule {
    name                       = "rule-ingress"
    rule_type                  = "Basic"
    http_listener_name         = "http-listener"
    backend_address_pool_name  = "bp-webapp"
    backend_http_settings_name = "http-settings"
    priority                   = 100
  }
}
