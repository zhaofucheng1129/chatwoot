# == Schema Information
#
# Table name: ai_assistant_inboxes
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  hook_id    :bigint           not null
#  inbox_id   :bigint           not null
#
# ai_assistant hook(即一个 AI 助理)与收件箱的多对多关联.
# 一个助理可服务多个收件箱, 这些收件箱共享同一套配置与知识库(挂在 hook 上).
class AiAssistant::Inbox < ApplicationRecord
  # 命名空间模型默认会推断成 inboxes 表, 必须显式指定 (与 AiAssistant::Document 一致)
  self.table_name = 'ai_assistant_inboxes'

  belongs_to :hook, class_name: 'Integrations::Hook'
  belongs_to :inbox, class_name: '::Inbox'

  # 一个收件箱只能归属一个 AI 助理
  validates :inbox_id, uniqueness: true
  # 与原生外部机器人互斥: 同一收件箱两套机器人会互相抢消息
  validate :ensure_no_active_agent_bot

  private

  def ensure_no_active_agent_bot
    return if inbox.blank? || !inbox.agent_bot_inbox&.active?

    errors.add(:base, I18n.t('errors.ai_assistant.agent_bot_conflict'))
  end
end
