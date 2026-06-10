import { computed } from 'vue';
import { useUISettings } from './useUISettings';
import { useAccount } from './useAccount';

/**
 * Select translation based on locale priority.
 * @param {Object} translations - Translations object with locale keys
 * @param {string} agentLocale - Agent's preferred locale
 * @param {string} accountLocale - Account's default locale
 * @returns {string|null} Selected translation or null
 */
export function selectTranslation(translations, agentLocale, accountLocale) {
  if (!translations || Object.keys(translations).length === 0) return null;

  if (agentLocale && translations[agentLocale]) {
    return translations[agentLocale];
  }
  if (accountLocale && translations[accountLocale]) {
    return translations[accountLocale];
  }
  return translations[Object.keys(translations)[0]];
}

/**
 * Normalize a locale to its base language code (e.g. "zh_CN" -> "zh").
 * @param {string} locale
 * @returns {string}
 */
export function baseLanguage(locale) {
  return (locale || '').toLowerCase().split(/[_-]/)[0];
}

/**
 * Composable to extract translation state/content from contentAttributes.
 * @param {Ref|Reactive} contentAttributes - Ref or reactive object containing `translations` property
 * @returns {Object} { hasTranslations, translationContent, detectedLanguage, accountLocale, needsTranslation }
 */
export function useTranslations(contentAttributes) {
  const { uiSettings } = useUISettings();
  const { currentAccount } = useAccount();

  const accountLocale = computed(() => currentAccount.value?.locale);

  const hasTranslations = computed(() => {
    if (!contentAttributes.value) return false;
    const { translations = {} } = contentAttributes.value;
    return Object.keys(translations || {}).length > 0;
  });

  const translationContent = computed(() => {
    if (!hasTranslations.value) return null;
    return selectTranslation(
      contentAttributes.value.translations,
      uiSettings.value?.locale,
      accountLocale.value
    );
  });

  const detectedLanguage = computed(
    () => contentAttributes.value?.detectedLanguage || null
  );

  // Same target-language resolution as the right-click translate menu,
  // so both entry points produce identical results.
  const targetLocale = computed(
    () => uiSettings.value?.locale || accountLocale.value || 'en'
  );

  // True when we know the message language and it differs from the account's
  // primary language, i.e. the agent likely needs a translation.
  const needsTranslation = computed(() => {
    if (!detectedLanguage.value || !accountLocale.value) return false;
    return (
      baseLanguage(detectedLanguage.value) !== baseLanguage(accountLocale.value)
    );
  });

  return {
    hasTranslations,
    translationContent,
    detectedLanguage,
    accountLocale,
    targetLocale,
    needsTranslation,
  };
}
