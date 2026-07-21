# Results — Experiment 01, High Booking Concurrency

> One block per run. Copy the template, fill it in, keep the history. Numbers here are the
> baseline the resilience experiments compare against.

## Run template

```
### Run 2026-07-08

Config
- Scenario:                   both
- Discovery:                  ROUTES=… (from lib/k6/config.js)
- Commit / image tags:        booking=…  inventory=…  payment=…
- Cluster shape:              nodes=3×(2 OCPU/16GB), max-pods=30
- HPA:                        booking min/max=1/4  inventory min/max=1/4
- Pooler:                     transaction, default_pool_size=12  (cutover: which services)
- k6 knobs:                   TARGET_RPS=60  RAMP=2m  HOLD=6m  MAX_VUS=200

Results (from k6 summary)
- Bookings created (201) / replayed (200) / failed:  28845 /  0 / 0
- booking_success_rate:                   100%
- cart_create_duration p95:               878.89 ms
- cart_add_item_duration p95:             884.23 ms
- booking_create_duration p50 / p90 / p95: 342.74ms / 484.58ms /  578.37ms
- journey_duration p95 (cart→flight→booking): 3.01 s
- http_req_failed:                        0.0%
- http_reqs                               144985
- Achieved throughput (journeys/s):       …

Observed (from Grafana)
- booking replicas:    min 1 → peak 4 (scaled at 60 rps)
- cart replicas:    min 1 → peak 1
- inventory replicas:  min 1 → peak 3 (kafka consumer concurrency = 2)
- Peak app CPU (from request):        150%
- PgBouncer cl_waiting / maxwait:  0 / …
- Postgres connections peak / limit: 95 / 200
- TPS:                  -
- Kafka consumer lag peak (inventory/payment): 1890/482

Verdict:  PASS / FAIL — <one line>
Notes / follow-ups:  
* Travel cart didn't scale, need to investigate why, it reached 300% CPU usage from request
* Inventory service needs to use concurrency to handle more traffic and add more partitions on booking.* events.
```

---

<!-- paste completed runs below -->
