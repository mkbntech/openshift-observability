# Enterprise OpenShift Observability Runbook
## Platform: Red Hat OpenShift Local (CRC) 4.20.x

This runbook provides step-by-step technical procedures to deploy, configure, and troubleshoot the full enterprise distributed tracing stack on a local laptop using **Red Hat OpenShift Local** (formerly CodeReady Containers / CRC) with OpenShift 4.20.x.

---

## 1. System Requirements & Hardware Allocation

Running the OpenShift 4.20 control plane, User Workload Monitoring, Red Hat OpenTelemetry Operator, TempoStack, MinIO, and four polyglot microservices requires careful resource provisioning.

| Resource | Minimum Required | Recommended Local Setting |
| :--- | :--- | :--- |
| **Workstation RAM** | 24 GB Physical | 32 GB Physical |
| **CRC Assigned RAM** | 14 GB (`14336 MB`) | **16 GB (`16384 MB`)** |
| **CRC Assigned vCPUs**| 4 vCPUs | **6 vCPUs** |
| **Disk Storage** | 35 GB | **40–50 GB** |
| **OS** | Linux (Fedora/RHEL/Ubuntu), macOS (Apple Silicon or Intel), Windows 11 WSL2 |

---

## 2. OpenShift Local (CRC) Initialization

### Step 2.1: Configure Hardware Footprint
Run these commands from your terminal **before** starting CRC:

```bash
# 1. Assign 16 GB of RAM to the CRC virtual machine
crc config set memory 16384

# 2. Assign 6 virtual CPU cores
crc config set cpus 6

# 3. Assign 40 GB disk space
crc config set disk-size 40

# 4. Disable anonymous telemetry to reduce background overhead
crc config set consent-telemetry no

# 5. Enable cluster monitoring operator (disabled by default in CRC)
crc config set enable-cluster-monitoring true

# 6. Verify the configuration
crc config view
```

