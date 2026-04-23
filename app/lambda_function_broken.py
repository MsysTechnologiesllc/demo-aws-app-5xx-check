import json
import time


def lambda_handler(event, context):
    """Broken v2 — /api/checkout raises an unhandled exception (simulates a bad deploy)."""
    path = event.get("rawPath", "/")

    if path == "/health":
        # Health endpoint still returns 200 so readiness check passes
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"status": "ok", "version": "v2", "timestamp": int(time.time())}),
        }

    if path == "/api/products":
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps([
                {"id": 1, "name": "Widget A", "price": 9.99, "stock": 100},
            ]),
        }

    if path == "/api/checkout":
        # BUG introduced in v2: cart_service was refactored but checkout was not updated.
        # Explicitly return 500 so API Gateway records it in the 5XXError CloudWatch metric.
        try:
            cart_service = None
            cart = cart_service.get_cart()  # AttributeError
            return {"statusCode": 200, "body": json.dumps({"order_id": cart["order_id"]})}
        except Exception as exc:
            return {
                "statusCode": 500,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps({
                    "error": "Internal Server Error",
                    "message": f"NullPointerException: cart_service.get_cart() returned None — {exc}",
                    "path": "/api/checkout",
                }),
            }

    return {
        "statusCode": 404,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": "Not found", "path": path}),
    }
