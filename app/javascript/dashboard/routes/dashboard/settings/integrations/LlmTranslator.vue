<script setup>
import { ref, watch, onMounted } from 'vue';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { useIntegrationHook } from 'dashboard/composables/useIntegrationHook';
import Draggable from 'vuedraggable';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import NewHook from './NewHook.vue';
import SettingsLayout from '../SettingsLayout.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import IntegrationsAPI from 'dashboard/api/integrations';

const INTEGRATION_ID = 'llm_translator';

const store = useStore();
const { t } = useI18n();
const uiFlags = useMapGetter('integrations/getUIFlags');
const { integration } = useIntegrationHook(INTEGRATION_ID);

const providers = ref([]);
const showAddHookModal = ref(false);
const showDeleteConfirmationPopup = ref(false);
const selectedHook = ref({});
// Connectivity check state per hook id:
// { state: 'testing'|'ok'|'fail', latency, error }
const healthChecks = ref({});

// Keep the local draggable list in sync with the store, ordered by priority.
watch(
  () => integration.value.hooks,
  hooks => {
    providers.value = [...(hooks || [])].sort(
      (a, b) =>
        Number(a.settings?.priority || 0) - Number(b.settings?.priority || 0)
    );
  },
  { immediate: true, deep: true }
);

onMounted(() => store.dispatch('integrations/get'));

// Persist the new order: priority = position in the list (1-based).
const onDragEnd = async () => {
  const updates = providers.value.filter(
    (hook, index) => Number(hook.settings?.priority) !== index + 1
  );
  try {
    await Promise.all(
      providers.value.map((hook, index) => {
        if (Number(hook.settings?.priority) === index + 1) return null;
        return store.dispatch('integrations/updateHook', {
          hookId: hook.id,
          settings: { ...hook.settings, priority: String(index + 1) },
        });
      })
    );
    if (updates.length) {
      useAlert(t('INTEGRATION_APPS.LLM_TRANSLATOR.PRIORITY_UPDATED'));
    }
  } catch (error) {
    useAlert(t('INTEGRATION_APPS.LLM_TRANSLATOR.PRIORITY_UPDATE_ERROR'));
  }
};

// Ping the provider through the backend and surface the result inline.
const verifyConnection = async hook => {
  healthChecks.value = {
    ...healthChecks.value,
    [hook.id]: { state: 'testing' },
  };
  try {
    const { data } = await IntegrationsAPI.processHookEvent(hook.id, {
      name: 'verify_connection',
    });
    const result = data?.message || {};
    healthChecks.value = {
      ...healthChecks.value,
      [hook.id]: result.success
        ? { state: 'ok', latency: result.latency_ms }
        : { state: 'fail', error: result.error },
    };
  } catch (error) {
    healthChecks.value = {
      ...healthChecks.value,
      [hook.id]: {
        state: 'fail',
        error: error?.response?.data?.error || error.message,
      },
    };
  }
};

const openDeletePopup = hook => {
  selectedHook.value = hook;
  showDeleteConfirmationPopup.value = true;
};

const confirmDeletion = async () => {
  try {
    await store.dispatch('integrations/deleteHook', {
      hookId: selectedHook.value.id,
      appId: selectedHook.value.app_id,
    });
    useAlert(t('INTEGRATION_APPS.DELETE.API.SUCCESS_MESSAGE'));
  } catch (error) {
    useAlert(t('INTEGRATION_APPS.DELETE.API.ERROR_MESSAGE'));
  } finally {
    showDeleteConfirmationPopup.value = false;
  }
};
</script>

