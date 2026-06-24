<script setup>
import { ref, computed } from 'vue';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { messageTimestamp } from 'shared/helpers/timeHelper';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import AiAssistantDocumentsAPI from 'dashboard/api/aiAssistantDocuments';

const props = defineProps({
  hookId: {
    type: [Number, String],
    required: true,
  },
});

const { t } = useI18n();

// Rebuild 轮询:每 2s 拉一次状态,最多 30 次(~1 分钟),直到没有 processing 文档.
const REBUILD_POLL_INTERVAL = 2000;
const REBUILD_MAX_POLLS = 30;

const sleep = ms =>
  new Promise(resolve => {
    setTimeout(resolve, ms);
  });

const expanded = ref(false);
const isLoading = ref(false);
const hasLoaded = ref(false);
const documents = ref([]);
const isReprocessing = ref(false);

const showAddModal = ref(false);
const isSubmitting = ref(false);
const formTitle = ref('');
const formContent = ref('');
const fileInput = ref(null);
// null = 新增模式; 文档 id = 编辑模式
const editingId = ref(null);

const showDeleteModal = ref(false);
const selectedDocument = ref({});

const STATUS_STYLES = {
  processing: 'bg-n-amber-9',
  ready: 'bg-n-teal-9',
  failed: 'bg-n-ruby-9',
};

const statusDotClass = status =>
  STATUS_STYLES[status] || STATUS_STYLES.processing;

// created_at comes from the API as an ISO8601 string; messageTimestamp expects
// unix seconds, so convert. Stay tolerant if it ever arrives as an epoch number.
const formattedDate = createdAt => {
  if (!createdAt) return '';
  const unix =
    typeof createdAt === 'number'
      ? createdAt
      : Math.floor(new Date(createdAt).getTime() / 1000);
  return messageTimestamp(unix);
};

const fetchDocuments = async (silent = false) => {
  if (!silent) isLoading.value = true;
  try {
    const { data } = await AiAssistantDocumentsAPI.list(props.hookId);
    documents.value = data || [];
    hasLoaded.value = true;
  } catch (error) {
    // 轮询(silent)时不弹错误,避免刷屏;只在用户主动加载时提示.
    if (!silent) {
      useAlert(
        t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.LIST_API.ERROR_MESSAGE')
      );
    }
  } finally {
    if (!silent) isLoading.value = false;
  }
};

const toggleExpanded = () => {
  expanded.value = !expanded.value;
  if (expanded.value && !hasLoaded.value) {
    fetchDocuments();
  }
};

const openAddModal = () => {
  editingId.value = null;
  formTitle.value = '';
  formContent.value = '';
  showAddModal.value = true;
};

