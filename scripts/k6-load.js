// HTTP latency test at a fixed request rate (S-4 / S-5).
//
//   k6 run -e TARGET_URL=http://<alb>:8002/1k -e RATE=500 -e DURATION=3m \
//          -e LABEL=B1 --summary-export results/k6-B1-500.json k6-load.js
//
// A fixed arrival rate keeps the offered load identical across patterns,
// so the p99 values are comparable.
import http from 'k6/http';
import { check } from 'k6';

const TARGET_URL = __ENV.TARGET_URL;
if (!TARGET_URL) {
  throw new Error('TARGET_URL is required');
}
const RATE = parseInt(__ENV.RATE || '500', 10);
const DURATION = __ENV.DURATION || '3m';

export const options = {
  discardResponseBodies: true,
  scenarios: {
    warmup: {
      executor: 'constant-arrival-rate',
      rate: Math.max(10, Math.floor(RATE / 5)),
      timeUnit: '1s',
      duration: '30s',
      preAllocatedVUs: 50,
      maxVUs: 500,
      tags: { phase: 'warmup' },
    },
    measure: {
      executor: 'constant-arrival-rate',
      startTime: '30s',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: Math.max(50, Math.floor(RATE / 5)),
      maxVUs: Math.max(500, RATE * 2),
      tags: { phase: 'measure' },
    },
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  thresholds: {
    // Thresholds on the measure phase only, so the summary shows clean numbers.
    'http_req_duration{phase:measure}': ['p(99)<10000'],
    'http_req_failed{phase:measure}': ['rate<1'],
    'dropped_iterations': ['count>=0'],
  },
};

export default function () {
  const res = http.get(TARGET_URL, { tags: { label: __ENV.LABEL || 'unknown' } });
  check(res, { 'status is 200': (r) => r.status === 200 });
}
