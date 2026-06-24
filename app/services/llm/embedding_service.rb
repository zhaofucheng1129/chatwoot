# 文本向量化服务.支持两类供应商接口:
#   - OpenAI 兼容文本接口 /embeddings:一次请求批量返回等长向量(文本模型);
#   - 火山方舟多模态接口 /embeddings/multimodal:input 为 content 数组,单次仅
#     返回一个向量,需逐条请求(doubao-embedding-vision 等多模态模型).
#
# 从 ai_assistant Integrations::Hook 的 settings 读取向量模型配置:
# embedding_base_url/embedding_api_key 缺省时回退 base_url/api_key,
# embedding_model 为空表示未启用知识库.批量传入文本,返回等长的向量数组;
# 请求失败返回 nil 由调用方降级处理.
class Llm::EmbeddingService
  pattr_initialize [:texts!, :hook!]

  MAX_RETRY = 3
  OPEN_TIMEOUT = 5
  TIMEOUT = 30

  def configured?
    model.present? && base_url.present? && api_key.present?
  end

  # 返回与 texts 等长的向量数组(每项为 Float 数组),失败返回 nil.
  def perform
    return if texts.blank? || !configured?

    multimodal? ? embed_multimodal : embed_text_batch
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

  # 多模态向量模型(doubao-embedding-vision)走独立的 /embeddings/multimodal 接口,
  # input 是 content 数组且单次仅返回一个向量,需逐条请求(不能批量).
  def multimodal?
    model.to_s.include?('vision') || model.to_s.include?('multimodal')
  end

  # 文本模型:一次请求批量返回,按 index 排序还原顺序.
  def embed_text_batch
    response = request_with_retry { post_text }
    return unless response

    data = response.parsed_response['data']
    return unless data.is_a?(Array)

    data.sort_by { |item| item['index'].to_i }.pluck('embedding')
  end

  # 多模态模型:逐条请求;任一条失败(向量为空)则整体返回 nil 由调用方降级.
  def embed_multimodal
    vectors = texts.map do |text|
      response = request_with_retry { post_multimodal(text) }
      response&.parsed_response&.dig('data', 'embedding')
    end
    return if vectors.any?(&:blank?)

    vectors
  end

  def request_with_retry
    (1..MAX_RETRY).each do |attempt|
      response = yield
      return response if response.success?

      # 429 限流或 5xx 服务端错误才退避重试;4xx(鉴权/参数)直接放弃.
      break unless (response.code == 429 || response.code >= 500) && attempt < MAX_RETRY

      sleep(attempt * 1.5)
    end
    nil
  rescue StandardError => e
    Rails.logger.error("[Llm::EmbeddingService] request failed #{e.class}: #{e.message}")
    nil
  end

  def post_text
    HTTParty.post(
      "#{base_url.to_s.chomp('/')}/embeddings",
      headers: auth_headers,
      body: { model: model, input: Array(texts) }.to_json,
      open_timeout: OPEN_TIMEOUT,
      read_timeout: TIMEOUT
    )
  end

  def post_multimodal(text)
    HTTParty.post(
      "#{base_url.to_s.chomp('/')}/embeddings/multimodal",
      headers: auth_headers,
      body: {
        model: model,
        encoding_format: 'float',
        input: [{ type: 'text', text: text }]
      }.to_json,
      open_timeout: OPEN_TIMEOUT,
      read_timeout: TIMEOUT
    )
  end

  def auth_headers
    { 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{api_key}" }
  end
end
