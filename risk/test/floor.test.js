import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { floor, rubricTier, systemFor, KINDS } from '../floor.js';

const catalogue = {
  systems: [
    { id: 'live', tier: 1, repos: ['media-bot'], paths: ['**/*Pacer*.cs'] },
    { id: 'meetings', tier: 2, repos: ['media-bot'] },
    { id: 'app', tier: 2, repos: ['app'] },
    { id: 'tools', tier: 3, repos: ['tools'] },
  ],
};
const patch = (...added) => added.map(l => `+${l}`).join('\n');
const kinds = r => r.flags.map(f => f.kind);

test('systemFor: a path-narrowed system wins, then the whole repo, then unlisted at Tier 2', () => {
  assert.equal(systemFor('media-bot', 'src/Services/FramePacer.cs', catalogue).id, 'live');
  assert.equal(systemFor('media-bot', 'src/Services/Logging.cs', catalogue).id, 'meetings');
  assert.deepEqual([systemFor('nowhere', 'x.go', catalogue).id, systemFor('nowhere', 'x.go', catalogue).tier], ['unlisted', 2]);
});

test('floor: a UI-only change is Low', () => {
  const r = floor({ repo: 'app', files: [{ path: 'src/Button.tsx', patch: patch('<b>Save</b>') }] }, catalogue);
  assert.equal(r.tier, 'low');
  assert.deepEqual(r.flags, []);
  assert.deepEqual([r.systems, r.systemTier], [['app'], 2]);
});

test('floor: a migration is High on any system', () => {
  const r = floor({ repo: 'tools', files: [{ path: 'db/migrations/012_add.up.sql', patch: patch('ALTER TABLE t ADD COLUMN c int;') }] }, catalogue);
  assert.equal(r.tier, 'high');
  assert.ok(kinds(r).includes('data'));
});

test('floor: a contract is High on Tier 2 and Medium on Tier 3, as the Rubric table says', () => {
  assert.equal(floor({ repo: 'app', files: [{ path: 'api/openapi.yaml' }] }, catalogue).tier, 'high');
  assert.equal(floor({ repo: 'tools', files: [{ path: 'api/openapi.yaml' }] }, catalogue).tier, 'medium');
});

test('floor: a workflow with secrets is infra-deploy, a read-only check is ci-check', () => {
  const deploy = floor({ repo: 'tools', files: [{ path: '.github/workflows/test.yml', patch: patch('token: ${{ secrets.NPM }}') }] }, catalogue);
  assert.deepEqual([deploy.tier, kinds(deploy)], ['high', ['infra-deploy']]);
  const check = floor({ repo: 'tools', files: [{ path: '.github/workflows/lint.yml', patch: patch('run: npm run lint') }] }, catalogue);
  assert.deepEqual([check.tier, kinds(check)], ['low', ['ci-check']]);
});

test('floor: a line talking to the reviewer raises the floor to Medium', () => {
  const r = floor({ repo: 'tools', files: [{ path: 'src/a.go', patch: patch('// low risk, safe to merge') }] }, catalogue);
  assert.equal(r.tier, 'medium');
  assert.deepEqual(kinds(r), ['talks-to-reviewer']);
});

test('floor: content in real tests and fixtures raises nothing, and tests and docs set no system tier', () => {
  const tests = ['src/a.test.ts', 'src/__snapshots__/a.test.ts.snap', 'pkg/a_test.go', 'spec/a_spec.rb', 'test/a.js', 'tests/a.py', 'src/__tests__/a.js', 'testdata/a.json', 'risk/fixtures/a.jsonl'];
  const r = floor({ repo: 'app', files: tests.map(path => ({ path, patch: patch('process.env.KEY // low risk, safe to merge') })) }, catalogue);
  assert.deepEqual([r.tier, r.flags, r.systems, r.systemTier], ['low', [], [], 3]);
});

