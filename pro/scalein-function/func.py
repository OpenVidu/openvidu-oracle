"""OpenVidu scale-in OCI Function.

Two execution modes, picked from the request body:

* **Terminate** — Called by a media node after its graceful drain finishes.
  The node POSTs a JSON body with key `terminate_instance_id` and the function
  uses Resource Principal auth to call TerminateInstance (which the node
  itself cannot do, because instance_principal is denied that operation at
  tenancy level).

* **Scale-in eval** — Called every 5 min by the master's cron with an empty
  body. The function checks pool-wide CPU and, if it's below threshold and
  the pool is above MIN_NODES, detaches the oldest member to start the
  drain/self-terminate sequence.

Environment variables (set on the Function Application by Terraform):
    COMPARTMENT_ID    — OCI compartment OCID
    POOL_DISPLAY_NAME — display name of the media node instance pool
    MIN_NODES         — minimum pool size; scale-in stops here
    CPU_THRESHOLD     — pool-wide avg CPU below which scale-in triggers
"""

import io
import json
import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Optional

import oci
from fdk import response

logger = logging.getLogger()

# How long a freshly spawned node is exempt from scale-in checks. Without this,
# the new node's cold CPU pulls the pool average below threshold and triggers
# an immediate scale-in of someone else.
GRACE_MINUTES = 7


def handler(ctx, data: io.BytesIO = None):
    """Entry point: parse the body and dispatch to terminate or scale-in eval."""
    signer = oci.auth.signers.get_resource_principals_signer()
    body = _parse_body(data)
    if "terminate_instance_id" in body:
        return _handle_terminate(ctx, signer, body["terminate_instance_id"])
    return _evaluate_scale_in(ctx, signer)


def _parse_body(data) -> dict:
    """Read the request body (whatever shape FDK hands us) and parse as JSON.

    FDK has historically passed `data` as either `io.BytesIO` or raw bytes
    depending on version; handle both. Body-routing bugs here previously
    sent the wrong branch the call, so we log liberally.
    """
    logger.info("handler invoked: data type=%s, repr=%r", type(data).__name__, data)
    if data is None:
        return {}
    try:
        if hasattr(data, "read"):
            raw = data.read()
        elif isinstance(data, (bytes, bytearray)):
            raw = bytes(data)
        else:
            raw = b""
        logger.info("raw body (%d bytes): %r", len(raw), raw)
        if not raw:
            return {}
        body = json.loads(raw)
        logger.info("parsed body: %r", body)
        return body
    except Exception as exc:
        logger.warning("body parse failed (%s: %s)", type(exc).__name__, exc)
        return {}


def _handle_terminate(ctx, signer, instance_id: str):
    """Terminate an instance on behalf of a draining media node.

    Identity model — a node may ONLY ask to terminate itself.
    OCI Functions injects the authenticated caller's identity into the
    request headers AFTER signature validation:
        oci-subject-type  = "instance" | "user" | "service" | ...
        oci-subject-id    = OCID of the calling principal
    For Instance Principal callers these are the instance's own OCID. They
    cannot be spoofed by the caller — the OCI service overwrites them.
    We refuse anything that doesn't match the body's terminate_instance_id.

    Resource Principal auth on the actual TerminateInstance call (the
    function's own identity) is still needed to bypass the tenancy-level
    deny policy that blocks instance_principal from terminating compute.
    """
    headers     = {k.lower(): v for k, v in (ctx.Headers() or {}).items()}
    caller_id   = headers.get("oci-subject-id", "")
    caller_type = headers.get("oci-subject-type", "")

    if caller_type != "instance":
        logger.warning(
            "Refusing terminate: caller is not an instance (type=%r, id=%r).",
            caller_type, caller_id,
        )
        return _refused(ctx, f"caller_not_instance:{caller_type or 'unknown'}", instance_id)

    if caller_id != instance_id:
        logger.warning(
            "Refusing terminate: caller %s tried to terminate %s.",
            caller_id, instance_id,
        )
        return _refused(ctx, "caller_target_mismatch", instance_id)

    logger.info("Authorized self-terminate for instance: %s", instance_id)
    compute = oci.core.ComputeClient(config={}, signer=signer)
    compute.terminate_instance(instance_id, preserve_boot_volume=False)
    logger.info("Terminate submitted for instance: %s", instance_id)
    return response.Response(
        ctx,
        response_data=json.dumps({"action": "terminated", "instance_id": instance_id}),
        headers={"Content-Type": "application/json"},
    )


def _refused(ctx, reason: str, instance_id: str):
    return response.Response(
        ctx,
        response_data=json.dumps({
            "action":      "refused",
            "reason":      reason,
            "instance_id": instance_id,
        }),
        status_code=403,
        headers={"Content-Type": "application/json"},
    )


