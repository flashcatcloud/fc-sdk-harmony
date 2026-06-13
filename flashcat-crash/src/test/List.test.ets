import crashEventMapperTests from './CrashEventMapper.test';
import crashSamplingTests from './CrashSampling.test';

export default function testsuite(): void {
  crashEventMapperTests();
  crashSamplingTests();
}
