export interface KubernetesResource {
  readonly id?: string;
  readonly name?: string;
  readonly namespace?: string;
  readonly metadata?: {
    readonly name?: string;
    readonly namespace?: string;
  };
  readonly state?: string | {
    readonly name?: string;
  };
  readonly status?: {
    readonly phase?: string;
  };
}

interface ResourceStore {
  dispatch(
    action: string,
    payload: { readonly type: string },
  ): Promise<unknown>;
}

function isResource(value: unknown): value is KubernetesResource {
  return typeof value === 'object' && value !== null;
}

export async function findAll(
  store: ResourceStore,
  type: string,
): Promise<KubernetesResource[]> {
  const result = await store.dispatch('cluster/findAll', { type });

  if (!Array.isArray(result)) {
    throw new TypeError(`Rancher returned a non-array response for ${ type }`);
  }

  return result.filter(isResource);
}

export function resourceName(resource: KubernetesResource): string {
  return resource.metadata?.name ?? resource.name ?? resource.id ?? 'Unknown';
}

export function resourceNamespace(resource: KubernetesResource): string {
  return resource.metadata?.namespace ?? resource.namespace ?? 'default';
}

export function podPhase(resource: KubernetesResource): string {
  if (resource.status?.phase) {
    return resource.status.phase;
  }

  if (typeof resource.state === 'string') {
    return resource.state;
  }

  return resource.state?.name ?? 'Unknown';
}
