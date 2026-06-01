# Apex Premium Banking Portal

A premium, single-file self-contained banking web application written in Node.js (Express) with a PostgreSQL database layer, secure JWT cookie authentication, KYC document upload, statement extraction, and interactive dashboards.

## Features

- **User Authentication**: Secure signup and signin using `bcryptjs` password hashing and HttpOnly JWT cookie session control.
- **Dynamic Dashboard**: Responsive metrics panel tracking current balances, total inflow, and debits with double bar and balance breakdown graphs powered by `Chart.js`.
- **Core Operations**: Bulletproof atomic transactions supporting deposits, withdrawals, and bank-to-bank transfers by email utilizing PostgreSQL transactions.
- **KYC Verification**: Multer-backed document upload (Aadhaar/PAN/Passport) with status badge tracking (`Pending`, `Submitted`, `Verified`).
- **Statements Exporter**: Account ledger statement queries downloadable instantly in CSV format.
- **Admin Control Center**: Built-in review dashboard listing registered users and transactions, allowing administrators to review and approve/reject KYC submissions.
- **Security Auditing & Alerts**: Compliance audit trail logging (tracks logins, logouts, transactions, and verification changes) and a new **Security & Alerts** dashboard tab displaying event history and transaction push notifications.
- **Database Fallback**: Safe connection pool initialization that reverts dynamically to a local `database.json` file if PostgreSQL is offline or configurations are wrong.
- **Azure App Service Ready**: Binds to standard ports, integrates Azure connection parameters (including `DATABASE_URL` and TLS/SSL configurations), and runs stateless-compatible storage.

---

## Getting Started

### 1. Installation
Clone or navigate to the directory and install dependencies:
```bash
npm install
```

### 2. Configure Environment Variables
Create or update the `.env` file in the root folder. Default variables are:
```env
PORT=3000
JWT_SECRET=banking_premium_app_secret_key_9988776655

# PostgreSQL database settings
DB_USER=postgres
DB_PASSWORD=SecurePass123!@
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=autohub
DB_SSL=false
```

### 3. Run the App
Launch the server in production mode:
```bash
npm start
```
Or in hot-reloading development mode:
```bash
npm run dev
```

Open **[http://localhost:3000](http://localhost:3000)** in your browser.

---

## Verification and Testing Flow

You can perform end-to-end testing of the registration, transfer, and verification loop:

1. **Sign Up**: Register two separate user accounts (e.g., `user1@apex.com` and `user2@apex.com`). Each starts with a ₹1,000 welcome bonus.
2. **KYC Upload**: Log in to `user1@apex.com`. Navigate to the **Verification (KYC)** tab and upload a test document (PDF, PNG, or JPG).
3. **Approve KYC**: Go to the **Control Center** tab (Admin view). Find `user1@apex.com` in the user grid and click **Approve**.
4. **Transfer Funds**: Navigate to the **Transfer & Funds** tab. Choose `Transfer to another user`, enter `user2@apex.com` as the recipient, specify an amount (e.g., ₹250.00), and submit.
5. **View Dashboard Charts**: Navigate to the **Overview** dashboard to see the income vs spending bar chart and the balance breakdown donut chart update in real-time.
6. **Export Statements**: Go to **Transactions List**, set your date filter, and click **Export CSV** to download the transaction ledger.

---

## Azure App Service Deployment

To deploy this application to Azure App Services (Linux Node.js runtime):

1. **Start Script**: The application configures `npm start` to execute `node app.js` which is the default entry point expected by Azure App Services.
2. **Port Binding**: The app binds to `process.env.PORT || 3000`. Azure App Service will set the `PORT` variable dynamically.
3. **Database settings**: Add database connection strings in the Azure portal under **App Service Configuration**:
   - Set `DATABASE_URL` or `AZURE_POSTGRESQL_CONNECTION_STRING` to your Azure Database for PostgreSQL connection string.
   - The application automatically turns on `SSL` connection mode with `rejectUnauthorized: false` when a remote host database is detected, meeting Azure's secure connection requirements.
4. **KYC Storage Note**: KYC documents are uploaded to the `./uploads` directory. In standard App Service deployments, this local directory is temporary. For production setups, ensure persistent shared storage is mounted or integrate a cloud blob storage service (e.g., Azure Blob Storage).
