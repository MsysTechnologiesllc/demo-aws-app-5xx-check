import json
import time


def lambda_handler(event, context):
    path = event.get("rawPath", "/")

    if path == "/health":
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"status": "ok", "version": "v1", "timestamp": int(time.time())}),
        }

    if path == "/api/products":
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps([
                {"id": 1, "name": "Widget A", "price": 9.99, "stock": 100},
                {"id": 2, "name": "Widget B", "price": 19.99, "stock": 50},
                {"id": 3, "name": "Widget C", "price": 4.99, "stock": 200},
            ]),
        }

    if path == "/api/checkout":
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({
                "order_id": f"ord-{int(time.time())}",
                "status": "confirmed",
                "message": "Order placed successfully",
                "estimated_delivery": "2-3 business days",
            }),
        }

    return {
        "statusCode": 404,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": "Not found", "path": path}),
    }
