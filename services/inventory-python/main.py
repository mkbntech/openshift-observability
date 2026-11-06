import os
import logging
from typing import Optional
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel
import httpx
from opentelemetry import trace

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("inventory-service")

app = FastAPI(title="Inventory Service", version="1.0.0")

WORKER_SERVICE_URL = os.getenv("WORKER_SERVICE_URL", "http://worker-service:8090/process")

class ReservationRequest(BaseModel):
    orderId: int
    item: str
    quantity: int

class ReservationResponse(BaseModel):
    status: str
    orderId: int
    item: str
    warehouse: str
    traceId: Optional[str]
    worker: Optional[dict]

@app.get("/healthz")
async def healthz():
    return {"status": "UP", "service": "inventory-python"}

@app.post("/reserve", response_model=ReservationResponse)
async def reserve_inventory(
    req: ReservationRequest,
    x_simulate_latency: Optional[str] = Header(None, alias="X-Simulate-Latency")
):
    current_span = trace.get_current_span()
    trace_id = format(current_span.get_span_context().trace_id, "032x") if current_span else "unknown"

    logger.info(
        f"Reserving {req.quantity}x '{req.item}' for Order #{req.orderId} (Trace: {trace_id}, LatencySim: {x_simulate_latency})"
    )

    # Forward to the Go Ingestion/Worker microservice
    headers = {"Content-Type": "application/json"}
    if x_simulate_latency:
        headers["X-Simulate-Latency"] = x_simulate_latency

    worker_payload = {
        "orderId": req.orderId,
        "item": req.item,
        "quantity": req.quantity,
        "action": "FULFILL_AND_DISPATCH"
    }

    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.post(WORKER_SERVICE_URL, json=worker_payload, headers=headers)
            resp.raise_for_status()
            worker_data = resp.json()
    except httpx.HTTPError as exc:
        logger.error(f"Downstream call to Worker service failed: {exc}")
        raise HTTPException(status_code=502, detail=f"Worker service communication failure: {str(exc)}")

    return ReservationResponse(
        status="RESERVED",
        orderId=req.orderId,
        item=req.item,
        warehouse="crc-east-datacenter",
        traceId=trace_id,
        worker=worker_data
    )

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=False)
