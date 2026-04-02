/**
 * Authentication module for Google Sheets MCP Server
 * Supports multiple authentication methods:
 * 1. Service Account (via file or base64 config)
 * 2. OAuth2 Standard (with client ID/secret)
 * 3. OAuth2 Legacy (with credentials file)
 * 4. Application Default Credentials (ADC)
 */
/**
 * Authenticate with Google APIs using various methods
 * Priority order:
 * 1. CREDENTIALS_CONFIG (base64 encoded service account)
 * 2. SERVICE_ACCOUNT_PATH (service account file)
 * 3. GOOGLE_SHEETS_CLIENT_ID + GOOGLE_SHEETS_CLIENT_SECRET (OAuth2 standard)
 * 4. CREDENTIALS_PATH (OAuth2 legacy with credentials file)
 * 5. Application Default Credentials (ADC)
 */
export declare function authenticateGoogle(): Promise<any>;
//# sourceMappingURL=auth.d.ts.map