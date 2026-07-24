# Documentation changes for `ha-optimizations` (Oracle Cloud HA)

This README lists the documentation edits that must be applied in the
**`openvidu.io`** repository (branch **`next`**) as a consequence of the
`ha-optimizations` changes made in `openvidu-oracle` (`pro/ha/` and
`pro/scalein-function/`).

All paths below are relative to the root of the `openvidu.io` repository.

> **TL;DR** — No public Terraform parameter, output, or default changed, so the
> parameter tables need no edits. The only doc-relevant changes are: (1) the
> scale-in image tag/namespace/build procedure in the shared snippet, and
> (2) an optional deployment-time note. Everything else about the HA deployment
> the docs describe (topology, scale-in lock, credentials, NLB entry point)
> remains accurate.

---

## 0. Context: what changed in the Terraform repo

The `ha-optimizations` branch of `openvidu-oracle` applied internal (non-user-facing)
optimizations to `pro/ha/tf-oracle-openvidu-ha.tf`:

- Master #1 now generates the ~20 cluster secrets in **one Python process**
  (`bootstrap_secrets.py`) instead of ~20 `store_secret.sh` CLI invocations.
- The Master Nodes no longer depend on the Network Load Balancer at Terraform
  time; master #1 resolves the NLB public IP **at runtime** (only when
  `domainName` is empty). This requires one new IAM statement
  (`read network-load-balancers`) added to the existing instances policy.
- Deduplicated `apt`/`pipx` retry blocks, bounded previously-infinite polls, and
  a more robust installer download.
- Repo hygiene: `pro/scalein-function/build-and-push.sh` is no longer git-ignored,
  and the scale-in image tag was unified to `main`.

**None of these are visible in the deployment's public interface** (no variable,
default, or output changed). The consequences for the docs are limited to the two
items below.

---

## 1. Scale-in function image — snippet `shared/self-hosting/oracle/scalein-function-image.md`

### 1.1 Findings (repo vs docs mismatch)

| Item | Terraform repo (after `ha-optimizations`) | Doc snippet (current) |
|------|-------------------------------------------|-----------------------|
| Image **tag** | `main` (in `build-and-push.sh` default and `terraform.tfvars.example`) | `3.8.0` (all four code blocks + the Madrid shortcut) |
| **Repository** name | `openvidu-oci-scalein` | `openvidu-oci-scalein` in Option 1, but **`scale-in-function`** in Option 2 |
| **Build procedure** | `pro/scalein-function/build-and-push.sh` (now tracked; runs a security scan then builds + pushes) | Option 2 uses a **raw `docker build`** and never mentions `build-and-push.sh` |
| Namespace **placeholder** | `<your-tenancy-namespace>` | `<tenancy-namespace>` |

So there are three genuine inconsistencies to reconcile: the **build command in
Option 2**, the **repository name in Option 2**, and the **image tag**.

### 1.2 Edit — Option 2 should use `build-and-push.sh` (build-from-source path)

`build-and-push.sh` is now tracked in the repo specifically so users can build the
image. Option 2 ("Build the image from source") should use it instead of a raw
`docker build`, and use the correct repository name `openvidu-oci-scalein`.

In `shared/self-hosting/oracle/scalein-function-image.md`, **Option 2, step 3**,
replace:

~~~markdown
    3. Build and tag the image. The tag must follow the format `<region-key>.ocir.io/<tenancy-namespace>/<repo>:<tag>`:

        ```bash
        docker build -t <region-key>.ocir.io/<tenancy-namespace>/scale-in-function:<tag> .
        ```
~~~

with:

~~~markdown
    3. Build, security-check and push the image with the helper script. Pass the
       full image reference as its argument; it must follow the format
       `<region-key>.ocir.io/<tenancy-namespace>/openvidu-oci-scalein:<tag>`:

        ```bash
        ./build-and-push.sh <region-key>.ocir.io/<tenancy-namespace>/openvidu-oci-scalein:main
        ```
~~~

Then **Option 2, step 4** (the separate `docker push`) becomes redundant because
`build-and-push.sh` already pushes. Replace:

~~~markdown
    4. Push the image to OCIR:

        ```bash
        docker push <region-key>.ocir.io/<tenancy-namespace>/scale-in-function:<tag>
        ```
~~~

with:

~~~markdown
    4. `build-and-push.sh` builds, scans and pushes in one step, so there is no
       separate push command. If the security scan fails, the image is **not**
       pushed — fix the reported issue and re-run.
~~~

And **Option 2, step 5** (set the parameter), replace:

~~~markdown
        ```hcl
        scale_in_function_image = "<region-key>.ocir.io/<tenancy-namespace>/scale-in-function:<tag>"
        ```
~~~

with:

~~~markdown
        ```hcl
        scale_in_function_image = "<region-key>.ocir.io/<tenancy-namespace>/openvidu-oci-scalein:main"
        ```
~~~

### 1.3 Decision required — image tag `main` vs `3.8.0`

The repo now standardizes on the tag **`main`** for the build helper's default and
for `terraform.tfvars.example`. The docs currently use the pinned release tag
**`3.8.0`** everywhere (Option 1 pulls `docker.io/openvidu/openvidu-oci-scalein:3.8.0`,
the Madrid shortcut points to `mad.ocir.io/axp2ice0s7el/openvidu-oci-scalein:3.8.0`,
and `install.md` step 1 does `git -C openvidu-oracle checkout 3.8.0`).

`main` is a **rolling branch default**, not a release tag. This is a
release/versioning decision the maintainers must make — do **not** blindly rewrite
`3.8.0` → `main` in the docs, because:

