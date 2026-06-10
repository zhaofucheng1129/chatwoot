# AI 客服对话生成服务,基于 OpenAI 兼容的 /chat/completions 接口.
#
# provider 配置从 inbox 上启用的 ai_assistant Integrations::Hook 读取
# (base_url/api_key/model/system_prompt).组装 system prompt 与最近会话历史后
# 请求模型生成回复;若模型判断无法处理或客户要求人工,会在回复末尾输出
# [[HANDOFF]] 标记,本服务解析后通过 handoff: true 通知调用方转人工.
class Llm::AssistantChatService
  pattr_initialize [:conversation!, :hook!]

  MAX_RETRY = 3
  TIMEOUT = 60
  # 历史消息条数与单条字符上限
  HISTORY_LIMIT = 20
  MAX_MESSAGE_LENGTH = 10_000
  HANDOFF_TOKEN = '[[HANDOFF]]'.freeze

  # 返回 { content:, handoff: } ;请求失败返回 nil 由调用方做 handoff 兜底.
  def perform
    response = request_with_retry
    return unless response

    parse(extract_content(response))
  end

  private

  def settings
    @settings ||= hook.settings || {}
  end

  def request_with_retry
    (1..MAX_RETRY).each do |attempt|
      response = post_request
      return response if response.success?

      # 免费档模型常见 429 限流,退避后重试;其它错误码直接放弃.
      break unless response.code == 429 && attempt < MAX_RETRY

      sleep(attempt * 1.5)
    end
    nil
  rescue StandardError => e
    Rails.logger.error("[Llm::AssistantChatService] request failed #{e.class}: #{e.message}")
    nil
  end

  def post_request
    HTTParty.post(
      "#{settings['base_url'].to_s.chomp('/')}/chat/completions",
      headers: { 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{settings['api_key']}" },
      body: request_body,
      timeout: TIMEOUT
    )
  end

  def request_body
    {
      model: settings['model'],
      temperature: 0.5,
      messages: [{ role: 'system', content: system_prompt }] + history_messages
    }.to_json
  end

  def system_prompt
    "#{settings['system_prompt']}\n\n" \
      "If you cannot answer the customer's question, or the customer explicitly asks for a human/live agent, " \
      "append the marker #{HANDOFF_TOKEN} at the very end of your reply."
  end

  # 取最近 HISTORY_LIMIT 条 incoming/outgoing 聊天消息(排除私有备注与活动消息).
  def history_messages
    conversation.messages
                .where(message_type: [:incoming, :outgoing])
                .where(private: false)
                .last(HISTORY_LIMIT)
                .map do |message|
      {
        role: message.incoming? ? 'user' : 'assistant',
        content: message.content.to_s[0, MAX_MESSAGE_LENGTH]
      }
    end
  end

  def extract_content(response)
    response.parsed_response.dig('choices', 0, 'message', 'content')&.strip
  end

  def parse(content)
    return if content.blank?

    handoff = content.include?(HANDOFF_TOKEN)
    { content: content.gsub(HANDOFF_TOKEN, '').strip, handoff: handoff }
  end
end
