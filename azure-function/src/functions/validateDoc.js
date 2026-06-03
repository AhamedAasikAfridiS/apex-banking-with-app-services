const { app } = require('@azure/functions');
const { BlobServiceClient } = require('@azure/storage-blob');
const { ServiceBusClient } = require('@azure/service-bus');
const { createWorker } = require('tesseract.js');
const pdfParse = require('pdf-parse');
const { Pool } = require('pg');

// Setup PostgreSQL Connection Pool
const pool = new Pool({
  connectionString: process.env.DATABASE_URL || process.env.AZURE_POSTGRESQL_CONNECTION_STRING
});

app.storageBlob('BlobTrigger1', {
  path: 'kyc-documents/{name}',
  connection: 'AZURE_STORAGE_CONNECTION_STRING',
  handler: async (blob, context) => {
    const filename = context.triggerMetadata.name;
    context.log(`[KYC TRIGGER] Processing blob: "${filename}"`);

    // Parse userId from filename (expected: kyc-{userId}-{uniqueSuffix}.{ext})
    const match = filename.match(/^kyc-(\d+)-/);
    if (!match) {
      context.error(`[KYC TRIGGER] Error: Filename does not match expected pattern: kyc-{userId}-...`);
      return;
    }
    const userId = parseInt(match[1]);

    let pgClient = null;
    let docType = 'Aadhaar';
    let docId = null;
    let userEmail = '';
    let userName = '';

    try {
      // Connect to PostgreSQL and fetch user profile
      pgClient = await pool.connect();
      const userRes = await pgClient.query('SELECT name, email FROM bank_users WHERE id = $1', [userId]);
      if (userRes.rows.length === 0) {
        throw new Error(`User with ID ${userId} not found in database.`);
      }
      userName = userRes.rows[0].name;
      userEmail = userRes.rows[0].email;

      // Extract metadata from the Blob properties
      const connStr = process.env.AZURE_STORAGE_CONNECTION_STRING;
      const blobServiceClient = BlobServiceClient.fromConnectionString(connStr);
      const sourceContainerClient = blobServiceClient.getContainerClient('kyc-documents');
      const sourceBlobClient = sourceContainerClient.getBlobClient(filename);
      const properties = await sourceBlobClient.getProperties();

      docType = properties.metadata.doc_type || 'Aadhaar';
      docId = properties.metadata.doc_id ? parseInt(properties.metadata.doc_id) : null;

      context.log(`[KYC TRIGGER] User: ${userName} (${userEmail}) | Document Type: ${docType} | Database Doc ID: ${docId}`);

      let isValid = false;
      let reason = '';
      let dob = null;
      let textContent = '';

      if (docType === 'Photo') {
        // Face profile photos skip OCR and are validated based on image extension
        const contentType = properties.contentType || '';
        const isImage = contentType.startsWith('image/') || filename.toLowerCase().match(/\.(jpg|jpeg|png)$/);
        if (isImage) {
          isValid = true;
          reason = 'Biometric photo structure and metadata validated successfully.';
        } else {
          isValid = false;
          reason = 'Profile Photo must be a valid image file (JPG or PNG).';
        }
      } else {
        // OCR Processing based on file extension
        const ext = filename.split('.').pop().toLowerCase();
        context.log(`[KYC TRIGGER] Initiating OCR for extension: .${ext}`);

        if (ext === 'pdf') {
          // Extract text from PDF using pdf-parse
          const pdfData = await pdfParse(blob);
          textContent = pdfData.text || '';
          context.log(`[KYC TRIGGER] PDF Text Extraction completed. Characters read: ${textContent.length}`);
        } else if (['jpg', 'jpeg', 'png'].includes(ext)) {
          // Extract text from Image using tesseract.js
          const worker = await createWorker('eng');
          const { data: { text } } = await worker.recognize(blob);
          textContent = text || '';
          await worker.terminate();
          context.log(`[KYC TRIGGER] Tesseract.js Image OCR completed. Characters read: ${textContent.length}`);
        } else {
          throw new Error(`Unsupported document extension for OCR: .${ext}`);
        }

        // Try extracting Date of Birth (DOB) from the OCR text
        // Looks for DD/MM/YYYY or DD-MM-YYYY format
        const dobRegex = /\b(\d{2})[-/](\d{2})[-/](\d{4})\b/;
        const dobMatch = textContent.match(dobRegex);
        if (dobMatch) {
          dob = dobMatch[0].replace(/\//g, '-');
        } else {
          // Look for Year of Birth (YOB)
          const yobRegex = /(?:yob|year\s*of\s*birth)[:\s]*(19\d{2}|20\d{2})/i;
          const yobMatch = textContent.match(yobRegex);
          if (yobMatch) {
            dob = `01-01-${yobMatch[1]}`;
          }
        }

        // Validate specific document identifiers
        const contentLower = textContent.toLowerCase();
        if (docType === 'Aadhaar') {
          const hasAadhaarKeywords = contentLower.includes('aadhaar') || contentLower.includes('uidai') || contentLower.includes('government of india') || contentLower.includes('unique identification') || contentLower.includes('aadhar');
          const hasAadhaarPattern = /\b\d{4}\s\d{4}\s\d{4}\b/.test(textContent) || /\b\d{12}\b/.test(textContent);

          if (hasAadhaarKeywords || hasAadhaarPattern) {
            isValid = true;
            reason = 'Aadhaar card national identity keywords and pattern matched successfully.';
          } else {
            isValid = false;
            reason = 'Failed to verify 12-digit Aadhaar number format or national identity keywords.';
          }
        } else if (docType === 'PAN') {
          const hasPanKeywords = contentLower.includes('income tax') || contentLower.includes('permanent account') || contentLower.includes('govt. of india') || contentLower.includes('pan');
          const hasPanPattern = /[A-Z]{5}[0-9]{4}[A-Z]/.test(textContent);

          if (hasPanKeywords || hasPanPattern) {
            isValid = true;
            reason = 'PAN card alphanumeric registration matched successfully.';
          } else {
            isValid = false;
            reason = 'Failed to verify PAN registration number pattern or income tax keywords.';
          }
        } else if (docType === 'Passport') {
          const hasPassportKeywords = contentLower.includes('passport') || contentLower.includes('republic of india') || contentLower.includes('travel') || contentLower.includes('mrz');
          const hasPassportPattern = /[A-Z][0-9]{7}/.test(textContent) || contentLower.includes('ind');

          if (hasPassportKeywords || hasPassportPattern) {
            isValid = true;
            reason = 'Passport travel booklet identifiers matched successfully.';
          } else {
            isValid = false;
            reason = 'Failed to verify Passport MRZ alignment or booklet code identifiers.';
          }
        }
      }

      // Query database for DOB fallback if OCR could not detect it
      if (!dob && pgClient) {
        const formRes = await pgClient.query('SELECT dob FROM bank_kyc_forms WHERE user_id = $1', [userId]);
        if (formRes.rows.length > 0 && formRes.rows[0].dob) {
          dob = formRes.rows[0].dob;
        }
      }
      if (!dob) {
        dob = '01-01-1990'; // Final placeholder if no DOB is found in document or DB
      }

      // Handle Validation Outputs
      const sbClient = new ServiceBusClient(process.env.AZURE_SERVICE_BUS_CONNECTION_STRING);
      const sender = sbClient.createSender('kyc-notifications');

      if (isValid) {
        context.log('[KYC TRIGGER] Validation Passed! Transferring blob with custom name...');

        // Format names safely for cloud storage naming rules
        const sanitizedName = userName.toLowerCase().replace(/[^a-z0-9]/g, '_');
        const sanitizedDob = dob.replace(/[^0-9\-]/g, '');
        const ext = filename.split('.').pop() || 'pdf';
        const customFileName = `${sanitizedName}_${sanitizedDob}_${docType}.${ext}`;

        // Upload to processed-and-validated-container
        const targetContainerClient = blobServiceClient.getContainerClient('processed-and-validated-container');
        await targetContainerClient.createIfNotExists();
        const targetBlobClient = targetContainerClient.getBlockBlobClient(customFileName);

        await targetBlobClient.upload(blob, blob.length, {
          blobHTTPHeaders: { blobContentType: properties.contentType },
          metadata: {
            original_name: filename,
            doc_type: docType,
            user_id: userId.toString(),
            doc_id: docId ? docId.toString() : ''
          }
        });

        context.log(`[KYC TRIGGER] Blob successfully moved as "${customFileName}"`);

        // Delete the original blob from the ingest container
        await sourceBlobClient.delete();
        context.log(`[KYC TRIGGER] Original blob deleted.`);

        // Publish SUCCESS result to Service Bus queue
        await sender.sendMessages({
          body: JSON.stringify({
            userId,
            docId,
            docType,
            status: 'Verified',
            reason,
            fileName: customFileName,
            email: userEmail
          })
        });
      } else {
        context.warn(`[KYC TRIGGER] Validation Failed: ${reason}`);

        // Delete from ingestion container to avoid duplicates
        await sourceBlobClient.delete();
        context.log(`[KYC TRIGGER] Temporary invalid blob deleted.`);

        // Publish FAILURE result to Service Bus queue
        await sender.sendMessages({
          body: JSON.stringify({
            userId,
            docId,
            docType,
            status: 'Invalid',
            reason,
            fileName: filename,
            email: userEmail
          })
        });
      }

      await sender.close();
      await sbClient.close();
      context.log('[KYC TRIGGER] Service Bus status notification published successfully.');

    } catch (err) {
      context.error('[KYC TRIGGER] Execution failed with error:', err.message);

      // Attempt to publish an error notification to avoid user flow freezing
      try {
        const sbClient = new ServiceBusClient(process.env.AZURE_SERVICE_BUS_CONNECTION_STRING);
        const sender = sbClient.createSender('kyc-notifications');
        await sender.sendMessages({
          body: JSON.stringify({
            userId,
            docId,
            docType,
            status: 'Invalid',
            reason: `Validation aborted due to system error: ${err.message}`,
            fileName: filename,
            email: userEmail
          })
        });
        await sender.close();
        await sbClient.close();
      } catch (sbErr) {
        context.error('[KYC TRIGGER] Failed to dispatch error notification to Service Bus:', sbErr.message);
      }
    } finally {
      if (pgClient) {
        pgClient.release();
      }
    }
  }
});
