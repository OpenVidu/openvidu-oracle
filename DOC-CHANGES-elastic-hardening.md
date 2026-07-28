# Documentation changes — Elastic Oracle hardening (`elastic-hardening`)

**Target docs repo / branch:** `openvidu.io`, branch `next`.
**Code scope of this branch:** `openvidu-oracle/pro/elastic/` only
(`tf-oracle-openvidu-elastic.tf`, `terraform.tfvars.example`). `pro/ha/` and
`pro/singlenode/` were not touched.

Docs affected (candidates): `docs/docs/self-hosting/elastic/oracle/*.md`
(`index.md`, `install.md`, `admin.md`, `upgrade.md`) and the shared snippets they
include.

---

## TL;DR

**No documentation edits are strictly required.** The hardening is entirely
internal (boot-time robustness + Master-Node secret-bootstrap consolidation). The
user-facing Terraform interface is unchanged, so the parameter tables and the
output description remain correct as written. Two **optional** additions are
proposed below (Items 2 and 3).

## Public interface: unchanged (important)

- **`variables.tf`**: no variable added, removed, renamed, or re-defaulted. The
  "Mandatory Parameters" and "Optional Parameters" tables in `install.md` need
  **no** change.
- **`output.tf`**: unchanged. The `openvidu_credentials` output and its doc
  references are still accurate.

## What changed in the code (context only — not doc copy)

- A per-deployment generation token is injected into every node via IMDS
  metadata. Media Nodes now trust only secrets stamped with their own token, so a
  re-used (recycled) OCI Vault can no longer feed a Media Node stale
  previous-deployment secrets.
- Master-Node secret generation is consolidated into a single
  `bootstrap_secrets.py` process (one Instance-Principal session) instead of
  ~20 serial `store_secret.sh` invocations that each spawned the OCI CLI. The 4
  URL secrets (`OPENVIDU_URL`, `LIVEKIT_URL`, `DASHBOARD_URL`, `GRAFANA_URL`) are
  produced there too.
- Every boot-time wait is now **bounded** and fails with a clear message instead
  of looping forever: Media-Node wait-for-secrets (30 min) and Master-Node
  app-readiness (20 min). `apt`/`pipx` bootstrap and the installer download now
  retry with backoff, and the installer is fetched to a file and size-checked
  before running.
- `terraform.tfvars.example`'s `scale_in_function_image` placeholder was aligned
  with the shared docs snippet (see Item 1).

---

## Item 1 — `scale_in_function_image` placeholder (consistency; no doc edit needed)

`pro/elastic/terraform.tfvars.example` previously showed:

```hcl
scale_in_function_image = "mad.ocir.io/<your-namespace>/openvidu-oci-scalein:main"
```

It now shows:

```hcl
scale_in_function_image = "<region-key>.ocir.io/<your-tenancy-namespace>/openvidu-oci-scalein:main"
```

This matches the already-updated shared snippet
`shared/self-hosting/oracle/scalein-function-image.md`, which consistently uses
the `<region-key>.ocir.io/<your-tenancy-namespace>/…` form. This closes an
example-vs-docs inconsistency. **No docs file needs editing** for this; the note
simply records that the example is now aligned with the published instructions.

## Item 2 (optional) — add a "time to ready" figure

There is currently **no** time/duration figure anywhere in the elastic Oracle
docs. The secret-bootstrap consolidation is expected to **materially reduce**
Master-Node ready time (fewer OCI CLI cold starts and Vault round-trips).

Recommendation: measure before/after with `ov-cloud-tester` and, only once a real
number exists, add a single sentence to `install.md` (near step 4 or the "Access
OpenVidu" section), e.g. "The Master Node is typically ready in about N seconds".
Baseline reference for the current code is ≈583 s to ready. Do **not** add a
figure until it is measured.

## Item 3 (optional) — troubleshooting note about the bounded gates

`install.md` includes `shared/self-hosting/oracle/troubleshooting.md`, which
already tells users to inspect `/var/log/cloud-init-output.log`. With this
hardening, failures now surface as **terminal, greppable errors** instead of an
eternal wait:

- Media Node that never receives the Master's secrets:
  `Timeout waiting for ALL_SECRETS_GENERATED=<token> after 30 min`
- Master Node whose app never becomes healthy:
  `[check_app_ready] OpenVidu health endpoint not ready after 20 min`

An optional one-line addition to the troubleshooting snippet could point readers
at these messages.

**Caveat:** that snippet is **shared** by the single-node, elastic and HA Oracle
docs. Edit it only if the note should apply to all three. The wording above is
accurate for elastic and HA (HA already has the bounded gates); verify single-node
behavior before making the change snippet-wide, or add the note inline in
`elastic/oracle/install.md` instead of in the shared file.

---

## Summary

| Doc                                   | Change required |
|---------------------------------------|-----------------|
| `elastic/oracle/index.md`             | None |
| `elastic/oracle/install.md`           | None required; optional Items 2 & 3 |
| `elastic/oracle/admin.md`             | None |
| `elastic/oracle/upgrade.md`           | None |
| `shared/.../scalein-function-image.md`| None (already correct; Item 1 aligns the example to it) |
| Parameter tables / outputs            | None (public interface unchanged) |
