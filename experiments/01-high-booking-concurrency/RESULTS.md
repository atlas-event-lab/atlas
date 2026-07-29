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

```
### Run 2026-07-09

Config
- Scenario:                   both
- Discovery:                  ROUTES=… (from lib/k6/config.js)
- Commit / image tags:        booking=…  inventory=…  payment=…
- Cluster shape:              nodes=3×(2 OCPU/16GB), max-pods=30
- HPA:                        booking min/max=1/4  inventory min/max=1/3
- Pooler:                     transaction, default_pool_size=12  (cutover: which services)
- k6 knobs:                   TARGET_RPS=60  RAMP=2m  HOLD=6m  MAX_VUS=200

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
- booking replicas:    min 1 → peak 4 (scaled at 60 rps)
- inventory replicas:  min 1 → peak 3
- Peak app CPU (from Request%/from Limits):        156%/22.5%
- Memory (from Request%/from Limits):       91.%/58.4%
- PgBouncer cl_waiting / maxwait:  0 / …
- Postgres connections peak / limit: 110 / 200
- TPS:                  1720
- Kafka consumer lag peak (inventory/payment): 182/889
- Kafka staleness (lag/consumer rate) (inventory/payment): 12.8s/40.5s

Verdict:  PASS / FAIL — <one line>
Notes / follow-ups:  
Now this time the bottleneck was wiremock (fake payment provider), due to a restart that caused a lag on payment, it reached 4k at the end.
```
