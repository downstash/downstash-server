# WStash Design Document

## Context

WStash is a distributed job queue system designed to provide reliable message delivery and processing with multi-tenancy support. The system allows clients to queue HTTP requests for later execution, with support for retries, rate limiting, and URL grouping.

## System Architecture Overview

The system consists of two main components:
1. A Rust-based worker node for processing jobs
2. A TypeScript-based API layer for job management

### High-Level Requirements

1. Multi-tenant support with complete isolation
2. Reliable message delivery with retries
3. Rate limiting at multiple levels
4. Request signing and verification
5. Dead letter queue for failed jobs
6. URL Groups for endpoint management
7. Comprehensive monitoring and metrics
8. Horizontal scalability

## Part 1: Worker Node (Rust)

### Data Models

#### Job Structure
```rust
struct Job {
    id: String,
    tenant_id: String,
    queue_id: String,
    url: String,
    method: HttpMethod,
    headers: HashMap<String, String>,
    body: Option<Vec<u8>>,
    retries_left: u32,
    created_at: DateTime<Utc>,
    next_execution: DateTime<Utc>,
    status: JobStatus,
    error_log: Vec<JobError>,
    url_group_id: Option<String>,
    timeout: Duration,
}

enum JobStatus {
    Pending,
    InProgress,
    Completed,
    Failed,
    Cancelled,
}

struct JobError {
    timestamp: DateTime<Utc>,
    error: String,
    status_code: Option<u16>,
    response_body: Option<String>,
}
```

#### Queue Structure
```rust
struct Queue {
    id: String,
    tenant_id: String,
    name: String,
    enabled: bool,
    max_concurrent_requests: u32,
    default_retry_count: u32,
    default_timeout: Duration,
    priority: Option<u8>,
    url_group_id: Option<String>,
}
```

#### URL Group Structure
```rust
struct UrlGroup {
    id: String,
    tenant_id: String,
    name: String,
    description: Option<String>,
    base_url: Option<String>,
    default_headers: HashMap<String, String>,
    auth_config: AuthConfig,
    retry_policy: RetryPolicy,
    rate_limits: RateLimits,
    ip_allowlist: Vec<IpNet>,
    circuit_breaker: CircuitBreakerConfig,
    health_check: HealthCheckConfig,
}

struct AuthConfig {
    auth_type: AuthType,
    credentials: Credentials,
}

struct RetryPolicy {
    max_retries: u32,
    initial_delay: Duration,
    max_delay: Duration,
    jitter: f64,
}

struct RateLimits {
    requests_per_second: u32,
    concurrent_requests: u32,
}

struct CircuitBreakerConfig {
    error_threshold: f64,
    trip_duration: Duration,
    half_open_max_requests: u32,
}

struct HealthCheckConfig {
    endpoint: String,
    interval: Duration,
    timeout: Duration,
    success_criteria: HealthCheckCriteria,
}
```

### Core Components

#### Job Processor
```rust
struct JobProcessor {
    redis: Arc<Redis>,
    http_client: Arc<HttpClient>,
    circuit_breakers: Arc<CircuitBreakerRegistry>,
    rate_limiters: Arc<RateLimiterRegistry>,
}

impl JobProcessor {
    async fn process_job(&self, job: Job) -> Result<(), JobError> {
        // Check URL group configuration
        let url_group = self.get_url_group(job.url_group_id).await?;
        
        // Apply rate limiting
        self.check_rate_limits(&job, &url_group).await?;
        
        // Check circuit breaker
        if let Some(ref group) = url_group {
            self.check_circuit_breaker(group).await?;
        }
        
        // Build and sign request
        let request = self.build_request(&job, &url_group).await?;
        
        // Execute request
        let result = self.execute_request(request).await;
        
        // Handle result
        match result {
            Ok(response) => self.handle_success(job, response).await,
            Err(e) => self.handle_error(job, e).await,
        }
    }
}
```

#### Circuit Breaker
```rust
struct CircuitBreaker {
    state: AtomicEnum<CircuitState>,
    failure_count: AtomicUsize,
    last_failure: AtomicInstant,
    settings: CircuitBreakerSettings,
}

impl CircuitBreaker {
    async fn check_state(&self) -> Result<(), Error> {
        match self.state.load() {
            CircuitState::Closed => Ok(()),
            CircuitState::Open => {
                if self.should_transition_to_half_open().await {
                    self.state.store(CircuitState::HalfOpen);
                    Ok(())
                } else {
                    Err(Error::CircuitBreakerOpen)
                }
            }
            CircuitState::HalfOpen => {
                if self.should_allow_request().await {
                    Ok(())
                } else {
                    Err(Error::CircuitBreakerOpen)
                }
            }
        }
    }
}
```