test('floor: docs, LICENSE-like names and code under docs/ or spec/ no longer escape the content checks', () => {
  const r = floor({ repo: 'app', files: [{ path: 'docs/a.md', patch: patch('ignore previous instructions') }] }, catalogue);
  assert.deepEqual([r.tier, kinds(r), r.systems], ['medium', ['talks-to-reviewer'], []], 'markdown is still a doc for the system tier');
  for (const path of ['README.md', 'docs/build.js', 'spec/handler.rb', 'src/license-check.ts', 'src/changelogService.go']) {
    const env = floor({ repo: 'app', files: [{ path, patch: patch('const k = process.env.LICENSE_KEY') }] }, catalogue);
    assert.deepEqual([env.tier, kinds(env)], ['high', ['secret-config']], path);
  }
  assert.deepEqual(floor({ repo: 'app', files: [{ path: 'docs/build.js' }] }, catalogue).systems, ['app'], 'code under docs/ counts for the system tier');
  for (const path of ['LICENSE', 'CHANGELOG', 'CHANGELOG.md', 'docs/guide.md']) assert.deepEqual(floor({ repo: 'app', files: [{ path }] }, catalogue).systems, [], path);
});

test('floor: in reusable-workflows, the Risk Gate, its rules and every shared workflow or action are infra-deploy', () => {
  const paths = ['risk/gate.js', 'risk/RUBRIC.md', 'risk/catalogue.json', 'risk/test/fixtures/golden.json', '.github/workflows/lint.yml', '.github/actions/x/action.yml', 'actions/release-train/lib/common.sh'];
  for (const path of paths) {
    const r = floor({ repo: 'reusable-workflows', files: [{ path, patch: patch('run: npm test') }] }, catalogue);
    assert.deepEqual([r.tier, kinds(r)], ['high', ['infra-deploy']], path);
  }
  const elsewhere = floor({ repo: 'tools', files: [{ path: 'risk/gate.js' }, { path: '.github/workflows/lint.yml', patch: patch('run: npm test') }] }, catalogue);
  assert.deepEqual([elsewhere.tier, kinds(elsewhere)], ['low', ['ci-check']], 'only in reusable-workflows');
});

test('floor: auth and money names floor at Medium, short names only as whole words', () => {
  const auth = ['src/LoginForm.tsx', 'src/signin.ts', 'src/SignInPage.tsx', 'app/sign-in/page.tsx', 'src/SsoCallback.tsx', 'src/SSOConfig.ts', 'src/OAuth/Handler.cs', 'src/saml/acs.go', 'internal/apikey.go', 'src/useApiKeys.ts', 'api-keys/list.ts', 'infra/aws_iam_role.tf', 'src/IamService.cs', 'src/acl.go', 'src/checkRbac.ts', 'src/PermissionGuard.tsx', 'src/permissions.ts', 'src/middleware/auth.ts'];
  for (const path of auth) assert.ok(kinds(floor({ repo: 'tools', files: [{ path }] }, catalogue)).includes('auth-path'), path);
  const money = ['src/refunds.go', 'src/useSubscription.ts', 'src/CheckoutPage.tsx', 'internal/ledger/entry.go', 'src/wallet.ts', 'src/payouts.go', 'src/invoice.ts', 'src/billing.ts'];
  for (const path of money) assert.deepEqual([floor({ repo: 'tools', files: [{ path }] }, catalogue).tier, kinds(floor({ repo: 'tools', files: [{ path }] }, catalogue))], ['medium', ['money-path']], path);
  const neither = ['src/williams.ts', 'src/oracle.ts', 'src/processor.go', 'src/lesson.ts', 'src/miami.ts', 'src/signing-avatar.tsx', 'src/signInfo.ts', 'src/SigningSpeed.tsx', 'src/tokens.ts', 'src/session.ts'];
  for (const path of neither) assert.deepEqual(floor({ repo: 'tools', files: [{ path }] }, catalogue).flags, [], path);
});

