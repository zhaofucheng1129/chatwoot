class AddUniqueIndexToAiAssistantDocumentChunks < ActiveRecord::Migration[7.1]
  def change
    # 防止并发处理产生同 position 的重复切片
    add_index :ai_assistant_document_chunks, [:document_id, :position], unique: true
  end
end
