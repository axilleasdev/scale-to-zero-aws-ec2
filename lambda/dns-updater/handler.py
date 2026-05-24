"""
Recipe DNS Updater — keeps the Route53 A record in sync with the EC2's
current public IP.

Triggered by EventBridge whenever the recipe EC2 transitions to 'running'.
Reads the instance's current public IP via DescribeInstances and upserts
the Route53 A record at recipe-origin.<zone>.

Why this matters:
  We don't pay for an Elastic IP, so the EC2 gets a new public IP every
  start. CloudFront's primary origin is recipe-origin.<zone>, so the DNS
  must always point to the *current* IP for direct traffic to work.

Environment variables:
  INSTANCE_ID   — EC2 instance to read from (required)
  HOSTED_ZONE_ID — Route53 hosted zone ID where we maintain the record
  RECORD_NAME   — full DNS name we manage (e.g. recipe-origin.recipe-aws.foo.gr)

IAM permissions (set in Terraform):
  ec2:DescribeInstances
  route53:ChangeResourceRecordSets   on the specific zone
  route53:GetChange                  for status checks
"""

import os
from typing import Any

import boto3

ec2 = boto3.client("ec2")
route53 = boto3.client("route53")

INSTANCE_ID = os.environ["INSTANCE_ID"]
HOSTED_ZONE_ID = os.environ["HOSTED_ZONE_ID"]
RECORD_NAME = os.environ["RECORD_NAME"]


def get_public_ip() -> str | None:
    resp = ec2.describe_instances(InstanceIds=[INSTANCE_ID])
    return resp["Reservations"][0]["Instances"][0].get("PublicIpAddress")


def upsert_a_record(ip: str) -> str:
    """UPSERT means "create or replace", so this is idempotent."""
    resp = route53.change_resource_record_sets(
        HostedZoneId=HOSTED_ZONE_ID,
        ChangeBatch={
            "Comment": "Recipe site EC2 IP refresh",
            "Changes": [
                {
                    "Action": "UPSERT",
                    "ResourceRecordSet": {
                        "Name": RECORD_NAME,
                        "Type": "A",
                        # Low TTL so CloudFront re-resolves quickly after
                        # an IP change. We still get the speed benefit on
                        # subsequent requests.
                        "TTL": 60,
                        "ResourceRecords": [{"Value": ip}],
                    },
                }
            ],
        },
    )
    return resp["ChangeInfo"]["Id"]


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """
    Triggered by EventBridge with an EC2 state-change event:
      { "detail": { "instance-id": "...", "state": "running" }, ... }
    """
    ip = get_public_ip()
    if not ip:
        return {"status": "skipped", "reason": "no public IP yet"}

    change_id = upsert_a_record(ip)
    return {"status": "ok", "ip": ip, "changeId": change_id}
