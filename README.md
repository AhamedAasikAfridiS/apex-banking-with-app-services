# Apex Premium Banking Portal: E2E Azure KYC Architecture

A premium, single-file self-contained banking web application written in Node.js (Express) coupled with a Blob-Triggered Azure Function that performs OCR verification and renames processed documents, coordinated asynchronously via Azure Service Bus.

This application runs perfectly in **two modes**:
1. **Local Fallback Mode:** Requires zero Azure configuration; uses local filesystem (`uploads/`), JSON DB (`database.json`), and in-memory events.
2. **Azure Cloud Mode:** Fully integrated enterprise cloud architecture using Azure App Service, Azure Functions, Azure Database for PostgreSQL, Blob Storage, Service Bus, and Application Gateway.

---

## Architecture Flow

```mermaid
sequenceDiagram
    autonumber
    actor User as User Browser
    participant WebApp as Web App (App Service)
    participant DB as PostgreSQL Server
    participant BlobIn as Blob Container (kyc-documents)
    participant Func as Azure Function (Blob Trigger)
    participant BlobOut as Blob Container (processed-and-validated-container)
    participant Bus as Service Bus Queue (kyc-notifications)
    participant Email as SMTP / Nodemailer

    User->>WebApp: 1. Register & Upload Aadhaar/PAN/Passport
    WebApp->>BlobIn: 2. Upload file named "kyc-{userId}-{random}.{ext}"
    BlobIn-->>Func: 3. Trigger on new blob upload
    Func->>DB: 4. Query user name by userId
    Note over Func: 5. Extract DOB & validate document pattern via OCR
    alt Document is Genuine
        Func->>BlobOut: 6a. Upload renamed blob "{username}_{dob}_{docType}.{ext}"
        Func->>BlobIn: 7a. Delete original raw blob
        Func->>Bus: 8a. Publish SUCCESS message
    else Document is Invalid
        Func->>BlobIn: 6b. Delete original raw blob
        Func->>Bus: 7b. Publish FAILURE message
    end
    Bus-->>WebApp: 9. Consume message from queue
    WebApp->>DB: 10. Update KYC status & log security audit
    WebApp->>Email: 11. Dispatch verification email to User
    Email-->>User: 12. Receive Email Alert
    WebApp-->>User: 13. Refresh dynamic balance charts & alerts
```

---

## Phase 1: Local Development & Fallback Setup

If you want to run the app locally without configuring Azure:

1. **Install Dependencies:**
   ```bash
   npm install
   ```
2. **Configure Local Environment:**
   Create a `.env` file in the root folder with the following contents:
   ```env
   PORT=3000
   JWT_SECRET=banking_premium_app_secret_key_9988776655
   DB_SSL=false
   ```
3. **Run the App:**
   ```bash
   npm start
   # or for development: npm run dev
   ```
