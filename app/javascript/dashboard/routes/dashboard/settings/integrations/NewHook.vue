<!-- eslint-disable vue/v-slot-style -->
<script>
import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';
import { useIntegrationHook } from 'dashboard/composables/useIntegrationHook';
import { FormKit } from '@formkit/vue';
import { useBranding } from 'shared/composables/useBranding';

import NextButton from 'dashboard/components-next/button/Button.vue';

export default {
  components: {
    FormKit,
    NextButton,
  },
  props: {
    integrationId: {
      type: String,
      required: true,
    },
    // 传入既有 hook 时进入编辑模式: 预填 settings 并改走更新接口
    hook: {
      type: Object,
      default: null,
    },
  },
  emits: ['close'],
  setup(props) {
    const { integration, isHookTypeInbox } = useIntegrationHook(
      props.integrationId
    );
    const { replaceInstallationName } = useBranding();

    return { integration, isHookTypeInbox, replaceInstallationName };
  },
  data() {
    const settings = this.hook?.settings || {};
    // 编辑模式预填: JSON 类型字段(对象)需转回字符串供文本框展示
    const values = Object.keys(settings).reduce((acc, key) => {
      const value = settings[key];
      acc[key] =
        typeof value === 'object' && value !== null
          ? JSON.stringify(value)
          : value;
      return acc;
    }, {});
    // ai_assistant 助理: 编辑模式预填已关联的收件箱(多选)
    if (this.integrationId === 'ai_assistant') {
      values.inbox_ids = (this.hook?.inboxes || []).map(inbox => inbox.id);
    }
    return {
      endPoint: '',
      alertMessage: '',
      values,
    };
  },
  computed: {
    ...mapGetters({
      uiFlags: 'integrations/getUIFlags',
      dialogFlowEnabledInboxes: 'inboxes/dialogFlowEnabledInboxes',
    }),
    isAiAssistant() {
      return this.integration.id === 'ai_assistant';
    },
    inboxes() {
      return this.dialogFlowEnabledInboxes
        .filter(inbox => {
          if (!this.isHookTypeInbox) {
            return true;
          }
          return !this.connectedInboxIds.includes(inbox.id);
        })
        .map(inbox => ({ label: inbox.name, value: inbox.id }));
    },

    // 按收件箱绑定的集成: 同一收件箱只允许归属一个配置/助理, 已占用的从可选项中排除.
    // ai_assistant 一个助理可关联多个收件箱(hook.inboxes 数组), 且编辑时放行本助理已选的;
    // 其它集成(dialogflow)仍是单个 hook.inbox.
    connectedInboxIds() {
      if (!this.isHookTypeInbox) {
        return [];
      }
      if (this.isAiAssistant) {
        return this.integration.hooks
          .filter(hook => !this.isEditing || hook.id !== this.hook.id)
          .flatMap(hook => (hook.inboxes || []).map(inbox => inbox.id));
      }
      return this.integration.hooks.map(hook => hook.inbox?.id);
    },
    formItems() {
      return this.integration.settings_form_schema;
    },
    isEditing() {
      return !!this.hook;
    },
    submitButtonLabel() {
      if (this.isEditing) {
        return this.$t('INTEGRATION_APPS.EDIT.FORM.SUBMIT');
      }
      if (this.integration.id === 'openai' && this.uiFlags.isCreatingHook) {
        return this.$t('INTEGRATION_APPS.ADD.FORM.VALIDATING_OPENAI');
      }

      return this.$t('INTEGRATION_APPS.ADD.FORM.SUBMIT');
    },
  },
  methods: {
    onClose() {
      this.$emit('close');
    },
    buildHookPayload() {
      const hookPayload = {
        app_id: this.integration.id,
        settings: {},
      };

      // inbox / inbox_ids 是收件箱关联字段, 不属于 settings
      hookPayload.settings = Object.keys(this.values).reduce((acc, key) => {
        if (key !== 'inbox' && key !== 'inbox_ids') {
          acc[key] = this.values[key];
        }
        return acc;
      }, {});

      this.formItems.forEach(item => {
        if (item.validation?.includes('JSON')) {
          hookPayload.settings[item.name] = JSON.parse(
            hookPayload.settings[item.name]
          );
        }
      });

      if (this.isHookTypeInbox) {
        if (this.isAiAssistant) {
          // 一个助理关联多个收件箱
          hookPayload.inbox_ids = this.values.inbox_ids || [];
        } else if (this.values.inbox) {
          hookPayload.inbox_id = this.values.inbox;
        }
      }

      return hookPayload;
    },
    async submitForm() {
      try {
        if (this.isEditing) {
          const updatePayload = {
            hookId: this.hook.id,
            settings: this.buildHookPayload().settings,
          };
          // ai_assistant 助理编辑时同步关联收件箱
          if (this.isAiAssistant) {
            updatePayload.inboxIds = this.values.inbox_ids || [];
          }
          await this.$store.dispatch('integrations/updateHook', updatePayload);
          this.alertMessage = this.$t(
            'INTEGRATION_APPS.EDIT.API.SUCCESS_MESSAGE'
          );
        } else {
          await this.$store.dispatch(
            'integrations/createHook',
            this.buildHookPayload()
          );
          this.alertMessage = this.$t(
            'INTEGRATION_APPS.ADD.API.SUCCESS_MESSAGE'
          );
        }
        this.onClose();
      } catch (error) {
        const errorMessage = error?.response?.data?.message;
        this.alertMessage =
          errorMessage || this.$t('INTEGRATION_APPS.ADD.API.ERROR_MESSAGE');
      } finally {
        useAlert(this.alertMessage);
      }
    },
  },
};
</script>

