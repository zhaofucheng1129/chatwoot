# 知识库文档处理 Job:切片 -> 向量化 -> 写入 chunks.
#
# 幂等:重跑前清空旧 chunks.任一批向量化失败则整篇标记 failed.
# 成功后记录所用 embedding_model,供后续检测模型切换并自动重建.
class AiAssistant::DocumentProcessJob < ApplicationJob
  queue_as :low

  # 切片参数:每片约 800 字符,相邻片重叠约 100 字符
  CHUNK_SIZE = 800
  CHUNK_OVERLAP = 100
  EMBED_BATCH_SIZE = 16

  def perform(document)
    document = AiAssistant::Document.find_by(id: document) if document.is_a?(Integer)
    return if document.blank?

    # with_lock 串行化并发处理,配合 (document_id, position) 唯一索引防重复切片
    document.with_lock { process(document) }
  end

  private

  def process(document)
    document.chunks.delete_all
    document.update!(status: :processing)

    chunks = build_chunks(document.content)
    embeddings = embed_all(chunks, document.hook)
    return mark_failed(document) if embeddings.nil?

    persist_chunks(document, chunks, embeddings)
    document.update!(status: :ready, embedding_model: current_model(document.hook))
  end

  # 按段落聚合成约 CHUNK_SIZE 字符的片,相邻片保留 CHUNK_OVERLAP 重叠.
  def build_chunks(content)
    paragraphs = content.to_s.split(/\n{2,}/).map(&:strip).reject(&:blank?)
    chunks = []
    buffer = ''
    paragraphs.each do |para|
      buffer = flush_buffer(chunks, buffer) if overflow?(buffer, para)
      buffer = "#{buffer}\n\n#{para}"
    end
    chunks << buffer.strip if buffer.strip.present?
    chunks
  end

  def overflow?(buffer, para)
    buffer.present? && buffer.length + para.length > CHUNK_SIZE
  end

  # 收纳当前片并返回带重叠的新 buffer.
  def flush_buffer(chunks, buffer)
    chunks << buffer.strip
    buffer[-CHUNK_OVERLAP..] || buffer
  end

  # 分批向量化,任一批失败返回 nil.
  def embed_all(chunks, hook)
    results = []
    chunks.each_slice(EMBED_BATCH_SIZE) do |batch|
      vectors = Llm::EmbeddingService.new(texts: batch, hook: hook).perform
      return nil if vectors.blank? || vectors.length != batch.length

      results.concat(vectors)
    end
    results
  end

  def persist_chunks(document, chunks, embeddings)
    chunks.each_with_index do |content, index|
      document.chunks.create!(content: content, embedding: embeddings[index], position: index)
    end
  end

  def current_model(hook)
    (hook.settings || {})['embedding_model']
  end

  def mark_failed(document)
    document.update!(status: :failed)
    Rails.logger.error("[AiAssistant::DocumentProcessJob] embedding failed for document #{document.id}")
  end
end
