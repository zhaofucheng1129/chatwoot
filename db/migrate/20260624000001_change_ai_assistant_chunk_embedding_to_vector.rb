class ChangeAiAssistantChunkEmbeddingToVector < ActiveRecord::Migration[7.1]
  # 知识库向量检索改用 pgvector:embedding 列从 jsonb 改为不定长 vector,
  # 余弦相似度交给数据库(<=> 运算符)在库内计算,不再把全部切片向量加载进
  # Ruby 逐条计算.列不指定维度,便于后续更换向量模型(维度变化)而无需再迁移;
  # 因此暂不建固定维度的 ANN 索引(FAQ 量级顺序扫描已足够快).
  def up
    enable_extension 'vector' unless extension_enabled?('vector')

    execute <<~SQL.squish
      ALTER TABLE ai_assistant_document_chunks
      ALTER COLUMN embedding TYPE vector USING embedding::text::vector
    SQL
  end

  def down
    execute <<~SQL.squish
      ALTER TABLE ai_assistant_document_chunks
      ALTER COLUMN embedding TYPE jsonb USING embedding::text::jsonb
    SQL
  end
end