def _evaluate_scale_in(ctx, signer):
    """Decide whether to scale the media node pool in and, if so, detach the
    oldest member. The detached member's pre-drain daemon does the rest."""
    compartment_id    = os.environ["COMPARTMENT_ID"]
    pool_display_name = os.environ["POOL_DISPLAY_NAME"]
    min_nodes         = int(os.environ.get("MIN_NODES", "1"))
    cpu_threshold     = float(os.environ.get("CPU_THRESHOLD", "50"))

    compute_mgmt = oci.core.ComputeManagementClient(config={}, signer=signer)
    monitoring   = oci.monitoring.MonitoringClient(config={}, signer=signer)
    now_utc      = datetime.now(tz=timezone.utc)

    # Locate the pool by display name; must be RUNNING.
    pools = oci.pagination.list_call_get_all_results(
        compute_mgmt.list_instance_pools,
        compartment_id=compartment_id,
        lifecycle_state="RUNNING",
    ).data
    pool = next((p for p in pools if p.display_name == pool_display_name), None)
    if pool is None:
        logger.info("Pool '%s' not found or not RUNNING.", pool_display_name)
        return _noop(ctx, "pool_not_found")

    # Never go below min_nodes.
    pool_detail  = compute_mgmt.get_instance_pool(pool.id).data
    current_size = pool_detail.size
    logger.info("Pool '%s' size: %d, min_nodes: %d", pool_display_name, current_size, min_nodes)
    if current_size <= min_nodes:
        logger.info("Pool at or below minimum (%d). Nothing to do.", min_nodes)
        return _noop(ctx, "at_minimum")

    # Running members, oldest first (the oldest is the scale-in candidate).
    members = oci.pagination.list_call_get_all_results(
        compute_mgmt.list_instance_pool_instances,
        compartment_id=compartment_id,
        instance_pool_id=pool.id,
    ).data
    running = sorted(
        [m for m in members if m.state == "Running"],
        key=lambda m: m.time_created,
    )
    if not running:
        logger.info("No Running instances found in pool.")
        return _noop(ctx, "no_running_members")

    # Skip the cycle if ANY member is still in its grace period — a young
    # node biases the pool average downward and would cause a false scale-in.
    for member in running:
        age_minutes = (now_utc - member.time_created).total_seconds() / 60
        if age_minutes < GRACE_MINUTES:
            logger.info(
                "Instance %s is only %.1f min old (grace: %d min). Skipping cycle.",
                member.display_name, age_minutes, GRACE_MINUTES,
            )
            return _noop(ctx, "grace_period")

    # Pool-wide avg CPU (5-min mean per instance).
    end_time   = datetime.now(tz=timezone.utc)
    start_time = end_time - timedelta(minutes=5)
    cpu_values = []
    for member in running:
        cpu = _get_cpu(monitoring, compartment_id, member.id, start_time, end_time)
        if cpu is None:
            logger.warning(
                "CPU metric unavailable for %s (%s). Skipping cycle (fail-safe).",
                member.display_name, member.id,
            )
            return _noop(ctx, "metrics_unavailable")
        logger.info("Instance %s CPU 5m mean: %.1f%%", member.id, cpu)
        cpu_values.append(cpu)

    pool_avg_cpu = sum(cpu_values) / len(cpu_values)
    logger.info(
        "Pool average CPU (5m mean): %.1f%%, threshold: %.1f%%",
        pool_avg_cpu, cpu_threshold,
    )
    if pool_avg_cpu >= cpu_threshold:
        logger.info("Pool avg CPU at or above threshold. No scale-in.")
        return _noop(ctx, "cpu_above_threshold")

    # Detach the oldest Running node — pool target -1, no replacement spawned,
    # no OCI-forced terminate. The node's drain watcher reacts to the removal.
    target = running[0]
    logger.info(
        "Pool avg %.1f%% < %.1f%%. Detaching oldest node: %s (%s).",
        pool_avg_cpu, cpu_threshold, target.display_name, target.id,
    )
    compute_mgmt.detach_instance_pool_instance(
        instance_pool_id=pool.id,
        detach_instance_pool_instance_details=oci.core.models.DetachInstancePoolInstanceDetails(
            instance_id=target.id,
            is_decrement_size=True,
            is_auto_terminate=False,
        ),
    )
    logger.info(
        "Detach request submitted. Drain watcher on %s will handle graceful shutdown.",
        target.display_name,
    )
    return response.Response(
        ctx,
        response_data=json.dumps({
            "action":       "scale_in",
            "instance_id":  target.id,
            "display_name": target.display_name,
            "pool_avg_cpu": round(pool_avg_cpu, 1),
            "threshold":    cpu_threshold,
        }),
        headers={"Content-Type": "application/json"},
    )


def _get_cpu(
    monitoring: oci.monitoring.MonitoringClient,
    compartment_id: str,
    instance_id: str,
    start_time: datetime,
    end_time: datetime,
) -> Optional[float]:
    """Return the 5-min mean CPU for one instance, or None on error / no data."""
    query = f'CpuUtilization[1m]{{resourceId="{instance_id}"}}.mean()'
    try:
        result = monitoring.summarize_metrics_data(
            compartment_id=compartment_id,
            summarize_metrics_data_details=oci.monitoring.models.SummarizeMetricsDataDetails(
                namespace="oci_computeagent",
                query=query,
                start_time=start_time.isoformat(),
                end_time=end_time.isoformat(),
            ),
        ).data
        if result and result[0].aggregated_datapoints:
            values = [dp.value for dp in result[0].aggregated_datapoints]
            return sum(values) / len(values)
    except Exception as exc:
        logger.warning("Failed to get CPU for %s: %s", instance_id, exc)
    return None


def _noop(ctx, reason: str):
    return response.Response(
        ctx,
        response_data=json.dumps({"action": "noop", "reason": reason}),
        headers={"Content-Type": "application/json"},
    )