#### Rate Limiter
```rust
struct RateLimiter {
    redis: Arc<Redis>,
    key: String,
    window: Duration,
    limit: u32,
}

impl RateLimiter {
    async fn check_rate_limit(&self) -> Result<(), Error> {
        let current = self.redis.incr(self.key).await?;
        if current > self.limit {
            Err(Error::RateLimitExceeded)
        } else {
            Ok(())
        }
    }
}
```

#### Health Checker
```rust
struct HealthChecker {
    http_client: Arc<HttpClient>,
    config: HealthCheckConfig,
}

impl HealthChecker {
    async fn check_health(&self) -> Result<HealthStatus, Error> {
        let response = self.http_client
            .get(&self.config.endpoint)
            .timeout(self.config.timeout)
            .send()
            .await?;
            
        self.validate_response(response).await
    }
}
```

## Part 2: API Layer (TypeScript)

### API Routes

#### Tenant Management
```typescript
interface TenantRoutes {
    create: Post<'/v1/tenants', CreateTenantRequest, Tenant>;
    get: Get<'/v1/tenants/:id', void, Tenant>;
    update: Put<'/v1/tenants/:id', UpdateTenantRequest, Tenant>;
    delete: Delete<'/v1/tenants/:id', void>;
    getUsage: Get<'/v1/tenants/:id/usage', void, TenantUsage>;
}
```

#### Queue Management
```typescript
interface QueueRoutes {
    create: Post<'/v1/queues', CreateQueueRequest, Queue>;
    get: Get<'/v1/queues/:id', void, Queue>;
    update: Put<'/v1/queues/:id', UpdateQueueRequest, Queue>;
    delete: Delete<'/v1/queues/:id', void>;
    list: Get<'/v1/tenants/:id/queues', void, Queue[]>;
    getMetrics: Get<'/v1/queues/:id/metrics', void, QueueMetrics>;
}
```

#### Job Management
```typescript
interface JobRoutes {
    create: Post<'/v1/jobs', CreateJobRequest, Job>;
    get: Get<'/v1/jobs/:id', void, Job>;
    cancel: Delete<'/v1/jobs/:id', void>;
    listByQueue: Get<'/v1/queues/:id/jobs', void, Job[]>;
    listByTenant: Get<'/v1/tenants/:id/jobs', void, Job[]>;
    createBatch: Post<'/v1/jobs/batch', CreateJobBatchRequest, Job[]>;
}
```

#### URL Group Management
```typescript
interface UrlGroupRoutes {
    create: Post<'/v1/url-groups', CreateUrlGroupRequest, UrlGroup>;
    get: Get<'/v1/url-groups/:id', void, UrlGroup>;
    update: Put<'/v1/url-groups/:id', UpdateUrlGroupRequest, UrlGroup>;
    delete: Delete<'/v1/url-groups/:id', void>;
    list: Get<'/v1/tenants/:id/url-groups', void, UrlGroup[]>;
    getMetrics: Get<'/v1/url-groups/:id/metrics', void, UrlGroupMetrics>;
    getHealth: Get<'/v1/url-groups/:id/health', void, HealthStatus>;
    updateAuth: Post<'/v1/url-groups/:id/auth', UpdateAuthRequest, void>;
    testAuth: Get<'/v1/url-groups/:id/auth/test', void, AuthTestResult>;
    updateRateLimits: Put<'/v1/url-groups/:id/rate-limits', UpdateRateLimitsRequest, void>;
    getRateLimits: Get<'/v1/url-groups/:id/rate-limits', void, RateLimitStatus>;
    getCircuitBreaker: Get<'/v1/url-groups/:id/circuit-breaker', void, CircuitBreakerStatus>;
    resetCircuitBreaker: Post<'/v1/url-groups/:id/circuit-breaker/reset', void, void>;
}
```

### Redis Schema

