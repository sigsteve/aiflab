<script lang="ts">
import { NAMESPACE, POD } from '@shell/config/types';
import { defineComponent } from 'vue';

import {
  findAll,
  resourceName,
  type KubernetesResource,
} from '../resources';

export default defineComponent({
  name: 'XtkClusterSummary',

  data() {
    return {
      error:      '',
      loading:    true,
      namespaces: [] as KubernetesResource[],
      pods:       [] as KubernetesResource[],
    };
  },

  computed: {
    namespaceNames(): string[] {
      return this.namespaces.map(resourceName).sort().slice(0, 5);
    },

    podNames(): string[] {
      return this.pods.map(resourceName).sort().slice(0, 5);
    },
  },

  async mounted() {
    await this.load();
  },

  methods: {
    async load(): Promise<void> {
      this.loading = true;
      this.error = '';

      try {
        [this.namespaces, this.pods] = await Promise.all([
          findAll(this.$store, NAMESPACE),
          findAll(this.$store, POD),
        ]);
      } catch (error) {
        this.error = error instanceof Error ? error.message : String(error);
      } finally {
        this.loading = false;
      }
    },
  },
});
</script>

<template>
  <main class="xtk-page">
    <header>
      <div>
        <h1>Cluster Summary</h1>
        <p>Live resources from the active Rancher cluster store.</p>
      </div>
      <button
        class="btn role-secondary"
        :disabled="loading"
        type="button"
        @click="load"
      >
        Refresh
      </button>
    </header>

    <p v-if="loading">
      Loading cluster resources...
    </p>
    <p
      v-else-if="error"
      role="alert"
    >
      {{ error }}
    </p>
    <section
      v-else
      class="summary-grid"
    >
      <article>
        <strong data-testid="namespace-count">{{ namespaces.length }}</strong>
        <span>Namespaces</span>
        <ul>
          <li
            v-for="name in namespaceNames"
            :key="name"
          >
            {{ name }}
          </li>
        </ul>
      </article>
      <article>
        <strong data-testid="summary-pod-count">{{ pods.length }}</strong>
        <span>Pods</span>
        <ul>
          <li
            v-for="name in podNames"
            :key="name"
          >
            {{ name }}
          </li>
        </ul>
      </article>
    </section>
  </main>
</template>

<style scoped>
.xtk-page {
  padding: 24px;
}

header {
  align-items: start;
  display: flex;
  justify-content: space-between;
}

.summary-grid {
  display: grid;
  gap: 24px;
  grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
  margin-top: 24px;
}

article {
  border: 1px solid var(--border, #d7d7d7);
  border-radius: 4px;
  padding: 20px;
}

strong {
  display: block;
  font-size: 32px;
}

ul {
  margin: 16px 0 0;
  padding-left: 20px;
}
</style>
