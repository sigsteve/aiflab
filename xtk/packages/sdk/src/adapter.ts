import { buildRoutes, planExtensionRegistration } from './plan.ts';
import type {
  AifExtensionDefinition,
  PageAccessRule,
  RancherPlugin,
  RancherVirtualType,
  ResolvedPageRegistration,
} from './types.ts';

function unreachable(value: never): never {
  throw new TypeError(`Unsupported access rule: ${ JSON.stringify(value) }`);
}

function virtualTypeFor(
  page: ResolvedPageRegistration,
): RancherVirtualType {
  const base = {
    name:  page.virtualTypeName,
    label: page.label,
    route: { name: page.routeName },
    ...(page.icon === undefined ? {} : { icon: page.icon }),
  };

  switch (page.access.kind) {
  case 'always':
    return base;
  case 'resource':
    return {
      ...base,
      ifHaveType: page.access.resourceType,
      ...(page.access.verb === undefined ? {} : { ifHaveVerb: page.access.verb }),
    };
  case 'feature':
    return {
      ...base,
      ifFeature: page.access.feature,
    };
  default:
    return unreachable(page.access);
  }
}

function groupTypeNames(
  planned: readonly ResolvedPageRegistration[],
): ReadonlyMap<string, readonly string[]> {
  const grouped = new Map<string, string[]>();

  for (const page of planned) {
    const typeNames = grouped.get(page.group) ?? [];

    typeNames.push(page.virtualTypeName);
    grouped.set(page.group, typeNames);
  }

  return grouped;
}

export function registerAifExtension(
  plugin: RancherPlugin,
  definition: AifExtensionDefinition,
): void {
  const planned = planExtensionRegistration(definition);
  const groupedTypeNames = groupTypeNames(planned);

  plugin.addProduct({
    init($plugin, store) {
      const {
        virtualType,
        basicType,
        weightType,
      } = $plugin.DSL(store, 'suseai');

      for (const page of planned) {
        virtualType(virtualTypeFor(page));

        if (page.weight !== undefined) {
          weightType(page.label, page.weight, true);
        }
      }

      for (const [group, typeNames] of groupedTypeNames) {
        basicType(typeNames, group);
      }
    },
  });
  plugin.addRoutes(buildRoutes(planned));
}

export type { PageAccessRule };
