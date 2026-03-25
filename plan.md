# 2026-03-25

## Finished
* Wrote `ai_infra_projects/kserve/cluster.sh` — create/delete script for GKE cluster `kserve-study` (3x e2-standard-4, us-central1-a, Gateway API enabled).
* Wrote `ai_infra_projects/kserve/install.sh` — installs cert-manager v1.17.2 + KServe v0.17.0 (Standard Mode, Gateway API). Filters out GKE-managed inference.networking CRDs to avoid conflicts.
* Wrote `ai_infra_projects/kserve/README.md` — session workflow and gotchas.
* Created GKE cluster `kserve-study` and installed KServe. All 3 controller pods Running.

## TODO
* ~~Run `bash cluster.sh create` to spin up the cluster~~ (resolved 2026-03-25)
* ~~Install KServe on the cluster (Week 1 Friday hands-on)~~ (resolved 2026-03-25)
* Delete cluster at end of session: `bash cluster.sh delete`

# 2026-03-24

## Finished
* Set up GCP billing account and linked it to project `ai-infra-lab-86222`.
* Created a $50/month budget alert with 50%/90%/100% threshold notifications.
* Set up automatic billing disablement when budget is reached: created Pub/Sub topic `billing-alert-topic`, linked it to the budget, deployed a Cloud Function (`disable-billing`) in `us-central1`, and granted `roles/billing.projectManager` to the function's service account.
### TODO
* Write script to create and delete cluster
* Check if I can create cluster after writing all deployment yalms for first two week project
* Also why need e2-standard-4 nodes?

## TODO
* Proceed with GKE cluster creation for Week 1 hands-on (KServe install).

# 2026-03-23

## Finished
* Created CLAUDE.md at project root (/Users/Sophie/ObsidianVault/AI-Infra-Study/CLAUDE.md) with an instruction to auto-read plan.md at the start of every conversation.
* Connected GKE MCP server (`gke-mcp` v0.10.0) to Claude Code. Binary at `/Users/Sophie/go/bin/gke-mcp`. Authenticated via `gcloud auth application-default login`.
* Initialized git repository for `ai_infra_projects/` folder with `plan.md` as the initial commit on branch `master`.
* Updated CLAUDE.md with plan.md read/write instructions: summarize top 3 date entries on session start, log completed tasks under today's Finished section.
* Converted study plan to markdown: `pandoc study_plan.docs -t markdown`
* Started Week 1 hands-on project (KServe Architecture & First Deploy).
* Created GCP project `ai-infra-lab-86222` for study work. Billing setup pending.

## TODO
* ~~Set up billing for GCP project `ai-infra-lab-86222` to proceed with GKE cluster creation.~~ (resolved 2026-03-24)
# 2026-03-21

## Finished
* I think I added gke mcp server on claude. Need to confirm. (confirmed 2026-03-23)
## TODO
* ~~Somehow let claude always read this file before working on projects.~~ (resolved 2026-03-23)

