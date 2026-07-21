# Results — Experiment 01, High Booking Concurrency

> One block per run. Copy the template, fill it in, keep the history. Numbers here are the
> baseline the resilience experiments compare against.

## Run template

```
### Run 2026-07-07

Config
- Scenario:                   both
- Discovery:                  ROUTES=… (from lib/k6/config.js)
- Commit / image tags:        booking=…  inventory=…  payment=…
- Cluster shape:              nodes=3×(2 OCPU/16GB), max-pods=30
- HPA:                        booking min/max=1/4  inventory min/max=1/4
- Pooler:                     transaction, default_pool_size=12  (cutover: which services)
- k6 knobs:                   TARGET_RPS=30  RAMP=2m  HOLD=4m  MAX_VUS=200

Results (from k6 summary)
- Bookings created (201) / replayed (200) / failed:  9455 /   / 1674
- booking_success_rate:                   84.95%
- cart_create_duration p95:               308.17 ms
- cart_add_item_duration p95:             308.24 ms
- booking_create_duration p50 / p90 / p95: 293.76ms / 377.93ms /  421.84ms
- journey_duration p95 (cart→flight→booking): 1.28 s
- http_req_failed:                        3.07%
- http_reqs                               54400
- Achieved throughput (journeys/s):       …

Observed (from Grafana)
- booking replicas:    min 1 → peak 4 (scaled at 30 rps)
- inventory replicas:  min 1 → peak 4
- Peak app CPU:        130%
- PgBouncer cl_waiting / maxwait:  0 / …
- Postgres connections peak / limit: 90 / 200
- TPS:                  1650
- Kafka consumer lag peak (inventory/payment): 30/44

Verdict:  PASS / FAIL — <one line>
Notes / follow-ups:  <bottleneck found, thresholds to adjust, next TARGET_RPS>
```

---

<!-- paste completed runs below -->
