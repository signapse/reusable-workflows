// The Risk Floor and the Rubric, worked out from paths and content with no AI and no dependencies.
// The Work Dashboard (Risk Check) and the Risk Gate run this same file, so they can't disagree.
// floor({ repo, files: [{ path, patch }] }, catalogue) -> { tier, systems, systemTier, flags: [{ kind, file, tier, why }] }
import { readFileSync } from 'node:fs';

export const RANK = { low: 0, medium: 1, high: 2 };
export const TIERS = ['low', 'medium', 'high'];
export const max = (a, b) => (RANK[b] > RANK[a] ? b : a);

// The Rubric's Change kinds table, read from RUBRIC.md itself: the Risk Check is shown that file, so the tiers the
// model reads and the tiers this code applies are the same table. Each kind -> [Tier 1, Tier 2, Tier 3 system].
const RUBRIC = Object.fromEntries(readFileSync(new URL('RUBRIC.md', import.meta.url), 'utf8').split('\n')
  .map(l => l.match(/^\|\s*([a-z-]+)\s*\|.*\|\s*(\w+)\s*\|\s*(\w+)\s*\|\s*(\w+)\s*\|\s*$/))
  .filter(Boolean)
  .map(([, kind, ...tiers]) => [kind, tiers.map(t => t.toLowerCase())]));
if (!Object.keys(RUBRIC).length || Object.values(RUBRIC).flat().some(t => !TIERS.includes(t))) {
  throw new Error('RUBRIC.md: every row of the Change kinds table must give Low, Medium or High for Tier 1, 2 and 3');
}
export const KINDS = Object.keys(RUBRIC);

// The floor's own flags, on top of the Rubric's rows. A path that only looks like auth or money is a Medium floor;
// the Risk Check raises it when it's real logic. A bump of a package we publish is Medium until the Risk Check
// looks inside and marks the Change kinds it carries. A binary file outside tests is Medium: no check can read it.
const M = ['medium', 'medium', 'medium'];
const KIND_TIER = { ...RUBRIC, 'talks-to-reviewer': M, 'auth-path': M, 'money-path': M, 'internal-dependency': M, binary: M };

const INTERNAL_DEP = /@signapse\/|account-ui|github\.com\/signapse\/|Include="Signapse\./i;
// A workflow or composite action is infra-deploy when its name or changed lines build, publish, deploy or use secrets
// or write permissions.
const WORKFLOW = /^\.github\/(workflows|actions)\//;
const DEPLOY_WORKFLOW = /deploy|release|publish|prod|docker|ecr|terraform|helm|flux/i;
const DEPLOY_LINES = /secrets\.|:\s*write\b|npm publish|docker (push|build)|aws-actions|azure\/login|kubectl|helm |terraform /i;

// In reusable-workflows: the Risk Gate with its Catalogue and Rubric, and the workflows and actions every repo runs at
// @main. A change to any of them changes what judges or runs in every repo.
const SHARED_REPO = 'reusable-workflows';
const SHARED = /^(risk|actions|\.github\/workflows|\.github\/actions)\//;

