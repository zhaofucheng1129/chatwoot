# 校验向量模型(OpenAI 兼容 /embeddings)是否可达,供 ai_assistant 设置页展示.
# 复用 EmbeddingService 的配置回退逻辑,用短文本 ping.返回 { success:, error: }.
class Llm::EmbeddingHealthCheckService
  pattr_initialize [:hook!]

  def perform
    service = Llm::EmbeddingService.new(texts: ['ping'], hook: hook)
    return { success: false, error: 'Embedding model not configured' } unless service.configured?

    service.perform.present? ? { success: true } : { success: false, error: 'Embedding request failed' }
  rescue StandardError => e
    { success: false, error: e.message }
  end
end
