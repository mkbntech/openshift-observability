package com.example.orderservice.client;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

import java.util.Map;

@Component
public class InventoryClient {

    private static final Logger log = LoggerFactory.getLogger(InventoryClient.class);
    private final RestClient restClient;
    private final String inventoryServiceUrl;

    public InventoryClient(RestClient restClient,
                           @Value("${inventory.service.url}") String inventoryServiceUrl) {
        this.restClient = restClient;
        this.inventoryServiceUrl = inventoryServiceUrl;
    }

    public Map<String, Object> reserveStock(Long orderId, String item, int quantity, String simulateLatency) {
        log.info("Contacting downstream Inventory Service at {} for Order ID: {}", inventoryServiceUrl, orderId);

        Map<String, Object> requestPayload = Map.of(
                "orderId", orderId,
                "item", item,
                "quantity", quantity
        );

        return restClient.post()
                .uri(inventoryServiceUrl)
                .contentType(MediaType.APPLICATION_JSON)
                .headers(headers -> {
                    if (simulateLatency != null && !simulateLatency.isBlank()) {
                        headers.add("X-Simulate-Latency", simulateLatency);
                    }
                })
                .body(requestPayload)
                .retrieve()
                .body(Map.class);
    }
}
