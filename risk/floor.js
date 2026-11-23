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
// looks inside and marks the Change kinds it carries.
const M = ['medium', 'medium', 'medium'];
const KIND_TIER = { ...RUBRIC, 'talks-to-reviewer': M, 'auth-path': M, 'money-path': M, 'internal-dependency': M };

const INTERNAL_DEP = /@signapse\/|account-ui|github\.com\/signapse\/|Include="Signapse\./i;
// A workflow is infra-deploy when its name or changed lines build, publish, deploy or use secrets or write permissions.
const DEPLOY_WORKFLOW = /deploy|release|publish|prod|docker|ecr|terraform|helm|flux/i;
const DEPLOY_LINES = /secrets\.|:\s*write\b|npm publish|docker (push|build)|aws-actions|azure\/login|kubectl|helm |terraform /i;

const TEST_DOC = /(^|\/)(tests?|__tests__|spec|e2e|docs?|testdata|fixtures?)\/|\.(test|spec)\.\w+$|_test\.go$|Tests?\.cs$|\.(md|mdx|txt)$|(^|\/)(LICENSE|CHANGELOG)/i;
export const isTestOrDoc = path => TEST_DOC.test(path);

const PATH_KINDS = [
  ['data', /(^|\/)migrations?\/|\.sql$/i, 'migration or SQL file'],
  ['infra-deploy', /(^|\/)Dockerfile|\.dockerfile$|(^|\/)(deploy|helm|charts|k8s|kustomize|terraform)\/|\.tf$|\.tfvars$/i, 'build or deploy file'],
  ['secret-config', /(^|\/)\.env(\.|$)|(^|\/)config\/.*\.(ya?ml|json)$|values[\w-]*\.ya?ml$|kustomization\.ya?ml$|appsettings[\w.]*\.json$|externalsecret|kongplugin/i, 'config or secret file'],
  ['dependency', /(^|\/)(go\.mod|go\.sum|Cargo\.toml|Cargo\.lock|requirements[\w-]*\.txt|pyproject\.toml|poetry\.lock|package-lock\.json|pnpm-lock\.yaml|yarn\.lock|Directory\.Packages\.props|packages\.lock\.json)$|\.csproj$/i, 'dependency manifest or lockfile'],
  ['contract', /\.proto$|openapi|swagger|(^|\/)contracts?\//i, 'API contract'],
  ['auth-path', /(^|\/)(auth\w*|authz|rbac|permissions?)(\/|\.)|jwt|oauth/i, 'auth path'], // not "session": live sessions aren't auth
  ['money-path', /billing|credit|payment|stripe|invoice|pric(e|ing)|charge|purchase|meter/i, 'money path'],
  ['ci-check', /(^|\/)\.github\/dependabot\.ya?ml$/i, 'Dependabot config'],
];
const CONTENT_KINDS = [
  ['secret-config', /process\.env\.|import\.meta\.env|os\.(Getenv|LookupEnv)\(|Environment\.GetEnvironmentVariable|getenv\(/, 'reads an env var'],
  ['data', /\b(CREATE|ALTER|DROP)\s+(TABLE|INDEX|COLUMN)\b/i, 'schema change'],
  ['talks-to-reviewer', /\b(low[- ]risk|safe to merge|skip (the )?review|ignore (all |any |previous )?instructions|risk check|note to (the )?(ai|reviewer))\b/i, 'a line addresses a reviewer or an AI'],
];
const PKG_DEP = /^[+-]\s*"(?!version")[@\w/.-]+":\s*"[\^~>=]?\d/; // a dependency line in package.json, not its own version

const glob = g => new RegExp('^' + g.split('**/').map(s => s.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '[^/]*')).join('(.*/)?') + '$');

// The Catalogue system a file belongs to: a system narrowed by paths wins over the repo's whole-repo system.
export function systemFor(repo, path, catalogue) {
  const inRepo = catalogue.systems.filter(s => s.repos.includes(repo));
  return inRepo.find(s => s.paths?.some(g => glob(g).test(path))) ?? inRepo.find(s => !s.paths) ?? { id: 'unlisted', tier: 2, why: 'not in the Catalogue: treated as Tier 2' };
}

export function floor({ repo, files }, catalogue) {
  const flags = [];
  let tier = 'low';
  const flag = (kind, file, sys, why) => {
    const t = KIND_TIER[kind][sys.tier - 1];
    flags.push({ kind, file, tier: t, why });
    tier = max(tier, t);
  };
  for (const f of files) {
    const sys = systemFor(repo, f.path, catalogue);
    const lines = (f.patch ?? '').split('\n').filter(l => /^[+-]/.test(l) && !/^(\+\+\+|---)/.test(l));
    for (const [kind, re, why] of PATH_KINDS) if (re.test(f.path)) flag(kind, f.path, sys, why);
    if (/^\.github\/workflows\//.test(f.path)) {
      if (DEPLOY_WORKFLOW.test(f.path) || lines.some(l => DEPLOY_LINES.test(l))) flag('infra-deploy', f.path, sys, 'workflow that builds, publishes, deploys or uses secrets');
      else flag('ci-check', f.path, sys, 'read-only CI check');
    }
    if (/(^|\/)package\.json$/.test(f.path) && lines.some(l => PKG_DEP.test(l))) flag('dependency', f.path, sys, 'package.json dependency changed');
    if (/(^|\/)(package\.json|go\.mod)$|\.csproj$/.test(f.path) && lines.some(l => INTERNAL_DEP.test(l))) flag('internal-dependency', f.path, sys, 'bumps a package we publish');
    if (!isTestOrDoc(f.path)) for (const [kind, re, why] of CONTENT_KINDS) if (lines.some(l => re.test(l))) flag(kind, f.path, sys, why);
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