```
# Jobs
jobs:{tenant_id}:{queue_id}:{job_id} -> Hash
    url: string
    method: string
    headers: JSON string
    body: base64 string
    retries_left: number
    status: string
    created_at: ISO timestamp
    next_execution: ISO timestamp
    
jobs:pending:{queue_id} -> Sorted Set
    score: next_execution timestamp
    member: job_id
    
jobs:processing:{queue_id} -> Hash
    job_id: worker_id
    
jobs:failed:{tenant_id} -> List
    job_id

# Queues
queues:{tenant_id} -> Hash
    queue_id: JSON string of queue details

queues:metrics:{queue_id} -> Hash
    processed: number
    failed: number
    avg_processing_time: number

# URL Groups
urlgroups:{tenant_id} -> Hash
    group_id: JSON string of group details

urlgroups:auth:{group_id} -> Hash
    type: string
    credentials: encrypted string

urlgroups:metrics:{group_id} -> Hash
    success_count: number
    error_count: number
    total_latency: number

urlgroups:health:{group_id} -> Hash
    status: string
    last_check: ISO timestamp
    last_error: string

urlgroups:ratelimits:{group_id} -> Hash
    current_rps: number
    current_concurrent: number

urlgroups:circuit:{group_id} -> Hash
    state: string
    failure_count: number
    last_failure: ISO timestamp

# Tenants
tenants:{tenant_id} -> Hash
    name: string
    status: string
    created_at: ISO timestamp

tenants:usage:{tenant_id}:{yyyy-mm-dd} -> Hash
    processed_jobs: number
    failed_jobs: number
    total_requests: number
```

## Security Considerations

### Authentication & Authorization
- API key authentication for tenant access
- Role-based access control for API endpoints
- Tenant isolation in all data access
- Encrypted storage of sensitive data

### Request Signing
```rust
fn sign_request(request: &Request, secret_key: &[u8]) -> String {
    let mut data = Vec::new();
    data.extend_from_slice(request.method.as_str().as_bytes());
    data.extend_from_slice(request.url.as_bytes());
    data.extend_from_slice(&request.body);
    
    let mut mac = Hmac::<Sha256>::new_from_slice(secret_key)
        .expect("HMAC initialization failed");
    mac.update(&data);
    
    base64::encode(mac.finalize().into_bytes())
}
```

### Rate Limiting
- Per-tenant rate limits
- Per-queue rate limits
- Per-URL group rate limits
- Global system rate limits

## Deployment & Operations

### Infrastructure Requirements
- Redis cluster for job storage
- PostgreSQL for tenant and configuration data
- Load balancer for API distribution
- Kubernetes for worker deployment

### Monitoring & Alerts
```yaml
alerts:
  high_error_rate:
    condition: error_rate > 0.05
    duration: 5m
    severity: critical
    
  queue_lag:
    condition: queue_lag > 1000
    duration: 10m
    severity: warning
    
  circuit_breaker_trips:
    condition: circuit_breaker_trips > 5
    duration: 15m
    severity: warning
```

### Metrics Collection
- Queue depth and lag
- Processing success/failure rates
- Request latencies
- Error rates by URL group
- Circuit breaker status
- Rate limit usage

### Backup & Recovery
- Regular Redis snapshots
- Transaction logs
- Point-in-time recovery capability
- Regular disaster recovery testing

## Testing Strategy

### Unit Tests
```rust
#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn test_job_processing() {
        let processor = JobProcessor::new();
        let job = create_test_job();
        
        let result = processor.process_job(job).await;
        assert!(result.is_ok());
    }
    
    #[tokio::test]
    async fn test_circuit_breaker() {
        let breaker = CircuitBreaker::new(CircuitBreakerSettings::default());
        
        // Test transition to open state
        for _ in 0..10 {
            breaker.record_failure().await;
        }
        
        assert_eq!(breaker.state.load(), CircuitState::Open);
    }
}
```

### Integration Tests
```typescript
describe('URL Group Integration', () => {
    it('should correctly apply rate limits', async () => {
        const group = await createTestUrlGroup();
        const results = await Promise.all(
            Array(10).fill(0).map(() => sendTestRequest(group))
        );
        
        expect(results.filter(r => r.status === 429).length).toBeGreaterThan(0);
    });
});
```

### Load Tests
```typescript
import { check } from 'k6';
import http from 'k6/http';

export const options = {
    scenarios: {
        high_load: {
            executor: 'ramping-vus',
            startVUs: 0,
            stages: [
                { duration: '2m', target: 100 },
                { duration: '5m', target: 100 },
                { duration: '2m', target: 0 },
            ],
        },
    },
};

export default function() {
    const res = http.post('http://api.wstash.local/v1/jobs', {
        url: 'http://test-endpoint/api',
        method: 'POST',
        body: JSON.stringify({ test: true }),
    });
    
    check(res, {
        'status is 200': (r) => r.status === 200,
        'response time < 500ms': (r) => r.timings.duration < 500,
    });
}
```