### Step 2.2: Setup & Start CRC
Download your Red Hat pull secret from [console.redhat.com](https://console.redhat.com/openshift/create/local).

```bash
# Prepare the hypervisor and VM environment
crc setup

# Start the cluster with your pull secret
crc start -p /path/to/pull-secret.txt

# Export OpenShift CLI environment variables to your shell
eval $(crc oc-env)

# Log in as cluster administrator
oc login -u kubeadmin https://api.crc.testing:6443
# (Use the password printed in your terminal by 'crc start')
```

---

## 3. Enable User Workload Monitoring

CRC disables user workload monitoring by default to save memory. We must enable it to collect application-level and OTel Collector metrics into OpenShift Prometheus.

Apply the monitoring configuration:
```bash
oc apply -f manifests/00-cluster-monitoring/cluster-monitoring-config.yaml
```

Verify that the user-workload-monitoring pods start:
```bash
oc get pods -n openshift-user-workload-monitoring
```
*(Expected: `prometheus-user-workload-0`, `thanos-ruler-user-workload-0` running).*

---

## 4. Install Enterprise Operators

OpenShift 4.20 uses Operator Lifecycle Manager (OLM) subscriptions from `redhat-operators`.

```bash
# 1. Create operator namespaces
oc apply -f manifests/01-operators/01-namespaces.yaml

# 2. Create OperatorGroups
oc apply -f manifests/01-operators/02-operator-group.yaml

# 3. Create Subscriptions for OpenTelemetry and Tempo
oc apply -f manifests/01-operators/03-subscriptions.yaml
```

Verify operator installations:
```bash
# Check Red Hat OpenTelemetry Operator
oc get csv -n openshift-opentelemetry-operator

# Check Red Hat OpenShift distributed tracing platform (Tempo)
oc get csv -n openshift-tempo-operator
```
Wait until both ClusterServiceVersions show **`Succeeded`**.

---

## 5. Deploy Local S3 Storage (MinIO)

Tempo requires an S3-compatible backend to store trace blocks. We deploy a lightweight single-pod MinIO instance with an auto-bucket initialization job.

```bash
# Deploy MinIO PVC, Deployment, Service, and Bucket Initializer
oc apply -f manifests/02-minio/01-minio.yaml

# Deploy Tempo S3 credentials Secret
oc apply -f manifests/02-minio/02-tempo-s3-secret.yaml
```

Verify MinIO status:
```bash
# Check MinIO pod
oc get pods -n tracing -l app=minio

# Check that the bucket creation job completed
oc get jobs -n tracing
```

---

## 6. Deploy TempoStack & OpenTelemetry Collector

```bash
# 1. Deploy TempoStack (pointing to local MinIO)
oc apply -f manifests/03-tracing/01-tempostack.yaml

# 2. Deploy OpenTelemetryCollector
oc apply -f manifests/03-tracing/02-otel-collector.yaml
```

Wait for the tracing infrastructure to reach ready state:
```bash
# Check Tempo distributor, querier, and ingester pods
oc get pods -n tracing

# Check OpenTelemetry Collector deployment
oc get deployment otel-collector -n tracing
```

---

## 7. Deploy Auto-Instrumentation & Microservices

### Step 7.1: Build Container Images
You have two options:

#### Option A: In-Cluster Binary Builds (Recommended — No local compiler or Docker needed)
```bash
./scripts/build-images.sh oc-build
```

#### Option B: Local Podman Build & Push
```bash
./scripts/build-images.sh podman
```

### Step 7.2: Deploy Application Stack
```bash
# 1. Create application namespace
oc apply -f manifests/04-apps/00-namespace.yaml

# 2. Deploy Instrumentation CR
oc apply -f manifests/03-tracing/03-instrumentation.yaml

# 3. Deploy the 4 microservices
oc apply -f manifests/04-apps/01-go-worker.yaml
oc apply -f manifests/04-apps/02-python-inventory.yaml
oc apply -f manifests/04-apps/03-java-order.yaml
oc apply -f manifests/04-apps/04-nodejs-frontend.yaml

# 4. Deploy Prometheus ServiceMonitor
oc apply -f manifests/04-apps/05-service-monitor.yaml
```

Check the status of all pods:
```bash
oc get pods -n observability-demo -w
```
All four pods should show `1/1` (or `2/2` for auto-instrumented pods with injected sidecars) in `Running` status.

---

## 8. Access the User Interfaces

Retrieve the external OpenShift route URLs:

```bash
# Frontend Web UI:
echo "https://$(oc get route frontend -n observability-demo -o jsonpath='{.spec.host}')"

# Jaeger / Tempo Query UI:
echo "https://$(oc get route -n tracing -l app.kubernetes.io/component=query-frontend -o jsonpath='{.items[0].spec.host}')"

# OpenShift Web Console:
echo "https://console-openshift-console.apps-crc.testing"
```

---

## 9. Live Chaos Troubleshooting Demonstration

### 9.1 Healthy Baseline Transaction
1. Open the Frontend Web UI in your browser.
2. Leave the "Inject 4-Second Latency Bug" toggle **OFF**.
3. Click **Execute Polyglot Transaction**.
4. Result:
   - **HTTP 200 OK** in ~50–80ms.
   - Click **Open Waterfall Trace in Tempo / Jaeger** to view the healthy 4-tier span waterfall.

### 9.2 Triggering the Chaos Latency Bug
1. In the Frontend Web UI, toggle **Inject 4-Second Latency Bug** to **ON**.
2. Click **Execute Polyglot Transaction**.
3. The request cascades:
   `Frontend (Node.js) -> Order (Java) -> Inventory (Python) -> Worker (Go)`.
4. Inside `worker-go`, execution hangs for **4,000ms**.
5. The Node.js frontend SLA timeout threshold is **3,000ms**:
   - Node.js cancels the pending downstream socket.
   - Frontend returns **HTTP 504 Gateway Timeout**.
   - Round-trip latency displays ~3,005ms.

### 9.3 Executing the Diagnostic Trail

#### Step 1: Metric Spike in OpenShift Web Console
1. Open OpenShift Web Console (`https://console-openshift-console.apps-crc.testing`).
2. Navigate to **Observe -> Metrics**.
3. Run the following PromQL queries:
   ```promql
   # Observe 504 SLA violations
   sum(rate(http_requests_total{status="504"}[1m])) by (service)

   # Observe latency spike across services
   histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[1m])) by (le, service))
   ```
4. Observe the immediate jump from 0 to 100% 5xx errors.

#### Step 2: Correlate via Trace ID
1. In the Frontend UI results card, click **Copy** next to the **OpenTelemetry Trace ID**.
2. Open the **Tempo / Jaeger UI** route.
3. Paste the Trace ID directly into the search bar:
   `https://<jaeger-route>/trace/<YOUR_TRACE_ID>`

#### Step 3: Drill Down into the Waterfall Trace
1. Expand the trace tree:
   - `frontend-node`: `HTTP POST /api/order` (Error: canceled / timeout after 3000ms).
   - `order-service`: `HTTP POST /orders` (In-flight).
   - `inventory-service`: `HTTP POST /reserve` (In-flight).
   - `worker-go`: `HTTP POST /process` -> `dispatch_fulfillment`.
2. Inspect `dispatch_fulfillment`:
   - Duration: **4.00s**.
   - Span Event: `latency_chaos_injected`.
   - Attribute: `delay_ms = 4000`, `performance.bottleneck = CRITICAL_BOTTLENECK_DETECTED`.
3. Root cause isolated: **Zero guesswork, zero log grepping across four pods.**

---

## 10. OpenShift Local (CRC) Optimization & Troubleshooting

### Memory Pressure Checklist
If CRC pods enter `OOMKilled` or nodes show `DiskPressure`:

1. **Check Node Resource Utilization:**
   ```bash
   oc adm top nodes
   oc adm top pods -A --sort-by=memory
   ```

2. **Java Memory Tuning:**
   The Order Service is configured with:
   `-Xms64m -Xmx192m -XX:+UseSerialGC -XX:MaxRAMPercentage=75`
   Do not increase heap limits on single-node CRC.

3. **Prune Unused Images:**
   ```bash
   oc adm prune images --confirm || true
   podman system prune -a -f || true
   ```

4. **Restart Clean:**
   ```bash
   crc stop
   crc start
   ```
