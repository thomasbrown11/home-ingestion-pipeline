# Filesystem-Based Media Ingestion Pipeline

## Overview

This project implements a deterministic, multi-stage ingestion pipeline for processing media datasets using only the filesystem as the source of truth.

It is designed to move data from an untrusted environment into a trusted storage system while enforcing:

- Validation and integrity checks
- Failure isolation
- Idempotent execution
- Cross-system traceability

The system avoids external orchestration (queues, databases) in favor of atomic filesystem operations and explicit state markers, resulting in a pipeline that is simple, auditable, and restart-safe.

---

## Core Concept

Each dataset is treated as a **transactional unit of work**, identified by a stable ID (derived from an upsteam-provided infohash).

The pipeline operates as a state machine, where:

- Each stage is idempotent
- Progress is recorded via .done markers and a .state file
- State transitions are represented by filesystem operations

---

## Architecture

The system is split across three layers with clearly defined responsibilities:

### 1. VM Layer (Untrusted Execution)

Handles:

Input from download completion hooks (post-download automation tools may rename/sort files before this stage)
Virus scanning (ClamAV)
Media validation (ffprobe / ffmpeg)
Metadata generation (manifest)
Initial staging into shared boundary

This layer performs all compute-heavy and trust-sensitive validation.

### 2. Host Layer (Controlled Promotion Boundary)

Handles:

Reading validated datasets from shared ingress (/ready)
Verifying readiness via manifest and completion markers
Promoting datasets into export space

This layer is intentionally minimal and acts as a controlled promotion step, not a processing engine.

### 3. NAS Layer (Trusted Storage)

Handles:

Pull-based ingestion from host export directory
Final storage and optional archival lifecycle management
Completion signaling (e.g., done markers or archive moves)

No system pushes directly into the NAS.

---

## Design Principle: Controlled Boundaries

Each layer only writes to explicit ingress points of the next layer:

- VM writes to /mnt/host/ready
- Host reads from /ready, writes to /export
- NAS pulls from /export

This ensures:

- Clear trust boundaries
- No implicit cross-system coupling
- Deterministic handoff behavior

---

## Pipeline Stages

The pipeline is composed of processing stages (VM) and transfer stages (cross-system).

### VM Processing (Pipeline-Controlled)

> ingest → scan → validate → manifest → stage

- **ingest**
	- Moves dataset into processing space and normalizes structure
(files are wrapped in directories; directories are preserved)
- **scan**
	- Runs ClamAV scan; failures are quarantined and terminate the pipeline
- **validate**
	- Verifies media integrity using ffprobe and ffmpeg
	- Filters out/quarantines junk files and preserves auxiliary files
- **manifest**
	- Generates a JSON manifest containing file SHA-256 hashes and metadata
- **stage**
	- Places validated dataset into shared boundary (/mnt/host/staging)

### VM Processing (Externally Controlled)

> stage → (external transform) → ready

- **transform (external)**
  - After staging, the dataset is processed by an external media management system
  - This system may:
    - rename files
    - restructure directories
    - relocate content into categorized paths (e.g. movies/shows)

  **Implications:**
  - File paths and names are no longer stable
  - Directory structure may change completely

  **Design response:**
  - The pipeline relies on:
    - transaction ID (infohash)
    - manifest (content hashes)
  - This ensures datasets remain identifiable across transformation
 
  - **Handoff contract:**
  - The external system performs a final move into:
    ```bash
    /mnt/host/ready
    ```
  - This move is treated as **atomic and authoritative**
  - The appearance of a dataset in this directory signals:
    - transformation is complete
    - dataset is stable and ready for promotion

  A systemd watcher on the host listens for `IN_MOVED_TO` events on this directory
  and triggers the next stage of the pipeline. This avoids the need for polling or partial-file detection on the host.

### Cross-System Transfer Stages

> promote → export → pull → finalize

- **promote (Host)**
	- Moves dataset from shared ingress (/ready) into export space
- **export (Host)**
	- Makes dataset available for downstream consumption
- **pull (NAS)**
	- NAS ingests dataset via pull-based model
- **finalize (NAS/Host)**
	- Dataset is archived, marked complete, or cleaned up

---

## Execution Model

### Trigger

The pipeline is initiated via a download completion hook:
```bash
ingestion-vm.sh "%N" "%F" "%I"
```
Where:

- `N` = name
-  `F` = path
-  `I` = infohash (used as transaction ID)

---

### Serialization

The pipeline runs as a **single-worker system** using:
```bash
flock
```
This guarantees:

- Only one dataset is processed at a time
- Jobs queue automatically at the OS level
- No race conditions between pipeline executions

---

### State Management

State is tracked using filesystem artifacts:

* `.done` files → stage completion
* `.state` file → current stage
* directory location → lifecycle state

This allows:

- Safe retries
- Crash recovery
- Deterministic execution

---

## 📁 Directory Layout (VM)

### VM View
- /home/tom/downloads/complete/     # download completion input
- /home/tom/processing/                        # active processing
- /home/tom/quarantine/                        # failed datasets
- /mnt/host/staging/                                 # intermediate workspace
- /mnt/host/ready/                                    # boundary to host
- /mnt/host/ready/registry/                     # manifests + state handling
- /home/tom/logs/                                    # VM logs

### Host View (via virtiofs)
- /mnt/vm-share/incoming/ready/         # maps from VM /mnt/host/ready
- /mnt/vm-share/export/                          # export directory for NAS
- /mnt/vm-share/finished/                       # optional archive/finalization
- /var/log/                                                   # host logs

Shared directories are mapped via virtiofs between VM and host.

---

## Logging

Logs are written locally on each system and correlated via transaction ID.

**VM:** /home/tom/logs/ingestion-vm.log
  
**Host:** /var/log/promotion.log

All stages emit **structured JSON logs (JSONL)**

Each entry includes:

- timestamp
- transaction ID
- stage
- action
- status
- source/destination paths
- message

Example:
```json
{
  "ts": "...",
  "tx": "...",
  "stage": "validate",
  "status": "passed",
  "msg": "validation passed"
}
```
This enables cross-system traceability without centralized logging.

---

## Safety & Failure Model

### Fail-Closed Design

- Any validation or scan failure:
  - dataset is quarantined
  - pipeline stops immediately

### Idempotency

- Each stage checks for `.done` markers
- Safe to re-run at any time
- Partial progress is preserved

### Atomic Operations

- Moves (`mv`) used as state transitions
- Manifest written via temp file > rename

---

## Design Tradeoffs

This system intentionally avoids:

- Message queues
- Databases
- Distributed schedulers

In favor of:

- Filesystem-driven state
- Simplicity of recovery
- Full observability via logs + artifacts

It is optimized for:

- Low throughput
- High reliability
- Clear failure boundaries

---

## Summary

This pipeline is a **reliable, restart-safe ingestion system** using only:

- Bash
- Filesystem primitives
- Standard Unix tools

Key characteristics:

- Deterministic execution model
- Explicit state transitions 
- strong trust boundary enforecement
- Fully auditable workflow

---

## Future Improvements

- Multi-worker queue model
- Retry/backoff strategy for transient failures
- Centralized log aggregation
- Metrics/alerting layer