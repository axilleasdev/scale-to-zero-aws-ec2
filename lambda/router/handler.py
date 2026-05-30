"""
EC2 On-Demand Router — wakes EC2 on demand and proxies traffic to it.

Sits behind API Gateway, behind CloudFront. Two roles:

1. Wake-up: if the EC2 is stopped or pending, return a loading page that
   auto-refreshes. The first request that arrives while the EC2 is
   stopped triggers StartInstances.

2. Proxy: if the EC2 is running and the app responds, forward the entire
   HTTP request and return the response. CloudFront only routes mutating
   requests (POST/PUT/DELETE on configured paths) here — GETs go
   directly to the EC2 origin via the failover origin group.

We skip Elastic IPs to save money, so the EC2 has a different public IP
on every start. We discover it on each invocation via DescribeInstances.

Environment variables:
  INSTANCE_ID    — EC2 instance to control (required)
  APP_PORT       — port the app listens on (default: 8080)
  APP_NAME       — display name shown on the loading page (default: "App")
  HEALTH_PATH    — readiness probe path (default: /)
  HEALTH_TIMEOUT — probe timeout in seconds (default: 2)
  PROXY_TIMEOUT  — upstream proxy request timeout in seconds (default: 25)

IAM permissions (defined in Terraform):
  ec2:DescribeInstances
  ec2:StartInstances  (scoped to the specific instance)
"""

import base64
import os
import socket
import urllib.request
import urllib.error
from typing import Any

import boto3

ec2 = boto3.client("ec2")

INSTANCE_ID = os.environ["INSTANCE_ID"]
APP_PORT = os.environ.get("APP_PORT", "8080")
APP_NAME = os.environ.get("APP_NAME", "App")
HEALTH_PATH = os.environ.get("HEALTH_PATH", "/")
HEALTH_TIMEOUT = float(os.environ.get("HEALTH_TIMEOUT", "2"))
PROXY_TIMEOUT = float(os.environ.get("PROXY_TIMEOUT", "25"))

# Hop-by-hop headers (RFC 7230 §6.1) and others we must not forward.
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "content-length",  # API GW computes its own
    "host",            # set per-request
}

TEXT_PREFIXES = ("text/", "application/json", "application/javascript",
                 "application/xml", "image/svg+xml")


def describe_instance() -> dict[str, Any]:
    resp = ec2.describe_instances(InstanceIds=[INSTANCE_ID])
    instance = resp["Reservations"][0]["Instances"][0]
    return {
        "state": instance["State"]["Name"],
        "public_ip": instance.get("PublicIpAddress"),
    }


def start_instance() -> None:
    ec2.start_instances(InstanceIds=[INSTANCE_ID])


def app_is_ready(ip: str) -> bool:
    url = f"http://{ip}:{APP_PORT}{HEALTH_PATH}"
    try:
        with urllib.request.urlopen(url, timeout=HEALTH_TIMEOUT) as resp:
            return resp.status < 600
    except urllib.error.HTTPError:
        return True
    except (urllib.error.URLError, socket.timeout, ConnectionError):
        return False


def is_text_content(content_type: str) -> bool:
    ct = (content_type or "").lower()
    return any(ct.startswith(p) for p in TEXT_PREFIXES)


def proxy_request(event: dict[str, Any], ip: str) -> dict[str, Any]:
    method = event["requestContext"]["http"]["method"]
    path = event.get("rawPath", "/")
    query = event.get("rawQueryString", "")
    target = f"http://{ip}:{APP_PORT}{path}"
    if query:
        target = f"{target}?{query}"

    headers = {
        k: v
        for k, v in (event.get("headers") or {}).items()
        if k.lower() not in HOP_BY_HOP
    }
    headers["host"] = f"{ip}:{APP_PORT}"

    body_bytes: bytes | None = None
    raw_body = event.get("body")
    if raw_body is not None:
        if event.get("isBase64Encoded"):
            body_bytes = base64.b64decode(raw_body)
        else:
            body_bytes = raw_body.encode("utf-8")

    req = urllib.request.Request(
        url=target,
        data=body_bytes,
        method=method,
        headers=headers,
    )

    try:
        with urllib.request.urlopen(req, timeout=PROXY_TIMEOUT) as resp:
            return _build_response(resp)
    except urllib.error.HTTPError as e:
        return _build_response(e)
    except (urllib.error.URLError, socket.timeout, ConnectionError) as e:
        return html_response(
            502,
            f"<h1>Bad gateway</h1><p>Upstream unreachable: {e}</p>",
        )


