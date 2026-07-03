# AI 客服自动回复 Job.
#
# 仅在会话仍处于 pending(人工未接管)时处理:命中转人工关键词或模型给出
# handoff 信号/请求失败时,发送一条过渡消息并 bot_handoff! 转人工;否则把模型
# 回复作为 bot 消息(无 sender)写回会话.任何异常都兜底转人工,避免客户消息无人响应.
class Llm::AssistantResponseJob < ApplicationJob
  # 面向客户的 AI 回复属高时效任务,放 default 队列(高于 low 的文档索引等后台任务),
  # 避免被 low 队列里的批处理拖慢回复.
  queue_as :default

  # 转人工过渡消息的基底文案,实际发送前按客户语言翻译.
  HANDOFF_MESSAGE = 'Transferring you to a human agent, please hold on.'.freeze

  def perform(conversation, hook)
    @conversation = conversation
    @hook = hook

    # 仅当会话没有分配人工客服时由 AI 接管(不论 open/pending);已分配人工则交给人工.
    return if conversation.assignee_id.present?
    return if conversation.resolved?

    # 客户端进入订单会话时自动发的"订单卡片"消息不是客户的真实提问, 不触发 AI 回复:
    # 改为回一条"快捷问题"卡片消息, 等客户真正提问再回复(订单数据仍注入上下文, 仅在
    # 被问到时引用). 避免一进会话就机械复述订单状态.
    return reply_quick_questions if order_card_trigger?

    # 按钮显式请求或打字命中关键词时直接 handoff,且不广播 AI typing,避免点
    # 「人工客服」后先闪一下"AI 助理思考中"再切到"正在为您接入人工客服".
    return handoff if explicit_handoff_request? || handoff_keyword_hit?

    # 输入护栏:命中提示词注入/越狱/离题诱导时直接回标准话术,不调用主模型、不转人工
    # (模型不被触达, 自然无法被引导).先跑零成本的字面正则, 再跑 LLM 语义判别.
    return reply_with_guard_message if guarded_input?

    generate_reply
  end

  private

  # 取最近 GUARD_CONTEXT_TURNS 条客户消息(多轮上下文), 覆盖渐进式/拆分注入.
  GUARD_CONTEXT_TURNS = 4

  def recent_customer_messages
    @recent_customer_messages ||=
      @conversation.messages
                   .where(message_type: :incoming, private: false)
                   .last(GUARD_CONTEXT_TURNS)
                   .filter_map { |message| message.content.to_s.strip.presence }
  end

  # 先字面正则(对拼接后的多轮文本, 可挡拆分注入), 命中则跳过更贵的 LLM 判别.
  def guarded_input?
    return true if guard.injection?(recent_customer_messages.join("\n"))

    Llm::GuardClassifierService.new(
      settings: @hook.settings || {}, messages: recent_customer_messages
    ).suspicious?
  end

  def reply_with_guard_message
    create_message(guard.safe_message)
  end

  # 客户在 AI 生成回复期间看到"正在输入"状态(外部 bot 经 API 回帖不会自动
  # 发 typing, 这里以机器人身份显式广播). ensure 确保任何路径都会关闭.
  def generate_reply
    trigger_typing(Events::Types::CONVERSATION_TYPING_ON)
    begin
      respond_with_llm
    rescue StandardError => e
      # No automatic handoff on error: stay with the AI (the customer can reach
      # a human via the explicit "Live agent" button). Auto-transferring on a
      # transient failure is exactly the behavior we must avoid.
      Rails.logger.error("[Llm::AssistantResponseJob] failed for conversation #{@conversation&.id}: #{e.class} #{e.message}")
    ensure
      trigger_typing(Events::Types::CONVERSATION_TYPING_OFF)
    end
  end

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

  def guard
    @guard ||= Llm::ResponseGuardService.new(settings: @hook.settings || {})
  end

  def respond_with_llm
    result = Llm::AssistantChatService.new(conversation: @conversation, hook: @hook).perform
    # No automatic handoff: a human is reached ONLY via the explicit "Live
    # agent" button or a typed handoff keyword (see #perform). We deliberately
    # ignore the model's [[HANDOFF]] signal and never transfer on a nil/empty
    # result -- the model's own reply invites the Live agent button when a human
    # is wanted, so normal questions are always answered by the AI.
    return if result.nil?

    content = result[:content].to_s.strip
    return if content.empty?

    create_message(content)
  end

  # 客户端「人工客服」按钮发来的显式请求:末条 incoming 的
  # content_attributes.lt_request == 'live_agent'. 与输入框打字的关键词路径
  # 区分,按钮精确触发,不依赖关键词模糊匹配(契约见 app 端 requestLiveAgent).
  def explicit_handoff_request?
    @conversation.messages.incoming.last&.content_attributes&.dig('lt_request') == 'live_agent'
  end

  # 末条 incoming 是客户端自动发送的订单卡片(content_attributes.lt_type ==
  # 'order_card', 契约见 app 端 _maybeSendOrderContext). 命中则跳过 AI 回复.
  def order_card_trigger?
    @conversation.messages.incoming.last&.content_attributes&.dig('lt_type') == 'order_card'
  end

  # 订单卡片进入会话后, 回一条"快捷问题"卡片消息(content_attributes.lt_type ==
  # 'quick_questions', 契约见 app 端 ChatMessageMapper). 内容取自 hook 设置的
  # quick_questions(按客户端语言 lt_locale 选集). 未配置或该语言缺失则不发
  # (客户端无卡片可显示时静默即可).
  def reply_quick_questions
    return unless quick_questions_due?

    payload = quick_questions_payload
    return if payload.blank?

    create_message(
      quick_questions_fallback_text(payload),
      content_attributes: {
        'lt_type' => 'quick_questions',
        'lt_quick_questions' => payload
      }
    )
  end

  # 是否该(再)发快捷问题卡: 从未发过则发(首张订单卡片场景); 否则仅当上一张
  # 快捷问题卡之后已有真实对话消息时才再发, 避免连续多张订单卡片之间反复刷 FAQ.
  def quick_questions_due?
    messages = @conversation.messages.order(:id).to_a
    last_card_index = messages.rindex do |message|
      message.content_attributes&.dig('lt_type') == 'quick_questions'
    end
    return true if last_card_index.nil?

    messages[(last_card_index + 1)..].any? { |message| dialogue_message?(message) }
  end

  # 真实对话消息: 既非订单卡片/快捷问题卡片, 也非 live-agent 状态标记.
  def dialogue_message?(message)
    attrs = message.content_attributes || {}
    attrs['lt_type'].blank? && attrs['lt_status'].blank?
  end

  # 从 hook.settings['quick_questions'] 取当前客户端语言的问题集. 结构:
  #   { "en" => { "greeting" => "..", "pages" => [ { "items" => ["q1","q2"] } ] } }
  def quick_questions_payload
    config = @hook.settings['quick_questions']
    return if config.blank?

    set = quick_questions_locale_candidates.filter_map { |key| config[key] }.first
    set.presence
  end

  # 客户端 lt_locale 是 BCP-47(如 'zh-Hans-CN'). 逐段回退再退 default/en:
  #   'zh-Hans-CN' -> 'zh-Hans' -> 'zh' -> 'default' -> 'en',
  # 从而 'zh-Hans' 键即可命中, 且 'ja-JP' 等带国家的 tag 也能落到主语言键.
  def quick_questions_locale_candidates
    parts = order_card_locale.to_s.split('-').reject(&:blank?)
    prefixes = parts.length.downto(1).map { |n| parts.first(n).join('-') }
    prefixes + %w[default en]
  end

  # 客户端订单卡片消息带 content_attributes.lt_locale, 标明客户界面语言.
  # reply_quick_questions 由 order_card_trigger? 触发, 此时末条 incoming 即订单卡片.
  def order_card_locale
    @conversation.messages.incoming.last&.content_attributes&.dig('lt_locale')
  end

  # 坐席后台 / 不支持卡片的端看到的纯文本兜底(问候语 + 所有问题逐行).
  def quick_questions_fallback_text(payload)
    lines = []
    lines << payload['greeting'] if payload['greeting'].present?
    Array(payload['pages']).each do |page|
      Array(page['items']).each { |item| lines << item }
    end
    lines.join("\n")
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