<template>
  <SettingsLayout :is-loading="uiFlags.isFetching">
    <template #header>
      <BaseSettingsHeader
        :title="integration.name || ''"
        :description="integration.description || ''"
        :feature-name="INTEGRATION_ID"
        :back-button-label="$t('INTEGRATION_SETTINGS.HEADER')"
      >
        <template #actions>
          <NextButton
            blue
            sm
            icon="i-lucide-plus"
            :label="$t('INTEGRATION_APPS.ADD_BUTTON')"
            @click="showAddHookModal = true"
          />
        </template>
      </BaseSettingsHeader>
    </template>
    <template #body>
      <div v-if="providers.length" class="w-full flex flex-col gap-2">
        <p class="text-sm text-n-slate-11">
          {{ $t('INTEGRATION_APPS.LLM_TRANSLATOR.DRAG_HINT') }}
        </p>
        <Draggable
          v-model="providers"
          item-key="id"
          class="flex flex-col gap-2"
          @end="onDragEnd"
        >
          <template #item="{ element: hook, index }">
            <div
              class="flex items-center gap-3 px-4 py-3 rounded-lg border border-n-weak bg-n-solid-1 cursor-move"
            >
              <Icon
                icon="i-woot-drag-indicator"
                class="size-4 text-n-slate-11 shrink-0"
              />
              <span
                class="flex items-center justify-center size-6 rounded-full bg-n-alpha-2 text-xs font-semibold text-n-slate-12 shrink-0"
              >
                {{ index + 1 }}
              </span>
              <div class="flex flex-col min-w-0 flex-1">
                <span class="text-sm font-medium text-n-slate-12 truncate">
                  {{ hook.settings?.name || '--' }}
                </span>
                <span class="text-xs text-n-slate-11 truncate">
                  {{ `${hook.settings?.model} · ${hook.settings?.base_url}` }}
                </span>
              </div>
              <span
                v-if="healthChecks[hook.id]?.state === 'testing'"
                class="flex items-center gap-1 text-xs text-n-slate-11 shrink-0"
              >
                <Icon icon="i-ph-spinner-gap" class="size-3.5 animate-spin" />
                {{ $t('INTEGRATION_APPS.LLM_TRANSLATOR.TESTING') }}
              </span>
              <span
                v-else-if="healthChecks[hook.id]?.state === 'ok'"
                class="flex items-center gap-1 text-xs text-n-teal-11 shrink-0"
              >
                <span class="size-2 rounded-full bg-n-teal-9" />
                {{
                  $t('INTEGRATION_APPS.LLM_TRANSLATOR.CONNECTED', {
                    latency: healthChecks[hook.id].latency,
                  })
                }}
              </span>
              <span
                v-else-if="healthChecks[hook.id]?.state === 'fail'"
                v-tooltip.top="healthChecks[hook.id].error"
                class="flex items-center gap-1 text-xs text-n-ruby-11 shrink-0 max-w-48"
              >
                <span class="size-2 rounded-full bg-n-ruby-9 shrink-0" />
                <span class="truncate">
                  {{ $t('INTEGRATION_APPS.LLM_TRANSLATOR.FAILED') }}
                </span>
              </span>
              <NextButton
                slate
                faded
                sm
                :label="$t('INTEGRATION_APPS.LLM_TRANSLATOR.TEST_BUTTON')"
                :disabled="healthChecks[hook.id]?.state === 'testing'"
                @click="verifyConnection(hook)"
              />
              <NextButton
                ruby
                faded
                sm
                icon="i-lucide-trash-2"
                @click="openDeletePopup(hook)"
              />
            </div>
          </template>
        </Draggable>
      </div>
      <p v-else class="text-sm text-n-slate-11">
        {{
          $t('INTEGRATION_APPS.NO_HOOK_CONFIGURED', {
            integrationId: INTEGRATION_ID,
          })
        }}
      </p>
    </template>

    <woot-modal
      v-model:show="showAddHookModal"
      :on-close="() => (showAddHookModal = false)"
    >
      <NewHook
        :integration-id="INTEGRATION_ID"
        @close="showAddHookModal = false"
      />
    </woot-modal>

    <woot-delete-modal
      v-model:show="showDeleteConfirmationPopup"
      :on-close="() => (showDeleteConfirmationPopup = false)"
      :on-confirm="confirmDeletion"
      :title="$t('INTEGRATION_APPS.DELETE.TITLE.ACCOUNT')"
      :message="$t('INTEGRATION_APPS.DELETE.MESSAGE.ACCOUNT')"
      :confirm-text="$t('INTEGRATION_APPS.DELETE.CONFIRM_BUTTON_TEXT.ACCOUNT')"
      :reject-text="$t('INTEGRATION_APPS.DELETE.CANCEL_BUTTON_TEXT')"
    />
  </SettingsLayout>
</template>
