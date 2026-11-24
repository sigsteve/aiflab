import type {
  ExtensionId,
  PageAccessRule,
  PageSlug,
  ParsedAifExtensionDefinition,
  ParsedAifExtensionPage,
  RancherRoute,
  ResolvedPageRegistration,
} from './types.ts';

const NAME_PATTERN = /^[a-z][a-z0-9-]{1,40}$/;
const RESOURCE_VERBS = new Set([
  'GET',
  'LIST',
  'CREATE',
  'UPDATE',
  'DELETE',
  'WATCH',
]);

function invalid(path: string, message: string): never {
  throw new TypeError(`Invalid extension definition: ${ path } ${ message }`);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function parseName(
  value: unknown,
  path: string,
  kind: 'extension id' | 'page slug',
): string {
  if (typeof value !== 'string' || !NAME_PATTERN.test(value)) {
    invalid(
      path,
      `must be a kebab-case ${ kind } matching ${ NAME_PATTERN.toString() }`,
    );
  }

  return value;
}

function parseNonEmptyString(value: unknown, path: string): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    invalid(path, 'must be a non-empty string');
  }

  return value.trim();
}

function rejectUnknownKeys(
  value: Record<string, unknown>,
  allowed: readonly string[],
  path: string,
): void {
  const unknownKey = Object.keys(value).find((key) => !allowed.includes(key));

  if (unknownKey) {
    invalid(path, `contains unsupported field "${ unknownKey }"`);
  }
}

function parseAccess(value: unknown, path: string): PageAccessRule {
  if (!isRecord(value) || typeof value.kind !== 'string') {
    invalid(path, 'must be a valid access rule');
  }

  switch (value.kind) {
  case 'always':
    rejectUnknownKeys(value, ['kind'], path);

    return Object.freeze({ kind: 'always' });
  case 'resource': {
    rejectUnknownKeys(value, ['kind', 'resourceType', 'verb'], path);
    const resourceType = parseNonEmptyString(
      value.resourceType,
      `${ path }.resourceType`,
    );

    if (
      value.verb !== undefined &&
      (typeof value.verb !== 'string' || !RESOURCE_VERBS.has(value.verb))
    ) {
      invalid(
        `${ path }.verb`,
        `must be one of ${ [...RESOURCE_VERBS].join(', ') }`,
      );
    }

    return Object.freeze({
      kind: 'resource',
      resourceType,
      ...(value.verb === undefined ? {} : { verb: value.verb }),
    }) as PageAccessRule;
  }
  case 'feature':
    rejectUnknownKeys(value, ['kind', 'feature'], path);

    return Object.freeze({
      kind:    'feature',
      feature: parseNonEmptyString(value.feature, `${ path }.feature`),
    });
  default:
    invalid(
      `${ path }.kind`,
      'must be "always", "resource", or "feature"',
    );
  }
}

function parsePage(
  value: unknown,
  index: number,
): ParsedAifExtensionPage {
  const path = `pages[${ index }]`;

  if (!isRecord(value)) {
    invalid(path, 'must be an object');
  }

  const slug = parseName(value.slug, `${ path }.slug`, 'page slug') as PageSlug;
  const label = parseNonEmptyString(value.label, `${ path }.label`);

  if (
    !Object.hasOwn(value, 'component') ||
    value.component === null ||
    value.component === undefined
  ) {
    invalid(`${ path }.component`, 'is required');
  }

  if (
    value.weight !== undefined &&
    (typeof value.weight !== 'number' || !Number.isFinite(value.weight))
  ) {
    invalid(`${ path }.weight`, 'must be a finite number');
  }

  const access = value.access === undefined ? undefined : parseAccess(value.access, `${ path }.access`);
  const icon = value.icon === undefined ? undefined : parseNonEmptyString(value.icon, `${ path }.icon`);

  return Object.freeze({
    slug,
    label,
    component: value.component,
    ...(value.weight === undefined ? {} : { weight: value.weight }),
    ...(access === undefined ? {} : { access }),
    ...(icon === undefined ? {} : { icon }),
  });
}

export function parseExtensionDefinition(
  raw: unknown,
): ParsedAifExtensionDefinition {
  if (!isRecord(raw)) {
    invalid('root', 'must be an object');
  }

  const id = parseName(raw.id, 'id', 'extension id') as ExtensionId;

  if (!Array.isArray(raw.pages) || raw.pages.length === 0) {
    invalid('pages', 'must be a non-empty array');
  }

  const pages = raw.pages.map(parsePage);
  const slugs = new Set<string>();

  for (const page of pages) {
    if (slugs.has(page.slug)) {
      invalid('pages', `contains duplicate slug "${ page.slug }"`);
    }

    slugs.add(page.slug);
  }

  const group = raw.group === undefined ? undefined : parseNonEmptyString(raw.group, 'group');

  return Object.freeze({
    id,
    ...(group === undefined ? {} : { group }),
    pages: Object.freeze(pages),
  });
}

export function planExtensionRegistration(
  definition: unknown,
): readonly ResolvedPageRegistration[] {
  const parsed = parseExtensionDefinition(definition);
  const group = parsed.group ?? 'Extensions';

  return Object.freeze(parsed.pages.map((page) => Object.freeze({
    virtualTypeName: `suseai.ext.${ parsed.id }.${ page.slug }`,
    routeName:       `c-cluster-suseai-ext-${ parsed.id }-${ page.slug }`,
    routePath:       `/c/:cluster/suseai/extensions/${ parsed.id }/${ page.slug }`,
    label:           page.label,
    group,
    access:          page.access ?? Object.freeze({ kind: 'always' }),
    component:       page.component,
    ...(page.weight === undefined ? {} : { weight: page.weight }),
    ...(page.icon === undefined ? {} : { icon: page.icon }),
  })));
}

export function buildRoutes(
  planned: readonly ResolvedPageRegistration[],
): readonly RancherRoute[] {
  return planned.map((page) => ({
    name:      page.routeName,
    path:      page.routePath,
    component: page.component,
    meta:      { product: 'suseai' as const },
  }));
}
