# AI 客服自动回复 Job.
#
# 仅在会话仍处于 pending(人工未接管)时处理:命中转人工关键词或模型给出
# handoff 信号/请求失败时,发送一条过渡消息并 bot_handoff! 转人工;否则把模型
# 回复作为 bot 消息(无 sender)写回会话.任何异常都兜底转人工,避免客户消息无人响应.
class Llm::AssistantResponseJob < ApplicationJob
  queue_as :low

  # 转人工时发送给客户的过渡消息.
  HANDOFF_MESSAGE = 'Transferring you to a human agent, please hold on.'.freeze

  def perform(conversation, hook)
    @conversation = conversation
    @hook = hook

    return unless conversation.pending?

    return handoff if handoff_keyword_hit?

    result = Llm::AssistantChatService.new(conversation: conversation, hook: hook).perform
    return handoff if result.nil? || result[:handoff]

    create_message(result[:content])
  rescue StandardError => e
    Rails.logger.error("[Llm::AssistantResponseJob] failed for conversation #{conversation&.id}: #{e.class} #{e.message}")
    handoff
  end

  private

  # 最后一条 incoming 消息命中 handoff_keywords(逗号分隔,包含匹配)即转人工.
  def handoff_keyword_hit?
    keywords = (@hook.settings['handoff_keywords']).to_s.split(',').map { |k| k.strip.downcase }.reject(&:blank?)
    return false if keywords.empty?

    content = @conversation.messages.incoming.last&.content.to_s.downcase
    keywords.any? { |keyword| content.include?(keyword) }
  end

  def handoff
    return unless @conversation.pending?

    create_message(HANDOFF_MESSAGE)
    @conversation.bot_handoff!
  end

  # 无 sender 即 bot 发出的 outgoing 消息.
  def create_message(content)
    @conversation.messages.create!(
      message_type: :outgoing,
      account_id: @conversation.account_id,
      inbox_id: @conversation.inbox_id,
      content: content
    )
  end
end
