import { registerAifExtension } from '@aif-xtk/sdk';
import type { RancherPlugin } from '@aif-xtk/sdk';
import { importTypes } from '@rancher/auto-import';
import type { IPlugin } from '@shell/core/types';

import ClusterSummary from './pages/ClusterSummary.vue';
import PodInspector from './pages/PodInspector.vue';

export default function register(plugin: IPlugin): void {
  importTypes(plugin);
  plugin.metadata = require('./package.json');
  registerAifExtension(plugin as unknown as RancherPlugin, {
    id:    'xtk-k8s',
    pages: [
      {
        slug:      'summary',
        label:     'Cluster Summary',
        component: ClusterSummary,
        weight:    80,
      },
      {
        slug:      'pods',
        label:     'Pod Inspector',
        component: PodInspector,
        weight:    60,
        access:    {
          kind: 'resource', resourceType: 'pod', verb: 'GET'
        },
      },
    ],
  });
}
