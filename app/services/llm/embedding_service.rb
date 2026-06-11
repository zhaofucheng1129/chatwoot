# 文本向量化服务,基于 OpenAI 兼容的 /embeddings 接口.
#
# 从 ai_assistant Integrations::Hook 的 settings 读取向量模型配置:
# embedding_base_url/embedding_api_key 缺省时回退 base_url/api_key,
# embedding_model 为空表示未启用知识库.批量传入文本,返回等长的向量数组;
# 请求失败返回 nil 由调用方降级处理.
class Llm::EmbeddingService
  pattr_initialize [:texts!, :hook!]

  MAX_RETRY = 3
  TIMEOUT = 30

  def configured?
    model.present? && base_url.present? && api_key.present?
  end

  # 返回与 texts 等长的向量数组(每项为 Float 数组),失败返回 nil.
  def perform
    return if texts.blank? || !configured?

    response = request_with_retry
    return unless response

    extract_embeddings(response)
  end

  private

  def settings
    @settings ||= hook.settings || {}
  end

  def model
    settings['embedding_model']
  end

  def base_url
    settings['embedding_base_url'].presence || settings['base_url']
  end

  def api_key
    settings['embedding_api_key'].presence || settings['api_key']
  end

  def request_with_retry
    (1..MAX_RETRY).each do |attempt|
      response = post_request
      return response if response.success?

      # 免费档模型常见 429 限流,退避后重试;其它错误码直接放弃.
      break unless response.code == 429 && attempt < MAX_RETRY

      sleep(attempt * 1.5)
    end
    nil
  rescue StandardError => e
    Rails.logger.error("[Llm::EmbeddingService] request failed #{e.class}: #{e.message}")
    nil
  end

  def post_request
    HTTParty.post(
      "#{base_url.to_s.chomp('/')}/embeddings",
      headers: { 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{api_key}" },
      body: { model: model, input: Array(texts) }.to_json,
      timeout: TIMEOUT
    )
  end

  # 按 index 排序还原顺序,返回纯向量数组.
  def extract_embeddings(response)
    data = response.parsed_response['data']
    return unless data.is_a?(Array)

    data.sort_by { |item| item['index'].to_i }.pluck('embedding')
  end
end
