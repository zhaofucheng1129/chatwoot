class CreateAiAssistantDocuments < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_assistant_documents do |t|
      t.bigint :account_id, null: false
      t.bigint :hook_id, null: false
      t.string :title, null: false
      t.text :content, null: false
      t.integer :status, default: 0, null: false
      # 记录处理时所用向量模型,用于检测模型切换后重建索引
      t.string :embedding_model

      t.timestamps
    end

    add_index :ai_assistant_documents, :account_id
    add_index :ai_assistant_documents, :hook_id
  end
end
