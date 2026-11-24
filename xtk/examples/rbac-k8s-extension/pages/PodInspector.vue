<script lang="ts">
import { POD } from '@shell/config/types';
import { defineComponent } from 'vue';

import {
  findAll,
  podPhase,
  resourceName,
  resourceNamespace,
  type KubernetesResource,
} from '../resources';

interface PodRow {
  readonly key: string;
  readonly name: string;
  readonly namespace: string;
  readonly phase: string;
}

export default defineComponent({
  name: 'XtkPodInspector',

  data() {
    return {
      error:   '',
      filter:  '',
      loading: true,
      pods:    [] as KubernetesResource[],
    };
  },

  computed: {
    rows(): PodRow[] {
      const filter = this.filter.trim().toLowerCase();

      return this.pods
        .map((pod) => {
          const name = resourceName(pod);
          const namespace = resourceNamespace(pod);

          return {
            key:   `${ namespace }/${ name }`,
            name,
            namespace,
            phase: podPhase(pod),
          };
        })
        .filter((pod) => !filter || pod.key.toLowerCase().includes(filter))
        .sort((left, right) => left.key.localeCompare(right.key));
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
        this.pods = await findAll(this.$store, POD);
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
        <h1>Pod Inspector</h1>
        <p>
          <strong data-testid="pod-count">{{ pods.length }}</strong>
          live pods in the active cluster
        </p>
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

    <label for="pod-filter">Filter pods</label>
    <input
      id="pod-filter"
      v-model="filter"
      class="input-sm"
      placeholder="namespace or pod name"
      type="search"
    >

    <p v-if="loading">
      Loading pods...
    </p>
    <p
      v-else-if="error"
      role="alert"
    >
      {{ error }}
    </p>
    <table v-else>
      <thead>
        <tr>
          <th>Name</th>
          <th>Namespace</th>
          <th>Phase</th>
        </tr>
      </thead>
      <tbody>
        <tr
          v-for="pod in rows"
          :key="pod.key"
          data-testid="pod-row"
        >
          <td>{{ pod.name }}</td>
          <td>{{ pod.namespace }}</td>
          <td>{{ pod.phase }}</td>
        </tr>
      </tbody>
    </table>
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

input {
  margin: 8px 0 20px;
  max-width: 420px;
  width: 100%;
}

table {
  border-collapse: collapse;
  width: 100%;
}

th,
td {
  border-bottom: 1px solid var(--border, #d7d7d7);
  padding: 10px;
  text-align: left;
}
</style>
