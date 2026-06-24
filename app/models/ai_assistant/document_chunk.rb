# == Schema Information
#
# Table name: ai_assistant_document_chunks
#
#  id          :bigint           not null, primary key
#  content     :text             not null
#  embedding   :vector
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
# 知识库文档切片.embedding 为 pgvector 不定长向量列,检索用 nearest_neighbors
# 在库内做余弦相似度(<=>),不再全量加载到 Ruby.
class AiAssistant::DocumentChunk < ApplicationRecord
  self.table_name = 'ai_assistant_document_chunks'

  has_neighbors :embedding

  belongs_to :document, class_name: 'AiAssistant::Document'

  validates :content, presence: true
end
