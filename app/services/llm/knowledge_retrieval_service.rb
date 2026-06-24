# 知识库检索服务:把查询文本向量化,对该 hook 下 ready 文档的切片做余弦相似度,
# 返回 top N 切片内容.用于给 AI 客服助理回复注入参考资料(RAG).
#
# 模型切换处理:仅检索 embedding_model 与当前配置一致的文档;对不一致的 ready
# 文档重新触发 DocumentProcessJob 自动重建索引.向量化失败时返回 [] 由调用方降级.
class Llm::KnowledgeRetrievalService
  pattr_initialize [:hook!, :query!]

  TOP_N = 5
  # 最小余弦相似度阈值:低于此分数的切片视为不相关,不注入(防幻觉/噪声).
  # 不同 embedding 模型相似度分布不同,上线后按实际命中分数微调.
  MIN_SIMILARITY = 0.6

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

  # 模型不一致的旧文档,触发重建后本次跳过.先置为 processing 再入队,避免后续
  # 每次查询都对同一批文档重复 perform_later(任务风暴).
  def rebuild_stale_documents
    stale = ready_documents.where.not(embedding_model: current_model)
    return if stale.empty?

    stale.find_each do |document|
      document.processing!
      AiAssistant::DocumentProcessJob.perform_later(document.id)
    end
  end

  def embed_query
    Llm::EmbeddingService.new(texts: [query], hook: hook).perform&.first
  end

  # pgvector 在库内算余弦距离并取最近的 TOP_N 条切片,只把候选(含距离)取回
  # Ruby,不再全量加载向量.neighbor_distance 是余弦距离(= 1 - 余弦相似度),
  # 据此用 MIN_SIMILARITY 过滤掉不相关切片.
  def top_chunks(vector)
    max_distance = 1.0 - MIN_SIMILARITY
    AiAssistant::DocumentChunk
      .where(document_id: fresh_document_ids)
      .nearest_neighbors(:embedding, vector, distance: 'cosine')
      .first(TOP_N)
      .select { |chunk| chunk.neighbor_distance <= max_distance }
      .map(&:content)
  end
end