// Real test files and fixtures (Jest and Vitest, Go, RSpec, C#, e2e): no content check reads them.
const TEST = /(^|\/)(tests?|__tests__|testdata|fixtures?|e2e)\/|\.(test|spec)\.[^/]*$|_test\.go$|_spec\.[^/]*$/i;
const isTest = path => TEST.test(path) || /Tests?\.cs$/.test(path); // FooTests.cs, not Latest.cs
// Code and scripts by name. Under docs/, anything else is a doc.
const CODE = /\.(sh|bash|zsh|ps1|[cm]?js|jsx|tsx?|py|go|rb|rs|cs|java|kt|php|swift)$|(^|\/)(Makefile|Dockerfile)$|(^|\/)[^/.]+$/i;
// Docs: markdown and text anywhere, LICENSE and CHANGELOG by their whole names, and what isn't code under docs/.
const DOC = /\.(md|mdx|rst|txt|adoc)$|(^|\/)(LICEN[CS]E|CHANGELOG)$/i;
const isDoc = path => DOC.test(path) || (/(^|\/)docs?\//i.test(path) && !CODE.test(path));
// Tests and docs: no system tier, no Risk Comments, no env-var or schema check. Docs still get the reviewer-talk check.
export const isTestOrDoc = path => isTest(path) || isDoc(path);
// A deploy, release or publish script, under a scripts dir or at the root. Only scripts and code: RELEASE.md is a doc.
const DEPLOY_SCRIPT = /(^|\/)scripts?\/(.*\/)?[^/]*(deploy|release|publish)[^/]*$|^[^/]*(deploy|release|publish)[^/]*$/i;

// Auth by name, in the path lowercased (OAuth, LogIn) and in its words (camelCase split: SsoCallback.tsx reads
// sso-callback.tsx). Short names (iam, acl) match only whole words, never williams or oracle. Not "session" (live
// sessions aren't auth), not a bare "token" (too broad), not "signing" or "signInfo" (sign language).
const AUTH = /(^|\/)auth[\w-]*(\/|\.)|jwt|oauth|login|sign[-_]?in(?![a-z])|api[-_]?keys?|permission|(^|[^a-z])(sso|saml|iam|acls?|rbac)([^a-z]|$)/;
const words = path => path.replace(/([a-z\d])([A-Z])/g, '$1-$2').replace(/([A-Z])([A-Z][a-z])/g, '$1-$2').toLowerCase();
const isAuthPath = path => AUTH.test(path.toLowerCase()) || AUTH.test(words(path));

const PATH_KINDS = [
  ['data', /(^|\/)migrations?\/|\.sql$/i, 'migration or SQL file'],
  ['infra-deploy', /(^|\/)Dockerfile|\.dockerfile$|(^|\/)(deploy|helm|charts|k8s|kustomize|terraform)\/|\.tf$|\.tfvars$/i, 'build or deploy file'],
  ['secret-config', /(^|\/)\.env(\.|$)|(^|\/)config\/.*\.(ya?ml|json)$|values[\w-]*\.ya?ml$|kustomization\.ya?ml$|appsettings[\w.]*\.json$|externalsecret|kongplugin/i, 'config or secret file'],
  ['dependency', /(^|\/)(go\.mod|go\.sum|Cargo\.toml|Cargo\.lock|requirements[\w-]*\.txt|pyproject\.toml|poetry\.lock|package-lock\.json|pnpm-lock\.yaml|yarn\.lock|Directory\.Packages\.props|packages\.lock\.json)$|\.csproj$/i, 'dependency manifest or lockfile'],
  ['contract', /\.proto$|openapi|swagger|(^|\/)contracts?\//i, 'API contract'],
  ['money-path', /billing|credit|payment|stripe|invoice|pric(e|ing)|charge|purchase|meter|refund|subscription|checkout|ledger|wallet|payout/i, 'money path'],
  ['ci-check', /(^|\/)\.github\/dependabot\.ya?ml$/i, 'Dependabot config'],
];
// [kind, changed-line pattern, why, the files it skips]
const CONTENT_KINDS = [
  ['secret-config', /process\.env\.|import\.meta\.env|os\.(Getenv|LookupEnv)\(|Environment\.GetEnvironmentVariable|getenv\(/, 'reads an env var', isTestOrDoc],
  ['data', /\b(CREATE|ALTER|DROP)\s+(TABLE|INDEX|COLUMN)\b/i, 'schema change', isTestOrDoc],
  ['talks-to-reviewer', /\b(low[- ]risk|safe to merge|skip (the )?review|ignore (all |any |previous )?instructions|risk check|note to (the )?(ai|reviewer))\b/i, 'a line addresses a reviewer or an AI', isTest],
];
// What no changed line shows: a submodule's commit pointer, and a binary file.
const SUBMODULE = /^(index \S+ 160000|(new|deleted) file mode 160000)$/m;
const BINARY = /^(Binary files .* differ|GIT binary patch)$/m;
const PKG_DEP = /^[+-]\s*"(?!version")[@\w/.-]+":\s*"[\^~>=]?\d/; // a dependency line in package.json, not its own version

// A Catalogue glob: **/ is any directories, a ** left after that (a trailing /**) is anything at any depth, * stays in one.
const glob = g => new RegExp('^' + g.split('**/').map(s => s.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*\*?/g, m => (m === '**' ? '.*' : '[^/]*'))).join('(.*/)?') + '$');

// A patch's changed lines: + and - lines inside hunks, never the file headers (--- a/x, +++ b/x) before the first @@.
// Hunk lines always start with a space, +, - or \, so no changed line can look like a header. A patch with no
// diff --git header is all hunk lines.
function changedLines(patch) {
  let inHunk = true;
  return (patch ?? '').split('\n').filter(l => {
    if (l.startsWith('diff --git ')) inHunk = false;
    else if (l.startsWith('@@')) inHunk = true;
    else return inHunk && /^[+-]/.test(l);
    return false;
  });
}

// The Catalogue system a file belongs to: a system narrowed by paths wins over the repo's whole-repo system.
export function systemFor(repo, path, catalogue) {
  const inRepo = catalogue.systems.filter(s => s.repos.includes(repo));
  return inRepo.find(s => s.paths?.some(g => glob(g).test(path))) ?? inRepo.find(s => !s.paths) ?? { id: 'unlisted', tier: 2, why: 'not in the Catalogue: treated as Tier 2' };
}

export function floor({ repo, files }, catalogue) {
  const flags = [];
  let tier = 'low';
  const flag = (kind, file, sys, why, atLeast = 'low') => {
    const t = max(KIND_TIER[kind][sys.tier - 1], atLeast);
    flags.push({ kind, file, tier: t, why });
    tier = max(tier, t);
  };
  for (const f of files) {
    const sys = systemFor(repo, f.path, catalogue);
    const lines = changedLines(f.patch);
    for (const [kind, re, why] of PATH_KINDS) if (re.test(f.path)) flag(kind, f.path, sys, why);
    if (DEPLOY_SCRIPT.test(f.path) && CODE.test(f.path)) flag('infra-deploy', f.path, sys, 'deploy, release or publish script');
    if (isAuthPath(f.path)) flag('auth-path', f.path, sys, 'auth path');
    if (repo === SHARED_REPO && SHARED.test(f.path)) flag('infra-deploy', f.path, sys, 'Risk Gate rules or CI every repo runs');
    else if (WORKFLOW.test(f.path)) {
      if (DEPLOY_WORKFLOW.test(f.path) || lines.some(l => DEPLOY_LINES.test(l))) flag('infra-deploy', f.path, sys, 'workflow or action that builds, publishes, deploys or uses secrets');
      else flag('ci-check', f.path, sys, 'read-only CI check');
    }
    if (/(^|\/)\.gitmodules$/.test(f.path) || SUBMODULE.test(f.patch ?? '')) flag('dependency', f.path, sys, 'submodule or .gitmodules changed', 'medium');
    if (BINARY.test(f.patch ?? '') && !isTest(f.path)) flag('binary', f.path, sys, 'binary file changed');
    if (/(^|\/)package\.json$/.test(f.path) && lines.some(l => PKG_DEP.test(l))) flag('dependency', f.path, sys, 'package.json dependency changed');
    if (/(^|\/)(package\.json|go\.mod)$|\.csproj$/.test(f.path) && lines.some(l => INTERNAL_DEP.test(l))) flag('internal-dependency', f.path, sys, 'bumps a package we publish');
    for (const [kind, re, why, skips] of CONTENT_KINDS) if (!skips(f.path) && lines.some(l => re.test(l))) flag(kind, f.path, sys, why);
  }
  // The system tier is the most critical system a non-test file touches, not the repo's.
  const touched = files.filter(f => !isTestOrDoc(f.path)).map(f => systemFor(repo, f.path, catalogue));
  const systems = [...new Set(touched.map(s => s.id))];
  const systemTier = touched.length ? Math.min(...touched.map(s => s.tier)) : 3;
  return { tier, systems, systemTier, flags };
}

// The Rubric applied in code to the Change kinds the Risk Check said are present: the model names the kinds, the
// table decides what they're worth (a model once said "contract: yes" on a Tier 2 system and still wrote "medium").
export function rubricTier(kinds, systemTier) {
  if (![1, 2, 3].includes(systemTier)) throw new Error(`rubricTier: system tier must be 1, 2 or 3, got ${systemTier}`);
  return Object.entries(kinds).filter(([k, yes]) => yes === true && Object.hasOwn(RUBRIC, k)).reduce((t, [k]) => max(t, RUBRIC[k][systemTier - 1]), 'low');
}
