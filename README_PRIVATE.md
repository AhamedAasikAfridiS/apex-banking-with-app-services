# Secure Private Architecture Guide: Application Gateway & Private Endpoints

This guide details how to configure the **Apex Premium Banking Portal** in a fully secure, zero-trust cloud network on Azure. In this setup:
1. **Public Ingress** is strictly restricted to the **Application Gateway** public IP address.
2. The **Web App (App Service)** blocks all direct public internet access, accepting traffic **only** from the Application Gateway subnet.
3. Backend resources (**PostgreSQL**, **Storage Account**, and **Service Bus**) disable all public network access, communicating privately using **VNet Integration** and **Private Endpoints**.

---

## Private Network Architecture

```mermaid
flowchart TD
    subgraph Public Internet
        Client[User Browser]
    end

    subgraph Azure Virtual Network (vnet-apex-banking)
        subgraph snet-appgw [Subnet: snet-appgw (10.0.1.0/27)]
            AppGW[Application Gateway]
        end

        subgraph snet-appservice [Subnet: snet-appservice (10.0.2.0/27)]
            WebApp[App Service Web App]
        end

        subgraph snet-function [Subnet: snet-function (10.0.5.0/27)]
            FuncApp[Function App]
        end

        subgraph snet-postgres [Subnet: snet-postgres (10.0.4.0/28)]
            Postgres[(PostgreSQL Server)]
        end

        subgraph snet-privateendpoints [Subnet: snet-privateendpoints (10.0.3.0/26)]
            PE_Storage[Private Endpoint: saapexbanking]
            PE_Bus[Private Endpoint: sb-apex-notifications]
        end
    end

    Client -->|Public HTTP/S| AppGW
    AppGW -->|Private Routing| WebApp
    WebApp -->|Outbound VNet Integration| PE_Storage
    WebApp -->|Outbound VNet Integration| PE_Bus
    WebApp -->|Outbound VNet Integration| Postgres
    FuncApp -->|Outbound VNet Integration| PE_Storage
    FuncApp -->|Outbound VNet Integration| PE_Bus
    FuncApp -->|Outbound VNet Integration| Postgres
```

---

## Step 1: Resource Group & VNet Configuration

To avoid routing issues, all resources **must** be created in the **same region** (e.g., `Central India`).

1. **Create the Resource Group:**
   * Name: `rg-apex-private`
   * Region: `Central India`
2. **Create the Virtual Network (VNet):**
   * Name: `vnet-apex-banking`
   * Address Space: `10.0.0.0/16`
3. **Configure the 5 Subnets:**
   * Go to **Subnets** in your Virtual Network and click **+ Subnet** to add each:
     | Subnet Name | Address Range | Subnet Delegation | Purpose |
     | :--- | :--- | :--- | :--- |
     | `snet-appgw` | `10.0.1.0/27` | None | Application Gateway ingress |
     | `snet-appservice` | `10.0.2.0/27` | `Microsoft.Web/serverFarms` | Web App Outbound VNet Integration |
     | `snet-function` | `10.0.5.0/27` | `Microsoft.Web/serverFarms` | Function App Outbound VNet Integration |
     | `snet-postgres` | `10.0.4.0/28` | `Microsoft.DBforPostgreSQL/flexibleServers` | PostgreSQL Private VNet access |
     | `snet-privateendpoints`| `10.0.3.0/26` | None | Host Private Endpoints |

---

## Step 2: Configure the Private PostgreSQL Server

1. Search for **Azure Database for PostgreSQL flexible servers** -> Click **+ Create**.
2. **Compute + Storage:** B1ms Burstable (development tier).
3. **Admin Credentials:** Set username as `bankingapp` and password as `Apex@1234`.
4. **Networking:**
   * Connectivity method: Choose **Private access (VNet Integration)**.
   * Virtual network: Select `vnet-apex-banking`.
   * Subnet: Select `snet-postgres`.
5. Click **Review + create** -> **Create**. 
   * *Note: Azure will automatically configure a Private DNS zone named `privatelink.postgres.database.azure.com` inside your resource group.*

---

## Step 3: Configure Private Storage & Service Bus

### 1. Storage Account & Private Endpoint
1. Search for **Storage accounts** -> Click **+ Create**.
2. **Name:** `saapexbanking` (LRS redundancy is sufficient).
3. Once deployed, click **Networking** (under Security + networking) -> Go to **Private endpoint connections** tab:
   * Click **+ Private endpoint**.
   * **Name:** `pe-storage-blob` | **Region:** `Central India`.
   * **Target sub-resource:** Select **`blob`**.
   * **Subnet:** Select `vnet-apex-banking` $\rightarrow$ `snet-privateendpoints`.
   * **Private DNS integration:** Select **Yes** (this links a private DNS zone named `privatelink.blob.core.windows.net` to your VNet).
4. Go back to the **Firewalls and virtual networks** tab:
   * Change public network access to **Disabled** or **Enabled from selected virtual networks and IP addresses** (leaving the configuration empty to deny all).