4. **Access the App:** Open `http://localhost:3000` in your browser.
   * *Fallback Behavior:* The app automatically falls back to [database.json](file:///c:/Users/Admin/Desktop/banking-app/database.json) if Postgres is not found and starts a local background loop to simulate the Azure Function/Service Bus triggers.

---

## Phase 2: Azure Cloud Resource Setup (Step-by-Step)

To deploy the production-ready secure network architecture, configure the following resources in the [Azure Portal](https://portal.azure.com):

### Step 1: Create a Resource Group
* Search for **Resource groups** -> Click **+ Create**.
* **Resource Group Name:** `rg-apex-banking`
* **Region:** Select `Central India` (or your preferred region). Keep all subsequent resources in this **same region**.

### Step 2: Create a Virtual Network & Subnets (Optional for Private Network)
To secure the database and event bus behind private endpoints:
* Search for **Virtual networks** -> Click **+ Create**.
* **Name:** `vnet-apex-banking`
* Under **Subnets**, add the following **5 subnets**:
  1. `snet-appgw` | Range: `10.0.1.0/27` (For Application Gateway)
  2. `snet-appservice` | Range: `10.0.2.0/27` (Delegated to `Microsoft.Web/serverFarms` for Web App)
  3. `snet-function` | Range: `10.0.5.0/27` (Delegated to `Microsoft.Web/serverFarms` for Function App)
  4. `snet-postgres` | Range: `10.0.4.0/28` (Delegated to `Microsoft.DBforPostgreSQL/flexibleServers` for DB)
  5. `snet-privateendpoints` | Range: `10.0.3.0/26` (For storage, service bus private endpoints)

### Step 3: Create the PostgreSQL Flexible Server
* Search for **Azure Database for PostgreSQL flexible servers** -> Click **+ Create**.
* **Server Name:** `banking-app-db`
* **Compute + storage:** Choose **Burstable, B1ms** (cost-effective development plan).
* **Admin credentials:** Username: `bankingapp` | Password: `Apex@1234`
* **Networking:** 
  * *Private Network Setup:* Choose **Private access (VNet Integration)** -> Select `vnet-apex-banking` and subnet `snet-postgres`.
  * *Public Network Setup:* Choose **Public access (allowed IP addresses)** -> Check **"Allow public access from any Azure service within Azure to this server"** (Required so App Service and Functions can query it without a VNet).

### Step 4: Create the Storage Account
* Search for **Storage accounts** -> Click **+ Create**.
* **Storage account name:** `saapexbanking`
* **Redundancy:** Select **LRS** (Locally Redundant Storage).
* Once deployed, go to **Containers** (under Data Storage) -> Click **+ Container**:
  * Create **`kyc-documents`** (Private access)
  * Create **`processed-and-validated-container`** (Private access)
* Go to **Access Keys** -> Copy the **Connection String** for `key1`.

### Step 5: Create the Service Bus Namespace & Queue
* Search for **Service Bus** -> Click **+ Create**.
* **Namespace Name:** `sb-apex-notifications`
* **Pricing Tier:** Select **Standard** (Standard is required to support Private Endpoints/VNet integration).
* Once deployed, go to **Queues** (under Entities) -> Click **+ Queue**:
  * Name: **`kyc-notifications`** -> Click **Create**.
* Go to **Shared access policies** -> Click `RootManageSharedAccessKey` -> Copy the **Primary Connection String**.

---

## Phase 3: Deploying the Web Application (Express App)

1. **Create the Web App:**
   * Search for **App Services** -> Click **+ Create** -> **Web App**.
   * **Resource Group:** `rg-apex-banking`
   * **Name:** `apex-banking`
   * **Runtime stack:** `Node.js 20 LTS` | **OS:** `Linux`
   * **App Service Plan:** Choose `Central India` (matching the region of the VNet/DB) and a `Basic B1` plan.
   * **Networking:** If using Private Network, select Virtual Network `vnet-apex-banking` and subnet `snet-appservice`.

2. **Add Application Settings (Environment Variables):**
   Open the Web App -> Go to **Configuration** (or **Environment variables**) and add these Key-Value pairs:
   * `PORT` = `8080` (App Service routes to port 8080 by default)
   * `JWT_SECRET` = `banking_premium_app_secret_key_9988776655`
   * `DATABASE_URL` = `postgres://bankingapp:Apex%401234@banking-app-db.postgres.database.azure.com:5432/autohub?sslmode=require` *(Ensure the `@` character in the password is URL encoded as `%40`)*
   * `AZURE_STORAGE_CONNECTION_STRING` = `[Copy Connection String from Storage Account]`
   * `AZURE_SERVICE_BUS_CONNECTION_STRING` = `[Copy Connection String from Service Bus]`
   * `SMTP_HOST` / `SMTP_PORT` / `SMTP_USER` / `SMTP_PASS` = `[Your SMTP Email Credentials]`

3. **CI/CD Deployment via GitHub Actions:**
   * Download the **Publish Profile** of the Web App from the Azure Portal.
   * Go to your GitHub Repository -> **Settings** -> **Secrets and variables** -> **Actions** -> Add a repository secret:
     * **Name:** `AZUREAPPSERVICE_PUBLISHPROFILE_2B6E08C30C004C3395328C45F80A02A9`
     * **Value:** `[Paste Publish Profile content]`
   * Trigger the action configured in [.github/workflows/main_apex-bank.yml](file:///c:/Users/Admin/Desktop/banking-app/.github/workflows/main_apex-bank.yml) by pushing to the `main` branch.

---

## Phase 4: Deploying the Azure Function (Blob Trigger)

1. **Create the Function App:**
   * Search for **Function App** -> Click **+ Create**.
   * **Name:** `fn-apex-kyc-validator`
   * **Runtime stack:** `Node.js` | **Version:** `20` | **OS:** `Linux`
   * **Hosting plan:** 
     * Select **App Service Plan** and select the plan created in Phase 3 (Cheapest, runs for free under the same plan).
     * Or select **Flex Consumption** (Serverless, supports VNets).
   * **Storage:** Select the storage account `saapexbanking` created in Phase 2.
   * **Networking:** Link to VNet `vnet-apex-banking` and subnet `snet-function`.

2. **Configure Application Settings:**
   Open the Function App -> Go to **Configuration** and add:
   * `DATABASE_URL` = `postgres://bankingapp:Apex%401234@banking-app-db.postgres.database.azure.com:5432/autohub?sslmode=require`
   * `AZURE_STORAGE_CONNECTION_STRING` = `[Connection String from Storage Account]`
   * `AZURE_SERVICE_BUS_CONNECTION_STRING` = `[Connection String from Service Bus]`

3. **Deploy the Function Code:**
   * Deploy the code inside the [/azure-function](file:///c:/Users/Admin/Desktop/banking-app/azure-function) subdirectory to the Function App using VS Code Azure Functions Extension or the Azure Core Tools CLI:
     ```bash
     cd azure-function
     func azure functionapp publish fn-apex-kyc-validator
     ```

---

## Phase 5: Application Gateway & Health Probes

If you configure Azure Application Gateway (AGW) as a reverse proxy in front of the App Service, configure the health probes as follows:

*   **Host Name (Critical):**
    *   Set the Health Probe **Host** manually to `apex-banking.azurewebsites.net` (or your customized App Service FQDN). 
    *   Alternatively, in the AGW settings, select **"Pick host name from backend HTTP settings"** and enable **"Override with new host name"** (selecting **"Yes - Pick host name from backend address"**).
    *   *Why:* Azure App Service front-end routers block any request whose Host header does not match the app's default URL, resulting in a `404 Site Not Found` mismatch.
*   **Health Probe Path:** `/health` or `/api/health` (Both are defined in [app.js](file:///c:/Users/Admin/Desktop/banking-app/app.js) and return a status code of `200` to indicate healthy status).
*   **Protocol:** `HTTPS`

---

## Phase 6: Testing & End-to-End Verification

To verify the deployment:
1. **Register:** Navigate to your Web App's URL, sign up a new account (e.g., `test_user@apex.com`).
2. **Submit KYC Profile:** Go to the **Verification (KYC)** tab, input your Date of Birth (e.g., `01-01-1990`), and select a document type (e.g., Aadhaar).
3. **Upload File:** Upload a PDF or Image Aadhaar card.
4. **Trigger Flow:**
   * The web application uploads the file to `kyc-documents` container.
   * The Azure Function [validateDoc.js](file:///c:/Users/Admin/Desktop/banking-app/azure-function/src/functions/validateDoc.js) fires. It performs local OCR scanning via `tesseract.js` / `pdf-parse` to find name and date-of-birth matches.
   * If genuine, the file is renamed to `test_user_01-01-1990_Aadhaar.png` and uploaded to the `processed-and-validated-container`. The temporary original is deleted.
   * The Function App publishes a status message to the `kyc-notifications` Service Bus queue.
5. **Update and Notify:** The Web App's Service Bus listener consumes the message, updates the database, updates the dashboard status badge, and dispatches a verification notification email to `test_user@apex.com`.
