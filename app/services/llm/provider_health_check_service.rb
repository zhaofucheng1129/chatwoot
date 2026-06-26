# Verifies that an LLM translation provider (OpenAI-compatible) is reachable
# and the credentials/model work, by sending a minimal chat completion.
# Returns { success:, latency_ms:, error: } for the settings UI.
class Llm::ProviderHealthCheckService
  pattr_initialize [:settings!]

  TIMEOUT = 15

  def perform
    started_at = Time.zone.now
    response = post_ping
    result(response, started_at)
  rescue StandardError => e
    { success: false, error: e.message }
  end

  private

  def post_ping
    HTTParty.post(
      "#{settings['base_url'].to_s.chomp('/')}/chat/completions",
      headers: { 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{settings['api_key']}" },
      body: ping_body.to_json,
      timeout: TIMEOUT
    )
  end

  def ping_body
    body = {
      model: settings['model'],
      max_tokens: 5,
      messages: [{ role: 'user', content: 'ping' }]
    }
    # Volcengine Doubao reasoning models default to chain-of-thought, which
    # pushes latency past the timeout. Disabling it keeps the ping fast.
    body[:thinking] = { type: 'disabled' } if ActiveModel::Type::Boolean.new.cast(settings['disable_thinking'])
    body
  end

  def result(response, started_at)
    latency_ms = ((Time.zone.now - started_at) * 1000).round
    return { success: true, latency_ms: latency_ms } if response.success?

    { success: false, latency_ms: latency_ms, error: error_message(response) }
  end

  def error_message(response)
    ["HTTP #{response.code}", error_detail(response)].compact.join(': ')
  end

  def error_detail(response)
    parsed = response.parsed_response
    # Some providers (e.g. Gemini) wrap the error object in an array.
    parsed = parsed.first if parsed.is_a?(Array)
    parsed.dig('error', 'message') if parsed.is_a?(Hash)
  rescue StandardError
    nil
  end
end
