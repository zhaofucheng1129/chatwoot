# == Schema Information
#
# Table name: ai_assistant_documents
#
#  id              :bigint           not null, primary key
#  content         :text             not null
#  embedding_model :string
#  status          :integer          default("processing"), not null
#  title           :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :bigint           not null
#  hook_id         :bigint           not null
#
# Indexes
#
#  index_ai_assistant_documents_on_account_id  (account_id)
#  index_ai_assistant_documents_on_hook_id     (hook_id)
#
# AI 客服助理知识库文档.上传后切片向量化,供客户提问时余弦检索.
class AiAssistant::Document < ApplicationRecord
  self.table_name = 'ai_assistant_documents'

  belongs_to :account
  belongs_to :hook, class_name: 'Integrations::Hook'
  has_many :chunks, class_name: 'AiAssistant::DocumentChunk', dependent: :destroy

  enum status: { processing: 0, ready: 1, failed: 2 }

  validates :title, presence: true
  validates :content, presence: true

  # 创建后异步切片向量化
  after_create_commit :enqueue_processing

  private

  def enqueue_processing
    AiAssistant::DocumentProcessJob.perform_later(id)
  end
end
