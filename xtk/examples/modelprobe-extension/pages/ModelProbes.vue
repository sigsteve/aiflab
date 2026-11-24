<script lang="ts">
import { defineComponent } from 'vue';

import {
  createModelProbe,
  findModelProbes,
  type ModelProbeResource,
} from '../resources';

interface ModelProbeRow {
  readonly key: string;
  readonly name: string;
  readonly namespace: string;
  readonly url: string;
  readonly healthy?: boolean;
  readonly statusCode?: number;
  readonly latencyMs?: number;
  readonly lastProbeTime?: string;
  readonly message?: string;
}

function errorMessage(error: unknown): string {
  if (Array.isArray(error)) {
    return error.map(String).join(', ');
  }

  return error instanceof Error ? error.message : String(error);
}

export default defineComponent({
  name: 'XtkModelProbes',

  data() {
    return {
      creating:  false,
      error:     '',
      loading:   true,
      name:      '',
      namespace: 'default',
      probes:    [] as ModelProbeResource[],
      success:   '',
      timer:     undefined as ReturnType<typeof setInterval> | undefined,
      url:       '',
    };
  },

  computed: {
    rows(): ModelProbeRow[] {
      return this.probes
        .map((probe) => {
          const name = probe.metadata?.name ?? probe.id ?? 'Unknown';
          const namespace = probe.metadata?.namespace ?? 'default';

          return {
            key:           `${ namespace }/${ name }`,
            name,
            namespace,
            url:           probe.spec?.url ?? '',
            healthy:       probe.status?.healthy,
            statusCode:    probe.status?.lastStatusCode,
            latencyMs:     probe.status?.latencyMs,
            lastProbeTime: probe.status?.lastProbeTime,
            message:       probe.status?.message,
          };
        })
        .sort((left, right) => left.key.localeCompare(right.key));
    },
  },

  async mounted() {
    await this.load();
    this.timer = setInterval(() => {
      this.load(false);
    }, 5_000);
  },

  beforeUnmount() {
    if (this.timer !== undefined) {
      clearInterval(this.timer);
    }
  },

  methods: {
    async load(showLoading = true): Promise<void> {
      if (showLoading) {
        this.loading = true;
      }
      this.error = '';

      try {
        this.probes = await findModelProbes(this.$store);
      } catch (error) {
        this.error = errorMessage(error);
      } finally {
        this.loading = false;
      }
    },

    async create(): Promise<void> {
      this.creating = true;
      this.error = '';
      this.success = '';

      try {
        const name = this.name.trim();

        await createModelProbe(this.$store, {
          name,
          namespace: this.namespace.trim(),
          url:       this.url.trim(),
        });
        this.name = '';
        this.url = '';
        this.success = `Created ${ name }.`;
        await this.load(false);
      } catch (error) {
        this.error = errorMessage(error);
      } finally {
        this.creating = false;
      }
    },

    statusLabel(healthy?: boolean): string {
      if (healthy === undefined) {
        return 'Pending';
      }

      return healthy ? 'Healthy' : 'Unhealthy';
    },

    formatTime(value?: string): string {
      return value ? new Date(value).toLocaleString() : 'Pending';
    },
  },
});
</script>

<template>
  <main class="xtk-page">
    <header>
      <div>
        <h1>Model Probes</h1>
        <p>Live ModelProbe resources from the active cluster.</p>
      </div>
      <button
        class="btn role-secondary"
        :disabled="loading"
        type="button"
        @click="load()"
      >
        Refresh
      </button>
    </header>

    <form @submit.prevent="create">
      <h2>Create a probe</h2>
      <div class="form-grid">
        <label>
          Name
          <input
            v-model="name"
            data-testid="probe-name"
            pattern="[a-z0-9]([-a-z0-9]*[a-z0-9])?"
            required
            type="text"
          >
        </label>
        <label>
          Namespace
          <input
            v-model="namespace"
            data-testid="probe-namespace"
            required
            type="text"
          >
        </label>
        <label>
          URL
          <input
            v-model="url"
            data-testid="probe-url"
            placeholder="https://example.com/health"
            required
            type="url"
          >
        </label>
        <button
          class="btn role-primary"
          data-testid="create-probe"
          :disabled="creating"
          type="submit"
        >
          {{ creating ? 'Creating...' : 'Create probe' }}
        </button>
      </div>
    </form>

    <p
      v-if="error"
      role="alert"
    >
      {{ error }}
    </p>
    <p
      v-if="success"
      class="success"
      role="status"
    >
      {{ success }}
    </p>
    <p v-if="loading">
      Loading ModelProbes...
    </p>
    <table v-else>
      <thead>
        <tr>
          <th>Name</th>
          <th>Namespace</th>
          <th>URL</th>
          <th>Status</th>
          <th>HTTP</th>
          <th>Latency</th>
          <th>Last probe</th>
        </tr>
      </thead>
      <tbody>
        <tr
          v-for="probe in rows"
          :key="probe.key"
          data-testid="modelprobe-row"
        >
          <td>{{ probe.name }}</td>
          <td>{{ probe.namespace }}</td>
          <td class="url">
            {{ probe.url }}
          </td>
          <td>
            <span
              class="status"
              :class="{
                healthy: probe.healthy === true,
                unhealthy: probe.healthy === false,
              }"
              data-testid="probe-status"
              :title="probe.message"
            >
              {{ statusLabel(probe.healthy) }}
            </span>
          </td>
          <td>{{ probe.statusCode ?? 'Pending' }}</td>
          <td>{{ probe.latencyMs === undefined ? 'Pending' : `${probe.latencyMs} ms` }}</td>
          <td>{{ formatTime(probe.lastProbeTime) }}</td>
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

form {
  border: 1px solid var(--border, #d7d7d7);
  border-radius: 4px;
  margin: 24px 0;
  padding: 20px;
}

h2 {
  margin-top: 0;
}

.form-grid {
  align-items: end;
  display: grid;
  gap: 16px;
  grid-template-columns: 1fr 1fr 2fr auto;
}

label {
  display: grid;
  gap: 6px;
}

input {
  min-height: 38px;
}

.success {
  color: var(--success, #24572c);
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

.url {
  max-width: 440px;
  overflow-wrap: anywhere;
}

.status {
  border-radius: 12px;
  display: inline-block;
  padding: 3px 10px;
}

.healthy {
  background: #dcf1df;
  color: #24572c;
}

.unhealthy {
  background: #f7d8d8;
  color: #8b1a1a;
}

@media (max-width: 1000px) {
  .form-grid {
    grid-template-columns: 1fr;
  }
}
</style>
