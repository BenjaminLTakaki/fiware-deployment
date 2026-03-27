// ============================================================================
// FIWARE Data Space Connector - K6 Load Testing Script
// ============================================================================
// This script performs load testing on FIWARE components for research purposes.
//
// Install K6:
//   https://k6.io/docs/getting-started/installation/
//
// Usage:
//   k6 run k6-fiware-test.js --env DOMAIN=192.168.1.100.nip.io
//   k6 run k6-fiware-test.js --env DOMAIN=192.168.1.100.nip.io --env SCENARIO=smoke
//   k6 run k6-fiware-test.js --env DOMAIN=192.168.1.100.nip.io --env SCENARIO=load
//   k6 run k6-fiware-test.js --env DOMAIN=192.168.1.100.nip.io --env SCENARIO=stress
// ============================================================================

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';
import { SharedArray } from 'k6/data';

// Custom metrics for research tracking
const errorRate = new Rate('errors');
const authLatency = new Trend('auth_latency', true);
const brokerLatency = new Trend('broker_latency', true);
const policyLatency = new Trend('policy_latency', true);
const successfulRequests = new Counter('successful_requests');
const failedRequests = new Counter('failed_requests');

// Configuration from environment
const DOMAIN = __ENV.DOMAIN || '127.0.0.1.nip.io';
const SCENARIO = __ENV.SCENARIO || 'smoke';
const PROXY = __ENV.PROXY || 'http://localhost:8888';

// Base URLs
const KEYCLOAK_PROVIDER = `https://keycloak-provider.${DOMAIN}`;
const KEYCLOAK_CONSUMER = `https://keycloak-consumer.${DOMAIN}`;
const SCORPIO_PROVIDER = `https://scorpio-provider.${DOMAIN}`;
const PAP_PROVIDER = `https://pap-provider.${DOMAIN}`;

// Test scenarios
const scenarios = {
  smoke: {
    executor: 'constant-vus',
    vus: 1,
    duration: '1m',
  },
  load: {
    executor: 'ramping-vus',
    startVUs: 0,
    stages: [
      { duration: '2m', target: 10 },   // Ramp up
      { duration: '5m', target: 10 },   // Steady state
      { duration: '2m', target: 20 },   // Peak
      { duration: '2m', target: 0 },    // Ramp down
    ],
  },
  stress: {
    executor: 'ramping-vus',
    startVUs: 0,
    stages: [
      { duration: '2m', target: 20 },
      { duration: '5m', target: 50 },
      { duration: '5m', target: 100 },
      { duration: '2m', target: 0 },
    ],
  },
  soak: {
    executor: 'constant-vus',
    vus: 10,
    duration: '30m',
  },
};

// Export options
export const options = {
  scenarios: {
    default: scenarios[SCENARIO] || scenarios.smoke,
  },
  thresholds: {
    http_req_duration: ['p(95)<2000'],  // 95% of requests under 2s
    http_req_failed: ['rate<0.1'],       // Less than 10% failure rate
    errors: ['rate<0.1'],                // Custom error rate
    auth_latency: ['p(95)<3000'],        // Auth under 3s
    broker_latency: ['p(95)<1000'],      // Broker queries under 1s
  },
  // TLS configuration for self-signed certs
  insecureSkipTLSVerify: true,
};

// HTTP request parameters
const params = {
  headers: {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  },
  timeout: '30s',
};

// Proxy configuration
const proxyParams = {
  ...params,
  // Note: K6 doesn't support proxy directly; run via proxychains or similar
};

// Helper function for authenticated requests
function getAccessToken(keycloakUrl, realm, clientId, username, password) {
  const tokenUrl = `${keycloakUrl}/realms/${realm}/protocol/openid-connect/token`;

  const tokenResponse = http.post(tokenUrl, {
    grant_type: 'password',
    client_id: clientId,
    username: username,
    password: password,
    scope: 'openid',
  }, {
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    timeout: '10s',
  });

  authLatency.add(tokenResponse.timings.duration);

  if (tokenResponse.status === 200) {
    const body = JSON.parse(tokenResponse.body);
    return body.access_token;
  }
  return null;
}

// Test setup
export function setup() {
  console.log(`Starting ${SCENARIO} test against domain: ${DOMAIN}`);

  // Verify services are accessible
  const healthChecks = [
    { name: 'Keycloak Provider', url: `${KEYCLOAK_PROVIDER}/health/ready` },
    { name: 'Scorpio Provider', url: `${SCORPIO_PROVIDER}/q/health` },
  ];

  let allHealthy = true;
  for (const check of healthChecks) {
    const res = http.get(check.url, { timeout: '10s' });
    if (res.status !== 200) {
      console.warn(`${check.name} not healthy: ${res.status}`);
      allHealthy = false;
    }
  }

  return { healthy: allHealthy, startTime: new Date().toISOString() };
}

