import crashEventMapperTests from './CrashEventMapper.test';
import crashSamplingTests from './CrashSampling.test';
import crashIncidentTests from './CrashIncident.test';
import jsCrashPolicyTests from './JsCrashPolicy.test';

export default function testsuite(): void {
  crashEventMapperTests();
  crashSamplingTests();
  crashIncidentTests();
  jsCrashPolicyTests();
}
