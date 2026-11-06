package com.example.orderservice.controller;

import com.example.orderservice.client.InventoryClient;
import com.example.orderservice.model.PurchaseOrder;
import com.example.orderservice.repository.OrderRepository;
import io.opentelemetry.api.trace.Span;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;

import java.util.HashMap;
import java.util.Map;

@RestController
public class OrderController {

    private static final Logger log = LoggerFactory.getLogger(OrderController.class);
    private final OrderRepository orderRepository;
    private final InventoryClient inventoryClient;

    public OrderController(OrderRepository orderRepository, InventoryClient inventoryClient) {
        this.orderRepository = orderRepository;
        this.inventoryClient = inventoryClient;
    }

    @GetMapping("/healthz")
    public ResponseEntity<Map<String, String>> healthz() {
        return ResponseEntity.ok(Map.of("status", "UP", "service", "order-service"));
    }

    @PostMapping("/orders")
    public ResponseEntity<Map<String, Object>> createOrder(
            @RequestBody PurchaseOrder order,
            @RequestHeader(value = "X-Simulate-Latency", required = false) String simulateLatency) {

        String traceId = Span.current().getSpanContext().getTraceId();
        log.info("Processing order for item: {} (qty: {}). Trace ID: {}, LatencySim: {}",
                order.getItem(), order.getQuantity(), traceId, simulateLatency);

        // 1. Save order to H2 in-memory database
        PurchaseOrder savedOrder = orderRepository.save(order);
        log.info("Persisted order with ID: {} to local H2 database", savedOrder.getId());

        // 2. Cascade transaction to downstream Python Inventory Service
        Map<String, Object> inventoryResponse = inventoryClient.reserveStock(
                savedOrder.getId(),
                savedOrder.getItem(),
                savedOrder.getQuantity() != null ? savedOrder.getQuantity() : 1,
                simulateLatency
        );

        // 3. Mark status confirmed
        savedOrder.setStatus("CONFIRMED");
        orderRepository.save(savedOrder);

        // 4. Return aggregated response
        Map<String, Object> response = new HashMap<>();
        response.put("orderId", savedOrder.getId());
        response.put("status", savedOrder.getStatus());
        response.put("item", savedOrder.getItem());
        response.put("quantity", savedOrder.getQuantity());
        response.put("price", savedOrder.getPrice());
        response.put("traceId", traceId);
        response.put("database", "H2 (in-memory)");
        response.put("inventory", inventoryResponse);

        return ResponseEntity.ok(response);
    }
}
