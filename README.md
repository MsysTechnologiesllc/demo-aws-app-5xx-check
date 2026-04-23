# demo-aws-app-5xx-check

Demo application for **Aziron Post-Deployment Validation Orchestration**.

A simple Lambda + API Gateway app that ships a "broken" v2 which causes 5xx errors on `/api/checkout`. CloudWatch detects the spike, fires a webhook to Aziron, and the validation flow runs automatically — producing a GitHub issue with a GO/NO-GO verdict.

---

## Architecture

```
bad-deploy (deploy.sh)
       │
       ▼
Lambda alias "live" → v2 (broken)
       │
  curl /api/checkout ×15 → HTTP 500
       │
       ▼
CloudWatch Alarm (5XXError > 3 / min)
       │  EventBridge rule
       ▼
Lambda: demo-5xx-aziron-forwarder
       │  POST
       ▼
Aziron Webhook ─────────────────────────────────────────────────────────┐
                                                                         │
┌──────────────────────────────────────────────────────────────────────┐ │
│  Aziron Flow: AWS Post-Deployment Validation                          │◄┘
│                                                                       │
│  parse_alarm_event                                                    │
│       │                                                               │
│  ┌────┴────────────────┐                                              │
│  ▼                     ▼                                ▼             │
│  check_health      get_cloudwatch_metrics      run_integration_tests  │
│  (curl endpoints)  (aws cloudwatch get-stats)  (lambda invoke tests)  │
│  └────────────────────────────┬────────────────────────┘             │
│                               ▼                                       │
│                   normalize_validation_results                        │
│                               │                                       │
│                   ai_validation_analysis                              │
│                               │                                       │
│                    ┌──────────┴──────────┐                           │
│                    ▼                     ▼                            │
│              ✅ GO                    🚨 NO-GO                        │
│           post_github_issue        post_github_issue                  │
│           (passed)                 (failed + rollback cmd)            │
│                    └──────────┬──────────┘                           │
│                               ▼                                       │
│                  publish_validation_metric                            │
│                  (Aziron/DeployValidation in CloudWatch)              │
└───────────────────────────────────────────────────────────────────────┘
```

---

## Repository Structure

```
demo-aws-app-5xx-check/
├── app/
│   ├── lambda_function.py          # Stable v1 — all endpoints 200
│   └── lambda_function_broken.py   # Broken v2 — /api/checkout → 500
├── infra/
│   ├── cloudformation.yaml         # Full AWS stack definition
│   ├── deploy.sh                   # Deploy + demo script
│   └── forwarder/
│       └── lambda_function.py      # EventBridge → Aziron forwarder
├── tests/
│   └── integration_test.py         # HTTP test runner (local or Lambda)
├── flow.json                       # Aziron validation flow definition
├── agent.json                      # Aziron validation agent definition
└── README.md
```

---

## Setup

### Prerequisites
- AWS CLI configured with account `267767410086`, region `us-east-1`
- Aziron server running at `https://aziron-bot.loca.lt`
- GitHub token with repo write access

### Step 1: Deploy AWS Infrastructure
```bash
chmod +x infra/deploy.sh
./infra/deploy.sh deploy
```

This creates:
- Lambda function `demo-aws-5xx-app` (stable v1)
- API Gateway HTTP API `demo-5xx-api`
- CloudWatch alarm `demo-5xx-ApiGw5xxAlarm`
- EventBridge rule → forwarder Lambda
- Integration test Lambda

### Step 2: Register Aziron Agent
Import `agent.json` into Aziron and note the agent ID.

### Step 3: Register Aziron Flow
1. Import `flow.json` into Aziron
2. Update `variables.agent_id` with the agent ID from Step 2
3. Update `variables.api_gw_url` and `variables.api_gw_id` from CloudFormation outputs
4. Copy the flow webhook URL from Aziron

### Step 4: Wire Up the Forwarder
```bash
./infra/deploy.sh set-webhook https://aziron-bot.loca.lt/api/v1/flows/<FLOW_ID>/trigger
```

### Step 5: Check Status
```bash
./infra/deploy.sh status
```

---

## Running the Demo

### Simulate a Bad Deployment
```bash
./infra/deploy.sh bad-deploy
```

This will:
1. Deploy broken v2 to Lambda (checkout returns 500)
2. Send 15 requests to `/api/checkout`
3. CloudWatch alarm fires within ~1 minute
4. Aziron flow triggers automatically

### Watch the Flow
Open the Aziron UI and watch the flow execute in real time.

### Expected Output
- GitHub issue created: **"🚨 Deployment Validation FAILED — demo-aws-5xx-app"**
- CloudWatch metric published: `Aziron/DeployValidation/ValidationResult = 0`

### Rollback
```bash
./infra/deploy.sh rollback
```

---

## API Endpoints

| Endpoint | Method | v1 (stable) | v2 (broken) |
|---|---|---|---|
| `/health` | GET | 200 `{"status":"ok","version":"v1"}` | 200 `{"status":"ok","version":"v2"}` |
| `/api/products` | GET | 200 `[{...}]` | 200 `[{...}]` |
| `/api/checkout` | POST | 200 `{"order_id":"ord-..."}` | **500** `NullPointerException` |

---

## Flow Variables to Configure

| Variable | Description | Example |
|---|---|---|
| `agent_id` | Aziron agent UUID | `abc123-...` |
| `api_gw_url` | API Gateway base URL | `https://xyz.execute-api.us-east-1.amazonaws.com` |
| `api_gw_id` | API Gateway ID (for CloudWatch) | `xyz123abc` |
| `aws_region` | AWS region | `us-east-1` |
| `aws_access_key_id` | AWS credentials | `AKIA...` |
| `aws_secret_access_key` | AWS credentials | `...` |
| `github_token` | GitHub PAT | `ghp_...` |
| `github_repo_url` | Repo URL | `https://github.com/MsysTechnologiesllc/demo-aws-app-5xx-check` |

---

## Teardown
```bash
./infra/deploy.sh destroy
```
