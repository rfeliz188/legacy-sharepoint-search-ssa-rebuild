<#
.SYNOPSIS
  SharePoint 2010 - Search Service Application (SSA) Recovery / Rebuild Script (Legacy - 2015)

.DESCRIPTION
  This script automates the creation of a SharePoint 2010 Search Service Application (SSA) and
  rebuilds the Search topology components (Administration, Crawl, Query) in a controlled way.

  High-level flow:
    1) Start required Search service instances
    2) Create the Search Service Application (SSA)
    3) Bind the Administration Component
    4) Create and activate a new Crawl Topology + Crawl Component
    5) Safely remove the old Crawl Topology (only after it becomes inactive)
    6) Create and activate a new Query Topology + Query Component
    7) Bind Property Database to the Index Partition
    8) Safely remove the old Query Topology (optional; shown as pattern)
    9) Create the SSA Proxy (so Web Apps can consume the SSA)

.NOTES
  - Environment details must be customized: server names, app pool, DB server, SSA name.
  - For educational purposes: identifiers are generalized and must be adapted for your farm.
  - Requires SharePoint 2010 Management Shell (or Microsoft.SharePoint.PowerShell) on a farm server.

#>

# -----------------------------
# 0) VARIABLES (EDIT THESE)
# -----------------------------

# Target server hosting Search components (use actual server name for your farm)
$searchServerName   = "SP-SEARCH-01"

# Name for the new Search Service Application
$searchSAName       = "Search Service Application"

# Application Pool name for the SSA (must exist or you must create it before running)
$saAppPoolName      = "SharePoint Search App Pool"

# SQL Server name hosting the Search DBs
$databaseServerName = "SQL-01"

# Optional: DB name for SSA (you can standardize naming conventions here)
$searchDBName       = "SearchDB"

# Sleep interval for polling old topologies
$pollSeconds        = 6


# -----------------------------
# 1) PRE-CHECKS
# -----------------------------

Write-Host "=== SharePoint 2010 Search SSA Recovery Script ===" -ForegroundColor Cyan
Write-Host "Target Search Server : $searchServerName"
Write-Host "SSA Name             : $searchSAName"
Write-Host "App Pool             : $saAppPoolName"
Write-Host "DB Server            : $databaseServerName"
Write-Host "DB Name              : $searchDBName"
Write-Host ""

# Ensure SharePoint PowerShell snap-in is loaded
if (-not (Get-PSSnapin -Name Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue)) {
    try {
        Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction Stop
        Write-Host "Loaded Microsoft.SharePoint.PowerShell snap-in." -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: Unable to load Microsoft.SharePoint.PowerShell snap-in. Run in SharePoint 2010 Management Shell." -ForegroundColor Red
        throw
    }
}

# -----------------------------
# 2) START SEARCH SERVICES
# -----------------------------
# Why: Search components won't provision properly if service instances are stopped.

Write-Host "`n[1/6] Starting Search services on $searchServerName..." -ForegroundColor Yellow

Start-SPEnterpriseSearchServiceInstance $searchServerName
Start-SPEnterpriseSearchQueryAndSiteSettingsServiceInstance $searchServerName

Write-Host "Search service instances started (or already running)." -ForegroundColor Green


# -----------------------------
# 3) CREATE SEARCH SERVICE APPLICATION (SSA)
# -----------------------------
# Why: We need a clean SSA object tied to a known app pool and DB configuration.
# Note: If an SSA with same name exists, this will fail. In legacy recovery scenarios,
# you may rename the old SSA or remove it (carefully) before recreating.

Write-Host "`n[2/6] Creating Search Service Application (SSA)..." -ForegroundColor Yellow

$searchApp = New-SPEnterpriseSearchServiceApplication `
    -Name $searchSAName `
    -ApplicationPool $saAppPoolName `
    -DatabaseServer $databaseServerName `
    -DatabaseName $searchDBName

# Get the service instance for component binding
$searchInstance = Get-SPEnterpriseSearchServiceInstance $searchServerName

Write-Host "SSA created: $searchSAName" -ForegroundColor Green


# -----------------------------
# 4) CREATE / BIND ADMINISTRATION COMPONENT
# -----------------------------
# Why: Admin Component orchestrates the SSA topology. If it's broken, Search health degrades
# and many operations fail (crawls, query pipeline, topology changes).

Write-Host "`n[3/6] Binding Administration Component..." -ForegroundColor Yellow

$searchApp |
    Get-SPEnterpriseSearchAdministrationComponent |
    Set-SPEnterpriseSearchAdministrationComponent -SearchServiceInstance $searchInstance

Write-Host "Administration Component configured." -ForegroundColor Green


# -----------------------------
# 5) REBUILD CRAWL TOPOLOGY (SAFE TRANSITION)
# -----------------------------
# Why: Crawl component controls content ingestion and feeding the index.
# Pattern: Create new topology -> add component -> activate -> wait old becomes inactive -> remove old.
# This avoids topology corruption during transitions.

Write-Host "`n[4/6] Rebuilding Crawl Topology..." -ForegroundColor Yellow

