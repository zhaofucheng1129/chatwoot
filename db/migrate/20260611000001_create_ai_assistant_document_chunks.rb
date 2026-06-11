class CreateAiAssistantDocumentChunks < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_assistant_document_chunks do |t|
      t.bigint :document_id, null: false
      t.text :content, null: false
      # 向量数组;MVP 用 jsonb + Ruby 余弦相似度,规避 pgvector 维度绑定
      t.jsonb :embedding
      t.integer :position

      t.timestamps
    end

    add_index :ai_assistant_document_chunks, :document_id
  end
end
