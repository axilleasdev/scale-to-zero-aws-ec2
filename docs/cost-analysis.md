# Cost Analysis

> Detailed breakdown of what this stack costs under various traffic scenarios.

All prices are for **eu-central-1 (Frankfurt)** as of 2026. Your region
may differ slightly.

## Fixed costs (always charged, regardless of traffic)

| Resource | Spec | Monthly |
| -------- | ---- | ------: |
| EBS root volume | 8 GB gp3 | $0.64 |
| EBS data volume | 4 GB gp3 | $0.32 |
| Route53 hosted zone | 1 zone | $0.50 |
| Elastic IP | not used | **$0** |
| **Total fixed** | | **$1.46** |

Everything else (CloudFront, API Gateway, Lambda, EventBridge,
CloudWatch) is pay-per-use and covered by the AWS free tier for
low-traffic sites.

### Why no Elastic IP?

An Elastic IP costs **$3.65/month** when attached to a stopped instance
(which is most of the time in this stack). Instead, we let the EC2 get a
fresh public IP on every start and use a Lambda + Route53 to update the
DNS record automatically. CloudFront re-resolves the origin hostname
within 60 seconds.

This saves **$44/year** with zero UX impact — the visitor always sees
the same `https://app.example.com` URL regardless of the underlying IP.

### Comparison with traditional setups

| Setup | Monthly cost |
| ----- | -----------: |
| **This stack** (scale-to-zero) | ~$1.50 |
| EC2 t4g.small always-on | $6.13 |
| EC2 + Elastic IP (stopped 90%) | $3.65 + $0.64 = $4.29 |
| EC2 + ALB + always-on | $22+ |
| Lightsail $5 plan | $5.00 |

## Scenario 1: Zero traffic (idle)

The EC2 stays stopped. The auto-stop Lambda fires every 5 minutes but
exits immediately when it sees `state != running`.

| Component | Cost |
| --------- | ---: |
| Fixed (above) | $1.46 |
| Lambda auto-stop (8,640 invocations) | $0 (free tier) |
| **Total** | **$1.46/mo** |

## Scenario 2: Light use (1 hour/day, ~30 h/month)

A handful of visitors per day. EC2 wakes up, serves traffic for an hour,
then auto-stops.

| Component | Cost |
| --------- | ---: |
| Fixed | $1.46 |
| EC2 t4g.small (30 h × $0.0084) | $0.25 |
| Lambda invocations (~500) | $0 |
| API Gateway (~500 requests) | $0 |
| CloudFront (free tier) | $0 |
| **Total** | **~$1.70/mo** |

## Scenario 3: 24-hour bot flood (1,000 req/min)

Total requests: 1,000 × 60 × 24 = **1.44 million**.

Assuming 90% CloudFront cache hit rate (the loading page is identical
for all visitors):

| Component | Cost |
| --------- | ---: |
| Fixed | $1.46 |
| EC2 (24 h) | $0.20 |
| CloudFront requests (1.44M, free tier 10M) | $0 |
| API Gateway (144K cache misses × $1/M) | $0.14 |
| Lambda (144K × 200 ms × 256 MB) | $0 (free tier) |
| CloudWatch logs (~200 MB ingestion) | $0.11 |
| **Total** | **~$2/mo** |

## Scenario 4: Sustained flood (1,000 req/min for 30 days)

Total requests: **43.2 million**.

| Component | Cost |
| --------- | ---: |
| Fixed | $1.46 |
| EC2 (720 h, always on) | $6.05 |
| CloudFront (43M requests, 33M over free tier) | ~$40 |
| API Gateway (13M cache misses) | $13 |
| Lambda (13M invocations, 12M over free) | $2.40 |
| CloudWatch logs (~13 GB) | $7.40 |
| **Total** | **~$70/mo** |

### Mitigations for scenario 4

- **Cloudflare proxy** (free): absorbs most bot traffic before it reaches AWS.
- **Rate limiting** (Cloudflare free rule): block IPs doing >60 req/min.
- **AWS Budget alarm** at $10: email notification before costs spiral.
- **CloudFront cache TTL** on loading page: reduces Lambda invocations.

With Cloudflare + rate limiting, the realistic cost even under sustained
attack drops to **$5-10/mo**.

## Free tier coverage

| Service | Free tier (always) | Our usage |
| ------- | ------------------ | --------- |
| Lambda invocations | 1M/mo | <50K |
| Lambda compute | 400K GB-sec/mo | <10K |
| CloudFront requests | 10M/mo | <100K |
| CloudFront data out | 1 TB/mo | <1 GB |
| CloudWatch logs ingestion | 5 GB/mo | <100 MB |
| API Gateway (REST) | 1M/mo first 12 months | — |
| API Gateway (HTTP) | no free tier | <50K |

For normal demo/side-project traffic, **everything except the fixed EBS +
Route53 is covered by free tier**.
