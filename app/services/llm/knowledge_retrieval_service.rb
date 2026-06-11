# 知识库检索服务:把查询文本向量化,对该 hook 下 ready 文档的切片做余弦相似度,
# 返回 top N 切片内容.用于给 AI 客服助理回复注入参考资料(RAG).
#
# 模型切换处理:仅检索 embedding_model 与当前配置一致的文档;对不一致的 ready
# 文档重新触发 DocumentProcessJob 自动重建索引.向量化失败时返回 [] 由调用方降级.
class Llm::KnowledgeRetrievalService
  pattr_initialize [:hook!, :query!]

  TOP_N = 5

  def perform
    return [] if current_model.blank? || query.blank?

    rebuild_stale_documents
    return [] if fresh_document_ids.blank?

    vector = embed_query
    return [] if vector.blank?

    top_chunks(vector)
  end

  private

  def settings
    @settings ||= hook.settings || {}
  end

  def current_model
    settings['embedding_model']
  end

  def ready_documents
    @ready_documents ||= hook.ai_assistant_documents.where(status: :ready)
  end

  # 与当前 embedding_model 一致的文档,可直接检索
  def fresh_document_ids
    @fresh_document_ids ||= ready_documents.where(embedding_model: current_model).pluck(:id)
  end

  # 模型不一致的旧文档,触发重建后本次跳过
  def rebuild_stale_documents
    ready_documents.where.not(embedding_model: current_model).find_each do |document|
      AiAssistant::DocumentProcessJob.perform_later(document.id)
    end
  end

  def embed_query
    Llm::EmbeddingService.new(texts: [query], hook: hook).perform&.first
  end

  # 全量加载切片(量级几百)在 Ruby 内做余弦相似度,取 top N.
  def top_chunks(vector)
    rows = AiAssistant::DocumentChunk.where(document_id: fresh_document_ids).pluck(:content, :embedding)
    rows.filter_map { |content, embedding| score_row(content, embedding, vector) }
        .sort_by { |item| -item[:score] }
        .first(TOP_N)
        .pluck(:content)
  end

  def score_row(content, embedding, vector)
    return if embedding.blank?

    { content: content, score: cosine_similarity(vector, embedding) }
  end

  def cosine_similarity(vec_a, vec_b)
    dot = 0.0
    norm_a = 0.0
    norm_b = 0.0
    vec_a.each_with_index do |val, index|
      other = vec_b[index].to_f
      dot += val * other
      norm_a += val * val
      norm_b += other * other
    end
    return 0.0 if norm_a.zero? || norm_b.zero?

    dot / (Math.sqrt(norm_a) * Math.sqrt(norm_b))
  end
end
