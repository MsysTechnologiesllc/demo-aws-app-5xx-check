#!/usr/bin/env python3
"""
Integration test runner for demo-aws-5xx-app.
Run locally: python3 tests/integration_test.py <api_gw_url>
Also invokeable as a Lambda function (for Aziron agent to call via aws_cli_execute lambda invoke).
"""
import json
import os
import sys
import time
import urllib.request
import urllib.error


def run_test(name, url, method="GET", body=None, expected_status=200):
    start = time.time()
    try:
        data = json.dumps(body).encode() if body else None
        headers = {"Content-Type": "application/json"} if data else {}
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        with urllib.request.urlopen(req, timeout=10) as resp:
            latency_ms = int((time.time() - start) * 1000)
            resp_body = resp.read().decode("utf-8")
            status = resp.status
    except urllib.error.HTTPError as e:
        latency_ms = int((time.time() - start) * 1000)
        status = e.code
        resp_body = e.read().decode("utf-8")
    except Exception as e:
        latency_ms = int((time.time() - start) * 1000)
        return {
            "name": name,
            "url": url,
            "status": "error",
            "error": str(e),
            "latency_ms": latency_ms,
        }

    passed = status == expected_status
    return {
        "name": name,
        "url": url,
        "http_code": status,
        "expected_code": expected_status,
        "latency_ms": latency_ms,
        "status": "pass" if passed else "fail",
        "response_preview": resp_body[:200],
    }


def run_all(base_url):
    results = [
        run_test("health_check", f"{base_url}/health", expected_status=200),
        run_test("products_list", f"{base_url}/api/products", expected_status=200),
        run_test(
            "checkout_order",
            f"{base_url}/api/checkout",
            method="POST",
            body={"item_id": 1, "qty": 1},
            expected_status=200,
        ),
    ]
    passed = sum(1 for r in results if r["status"] == "pass")
    failed = sum(1 for r in results if r["status"] != "pass")
    return {
        "total": len(results),
        "passed": passed,
        "failed": failed,
        "overall": "pass" if failed == 0 else "fail",
        "tests": results,
    }


def lambda_handler(event, context):
    """Lambda entry point — called by Aziron agent via aws_cli_execute lambda invoke."""
    base_url = event.get("api_gw_url") or os.environ.get("API_GW_URL", "")
    if not base_url:
        return {"statusCode": 400, "body": json.dumps({"error": "api_gw_url required"})}
    results = run_all(base_url)
    return {"statusCode": 200, "body": json.dumps(results)}


if __name__ == "__main__":
    base_url = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("API_GW_URL", "")
    if not base_url:
        print("Usage: python3 integration_test.py <api_gw_url>")
        sys.exit(1)
    results = run_all(base_url)
    print(json.dumps(results, indent=2))
    sys.exit(0 if results["overall"] == "pass" else 1)
