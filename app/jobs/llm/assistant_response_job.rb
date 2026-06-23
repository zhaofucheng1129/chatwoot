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

    # 仅当会话没有分配人工客服时由 AI 接管(不论 open/pending);已分配人工则交给人工.
    return if conversation.assignee_id.present?
    return if conversation.resolved?

    # 按钮显式请求或打字命中关键词时直接 handoff,且不广播 AI typing,避免点
    # 「人工客服」后先闪一下"AI 助理思考中"再切到"正在为您接入人工客服".
    return handoff if explicit_handoff_request? || handoff_keyword_hit?

    # 客户在 AI 生成回复期间看到"正在输入"状态(外部 bot 经 API 回帖不会自动
    # 发 typing, 这里以机器人身份显式广播). ensure 确保任何路径都会关闭.
    trigger_typing(Events::Types::CONVERSATION_TYPING_ON)
    begin
      respond_with_llm
    rescue StandardError => e
      Rails.logger.error("[Llm::AssistantResponseJob] failed for conversation #{conversation&.id}: #{e.class} #{e.message}")
      handoff
    ensure
      trigger_typing(Events::Types::CONVERSATION_TYPING_OFF)
    end
  end

  private

  # 以机器人身份广播 typing 状态; 经 ActionCableListener 推到联系人.
  # 需要 bot 身份(push_event_data), 未设 bot_name 时跳过.
  def trigger_typing(event)
    bot = bot_sender
    return if bot.nil?

    Rails.configuration.dispatcher.dispatch(
      event, Time.zone.now, conversation: @conversation, user: bot, is_private: false
    )
  rescue StandardError => e
    Rails.logger.warn("[Llm::AssistantResponseJob] typing dispatch failed: #{e.message}")
  end

  def respond_with_llm
    result = Llm::AssistantChatService.new(conversation: @conversation, hook: @hook).perform
    # 模型主动转人工时其回复本身已是客户语言,优先作为过渡话术
    return handoff(result&.dig(:content)) if result.nil? || result[:handoff]

    create_message(result[:content])
  end

  # 客户端「人工客服」按钮发来的显式请求:末条 incoming 的
  # content_attributes.lt_request == 'live_agent'. 与输入框打字的关键词路径
  # 区分,按钮精确触发,不依赖关键词模糊匹配(契约见 app 端 requestLiveAgent).
  def explicit_handoff_request?
    @conversation.messages.incoming.last&.content_attributes&.dig('lt_request') == 'live_agent'
  end

  # 输入框打字命中 handoff_keywords 即转人工. 收紧为整条消息(去空白/标点后)
  # 精确等于某个关键词才算,避免"人工智能"等含子串的正常提问被误判转人工.
  def handoff_keyword_hit?
    raw = @hook.settings['handoff_keywords'].to_s.split(',')
    keywords = raw.map { |k| normalize_handoff_text(k) }.reject(&:blank?)
    return false if keywords.empty?

    content = normalize_handoff_text(@conversation.messages.incoming.last&.content)
    content.present? && keywords.include?(content)
  end

  # 归一化:小写 + 去掉所有空白与标点,便于精确比较(中英标点都处理).
  def normalize_handoff_text(text)
    text.to_s.downcase.gsub(/[[:space:][:punct:]]/, '')
  end

  def handoff(content = nil)
    # Skip if a human is already on the conversation (avoid a duplicate
    # transition message); otherwise post the transition line and hand off.
    return if @conversation.assignee_id.present?

    # 过渡消息打上「连接中」状态标记,客户端据此还原连接状态(含历史回放).
    # 不做翻译:移动端按 content_attributes.lt_status 走自己的 l10n 渲染,不显示
    # 这段文字;且翻译是外部调用,放在分配真人之前会拖慢整个转人工(见 B 优化).
    create_message(
      content.presence || HANDOFF_MESSAGE,
      content_attributes: { 'lt_status' => 'agent_connecting' }
    )
    @conversation.bot_handoff!
    assign_human_agent
  end

  # Assign a human on handoff so the conversation actually reaches an agent
  # (bot_handoff! alone only opens + emits an event). Prefer an online agent via
  # the inbox round-robin rules; fall back to any inbox member so the handoff
  # still lands on someone and the assistant stops replying (the assistant only
  # answers unassigned conversations).
  def assign_human_agent
    return if @conversation.assignee_id.present?

    candidate_ids = routable_agent_ids
    return if candidate_ids.empty?

    AutoAssignment::AgentAssignmentService.new(
      conversation: @conversation, allowed_agent_ids: candidate_ids
    ).perform
    # Round-robin 没分到人时兜底指派第一个候选,确保 handoff 真正落到人.
    @conversation.update(assignee_id: candidate_ids.first) if @conversation.reload.assignee_id.blank?

    # 真人已接入:发一条带客服名的「已接入」状态标记消息(历史可还原).
    announce_agent_connected if @conversation.reload.assignee_id.present?
  rescue StandardError => e
    Rails.logger.warn("[Llm::AssistantResponseJob] agent assignment failed: #{e.message}")
  end

  # 「已接入真人」状态标记消息.content 仅作坐席后台/兜底文案,客户端按 l10n 用
  # content_attributes.lt_status 渲染状态,agent_name 用于显示客服名.
  def announce_agent_connected
    name = @conversation.assignee&.name
    create_message(
      name.present? ? "#{name} joined the conversation" : 'A support agent joined the conversation',
      content_attributes: { 'lt_status' => 'agent_connected', 'agent_name' => name }
    )
  end

  # Candidate agents for a handoff: the conversation's team members when a team
  # has been routed to it (the account's automation rules assign the team from
  # the order/product attributes such as order_title); otherwise all inbox
  # members. Round-robin then picks among these.
  def routable_agent_ids
    team_member_ids = @conversation.team&.members&.pluck(:id)
    return team_member_ids if team_member_ids.present?

    @conversation.inbox.inbox_members.pluck(:user_id)
  end

  def create_message(content, content_attributes: {})
    @conversation.messages.create!(
      message_type: :outgoing,
      account_id: @conversation.account_id,
      inbox_id: @conversation.inbox_id,
      content: content,
      content_attributes: content_attributes,
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
