# Post-Deployment Validation Orchestration — Plan

## Overview

Demo use case: a simple AWS Lambda + API Gateway app is "deployed" with a broken version that returns HTTP 5xx on `/api/checkout`. CloudWatch detects the spike, fires a webhook to Aziron, and the flow runs a full validation suite — health checks, CloudWatch metric analysis, integration tests — then posts a NO-GO verdict as a GitHub PR comment and publishes a result metric back to CloudWatch.

---

## AWS Account Context

- **Account**: 267767410086
- **Region**: us-east-1
- **Existing relevant resources**:
  - Lambda `cloudwatch-to-jira-webhook` — routes CloudWatch alarms to Jira (keep untouched)
  - EventBridge rule `cloudwatch-alarm-to-jira` — watching named alarms → Jira Lambda
  - Lambda `Failure-Simulation` — sends bad SQS messages (unrelated, don't touch)

---

## What Will Be Created

### 1. GitHub Repository

**URL**: `https://github.com/MsysTechnologiesllc/demo-aws-app-5xx-check`

**Local clone path**: `/Users/damirdarasu/workspace/Aziron/tests/flow-json/CI/CD-Build-Failure/demo-aws-app-5xx-check/`

**Repo structure**:
```
demo-aws-app-5xx-check/
├── README.md
├── app/
│   ├── lambda_function.py       # stable version (v1) — all 200s
│   └── lambda_function_broken.py # broken version (v2) — /api/checkout → 500
├── infra/
│   ├── cloudformation.yaml      # full stack: Lambda + API GW + alarms + EventBridge
│   └── deploy.sh                # CLI script: package, deploy, simulate bad deploy
├── tests/
│   └── integration_test.py      # smoke test invoked by Aziron flow
├── flow.json                    # Aziron Post-Deployment Validation flow
└── agent.json                   # Aziron AWS Validation Agent definition
```

---

### 2. The Demo App (Lambda + API Gateway)

**Lambda function name**: `demo-aws-5xx-app`
**Runtime**: Python 3.12
**Region**: us-east-1

**Endpoints via API Gateway HTTP API**:

| Endpoint | Stable (v1) | Broken (v2) |
|---|---|---|
| `GET /health` | `200 {"status": "ok"}` | `200 {"status": "ok"}` (always healthy) |
| `GET /api/products` | `200 [{"id":1,"name":"Widget"}]` | `200` (unchanged) |
| `GET /api/checkout` | `200 {"order_id": "ord-123", "status": "confirmed"}` | `500 {"error": "NullPointerException in checkout handler"}` |

**Lambda aliases**:
- `stable` → v1 (working)
- `live` → updated to v2 to simulate a bad deploy

**API Gateway**: HTTP API (v2) — cheaper, faster, no resources/methods complexity
- Base URL: `https://{api-id}.execute-api.us-east-1.amazonaws.com`
- Routes all point to Lambda alias `live`

---

### 3. AWS Infrastructure (CloudFormation)

**Stack name**: `demo-aws-5xx-check`

Resources:
```
1. IAM Role          demo-5xx-lambda-role
                     → AWSLambdaBasicExecutionRole
                     → cloudwatch:PutMetricData (for publishing validation results)

2. Lambda Function   demo-aws-5xx-app
                     Runtime: python3.12
                     Handler: lambda_function.lambda_handler
                     Timeout: 10s

3. Lambda Version    v1 (stable publish)
   Lambda Alias      live  → v1 initially

4. HTTP API          demo-5xx-api (API Gateway v2)
   Stage             $default (auto-deploy)
   Integration       Lambda proxy → alias ARN (live)
   Routes            GET /health, GET /api/products, GET /api/checkout

5. Lambda Permission Allow API GW to invoke demo-aws-5xx-app

6. CloudWatch Alarm  demo-5xx-ApiGw5xxAlarm
                     Namespace: AWS/ApiGateway
                     Metric: 5XXError
                     Dimension: ApiId = {api-id}
                     Period: 60s | Threshold: 3 | EvaluationPeriods: 1
                     ComparisonOperator: GreaterThanThreshold
                     TreatMissingData: notBreaching

7. EventBridge Rule  demo-5xx-alarm-to-aziron
                     EventPattern:
                       source: aws.cloudwatch
                       detail-type: CloudWatch Alarm State Change
                       detail.alarmName: [demo-5xx-ApiGw5xxAlarm]
                       detail.state.value: [ALARM]
                     Target: Lambda demo-5xx-aziron-forwarder

8. Lambda Function   demo-5xx-aziron-forwarder
                     Forwards EventBridge alarm events to Aziron webhook
                     Env: AZIRON_WEBHOOK_URL (set after Aziron flow is created)

9. Lambda Permission Allow EventBridge to invoke forwarder
```

**Deployment script steps** (`infra/deploy.sh`):
```bash
# Step 1: Deploy CloudFormation stack (creates all infra)
# Step 2: Publish stable Lambda version, update alias live → v1
# Step 3: [Demo trigger] Update Lambda code to broken version, publish v2, update alias live → v2
# Step 4: Hit /api/checkout 10 times to generate 5xx → triggers alarm → Aziron flow runs
# Step 5: [Reset] Restore stable version, update alias live → v1
```

---

### 4. Aziron Flow

**Flow name**: `AWS Post-Deployment Validation`
**File**: `flow.json` (in repo) + registered in Aziron

**Nodes**:

```
webhook_receive_deploy_alert     [start / webhook trigger]
    │
parse_alarm_event                [code_block]
    Extracts: alarm_name, api_id, deploy_time, region from EventBridge payload
    │
notify_validation_started        [notification]
    "Validation started for demo-aws-5xx-app after alarm: {alarm_name}"
    │
    ├────────────────────┬────────────────────────────────────┐
    ▼                    ▼                                    ▼
check_health_endpoint    get_cloudwatch_5xx_metrics           run_integration_tests
[agent_call]             [agent_call]                         [agent_call]
HTTP GET /health         cloudwatch_get_metric_statistics     lambda_invoke integration_test.py
Returns: status, ms      5XXError last 10min, per-minute      Returns: pass/fail per endpoint
    │                    │                                    │
    └────────────────────┴────────────────────────────────────┘
                         │
              normalize_validation_results   [code_block]
              Merges all three outputs into single object
                         │
              ai_validation_analysis         [agent_call]
              Correlates results, detects regression,
              generates GO/NO-GO verdict + summary
                         │
              check_validation_result        [if_else]
              condition: steps.ai_validation_analysis.output.output.verdict == "GO"
                    │                    │
                   PASS               FAIL
                    │                    │
                    ▼                    ▼
          post_pr_comment_pass    post_pr_comment_fail
          [agent_call]            [agent_call]
          ✅ Validation passed    ❌ Validation FAILED
          github_create_pr_       github_create_pr_
          comment                 comment with details
                    │                    │
                    └──────────┬─────────┘
                               ▼
                  publish_validation_metric   [agent_call]
                  cloudwatch_put_metric_data
                  Namespace: Aziron/DeployValidation
                  Metric: ValidationResult (1=pass, 0=fail)
                               │
                  notify_complete            [notification]
                  "Validation complete: {verdict} for demo-aws-5xx-app"
```

**Connections**: 22 nodes total, parallel execution for the 3 validation checks.

---

### 5. Aziron Agent

**Agent name**: `AWS Deployment Validation Agent`
**File**: `agent.json` (in repo)

**Tools needed**:
- `cloudwatch_get_metric_statistics` — fetch 5xx rate from API Gateway namespace
- `cloudwatch_put_metric_data` — publish validation result metric
- `lambda_invoke` — invoke integration test Lambda
- `github_create_pull_request` / `github_create_or_update_file` — PR comment
- HTTP tool (built-in) — health/readiness endpoint checks

**AWS credentials**: passed via flow variables (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION)

---

### 6. Integration Test Lambda

**Function name**: `demo-5xx-integration-tests` (new, deployed by CloudFormation)

What it does:
- Hits `/health`, `/api/products`, `/api/checkout` on the API GW
- Returns structured JSON: `{ "tests": [ {"name": "...", "status": "pass|fail", "http_code": 200, "latency_ms": 45} ] }`
- Callable by Aziron agent via `lambda_invoke`

---

## Execution Order (when ready to build)

1. **Create GitHub repo** (gh CLI or GitHub API)
2. **Write app code**: `lambda_function.py` (stable), `lambda_function_broken.py` (broken)
3. **Write CloudFormation**: `infra/cloudformation.yaml`
4. **Write deploy script**: `infra/deploy.sh`
5. **Write integration test**: `tests/integration_test.py`
6. **Deploy CloudFormation stack**: creates all AWS infra
7. **Register Aziron flow** → get webhook URL
8. **Update forwarder Lambda** with Aziron webhook URL env var
9. **Write `flow.json`** with real API IDs filled in
10. **Write `agent.json`**
11. **Write `README.md`**
12. **Push all to GitHub**
13. **Test**: run `deploy.sh` step 3 (bad deploy) → verify alarm fires → verify Aziron flow runs → verify PR comment posted

---

## Open Questions (to confirm before building)

1. **Aziron webhook base URL** — what is the Aziron server URL the forwarder should POST to?
2. **GitHub repo** — which org token to use for creating the repo and posting PR comments?
3. **AWS CloudWatch tools in aziron-mcp** — do `cloudwatch_get_metric_statistics` and `cloudwatch_put_metric_data` exist, or do they need to be added?
4. **Region confirmation** — build everything in `us-east-1` (where other demo resources live)?