# Capture the currently active crawl topology (if any)
$InitialCrawlTopology = $searchApp | Get-SPEnterpriseSearchCrawlTopology -Active -ErrorAction SilentlyContinue

# Create a new crawl topology
$CrawlTopology = $searchApp | New-SPEnterpriseSearchCrawlTopology

# Get the first crawl database associated with SSA
$CrawlDatabase = ([array]($searchApp | Get-SPEnterpriseSearchCrawlDatabase))[0]

# Create a new crawl component on the target server instance
$CrawlComponent = New-SPEnterpriseSearchCrawlComponent `
    -CrawlTopology $CrawlTopology `
    -CrawlDatabase $CrawlDatabase `
    -SearchServiceInstance $searchInstance

# Activate the new crawl topology
$CrawlTopology | Set-SPEnterpriseSearchCrawlTopology -Active

Write-Host "New Crawl Topology activated." -ForegroundColor Green

# If there was an old active topology, remove it only once it becomes inactive
if ($InitialCrawlTopology) {
    Write-Host "Waiting for old Crawl Topology to become inactive..." -ForegroundColor White -NoNewline
    do {
        Write-Host -NoNewline "."
        Start-Sleep $pollSeconds
        # Refresh object state (best effort)
        $InitialCrawlTopology = $searchApp | Get-SPEnterpriseSearchCrawlTopology | Where-Object { $_.Id -eq $InitialCrawlTopology.Id }
    } while ($InitialCrawlTopology.State -ne "Inactive")

    Write-Host ""
    $InitialCrawlTopology | Remove-SPEnterpriseSearchCrawlTopology -Confirm:$false
    Write-Host "Old Crawl Topology removed." -ForegroundColor Green
}


# -----------------------------
# 6) REBUILD QUERY TOPOLOGY (SAFE TRANSITION)
# -----------------------------
# Why: Query component powers search queries.
# We create a new Query Topology and Query Component, bind IndexPartition to Property DB,
# activate the new topology, and (optionally) remove the old one.

Write-Host "`n[5/6] Rebuilding Query Topology..." -ForegroundColor Yellow

# Capture currently active query topology (if any)
$InitialQueryTopology = $searchApp | Get-SPEnterpriseSearchQueryTopology -Active -ErrorAction SilentlyContinue

# Create a new query topology (Partitions = 1 is typical for smaller farms; adjust if needed)
$QueryTopology = $searchApp | New-SPEnterpriseSearchQueryTopology -Partitions 1

# Get index partition for that query topology
$IndexPartition = Get-SPEnterpriseSearchIndexPartition -QueryTopology $QueryTopology

# Create query component on the target server instance
$QueryComponent = New-SPEnterpriseSearchQueryComponent `
    -QueryTopology $QueryTopology `
    -IndexPartition $IndexPartition `
    -SearchServiceInstance $searchInstance

# Bind property database to index partition (important for result metadata)
$PropertyDatabase = ([array]($searchApp | Get-SPEnterpriseSearchPropertyDatabase))[0]
$IndexPartition | Set-SPEnterpriseSearchIndexPartition -PropertyDatabase $PropertyDatabase

# Activate new query topology
$QueryTopology | Set-SPEnterpriseSearchQueryTopology -Active
Write-Host "New Query Topology activated." -ForegroundColor Green

# Optional: Remove old query topology using same safe pattern (only if it exists)
if ($InitialQueryTopology) {
    Write-Host "Waiting for old Query Topology to become inactive..." -ForegroundColor White -NoNewline
    do {
        Write-Host -NoNewline "."
        Start-Sleep $pollSeconds
        # Refresh object state (best effort)
        $InitialQueryTopology = $searchApp | Get-SPEnterpriseSearchQueryTopology | Where-Object { $_.Id -eq $InitialQueryTopology.Id }
    } while ($InitialQueryTopology.State -ne "Inactive")

    Write-Host ""
    $InitialQueryTopology | Remove-SPEnterpriseSearchQueryTopology -Confirm:$false
    Write-Host "Old Query Topology removed." -ForegroundColor Green
}


# -----------------------------
# 7) CREATE SSA PROXY
# -----------------------------
# Why: Without the Service Application Proxy, web applications won't be able to consume Search.

Write-Host "`n[6/6] Creating Search Service Application Proxy..." -ForegroundColor Yellow

$searchAppProxy = New-SPEnterpriseSearchServiceApplicationProxy `
    -Name "$searchSAName Proxy" `
    -SearchApplication $searchSAName > $null

Write-Host "SSA Proxy created successfully." -ForegroundColor Green


# -----------------------------
# 8) POST-RUN VALIDATION (GUIDANCE)
# -----------------------------
Write-Host "`n=== Next Steps / Validation Checklist ===" -ForegroundColor Cyan
Write-Host "1) In Central Admin: verify SSA status is Healthy."
Write-Host "2) Validate that Crawl + Query components show as Active."
Write-Host "3) Run a test crawl and confirm content is indexed."
Write-Host "4) Execute a user search query and confirm results return."
Write-Host "5) Review ULS logs for any Search topology errors."
Write-Host "`nDone." -ForegroundColor Cyan
