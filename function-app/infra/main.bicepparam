using './main.bicep'

// Replace these placeholder values before deploying
param parEnvironment = 'prod'
param parUniqueSuffix = 'a3f9'  // Change to a unique 4-6 char suffix

// Daily at 06:00 UTC — 6-field NCRONTAB: {sec} {min} {hr} {dom} {mon} {dow}
param parTimerSchedule = '0 0 6 * * *'

// KQL must be single-line (no newlines). Adjust to your Defender XDR schema.
param parKqlQuery = 'DeviceEvents | where Timestamp > ago(1d) | project DeviceName, ActionType, InitiatingProcessFileName, Timestamp | limit 1000'

// Obtain from: GET https://graph.microsoft.com/v1.0/sites?$search="your-site-name"
param parSharePointSiteId = '<tenant>.sharepoint.com,<site-guid>,<web-guid>'

// Obtain from: GET https://graph.microsoft.com/v1.0/sites/{siteId}/drives
param parSharePointDriveId = '<drive-guid>'

// Use 'root' for the document library root, or an item GUID for a subfolder
param parSharePointParentFolderId = 'root'