def _build_response(resp: Any) -> dict[str, Any]:
    status = resp.status if hasattr(resp, "status") else resp.code
    body = resp.read()

    out_headers: dict[str, str] = {}
    cookies: list[str] = []
    is_compressed = False

    for key, value in resp.headers.items():
        key_lc = key.lower()
        if key_lc in HOP_BY_HOP:
            continue
        if key_lc == "set-cookie":
            cookies.append(value)
            continue
        if key_lc == "content-encoding" and value.lower() in ("gzip", "deflate", "br"):
            is_compressed = True
        if key in out_headers:
            out_headers[key] = f"{out_headers[key]}, {value}"
        else:
            out_headers[key] = value

    if is_compressed:
        return {
            "statusCode": status,
            "headers": out_headers,
            "cookies": cookies,
            "body": base64.b64encode(body).decode("ascii"),
            "isBase64Encoded": True,
        }

    content_type = out_headers.get("Content-Type", "")
    if is_text_content(content_type):
        try:
            return {
                "statusCode": status,
                "headers": out_headers,
                "cookies": cookies,
                "body": body.decode("utf-8"),
                "isBase64Encoded": False,
            }
        except UnicodeDecodeError:
            pass

    return {
        "statusCode": status,
        "headers": out_headers,
        "cookies": cookies,
        "body": base64.b64encode(body).decode("ascii"),
        "isBase64Encoded": True,
    }


def loading_page_html(state: str) -> str:
    state_msg = {
        "stopped": "Starting the server…",
        "pending": "Server is booting…",
        "warming_up": "Server is up — waiting for the app to start…",
        "stopping": "Please wait…",
    }.get(state, "Loading…")

    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="5">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{APP_NAME} — loading</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    display: flex; align-items: center; justify-content: center;
    min-height: 100vh; margin: 0; padding: 1rem;
    background: #f7f5f0; color: #222;
  }}
  @media (prefers-color-scheme: dark) {{
    body {{ background: #1a1a1a; color: #f0f0f0; }}
  }}
  .card {{
    text-align: center; max-width: 28rem;
    padding: 2.5rem 2rem; border-radius: 1rem;
    background: rgba(255,255,255,0.6);
    backdrop-filter: blur(8px);
    box-shadow: 0 10px 40px rgba(0,0,0,0.08);
  }}
  @media (prefers-color-scheme: dark) {{
    .card {{ background: rgba(40,40,40,0.6); }}
  }}
  h1 {{ font-size: 1.4rem; margin: 0 0 0.5rem; }}
  p {{ margin: 0.5rem 0; opacity: 0.7; }}
  .spinner {{
    width: 48px; height: 48px; margin: 1.5rem auto;
    border: 3px solid currentColor; border-bottom-color: transparent;
    border-radius: 50%; opacity: 0.4;
    animation: spin 1s linear infinite;
  }}
  @keyframes spin {{ to {{ transform: rotate(360deg); }} }}
  .small {{ font-size: 0.85rem; opacity: 0.5; margin-top: 1.5rem; }}
</style>
</head>
<body>
  <div class="card">
    <div class="spinner"></div>
    <h1>{APP_NAME}</h1>
    <p>{state_msg}</p>
    <p>This usually takes about 30–60 seconds.</p>
    <p class="small">This page will refresh automatically.</p>
    <p class="small" style="margin-top: 2rem;">Powered by <a href="https://github.com/axilleasdev/scale-to-zero-aws-ec2" style="color: inherit;">scale-to-zero-aws-ec2</a></p>
  </div>
</body>
</html>
"""


def html_response(status_code: int, body: str) -> dict[str, Any]:
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "text/html; charset=utf-8",
            "Cache-Control": "no-store, must-revalidate",
        },
        "body": body,
        "isBase64Encoded": False,
    }


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    info = describe_instance()
    state = info["state"]
    public_ip = info["public_ip"]

    if state == "running" and public_ip and app_is_ready(public_ip):
        return proxy_request(event, public_ip)

    if state == "running":
        return html_response(200, loading_page_html("warming_up"))

    if state in ("stopped", "stopping"):
        if state == "stopped":
            start_instance()
        return html_response(200, loading_page_html(state))

    if state == "pending":
        return html_response(200, loading_page_html(state))

    return html_response(
        503,
        f"<h1>Service unavailable</h1><p>Instance state: {state}</p>",
    )