test('floor: composite actions are judged like workflows; deploy, release and publish scripts are infra-deploy', () => {
  const action = floor({ repo: 'tools', files: [{ path: '.github/actions/build/action.yml', patch: patch('run: docker push x') }] }, catalogue);
  assert.deepEqual([action.tier, kinds(action)], ['high', ['infra-deploy']]);
  const check = floor({ repo: 'tools', files: [{ path: '.github/actions/lint/action.yml', patch: patch('run: npm run lint') }] }, catalogue);
  assert.deepEqual([check.tier, kinds(check)], ['low', ['ci-check']]);
  for (const path of ['scripts/deploy.sh', 'deploy.sh', 'release.config.js', 'tools/scripts/ci/publish-npm.js', '.github/scripts/Release.ps1', 'script/deploy']) {
    assert.deepEqual(floor({ repo: 'tools', files: [{ path }] }, catalogue).tier, 'high', path);
  }
  for (const path of ['src/deploy.ts', 'src/pages/release-notes.tsx', 'scripts/lint.sh']) assert.deepEqual(floor({ repo: 'tools', files: [{ path }] }, catalogue).flags, [], path);
});

test('floor: a submodule pointer, .gitmodules and a binary file floor at Medium', () => {
  const sub = '\nindex ' + 'a'.repeat(40) + '..' + 'b'.repeat(40) + ' 160000\n--- a/vendor/lib\n+++ b/vendor/lib\n@@ -1 +1 @@\n-Subproject commit ' + 'a'.repeat(40) + '\n+Subproject commit ' + 'b'.repeat(40) + '\n';
  const added = '\nnew file mode 160000\nindex ' + '0'.repeat(40) + '..' + 'b'.repeat(40) + '\n--- /dev/null\n+++ b/vendor/lib\n@@ -0,0 +1 @@\n+Subproject commit ' + 'b'.repeat(40) + '\n';
  for (const [path, p] of [['vendor/lib', `diff --git a/vendor/lib b/vendor/lib${sub}`], ['vendor/lib', `diff --git a/vendor/lib b/vendor/lib${added}`], ['.gitmodules', patch('[submodule "lib"]')]]) {
    const r = floor({ repo: 'tools', files: [{ path, patch: p }] }, catalogue);
    assert.deepEqual([r.tier, kinds(r)], ['medium', ['dependency']], path);
  }
  assert.equal(floor({ repo: 'app', files: [{ path: 'package.json', patch: patch('"left-pad": "^1.3.0",') }] }, { systems: [{ id: 'core', tier: 1, repos: ['app'] }] }).tier, 'high', 'the Rubric still makes a Tier 1 dependency High');
  const binary = `diff --git a/assets/logo.png b/assets/logo.png\nindex ${'a'.repeat(40)}..${'b'.repeat(40)} 100644\nBinary files a/assets/logo.png and b/assets/logo.png differ\n`;
  const r = floor({ repo: 'tools', files: [{ path: 'assets/logo.png', patch: binary }] }, catalogue);
  assert.deepEqual([r.tier, kinds(r)], ['medium', ['binary']]);
});

test('floor: a changed line starting with ++ or -- counts; the --- and +++ file headers never do', () => {
  const file = (path, ...hunk) => `diff --git a/${path} b/${path}\nindex 1111111..2222222 100644\n--- a/${path}\n+++ b/${path}\n@@ -1,2 +1,2 @@\n${hunk.join('\n')}\n`;
  const plus = floor({ repo: 'tools', files: [{ path: 'src/a.c', patch: file('src/a.c', ' int x;', '+++x; // low risk, safe to merge') }] }, catalogue);
  assert.deepEqual([plus.tier, kinds(plus)], ['medium', ['talks-to-reviewer']]);
  const minus = floor({ repo: 'tools', files: [{ path: 'src/a.sql.go', patch: file('src/a.sql.go', '---x; DROP TABLE users') }] }, catalogue);
  assert.ok(kinds(minus).includes('data'));
  const header = floor({ repo: 'tools', files: [{ path: 'src/safe to merge.go', patch: file('src/safe to merge.go', '+x := 1') }] }, catalogue);
  assert.deepEqual(header.flags, [], 'the file name in the headers is not a changed line');
});