### 2. Service Bus Namespace & Private Endpoint
1. Search for **Service Bus** -> Click **+ Create** (Select **Standard** or **Premium** tier; basic does not support private networking).
2. **Name:** `sb-apex-notifications`.
3. Once deployed, click **Networking** -> **Private endpoint connections** -> Click **+ Private endpoint**:
   * **Name:** `pe-servicebus` | **Target sub-resource:** **`namespace`**.
   * **Subnet:** Select `snet-privateendpoints`.
   * **Private DNS integration:** Select **Yes** (integrates with `privatelink.servicebus.windows.net`).
4. In the **Public access** tab, change public access to **Disabled**.
5. Create your queue named `kyc-notifications` under **Queues** in the left menu.

---

## Step 4: Configure Web App VNet Integration & Access Restrictions

1. Create a Linux Node.js 20 Web App named `apex-banking` in `Central India` on a **Basic B1** (or higher) App Service plan.
2. **Configure Outbound VNet Integration:**
   * Go to **Networking** in the Web App's left menu.
   * Under **Outbound traffic**, click **VNet integration**.
   * Click **+ Add VNet integration** $\rightarrow$ select `vnet-apex-banking` $\rightarrow$ select `snet-appservice`. Click **Connect**.
3. **Configure Inbound Access Restrictions (Blocks Public Internet):**
   * Under **Inbound traffic** (in the Networking tab), click **Access restrictions**.
   * Click **+ Add rule**:
     * **Name:** `Allow-AppGW-Only`
     * **Action:** `Allow`
     * **Source type:** `Virtual Network`
     * **Subnet:** Select `vnet-apex-banking` $\rightarrow$ `snet-appgw` (the Application Gateway subnet).
   * Ensure the **Unmatched rule** (default rule) is set to **Deny**.
   * *Result: Any request trying to access `apex-banking.azurewebsites.net` directly from the internet will receive a `403 Forbidden` response.*

---

## Step 5: Configure Function App VNet Integration

1. Create your Function App (`fn-apex-kyc-validator`) on an **App Service Plan** (reusing the Web App plan) or **Flex Consumption** in the `Central India` region.
2. Go to **Networking** in the Function App's left menu.
3. Under **Outbound traffic**, click **VNet integration**.
4. Select `vnet-apex-banking` $\rightarrow$ subnet `snet-function`.
5. *Result: The Function App can now resolve the private DNS hosts of the Storage Account, Service Bus, and PostgreSQL server.*

---

## Step 6: Create the Application Gateway (Public Entry Point)

1. Search for **Application Gateways** -> Click **+ Create**.
2. **Basics:**
   * Name: `agw-apex-banking` | Region: `Central India`.
   * Tier: **Standard v2**.
   * Virtual network: Select `vnet-apex-banking` $\rightarrow$ subnet `snet-appgw`.
3. **Frontends:**
   * Frontend IP address type: Select **Public** -> Create a new public IP address.
4. **Backends:**
   * Click **Add a backend pool**.
   * Name: `bp-webapp`.
   * Target Type: Select **App Services**.
   * Target: Select your Web App (`apex-banking.azurewebsites.net`).
5. **Configuration (Routing Rules):**
   * Click **Add a routing rule**.
   * Name: `rule-ingress`.
   * **Listener tab:**
     * Listener name: `http-listener`.
     * Frontend IP: **Public**.
     * Protocol: **HTTP** | Port: **80** (you can update to HTTPS/443 later).
   * **Backend targets tab:**
     * Backend target: `bp-webapp`.
     * **Backend settings:** Click **Create new**:
       * Backend settings name: `http-settings`.
       * Port: `80` (or `443` for HTTPS).
       * Override with new host name: Select **Yes**.
       * Host name override: Choose **Yes - Pick host name from backend address**.
       * Click **Save**.

### 7. Configure the Health Probe (Crucial for App Service)
If the Application Gateway reports the Web App backend as unhealthy:
1. Under **Settings** in the Application Gateway left menu, click **Health probes**.
2. Click **+ Add**:
   * Name: `probe-health`.
   * Protocol: `HTTP` (or `HTTPS`).
   * Host: Select **Pick host name from backend settings**.
   * Path: **/health** (Matches the endpoint defined in [app.js](file:///c:/Users/Admin/Desktop/banking-app/app.js)).
   * Match conditions (status code): **200-399**.
3. Go back to your **Backend settings** (`http-settings`), check **"Custom probe"**, and choose your new `probe-health` probe. Click **Save**.

---

## Troubleshooting Private Deployments

* **502 Bad Gateway / Unhealthy Backend:**
  This usually means the Application Gateway health probe is getting blocked or getting a 404/403:
  1. Confirm the health probe path is exactly `/health`.
  2. Confirm **Pick host name from backend settings** is enabled in the probe, and **Pick host name from backend address** is enabled in HTTP Settings.
  3. Ensure the Web App's **Access Restrictions** allow the subnet `snet-appgw` (if restricted, AppGW probes will get a `403 Forbidden` unless the rule permits it).
* **ENOTFOUND Error in Logs:**
  If Web App or Function App logs say `getaddrinfo ENOTFOUND`:
  1. Confirm outbound VNet integration is enabled.
  2. Confirm **Private DNS Zones** (e.g., `privatelink.blob.core.windows.net`) are linked to the VNet (`vnet-apex-banking`). Under **Private DNS zones** in the portal, select the zone, click **Virtual network links** in the left menu, and verify the link exists and is healthy.
