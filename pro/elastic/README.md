# OpenVidu Pro – Elastic Deployment on OCI

Deploys OpenVidu Pro in an elastic (autoscaling) topology on Oracle Cloud Infrastructure.

## Architecture

```
Internet
   │
   ▼
Master Node (fixed VM)          ← handles signaling, recording, dashboard
   │
   ├── Media Node 1 (pool)      ← WebRTC media processing
   ├── Media Node 2 (pool)      ← WebRTC media processing
   └── ...                      ← autoscaled between min/max
```

**Networking:** Single VCN (`10.0.0.0/16`) with one public subnet. Two NSGs enforce that internet traffic only reaches the ports each role needs, and cross-node traffic is restricted to the specific internal ports OpenVidu requires.

**Storage:** OCI Object Storage bucket (S3-compatible) used for recordings and app data. The bucket name is `<stackName>-appdata-<random hex suffix>` to avoid collisions between deployments. S3 credentials are generated at deploy time via a Customer Secret Key.

**Media node naming:** Instances spawned by the pool are named `<stackName>-media-pool-N` (OCI appends the sequence number automatically).

**Secrets:** OCI KMS Vault + AES-256 key for secrets management.

---

## Networking & Firewall

Each node runs **firewalld** (installed during bootstrap) as its host-level firewall. The VCN CIDR (`10.0.0.0/16`) is added to the `trusted` zone, allowing all intra-cluster traffic without enumerating every internal port — the NSGs already handle that at the OCI level. Only internet-facing ports are explicitly opened:

| Node | Ports |
|---|---|
| Master | TCP 22, 80, 443, 1935, 9000 |
| Media | TCP 22, 7881, 7880, 50000–60000 · UDP 443, 7885, 50000–60000 |

This is required because OCI instances run Ubuntu, which doesn't have firewalld pre-installed or pre-configured. Without it, the host `iptables` has an `INPUT DROP` policy that blocks intra-VCN traffic even when NSG rules allow it.

---

## Scale-out

Handled natively by `oci_autoscaling_auto_scaling_configuration`. When the pool's average CPU exceeds `scaleTargetCPU` (default 50%), OCI adds one media node. The `cool_down_in_seconds = 300` prevents oscillation.

---

## Scale-in — Graceful Drain (Two-Layer)

OCI's autoscaler terminates instances via an ACPI shutdown signal with a hard ~15-minute OS timeout enforced at the hypervisor. This is incompatible with meetings that last hours or days.

The solution bypasses OCI's timeout entirely by **owning scale-in from inside the instance** before OCI ever decides to terminate it.

### Layer 1 — Pre-drain Daemon (primary)

A systemd service (`openvidu-pre-drain`) runs on every media node from boot. It polls the OCI API every ~60 seconds and decides independently when to scale in. The daemon is configured at deploy time via `/etc/openvidu/predrain.conf` (baked in by Terraform user-data), which contains the compartment ID, pool display name (`<stackName>-media-pool`), minimum node count, and CPU threshold.

**Decision flow:**

```
Every ~60s:
  pool_size > MIN_NODES?  ──No──► reset streak, sleep
         │ Yes
  local_cpu < SCALE_IN_CPU_THRESHOLD?  ──No──► reset streak, sleep
         │ Yes
  idle_streak++ < REQUIRED_STREAK (3)?  ──Yes──► sleep (need sustained idle ~3min)
         │ No (3 consecutive idle checks)
  am I the oldest RUNNING instance?  ──No──► reset streak, sleep
         │ Yes
  sleep random 0–30s jitter
  re-verify all conditions  ──changed──► reset streak, sleep
         │ still valid
  ┌─────▼──────────────────────────────────────────────────────────┐
  │ 1. SIGQUIT → openvidu, ingress, egress, agents                 │
  │    (stops accepting new sessions while still registered)       │
  │ 2. detach-instance --is-decrement-size=true --auto-terminate=false │
  │    (pool target -1, no replacement, instance is now free)      │
  │ 3. wait indefinitely until all containers stop                 │
  │    (no OCI timeout — instance is outside the pool)             │
  │ 4. oci compute instance terminate (self-delete)                │
  └────────────────────────────────────────────────────────────────┘
```

**Why it works:** after step 2, the instance is detached from the pool. OCI has no reference to it and will never send an ACPI signal. The wait in step 3 is truly unbounded — hours, days, or indefinitely.

**Oldest-node selection** ensures only one node scales in at a time even if all nodes are idle simultaneously. The jitter + re-verify step prevents two nodes selecting themselves in the same polling window.

**Drain lock** (`/var/run/openvidu-drain.lock`) prevents a daemon restart during drain from starting a duplicate drain sequence.

### Layer 2 — Systemd Shutdown Service (fallback)

`openvidu-graceful-shutdown.service` runs at OS shutdown (`Before=shutdown.target`). It handles the narrow window where an external ACPI signal (e.g. manual `oci compute instance terminate`) arrives before the daemon has completed detach. It checks the drain lock to skip duplicate work.

`DefaultTimeoutStopSec=infinity` in `/etc/systemd/system.conf` removes systemd's global 90-second shutdown cap.

### IAM

The daemon authenticates via **Instance Principal** — no credentials stored on the instance. Two IAM resources are created:

- **Dynamic Group** — matches all instances in the compartment
- **Policy** — grants `manage instance-pools` (list + detach) and `manage instances` (list-instances + terminate) in the compartment

---

## Variables

| Variable | Default | Description |
|---|---|---|
| `minNumberOfMediaNodes` | 1 | Pool floor — daemon never scales below this |
| `maxNumberOfMediaNodes` | 5 | Pool ceiling for scale-out |
| `initialNumberOfMediaNodes` | 1 | Pool size at first deploy |
| `scaleTargetCPU` | 50 | CPU% threshold for both scale-out (OCI autoscaler) and scale-in (pre-drain daemon) |
| `masterNodeShape` | `VM.Standard.E4.Flex` | OCI shape for master node |
| `mediaNodeShape` | `VM.Standard.E4.Flex` | OCI shape for media nodes |
| `masterNodeDiskSize` | 100 | Master boot volume GB |
| `mediaNodeDiskSize` | 100 | Media boot volume GB |
| `certificateType` | `letsencrypt` | `selfsigned` / `owncert` / `letsencrypt` |
| `rtcEngine` | `pion` | `pion` or `mediasoup` |

---

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars
# fill in terraform.tfvars
terraform init
terraform apply
```
