# == Schema Information
#
# Table name: ai_assistant_document_chunks
#
#  id          :bigint           not null, primary key
#  content     :text             not null
#  embedding   :jsonb
#  position    :integer
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  document_id :bigint           not null
#
# Indexes
#
#  index_ai_assistant_document_chunks_on_document_id               (document_id)
#  index_ai_assistant_document_chunks_on_document_id_and_position  (document_id,position) UNIQUE
#
# 知识库文档切片.embedding 存向量数组(jsonb),检索时全量加载做余弦相似度.
class AiAssistant::DocumentChunk < ApplicationRecord
  self.table_name = 'ai_assistant_document_chunks'

  belongs_to :document, class_name: 'AiAssistant::Document'

  validates :content, presence: true
end