- The docs pin the clone with `git checkout 3.8.0` (`install.md` line ~61). The
  `ha-optimizations` changes are **not** in the `3.8.0` tag; they will ship in a
  future release tag `X.Y.Z`.
- Option 1 and the Madrid shortcut pull a **published** image
  (`docker.io/openvidu/openvidu-oci-scalein:3.8.0`,
  `mad.ocir.io/axp2ice0s7el/openvidu-oci-scalein:3.8.0`). Those references are only
  valid if OpenVidu actually publishes that tag.

**Recommended reconciliation (to apply when these changes are released as `X.Y.Z`):**

1. Bump `git -C openvidu-oracle checkout 3.8.0` → `git -C openvidu-oracle checkout X.Y.Z`
   in `docs/docs/self-hosting/ha/oracle/install.md` (step 1, code block after line ~59).
2. Bump every `3.8.0` in `shared/self-hosting/oracle/scalein-function-image.md`
   (Option 1 pull/tag/push/param at lines ~17, ~33, ~39, ~45, and the Madrid
   shortcut at line ~6) to the same `X.Y.Z`, **provided** OpenVidu publishes
   `docker.io/openvidu/openvidu-oci-scalein:X.Y.Z` and
   `mad.ocir.io/axp2ice0s7el/openvidu-oci-scalein:X.Y.Z`.
3. In the same release, bump the repo's `pro/scalein-function/build-and-push.sh`
   default and `pro/ha/terraform.tfvars.example` from `main` to `X.Y.Z` so the
   build-from-source path matches the published release.

If instead the maintainers want a permanent rolling `main` image, they must first
publish `docker.io/openvidu/openvidu-oci-scalein:main` (and the Madrid mirror),
then change the Option 1 / Madrid-shortcut tags to `main`.

Until that decision is made, the safe state is: **Option 2 (build-from-source) uses
`main`** (matching `build-and-push.sh`), while **Option 1 / Madrid shortcut keep the
published release tag `3.8.0`**. The two paths legitimately differ (source HEAD vs
pinned release); a one-line note in the snippet can make that explicit if desired.

### 1.4 Optional — placeholder wording consistency

The repo uses `<your-tenancy-namespace>`; the snippet uses `<tenancy-namespace>`.
Low priority. If unifying, prefer `<your-tenancy-namespace>` in the snippet for
consistency with `build-and-push.sh` and `terraform.tfvars.example`.

---

## 2. Deployment-time note (optional) — `docs/docs/self-hosting/ha/oracle/install.md`

The Oracle HA docs do **not** publish a deployment-time figure. The natural place
to add one (optional) is **step 4** of "Deployment details" (the "Wait for it to
finish and display `Apply Complete!`" step, currently line ~242).

Suggested insertion right after that sentence, using a placeholder to be filled
with a real measurement from `ov-cloud-tester`:

~~~markdown
    !!! note
        A full HA deployment (4 Master Nodes + the Media Node pool forming the
        cluster) typically completes in about **X to Y minutes** — rellenar con
        medición de ov-cloud-tester.
~~~

> Replace `X to Y minutes — rellenar con medición de ov-cloud-tester` with the
> measured range before publishing. Do **not** publish the placeholder text.

If a figure is added, note that the `ha-optimizations` changes are expected to
*reduce* startup time (the NLB now provisions in parallel with the Master Nodes
instead of blocking them, and master #1 generates secrets in one process), so any
previously-measured figure should be re-measured on the optimized branch.

---

## 3. Public parameters — no change

Confirmed: the `ha-optimizations` branch changed **no** input variable (name,
type, default, validation) and **no** output.

- `scale_in_function_image`, `domainName`, `initialMeetAdminPassword`,
  `initialMeetApiKey`, `fixedNumberOfMediaNodes`, and all sizing/autoscaling
  variables are unchanged.
- `pro/ha/output.tf` is unchanged.
- The only edit to `pro/ha/terraform.tfvars.example` is the **example value** of
  `scale_in_function_image` (`mad.ocir.io/<your-namespace>/…:main` →
  `<region-key>.ocir.io/<your-tenancy-namespace>/…:main`), i.e. a placeholder, not
  a parameter contract.

Therefore the parameter tables in `install.md` (mandatory + optional) need **no
edits**.

---

## 4. Claims that are still accurate (no change needed)

Re-checked against the code; these doc statements remain correct:

- **Topology** (`install.md` §"Deployment details"): 4 fixed Master Nodes + Media
  Node Instance Pool. Unchanged.
- **Custom scale-in strategy** (`install.md` lines ~47–51): OCI Function on a
  schedule, `scalein.lock` ETag CAS with 3-minute TTL, per-node draining daemon.
  Unchanged.
- **NLB as the entry point / per-master public IPs are SSH-only**
  (`install.md` line ~277). Unchanged — the NLB is still the user-facing entry
  point; only *how the masters learn the NLB IP* changed (now at runtime, an
  internal detail).
- **Credentials in OCI Vault / on the instance** (`install.md` §"Access OpenVidu"):
  secret names (`OPENVIDU_URL`, `MEET_INITIAL_ADMIN_PASSWORD`, …) are unchanged —
  the Python generator writes the exact same secret names and formats as the old
  `store_secret.sh` flow.
- `admin.md` and `upgrade.md`: no references to any changed behavior.

The internal mechanisms that changed (single-process secret generation, runtime
NLB IP resolution, `store_secret.sh` still used by the other flows) are **not**
described in the public docs, so they require no documentation edits.
