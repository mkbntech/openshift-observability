const express = require('express');
const path = require('path');
const axios = require('axios');
let trace;
try {
  ({ trace } = require('/otel-auto-instrumentation-nodejs/node_modules/@opentelemetry/api'));
} catch {
  ({ trace } = require('@opentelemetry/api'));
}

const app = express();
const PORT = process.env.PORT || 3000;
const ORDER_SERVICE_URL = process.env.ORDER_SERVICE_URL || 'http://order-service:8080/orders';
const JAEGER_UI_URL = process.env.JAEGER_UI_URL || 'https://tempo-tempo-query-frontend-tracing.apps-crc.testing';
const REQUEST_TIMEOUT_MS = parseInt(process.env.REQUEST_TIMEOUT_MS || '3000', 10);

// In-memory Prometheus metrics counters/histograms for /metrics
const requestCounts = { '200': 0, '502': 0, '504': 0 };
const durationBuckets = [0.05, 0.1, 0.25, 0.5, 1, 2.5, 3, 5, 10];
const bucketCounts = durationBuckets.map(() => 0);
let durationSum = 0;
let durationCount = 0;

function recordMetrics(statusCode, durationSeconds) {
  const key = String(statusCode);
  requestCounts[key] = (requestCounts[key] || 0) + 1;
  durationSum += durationSeconds;
  durationCount += 1;
  for (let i = 0; i < durationBuckets.length; i++) {
    if (durationSeconds <= durationBuckets[i]) {
      bucketCounts[i] += 1;
    }
  }
}

app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));
app.use(express.static(path.join(__dirname, 'public')));
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Helper to get current trace ID from OpenTelemetry active span
function getCurrentTraceId() {
  const activeSpan = trace.getActiveSpan();
  if (activeSpan) {
    const spanContext = activeSpan.spanContext();
    if (spanContext && spanContext.traceId) {
      return spanContext.traceId;
    }
  }
  return null;
}

// Render main UI page
app.get('/', (req, res) => {
  res.render('index', {
    orderServiceUrl: ORDER_SERVICE_URL,
    jaegerUiUrl: JAEGER_UI_URL,
    requestTimeoutMs: REQUEST_TIMEOUT_MS
  });
});

// Health check endpoint for OpenShift probes
app.get('/healthz', (req, res) => {
  res.status(200).json({ status: 'UP', service: 'frontend-node' });
});

// Prometheus metrics endpoint
app.get('/metrics', (req, res) => {
  const lines = [
    '# HELP http_requests_total Total number of HTTP requests processed by frontend-node.',
    '# TYPE http_requests_total counter'
  ];
  for (const [status, count] of Object.entries(requestCounts)) {
    lines.push(`http_requests_total{service="frontend-node",status="${status}"} ${count}`);
  }
  lines.push(
    '# HELP http_request_duration_seconds HTTP request duration in seconds.',
    '# TYPE http_request_duration_seconds histogram'
  );
  for (let i = 0; i < durationBuckets.length; i++) {
    lines.push(`http_request_duration_seconds_bucket{service="frontend-node",le="${durationBuckets[i]}"} ${bucketCounts[i]}`);
  }
  lines.push(`http_request_duration_seconds_bucket{service="frontend-node",le="+Inf"} ${durationCount}`);
  lines.push(`http_request_duration_seconds_sum{service="frontend-node"} ${durationSum}`);
  lines.push(`http_request_duration_seconds_count{service="frontend-node"} ${durationCount}`);
  res.set('Content-Type', 'text/plain; version=0.0.4').send(lines.join('\n') + '\n');
});

// API endpoint that triggers the 4-tier microservice chain
app.post('/api/order', async (req, res) => {
  const startTime = Date.now();
  const currentTraceId = getCurrentTraceId();
  
  const {
    item = 'OpenShift Enterprise Worker Node',
    quantity = 1,
    price = 1250.00,
    simulateLatency = false
  } = req.body;

  const orderPayload = {
    item,
    quantity: Number(quantity),
    price: Number(price),
    orderDate: new Date().toISOString(),
    customerEmail: 'devops-lead@enterprise.local'
  };

  const headers = {
    'Content-Type': 'application/json'
  };

  // Forward latency chaos simulation flag to downstream services
  if (simulateLatency === true || simulateLatency === 'true' || req.query.latency === 'true') {
    headers['X-Simulate-Latency'] = 'true';
  }

  try {
    const response = await axios.post(ORDER_SERVICE_URL, orderPayload, {
      headers,
      timeout: REQUEST_TIMEOUT_MS // Strict SLA limit to trigger 504 when bug is enabled
    });

    const elapsedMs = Date.now() - startTime;
    recordMetrics(200, elapsedMs / 1000);
    const finalTraceId = getCurrentTraceId() || currentTraceId || (response.data && response.data.traceId) || 'unknown';

    return res.status(200).json({
      status: 'success',
      statusCode: 200,
      elapsedMs,
      traceId: finalTraceId,
      jaegerTraceUrl: `${JAEGER_UI_URL}/trace/${finalTraceId}`,
      data: response.data
    });
  } catch (error) {
    const elapsedMs = Date.now() - startTime;
    const finalTraceId = getCurrentTraceId() || currentTraceId || 'unknown';

    if (error.code === 'ECONNABORTED' || (error.message && error.message.includes('timeout'))) {
      recordMetrics(504, elapsedMs / 1000);
      console.error(`[TIMEOUT] SLA violation: Request to downstream Order Service timed out after ${elapsedMs}ms. Trace ID: ${finalTraceId}`);
      return res.status(504).json({
        status: 'error',
        statusCode: 504,
        error: 'Gateway Timeout',
        message: `Downstream service processing exceeded the strict SLA timeout threshold of ${REQUEST_TIMEOUT_MS}ms.`,
        elapsedMs,
        traceId: finalTraceId,
        jaegerTraceUrl: `${JAEGER_UI_URL}/trace/${finalTraceId}`,
        details: error.message
      });
    }

    console.error(`[ERROR] Downstream call failed: ${error.message}. Trace ID: ${finalTraceId}`);
    const statusCode = error.response ? error.response.status : 502;
    recordMetrics(statusCode, elapsedMs / 1000);
    return res.status(statusCode).json({
      status: 'error',
      statusCode,
      error: 'Downstream Service Error',
      message: error.message,
      elapsedMs,
      traceId: finalTraceId,
      jaegerTraceUrl: `${JAEGER_UI_URL}/trace/${finalTraceId}`,
      downstreamResponse: error.response ? error.response.data : null
    });
  }
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Frontend Node.js service running on http://0.0.0.0:${PORT}`);
  console.log(`Targeting Order Service at: ${ORDER_SERVICE_URL}`);
  console.log(`SLA Timeout configured at: ${REQUEST_TIMEOUT_MS}ms`);
});
