# 拉取客户当前订单详情, 供 AI 客服回复时作为上下文参考, 让助理能更准确回答订单
# 相关问题(状态/金额/行程/出发日期等).
#
# 临时测试接口, 后续部署到服务端会替换:base url 走环境变量 LIONTRIP_ORDER_API_URL
# (缺省回退到临时测试 IP), path 为常量.
#
# order_no 取值:优先取最近 incoming 历史里最新的 #<orderId> 订单上下文消息(客户端
# 每进一个订单会发一条这样的消息, 反映客户当前在问哪个订单), 取不到再回退到会话
# custom_attributes 上的 order_id(建会话时写入的首个订单).
#
# 可用性:无订单号 / 接口失败 / 空响应一律返回 nil 由调用方降级(跳过订单上下文照常
# 回复), 绝不抛出阻塞主回复流程.
class Llm::OrderDetailService
  pattr_initialize [:conversation!]

  ORDER_PATH = '/order/api/v1/internalservice/orders'.freeze
  DEFAULT_BASE_URL = 'http://20.187.191.189'.freeze
  OPEN_TIMEOUT = 5
  TIMEOUT = 15
  # 倒序扫描寻找订单号的最近 incoming 消息条数
  HISTORY_LIMIT = 20
  # 注入 prompt 的订单详情上限, 防止 prompt 过度膨胀
  MAX_DETAIL_LENGTH = 4_000

  # 返回注入 system prompt 的订单详情段落;无订单号 / 失败 / 空响应返回 nil.
  def perform
    order_no = current_order_no
    return if order_no.blank?

    detail = fetch(order_no)
    return if detail.blank?

    "\n\n以下是该客户当前订单(订单号 #{order_no})的详细信息(JSON). " \
      '不要主动复述或总结订单状态; 仅当客户明确询问订单相关问题时, 才依据它回答, ' \
      "其中没有的信息不要编造:\n" \
      "#{detail[0, MAX_DETAIL_LENGTH]}"
  rescue StandardError => e
    Rails.logger.error("[Llm::OrderDetailService] failed #{e.class}: #{e.message}")
    nil
  end

  private

  def base_url
    ENV['LIONTRIP_ORDER_API_URL'].presence || DEFAULT_BASE_URL
  end

  def current_order_no
    order_no_from_messages || conversation.custom_attributes&.dig('order_id').presence
  end

  # 倒序遍历最近 incoming 消息, 返回首个命中的订单号(即时间上最新的).
  def order_no_from_messages
    messages = conversation.messages
                           .where(message_type: :incoming, private: false)
                           .last(HISTORY_LIMIT)
    messages.reverse_each do |message|
      order_no = parse_order_no(message.content.to_s)
      return order_no if order_no.present?
    end
    nil
  end

  # 订单上下文消息正文里以 # 开头的那一行即订单号(对齐客户端发送格式).
  def parse_order_no(content)
    content.each_line do |line|
      trimmed = line.strip
      return trimmed[1..] if trimmed.start_with?('#') && trimmed.length > 1
    end
    nil
  end

  def fetch(order_no)
    response = HTTParty.get(
      "#{base_url.chomp('/')}#{ORDER_PATH}/#{order_no}",
      headers: { 'accept' => 'application/json' },
      open_timeout: OPEN_TIMEOUT,
      read_timeout: TIMEOUT
    )
    if response.success?
      response.body
    else
      Rails.logger.error("[Llm::OrderDetailService] non-2xx for order #{order_no}: #{response.code}")
      nil
    end
  end
end
