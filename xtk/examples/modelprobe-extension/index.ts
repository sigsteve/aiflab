import { registerAifExtension } from '@aif-xtk/sdk';
import type { RancherPlugin } from '@aif-xtk/sdk';
import { importTypes } from '@rancher/auto-import';
import type { IPlugin } from '@shell/core/types';

import ModelProbes from './pages/ModelProbes.vue';
import { MODEL_PROBE } from './resources';

export default function register(plugin: IPlugin): void {
  importTypes(plugin);
  plugin.metadata = require('./package.json');
  registerAifExtension(plugin as unknown as RancherPlugin, {
    id:    'xtk-modelprobe',
    pages: [{
      slug:      'probes',
      label:     'Model Probes',
      component: ModelProbes,
      weight:    40,
      access:    {
        kind:         'resource',
        resourceType: MODEL_PROBE,
        verb:         'GET',
      },
    }],
  });
}
