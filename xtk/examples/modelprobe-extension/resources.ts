export const MODEL_PROBE = 'xtk.aiflab.io.modelprobe';

export interface ModelProbeResource {
  readonly id?: string;
  readonly metadata?: {
    readonly name?: string;
    readonly namespace?: string;
  };
  readonly spec?: {
    readonly url?: string;
    readonly intervalSeconds?: number;
    readonly expectStatus?: number;
  };
  readonly status?: {
    readonly healthy?: boolean;
    readonly lastStatusCode?: number;
    readonly latencyMs?: number;
    readonly lastProbeTime?: string;
    readonly message?: string;
  };
}

interface SavableResource {
  save(): Promise<unknown>;
}

interface ResourceStore {
  dispatch(
    action: 'cluster/findAll',
    payload: {
      readonly type: string;
      readonly opt: { readonly force: boolean };
    },
  ): Promise<unknown>;
  dispatch(
    action: 'cluster/create',
    payload: {
      readonly type: string;
      readonly metadata: {
        readonly name: string;
        readonly namespace: string;
      };
      readonly spec: { readonly url: string };
    },
  ): Promise<SavableResource>;
}

function isModelProbe(value: unknown): value is ModelProbeResource {
  return typeof value === 'object' && value !== null;
}

export async function findModelProbes(
  store: ResourceStore,
): Promise<ModelProbeResource[]> {
  const result = await store.dispatch('cluster/findAll', {
    type: MODEL_PROBE,
    opt:  { force: true },
  });

  if (!Array.isArray(result)) {
    throw new TypeError('Rancher returned a non-array ModelProbe response');
  }

  return result.filter(isModelProbe);
}

export async function createModelProbe(
  store: ResourceStore,
  input: {
    readonly name: string;
    readonly namespace: string;
    readonly url: string;
  },
): Promise<void> {
  const resource = await store.dispatch('cluster/create', {
    type:     MODEL_PROBE,
    metadata: {
      name:      input.name,
      namespace: input.namespace,
    },
    spec: { url: input.url },
  });

  await resource.save();
}
