# legacy-sharepoint-search-ssa-rebuild

# SharePoint 2010 Search Recovery (Legacy | 2015)

**Problem:** Enterprise SharePoint 2010 portal had **broken Search** (user queries failed / SSA degraded).  
**Solution:** Built a **PowerShell recovery script** to **recreate the Search Service Application (SSA)** and rebuild **Admin + Crawl + Query** components safely.

## What I Delivered
- ✅ Restarted and stabilized Search services
- ✅ Rebuilt SSA + topology (Admin/Crawl/Query) in a controlled way
- ✅ Prevented corruption by **activating new topology → waiting inactive → removing old**
- ✅ Created the SSA Proxy so web apps could use Search again
- ✅ Documented a repeatable recovery/runbook for future incidents

## Result
- 🔎 Search queries worked again
- ⏱ Faster recovery during future outages (repeatable procedure vs manual troubleshooting)

## Tech
PowerShell | SharePoint Server 2010 | Search Service Application (SSA) | Crawl/Query Topology

> Note: Shared for learning. Environment details are anonymized.