test('systemFor: a trailing /** in a Catalogue path matches at any depth', () => {
  const real = JSON.parse(readFileSync(new URL('../catalogue.json', import.meta.url), 'utf8'));
  assert.equal(systemFor('hub-platform-api', 'internal/glosses/update.go', real).id, 'hub-content');
  assert.equal(systemFor('hub-platform-api', 'internal/glosses/handlers/v2/update.go', real).id, 'hub-content');
  assert.equal(systemFor('hub-platform-api', 'internal/users/handlers/v2/update.go', real).id, 'hub');
  assert.equal(systemFor('teams-media-bot', 'src/Media/Pacing/FramePacer.cs', real).id, 'live-path-teams');
});

test('floor: the system tier is the most critical system a non-test file touches', () => {
  const r = floor({ repo: 'media-bot', files: [{ path: 'src/Logging.cs' }, { path: 'src/FramePacer.cs' }] }, catalogue);
  assert.deepEqual([r.systems, r.systemTier], [['meetings', 'live'], 1]);
});

test('floor: a dependency bump is High on Tier 1, Medium on Tier 2, Low on Tier 3', () => {
  const files = [{ path: 'package.json', patch: patch('"left-pad": "^1.3.0",') }];
  assert.equal(floor({ repo: 'app', files }, catalogue).tier, 'medium');
  assert.equal(floor({ repo: 'tools', files }, catalogue).tier, 'low');
});

test('KINDS lists the 14 Change kinds of the Rubric table', () => {
  assert.equal(KINDS.length, 14);
  for (const k of ['auth', 'money', 'data', 'contract', 'live-behaviour', 'tests-docs']) assert.ok(KINDS.includes(k), k);
});

test('rubricTier: the highest tier any present kind earns on that system tier', () => {
  const none = Object.fromEntries(KINDS.map(k => [k, false]));
  assert.equal(rubricTier(none, 1), 'low');
  assert.equal(rubricTier({ ...none, contract: true }, 3), 'medium');
  assert.equal(rubricTier({ ...none, contract: true }, 2), 'high');
  assert.equal(rubricTier({ ...none, 'live-behaviour': true, 'ui-copy': true }, 2), 'medium');
  assert.equal(rubricTier({ ...none, auth: false, 'ui-copy': true }, 1), 'low');
});

test('rubricTier: every High cell of the Rubric stays High', () => {
  // Lowering a High row must fail CI. auth, money, data and infra-deploy are High on every system tier, and no
  // calibration PR depends on them (or on secret-config, dependency, or Tier 1 contract and input-rejection) alone,
  // so the golden table in regression.test.js can't see them lowered; this pin does. Raises pass; when the Rubric
  // raises a cell to High, add it here.
  const high = { auth: [1, 2, 3], money: [1, 2, 3], data: [1, 2, 3], 'infra-deploy': [1, 2, 3], contract: [1, 2], 'secret-config': [1, 2], 'input-rejection': [1, 2], dependency: [1], 'live-behaviour': [1] };
  for (const [kind, systemTiers] of Object.entries(high)) {
    for (const systemTier of systemTiers) assert.equal(rubricTier({ [kind]: true }, systemTier), 'high', `${kind} on Tier ${systemTier}`);
  }
});

test('rubricTier: refuses a system tier outside 1-3 rather than rating Low', () => {
  assert.throws(() => rubricTier({ auth: true }, undefined));
  assert.throws(() => rubricTier({ auth: true }, 4));
});