// Main test function
export default function(data) {
  // Test Group 1: Keycloak Authentication
  group('Keycloak Authentication', function() {
    const startTime = Date.now();

    // Test token endpoint
    const tokenResponse = http.post(
      `${KEYCLOAK_CONSUMER}/realms/test-realm/protocol/openid-connect/token`,
      {
        grant_type: 'password',
        client_id: 'account-console',
        username: 'employee',
        password: 'test',
        scope: 'openid',
      },
      {
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        timeout: '10s',
      }
    );

    const duration = Date.now() - startTime;
    authLatency.add(duration);

    const success = check(tokenResponse, {
      'token endpoint returns 200': (r) => r.status === 200,
      'response contains access_token': (r) => {
        try {
          const body = JSON.parse(r.body);
          return body.access_token !== undefined;
        } catch {
          return false;
        }
      },
      'response time < 3000ms': (r) => r.timings.duration < 3000,
    });

    if (success) {
      successfulRequests.add(1);
    } else {
      failedRequests.add(1);
      errorRate.add(1);
    }
  });

  sleep(0.5);

  // Test Group 2: Scorpio Broker
  group('Scorpio Broker Queries', function() {
    const startTime = Date.now();

    // Query entities (no auth required for basic query)
    const entitiesResponse = http.get(
      `${SCORPIO_PROVIDER}/ngsi-ld/v1/entities?type=urn:ngsi-ld:Product`,
      {
        headers: {
          'Content-Type': 'application/ld+json',
          'Accept': 'application/ld+json',
        },
        timeout: '10s',
      }
    );

    const duration = Date.now() - startTime;
    brokerLatency.add(duration);

    const success = check(entitiesResponse, {
      'broker returns 200 or 404': (r) => r.status === 200 || r.status === 404,
      'response time < 1000ms': (r) => r.timings.duration < 1000,
    });

    if (success) {
      successfulRequests.add(1);
    } else {
      failedRequests.add(1);
      errorRate.add(1);
    }
  });

  sleep(0.5);

  // Test Group 3: Policy Access Point
  group('Policy Access Point', function() {
    const startTime = Date.now();

    const policyResponse = http.get(
      `${PAP_PROVIDER}/policy`,
      {
        headers: { 'Accept': 'application/json' },
        timeout: '10s',
      }
    );

    const duration = Date.now() - startTime;
    policyLatency.add(duration);

    const success = check(policyResponse, {
      'PAP returns 200': (r) => r.status === 200,
      'response time < 500ms': (r) => r.timings.duration < 500,
    });

    if (success) {
      successfulRequests.add(1);
    } else {
      failedRequests.add(1);
      errorRate.add(1);
    }
  });

  sleep(1);
}

// Test teardown
export function teardown(data) {
  console.log(`Test completed. Started at: ${data.startTime}`);
  console.log(`Finished at: ${new Date().toISOString()}`);
}

// Summary handler for custom output
export function handleSummary(data) {
  const summary = {
    timestamp: new Date().toISOString(),
    scenario: SCENARIO,
    domain: DOMAIN,
    metrics: {
      http_reqs: data.metrics.http_reqs?.values?.count || 0,
      http_req_duration_avg: data.metrics.http_req_duration?.values?.avg || 0,
      http_req_duration_p95: data.metrics.http_req_duration?.values?.['p(95)'] || 0,
      http_req_failed_rate: data.metrics.http_req_failed?.values?.rate || 0,
      error_rate: data.metrics.errors?.values?.rate || 0,
      successful_requests: data.metrics.successful_requests?.values?.count || 0,
      failed_requests: data.metrics.failed_requests?.values?.count || 0,
    },
    thresholds: {
      passed: Object.values(data.root_group?.checks || {}).every(c => c.passes > 0),
    },
  };

  return {
    'stdout': textSummary(data, { indent: ' ', enableColors: true }),
    'summary.json': JSON.stringify(summary, null, 2),
  };
}

// Text summary helper
function textSummary(data, options) {
  let summary = '\n';
  summary += '='.repeat(60) + '\n';
  summary += '  FIWARE Load Test Results\n';
  summary += '='.repeat(60) + '\n\n';

  summary += `  Scenario: ${SCENARIO}\n`;
  summary += `  Domain: ${DOMAIN}\n\n`;

  summary += '  Metrics:\n';
  summary += `    Total Requests: ${data.metrics.http_reqs?.values?.count || 0}\n`;
  summary += `    Avg Duration: ${(data.metrics.http_req_duration?.values?.avg || 0).toFixed(2)}ms\n`;
  summary += `    P95 Duration: ${(data.metrics.http_req_duration?.values?.['p(95)'] || 0).toFixed(2)}ms\n`;
  summary += `    Error Rate: ${((data.metrics.errors?.values?.rate || 0) * 100).toFixed(2)}%\n\n`;

  summary += '  Custom Metrics:\n';
  summary += `    Auth Latency (P95): ${(data.metrics.auth_latency?.values?.['p(95)'] || 0).toFixed(2)}ms\n`;
  summary += `    Broker Latency (P95): ${(data.metrics.broker_latency?.values?.['p(95)'] || 0).toFixed(2)}ms\n`;
  summary += `    Policy Latency (P95): ${(data.metrics.policy_latency?.values?.['p(95)'] || 0).toFixed(2)}ms\n\n`;

  summary += '='.repeat(60) + '\n';

  return summary;
}
