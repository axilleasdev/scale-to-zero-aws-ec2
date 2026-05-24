# Architecture

Three diagrams: the high-level component map, the cold-start sequence
(when a visitor arrives while the EC2 is stopped), and the periodic
auto-stop loop.

All three render natively on GitHub.

## High-level component map

```mermaid
flowchart TB
    Visitor([👤 Visitor<br/>browser])

    subgraph Cloudflare["Cloudflare (free tier)"]
        CFP[DNS + Proxy<br/>Bot Fight + DDoS]
    end

    subgraph AWS["AWS — primary region (+ us-east-1 for ACM)"]
        CF[CloudFront<br/>CDN + TLS + cache]

        subgraph OG["Origin Group (failover)"]
            EC2[("EC2 instance<br/>your container app")]
            APIGW[API Gateway<br/>HTTP API]
        end

        subgraph Lambdas["Control plane Lambdas"]
            L1[router<br/>wake-up + proxy]
            L2[dns-updater<br/>refresh Route53]
            L3[auto-stop<br/>idle detection]
        end

        R53[Route53<br/>delegated subdomain]
        EBS[("EBS data volume<br/>persistent")]
        EB[EventBridge<br/>schedules + rules]
        CW[CloudWatch<br/>logs + metrics]
    end

    Visitor -- "HTTPS<br/>app.example.com" --> CFP
    CFP --> CF

    CF -- "GET (cacheable)" --> EC2
    CF -- "POST / origin down" --> APIGW
    APIGW --> L1
    L1 -- "describe / start" --> EC2
    L1 -- "proxy if running" --> EC2

    EB -. "EC2 → running" .-> L2
    L2 -- "UPSERT A record" --> R53
    R53 -. "resolves origin host" .-> CF

    EB -. "every 5 min" .-> L3
    L3 -- "GetMetricStatistics" --> CW
    L3 -- "StopInstances if idle" --> EC2

    EC2 --- EBS
    EC2 -. "publishes metrics" .-> CW
    L1 -. "logs" .-> CW

    style Visitor fill:#fef3c7,stroke:#f59e0b,color:#000
    style CFP fill:#fee2e2,stroke:#ea580c,color:#000
    style CF fill:#dbeafe,stroke:#1e40af,color:#000
    style EC2 fill:#e0e7ff,stroke:#3730a3,color:#000
    style APIGW fill:#fef3c7,stroke:#a16207,color:#000
    style L1 fill:#fef3c7,stroke:#a16207,color:#000
    style L2 fill:#fef3c7,stroke:#a16207,color:#000
    style L3 fill:#fef3c7,stroke:#a16207,color:#000
    style R53 fill:#dcfce7,stroke:#15803d,color:#000
    style EB fill:#fce7f3,stroke:#be185d,color:#000
    style CW fill:#fce7f3,stroke:#be185d,color:#000
    style EBS fill:#e0e7ff,stroke:#3730a3,color:#000
```

### What each piece does

| Component | Responsibility |
| --- | --- |
| **Cloudflare** | Public DNS, free DDoS / bot mitigation, edge caching |
| **CloudFront** | TLS termination, regional caching, origin failover |
| **EC2** | Runs your actual application via Docker / systemd / whatever |
| **EBS data volume** | Persistent disk that survives stop/start cycles |
| **API Gateway + router Lambda** | Wake-up flow + proxy for POST when origin is down |
| **Route53 delegated zone** | Holds the dynamic A record CloudFront uses as origin |
| **dns-updater Lambda** | Updates the A record when EC2 gets a new public IP |
| **EventBridge rule** | Fires on `EC2 state-change → running` |
| **EventBridge schedule** | Fires every 5 minutes for the auto-stop check |
| **auto-stop Lambda** | Reads `NetworkPacketsOut` and stops idle instances |
| **CloudWatch** | Metrics for idle detection, logs for debugging |

## Cold-start sequence

What happens when a visitor arrives while the EC2 is stopped.

```mermaid
sequenceDiagram
    participant U as Visitor
    participant CFL as Cloudflare
    participant CF as CloudFront
    participant APIGW as API Gateway
    participant LR as router Lambda
    participant EC2 as EC2
    participant EB as EventBridge
    participant LU as dns-updater Lambda
    participant R53 as Route53

    U->>CFL: GET https://app.example.com
    CFL->>CF: forward
    CF->>EC2: try primary origin
    EC2-->>CF: connection refused (stopped)
    CF->>APIGW: failover
    APIGW->>LR: invoke
    LR->>EC2: DescribeInstances → stopped
    LR->>EC2: StartInstances
    LR-->>APIGW: 200 + loading HTML (auto-refresh in 5 s)
    APIGW-->>CF: 200 loading HTML
    CF-->>CFL: 200 loading HTML
    CFL-->>U: loading page

    Note over EC2: instance boots (~30 s)
    EC2-->>EB: state = running
    EB->>LU: trigger
    LU->>EC2: DescribeInstances → IP
    LU->>R53: UPSERT A record (new IP, TTL=60)

    Note over U: browser auto-refresh after 5 s
    U->>CFL: GET (refresh)
    CFL->>CF: forward
    CF->>EC2: primary origin (new IP via Route53)
    EC2-->>CF: 200 with site
    CF-->>CFL: 200
    CFL-->>U: site loads ✅
```

A few notes:

- The CloudFront connection-refused → failover path adds ≈3-5 s on the
  very first request after the EC2 has been stopped. Subsequent
  refreshes hit the loading page instantly because the failover route
  is now warm in CloudFront.
- The DNS update happens asynchronously. CloudFront re-resolves origin
  DNS on a 60 s timer (we set the A record TTL to 60), so by the time
  the user has refreshed twice, the new IP is in play.
- The total cold-start UX is therefore: one ≈3 s "loading screen" hit,
  then visible loading-page polling for 30-60 s, then the site appears.

## Auto-stop loop

What happens every 5 minutes.

```mermaid
sequenceDiagram
    participant EB as EventBridge<br/>schedule
    participant LS as auto-stop Lambda
    participant EC2 as EC2
    participant CW as CloudWatch

    EB->>LS: tick (rate 5 min)
    LS->>EC2: DescribeInstances
    alt state != running
        EC2-->>LS: stopped/pending
        Note right of LS: skip
    else uptime < MIN_UPTIME_MIN
        EC2-->>LS: running, just started
        Note right of LS: skip warm-up
    else
        EC2-->>LS: running, mature
        LS->>CW: GetMetricStatistics<br/>NetworkPacketsOut last 15 min
        CW-->>LS: avg pps
        alt pps >= threshold
            Note right of LS: traffic detected, keep alive
        else
            LS->>EC2: StopInstances ✅
        end
    end
```

We use **NetworkPacketsOut** as the activity signal because:

- A bored web server uses near-zero CPU even when serving health probes,
  so CPU alone gives lots of false negatives.
- Outbound packets correlate directly with serving real responses to
  visitors. If no one is asking, there's nothing to send back.
- Some background OS chatter always leaks ~1-2 packets/sec, so the
  threshold needs to sit a little above that (default `3.0 pps`).

CloudWatch publishes basic-monitoring metrics on **5-minute intervals**.
That's why the lookback window defaults to 15 min: it gives the metric
a chance to be published and averages out the noise without keeping the
EC2 alive forever after a single visit.
