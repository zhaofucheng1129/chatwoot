# AI 客服自动回复 Job.
#
# 仅在会话仍处于 pending(人工未接管)时处理:命中转人工关键词或模型给出
# handoff 信号/请求失败时,发送一条过渡消息并 bot_handoff! 转人工;否则把模型
# 回复作为 bot 消息(无 sender)写回会话.任何异常都兜底转人工,避免客户消息无人响应.
class Llm::AssistantResponseJob < ApplicationJob
  queue_as :low

  # 转人工过渡消息的基底文案,实际发送前按客户语言翻译.
  HANDOFF_MESSAGE = 'Transferring you to a human agent, please hold on.'.freeze

  def perform(conversation, hook)
    @conversation = conversation
    @hook = hook

    return unless conversation.pending?

    return handoff if handoff_keyword_hit?

    respond_with_llm
  rescue StandardError => e
    Rails.logger.error("[Llm::AssistantResponseJob] failed for conversation #{conversation&.id}: #{e.class} #{e.message}")
    handoff
  end

  private

  def respond_with_llm
    result = Llm::AssistantChatService.new(conversation: @conversation, hook: @hook).perform
    # 模型主动转人工时其回复本身已是客户语言,优先作为过渡话术
    return handoff(result&.dig(:content)) if result.nil? || result[:handoff]

    create_message(result[:content])
  end

  # 最后一条 incoming 消息命中 handoff_keywords(逗号分隔,包含匹配)即转人工.
  def handoff_keyword_hit?
    keywords = (@hook.settings['handoff_keywords']).to_s.split(',').map { |k| k.strip.downcase }.reject(&:blank?)
    return false if keywords.empty?

    content = @conversation.messages.incoming.last&.content.to_s.downcase
    keywords.any? { |keyword| content.include?(keyword) }
  end

  def handoff(content = nil)
    return unless @conversation.pending?

    create_message(content.presence || translated_handoff_message)
    @conversation.bot_handoff!
  end

  # 关键词/异常路径的过渡话术:按客户消息的检测语言翻译(走 AI 翻译的独立供应商,
  # 与助理供应商互为备份),按语言缓存;翻译不可用时回退英文基底文案.
  def translated_handoff_message
    lang = detected_customer_language
    return HANDOFF_MESSAGE if lang.blank? || lang.start_with?('en')

    # skip_nil: 翻译失败不缓存,下次重试;成功结果按语言缓存 7 天
    translated = Rails.cache.fetch("ai_assistant/handoff_message/#{lang}", expires_in: 7.days, skip_nil: true) do
      translate_handoff(lang)
    end
    translated.presence || HANDOFF_MESSAGE
  rescue StandardError
    HANDOFF_MESSAGE
  end

  def detected_customer_language
    message = @conversation.messages.incoming.last
    return if message.blank?

    # 异步检测可能尚未落库,用本地 CLD3 同步兜底(毫秒级,无外部调用)
    message.content_attributes['detected_language'].presence ||
      Messages::LanguageDetectionService.new(text: message.content).perform
  end

  def translate_handoff(lang)
    Llm::TranslationService.new(
      content: HANDOFF_MESSAGE, target_language: lang, account: @conversation.account
    ).perform.presence
  end

  def create_message(content)
    @conversation.messages.create!(
      message_type: :outgoing,
      account_id: @conversation.account_id,
      inbox_id: @conversation.inbox_id,
      content: content,
      sender: bot_sender
    )
  end

  # 设置了 bot_name 时以同名机器人身份发送(挂件显示该名称);未设置则无 sender(默认"机器人").
  def bot_sender
    name = @hook.settings['bot_name'].to_s.strip
    return if name.blank?

    @bot_sender ||= @conversation.account.agent_bots.find_or_create_by!(name: name)
  end
end
