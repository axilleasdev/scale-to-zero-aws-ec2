"""
Auto-Stop — stops the EC2 when it has been idle for too long.

Triggered by EventBridge on a fixed schedule (every 5 minutes by default).
We define "idle" as: average outbound network packets per second over the
last IDLE_WINDOW_MIN minutes is below IDLE_THRESHOLD_PPS.

Why NetworkPacketsOut instead of CPU:
  - A bored web server uses near-zero CPU even with a steady trickle of
    HTTP probes; CPU thresholds end up either too low (false positives)
    or too high (won't stop).
  - Outbound packets directly correlate with serving traffic to visitors.
    No visitors → no responses → ~zero outbound packets.
  - Some background OS chatter (~1-2 packets/sec) always exists, so the
    threshold should be a bit above that.

Environment variables:
  INSTANCE_ID         — EC2 instance to monitor and stop (required)
  IDLE_WINDOW_MIN     — lookback window in minutes (default: 30)
  IDLE_THRESHOLD_PPS  — packets-per-sec threshold below which we call it idle
                        (default: 5.0)
  MIN_UPTIME_MIN      — don't stop if the instance was started in the last
                        N minutes (avoid stopping during boot warm-up;
                        default: 10)

IAM permissions (set in Terraform):
  ec2:DescribeInstances
  ec2:StopInstances        on the specific instance
  cloudwatch:GetMetricStatistics
"""

from __future__ import annotations

import datetime as dt
import os
from typing import Any

import boto3

ec2 = boto3.client("ec2")
cloudwatch = boto3.client("cloudwatch")

INSTANCE_ID = os.environ["INSTANCE_ID"]
IDLE_WINDOW_MIN = int(os.environ.get("IDLE_WINDOW_MIN", "30"))
IDLE_THRESHOLD_PPS = float(os.environ.get("IDLE_THRESHOLD_PPS", "5.0"))
MIN_UPTIME_MIN = int(os.environ.get("MIN_UPTIME_MIN", "10"))


def describe_instance() -> dict[str, Any]:
    resp = ec2.describe_instances(InstanceIds=[INSTANCE_ID])
    instance = resp["Reservations"][0]["Instances"][0]
    return {
        "state": instance["State"]["Name"],
        "launch_time": instance["LaunchTime"],
    }


def average_packets_out(window_min: int) -> float | None:
    """
    NetworkPacketsOut is in 'count per period'. We use 60-second periods
    over the lookback window, then average to per-second.

    Returns None if CloudWatch has no datapoints (instance just started or
    metric hasn't been published yet).
    """
    end = dt.datetime.now(dt.timezone.utc)
    start = end - dt.timedelta(minutes=window_min)

    resp = cloudwatch.get_metric_statistics(
        Namespace="AWS/EC2",
        MetricName="NetworkPacketsOut",
        Dimensions=[{"Name": "InstanceId", "Value": INSTANCE_ID}],
        StartTime=start,
        EndTime=end,
        Period=60,
        Statistics=["Average"],
    )
    points = resp.get("Datapoints") or []
    if not points:
        return None

    # 'Average' here is average packets observed in each 60s period;
    # divide by 60 to convert to per-second.
    avg_per_period = sum(p["Average"] for p in points) / len(points)
    return avg_per_period / 60.0


def stop_instance() -> None:
    ec2.stop_instances(InstanceIds=[INSTANCE_ID])


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    info = describe_instance()
    state = info["state"]

    if state != "running":
        return {"action": "skip", "reason": f"state is {state}, nothing to do"}

    # Don't stop a freshly-booted instance — it may be still warming up
    # while the metric window is still empty.
    age = dt.datetime.now(dt.timezone.utc) - info["launch_time"]
    if age < dt.timedelta(minutes=MIN_UPTIME_MIN):
        return {
            "action": "skip",
            "reason": f"instance up only {age.total_seconds():.0f}s, below MIN_UPTIME_MIN",
        }

    pps = average_packets_out(IDLE_WINDOW_MIN)
    if pps is None:
        return {"action": "skip", "reason": "no metric datapoints yet"}

    if pps >= IDLE_THRESHOLD_PPS:
        return {
            "action": "skip",
            "reason": f"active: {pps:.2f} pps >= threshold {IDLE_THRESHOLD_PPS}",
        }

    stop_instance()
    return {
        "action": "stopped",
        "reason": f"idle: {pps:.2f} pps < threshold {IDLE_THRESHOLD_PPS}",
    }
