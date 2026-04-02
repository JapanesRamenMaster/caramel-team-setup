#!/usr/bin/env node
/**
 * Google Spreadsheet MCP Server
 * A Model Context Protocol (MCP) server for interacting with Google Sheets
 */
import { sheets_v4, drive_v3 } from 'googleapis';
/**
 * Get the initialized services
 */
export declare function getServices(): {
    sheetsService: sheets_v4.Sheets;
    driveService: drive_v3.Drive;
    folderIdContext: string | undefined;
};
//# sourceMappingURL=index.d.ts.map