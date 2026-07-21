# Results — Experiment 01, High Booking Concurrency

> One block per run. Copy the template, fill it in, keep the history. Numbers here are the
> baseline the resilience experiments compare against.

## Run template

```
### Run 2026-07-06

Config
- Scenario:                   both
- Discovery:                  ROUTES=… (from lib/k6/config.js)
- Commit / image tags:        booking=…  inventory=…  payment=…
- Cluster shape:              nodes=3×(2 OCPU/16GB), max-pods=30
- HPA:                        booking min/max=1/4  inventory min/max=1/4
- Pooler:                     transaction, default_pool_size=12  (cutover: which services)
- k6 knobs:                   TARGET_RPS=30  RAMP=2m  HOLD=4m  MAX_VUS=200

Results (from k6 summary)
- Bookings created (201) / replayed (200) / failed:  9547 /   / 1538
- booking_success_rate:                   86.12%
- cart_create_duration p95:               356.89 ms
- cart_add_item_duration p95:             306.76 ms
- booking_create_duration p50 / p90 / p95: 283.3ms / 317.86ms /  356.89ms
- journey_duration p95 (cart→flight→booking): 1.25 s
- http_req_failed:                        2.83%
- http_reqs                               54189
- Achieved throughput (journeys/s):       …

Observed (from Grafana)
- booking replicas:    min 1 → peak 4 (scaled at 30 rps)
- inventory replicas:  min 1 → peak 4
- Peak app CPU:        150%
- PgBouncer cl_waiting / maxwait:  … / …
- Postgres connections peak / limit: 180 / 200
- Kafka consumer lag peak (inventory/payment): 15/136

Verdict:  PASS / FAIL — <one line>
Notes / follow-ups:  <bottleneck found, thresholds to adjust, next TARGET_RPS>
There were insufficient inventory capacity that led to inventory rejection for bookings. Another test should be done
including more catalog options flight/hotels to provide enough data for the load test.
```

---

<!-- paste completed runs below -->
