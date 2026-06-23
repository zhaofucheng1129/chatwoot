# Translates text using OpenAI-compatible LLM providers.
#
# Providers are configured per account via the "llm_translator" integration
# (Settings -> Integrations), each with { name, base_url, api_key, model,
# priority }. They are tried in ascending priority order and the service fails
# over to the next provider when one errors out, improving reliability.
#
# When no account providers exist it falls back to env config
# (LLM_TRANSLATE_BASE_URL / LLM_TRANSLATE_API_KEY / LLM_TRANSLATE_MODEL) so
# existing single-provider setups keep working.
class Llm::TranslationService
  pattr_initialize [:content!, :target_language!, :account]

  INTEGRATION_APP_ID = 'llm_translator'.freeze
  MAX_RETRY = 3

  # Map locale codes (account locale) to a human language name the model understands.
  LANGUAGE_NAMES = {
    'en' => 'English', 'zh' => '简体中文', 'zh_CN' => '简体中文', 'zh_TW' => '繁体中文',
    'ja' => '日本語', 'ko' => '한국어', 'fr' => 'Français', 'de' => 'Deutsch',
    'es' => 'Español', 'pt' => 'Português', 'pt_BR' => 'Português (Brasil)',
    'ru' => 'Русский', 'it' => 'Italiano', 'ar' => 'العربية', 'nl' => 'Nederlands',
    'tr' => 'Türkçe', 'th' => 'ไทย', 'vi' => 'Tiếng Việt', 'id' => 'Bahasa Indonesia'
  }.freeze

  def configured?
    providers.any?
  end

  def perform
    return if content.blank?

    providers.each do |provider|
      result = translate_with(provider)
      return result if result.present?
    end
    nil
  end

  private

  def providers
    @providers ||= account_providers.presence || Array(env_provider)
  end

  def account_providers
    return [] if account.blank?

    hooks = account.hooks.where(app_id: INTEGRATION_APP_ID).select(&:enabled?)
    providers = hooks.filter_map { |hook| provider_from_settings(hook.settings || {}) }
    providers.sort_by { |provider| provider[:priority] }
  end

  def provider_from_settings(settings)
    return if settings['base_url'].blank? || settings['api_key'].blank? || settings['model'].blank?

    {
      base_url: settings['base_url'], api_key: settings['api_key'],
      model: settings['model'], priority: settings['priority'].to_i
    }
  end

  def env_provider
    base_url = ENV.fetch('LLM_TRANSLATE_BASE_URL', nil)
    api_key = ENV.fetch('LLM_TRANSLATE_API_KEY', nil)
    return if base_url.blank? || api_key.blank?

    {
      base_url: base_url, api_key: api_key,
      model: ENV.fetch('LLM_TRANSLATE_MODEL', 'gemini-2.5-flash'), priority: 0
    }
  end

  # Returns the translated text, or nil so the caller can fail over.
  def translate_with(provider)
    (1..MAX_RETRY).each do |attempt|
      response = post_request(provider)
      return extract_content(response) if response.success?

      # Free-tier models are rate-limited (429); back off and retry.
      break unless response.code == 429 && attempt < MAX_RETRY

      sleep(attempt * 1.5)
    end
    nil
  rescue StandardError => e
    Rails.logger.error("[Llm::TranslationService] provider failed #{e.class}: #{e.message}")
    nil
  end

  def post_request(provider)
    HTTParty.post(
      "#{provider[:base_url].chomp('/')}/chat/completions",
      headers: { 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{provider[:api_key]}" },
      body: request_body(provider[:model]),
      # Split the timeouts: a short open_timeout fails over fast when a provider
      # is unreachable (e.g. a blocked endpoint) instead of stalling ~45s, while
      # a generous read_timeout still lets a connected-but-slow model finish
      # (long messages / load) so legitimate translations are not cut off.
      open_timeout: 5,
      read_timeout: 30
    )
  end

  def extract_content(response)
    response.parsed_response.dig('choices', 0, 'message', 'content')&.strip
  end

  def request_body(model)
    {
      model: model,
      temperature: 0.3,
      messages: [
        { role: 'system', content: system_prompt },
        { role: 'user', content: content }
      ]
    }.to_json
  end

  def system_prompt
    "You are a professional translator. Translate the user's message into #{language_name}. " \
      'Output only the translated text, without explanations, quotes or extra formatting.'
  end

  def language_name
    LANGUAGE_NAMES[target_language] || LANGUAGE_NAMES[target_language.to_s.split('_').first] || target_language
  end
end
