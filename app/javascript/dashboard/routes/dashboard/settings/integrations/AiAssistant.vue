<script setup>
import { ref, onMounted } from 'vue';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { useIntegrationHook } from 'dashboard/composables/useIntegrationHook';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import NewHook from './NewHook.vue';
import AiAssistantKnowledgeBase from './AiAssistantKnowledgeBase.vue';
import SettingsLayout from '../SettingsLayout.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import IntegrationsAPI from 'dashboard/api/integrations';

const INTEGRATION_ID = 'ai_assistant';

const store = useStore();
const { t } = useI18n();
const uiFlags = useMapGetter('integrations/getUIFlags');
const { integration } = useIntegrationHook(INTEGRATION_ID);

const showAddHookModal = ref(false);
const showEditHookModal = ref(false);
const hookToEdit = ref(null);
const showDeleteConfirmationPopup = ref(false);
const selectedHook = ref({});
// Connectivity check state per hook id:
// { state: 'testing'|'ok'|'fail', latency, error }
const healthChecks = ref({});

onMounted(() => store.dispatch('integrations/get'));

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
        ? {
            state: 'ok',
            latency: result.latency_ms,
            embedding: result.embedding,
          }
        : { state: 'fail', error: result.error, embedding: result.embedding },
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

const openEditModal = hook => {
  hookToEdit.value = hook;
  showEditHookModal.value = true;
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
      <div
        v-if="integration.hooks && integration.hooks.length"
        class="w-full flex flex-col gap-2"
      >
        <p class="text-sm text-n-slate-11">
          {{ $t('INTEGRATION_APPS.AI_ASSISTANT.LIST_HINT') }}
        </p>
        <div
          v-for="hook in integration.hooks"
          :key="hook.id"
          class="flex flex-col gap-3 px-4 py-3 rounded-lg border border-n-weak bg-n-solid-1"
        >
          <div class="flex items-center gap-3">
            <Icon icon="i-lucide-bot" class="size-5 text-n-slate-11 shrink-0" />
            <div class="flex flex-col min-w-0 flex-1">
              <span class="text-sm font-medium text-n-slate-12 truncate">
                {{ hook.settings?.bot_name || hook.settings?.model || '--' }}
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
              {{ $t('INTEGRATION_APPS.AI_ASSISTANT.TESTING') }}
            </span>
            <span
              v-else-if="healthChecks[hook.id]?.state === 'ok'"
              class="flex items-center gap-1 text-xs text-n-teal-11 shrink-0"
            >
              <span class="size-2 rounded-full bg-n-teal-9" />
              {{
                $t('INTEGRATION_APPS.AI_ASSISTANT.CONNECTED', {
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
                {{ $t('INTEGRATION_APPS.AI_ASSISTANT.FAILED') }}
              </span>
            </span>
            <span
              v-if="healthChecks[hook.id]?.embedding"
              class="flex items-center gap-1 text-xs shrink-0 max-w-48"
              :class="
                healthChecks[hook.id].embedding.success
                  ? 'text-n-teal-11'
                  : 'text-n-ruby-11'
              "
            >
              <span
                class="size-2 rounded-full shrink-0"
                :class="
                  healthChecks[hook.id].embedding.success
                    ? 'bg-n-teal-9'
                    : 'bg-n-ruby-9'
                "
              />
              <span v-if="healthChecks[hook.id].embedding.success">
                {{ $t('INTEGRATION_APPS.AI_ASSISTANT.EMBEDDING_OK') }}
              </span>
              <span v-else class="truncate">
                {{
                  $t('INTEGRATION_APPS.AI_ASSISTANT.EMBEDDING_FAILED', {
                    error: healthChecks[hook.id].embedding.error,
                  })
                }}
              </span>
            </span>
            <NextButton
              slate
              faded
              sm
              :label="$t('INTEGRATION_APPS.AI_ASSISTANT.TEST_BUTTON')"
              :disabled="healthChecks[hook.id]?.state === 'testing'"
              @click="verifyConnection(hook)"
            />
            <NextButton
              slate
              faded
              sm
              icon="i-lucide-pencil"
              @click="openEditModal(hook)"
            />
            <NextButton
              ruby
              faded
              sm
              icon="i-lucide-trash-2"
              @click="openDeletePopup(hook)"
            />
          </div>
          <div
            v-if="hook.inboxes && hook.inboxes.length"
            class="flex flex-wrap items-center gap-1.5"
          >
            <span class="text-xs text-n-slate-11 shrink-0">
              {{ $t('INTEGRATION_APPS.AI_ASSISTANT.CONNECTED_INBOXES') }}
            </span>
            <span
              v-for="inbox in hook.inboxes"
              :key="inbox.id"
              class="px-2 py-0.5 rounded-md text-xs bg-n-alpha-2 text-n-slate-12"
            >
              {{ inbox.name }}
            </span>
          </div>
          <AiAssistantKnowledgeBase :hook-id="hook.id" />
        </div>
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

    <woot-modal
      v-model:show="showEditHookModal"
      :on-close="() => (showEditHookModal = false)"
    >
      <NewHook
        v-if="showEditHookModal && hookToEdit"
        :key="hookToEdit.id"
        :integration-id="INTEGRATION_ID"
        :hook="hookToEdit"
        @close="showEditHookModal = false"
      />
    </woot-modal>

    <woot-delete-modal
      v-model:show="showDeleteConfirmationPopup"
      :on-close="() => (showDeleteConfirmationPopup = false)"
      :on-confirm="confirmDeletion"
      :title="$t('INTEGRATION_APPS.DELETE.TITLE.INBOX')"
      :message="$t('INTEGRATION_APPS.DELETE.MESSAGE.INBOX')"
      :confirm-text="$t('INTEGRATION_APPS.DELETE.CONFIRM_BUTTON_TEXT.INBOX')"
      :reject-text="$t('INTEGRATION_APPS.DELETE.CANCEL_BUTTON_TEXT')"
    />
  </SettingsLayout>
</template>
