"""
DNS Updater — keeps CloudFront pointing at the EC2's current public IP.

Two modes (set via MODE env var):

  route53:    Updates a Route53 A record. CloudFront resolves the hostname.
              Used when a custom domain with a delegated public zone exists.

  cloudfront: Updates the CloudFront origin's domain_name directly with the
              EC2's public IP. Used when no custom domain is configured (the
              .internal zone trick doesn't work because CloudFront can't
              resolve private zones).

Triggered by EventBridge whenever the managed EC2 transitions to 'running'.
"""

import os
from typing import Any

import boto3

ec2 = boto3.client("ec2")

INSTANCE_ID = os.environ["INSTANCE_ID"]
MODE = os.environ.get("MODE", "route53")


def get_public_ip() -> str | None:
    resp = ec2.describe_instances(InstanceIds=[INSTANCE_ID])
    return resp["Reservations"][0]["Instances"][0].get("PublicIpAddress")


# ─── Route53 mode ───────────────────────────────────────────────────────────

def update_route53(ip: str) -> dict[str, Any]:
    route53 = boto3.client("route53")
    zone_id = os.environ["HOSTED_ZONE_ID"]
    record = os.environ["RECORD_NAME"]
    resp = route53.change_resource_record_sets(
        HostedZoneId=zone_id,
        ChangeBatch={
            "Comment": "EC2 IP refresh (scale-to-zero)",
            "Changes": [{
                "Action": "UPSERT",
                "ResourceRecordSet": {
                    "Name": record,
                    "Type": "A",
                    "TTL": 60,
                    "ResourceRecords": [{"Value": ip}],
                },
            }],
        },
    )
    return {"status": "ok", "mode": "route53", "ip": ip, "changeId": resp["ChangeInfo"]["Id"]}


# ─── CloudFront mode ────────────────────────────────────────────────────────

def update_cloudfront(ip: str) -> dict[str, Any]:
    cf = boto3.client("cloudfront")
    dist_ids = os.environ["DISTRIBUTION_IDS"].split(",")
    origin_id = os.environ["ORIGIN_ID"]

    # CloudFront doesn't allow raw IPs. Use sslip.io wildcard DNS.
    new_domain = ip.replace(".", "-") + ".sslip.io"

    results = []
    for dist_id in dist_ids:
        resp = cf.get_distribution_config(Id=dist_id)
        config = resp["DistributionConfig"]
        etag = resp["ETag"]

        for origin in config["Origins"]["Items"]:
            if origin["Id"] == origin_id:
                if origin["DomainName"] == new_domain:
                    results.append({"dist": dist_id, "status": "unchanged"})
                    break
                origin["DomainName"] = new_domain
                cf.update_distribution(Id=dist_id, DistributionConfig=config, IfMatch=etag)
                results.append({"dist": dist_id, "status": "updated"})
                break

    return {"status": "ok", "mode": "cloudfront", "ip": ip, "domain": new_domain, "results": results}


# ─── Handler ────────────────────────────────────────────────────────────────

def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    ip = get_public_ip()
    if not ip:
        return {"status": "skipped", "reason": "no public IP yet"}

    if MODE == "cloudfront":
        return update_cloudfront(ip)
    return update_route53(ip)
