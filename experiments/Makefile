# Convenience runners for the Atlas experiments.
# Load config first:  set -a; source .env; set +a
#
#   make run   EXP=01-high-booking-concurrency
#   make run   EXP=01-high-booking-concurrency K6_FLAGS="--summary-export=summary.json"
#   make smoke EXP=01-high-booking-concurrency [N=5]   # run exactly N journeys
#   make list

K6 ?= k6
K6_FLAGS ?=
SCRIPT ?= load.js
N ?= 1
CONFIRM ?=
RESET_FLAGS ?=

# Prometheus remote-write output — sends k6's OWN metrics (k6_*) to Prometheus so they show
# in Grafana next to the app metrics (e.g. the "Atlas — Experiment 02" dashboard). The stack's
# receiver is already enabled (kube-prometheus-stack-values.yaml: enableRemoteWriteReceiver).
# Turn it on with PROM=1, after opening a port-forward to Prometheus:
#   kubectl -n atlas-observability port-forward svc/kps-kube-prometheus-stack-prometheus 9090:9090
K6_PROMETHEUS_RW_SERVER_URL ?= http://localhost:9090/api/v1/write
K6_PROMETHEUS_RW_TREND_STATS ?= p(95),p(99),count
K6_OUT :=
ifeq ($(PROM),1)
  K6_OUT := -o experimental-prometheus-rw
  export K6_PROMETHEUS_RW_SERVER_URL
  export K6_PROMETHEUS_RW_TREND_STATS
endif

.PHONY: run smoke list reset help

help:
	@echo "Targets:"
	@echo "  run    EXP=<dir> [K6_FLAGS=...] [PROM=1]   run an experiment's $(SCRIPT)"
	@echo "  smoke  EXP=<dir> [N=5] [PROM=1]            run exactly N journeys (= N bookings)"
	@echo "  reset  [CONFIRM=yes] [RESET_FLAGS=...]     reset DB/Kafka/read-model to a clean baseline"
	@echo "  list                                       list available experiments"
	@echo ""
	@echo "  PROM=1 also remote-writes k6 metrics to Prometheus (needs the port-forward; see Makefile)."

run:
	@test -n "$(EXP)" || { echo "Set EXP=<experiment-dir>"; exit 1; }
	cd $(EXP) && $(K6) run $(K6_OUT) $(K6_FLAGS) $(SCRIPT)

# Smoke test: N end-to-end journeys, sequentially (1 VU). Validates the whole flow and auth
# without generating real load. Requires .env to be loaded. N bookings are created.
smoke:
	@test -n "$(EXP)" || { echo "Set EXP=<experiment-dir>"; exit 1; }
	cd $(EXP) && $(K6) run $(K6_OUT) -e ITERATIONS=$(N) $(K6_FLAGS) $(SCRIPT)

list:
	@ls -d [0-9][0-9]-*/ 2>/dev/null | sed 's:/$$::' || echo "no experiments yet"

# Reset DB/Kafka/read-model to a clean baseline between runs. Dry-run unless CONFIRM=yes.
# Doc: scripts/reset-state.md.  e.g.  make reset CONFIRM=yes RESET_FLAGS=--include-search
reset:
	@if [ -n "$(CONFIRM)" ]; then \
	  CONFIRM=$(CONFIRM) bash scripts/reset-state.sh $(RESET_FLAGS); \
	else \
	  echo ">> DRY-RUN (pass CONFIRM=yes to execute)"; \
	  DRY_RUN=1 bash scripts/reset-state.sh $(RESET_FLAGS); \
	fi