const openEditModal = async document => {
  try {
    const { data } = await AiAssistantDocumentsAPI.show(document.id);
    formTitle.value = data.title || '';
    formContent.value = data.content || '';
    editingId.value = document.id;
    showAddModal.value = true;
  } catch (error) {
    useAlert(t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.FORM.LOAD_ERROR'));
  }
};

const rebuildIndex = async () => {
  isReprocessing.value = true;
  try {
    try {
      await AiAssistantDocumentsAPI.reprocess(props.hookId);
    } catch (error) {
      useAlert(
        t(
          'INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.REBUILD.API.ERROR_MESSAGE'
        )
      );
      return;
    }

    // 重建是异步的(Sidekiq),轮询刷新状态,文档状态点会随之 red->amber->green
    // 实时变化,直到没有 processing 或超时为止.
    for (let i = 0; i < REBUILD_MAX_POLLS; i += 1) {
      // eslint-disable-next-line no-await-in-loop
      await fetchDocuments(true);
      const stillProcessing = documents.value.some(
        document => document.status === 'processing'
      );
      if (!stillProcessing) break;
      // eslint-disable-next-line no-await-in-loop
      await sleep(REBUILD_POLL_INTERVAL);
    }

    const failures = documents.value.filter(
      document => document.status === 'failed'
    );
    if (failures.length === 0) {
      useAlert(
        t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.REBUILD.API.DONE')
      );
    } else {
      useAlert(
        t(
          'INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.REBUILD.API.DONE_WITH_FAILURES',
          { count: failures.length }
        )
      );
    }
  } finally {
    isReprocessing.value = false;
  }
};

const onFileChange = event => {
  const file = event.target.files?.[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = () => {
    formContent.value = reader.result || '';
    if (!formTitle.value) {
      formTitle.value = file.name.replace(/\.[^/.]+$/, '');
    }
  };
  reader.onerror = () => {
    useAlert(
      t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.FORM.UPLOAD_ERROR')
    );
  };
  reader.readAsText(file);
  event.target.value = '';
};

const isFormValid = computed(
  () => formTitle.value.trim() && formContent.value.trim()
);

const submitDocument = async () => {
  if (!isFormValid.value) {
    useAlert(t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.FORM.VALIDATION'));
    return;
  }
  isSubmitting.value = true;
  try {
    if (editingId.value) {
      await AiAssistantDocumentsAPI.update({
        id: editingId.value,
        title: formTitle.value.trim(),
        content: formContent.value.trim(),
      });
      useAlert(
        t(
          'INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.FORM.API.UPDATE_SUCCESS_MESSAGE'
        )
      );
    } else {
      await AiAssistantDocumentsAPI.create({
        hookId: props.hookId,
        title: formTitle.value.trim(),
        content: formContent.value.trim(),
      });
      useAlert(
        t(
          'INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.FORM.API.SUCCESS_MESSAGE'
        )
      );
    }
    showAddModal.value = false;
    await fetchDocuments();
  } catch (error) {
    if (editingId.value) {
      useAlert(
        t(
          'INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.FORM.API.UPDATE_ERROR_MESSAGE'
        )
      );
    } else {
      useAlert(
        t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.FORM.API.ERROR_MESSAGE')
      );
    }
  } finally {
    isSubmitting.value = false;
  }
};

const openDeleteModal = document => {
  selectedDocument.value = document;
  showDeleteModal.value = true;
};

const confirmDeletion = async () => {
  try {
    await AiAssistantDocumentsAPI.delete(selectedDocument.value.id);
    useAlert(
      t(
        'INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.DELETE.API.SUCCESS_MESSAGE'
      )
    );
    await fetchDocuments();
  } catch (error) {
    useAlert(
      t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.DELETE.API.ERROR_MESSAGE')
    );
  } finally {
    showDeleteModal.value = false;
  }
};
</script>

<template>
  <div class="flex flex-col w-full">
    <button
      class="flex items-center gap-2 text-xs font-medium text-n-slate-11 hover:text-n-slate-12"
      @click="toggleExpanded"
    >
      <Icon
        :icon="expanded ? 'i-lucide-chevron-down' : 'i-lucide-chevron-right'"
        class="size-4"
      />
      {{ $t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.TOGGLE') }}
    </button>

    <div v-if="expanded" class="flex flex-col gap-2 mt-3 pl-6">
      <div class="flex items-center justify-between gap-2">
        <p class="text-xs text-n-slate-11">
          {{ $t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.HINT') }}
        </p>
        <div class="flex items-center gap-2 shrink-0">
          <NextButton
            slate
            faded
            xs
            icon="i-lucide-refresh-cw"
            :label="
              $t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.REFRESH_BUTTON')
            "
            :disabled="isLoading"
            @click="fetchDocuments"
          />
          <NextButton
            slate
            faded
            xs
            icon="i-lucide-database-zap"
            :label="
              $t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.REBUILD_BUTTON')
            "
            :is-loading="isReprocessing"
            :disabled="isReprocessing || !documents.length"
            @click="rebuildIndex"
          />
          <NextButton
            blue
            xs
            icon="i-lucide-plus"
            :label="
              $t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.ADD_BUTTON')
            "
            @click="openAddModal"
          />
        </div>
      </div>

      <p v-if="isLoading" class="text-xs text-n-slate-11">
        {{ $t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.LOADING') }}
      </p>
      <p v-else-if="!documents.length" class="text-xs text-n-slate-11">
        {{ $t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.EMPTY') }}
      </p>
      <div v-else class="flex flex-col gap-2">
        <div
          v-for="document in documents"
          :key="document.id"
          class="flex items-center gap-3 px-3 py-2 rounded-md border border-n-weak bg-n-solid-2"
        >
          <div class="flex flex-col min-w-0 flex-1">
            <span class="text-sm text-n-slate-12 truncate">
              {{ document.title }}
            </span>
            <span
              v-if="document.content_preview"
              class="text-xs text-n-slate-11 truncate"
            >
              {{ document.content_preview }}
            </span>
            <span class="text-xs text-n-slate-11 truncate">
              {{ formattedDate(document.created_at) }}
            </span>
          </div>
          <span
            class="flex items-center gap-1 text-xs text-n-slate-11 shrink-0"
          >
            <span
              class="size-2 rounded-full"
              :class="statusDotClass(document.status)"
            />
            <span v-if="document.status === 'ready'">
              {{
                $t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.STATUS.READY')
              }}
            </span>
            <span v-else-if="document.status === 'failed'">
              {{
                $t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.STATUS.FAILED')
              }}
            </span>
            <span v-else>
              {{
                $t(
                  'INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.STATUS.PROCESSING'
                )
              }}
            </span>
          </span>
          <NextButton
            slate
            faded
            xs
            icon="i-lucide-pencil"
            @click="openEditModal(document)"
          />
          <NextButton
            ruby
            faded
            xs
            icon="i-lucide-trash-2"
            @click="openDeleteModal(document)"
          />
        </div>
      </div>
    </div>

    <woot-modal
      v-model:show="showAddModal"
      :on-close="() => (showAddModal = false)"
    >
      <div class="flex flex-col gap-4 p-8">
        <h2 class="text-xl font-medium text-n-slate-12">
          {{
            editingId
              ? $t(
                  'INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.FORM.EDIT_TITLE'
                )
              : $t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.FORM.TITLE')
          }}
        </h2>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{
            $t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.FORM.TITLE_LABEL')
          }}
          <input
            v-model="formTitle"
            type="text"
            class="w-full"
            :placeholder="
              $t(
                'INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.FORM.TITLE_PLACEHOLDER'
              )
            "
          />
        </label>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{
            $t(
              'INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.FORM.CONTENT_LABEL'
            )
          }}
          <textarea
            v-model="formContent"
            rows="8"
            class="w-full"
            :placeholder="
              $t(
                'INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.FORM.CONTENT_PLACEHOLDER'
              )
            "
          />
        </label>
        <label
          class="flex items-center gap-2 text-xs text-n-slate-11 cursor-pointer"
        >
          <Icon icon="i-lucide-upload" class="size-4" />
          {{
            $t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.FORM.UPLOAD_HINT')
          }}
          <input
            ref="fileInput"
            type="file"
            accept=".txt,.md,text/plain,text/markdown"
            class="hidden"
            @change="onFileChange"
          />
        </label>
        <div class="flex items-center justify-end gap-2">
          <NextButton
            slate
            faded
            :label="
              $t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.FORM.CANCEL')
            "
            @click="showAddModal = false"
          />
          <NextButton
            blue
            :label="
              editingId
                ? $t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.FORM.SAVE')
                : $t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.FORM.SUBMIT')
            "
            :is-loading="isSubmitting"
            :disabled="isSubmitting || !isFormValid"
            @click="submitDocument"
          />
        </div>
      </div>
    </woot-modal>

    <woot-delete-modal
      v-model:show="showDeleteModal"
      :on-close="() => (showDeleteModal = false)"
      :on-confirm="confirmDeletion"
      :title="$t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.DELETE.TITLE')"
      :message="
        $t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.DELETE.MESSAGE')
      "
      :confirm-text="
        $t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.DELETE.CONFIRM')
      "
      :reject-text="
        $t('INTEGRATION_APPS.AI_ASSISTANT.KNOWLEDGE_BASE.DELETE.CANCEL')
      "
    />
  </div>
</template>