<template>
  <div class="flex flex-col h-auto overflow-auto integration-hooks">
    <woot-modal-header
      :header-title="integration.name"
      :header-content="replaceInstallationName(integration.short_description)"
    />
    <FormKit
      v-model="values"
      type="form"
      form-class="w-full grid gap-4"
      :submit-attrs="{
        inputClass: 'hidden',
        wrapperClass: 'hidden',
      }"
      :incomplete-message="false"
      @submit="submitForm"
    >
      <FormKit v-for="item in formItems" :key="item.name" v-bind="item" />
      <!-- ai_assistant: 一个助理可关联多个收件箱(多选), 创建与编辑均可调整 -->
      <FormKit
        v-if="isHookTypeInbox && isAiAssistant"
        :options="inboxes"
        type="checkbox"
        name="inbox_ids"
        :label="$t('INTEGRATION_APPS.AI_ASSISTANT.FORM.INBOXES.LABEL')"
        :help="$t('INTEGRATION_APPS.AI_ASSISTANT.FORM.INBOXES.HELP')"
        validation="required"
        :validation-messages="{
          required: $t('INTEGRATION_APPS.AI_ASSISTANT.FORM.INBOXES.REQUIRED'),
        }"
        validation-name="Inboxes"
      />
      <!-- 其它 inbox 型集成(dialogflow 等): 单选, 仅创建时可选 -->
      <FormKit
        v-else-if="isHookTypeInbox && !isEditing"
        :options="inboxes"
        type="select"
        name="inbox"
        input-class="reset-base"
        :placeholder="$t('INTEGRATION_APPS.ADD.FORM.INBOX.LABEL')"
        :label="$t('INTEGRATION_APPS.ADD.FORM.INBOX.PLACEHOLDER')"
        validation="required"
        validation-name="Inbox"
      />
      <div class="flex flex-row justify-end w-full gap-2 px-0 py-2">
        <NextButton
          faded
          slate
          type="reset"
          :label="$t('INTEGRATION_APPS.ADD.FORM.CANCEL')"
          @click.prevent="onClose"
        />
        <NextButton
          type="submit"
          :label="submitButtonLabel"
          :is-loading="uiFlags.isCreatingHook || uiFlags.isUpdatingHook"
        />
      </div>
    </FormKit>
  </div>
</template>

<style lang="css">
.formkit-outer {
  @apply mt-2;
}

.formkit-form > .formkit-wrapper > ul.formkit-messages {
  @apply hidden;
}

.formkit-form .formkit-help {
  @apply text-n-slate-10 text-sm font-normal mt-2 w-full;
}

/* equivalent of .reset-base */
.formkit-input {
  margin-bottom: 0px !important;
}

[data-invalid] .formkit-message {
  @apply text-n-ruby-9 block text-xs font-normal my-1 w-full;
}

.formkit-outer[data-type='checkbox'] .formkit-wrapper {
  @apply flex items-center gap-2 px-0.5;
}

.formkit-messages {
  @apply list-none m-0 p-0;
}

.formkit-actions {
  @apply hidden;
}
</style>
