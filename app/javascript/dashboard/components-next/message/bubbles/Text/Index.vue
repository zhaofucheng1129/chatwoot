<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert, useTrack } from 'dashboard/composables';
import { CONVERSATION_EVENTS } from 'dashboard/helper/AnalyticsHelper/events';
import BaseBubble from 'next/message/bubbles/Base.vue';
import FormattedContent from './FormattedContent.vue';
import AttachmentChips from 'next/message/chips/AttachmentChips.vue';
import { MESSAGE_TYPES } from '../../constants';
import { useMessageContext } from '../../provider.js';
import { useTranslations } from 'dashboard/composables/useTranslations';

const { t } = useI18n();
const store = useStore();
const {
  content,
  attachments,
  contentAttributes,
  messageType,
  conversationId,
  id,
} = useMessageContext();

const { hasTranslations, translationContent, needsTranslation, targetLocale } =
  useTranslations(contentAttributes);

// Translating state lives in the store so the bubble button and the
// right-click "Translate" menu reflect the same in-progress state.
const messagesTranslating = useMapGetter('getMessagesTranslating');
const isTranslating = computed(() => !!messagesTranslating.value[id.value]);

const isTemplate = computed(() => {
  return messageType.value === MESSAGE_TYPES.TEMPLATE;
});

const isIncoming = computed(() => {
  return messageType.value === MESSAGE_TYPES.INCOMING;
});

const isEmpty = computed(() => {
  return !content.value && !attachments.value?.length;
});

// Offer the translate button only on received messages whose language
// differs from the account's primary language and not yet translated.
const showTranslateButton = computed(() => {
  return (
    isIncoming.value &&
    !!content.value &&
    needsTranslation.value &&
    !hasTranslations.value
  );
});

// Same behaviour as the right-click "Translate" menu, just a different entry
// point: dispatch the translate action, then the translated message arrives
// via the message.updated websocket and replaces the button with the
// original/translation comparison.
const handleTranslate = async () => {
  if (isTranslating.value) return;
  try {
    const data = await store.dispatch('translateMessage', {
      conversationId: conversationId.value,
      messageId: id.value,
      targetLanguage: targetLocale.value,
    });
    useTrack(CONVERSATION_EVENTS.TRANSLATE_A_MESSAGE);

    // Empty content means the translation failed (e.g. the model was rate
    // limited); surface it so the agent can retry.
    if (!data?.content) useAlert(t('CONVERSATION.TRANSLATION_FAILED'));
  } catch (error) {
    useAlert(t('CONVERSATION.TRANSLATION_FAILED'));
  }
};
</script>

<template>
  <BaseBubble class="px-4 py-3" data-bubble-name="text">
    <div class="gap-3 flex flex-col">
      <span v-if="isEmpty" class="text-n-slate-11">
        {{ $t('CONVERSATION.NO_CONTENT') }}
      </span>

      <FormattedContent v-if="content" :content="content" />

      <!-- Original / translation side-by-side comparison -->
      <template v-if="hasTranslations && translationContent">
        <div class="flex items-center gap-2 -my-1">
          <div class="h-px flex-1 bg-n-strong" />
          <span class="text-xs text-n-slate-11 shrink-0">
            {{ $t('CONVERSATION.TRANSLATION_TEXT') }}
          </span>
          <div class="h-px flex-1 bg-n-strong" />
        </div>
        <FormattedContent :content="translationContent" />
      </template>

      <!-- Translate button at the bubble bottom -->
      <button
        v-else-if="showTranslateButton"
        type="button"
        :disabled="isTranslating"
        class="self-end text-xs font-medium text-n-blue-11 underline underline-offset-2 cursor-pointer select-none hover:enabled:text-n-blue-10 disabled:cursor-default disabled:opacity-60"
        @click="handleTranslate"
      >
        {{
          isTranslating
            ? $t('CONVERSATION.TRANSLATING')
            : $t('CONVERSATION.TRANSLATE_MESSAGE')
        }}
      </button>

      <AttachmentChips :attachments="attachments" class="gap-2" />
      <template v-if="isTemplate">
        <div
          v-if="contentAttributes.submittedEmail"
          class="px-2 py-1 rounded-lg bg-n-alpha-3"
        >
          {{ contentAttributes.submittedEmail }}
        </div>
      </template>
    </div>
  </BaseBubble>
</template>

<style>
p:last-child {
  margin-bottom: 0;
}
</style>
